-- Kodi (Open Source) - main player driver
--
-- media_player proxy (5001) for room control, plus a hidden virtual switcher
-- (5002) that owns the HDMI output so the linked Kodi Movies media service can
-- reach the room through the same physical connection.
--
-- WebSocket control core derived from the MIT-licensed Kodi-Control4-Driver by
-- bmrowe (https://github.com/bmrowe/Kodi-Control4-Driver).

local C4Utils = require("c4_utils")
local KodiRpc = require("kodi_rpc")
local AvDetails = require("av_details")
local Notifications = require("notifications")
local Commands = require("commands")
local Bridge = require("library_bridge")
local WebSocket = require("drivers-common-public.module.websocket")

DRIVER_VERSION = "1.0.0"

local MEDIA_PLAYER_BINDING_ID = 5001
local SWITCH_BINDING_ID = 5002
local KODI_WEBSOCKET_PORT = 9090
local DEFAULT_SKIP_INTERVAL_SECONDS = 30

-- The websocket library pings on an interval and fails the connection if no
-- pong arrives within pong_response_interval. Keep PONG < PING (see reference).
local WEBSOCKET_PING_INTERVAL_SECONDS = 5
local WEBSOCKET_PONG_TIMEOUT_SECONDS = 3

-- websocket.lua's Close() releases the net binding on a 3s timer; every
-- reconnect must outlast it.
local WEBSOCKET_TEARDOWN_MS = 3000
local RECONNECT_DELAY_MS = 5000

local JSONRPC_CALLBACK_TIMEOUT_MS = 10000
local AV_DETAILS_DEBOUNCE_MS = 500
local SWITCH_HIDE_INTERVAL_MS = 15 * 60 * 1000

assert(RECONNECT_DELAY_MS > WEBSOCKET_TEARDOWN_MS, "reconnect must outlast socket teardown")
assert(WEBSOCKET_PONG_TIMEOUT_SECONDS < WEBSOCKET_PING_INTERVAL_SECONDS, "pong timeout must be shorter than ping interval")

local logger = C4Utils.createLogger("Kodi: ")
local logInfo = logger.info
local logDebug = logger.debug

local updateProperty = C4Utils.updateProperty
local cancelTimer = C4Utils.cancelTimer

local state = {
  webSocket = nil,
  directionalsMode = "PM4K", -- "PM4K" or "Kodi"
  isShuttingDown = false,
  wsConnecting = false,
  wsConnected = false,
  reconnectTimerId = nil,
  playbackType = nil, -- "video" | "audio" | nil
  playerId = nil,     -- Kodi playerid of the active player, or nil
  deviceOn = false,   -- media_player proxy ON/OFF as reported by the room
  nowPlayingTitle = nil,
  switchHideTimer = nil,
  playerProxyId = nil,
}

-- Forward declarations
local connectKodiWebSocket
local kodiRpc
local commandHandlers
local bridge

local function setTimer(ms, callback)
  return C4:SetTimer(ms, callback)
end

local function fireEvent(name)
  pcall(function() C4:FireEvent(name) end)
end

local function isAutoRoomOnEnabled()
  return Properties and Properties["Auto Room On"] == "ON"
end

local function isAutoRoomOffEnabled()
  return Properties and Properties["Auto Room Off"] == "ON"
end

local function loadDirectionalsModeFromProperties()
  if not Properties then return end
  state.directionalsMode = (Properties["Playback Directionals"] == "Kodi") and "Kodi" or "PM4K"
  logDebug("Playback Directionals mode set to: " .. state.directionalsMode)
end

local function shouldUseKodiPlaybackDirectionals()
  return state.playbackType == "video" and state.directionalsMode == "Kodi"
end

local function getSkipIntervalSeconds()
  if not Properties then return DEFAULT_SKIP_INTERVAL_SECONDS end
  return tonumber(Properties["Skip Interval (seconds)"]) or DEFAULT_SKIP_INTERVAL_SECONDS
end

-- The proxy device id of a proxy binding. Multi-proxy drivers report each
-- proxy as a bound consumer of its own binding id.
local function getProxyDeviceId(bindingId)
  local ok, devices = pcall(function()
    return C4:GetBoundConsumerDevices(C4:GetDeviceID(), bindingId)
  end)
  if ok and type(devices) == "table" then
    for id, _ in pairs(devices) do
      local n = tonumber(id)
      if n then return n end
    end
  end
  return nil
end

local function getPlayerProxyId()
  if state.playerProxyId then return state.playerProxyId end

  local id = getProxyDeviceId(MEDIA_PLAYER_BINDING_ID)
  if not id then
    -- Fallback: the first proxy listed is the media player (declared first).
    local ok, proxies = pcall(function() return C4:GetProxyDevices() end)
    if ok and proxies then
      id = tonumber(string.match(tostring(proxies), "(%d+)"))
    end
  end
  state.playerProxyId = id
  return id
end

local autoRoom = {
  isOnEnabled = isAutoRoomOnEnabled,
  isOffEnabled = isAutoRoomOffEnabled,
  sendOn = function() C4:SendToProxy(MEDIA_PLAYER_BINDING_ID, "ON", {}) end,
  sendOff = function() C4:SendToProxy(MEDIA_PLAYER_BINDING_ID, "OFF", {}) end,
}

local function setWsStatus(connected, connecting)
  local was = state.wsConnected
  state.wsConnected = connected and true or false
  state.wsConnecting = connecting and true or false
  updateProperty(
    "WebSocket Status",
    state.wsConnected and "Connected" or (state.wsConnecting and "Connecting" or "Disconnected")
  )
  if bridge and was ~= state.wsConnected then
    bridge.pushConfig()
  end
end

local function clearStaleWebSocketBindingAddresses()
  for bindingId = 6100, 6199 do
    pcall(C4.SetBindingAddress, C4, bindingId, "")
  end
end

local function disconnectWebSocket(reason)
  logInfo("Disconnecting WebSocket" .. (reason and (" (" .. tostring(reason) .. ")") or ""))

  setWsStatus(false, false)
  state.reconnectTimerId = cancelTimer(state.reconnectTimerId)

  if state.webSocket then
    -- delete() releases the net binding WEBSOCKET_TEARDOWN_MS later; do not
    -- release it here (see reference driver notes).
    pcall(function() state.webSocket:delete() end)
    state.webSocket = nil
  end

  if kodiRpc then
    kodiRpc:setWebSocket(nil)
    kodiRpc:clearPendingCallbacks()
  end

  if commandHandlers and commandHandlers.STOP_REPEAT then
    commandHandlers.STOP_REPEAT()
  end
end

local function scheduleWebSocketReconnect()
  if state.isShuttingDown then return end
  if state.reconnectTimerId then return end

  state.reconnectTimerId = C4:SetTimer(RECONNECT_DELAY_MS, function()
    state.reconnectTimerId = nil
    if state.isShuttingDown then return end
    logInfo("Attempting to reconnect...")
    connectKodiWebSocket()
  end)
end

local function reconnectWebSocket(reason)
  local hadSocket = (state.webSocket ~= nil)
  disconnectWebSocket(reason)
  if hadSocket then
    scheduleWebSocketReconnect()
  else
    connectKodiWebSocket()
  end
end

-- Used by the library bridge while waiting to start a movie: make sure a
-- connection attempt is under way without tearing down one in progress.
local function ensureConnected()
  if state.isShuttingDown or state.wsConnected or state.wsConnecting then return end
  if state.reconnectTimerId then return end
  if state.webSocket then
    scheduleWebSocketReconnect()
  else
    connectKodiWebSocket()
  end
end

kodiRpc = KodiRpc:new({
  -- The bundled pure-Lua encoder keeps Lua arrays as JSON arrays, which
  -- C4:JsonEncode does not reliably do (the reference hand-built those).
  jsonEncode = function(value) return JSON:encode(value) end,
  setTimer = setTimer,
  callbackTimeoutMs = JSONRPC_CALLBACK_TIMEOUT_MS,
  logDebug = logDebug,
  logInfo = logInfo,

  isConnectedFn = function()
    return state.wsConnected
  end,

  onTransportError = function(why)
    if state.isShuttingDown then return end
    if not state.wsConnected and not state.wsConnecting then
      scheduleWebSocketReconnect()
      return
    end
    logInfo("Transport error: " .. tostring(why))
    disconnectWebSocket(why)
    scheduleWebSocketReconnect()
  end,
})

local avDetails = AvDetails:new({
  kodiRpc = kodiRpc,
  updateProperty = updateProperty,
  setTimer = setTimer,
  cancelTimer = cancelTimer,
  debounceMs = AV_DETAILS_DEBOUNCE_MS,
  logDebug = logDebug,
})

bridge = Bridge.create({
  state = state,
  kodiRpc = kodiRpc,
  setTimer = setTimer,
  cancelTimer = cancelTimer,
  getPlayerProxyId = getPlayerProxyId,
  ensureConnected = ensureConnected,
  updateProperty = updateProperty,
  fireEvent = fireEvent,
  getCommandHandlers = function() return commandHandlers end,
  logInfo = logInfo,
  logDebug = logDebug,
})

local notifications = Notifications.create({
  state = state,
  kodiRpc = kodiRpc,
  updateProperty = updateProperty,
  logDebug = logDebug,
  autoRoom = autoRoom,
  avDetails = avDetails,
  fireEvent = fireEvent,
  onLibraryChanged = function(kind, movieId) bridge.libraryChanged(kind, movieId) end,
})
local notificationHandlers = notifications.handlers

commandHandlers = Commands.createHandlers({
  state = state,
  kodiRpc = kodiRpc,
  getSkipIntervalSeconds = getSkipIntervalSeconds,
  shouldUseKodiPlaybackDirectionals = shouldUseKodiPlaybackDirectionals,
  autoRoom = autoRoom,
  setTimer = setTimer,
  cancelTimer = cancelTimer,
  logInfo = logInfo,
  isLibraryLaunchPending = function() return bridge.isLaunchPending() end,
})

local function handleKodiNotification(method, data)
  local handler = notificationHandlers[method]
  if handler then
    handler(data)
  else
    logDebug("Unhandled notification: " .. tostring(method))
  end
end

local function decodeJson(raw)
  local ok, value = pcall(function() return C4:JsonDecode(raw) end)
  if ok and type(value) == "table" then return value end
  ok, value = pcall(function() return JSON:decode(raw) end)
  if ok and type(value) == "table" then return value end
  return nil
end

local function processWebSocketMessage(_, rawData)
  local response = decodeJson(rawData)
  if not response then
    logInfo("Failed to decode JSON message")
    return
  end

  if response.id then
    kodiRpc:handleResponse(response)
  elseif response.method then
    logDebug("Notification: " .. response.method)
    handleKodiNotification(response.method, response.params and response.params.data)
  end
end

local function fetchKodiVersion()
  kodiRpc:sendRequest("Application.GetProperties", { properties = { "version", "name" } }, function(result, err)
    if err or type(result) ~= "table" or type(result.version) ~= "table" then return end
    local v = result.version
    local text = tostring(result.name or "Kodi") .. " " .. tostring(v.major or "?") .. "." .. tostring(v.minor or "?")
    if v.tag and v.tag ~= "stable" then text = text .. " " .. tostring(v.tag) end
    updateProperty("Kodi Version", text)
  end)
end

connectKodiWebSocket = function()
  if state.isShuttingDown then return end

  if not Properties then
    logInfo("Properties not available")
    return
  end

  local ipAddress = Properties["IP Address"]
  if not ipAddress or ipAddress == "" then
    logInfo("No IP address configured")
    return
  end

  if state.wsConnected or state.wsConnecting then
    logDebug("WebSocket already connected/connecting")
    return
  end

  if state.webSocket then
    logInfo("Unexpected live WebSocket at connect; tearing down first")
    disconnectWebSocket("connect_start")
    scheduleWebSocketReconnect()
    return
  end

  local port = tonumber(Properties["Kodi WebSocket Port"]) or KODI_WEBSOCKET_PORT
  local url = "ws://" .. ipAddress .. ":" .. port .. "/jsonrpc"
  logInfo("Connecting to " .. url)
  setWsStatus(false, true)

  local ws = WebSocket:new(url)
  if not ws then
    logInfo("Failed to create WebSocket")
    setWsStatus(false, false)
    scheduleWebSocketReconnect()
    return
  end

  ws.ping_interval = WEBSOCKET_PING_INTERVAL_SECONDS
  ws.pong_response_interval = WEBSOCKET_PONG_TIMEOUT_SECONDS

  state.webSocket = ws
  kodiRpc:setWebSocket(ws)

  ws:SetProcessMessageFunction(processWebSocketMessage)

  ws:SetEstablishedFunction(function(_)
    logInfo("WebSocket connected")
    setWsStatus(true, false)
    state.reconnectTimerId = cancelTimer(state.reconnectTimerId)
    notifications.refreshPlaybackState()
    fetchKodiVersion()
  end)

  ws:SetOfflineFunction(function(_)
    logInfo("WebSocket offline")
    if state.isShuttingDown then return end
    disconnectWebSocket("offline")
    scheduleWebSocketReconnect()
  end)

  ws:SetClosedByRemoteFunction(function(_)
    logInfo("WebSocket closed by remote")
    if state.isShuttingDown then return end
    disconnectWebSocket("closed_by_remote")
    scheduleWebSocketReconnect()
  end)

  ws:Start()
end

-------------------------------------------------------------------------------
-- Virtual switcher (binding 5002)
--
-- Plumbing, not a source. It owns the HDMI output so the media player and the
-- Kodi Movies service share one physical path to the TV/AVR. It must
-- acknowledge input changes or the room's AV path never completes, and it is
-- hidden from every room's source list.
-------------------------------------------------------------------------------

local SWITCH = {}

SWITCH.SET_INPUT = function(tParams)
  local input = tParams and tParams.INPUT
  local output = tParams and tParams.OUTPUT
  logDebug("Virtual switcher input " .. tostring(input) .. " -> output " .. tostring(output))
  C4:SendToProxy(SWITCH_BINDING_ID, "INPUT_CHANGED", { INPUT = input })
  C4:SendToProxy(SWITCH_BINDING_ID, "INPUT_OUTPUT_CHANGED", { INPUT = input, OUTPUT = output })
end

local function hideSwitcherInAllRooms()
  local deviceId = getProxyDeviceId(SWITCH_BINDING_ID)
  if not deviceId then return end

  local ok, rooms = pcall(function() return C4:GetDevicesByC4iName("roomdevice.c4i") end)
  if not ok or type(rooms) ~= "table" then return end

  for roomId, _ in pairs(rooms) do
    pcall(function()
      C4:SendToDevice(roomId, "SET_DEVICE_HIDDEN_STATE", {
        PROXY_GROUP = "ALL",
        DEVICE_ID = deviceId,
        IS_HIDDEN = true,
      })
    end)
  end
end

local function startSwitcherHiding()
  pcall(hideSwitcherInAllRooms)
  state.switchHideTimer = cancelTimer(state.switchHideTimer)
  state.switchHideTimer = C4:SetTimer(SWITCH_HIDE_INTERVAL_MS, function()
    pcall(hideSwitcherInAllRooms)
  end, true)
end

-------------------------------------------------------------------------------
-- Control4 entry points
-------------------------------------------------------------------------------

function ReceivedFromProxy(bindingID, command, params)
  params = params or {}

  if bindingID == SWITCH_BINDING_ID then
    local handler = SWITCH[command]
    if handler then
      pcall(handler, params)
    else
      logDebug("Virtual switcher: ignoring " .. tostring(command))
    end
    return
  end

  if bindingID == MEDIA_PLAYER_BINDING_ID and commandHandlers[command] then
    logDebug("Command: " .. command)
    local ok, err = pcall(function() commandHandlers[command](params) end)
    if not ok then
      logInfo("ReceivedFromProxy error (" .. tostring(command) .. "): " .. tostring(err))
    end
  elseif bindingID == MEDIA_PLAYER_BINDING_ID then
    logDebug("Unhandled media player command: " .. tostring(command))
  end
end

local function initialize()
  state.isShuttingDown = false
  state.playerProxyId = nil
  clearStaleWebSocketBindingAddresses()
  loadDirectionalsModeFromProperties()
  updateProperty("Driver Version", DRIVER_VERSION)
  connectKodiWebSocket()
  bridge.updateLinkStatus()
  bridge.pushConfig()
  startSwitcherHiding()
end

function OnDriverInit()
  logInfo("Driver initialized")
  state.isShuttingDown = false
end

function OnDriverLateInit()
  logInfo("Driver late init")
  initialize()
end

function OnDriverDestroyed()
  logInfo("Driver shutting down")
  state.isShuttingDown = true
  state.reconnectTimerId = cancelTimer(state.reconnectTimerId)
  state.switchHideTimer = cancelTimer(state.switchHideTimer)
  avDetails:clear()
  bridge.clear()
  disconnectWebSocket("driver_destroyed")
end

local LINK_SETTINGS = {
  ["IP Address"] = true,
  ["Kodi HTTP Port"] = true,
  ["Kodi Username"] = true,
  ["Kodi Password"] = true,
}

function OnPropertyChanged(propertyName)
  logDebug("Property changed: " .. propertyName)

  if propertyName == "Playback Directionals" then
    loadDirectionalsModeFromProperties()
  elseif propertyName == "IP Address" or propertyName == "Kodi WebSocket Port" then
    if state.isShuttingDown then return end
    logInfo(propertyName .. " changed, reconnecting")
    reconnectWebSocket("address_changed")
  end

  if LINK_SETTINGS[propertyName] then
    bridge.pushConfig()
  end
end

-- Kodi Movies binds/unbinds its control link.
OBC = OBC or {}
OBC[Bridge.LINK_BINDING_ID] = function(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
  logInfo("Library link " .. (bIsBound and "bound" or "unbound") .. " (device " .. tostring(otherDeviceId) .. ")")
  bridge.updateLinkStatus()
  if bIsBound and otherDeviceId then
    bridge.pushConfig(tonumber(otherDeviceId))
  end
end

-------------------------------------------------------------------------------
-- Actions and programming commands
-------------------------------------------------------------------------------

EX_CMD = EX_CMD or {}

function EX_CMD.ACTION_ReconnectWebSocket(_)
  logInfo("Driver Action: Reconnect WebSocket")
  if state.isShuttingDown then state.isShuttingDown = false end
  reconnectWebSocket("action_reconnect")
end

function EX_CMD.ACTION_DisconnectWebSocket(_)
  logInfo("Driver Action: Disconnect WebSocket")
  disconnectWebSocket("action_disconnect")
end

function EX_CMD.ACTION_ScanVideoLibrary(_)
  logInfo("Driver Action: Scan video library")
  kodiRpc:sendRequest("VideoLibrary.Scan", {})
end

function EX_CMD.ACTION_PushLibraryConfig(_)
  bridge.updateLinkStatus()
  bridge.pushConfig()
  bridge.libraryChanged("scan", nil)
end

EX_CMD["Kodi_Action"] = function(tParams)
  local action = tParams and (tParams.Action or tParams.ACTION)
  if action and action ~= "" then kodiRpc:executeAction(action) end
end

EX_CMD["Show_Notification"] = function(tParams)
  tParams = tParams or {}
  kodiRpc:sendRequest("GUI.ShowNotification", {
    title = tParams.Title or "Control4",
    message = tParams.Message or "",
    displaytime = (tonumber(tParams["Seconds"]) or 5) * 1000,
  })
end

EX_CMD["Open_Movies_Library"] = function(_)
  kodiRpc:sendRequest("GUI.ActivateWindow", { window = "videos", parameters = { "videodb://movies/titles/" } })
end

EX_CMD["Scan_Video_Library"] = EX_CMD.ACTION_ScanVideoLibrary

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}

  -- Composer actions arrive as LUA_ACTION with the command in ACTION.
  if strCommand == "LUA_ACTION" and tParams.ACTION then
    strCommand = tParams.ACTION
  end

  local ok, handled = pcall(bridge.handleCommand, strCommand, tParams)
  if not ok then
    logInfo("Library bridge error (" .. tostring(strCommand) .. "): " .. tostring(handled))
    return
  end
  if handled then return end

  local key = string.gsub(tostring(strCommand), "%s+", "_")
  local fn = EX_CMD[strCommand] or EX_CMD[key]
  if type(fn) == "function" then
    local ok2, err = pcall(fn, tParams)
    if not ok2 then
      logInfo("ExecuteCommand error (" .. tostring(strCommand) .. "): " .. tostring(err))
    end
    return
  end

  logDebug("ExecuteCommand: Unhandled command = " .. tostring(strCommand))
end
