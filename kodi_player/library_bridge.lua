-- Library bridge: the main Kodi driver's side of the link to Kodi Movies.
--
-- Kodi Movies binds to this driver through a type-1 control connection
-- (binding LINK_BINDING_ID, class OSKODI_PLAYER_LINK). Messages travel with
-- C4:SendToDevice and arrive in each driver's ExecuteCommand:
--
--   Movies -> Player
--     OSKODI_REGISTER        { DEVICE_ID }              ask for connection config
--     OSKODI_PLAY_MOVIE      { MOVIE_ID, ROOM_ID, RESUME = "1"|"0"|"", TITLE }
--     OSKODI_TRANSPORT       { CMD = "PLAY"|"PAUSE"|"STOP"|... }
--
--   Player -> Movies
--     OSKODI_CONFIG          { HOST, HTTP_PORT, USERNAME, PASSWORD, WS_CONNECTED,
--                              PLAYER_DEVICE_ID, PLAYER_NAME }
--     OSKODI_LIBRARY_CHANGED { KIND = "update"|"remove"|"scan", MOVIE_ID }
--     OSKODI_PLAY_RESULT     { MOVIE_ID, OK = "1"|"0", ERROR }
--
-- Playing a movie: select Kodi as the room's video source (which powers the
-- room's TV/AVR chain through the normal Control4 path), wait for the AV chain
-- to settle and for Kodi's WebSocket to be up, then Player.Open the movie.

local Bridge = {}

Bridge.LINK_BINDING_ID = 3900

local LAUNCH_GUARD_SECONDS = 120     -- how long ON is suppressed after a launch starts
local OPEN_RETRY_MS = 2500
local CONNECT_POLL_MS = 2000
local MAX_OPEN_ATTEMPTS = 3

local function now()
  return os.time()
end

function Bridge.create(ctx)
  local state = assert(ctx.state, "state is required")
  local kodiRpc = assert(ctx.kodiRpc, "kodiRpc is required")
  local setTimer = assert(ctx.setTimer, "setTimer is required")
  local cancelTimer = assert(ctx.cancelTimer, "cancelTimer is required")
  local getPlayerProxyId = assert(ctx.getPlayerProxyId, "getPlayerProxyId is required")
  local ensureConnected = assert(ctx.ensureConnected, "ensureConnected is required")
  local updateProperty = ctx.updateProperty or function(_, _) end
  local fireEvent = ctx.fireEvent or function(_) end
  local getCommandHandlers = ctx.getCommandHandlers or function() return {} end
  local logInfo = ctx.logInfo or function(_) end
  local logDebug = ctx.logDebug or function(_) end

  local self = {
    pending = nil,     -- { movieId, roomId, resume, title, startedAt, deadline, attempts, opened }
    timerId = nil,
  }

  local function prop(name, default)
    if Properties and Properties[name] ~= nil and Properties[name] ~= "" then
      return Properties[name]
    end
    return default
  end

  ---------------------------------------------------------------------------
  -- Linked devices
  ---------------------------------------------------------------------------

  function self.linkedDevices()
    local ids = {}
    local ok, devices = pcall(function()
      return C4:GetBoundConsumerDevices(C4:GetDeviceID(), Bridge.LINK_BINDING_ID)
    end)
    if ok and type(devices) == "table" then
      for id, _ in pairs(devices) do
        local n = tonumber(id)
        if n then table.insert(ids, n) end
      end
    end
    table.sort(ids)
    return ids
  end

  local function sendTo(deviceId, command, params)
    local ok, err = pcall(function() C4:SendToDevice(deviceId, command, params or {}) end)
    if not ok then
      logInfo("SendToDevice " .. tostring(command) .. " -> " .. tostring(deviceId) .. " failed: " .. tostring(err))
    end
  end

  local function broadcast(command, params)
    for _, id in ipairs(self.linkedDevices()) do
      sendTo(id, command, params)
    end
  end

  function self.updateLinkStatus()
    local ids = self.linkedDevices()
    if #ids == 0 then
      updateProperty("Library Link", "Not linked (bind a Kodi Movies driver)")
    else
      local names = {}
      for _, id in ipairs(ids) do
        local ok, name = pcall(function() return C4:GetDeviceDisplayName(id) end)
        table.insert(names, (ok and name and name ~= "") and name or ("device " .. id))
      end
      updateProperty("Library Link", "Linked: " .. table.concat(names, ", "))
    end
  end

  ---------------------------------------------------------------------------
  -- Config push
  ---------------------------------------------------------------------------

  local function configParams()
    local playerName = ""
    local proxyId = getPlayerProxyId()
    if proxyId then
      local ok, name = pcall(function() return C4:GetDeviceDisplayName(proxyId) end)
      if ok and name then playerName = name end
    end

    return {
      HOST = prop("IP Address", ""),
      HTTP_PORT = tostring(prop("Kodi HTTP Port", "8080")),
      USERNAME = prop("Kodi Username", ""),
      PASSWORD = prop("Kodi Password", ""),
      WS_CONNECTED = state.wsConnected and "1" or "0",
      PLAYER_DEVICE_ID = tostring(proxyId or ""),
      PLAYER_NAME = playerName,
    }
  end

  function self.pushConfig(deviceId)
    local params = configParams()
    if deviceId then
      sendTo(deviceId, "OSKODI_CONFIG", params)
    else
      broadcast("OSKODI_CONFIG", params)
    end
  end

  function self.libraryChanged(kind, movieId)
    logDebug("Library changed: " .. tostring(kind) .. " " .. tostring(movieId or ""))
    broadcast("OSKODI_LIBRARY_CHANGED", { KIND = kind, MOVIE_ID = movieId and tostring(movieId) or "" })
  end

  ---------------------------------------------------------------------------
  -- Launching a movie
  ---------------------------------------------------------------------------

  function self.isLaunchPending()
    local p = self.pending
    return p ~= nil and (now() - p.startedAt) < LAUNCH_GUARD_SECONDS
  end

  local function clearPending(reason)
    if self.pending then
      logDebug("Library launch cleared (" .. tostring(reason) .. ")")
    end
    self.pending = nil
    self.timerId = cancelTimer(self.timerId)
  end

  local function reportResult(p, ok, err)
    broadcast("OSKODI_PLAY_RESULT", {
      MOVIE_ID = tostring(p.movieId),
      OK = ok and "1" or "0",
      ERROR = err and tostring(err) or "",
    })
  end

  local function schedule(ms, fn)
    self.timerId = cancelTimer(self.timerId)
    self.timerId = setTimer(ms, function()
      self.timerId = nil
      fn()
    end)
  end

  local attemptOpen

  attemptOpen = function()
    local p = self.pending
    if not p or p.opened then return end

    if now() > p.deadline then
      logInfo("Gave up starting movie " .. tostring(p.movieId) .. ": Kodi did not become reachable in time")
      reportResult(p, false, "Kodi not reachable")
      clearPending("timeout")
      return
    end

    if not state.wsConnected then
      ensureConnected()
      schedule(CONNECT_POLL_MS, attemptOpen)
      return
    end

    p.attempts = p.attempts + 1
    logInfo("Opening movie " .. tostring(p.movieId) .. (p.title ~= "" and (" (" .. p.title .. ")") or "")
      .. (p.resume and " [resume]" or " [from start]") .. ", attempt " .. p.attempts)

    local sent = kodiRpc:sendRequest("Player.Open", {
      item = { movieid = p.movieId },
      options = { resume = p.resume },
    }, function(_, err)
      if self.pending ~= p then return end
      if err then
        logInfo("Player.Open failed: " .. (type(err) == "table" and tostring(err.message) or tostring(err)))
        if p.attempts < MAX_OPEN_ATTEMPTS then
          schedule(OPEN_RETRY_MS, attemptOpen)
        else
          reportResult(p, false, "Player.Open failed")
          clearPending("open_failed")
        end
        return
      end

      p.opened = true
      reportResult(p, true, nil)
      fireEvent("Library Movie Launched")
      -- Keep the ON guard for a little longer: some TVs/AVRs report ON late.
      schedule(30000, function() clearPending("guard_expired") end)
    end)

    if not sent and self.pending == p and p.attempts < MAX_OPEN_ATTEMPTS then
      schedule(OPEN_RETRY_MS, attemptOpen)
    end
  end

  local function selectKodiInRoom(roomId)
    local proxyId = getPlayerProxyId()
    if not proxyId then
      logInfo("Cannot select Kodi in room " .. tostring(roomId) .. ": media player proxy id unknown")
      return false
    end
    logInfo("Selecting Kodi (" .. proxyId .. ") as the video source in room " .. tostring(roomId))
    local ok, err = pcall(function()
      C4:SendToDevice(roomId, "SELECT_VIDEO_DEVICE", { deviceid = proxyId })
    end)
    if not ok then
      logInfo("SELECT_VIDEO_DEVICE failed: " .. tostring(err))
    end
    return ok
  end

  function self.playMovie(params)
    local movieId = tonumber(params.MOVIE_ID)
    if not movieId then
      logInfo("OSKODI_PLAY_MOVIE without a valid MOVIE_ID")
      return
    end

    local roomId = tonumber(params.ROOM_ID)
    local resume
    if params.RESUME == "1" then
      resume = true
    elseif params.RESUME == "0" then
      resume = false
    else
      resume = prop("Resume Behavior", "Resume Where Left Off") ~= "Start From Beginning"
    end

    local alreadyRunning = state.deviceOn and state.wsConnected
    local timeoutSeconds = tonumber(prop("Library Play Timeout (seconds)", "90")) or 90

    clearPending("superseded")
    self.pending = {
      movieId = movieId,
      roomId = roomId,
      resume = resume,
      title = params.TITLE or "",
      startedAt = now(),
      deadline = now() + timeoutSeconds,
      attempts = 0,
      opened = false,
    }

    local delayMs = 300
    if roomId and roomId > 0 and prop("Turn Room On When Playing From Library", "ON") == "ON" then
      selectKodiInRoom(roomId)
      if not alreadyRunning then
        delayMs = (tonumber(prop("Play Delay After Room On (seconds)", "4")) or 4) * 1000
      end
    end

    if not state.wsConnected then
      ensureConnected()
    end

    logDebug("Library launch scheduled in " .. delayMs .. " ms")
    schedule(math.max(delayMs, 100), attemptOpen)
  end

  function self.clear()
    clearPending("driver")
  end

  ---------------------------------------------------------------------------
  -- Command dispatch (from ExecuteCommand)
  ---------------------------------------------------------------------------

  function self.handleCommand(command, params)
    params = params or {}

    if command == "OSKODI_REGISTER" then
      local deviceId = tonumber(params.DEVICE_ID)
      logDebug("Kodi Movies registered: " .. tostring(deviceId))
      self.updateLinkStatus()
      self.pushConfig(deviceId)
      return true

    elseif command == "OSKODI_PLAY_MOVIE" then
      self.playMovie(params)
      return true

    elseif command == "OSKODI_TRANSPORT" then
      local handlers = getCommandHandlers()
      local cmd = params.CMD
      if cmd and handlers[cmd] then
        handlers[cmd](params)
      else
        logDebug("Unhandled transport from Kodi Movies: " .. tostring(cmd))
      end
      return true
    end

    return false
  end

  return self
end

return Bridge
