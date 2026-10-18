-- Artwork URLs for Navigator.
--
-- Navigators (touchscreens, apps, Halo) fetch images themselves, so URLs must be
-- reachable from them, not just from the controller. Two sources:
--
--  * Internet: Kodi stores scraped art as image://<encoded original URL>/. For
--    TMDB art the original is decoded and resized through TMDB's own size
--    paths (w185/w342/w500/w780), which keeps posters small for the Halo and
--    works even off the home network.
--  * Kodi web server: http://host:port/image/<encoded image:// URL>. Works for
--    every image Kodi has (local files, NAS artwork), needs Kodi's web server
--    enabled and reachable from each navigator.

local Artwork = {}

local function urlEncode(s)
  return (string.gsub(s, "([^%w%-%._~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end
Artwork.urlEncode = urlEncode

local function urlDecode(s)
  return (string.gsub(s, "%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end
Artwork.urlDecode = urlDecode

-- image://<encoded>/  ->  decoded inner URL (or nil)
function Artwork.innerUrl(imagePath)
  if type(imagePath) ~= "string" then return nil end
  local inner = imagePath:match("^image://(.+)$")
  if not inner then
    if imagePath:match("^https?://") then return imagePath end
    return nil
  end
  inner = inner:gsub("/$", "")
  return urlDecode(inner)
end

local TMDB_PATTERN = "^(https?://image%.tmdb%.org/t/p/)[^/]+(/.+)$"

function Artwork.isTmdb(url)
  return type(url) == "string" and url:match(TMDB_PATTERN) ~= nil
end

function Artwork.tmdbSized(url, size)
  local prefix, rest = url:match(TMDB_PATTERN)
  if not prefix then return url end
  return prefix .. size .. rest
end

-- options: { mode = "internet"|"kodi", host, port, username, password, embedCredentials }
function Artwork.new(options)
  local self = { options = options or {} }

  function self.configure(opts)
    self.options = opts or {}
  end

  local function kodiBase()
    local o = self.options
    if not o.host or o.host == "" then return nil end
    local auth = ""
    if o.embedCredentials and o.username and o.username ~= "" and o.password and o.password ~= "" then
      auth = urlEncode(o.username) .. ":" .. urlEncode(o.password) .. "@"
    end
    return "http://" .. auth .. o.host .. ":" .. tostring(o.port or 8080)
  end

  local function kodiImage(imagePath)
    local base = kodiBase()
    if not base then return nil end
    return base .. "/image/" .. urlEncode(imagePath)
  end

  -- kind: "poster" | "fanart"; size: "small" | "large"
  function self.url(imagePath, kind, size)
    if type(imagePath) ~= "string" or imagePath == "" then return nil end

    if self.options.mode ~= "kodi" then
      local inner = Artwork.innerUrl(imagePath)
      if inner and inner:match("^https?://") then
        if Artwork.isTmdb(inner) then
          local tmdbSize
          if kind == "fanart" then
            tmdbSize = (size == "small") and "w300" or "w780"
          else
            tmdbSize = (size == "small") and "w342" or "w500"
          end
          return Artwork.tmdbSized(inner, tmdbSize)
        end
        return inner
      end
    end

    if imagePath:match("^https?://") then return imagePath end
    return kodiImage(imagePath)
  end

  -- Navigator image_list entries for a list row.
  function self.imageList(imagePath, kind)
    local out = {}
    local small = self.url(imagePath, kind, "small")
    if not small then return out end
    local w, h = 342, 513
    if kind == "fanart" then w, h = 300, 169 end
    table.insert(out, { url = small, width = w, height = h })
    local large = self.url(imagePath, kind, "large")
    if large and large ~= small then
      local lw, lh = 500, 750
      if kind == "fanart" then lw, lh = 780, 439 end
      table.insert(out, { url = large, width = lw, height = lh })
    end
    return out
  end

  return self
end

return Artwork
