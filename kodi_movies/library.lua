-- In-memory Kodi movie library: normalisation, indexes and queries.
-- Pure Lua (no Control4 API) so it can be unit tested off-controller.

local Library = {}
Library.__index = Library

local ARTICLES = { "the ", "a ", "an " }

local function stripBBCode(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("%[/?[BIUbiu]%]", "")
  s = s:gsub("%[/?COLOR[^%]]*%]", "")
  s = s:gsub("%[/?CR%]", " ")
  s = s:gsub("%[/?LIGHT%]", "")
  s = s:gsub("%[/?UPPERCASE%]", "")
  s = s:gsub("%[/?LOWERCASE%]", "")
  s = s:gsub("%[/?CAPITALIZE%]", "")
  return s
end
Library.stripBBCode = stripBBCode

local function sortKey(title)
  local s = string.lower(title or "")
  s = s:gsub("^%s+", "")
  for _, a in ipairs(ARTICLES) do
    if s:sub(1, #a) == a then
      s = s:sub(#a + 1)
      break
    end
  end
  return s
end
Library.sortKey = sortKey

local function asNumber(v, default)
  local n = tonumber(v)
  if n == nil then return default end
  return n
end

local function asList(v)
  if type(v) == "table" then
    local out = {}
    for _, x in ipairs(v) do
      if type(x) == "string" and x ~= "" then table.insert(out, x) end
    end
    return out
  elseif type(v) == "string" and v ~= "" then
    return { v }
  end
  return {}
end

-- Convert one VideoLibrary.GetMovies / GetMovieDetails record.
function Library.normalize(raw)
  if type(raw) ~= "table" then return nil end
  local id = asNumber(raw.movieid, nil)
  if not id then return nil end

  local art = type(raw.art) == "table" and raw.art or {}
  local resume = type(raw.resume) == "table" and raw.resume or {}
  local title = raw.title
  if type(title) ~= "string" or title == "" then title = raw.label end
  if type(title) ~= "string" or title == "" then title = "Movie " .. id end

  local sorttitle = raw.sorttitle
  if type(sorttitle) ~= "string" or sorttitle == "" then sorttitle = title end

  local plot = stripBBCode(raw.plot)
  if plot == "" then plot = stripBBCode(raw.plotoutline) end

  local set = raw.set
  if type(set) ~= "string" then set = "" end

  return {
    id = id,
    title = title,
    sortKey = sortKey(sorttitle),
    year = asNumber(raw.year, 0),
    runtime = asNumber(raw.runtime, 0),         -- seconds
    genres = asList(raw.genre),
    directors = asList(raw.director),
    plot = plot,
    tagline = stripBBCode(raw.tagline),
    poster = (type(art.poster) == "string" and art.poster ~= "" and art.poster)
      or (type(raw.thumbnail) == "string" and raw.thumbnail ~= "" and raw.thumbnail) or nil,
    fanart = (type(art.fanart) == "string" and art.fanart ~= "" and art.fanart)
      or (type(raw.fanart) == "string" and raw.fanart ~= "" and raw.fanart) or nil,
    rating = asNumber(raw.rating, 0),
    mpaa = type(raw.mpaa) == "string" and raw.mpaa or "",
    playcount = asNumber(raw.playcount, 0),
    resumePos = asNumber(resume.position, 0),
    resumeTotal = asNumber(resume.total, 0),
    dateadded = type(raw.dateadded) == "string" and raw.dateadded or "",
    lastplayed = type(raw.lastplayed) == "string" and raw.lastplayed or "",
    setid = asNumber(raw.setid, 0),
    set = set,
  }
end

-- Properties requested from Kodi for every movie.
Library.PROPERTIES = {
  "title", "sorttitle", "year", "runtime", "genre", "director", "plot", "plotoutline",
  "tagline", "art", "thumbnail", "rating", "mpaa", "playcount", "resume",
  "dateadded", "lastplayed", "setid", "set",
}

function Library.new()
  local self = setmetatable({}, Library)
  self:clear()
  return self
end

function Library:clear()
  self.byId = {}
  self.list = {}       -- sorted by title
  self.count = 0
  self.loadedAt = nil
  self.version = 0
  self._cache = {}
end

function Library:setMovies(rawMovies)
  self.byId = {}
  self.list = {}
  for _, raw in ipairs(rawMovies or {}) do
    local m = Library.normalize(raw)
    if m and not self.byId[m.id] then
      self.byId[m.id] = m
      table.insert(self.list, m)
    end
  end
  self:_reindex()
end

function Library:_reindex()
  table.sort(self.list, function(a, b)
    if a.sortKey == b.sortKey then
      if a.year == b.year then return a.id < b.id end
      return a.year < b.year
    end
    return a.sortKey < b.sortKey
  end)
  self.count = #self.list
  self.version = self.version + 1
  self._cache = {}
end

function Library:upsert(raw)
  local m = Library.normalize(raw)
  if not m then return false end
  local existing = self.byId[m.id]
  if existing then
    for i, x in ipairs(self.list) do
      if x.id == m.id then
        self.list[i] = m
        break
      end
    end
  else
    table.insert(self.list, m)
  end
  self.byId[m.id] = m
  self:_reindex()
  return true
end

function Library:remove(id)
  id = tonumber(id)
  if not id or not self.byId[id] then return false end
  self.byId[id] = nil
  for i, x in ipairs(self.list) do
    if x.id == id then
      table.remove(self.list, i)
      break
    end
  end
  self:_reindex()
  return true
end

function Library:get(id)
  return self.byId[tonumber(id) or -1]
end

---------------------------------------------------------------------------
-- Queries. Each returns a fresh array of movie records (do not mutate).
---------------------------------------------------------------------------

local function copy(list)
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  return out
end

local function filter(list, pred)
  local out = {}
  for _, v in ipairs(list) do
    if pred(v) then table.insert(out, v) end
  end
  return out
end

local SORTERS = {
  ["Title"] = nil, -- list is already title-sorted
  ["Year (Newest First)"] = function(a, b)
    if a.year == b.year then return a.sortKey < b.sortKey end
    return a.year > b.year
  end,
  ["Date Added (Newest First)"] = function(a, b)
    if a.dateadded == b.dateadded then return a.sortKey < b.sortKey end
    return a.dateadded > b.dateadded
  end,
  ["Rating"] = function(a, b)
    if a.rating == b.rating then return a.sortKey < b.sortKey end
    return a.rating > b.rating
  end,
}
Library.SORT_MODES = { "Title", "Year (Newest First)", "Date Added (Newest First)", "Rating" }

function Library:all(sortMode, hideWatched)
  local key = "all|" .. tostring(sortMode) .. "|" .. tostring(hideWatched)
  if self._cache[key] then return self._cache[key] end

  local out = hideWatched and filter(self.list, function(m) return m.playcount == 0 end) or copy(self.list)
  local sorter = SORTERS[sortMode or "Title"]
  if sorter then table.sort(out, sorter) end
  self._cache[key] = out
  return out
end

function Library:recent(limit)
  local out = copy(self.list)
  table.sort(out, SORTERS["Date Added (Newest First)"])
  limit = tonumber(limit) or 50
  while #out > limit do table.remove(out) end
  return out
end

function Library:inProgress()
  local out = filter(self.list, function(m) return m.resumePos > 0 end)
  table.sort(out, function(a, b)
    if a.lastplayed == b.lastplayed then return a.sortKey < b.sortKey end
    return a.lastplayed > b.lastplayed
  end)
  return out
end

function Library:unwatched()
  return filter(self.list, function(m) return m.playcount == 0 end)
end

function Library:topRated(limit)
  local out = filter(self.list, function(m) return m.rating > 0 end)
  table.sort(out, SORTERS["Rating"])
  limit = tonumber(limit) or 100
  while #out > limit do table.remove(out) end
  return out
end

-- A stable-per-call random selection of unwatched movies (falls back to all).
function Library:randomPicks(count, seed)
  local pool = self:unwatched()
  if #pool == 0 then pool = copy(self.list) end
  if seed then math.randomseed(seed) end
  for i = #pool, 2, -1 do
    local j = math.random(i)
    pool[i], pool[j] = pool[j], pool[i]
  end
  count = tonumber(count) or 25
  while #pool > count do table.remove(pool) end
  return pool
end

function Library:genres()
  if self._cache.genres then return self._cache.genres end
  local map, out = {}, {}
  for _, m in ipairs(self.list) do
    for _, g in ipairs(m.genres) do
      local e = map[g]
      if not e then
        e = { name = g, count = 0, sample = m }
        map[g] = e
        table.insert(out, e)
      end
      e.count = e.count + 1
      -- Prefer a well-rated movie with artwork as the row image.
      if m.poster and ((not e.sample.poster) or m.rating > e.sample.rating) then
        e.sample = m
      end
    end
  end
  table.sort(out, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
  self._cache.genres = out
  return out
end

function Library:byGenre(name)
  return filter(self.list, function(m)
    for _, g in ipairs(m.genres) do
      if g == name then return true end
    end
    return false
  end)
end

function Library:sets()
  if self._cache.sets then return self._cache.sets end
  local map, out = {}, {}
  for _, m in ipairs(self.list) do
    if m.setid > 0 then
      local e = map[m.setid]
      if not e then
        e = { id = m.setid, name = (m.set ~= "" and m.set) or ("Collection " .. m.setid), count = 0, sample = m }
        map[m.setid] = e
        table.insert(out, e)
      end
      e.count = e.count + 1
      if m.poster and (not e.sample.poster or (m.year > 0 and m.year < e.sample.year)) then
        e.sample = m
      end
    end
  end
  table.sort(out, function(a, b) return sortKey(a.name) < sortKey(b.name) end)
  self._cache.sets = out
  return out
end

function Library:bySet(setId)
  setId = tonumber(setId)
  local out = filter(self.list, function(m) return m.setid == setId end)
  table.sort(out, function(a, b)
    if a.year == b.year then return a.sortKey < b.sortKey end
    return a.year < b.year
  end)
  return out
end

function Library:years()
  if self._cache.years then return self._cache.years end
  local map, out = {}, {}
  for _, m in ipairs(self.list) do
    if m.year > 0 then
      local e = map[m.year]
      if not e then
        e = { year = m.year, count = 0, sample = m }
        map[m.year] = e
        table.insert(out, e)
      end
      e.count = e.count + 1
      if m.poster and (not e.sample.poster or m.rating > e.sample.rating) then
        e.sample = m
      end
    end
  end
  table.sort(out, function(a, b) return a.year > b.year end)
  self._cache.years = out
  return out
end

function Library:byYear(year)
  year = tonumber(year)
  return filter(self.list, function(m) return m.year == year end)
end

---------------------------------------------------------------------------
-- Presentation helpers
---------------------------------------------------------------------------

function Library.formatRuntime(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then return "" end
  local minutes = math.floor(seconds / 60 + 0.5)
  local h = math.floor(minutes / 60)
  local m = minutes % 60
  if h > 0 and m > 0 then return h .. "h " .. m .. "m" end
  if h > 0 then return h .. "h" end
  return m .. "m"
end

function Library.formatClock(seconds)
  seconds = math.floor(tonumber(seconds) or 0)
  if seconds <= 0 then return "" end
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- Truncate on a UTF-8 boundary and a word boundary where possible.
function Library.truncate(s, maxBytes)
  s = s or ""
  if #s <= maxBytes then return s end
  local cut = maxBytes
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1
  end
  local out = s:sub(1, cut)
  local lastSpace = out:match(".*()%s")
  if lastSpace and lastSpace > maxBytes * 0.6 then
    out = out:sub(1, lastSpace - 1)
  end
  out = out:gsub("[%s%p]+$", "")
  return out .. "…"
end

return Library
