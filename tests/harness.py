"""Off-controller harness: runs both drivers in Lua 5.1 (lupa) against a
stubbed Control4 API, a virtual clock, a fake Kodi HTTP endpoint and a fake
Kodi WebSocket.

Each driver gets its own Lua state, as on a controller. C4:SendToDevice is
routed between them by a Python broker.
"""
import json
import os
import xml.etree.ElementTree as ET

from lupa import lua51

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

STUB = r"""
local py = ...
CLOCK_MS = 0
local timers = {}
local timerSeq = 0

os.time = function(t)
  if t then return 0 end
  return math.floor(CLOCK_MS / 1000) + 1800000000
end

local Timer = {}
Timer.__index = Timer
function Timer:Cancel() self.cancelled = true return nil end

function C4TEST_advance(ms)
  local target = CLOCK_MS + ms
  while true do
    local best
    for _, t in ipairs(timers) do
      if not t.cancelled and t.due <= target and (best == nil or t.due < best.due or (t.due == best.due and t.seq < best.seq)) then
        best = t
      end
    end
    if not best then break end
    CLOCK_MS = math.max(CLOCK_MS, best.due)
    if best.rep then
      best.due = best.due + best.ms
    else
      best.cancelled = true
    end
    local ok, err = pcall(best.fn, best)
    if not ok then py.error("timer error: " .. tostring(err)) end
  end
  CLOCK_MS = target
  local live = {}
  for _, t in ipairs(timers) do if not t.cancelled then table.insert(live, t) end end
  timers = live
end

C4 = {}
function C4:SetTimer(ms, fn, rep)
  timerSeq = timerSeq + 1
  local t = setmetatable({ due = CLOCK_MS + ms, ms = ms, fn = fn, rep = rep and true or false, seq = timerSeq }, Timer)
  table.insert(timers, t)
  return t
end
function C4:KillTimer(t) return 0 end
function C4:UpdateProperty(name, value) Properties[name] = value; py.property(name, tostring(value)) end
function C4:SendToProxy(binding, cmd, params, kind) py.to_proxy(binding, cmd, params) end
function C4:SendToDevice(id, cmd, params) py.to_device(id, cmd, params) end
function C4:GetDeviceID() return py.device_id() end
function C4:GetBoundConsumerDevices(dev, binding) return py.bound_consumers(dev, binding) end
function C4:GetBoundProviderDevice(dev, binding) return py.bound_provider(dev, binding) end
function C4:GetProxyDevices() return py.proxy_devices() end
function C4:GetDeviceDisplayName(id) return "Device " .. tostring(id) end
function C4:FireEvent(name) py.event(name) end
function C4:JsonDecode(s) return py.json_decode(s) end
function C4:JsonEncode(v) error("C4:JsonEncode should not be used") end
function C4:ParseXml(s) return py.parse_xml(s) end
function C4:Base64Encode(s) return py.b64(s) end
function C4:urlSetTimeout(s) end
function C4:urlPost(url, body, headers, flag, cb) py.url_post(url, body, headers, cb) end
function C4:SetBindingAddress(b, a) end
function C4:GetDevicesByC4iName(n) return py.rooms() end
function C4:AddVariable(...) return true end
function C4:SetVariable(name, value) py.variable(name, tostring(value)) end
function C4:GetDriverConfigInfo(k)
  if k == "name" then return "Kodi" end
  if k == "version" then return "100" end
  if k == "model" then return "Kodi Player" end
  return ""
end
function C4:StatsdIncrementMeter() end
function C4:StatsdGauge() end
function C4:StatsdCounter() end
function C4:StatsdTimer() end
function C4:GetVersionInfo() return { version = "3.4.0" } end
function C4:GetControllerNetworkAddress() return "127.0.0.1" end
function C4:GetDeviceVariable() return "" end
function C4:RegisterSystemEvent() end
function C4:UnregisterSystemEvent() end
function C4:AllowExecute() end
function C4:urlSetOption() end
function C4:SetPropertyAttribs() end
function C4:GetUniqueMAC() return "000000000000" end
function C4:GetSystemType() return "test" end
function C4:GetZigbeeEUID() return "" end
function C4:ErrorLog(s) py.log("ERR " .. tostring(s)) end
function C4:DebugLog(s) end

print = function(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
  py.log(table.concat(t, " "))
end
"""

FAKE_WS = r"""
local py = ...
local ws = {}
ws.__index = ws
function ws:new(url)
  local o = setmetatable({ url = url, connected = false }, ws)
  py.ws_created(o)
  return o
end
function ws:delete() self.connected = false; py.ws_deleted(self) end
function ws:Start() py.ws_started(self) end
function ws:Send(s) py.ws_send(s) end
function ws:SetProcessMessageFunction(f) self.onMessage = f end
function ws:SetEstablishedFunction(f) self.onEstablished = f end
function ws:SetOfflineFunction(f) self.onOffline = f end
function ws:SetClosedByRemoteFunction(f) self.onClosed = f end
function ws:Establish() self.connected = true; self.onEstablished(self) end
function ws:Deliver(s) self.onMessage(self, s) end
-- Load the real handler/lib chain so globals (JSON, OBC, ...) match the controller.
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.timer")
return ws
"""


def make_movies(n=600):
    genres = ["Action", "Comedy", "Drama", "Sci-Fi", "Thriller", "Animation", "Horror", "Romance"]
    movies = []
    for i in range(1, n + 1):
        title = ("The " if i % 7 == 0 else "") + f"Movie {i:04d} & Friends <Cut>"
        movies.append({
            "movieid": i,
            "label": title,
            "title": title,
            "sorttitle": "",
            "year": 1980 + (i % 45),
            "runtime": 5400 + (i % 60) * 60,
            "genre": [genres[i % len(genres)], genres[(i * 3) % len(genres)]],
            "director": [f"Director {i % 30}"],
            "plot": f"[B]Plot[/B] for movie {i}. A long description that goes on " * 3,
            "plotoutline": "",
            "tagline": f"Tagline {i}",
            "art": {
                "poster": "image://https%3a%2f%2fimage.tmdb.org%2ft%2fp%2foriginal%2fposter" + str(i) + ".jpg/",
                "fanart": "image://smb%3a%2f%2fnas%2fmovies%2ffanart" + str(i) + ".jpg/",
            },
            "thumbnail": "",
            "rating": round((i % 90) / 10.0, 1),
            "mpaa": "Rated PG-13" if i % 2 else "R",
            "playcount": 1 if i % 5 == 0 else 0,
            "resume": {"position": 1200.0 if i % 11 == 0 else 0.0, "total": 6000.0 if i % 11 == 0 else 0.0},
            "dateadded": f"2026-{(i % 12) + 1:02d}-{(i % 28) + 1:02d} 10:00:00",
            "lastplayed": f"2026-09-{(i % 28) + 1:02d} 21:00:00" if i % 11 == 0 else "",
            "setid": (i % 20) + 1 if i % 4 == 0 else 0,
            "set": f"Saga {(i % 20) + 1}" if i % 4 == 0 else "",
        })
    return movies


class Driver:
    def __init__(self, world, name, device_id, folder, properties, ws_stub=False):
        self.world = world
        self.name = name
        self.device_id = device_id
        self.folder = folder
        self.properties_log = {}
        self.proxy_messages = []
        self.events = []
        self.logs = []
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        lua = self.lua
        lua.execute('package.path = "%s/?.lua;" .. package.path' % folder)
        props = lua.table()
        for k, v in properties.items():
            props[k] = v
        lua.globals().Properties = props
        hooks = self._hooks()
        lua.eval("function(...) " + STUB + " end")(hooks)
        if ws_stub:
            fake = lua.eval("function(...) " + FAKE_WS + " end")(hooks)
            lua.globals().package.loaded["drivers-common-public.module.websocket"] = fake
        with open(os.path.join(folder, "driver.lua"), encoding="utf-8") as f:
            src = f.read()
        lua.execute(src)

    # -- conversions -------------------------------------------------------
    def to_lua(self, obj):
        lua = self.lua
        if isinstance(obj, dict):
            t = lua.table()
            for k, v in obj.items():
                t[k] = self.to_lua(v)
            return t
        if isinstance(obj, list):
            t = lua.table()
            for i, v in enumerate(obj, 1):
                t[i] = self.to_lua(v)
            return t
        return obj

    @staticmethod
    def lua_to_py(t):
        if t is None or isinstance(t, (str, int, float, bool)):
            return t
        try:
            items = list(t.items())
        except AttributeError:
            return t
        return {k: Driver.lua_to_py(v) for k, v in items}

    def _hooks(self):
        world = self
        hooks = self.lua.table()

        def log(s):
            world.logs.append(s)
            if os.environ.get("VERBOSE"):
                print(f"[{world.name}] {s}")

        def error(s):
            world.logs.append("ERROR " + s)
            raise RuntimeError(f"[{world.name}] {s}")

        hooks.log = log
        hooks.error = error
        hooks.property = lambda k, v: world.properties_log.__setitem__(k, v)
        hooks.to_proxy = lambda b, c, p: world.proxy_messages.append((b, c, Driver.lua_to_py(p)))
        hooks.to_device = lambda d, c, p: world.world.route(world, d, c, Driver.lua_to_py(p))
        hooks.device_id = lambda: world.device_id
        hooks.bound_consumers = lambda d, b: world.to_lua(world.world.consumers(d, b))
        hooks.bound_provider = lambda d, b: world.world.provider(d, b)
        hooks.proxy_devices = lambda: world.world.proxy_devices(world.device_id)
        hooks.event = lambda n: world.events.append(n)
        hooks.json_decode = lambda s: world.to_lua(json.loads(s))
        hooks.parse_xml = lambda s: world._parse_xml(s)
        hooks.b64 = lambda s: __import__("base64").b64encode(s.encode()).decode()
        hooks.url_post = lambda url, body, headers, cb: world.world.http(world, url, body, Driver.lua_to_py(headers), cb)
        hooks.rooms = lambda: world.to_lua({r: "Room" for r in world.world.rooms_list})
        hooks.variable = lambda n, v: world.events.append(("var", n, v))
        hooks.ws_created = lambda o: world.world.ws_created(o)
        hooks.ws_deleted = lambda o: None
        hooks.ws_started = lambda o: world.world.ws_started(o)
        hooks.ws_send = lambda s: world.world.ws_sent(s)
        return hooks

    def _parse_xml(self, s):
        root = ET.fromstring(s)
        nodes = []
        for child in root:
            nodes.append({"Name": child.tag, "Attributes": dict(child.attrib), "Value": child.text or ""})
        return self.to_lua({"Name": root.tag, "ChildNodes": nodes})

    def call(self, fn, *args):
        f = self.lua.globals()[fn]
        return f(*[self.to_lua(a) if isinstance(a, (dict, list)) else a for a in args])

    def advance(self, ms):
        self.lua.globals().C4TEST_advance(ms)


class World:
    MAIN_ID = 1001
    MOVIES_ID = 1002
    PLAYER_PROXY_ID = 1011
    SWITCH_PROXY_ID = 1012
    MOVIES_PROXY_ID = 1021

    def __init__(self, movies=None, linked=True, main_props=None, movies_props=None):
        self.movies = movies if movies is not None else make_movies()
        self.linked = linked
        self.rooms_list = [33, 34]
        self.http_log = []
        self.http_queue = []
        self.ws_log = []
        self.ws = None
        self.routed = []
        self.http_fail = None
        mp = {
            "IP Address": "10.0.0.50",
            "Kodi WebSocket Port": "9090",
            "Kodi HTTP Port": "8080",
            "Kodi Username": "kodi",
            "Kodi Password": "secret",
            "Playback Directionals": "PM4K",
            "Startup Action on ON": "Kodi Home",
            "Skip Interval (seconds)": "30",
            "Auto Room On": "OFF",
            "Auto Room Off": "OFF",
            "Turn Room On When Playing From Library": "ON",
            "Play Delay After Room On (seconds)": "4",
            "Library Play Timeout (seconds)": "90",
            "Resume Behavior": "Resume Where Left Off",
            "Debug Mode": "OFF",
            "Stop Playback When Room Turns Off": "OFF",
        }
        mp.update(main_props or {})
        vp = {
            "Movie Tap Action": "Play Movie",
            "Resume Behavior": "Use Kodi Driver Setting",
            "Default Sort": "Title",
            "List Subtitle": "Year, Runtime and Plot",
            "Hide Watched Movies": "OFF",
            "Show Watched Marker": "ON",
            "Recently Added Count": "50",
            "Details Image": "Poster",
            "Artwork Source": "Internet When Available",
            "Send Kodi Login With Artwork": "ON",
            "Auto Refresh (minutes)": "60",
            "Debug Mode": "OFF",
        }
        vp.update(movies_props or {})
        self.main = Driver(self, "main", self.MAIN_ID, os.path.join(ROOT, "kodi_player"), mp, ws_stub=True)
        self.mov = Driver(self, "movies", self.MOVIES_ID, os.path.join(ROOT, "kodi_movies"), vp)

    # -- topology ------------------------------------------------------------
    def consumers(self, device, binding):
        if device == self.MAIN_ID and binding == 3900:
            return {self.MOVIES_ID: "Kodi Movies"} if self.linked else {}
        if device == self.MAIN_ID and binding == 5001:
            return {self.PLAYER_PROXY_ID: "Kodi"}
        if device == self.MAIN_ID and binding == 5002:
            return {self.SWITCH_PROXY_ID: "Kodi Virtual Switcher"}
        return {}

    def provider(self, device, binding):
        if device == self.MOVIES_ID and binding == 3900 and self.linked:
            return self.MAIN_ID
        return 0

    def proxy_devices(self, device):
        return f"{self.PLAYER_PROXY_ID},{self.SWITCH_PROXY_ID}" if device == self.MAIN_ID else str(self.MOVIES_PROXY_ID)

    def route(self, sender, target, cmd, params):
        self.routed.append((sender.name, target, cmd, params))
        if target == self.MAIN_ID:
            self.main.call("ExecuteCommand", cmd, params or {})
        elif target == self.MOVIES_ID:
            self.mov.call("ExecuteCommand", cmd, params or {})
        # rooms and other devices: recorded only

    # -- fake Kodi HTTP --------------------------------------------------------
    def http(self, driver, url, body, headers, cb):
        req = json.loads(body)
        self.http_log.append((url, req, headers))
        self.http_queue.append((driver, req, cb))

    def pump_http(self):
        n = 0
        while self.http_queue:
            driver, req, cb = self.http_queue.pop(0)
            n += 1
            if self.http_fail:
                cb(1, "", self.http_fail, driver.lua.table(), "")
                continue
            m = req["method"]
            p = req.get("params", {})
            if m == "VideoLibrary.GetMovies":
                s, e = p["limits"]["start"], p["limits"]["end"]
                chunk = self.movies[s:e]
                result = {"movies": chunk, "limits": {"start": s, "end": min(e, len(self.movies)), "total": len(self.movies)}}
            elif m == "VideoLibrary.GetMovieDetails":
                mv = next(x for x in self.movies if x["movieid"] == p["movieid"])
                result = {"moviedetails": mv}
            elif m == "VideoLibrary.SetMovieDetails":
                mv = next(x for x in self.movies if x["movieid"] == p["movieid"])
                mv["playcount"] = p["playcount"]
                result = "OK"
            else:
                result = None
            resp = json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result})
            cb(1, resp, 200, driver.lua.table(), "")
        return n

    # -- fake Kodi WebSocket ---------------------------------------------------
    def ws_created(self, o):
        self.ws = o

    def ws_started(self, o):
        self.ws_log.append(("start", o.url))

    def ws_sent(self, s):
        self.ws_log.append(("send", json.loads(s)))

    def ws_requests(self, method=None):
        return [m for kind, m in self.ws_log if kind == "send" and (method is None or m.get("method") == method)]

    def ws_reply(self, request, result="OK", error=None):
        payload = {"jsonrpc": "2.0", "id": request["id"]}
        if error:
            payload["error"] = error
        else:
            payload["result"] = result
        self.ws.Deliver(self.ws, json.dumps(payload))

    def ws_notify(self, method, data):
        self.ws.Deliver(self.ws, json.dumps({"jsonrpc": "2.0", "method": method, "params": {"data": data, "sender": "xbmc"}}))

    # -- helpers -----------------------------------------------------------------
    def advance(self, ms):
        # Advance both drivers' clocks in lock-step, pumping HTTP in between.
        step = 100
        done = 0
        while done < ms:
            d = min(step, ms - done)
            self.main.advance(d)
            self.mov.advance(d)
            self.pump_http()
            done += d

    def start(self):
        for d in (self.main, self.mov):
            d.call("OnDriverInit")
        self.main.call("OnDriverLateInit")
        self.mov.call("OnDriverLateInit")
        self.pump_http()

    def nav(self, command, seq, args=None, room=33, nav_id="nav-1"):
        args_xml = "<args>" + "".join(
            f'<arg name="{k}">{v}</arg>' for k, v in (args or {}).items()
        ) + "</args>"
        before = len(self.mov.proxy_messages)
        self.mov.call("ReceivedFromProxy", 5001, command, {"NAVID": nav_id, "SEQ": str(seq), "ROOMID": str(room), "ARGS": args_xml})
        for _ in range(5):
            self.pump_http()
        return [m for m in self.mov.proxy_messages[before:]]

    def data_for(self, seq):
        for b, c, p in reversed(self.mov.proxy_messages):
            if c == "DATA_RECEIVED" and str(p.get("SEQ")) == str(seq):
                return p
        return None
