-- Kodi Movies (Open Source) - media service driver
--
-- Browses the movie library of the Kodi player this driver is linked to and
-- shows it on Control4 Navigators and Halo remotes: posters, titles, plots,
-- genres, collections, recently added and in-progress lists. Selecting a movie
-- asks the linked Kodi driver to turn the room on (Kodi as the video source)
-- and then start the movie.
--
-- Bindings
--   5001  media_service proxy (Navigator UI)
--   1     LINK_OSKODI_MOVIES -> Kodi Virtual Switcher (route to the room)
--   2001  RF_OSKODI_MOVIES   -> Kodi Virtual Switcher (AV path)
--   3900  OSKODI_PLAYER_LINK -> Kodi driver (control link, driver-to-driver)

JSON = require("module.json")
local Library = require("library")
local Artwork = require("artwork")
local KodiHttp = require("kodi_http")

DRIVER_VERSION = "1.0.0"
DRIVER_FILENAME = "kodi_os_movies"

local MSP_PROXY = 5001
local LINK_BINDING_ID = 3900

local PAGE_SIZE = 250                   -- movies per VideoLibrary.GetMovies request
local WAIT_FOR_LOAD_MS = 25000          -- longest a navigator waits for a first load
local REGISTER_RETRY_MS = 30000
local RELOAD_DEBOUNCE_MS = 15000
local RETRY_AFTER_ERROR_MS = 60000

-------------------------------------------------------------------------------
-- Logging / properties
-------------------------------------------------------------------------------

local function prop(name, default)
  if Properties and Properties[name] ~= nil and Properties[name] ~= "" then
    return Properties[name]
  end
  return default
end

local function logInfo(msg)
  print("Kodi Movies: " .. tostring(msg))
end

local function logDebug(msg)
  if prop("Debug Mode", "OFF") == "ON" then
    print("Kodi Movies: " .. tostring(msg))
  end
end

local function updateProperty(name, value)
  pcall(function() C4:UpdateProperty(name, tostring(value)) end)
end

local function cancelTimer(t)
  if type(t) == "userdata" or type(t) == "table" then
    pcall(function() t:Cancel() end)
  elseif type(t) == "number" and t ~= 0 then
    pcall(function() C4:KillTimer(t) end)
  end
  return nil
end

local function setTimer(ms, fn, rep)
  return C4:SetTimer(ms, fn, rep)
end

local function jsonDecode(s)
  if type(s) ~= "string" or s == "" then return nil end
  local ok, v = pcall(function() return C4:JsonDecode(s) end)
  if ok and type(v) == "table" then return v end
  ok, v = pcall(function() return JSON:decode(s) end)
  if ok and type(v) == "table" then return v end
  return nil
end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local library = Library.new()
local artwork = Artwork.new({ mode = "internet" })
local http = KodiHttp.new({
  jsonEncode = function(v) return JSON:encode(v) end,
  jsonDecode = jsonDecode,
  logDebug = logDebug,
})

local link = {
  config = nil,           -- last OSKODI_CONFIG
  registerTimer = nil,
}

local load = {
  state = "idle",         -- idle | loading | ready | error
  error = nil,
  generation = 0,
  waiters = {},
  retryTimer = nil,
  reloadTimer = nil,
  refreshTimer = nil,
  lastFailure = 0,
}

local pendingPlays = {}   -- movieId -> { navId, roomId, title }
Navigators = Navigators or {}

-------------------------------------------------------------------------------
-- XML helpers
-------------------------------------------------------------------------------

local function xmlEscape(s)
  if s == nil then return "" end
  s = tostring(s)
  -- Drop control characters XML 1.0 cannot carry (keep tab/newline/CR).
  s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  s = s:gsub('"', "&quot;")
  s = s:gsub("'", "&apos;")
  return s
end

local ITEM_FIELD_ORDER = {
  "id", "itemType", "title", "subtitle", "duration", "isLink", "isHeader",
  "default_action", "actions_list",
}

local function itemXml(item)
  local parts = { "<item>" }
  for _, k in ipairs(ITEM_FIELD_ORDER) do
    local v = item[k]
    if v ~= nil and v ~= "" then
      table.insert(parts, "<" .. k .. ">" .. xmlEscape(v) .. "</" .. k .. ">")
    end
  end
  for _, img in ipairs(item.images or {}) do
    table.insert(parts, '<image_list width="' .. img.width .. '" height="' .. img.height .. '">'
      .. xmlEscape(img.url) .. "</image_list>")
  end
  table.insert(parts, "</item>")
  return table.concat(parts)
end

local function listXml(items, totalLength)
  local body = {}
  for _, item in ipairs(items) do
    table.insert(body, itemXml(item))
  end
  if totalLength then
    return '<List length="' .. tostring(totalLength) .. '">' .. table.concat(body) .. "</List>"
  end
  return "<List>" .. table.concat(body) .. "</List>"
end

local function iconUrl(name, size)
  return "controller://driver/" .. DRIVER_FILENAME .. "/icons/" .. name .. "_" .. size .. ".png"
end

local function iconImages(name)
  name = name:gsub("^tab_", "row_")
  local out = {}
  for _, size in ipairs({ 70, 140, 300 }) do
    table.insert(out, { url = iconUrl(name, size), width = size, height = size })
  end
  return out
end

-------------------------------------------------------------------------------
-- Proxy messaging
-------------------------------------------------------------------------------

local function dataReceived(navId, seq, data)
  C4:SendToProxy(MSP_PROXY, "DATA_RECEIVED", {
    NAVID = navId,
    SEQ = seq,
    DATA = data or "",
  })
end

local function dataReceivedError(navId, seq, msg)
  C4:SendToProxy(MSP_PROXY, "DATA_RECEIVED", {
    NAVID = navId,
    SEQ = seq,
    DATA = "",
    ERROR = msg,
  })
end

local function sendEvent(navId, roomId, name, data)
  local params = { NAME = name, EVTARGS = data or "" }
  if navId then params.NAVID = navId end
  if roomId then params.ROOMID = tostring(roomId) end
  C4:SendToProxy(MSP_PROXY, "SEND_EVENT", params, "COMMAND")
end

local function notifyUser(navId, roomId, title, message)
  sendEvent(navId, roomId, "DriverNotification",
    "<Id>KodiMoviesNotice</Id><Title>" .. xmlEscape(title) .. "</Title><Message>" .. xmlEscape(message) .. "</Message>")
end

-------------------------------------------------------------------------------
-- Link to the main Kodi driver
-------------------------------------------------------------------------------

local function getPlayerDriverId()
  local ok, id = pcall(function()
    return C4:GetBoundProviderDevice(C4:GetDeviceID(), LINK_BINDING_ID)
  end)
  id = ok and tonumber(id) or nil
  if id and id > 0 then return id end
  return nil
end

local function sendToPlayer(command, params)
  local playerId = getPlayerDriverId()
  if not playerId then return false end
  local ok, err = pcall(function() C4:SendToDevice(playerId, command, params or {}) end)
  if not ok then
    logInfo("SendToDevice " .. command .. " failed: " .. tostring(err))
    return false
  end
  return true
end

local function updateLinkProperty()
  local playerId = getPlayerDriverId()
  if not playerId then
    updateProperty("Kodi Player", "Not linked - bind 'Kodi Player' to a Kodi driver")
    return
  end
  local name = link.config and link.config.playerName
  if not name or name == "" then
    local ok, n = pcall(function() return C4:GetDeviceDisplayName(playerId) end)
    name = (ok and n) or ("device " .. playerId)
  end
  local host = link.config and link.config.host or ""
  local status = (link.config and link.config.wsConnected) and "online" or "offline"
  if not link.config then status = "waiting for config" end
  updateProperty("Kodi Player", name .. (host ~= "" and (" @ " .. host) or "") .. " (" .. status .. ")")
end

local function register()
  if sendToPlayer("OSKODI_REGISTER", { DEVICE_ID = tostring(C4:GetDeviceID()) }) then
    logDebug("Registered with Kodi player driver")
  end
  updateLinkProperty()
end

local function startRegisterLoop()
  link.registerTimer = cancelTimer(link.registerTimer)
  register()
  link.registerTimer = setTimer(REGISTER_RETRY_MS, function()
    if not link.config then register() end
  end, true)
end

-------------------------------------------------------------------------------
-- Library loading
-------------------------------------------------------------------------------

local function flushWaiters()
  local waiters = load.waiters
  load.waiters = {}
  for _, w in ipairs(waiters) do
    w.timer = cancelTimer(w.timer)
    if not w.done then
      w.done = true
      local ok, err = pcall(w.fn)
      if not ok then logInfo("Waiter error: " .. tostring(err)) end
    end
  end
end

local function setLibraryStatus(text)
  updateProperty("Library Status", text)
end

local scheduleReload

local function loadLibrary(reason)
  if load.state == "loading" then return end

  if not http:isConfigured() then
    load.state = "error"
    load.error = getPlayerDriverId() and "Waiting for the Kodi driver to send its address" or "Not linked to a Kodi driver"
    setLibraryStatus(load.error)
    flushWaiters()
    return
  end

  load.state = "loading"
  load.error = nil
  load.generation = load.generation + 1
  local myGeneration = load.generation
  local accumulated = {}
  setLibraryStatus("Loading (" .. tostring(reason or "refresh") .. ")...")
  logInfo("Loading movie library (" .. tostring(reason or "refresh") .. ")")

  local function fail(err)
    load.state = "error"
    load.error = err
    load.lastFailure = os.time()
    logInfo("Library load failed: " .. tostring(err))
    setLibraryStatus("Error: " .. tostring(err))
    flushWaiters()
    load.retryTimer = cancelTimer(load.retryTimer)
    load.retryTimer = setTimer(RETRY_AFTER_ERROR_MS, function()
      load.retryTimer = nil
      if load.state == "error" then loadLibrary("retry") end
    end)
  end

  local function fetchPage(start)
    http:call("VideoLibrary.GetMovies", {
      properties = Library.PROPERTIES,
      limits = { start = start, ["end"] = start + PAGE_SIZE },
      sort = { method = "title", order = "ascending", ignorearticle = true },
    }, function(result, err)
      if myGeneration ~= load.generation then return end
      if err then
        fail(err)
        return
      end

      local movies = (type(result) == "table" and type(result.movies) == "table") and result.movies or {}
      for _, m in ipairs(movies) do table.insert(accumulated, m) end

      local total = (type(result) == "table" and type(result.limits) == "table" and tonumber(result.limits.total)) or #accumulated
      if #movies > 0 and #accumulated < total then
        fetchPage(start + PAGE_SIZE)
        return
      end

      library:setMovies(accumulated)
      library.loadedAt = os.time()
      load.state = "ready"
      load.error = nil
      load.retryTimer = cancelTimer(load.retryTimer)
      updateProperty("Movie Count", library.count)
      setLibraryStatus("Loaded " .. library.count .. " movies at " .. os.date("%H:%M"))
      logInfo("Library loaded: " .. library.count .. " movies")
      flushWaiters()
    end)
  end

  fetchPage(0)
end

scheduleReload = function(delayMs, reason)
  load.reloadTimer = cancelTimer(load.reloadTimer)
  load.reloadTimer = setTimer(delayMs or RELOAD_DEBOUNCE_MS, function()
    load.reloadTimer = nil
    if load.state == "loading" then
      scheduleReload(RELOAD_DEBOUNCE_MS, reason)
    else
      loadLibrary(reason)
    end
  end)
end

local function startAutoRefresh()
  load.refreshTimer = cancelTimer(load.refreshTimer)
  local minutes = tonumber(prop("Auto Refresh (minutes)", "60")) or 0
  if minutes <= 0 then return end
  load.refreshTimer = setTimer(minutes * 60 * 1000, function()
    if load.state ~= "loading" then loadLibrary("scheduled") end
  end, true)
end

-- Runs fn once the library is usable (ready or failed), or after a timeout.
local function whenLoaded(fn)
  if load.state == "ready" then
    fn()
    return
  end

  local waiter = { fn = fn, done = false }
  table.insert(load.waiters, waiter)
  waiter.timer = setTimer(WAIT_FOR_LOAD_MS, function()
    waiter.timer = nil
    if not waiter.done then
      waiter.done = true
      fn()
    end
  end)

  if load.state == "idle" then
    loadLibrary("first use")
  elseif load.state == "error" and (os.time() - (load.lastFailure or 0)) > 10 then
    loadLibrary("navigator")
  elseif load.state == "error" then
    flushWaiters()
  end
end

local function refreshMovie(movieId)
  http:call("VideoLibrary.GetMovieDetails", { movieid = movieId, properties = Library.PROPERTIES }, function(result, err)
    if err or type(result) ~= "table" or type(result.moviedetails) ~= "table" then
      logDebug("GetMovieDetails " .. tostring(movieId) .. " failed: " .. tostring(err))
      return
    end
    if library:upsert(result.moviedetails) then
      updateProperty("Movie Count", library.count)
      logDebug("Updated movie " .. tostring(movieId))
    end
  end)
end

-------------------------------------------------------------------------------
-- Config from the main driver
-------------------------------------------------------------------------------

local function artworkOptions(cfg)
  return {
    mode = (prop("Artwork Source", "Internet When Available") == "Kodi Web Server Only") and "kodi" or "internet",
    host = cfg and cfg.host or "",
    port = cfg and cfg.port or 8080,
    username = cfg and cfg.username or "",
    password = cfg and cfg.password or "",
    embedCredentials = prop("Send Kodi Login With Artwork", "ON") == "ON",
  }
end

local function applyConfig(params)
  local cfg = {
    host = params.HOST or "",
    port = tonumber(params.HTTP_PORT) or 8080,
    username = params.USERNAME or "",
    password = params.PASSWORD or "",
    wsConnected = params.WS_CONNECTED == "1",
    playerName = params.PLAYER_NAME or "",
    playerProxyId = tonumber(params.PLAYER_DEVICE_ID),
  }

  local old = link.config
  link.config = cfg
  http:configure({ host = cfg.host, port = cfg.port, username = cfg.username, password = cfg.password })
  artwork.configure(artworkOptions(cfg))
  updateLinkProperty()

  local addressChanged = (not old) or old.host ~= cfg.host or old.port ~= cfg.port
    or old.username ~= cfg.username or old.password ~= cfg.password

  if addressChanged then
    if cfg.host ~= "" then
      loadLibrary("Kodi address received")
    end
  elseif cfg.wsConnected and old and not old.wsConnected and load.state ~= "ready" then
    loadLibrary("Kodi came online")
  end
end

-------------------------------------------------------------------------------
-- Presentation
-------------------------------------------------------------------------------

local function movieSubtitle(m)
  local mode = prop("List Subtitle", "Year, Runtime and Plot")
  local bits = {}
  if m.year > 0 then table.insert(bits, tostring(m.year)) end
  local rt = Library.formatRuntime(m.runtime)
  if rt ~= "" then table.insert(bits, rt) end
  local head = table.concat(bits, " · ")

  if m.resumePos > 0 and m.resumeTotal > 0 then
    local left = math.max(0, m.resumeTotal - m.resumePos)
    head = head .. (head ~= "" and " · " or "") .. Library.formatRuntime(left) .. " left"
  elseif m.playcount > 0 and prop("Show Watched Marker", "ON") == "ON" then
    head = head .. (head ~= "" and " · " or "") .. "✓ Watched"
  end

  if mode == "Year and Runtime" then
    return head
  elseif mode == "Genre" then
    return table.concat(m.genres, ", ")
  elseif mode == "Year, Runtime and Genre" then
    local g = table.concat(m.genres, ", ")
    return (g ~= "" and head ~= "") and (head .. " · " .. g) or (head .. g)
  elseif mode == "Plot" then
    return Library.truncate(m.plot, 160)
  end

  -- Year, Runtime and Plot (default)
  local plot = Library.truncate(m.plot ~= "" and m.plot or m.tagline, 140)
  if plot ~= "" and head ~= "" then return head .. " — " .. plot end
  return head .. plot
end

local function movieActions(m)
  local actions = { "PlayMovie" }
  if m.resumePos > 0 then
    table.insert(actions, "ResumeMovie")
    table.insert(actions, "RestartMovie")
  end
  table.insert(actions, "ViewDetails")
  if m.playcount > 0 then
    table.insert(actions, "MarkUnwatched")
  else
    table.insert(actions, "MarkWatched")
  end
  return table.concat(actions, " ")
end

local function movieItem(m)
  local tapDetails = prop("Movie Tap Action", "Play Movie") == "Show Details"
  return {
    id = tostring(m.id),
    itemType = "movie",
    title = m.title,
    subtitle = movieSubtitle(m),
    duration = Library.formatRuntime(m.runtime),
    default_action = tapDetails and "ViewDetails" or "PlayMovie",
    actions_list = movieActions(m),
    images = artwork.imageList(m.poster or m.fanart, m.poster and "poster" or "fanart"),
  }
end

local function linkItem(id, title, subtitle, sampleMovie, icon)
  local images = {}
  if sampleMovie and (sampleMovie.poster or sampleMovie.fanart) then
    images = artwork.imageList(sampleMovie.poster or sampleMovie.fanart, sampleMovie.poster and "poster" or "fanart")
  elseif icon then
    images = iconImages(icon)
  end
  return {
    id = id,
    itemType = "link",
    title = title,
    subtitle = subtitle,
    isLink = "true",
    default_action = "SelectItem",
    images = images,
  }
end

local function headerItem(title)
  return { title = title, isHeader = "true" }
end

local function countLabel(n)
  return n == 1 and "1 movie" or (tostring(n) .. " movies")
end

local function statusItems()
  if not getPlayerDriverId() then
    return {
      headerItem("Not linked to a Kodi player"),
      { title = "In Composer, bind Kodi Movies 'Kodi Player' to the Kodi driver", itemType = "info" },
    }
  end
  if load.state == "loading" or load.state == "idle" then
    return { headerItem("Loading your Kodi movie library…") }
  end
  if load.state == "error" then
    return {
      headerItem("Couldn't load the Kodi library"),
      { id = "retry", itemType = "action", title = "Try again", subtitle = tostring(load.error or ""), default_action = "RetryLoad",
        images = iconImages("tab_more") },
    }
  end
  return nil
end

local function moviesToItems(movies, start, count)
  local items = {}
  start = math.max(0, tonumber(start) or 0)
  count = tonumber(count)
  local last = #movies
  if count and count > 0 then last = math.min(#movies, start + count) end
  for i = start + 1, last do
    table.insert(items, movieItem(movies[i]))
  end
  return items
end

-------------------------------------------------------------------------------
-- Screens
-------------------------------------------------------------------------------

local OFFSET_SCREENS = { MoviesScreen = true, BrowseScreen = true }

local TAB_SCREENS = {
  Movies = "MoviesScreen",
  Recent = "RecentScreen",
  Continue = "ContinueScreen",
  Genres = "GenresScreen",
  More = "MoreScreen",
}

local function moreLinks()
  local unwatched = library:unwatched()
  local sets = library:sets()
  local years = library:years()
  local top = library:topRated(100)
  return {
    linkItem("unwatched", "Unwatched", countLabel(#unwatched), unwatched[1], "tab_movies"),
    linkItem("sets", "Collections", (#sets == 1) and "1 collection" or (#sets .. " collections"), sets[1] and sets[1].sample, "tab_more"),
    linkItem("years", "By Year", (#years > 0) and (years[#years].year .. " – " .. years[1].year) or "", years[1] and years[1].sample, "tab_recent"),
    linkItem("toprated", "Top Rated", countLabel(#top), top[1], "tab_genres"),
    linkItem("random", "Surprise Me", "25 random picks you haven't seen", nil, "tab_continue"),
    linkItem("all", "All Movies", countLabel(library.count), nil, "tab_movies"),
  }
end

-- Resolve a BrowseScreen id to { movies = {...} } or { items = {...} }.
local function resolveBrowse(id)
  id = tostring(id or "")

  local genre = id:match("^genre:(.+)$")
  if genre then return { movies = library:byGenre(genre) } end

  local setId = id:match("^set:(%d+)$")
  if setId then return { movies = library:bySet(setId) } end

  local year = id:match("^year:(%d+)$")
  if year then return { movies = library:byYear(year) } end

  if id == "unwatched" then return { movies = library:unwatched() } end
  if id == "toprated" then return { movies = library:topRated(100) } end
  if id == "random" then return { movies = library:randomPicks(25, os.time()) } end
  if id == "all" then return { movies = library:all(prop("Default Sort", "Title"), false) } end

  if id == "sets" then
    local items = {}
    for _, s in ipairs(library:sets()) do
      table.insert(items, linkItem("set:" .. s.id, s.name, countLabel(s.count), s.sample))
    end
    return { items = items }
  end

  if id == "years" then
    local items = {}
    for _, y in ipairs(library:years()) do
      table.insert(items, linkItem("year:" .. y.year, tostring(y.year), countLabel(y.count), y.sample))
    end
    return { items = items }
  end

  if id == "genres" then
    local items = {}
    for _, g in ipairs(library:genres()) do
      table.insert(items, linkItem("genre:" .. g.name, g.name, countLabel(g.count), g.sample))
    end
    return { items = items }
  end

  return { movies = {} }
end

local function buildScreen(args)
  local screenId = args.screenId
  if (not screenId or screenId == "") and args.tabId then
    screenId = TAB_SCREENS[args.tabId]
  end
  screenId = screenId or "MoviesScreen"
  local paged = OFFSET_SCREENS[screenId]

  local status = statusItems()
  if status then
    return paged and listXml(status, #status) or listXml(status)
  end

  if screenId == "MoviesScreen" then
    local hideWatched = prop("Hide Watched Movies", "OFF") == "ON"
    local movies = library:all(prop("Default Sort", "Title"), hideWatched)
    if #movies == 0 then
      local items = { headerItem(hideWatched and "Everything has been watched" or "No movies in the Kodi library") }
      return listXml(items, #items)
    end
    return listXml(moviesToItems(movies, args.start, args.count), #movies)

  elseif screenId == "RecentScreen" then
    local movies = library:recent(tonumber(prop("Recently Added Count", "50")) or 50)
    if #movies == 0 then return listXml({ headerItem("Nothing added recently") }) end
    return listXml(moviesToItems(movies))

  elseif screenId == "ContinueScreen" then
    local movies = library:inProgress()
    if #movies == 0 then return listXml({ headerItem("No movies in progress") }) end
    return listXml(moviesToItems(movies))

  elseif screenId == "GenresScreen" then
    local r = resolveBrowse("genres")
    if #r.items == 0 then return listXml({ headerItem("No genres found") }) end
    return listXml(r.items)

  elseif screenId == "MoreScreen" then
    return listXml(moreLinks())

  elseif screenId == "BrowseScreen" then
    local r = resolveBrowse(args.id)
    if r.items then
      local items = r.items
      local start = math.max(0, tonumber(args.start) or 0)
      local count = tonumber(args.count)
      local slice = {}
      local last = #items
      if count and count > 0 then last = math.min(#items, start + count) end
      for i = start + 1, last do table.insert(slice, items[i]) end
      return listXml(slice, #items)
    end
    if #r.movies == 0 then
      local items = { headerItem("Nothing here") }
      return listXml(items, #items)
    end
    return listXml(moviesToItems(r.movies, args.start, args.count), #r.movies)
  end

  return listXml({ headerItem("Unknown screen " .. tostring(screenId)) })
end

local function buildDetails(id)
  local m = library:get(id)
  if not m then
    return "<Details><title>Movie not found</title><description>It may have been removed from the Kodi library.</description></Details>"
  end

  local useFanart = prop("Details Image", "Poster") == "Fanart"
  local imagePath = useFanart and (m.fanart or m.poster) or (m.poster or m.fanart)
  local image = artwork.url(imagePath, (imagePath == m.fanart) and "fanart" or "poster", "large") or ""

  local ratingBits = {}
  if m.rating > 0 then table.insert(ratingBits, string.format("★ %.1f", m.rating)) end
  if m.mpaa ~= "" then table.insert(ratingBits, (m.mpaa:gsub("^Rated%s+", ""))) end

  local subtitleBits = {}
  if #m.genres > 0 then table.insert(subtitleBits, table.concat(m.genres, ", ")) end
  if #m.directors > 0 then table.insert(subtitleBits, "Directed by " .. table.concat(m.directors, ", ")) end

  local description = {}
  if m.tagline ~= "" then table.insert(description, m.tagline) end
  if m.plot ~= "" then table.insert(description, m.plot) end
  if m.resumePos > 0 then
    table.insert(description, "Stopped at " .. Library.formatClock(m.resumePos) .. " of " .. Library.formatClock(m.resumeTotal) .. ".")
  elseif m.playcount > 0 then
    table.insert(description, "Watched.")
  end
  if m.set ~= "" then table.insert(description, "Part of " .. m.set .. ".") end

  local fields = {
    { "id", tostring(m.id) },
    { "itemType", "movie" },
    { "title", m.title },
    { "subtitle", table.concat(subtitleBits, " · ") },
    { "image", image },
    { "release_date", m.year > 0 and tostring(m.year) or "" },
    { "rating", table.concat(ratingBits, " · ") },
    { "duration", Library.formatRuntime(m.runtime) },
    { "description", table.concat(description, "\n\n") },
    { "attribution_image", iconUrl("device", 140) },
    { "default_action", "PlayMovie" },
    { "actions_list", movieActions(m) },
  }

  local parts = { "<Details>" }
  for _, f in ipairs(fields) do
    if f[2] ~= nil and f[2] ~= "" then
      table.insert(parts, "<" .. f[1] .. ">" .. xmlEscape(f[2]) .. "</" .. f[1] .. ">")
    end
  end
  table.insert(parts, "</Details>")
  return table.concat(parts)
end

-------------------------------------------------------------------------------
-- Playback
-------------------------------------------------------------------------------

local function resumeFlagFor(kind)
  if kind == "resume" then return "1" end
  if kind == "restart" then return "0" end
  local setting = prop("Resume Behavior", "Use Kodi Driver Setting")
  if setting == "Always Resume" then return "1" end
  if setting == "Always Start From Beginning" then return "0" end
  return ""  -- let the Kodi driver's Resume Behavior decide
end

local function startMovie(nav, id, kind)
  local movieId = tonumber(id)
  if not movieId then return "" end
  local m = library:get(movieId)
  local title = m and m.title or ("movie " .. movieId)

  if not getPlayerDriverId() then
    notifyUser(nav.navId, nil, "Kodi Movies", "This driver isn't linked to a Kodi player driver yet.")
    return ""
  end

  pendingPlays[movieId] = { navId = nav.navId, roomId = nav.roomId, title = title }

  logInfo("Play '" .. title .. "' (" .. movieId .. ") in room " .. tostring(nav.roomId))
  sendToPlayer("OSKODI_PLAY_MOVIE", {
    MOVIE_ID = tostring(movieId),
    ROOM_ID = tostring(nav.roomId or ""),
    RESUME = resumeFlagFor(kind),
    TITLE = title,
  })
  pcall(function() C4:FireEvent("Movie Selected") end)
  pcall(function() C4:SetVariable("LAST_MOVIE_SELECTED", title) end)
  return ""
end

local function setWatched(nav, seq, id, watched)
  local movieId = tonumber(id)
  if not movieId then return "" end
  local params = { movieid = movieId, playcount = watched and 1 or 0 }
  if not watched then params.resume = { position = 0, total = 0 } end
  http:call("VideoLibrary.SetMovieDetails", params, function(_, err)
    if err then
      logInfo("SetMovieDetails failed: " .. tostring(err))
      dataReceived(nav.navId, seq, "")
      return
    end
    local m = library:get(movieId)
    if m then
      m.playcount = watched and 1 or 0
      if not watched then m.resumePos = 0 end
      library._cache = {}
    end
    refreshMovie(movieId)
    dataReceived(nav.navId, seq, "<RefreshScreen>true</RefreshScreen>")
  end)
  return nil -- answered asynchronously
end

-------------------------------------------------------------------------------
-- Navigator sessions
-------------------------------------------------------------------------------

Navigator = Navigator or {}
Navigator.__index = Navigator

function Navigator.new(navId)
  return setmetatable({ navId = navId, roomId = 0 }, Navigator)
end

function Navigator:Browse(seq, args)
  local navId = self.navId
  whenLoaded(function()
    local ok, data = pcall(buildScreen, args)
    if ok then
      dataReceived(navId, seq, data)
    else
      logInfo("Browse error: " .. tostring(data))
      dataReceivedError(navId, seq, tostring(data))
    end
  end)
  return nil
end

function Navigator:GetDetails(seq, args)
  local navId = self.navId
  whenLoaded(function()
    local ok, data = pcall(buildDetails, args.id)
    if ok then
      dataReceived(navId, seq, data)
    else
      dataReceivedError(navId, seq, tostring(data))
    end
  end)
  return nil
end

function Navigator:SelectItem(seq, args)
  if args.itemType == "link" then
    return "<NextScreen>BrowseScreen</NextScreen>"
  elseif args.itemType == "movie" then
    if prop("Movie Tap Action", "Play Movie") == "Show Details" then
      return "<NextScreen>DetailsScreen</NextScreen>"
    end
    return startMovie(self, args.id, "default")
  elseif args.id == "retry" then
    return self:RetryLoad(seq, args)
  end
  return ""
end

function Navigator:PlayMovie(seq, args) return startMovie(self, args.id, "default") end
function Navigator:ResumeMovie(seq, args) return startMovie(self, args.id, "resume") end
function Navigator:RestartMovie(seq, args) return startMovie(self, args.id, "restart") end
function Navigator:ViewDetails(seq, args) return "<NextScreen>DetailsScreen</NextScreen>" end
function Navigator:MarkWatched(seq, args) return setWatched(self, seq, args.id, true) end
function Navigator:MarkUnwatched(seq, args) return setWatched(self, seq, args.id, false) end

function Navigator:RetryLoad(seq, args)
  local navId = self.navId
  load.lastFailure = 0
  if load.state ~= "loading" then
    load.state = "idle"
  end
  whenLoaded(function()
    dataReceived(navId, seq, "<RefreshScreen>true</RefreshScreen>")
  end)
  return nil
end

-- Dashboard / transport from a navigator session: forward to Kodi.
local TRANSPORT = { PLAY = true, PAUSE = true, STOP = true, SKIP_FWD = true, SKIP_REV = true, SCAN_FWD = true, SCAN_REV = true }
for cmd, _ in pairs(TRANSPORT) do
  Navigator[cmd] = function(self, seq, args)
    sendToPlayer("OSKODI_TRANSPORT", { CMD = cmd })
    return ""
  end
end

-------------------------------------------------------------------------------
-- Control4 entry points
-------------------------------------------------------------------------------

local function parseArgs(argsXml)
  local args = {}
  if type(argsXml) ~= "string" or argsXml == "" then return args end
  local ok, parsed = pcall(function() return C4:ParseXml(argsXml) end)
  if ok and type(parsed) == "table" and type(parsed.ChildNodes) == "table" then
    for _, v in pairs(parsed.ChildNodes) do
      if type(v) == "table" and v.Attributes and v.Attributes.name then
        args[v.Attributes.name] = v.Value
      end
    end
  end
  return args
end

local unhandledLogged = {}

function ReceivedFromProxy(idBinding, strCommand, tParams)
  strCommand = strCommand or ""
  tParams = tParams or {}

  if idBinding ~= MSP_PROXY then return end

  local args = parseArgs(tParams.ARGS)
  tParams.ARGS = nil

  if prop("Debug Mode", "OFF") == "ON" then
    local out = { "RFP " .. strCommand }
    for k, v in pairs(tParams) do table.insert(out, "  " .. tostring(k) .. "=" .. tostring(v)) end
    for k, v in pairs(args) do table.insert(out, "  args." .. tostring(k) .. "=" .. tostring(v)) end
    logDebug(table.concat(out, "\n"))
  end

  local navId = tParams.NAVID

  if strCommand == "DESTROY_NAV" or strCommand == "DESTROY_NAVIGATOR" then
    if navId then Navigators[navId] = nil end
    return
  end

  if not navId then
    -- Room buttons (no navigator session) arrive here when this service is
    -- the room's selected device; hand them to Kodi.
    local cmd = strCommand:gsub("^END_", "")
    if TRANSPORT[strCommand] then
      sendToPlayer("OSKODI_TRANSPORT", { CMD = strCommand })
    elseif TRANSPORT[cmd] then
      -- release of a held key; nothing to do
    elseif not unhandledLogged[strCommand] then
      unhandledLogged[strCommand] = true
      logDebug("Ignoring room command " .. strCommand)
    end
    return
  end

  local nav = Navigators[navId]
  if not nav then
    nav = Navigator.new(navId)
    Navigators[navId] = nav
  end
  nav.roomId = tonumber(tParams.ROOMID) or tonumber(tParams.ROOM_ID) or nav.roomId
  local seq = tParams.SEQ

  local handler = Navigator[strCommand]
  if type(handler) ~= "function" or strCommand == "new" then
    if not unhandledLogged[strCommand] then
      unhandledLogged[strCommand] = true
      logInfo("Unhandled navigator command: " .. strCommand)
    end
    dataReceived(navId, seq, "")
    return
  end

  local ok, ret = pcall(handler, nav, seq, args)
  if not ok then
    logInfo("Navigator command " .. strCommand .. " failed: " .. tostring(ret))
    dataReceivedError(navId, seq, tostring(ret))
  elseif ret ~= nil then
    dataReceived(navId, seq, ret)
  end
end

local function onPlayResult(params)
  local movieId = tonumber(params.MOVIE_ID)
  local pending = movieId and pendingPlays[movieId]
  if movieId then pendingPlays[movieId] = nil end
  if params.OK == "1" then
    logDebug("Kodi started movie " .. tostring(movieId))
    return
  end
  local title = pending and pending.title or ("movie " .. tostring(movieId))
  logInfo("Kodi could not start " .. title .. ": " .. tostring(params.ERROR))
  notifyUser(pending and pending.navId, nil, "Kodi Movies",
    "Couldn't start " .. title .. " (" .. tostring(params.ERROR or "unknown error") .. ").")
end

local function onLibraryChanged(params)
  local kind = params.KIND
  local movieId = tonumber(params.MOVIE_ID)
  if kind == "update" and movieId then
    refreshMovie(movieId)
  elseif kind == "remove" and movieId then
    if library:remove(movieId) then updateProperty("Movie Count", library.count) end
  else
    scheduleReload(RELOAD_DEBOUNCE_MS, "Kodi library changed")
  end
end

local ACTIONS = {
  RefreshLibrary = function()
    load.lastFailure = 0
    if load.state == "loading" then return end
    loadLibrary("manual refresh")
  end,
  Relink = function()
    link.config = nil
    startRegisterLoop()
  end,
}

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "LUA_ACTION" and tParams.ACTION then
    strCommand = tParams.ACTION
  end

  if strCommand == "OSKODI_CONFIG" then
    applyConfig(tParams)
  elseif strCommand == "OSKODI_LIBRARY_CHANGED" then
    onLibraryChanged(tParams)
  elseif strCommand == "OSKODI_PLAY_RESULT" then
    onPlayResult(tParams)
  elseif ACTIONS[strCommand] then
    ACTIONS[strCommand](tParams)
  elseif strCommand == "Refresh Library" then
    ACTIONS.RefreshLibrary(tParams)
  else
    logDebug("Unhandled ExecuteCommand " .. tostring(strCommand))
  end
end

function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
  if idBinding ~= LINK_BINDING_ID then return end
  logInfo("Kodi player link " .. (bIsBound and "bound" or "unbound"))
  if bIsBound then
    startRegisterLoop()
  else
    link.config = nil
    http:configure({})
    updateLinkProperty()
  end
end

function OnPropertyChanged(strProperty)
  if strProperty == "Artwork Source" or strProperty == "Send Kodi Login With Artwork" then
    artwork.configure(artworkOptions(link.config))
  elseif strProperty == "Auto Refresh (minutes)" then
    startAutoRefresh()
  end
end

function OnDriverInit()
  pcall(function() C4:urlSetTimeout(30) end)
end

function OnDriverLateInit()
  updateProperty("Driver Version", DRIVER_VERSION)
  updateProperty("Movie Count", 0)
  setLibraryStatus("Waiting for the Kodi driver")
  pcall(function() C4:AddVariable("LAST_MOVIE_SELECTED", "", "STRING", true, false) end)
  artwork.configure(artworkOptions(nil))
  startRegisterLoop()
  startAutoRefresh()
end

function OnDriverDestroyed()
  link.registerTimer = cancelTimer(link.registerTimer)
  load.retryTimer = cancelTimer(load.retryTimer)
  load.reloadTimer = cancelTimer(load.reloadTimer)
  load.refreshTimer = cancelTimer(load.refreshTimer)
  for _, w in ipairs(load.waiters) do w.timer = cancelTimer(w.timer) end
  load.waiters = {}
end

-- Exposed for the off-controller test harness.
KodiMovies = {
  library = library,
  artwork = artwork,
  load = load,
  link = link,
  buildScreen = buildScreen,
  buildDetails = buildDetails,
}
