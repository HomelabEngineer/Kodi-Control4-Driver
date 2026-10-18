# Kodi for Control4 — Player + Movies

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Control4 OS](https://img.shields.io/badge/Control4%20OS-3.1%2B-orange.svg)
![Kodi](https://img.shields.io/badge/Kodi-19%2B-17b2e7.svg)

Two open-source Control4 drivers for [Kodi](https://kodi.tv):

- **Kodi** — an IP control driver for the Kodi box, with full remote/D-pad control, live playback status and AV connections.
- **Kodi Movies** — a media service that shows your Kodi movie library on Control4 Navigators and Halo remotes, with posters, titles and plots. Pick a movie and the room turns on with Kodi as the source, then the movie starts playing automatically.

The main driver extends [bmrowe/Kodi-Control4-Driver](https://github.com/bmrowe/Kodi-Control4-Driver). See [References](#references) for everything this project builds on.

---

## Contents

- [Features](#features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Programming](#programming)
- [Troubleshooting](#troubleshooting)
- [Building from source](#building-from-source)
- [Project layout](#project-layout)
- [Status and known limitations](#status-and-known-limitations)
- [References](#references)
- [License](#license)

---

## Features

### Kodi (`kodi_os_player.c4z`)

Everything from the original bmrowe driver:

- Real-time control over Kodi's JSON-RPC WebSocket (port 9090), with automatic reconnect
- Play, pause, stop, skip, scan, and press-and-hold directional repeat
- **PM4K** and **Kodi** playback directional modes
- Configurable Red/Green/Yellow/Blue program buttons
- Live Player State, Media Type, and video/audio details (resolution, aspect, codec, HDR, audio format)
- Auto Room On / Auto Room Off

Added in this version:

- **Virtual switcher** that owns the HDMI output, so the media player and Kodi Movies share one physical connection to the TV/AVR
- **Library link** that receives play requests from Kodi Movies, turns the room on, and starts the movie
- Programming **events**: Playback Started, Paused, Resumed, Stopped, Ended, Library Movie Launched
- Programming **commands**: Kodi Action, Show Notification, Open Movies Library, Scan Video Library
- New startup options (Open Movies Library, Do Nothing), Stop Playback When Room Turns Off
- Now Playing title and Kodi version properties
- Library change notifications forwarded to Kodi Movies (watched state, resume points, scans, removals)

### Kodi Movies (`kodi_os_movies.c4z`)

- Works on Control4 touchscreens, the Control4 app and **Halo** remotes
- Tabs: **Movies** · **Recent** · **Continue** · **Genres** · **More** (Unwatched, Collections, By Year, Top Rated, Surprise Me, All Movies)
- Every row shows the **poster**, **title**, and a subtitle with year, runtime and the start of the plot (configurable)
- **Details screen**: poster or fanart, year, rating and certification, runtime, genres, director, tagline, full plot, resume position
- Item actions: **Play**, **Resume**, **Play From Beginning**, **Details**, **Mark as Watched/Unwatched**
- **One tap to watch**: the room switches to Kodi, the TV/AVR power up, and the movie starts
- Paged lists so large libraries stay responsive
- TMDB artwork loaded directly from TMDB at Halo-friendly sizes (works away from home); other artwork served by Kodi's web server
- Library stays current live, with an optional periodic refresh

---

## How it works

```
  Navigator / Halo
        │  browse, tap a movie
        ▼
  ┌───────────────┐   OSKODI_PLAY_MOVIE    ┌──────────────────┐
  │  Kodi Movies  │ ─────────────────────► │       Kodi       │
  │ media_service │ ◄───────────────────── │   media_player   │
  └───────┬───────┘  config, library       └────────┬─────────┘
          │          change notifications           │
          │ HTTP JSON-RPC :8080                      │ 1. room: SELECT_VIDEO_DEVICE
          │ (library + artwork)                      │    (TV/AVR power on, input switch)
          ▼                                          │ 2. WebSocket :9090: Player.Open
     ┌─────────┐ ◄──────────────────────────────────-┘
     │ Kodi box │
     └─────────┘

  Kodi Movies ──Link / AV──►  Kodi Virtual Switcher  ──HDMI OUTPUT──►  TV / AVR
  Kodi (player) ───────────►  (internal, autobinds)
```

1. Kodi Movies reads the library over Kodi's HTTP JSON-RPC and caches it on the controller.
2. When a movie is tapped, Kodi Movies sends the movie ID and the Navigator's room to the Kodi driver over a driver-to-driver control link.
3. The Kodi driver selects Kodi as that room's video source. Control4 powers the TV/AVR and switches inputs as it normally would.
4. While the launch is pending, the room's `ON` command does not send Kodi Home or start PM4K, so nothing races the movie.
5. After a configurable settle delay (skipped if the room is already on Kodi) and once the WebSocket is connected, the driver calls `Player.Open` with the movie and the chosen resume behavior.
6. If Kodi doesn't respond within the timeout, the Navigator is told the movie couldn't start.

A `media_service` proxy has no route to a room on its own; it has to bind into a device that owns an AV path. The hidden virtual switcher provides that path, following the topology documented in the [JRiver driver's design notes](https://github.com/luminationlabs/control4-jriver/blob/main/DESIGN.md) and Snap One's MSP driver suite.

---

## Requirements

- Control4 OS **3.1** or later (the details screen needs 3.1)
- Kodi **19 (Matrix)** or later
- Kodi web server enabled and reachable from the controller (and, for local artwork, from each Navigator)

---

## Installation

### 1. Kodi

Settings → Services → Control:

- **Allow remote control via HTTP** — on (note the port, username and password)
- **Allow remote control from applications on other systems** — on

Give the Kodi box a fixed IP (DHCP reservation).

### 2. Kodi driver

1. Composer Pro → add `kodi_os_player.c4z`. Two devices appear: **Kodi** and **Kodi Virtual Switcher**.
2. Set **IP Address**, **Kodi HTTP Port**, **Kodi Username** and **Kodi Password**.
3. Connections → bind **Kodi Virtual Switcher → HDMI OUTPUT** to the TV or AVR input Kodi is plugged into.
4. Add the room's video endpoints as usual so **Kodi** appears under Watch.

> Upgrading from the bmrowe driver: the HDMI output has moved from the media player to the virtual switcher. Rebind it there.

### 3. Kodi Movies driver

1. Add `kodi_os_movies.c4z`. Its three connections autobind to the Kodi driver.
2. If the **Kodi Player** property says *Not linked*, bind manually in Connections:
   - **Kodi Movies → Kodi Player** → Kodi **Kodi Library Control**
   - **Kodi Movies Link** and **Kodi Movies AV** → the **Kodi Virtual Switcher** inputs of the same names
3. Refresh Navigators.

> Keep the `.c4z` filenames unchanged. Composer derives each driver's icon namespace (`controller://driver/<name>/…`) from the package filename.

---

## Configuration

### Kodi driver

| Property | Default | Notes |
|---|---|---|
| IP Address | — | Kodi box address |
| Kodi WebSocket Port | 9090 | Control and notifications |
| Kodi HTTP Port / Username / Password | 8080 / kodi / — | Passed to Kodi Movies for library and artwork |
| Playback Directionals | PM4K | Kodi mode: Up/Down ±10 min, Left/Right ±10 s, Enter = OSD |
| Startup Action on ON | Kodi Home | Kodi Home, Open Movies Library, Launch PM4K, Do Nothing |
| Skip Interval (seconds) | 30 | <30 small step, 30–599 step, ≥600 big step |
| Program A–D Buttons | No Operation | Codec info, OSD, subtitles, audio track, context menu, Movies library, screenshot… |
| Auto Room On / Off | OFF | Turn the room on/off when video starts/stops on Kodi |
| Stop Playback When Room Turns Off | OFF | |
| Turn Room On When Playing From Library | ON | Select Kodi in the Navigator's room before playing |
| Play Delay After Room On (seconds) | 4 | Lets the TV/AVR settle before playback |
| Library Play Timeout (seconds) | 90 | How long to wait for Kodi to be reachable |
| Resume Behavior | Resume Where Left Off | Default for Kodi Movies' *Play* |
| Debug Mode | OFF | |

Read-only: Driver Version, WebSocket Status, Kodi Version, Library Link, Player State, Now Playing, Media Type, Video Details, Audio Details.

### Kodi Movies driver

| Property | Default | Notes |
|---|---|---|
| Movie Tap Action | Play Movie | Or Show Details |
| Resume Behavior | Use Kodi Driver Setting | Always Resume, Always Start From Beginning |
| Default Sort | Title | Year, Date Added, Rating |
| List Subtitle | Year, Runtime and Plot | Year/Runtime/Genre, Year/Runtime, Plot, Genre |
| Hide Watched Movies | OFF | Movies tab only |
| Show Watched Marker | ON | |
| Recently Added Count | 50 | 25–200 |
| Details Image | Poster | Or Fanart |
| Artwork Source | Internet When Available | Or Kodi Web Server Only |
| Send Kodi Login With Artwork | ON | For Kodi installs that require a login |
| Auto Refresh (minutes) | 60 | 0 disables |
| Debug Mode | OFF | |

Read-only: Driver Version, Kodi Player, Library Status, Movie Count.

---

## Programming

**Kodi driver**

- Events: `Playback Started`, `Playback Paused`, `Playback Resumed`, `Playback Stopped`, `Playback Ended`, `Library Movie Launched`
- Commands: `Kodi Action` (any [Kodi action](https://kodi.wiki/view/Action_IDs) name, e.g. `osd`), `Show Notification`, `Open Movies Library`, `Scan Video Library`
- Actions: Reconnect WebSocket, Disconnect WebSocket, Scan Kodi Video Library, Refresh Linked Kodi Movies

**Kodi Movies driver**

- Event: `Movie Selected`
- Variable: `LAST_MOVIE_SELECTED`
- Actions: Refresh Library, Re-link to Kodi Player

Example: *When Kodi → Playback Started, dim the theater lights to 10%. When Playback Stopped, raise them to 60%.*

---

## Troubleshooting

| Symptom | Check |
|---|---|
| WebSocket Status stays *Disconnected* | IP address, Kodi running, "applications on other systems" enabled, port 9090 open |
| Library Status shows *HTTP 401* | Web server username/password on the Kodi driver |
| Posters missing | Each Navigator loads artwork itself. For local/NAS artwork (or *Kodi Web Server Only*), every touchscreen, phone and Halo must reach Kodi's web server |
| Kodi Movies says *Not linked* | Bind the three connections (see Installation §3) |
| Kodi Movies not shown in a room | Link/AV bindings to the virtual switcher, and Kodi is a video source in that room |
| Room turns on but the movie doesn't start | Increase *Play Delay After Room On*; check *Library Play Timeout* |

Turn on **Debug Mode** on both drivers and watch Composer's Lua output.

---

## Building from source

```bash
pip install lupa lxml pillow
python3 build.py              # regenerate UI XML + icons, run tests, package dist/*.c4z
python3 build.py --no-test    # package only
python3 tests/test_drivers.py # tests only
```

The test suite runs both drivers in Lua 5.1 (via [lupa](https://github.com/scoder/lupa)) against a stubbed Control4 API, a fake Kodi HTTP server with a 600-movie fixture, and a fake WebSocket. It covers paging, every tab and drill-down, the details screen, artwork URLs, the room-on → `Player.Open` launch sequence (including Kodi being offline and timing out), library change propagation, error/retry states, transport forwarding and the virtual switcher.

The build also checks that every `controller://` asset in each `driver.xml` exists, that the asset namespace matches the package filename, and that connection IDs are unique.

---

## Project layout

```
kodi_player/                  Kodi driver
  driver.xml                  proxies, connections, properties, events, commands
  driver.lua                  WebSocket lifecycle, proxy dispatch, virtual switcher
  library_bridge.lua          link to Kodi Movies: config push, room-on + Player.Open
  commands.lua                media_player command handlers
  notifications.lua           Kodi notifications → status, events, library changes
  kodi_rpc.lua, av_details.lua, c4_utils.lua
  drivers-common-public/      Snap One helper library (WebSocket, handlers, JSON)
  www/                        documentation + icons
kodi_movies/                  Kodi Movies driver
  driver.xml                  generated by tools/gen_movies_xml.py
  driver.lua                  Navigator UI, link, library loading
  library.lua                 in-memory library, indexes and queries
  artwork.lua                 TMDB / Kodi web server artwork URLs
  kodi_http.lua               HTTP JSON-RPC client
  www/                        documentation + icons
tools/                        gen_movies_xml.py, make_icons.py
tests/                        harness.py, test_drivers.py
build.py                      tests + validation + packaging
```

### Inter-driver protocol

Messages travel with `C4:SendToDevice` over the `OSKODI_PLAYER_LINK` control binding (ID 3900) and arrive in `ExecuteCommand`.

| Direction | Command | Parameters |
|---|---|---|
| Movies → Kodi | `OSKODI_REGISTER` | `DEVICE_ID` |
| Movies → Kodi | `OSKODI_PLAY_MOVIE` | `MOVIE_ID`, `ROOM_ID`, `RESUME` (`1`/`0`/empty), `TITLE` |
| Movies → Kodi | `OSKODI_TRANSPORT` | `CMD` |
| Kodi → Movies | `OSKODI_CONFIG` | `HOST`, `HTTP_PORT`, `USERNAME`, `PASSWORD`, `WS_CONNECTED`, `PLAYER_DEVICE_ID`, `PLAYER_NAME` |
| Kodi → Movies | `OSKODI_LIBRARY_CHANGED` | `KIND` (`update`/`remove`/`scan`), `MOVIE_ID` |
| Kodi → Movies | `OSKODI_PLAY_RESULT` | `MOVIE_ID`, `OK`, `ERROR` |

A future Kodi TV Shows driver can use the same link.

---

## Status and known limitations

Built against Snap One's MSP documentation and samples and the hardware-verified JRiver media service driver, and tested in a simulated Control4 runtime. **Not yet validated on a controller.** Please confirm and report:

- Kodi Movies appearing under **Watch** in rooms with Kodi
- OFFSET paging and the details screen rendering on **Halo**
- Cross-driver autobind of the three connections

Other limitations:

- Movies only (no TV shows or music yet)
- No on-screen search; use Genres, Collections, By Year or sorting instead
- Local/NAS artwork requires every Navigator to reach Kodi's web server

---

## References

This project builds on, adapts or follows the documentation of:

| Source | Used for |
|---|---|
| [bmrowe/Kodi-Control4-Driver](https://github.com/bmrowe/Kodi-Control4-Driver) (MIT) | The base of the Kodi driver: WebSocket connection lifecycle, JSON-RPC client (`kodi_rpc.lua`), AV details (`av_details.lua`), command and notification handlers, PM4K/Kodi directionals, program buttons, Auto Room On/Off |
| [luminationlabs/control4-jriver](https://github.com/luminationlabs/control4-jriver) and its [DESIGN.md](https://github.com/luminationlabs/control4-jriver/blob/main/DESIGN.md) | Hardware-verified patterns: `media_service` routed through a virtual `avswitch`, link/RF connection topology, hiding the switcher from rooms, `SET_INPUT` acknowledgement, transport capabilities, image list format, asset namespace = package filename |
| [Snap One — DriverWorks documentation](https://github.com/snap-one/docs-driverworks) | Media Service Proxy: *MSP Driver Development Documentation OS 3.2.1* (screens, `DetailScreenType`, `OFFSET` pagination, `NextScreen`/`RefreshScreen`, capabilities such as `ui_selects_device`), the *MSP By Numbers* samples and the *MSP driver suite* (cross-driver service → player binding) |
| [Control4 DriverWorks Proxy & Protocol Guide](https://control4.github.io/docs-driverworks-proxyprotocol/) | Media player proxy commands and capabilities |
| Snap One `drivers-common-public` (bundled in the bmrowe repository) | WebSocket client, handler dispatch, timers, metrics |
| [Kodi JSON-RPC API](https://kodi.wiki/view/JSON-RPC_API) | `VideoLibrary.GetMovies`/`GetMovieDetails`/`SetMovieDetails`, `Player.Open` with resume, `GUI.ActivateWindow`, `GUI.ShowNotification`, library notifications |
| [Kodi web interface / image URLs](https://kodi.wiki/view/Web_interface) | Serving artwork through `/image/<encoded image:// path>` |
| [TMDB image basics](https://developer.themoviedb.org/docs/image-basics) | Resizing poster/fanart URLs (`w342`, `w500`, `w780`) |
| [JSON.lua](http://regex.info/blog/lua/json) by Jeffrey Friedl (CC-BY 3.0) | JSON encoding (keeps Lua arrays as JSON arrays) |
| [lupa](https://github.com/scoder/lupa) | Running the drivers in Lua 5.1 for the test suite |

Icons are original artwork generated by `tools/make_icons.py`.

Kodi is a trademark of the XBMC Foundation. Control4 and Halo are trademarks of Snap One, LLC. This project is not affiliated with or endorsed by either.

---

## License

[MIT](LICENSE). Portions © 2025 bmrowe (MIT). Third-party components are listed in [NOTICE.md](NOTICE.md).
