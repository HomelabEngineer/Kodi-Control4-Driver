-- Kodi JSON-RPC notification handlers.
--
-- Based on the MIT-licensed Kodi-Control4-Driver by bmrowe. Additions: Control4
-- events for programming, a "Now Playing" property, and VideoLibrary change
-- notifications forwarded to linked Kodi Movies drivers so their cached library
-- (watched state, resume points, new movies) stays current.

local Notifications = {}

-- Kodi reports one player per active stream. Video wins outright; audio only
-- counts when no video player is present.
local function parseActivePlayers(players)
  if type(players) ~= "table" then return nil, nil end

  local playerId, playbackType
  for _, p in ipairs(players) do
    if p.type == "video" then
      return p.playerid, "video"
    elseif p.type == "audio" and playbackType == nil then
      playerId, playbackType = p.playerid, "audio"
    end
  end
  return playerId, playbackType
end

function Notifications.create(context)
  local state = assert(context.state, "state is required")
  local kodiRpc = assert(context.kodiRpc, "kodiRpc is required")
  local updateProperty = assert(context.updateProperty, "updateProperty is required")
  local logDebug = assert(context.logDebug, "logDebug is required")
  local autoRoom = assert(context.autoRoom, "autoRoom is required")
  local avDetails = assert(context.avDetails, "avDetails is required")
  local fireEvent = context.fireEvent or function(_) end
  local onLibraryChanged = context.onLibraryChanged or function(_, _, _) end
  local onVideoStarted = context.onVideoStarted or function() end

  local handlers = {}

  local function setStoppedProperties()
    updateProperty("Player State", "Stopped")
    updateProperty("Media Type", "-")
    updateProperty("Now Playing", "-")
    avDetails:resetProperties()
  end

  local function refreshNowPlayingTitle()
    if not state.playerId then return end
    kodiRpc:sendRequest("Player.GetItem", { playerid = state.playerId, properties = { "title", "year", "showtitle", "season", "episode" } }, function(result, err)
      if err or type(result) ~= "table" or type(result.item) ~= "table" then return end
      local item = result.item
      local title = item.title
      if (not title or title == "") then title = item.label end
      if not title or title == "" then return end
      if item.showtitle and item.showtitle ~= "" then
        title = item.showtitle .. " - " .. title
      elseif tonumber(item.year) and tonumber(item.year) > 0 then
        title = title .. " (" .. tostring(item.year) .. ")"
      end
      state.nowPlayingTitle = title
      updateProperty("Now Playing", title)
    end)
  end

  local function refreshPlaybackState(afterFn)
    kodiRpc:sendRequest("Player.GetActivePlayers", {}, function(players, err)
      -- A timeout, cancel, or JSON-RPC error yields a nil result. Treating that
      -- as "no active players" would wrongly clear playbackType mid-playback.
      if err then
        logDebug("Player.GetActivePlayers failed; leaving playback state unchanged")
        return
      end

      local playerId, pType = parseActivePlayers(players)
      state.playerId = playerId
      state.playbackType = pType

      if afterFn then afterFn(pType) end
    end)
  end

  handlers["Player.OnPlay"] = function(data)
    logDebug("Player.OnPlay notification")

    local wasInVideo = (state.playbackType == "video")

    refreshPlaybackState(function(pType)
      if pType ~= "video" then
        return
      end

      updateProperty("Player State", "Playing")

      if data and data.item and data.item.type then
        updateProperty("Media Type", data.item.type)
      end

      refreshNowPlayingTitle()

      if not wasInVideo then
        fireEvent("Playback Started")
        onVideoStarted(data and data.item)
        if autoRoom.isOnEnabled() then
          logDebug("Auto Room On: sending ON to proxy")
          autoRoom.sendOn()
        end
      else
        fireEvent("Playback Resumed")
      end
    end)
  end

  handlers["Player.OnPause"] = function(_)
    logDebug("Player.OnPause notification")

    refreshPlaybackState(function(pType)
      if pType == "video" then
        updateProperty("Player State", "Paused")
        fireEvent("Playback Paused")
      end
    end)
  end

  handlers["Player.OnResume"] = function(_)
    logDebug("Player.OnResume notification")

    refreshPlaybackState(function(pType)
      if pType == "video" then
        updateProperty("Player State", "Playing")
        fireEvent("Playback Resumed")
      end
    end)
  end

  handlers["Player.OnStop"] = function(data)
    logDebug("Player.OnStop notification")

    local wasInVideo = (state.playbackType == "video")

    refreshPlaybackState(function(pType)
      if wasInVideo and pType ~= "video" then
        avDetails:clear()
        setStoppedProperties()
        state.nowPlayingTitle = nil

        if data and data["end"] == true then
          fireEvent("Playback Ended")
        end
        fireEvent("Playback Stopped")

        if autoRoom.isOffEnabled() then
          logDebug("Auto Room Off: sending OFF to proxy")
          autoRoom.sendOff()
        end
      end
    end)
  end

  handlers["Player.OnSpeedChanged"] = function(data)
    logDebug("Player.OnSpeedChanged notification")

    if state.playbackType ~= "video" then return end

    if data and data.player and data.player.speed ~= nil then
      if data.player.speed == 0 then
        updateProperty("Player State", "Paused")
      elseif data.player.speed == 1 then
        updateProperty("Player State", "Playing")
      else
        updateProperty("Player State", "Fast Forward/Rewind")
      end
    end
  end

  handlers["Player.OnAVChange"] = function(_)
    logDebug("Player.OnAVChange notification")
    avDetails:scheduleUpdate()
  end

  handlers["Player.OnAVStart"] = function(_)
    logDebug("Player.OnAVStart notification")
    refreshPlaybackState(function(_)
      avDetails:scheduleUpdate()
    end)
  end

  -- Library changes. OnUpdate fires for watched/resume changes after playback
  -- and for metadata edits; OnRemove for deleted items; the scan/clean pair for
  -- bulk changes. Only movies matter to Kodi Movies, but bulk events carry no
  -- item so they always forward.
  handlers["VideoLibrary.OnUpdate"] = function(data)
    local item = data and data.item
    if type(item) == "table" and item.type == "movie" and item.id then
      onLibraryChanged("update", item.id)
    end
  end

  handlers["VideoLibrary.OnRemove"] = function(data)
    if type(data) == "table" and data.type == "movie" and data.id then
      onLibraryChanged("remove", data.id)
    end
  end

  handlers["VideoLibrary.OnScanFinished"] = function(_)
    onLibraryChanged("scan", nil)
  end

  handlers["VideoLibrary.OnCleanFinished"] = function(_)
    onLibraryChanged("scan", nil)
  end

  handlers["VideoLibrary.OnRefresh"] = function(_)
    onLibraryChanged("scan", nil)
  end

  return {
    handlers = handlers,
    refreshPlaybackState = refreshPlaybackState,
  }
end

return Notifications
