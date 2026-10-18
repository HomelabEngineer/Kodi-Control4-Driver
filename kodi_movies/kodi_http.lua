-- Minimal Kodi JSON-RPC over HTTP (POST /jsonrpc) using the Control4 URL API.
--
-- The library is read over HTTP rather than through the main driver's
-- WebSocket: responses for large libraries are big, and HTTP keeps them off
-- the control channel the remote depends on.

local KodiHttp = {}
KodiHttp.__index = KodiHttp

function KodiHttp.new(options)
  local self = setmetatable({}, KodiHttp)
  self.jsonEncode = assert(options.jsonEncode, "jsonEncode is required")
  self.jsonDecode = assert(options.jsonDecode, "jsonDecode is required")
  self.logDebug = options.logDebug or function(_) end
  self.config = {}
  self.nextId = 0
  return self
end

function KodiHttp:configure(config)
  self.config = config or {}
end

function KodiHttp:isConfigured()
  return self.config.host ~= nil and self.config.host ~= ""
end

function KodiHttp:url()
  return "http://" .. tostring(self.config.host) .. ":" .. tostring(self.config.port or 8080) .. "/jsonrpc"
end

function KodiHttp:headers()
  local headers = { ["Content-Type"] = "application/json" }
  local user = self.config.username or ""
  local pass = self.config.password or ""
  if user ~= "" then
    headers["Authorization"] = "Basic " .. C4:Base64Encode(user .. ":" .. pass)
  end
  return headers
end

-- callback(result, err) where err is a short human-readable string.
function KodiHttp:call(method, params, callback)
  callback = callback or function(_, _) end

  if not self:isConfigured() then
    callback(nil, "Kodi address unknown")
    return
  end

  self.nextId = (self.nextId % 99999) + 1
  local body = self.jsonEncode({
    jsonrpc = "2.0",
    id = self.nextId,
    method = method,
    params = params or {},
  })

  self.logDebug("HTTP " .. method .. " -> " .. self:url())

  local ok, err = pcall(function()
    C4:urlPost(self:url(), body, self:headers(), false,
      function(_, strData, responseCode, _, strError)
        local code = tonumber(responseCode) or 0
        if strError and strError ~= "" and code == 0 then
          callback(nil, "Network error: " .. tostring(strError))
          return
        end
        if code == 401 then
          callback(nil, "Kodi rejected the username/password (401)")
          return
        end
        if code ~= 200 then
          callback(nil, "HTTP " .. tostring(code) .. ((strError and strError ~= "") and (" " .. strError) or ""))
          return
        end

        local response = self.jsonDecode(strData or "")
        if type(response) ~= "table" then
          callback(nil, "Invalid JSON from Kodi")
          return
        end
        if response.error then
          local msg = type(response.error) == "table" and response.error.message or tostring(response.error)
          callback(nil, "Kodi error: " .. tostring(msg))
          return
        end
        callback(response.result, nil)
      end)
  end)

  if not ok then
    callback(nil, "Request failed: " .. tostring(err))
  end
end

return KodiHttp
