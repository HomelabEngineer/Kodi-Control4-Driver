local C4Utils = require("c4_utils")
local KodiRpc = require("kodi_rpc")
local AvDetails = require("av_details")
local Notifications = require("notifications")
local Commands = require("commands")
local WebSocket = require("drivers-common-public.module.websocket")

local MEDIA_PLAYER_BINDING_ID = 5001
local KODI_WEBSOCKET_PORT = 9090
local DEFAULT_SKIP_INTERVAL_SECONDS = 30

-- The websocket library pings on an interval and fails the connection if no pong
-- arrives within pong_response_interval. Each ping re-arms that deadline, so the
-- pong timeout only ever fires if it is SHORTER than the ping interval --
-- otherwise the next ping pushes the deadline out and a dead peer is never
-- detected. Keep PONG < PING.
local WEBSOCKET_PING_INTERVAL_SECONDS = 5
local WEBSOCKET_PONG_TIMEOUT_SECONDS = 3

-- websocket.lua's Close() releases the net binding on a 3s timer, so a socket
-- created sooner than that can be handed the binding the old one is about to
-- tear down. Every reconnect must outlast it.
local WEBSOCKET_TEARDOWN_MS = 3000
local RECONNECT_DELAY_MS = 5000

local JSONRPC_CALLBACK_TIMEOUT_MS = 10000
local AV_DETAILS_DEBOUNCE_MS = 500

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

}

-- Forward declarations (avoid Lua scoping issues)
local connectKodiWebSocket
local kodiRpc
local commandHandlers

local function isAutoRoomOnEnabled()
  return Properties and Properties["Auto Room On"] == "ON"
end

local function isAutoRoomOffEnabled()
  return Properties and Properties["Auto Room Off"] == "ON"
end

local function loadDirectionalsModeFromProperties()
  if not Properties then return end

  local directionalsSetting = Properties["Playback Directionals"]
  if directionalsSetting == "Kodi" then
    state.directionalsMode = "Kodi"
  else
    state.directionalsMode = "PM4K"
  end

  logDebug("Playback Directionals mode set to: " .. state.directionalsMode)
end

local function shouldUseKodiPlaybackDirectionals()
  return state.playbackType == "video" and state.directionalsMode == "Kodi"
end

local function getSkipIntervalSeconds()
  if not Properties then return DEFAULT_SKIP_INTERVAL_SECONDS end
  return tonumber(Properties["Skip Interval (seconds)"]) or DEFAULT_SKIP_INTERVAL_SECONDS
end

local autoRoom = {
  isOnEnabled = isAutoRoomOnEnabled,
  isOffEnabled = isAutoRoomOffEnabled,
  sendOn = function() C4:SendToProxy(MEDIA_PLAYER_BINDING_ID, "ON", {}) end,
  sendOff = function() C4:SendToProxy(MEDIA_PLAYER_BINDING_ID, "OFF", {}) end,
}

local function setWsStatus(connected, connecting)
  state.wsConnected = connected and true or false
  state.wsConnecting = connecting and true or false
  updateProperty(
    "WebSocket Status",
    state.wsConnected and "Connected" or (state.wsConnecting and "Connecting" or "Disconnected")
  )
end

-- Bindings can survive a driver reload with an address still set, which would
-- push the library's 6100-6199 scan onto a fresh binding every restart.
local function clearStaleWebSocketBindingAddresses()
  for bindingId = 6100, 6199 do
    pcall(C4.SetBindingAddress, C4, bindingId, "")
  end
end

local function disconnectWebSocket(reason)
  if reason then
    logInfo("Disconnecting WebSocket (" .. tostring(reason) .. ")")
  else
    logInfo("Disconnecting WebSocket")
  end

  setWsStatus(false, false)
  state.reconnectTimerId = cancelTimer(state.reconnectTimerId)

  if state.webSocket then
    -- delete() closes the socket, drops the library's URL cache entry, and
    -- releases the net binding -- but only WEBSOCKET_TEARDOWN_MS later. Do not
    -- release the binding here: freeing it early lets the next socket claim the
    -- same one, and the old teardown then clears the new socket's handlers.
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
  -- Already pending: re-arming here would let repeated failures (e.g. button
  -- presses against a dead player) push the reconnect out indefinitely.
  if state.reconnectTimerId then return end

  state.reconnectTimerId = C4:SetTimer(RECONNECT_DELAY_MS, function()
    state.reconnectTimerId = nil
    if state.isShuttingDown then return end
    logInfo("Attempting to reconnect...")
    connectKodiWebSocket()
  end)
end

-- Reconnect without racing an in-progress teardown.
local function reconnectWebSocket(reason)
  local hadSocket = (state.webSocket ~= nil)
  disconnectWebSocket(reason)
  if hadSocket then
    scheduleWebSocketReconnect()
  else
    connectKodiWebSocket()
  end
end

kodiRpc = KodiRpc:new({
  jsonEncode = function(value) return C4:JsonEncode(value) end,
  setTimer = function(ms, callback) return C4:SetTimer(ms, callback) end,
  callbackTimeoutMs = JSONRPC_CALLBACK_TIMEOUT_MS,
  logDebug = logDebug,
  logInfo = logInfo,

  isConnectedFn = function()
    return state.wsConnected
  end,

  onTransportError = function(why)
    if state.isShuttingDown then return end

    -- Already down with a reconnect pending: tearing down again would cancel
    -- that timer and re-arm it, so a stream of failures (e.g. button presses
    -- against a dead player) would push reconnection out indefinitely.
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
  setTimer = function(ms, callback) return C4:SetTimer(ms, callback) end,
  cancelTimer = cancelTimer,
  debounceMs = AV_DETAILS_DEBOUNCE_MS,
  logDebug = logDebug,
})

local notifications = Notifications.create({
  state = state,
  kodiRpc = kodiRpc,
  updateProperty = updateProperty,
  logDebug = logDebug,
  autoRoom = autoRoom,
  avDetails = avDetails,
})
local notificationHandlers = notifications.handlers

commandHandlers = Commands.createHandlers({
  state = state,
  kodiRpc = kodiRpc,
  getSkipIntervalSeconds = getSkipIntervalSeconds,
  shouldUseKodiPlaybackDirectionals = shouldUseKodiPlaybackDirectionals,
  autoRoom = autoRoom,
  setTimer = function(ms, callback) return C4:SetTimer(ms, callback) end,
  cancelTimer = cancelTimer,
  logInfo = logInfo,
})

local function handleKodiNotification(method, data)
  local handler = notificationHandlers[method]
  if handler then
    handler(data)
  else
    logDebug("Unhandled notification: " .. tostring(method))
  end
end

local function processWebSocketMessage(_, rawData)
  logDebug("Message received")

  local ok, response = pcall(function() return C4:JsonDecode(rawData) end)
  if not ok or type(response) ~= "table" then
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
    -- Shouldn't happen: callers disconnect first. Tear the old socket down and
    -- retry once its binding has actually been released.
    logInfo("Unexpected live WebSocket at connect; tearing down first")
    disconnectWebSocket("connect_start")
    scheduleWebSocketReconnect()
    return
  end

  local url = "ws://" .. ipAddress .. ":" .. KODI_WEBSOCKET_PORT .. "/jsonrpc"
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

function ReceivedFromProxy(bindingID, command, params)
  if bindingID == MEDIA_PLAYER_BINDING_ID and commandHandlers[command] then
    logDebug("Command: " .. command)
    local ok, err = pcall(function() commandHandlers[command](params) end)
    if not ok then
      logInfo("ReceivedFromProxy error (" .. tostring(command) .. "): " .. tostring(err))
    end
  end
end

function OnDriverInit()
  logInfo("Driver initialized")
  state.isShuttingDown = false
  clearStaleWebSocketBindingAddresses()
  loadDirectionalsModeFromProperties()
  connectKodiWebSocket()
end

function OnDriverDestroyed()
  logInfo("Driver shutting down")
  state.isShuttingDown = true
  state.reconnectTimerId = cancelTimer(state.reconnectTimerId)
  avDetails:clear()
  disconnectWebSocket("driver_destroyed")
end

function OnPropertyChanged(propertyName)
  logDebug("Property changed: " .. propertyName)

  if propertyName == "Playback Directionals" then
    loadDirectionalsModeFromProperties()

  elseif propertyName == "IP Address" then
    logInfo("IP address changed, reconnecting")
    if state.isShuttingDown then return end

    reconnectWebSocket("ip_changed")
  end
end

-- Action command handlers (match driver.xml <actions>/<command>)
EX_CMD = EX_CMD or {}

function EX_CMD.ACTION_ReconnectWebSocket(_)
  logInfo("Driver Action: ACTION_ReconnectWebSocket")
  if state.isShuttingDown then state.isShuttingDown = false end
  reconnectWebSocket("action_reconnect")
end

function EX_CMD.ACTION_DisconnectWebSocket(_)
  logInfo("Driver Action: ACTION_DisconnectWebSocket")
  disconnectWebSocket("action_disconnect")
end

function ExecuteCommand(strCommand, tParams)
  local fn = EX_CMD and EX_CMD[strCommand]
  if type(fn) == "function" then
    local ok, err = pcall(function() return fn(tParams) end)
    if not ok then
      logInfo("ExecuteCommand error (" .. tostring(strCommand) .. "): " .. tostring(err))
    end
    return
  end

  logDebug("ExecuteCommand: Unhandled command = " .. tostring(strCommand))
end
