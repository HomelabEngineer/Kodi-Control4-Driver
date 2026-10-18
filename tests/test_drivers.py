"""End-to-end tests for both drivers in a stubbed Control4 runtime.

    python3 -m pytest -q tests/        (or: python3 tests/test_drivers.py)
"""
import os
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(__file__))
from harness import World, make_movies  # noqa: E402


def parse(data):
    return ET.fromstring(data)


def started_world(**kw):
    w = World(**kw)
    w.start()
    w.advance(500)
    return w


def connect_ws(w):
    assert w.ws is not None, "main driver never created a websocket"
    w.ws.Establish(w.ws)
    # answer the initial GetActivePlayers / Application.GetProperties
    for req in w.ws_requests():
        if req["method"] == "Player.GetActivePlayers":
            w.ws_reply(req, [])
        elif req["method"] == "Application.GetProperties":
            w.ws_reply(req, {"name": "Kodi", "version": {"major": 21, "minor": 1, "tag": "stable"}})


# ----------------------------------------------------------------- library/link

def test_link_and_library_load_paginates():
    w = started_world()
    pages = [r for _, r, _ in w.http_log if r["method"] == "VideoLibrary.GetMovies"]
    assert [p["params"]["limits"]["start"] for p in pages] == [0, 250, 500]
    assert w.mov.properties_log["Movie Count"] == "600"
    assert w.main.properties_log["Library Link"].startswith("Linked")
    # Basic auth goes on the library request
    _, _, headers = w.http_log[0]
    assert headers["Authorization"].startswith("Basic ")
    # properties array is a JSON array, not an object
    assert isinstance(pages[0]["params"]["properties"], list)


def test_movies_tab_offset_paging_and_artwork():
    w = started_world()
    w.nav("Browse", 10, {"screenId": "MoviesScreen", "tabId": "Movies", "start": 0, "count": 40})
    d = w.data_for(10)
    root = parse(d["DATA"])
    assert root.tag == "List" and root.get("length") == "600"
    items = root.findall("item")
    assert len(items) == 40
    first = items[0]
    # "The Movie 0007" sorts under M, not T; first title is Movie 0001
    assert first.findtext("title").startswith("Movie 0001")
    assert first.findtext("default_action") == "PlayMovie"
    assert "ViewDetails" in first.findtext("actions_list")
    imgs = first.findall("image_list")
    assert imgs and imgs[0].text.startswith("https://image.tmdb.org/t/p/w342/poster")
    assert imgs[0].get("width") == "342"
    # plot snippet in the subtitle, BBCode stripped, escaped & survives
    sub = first.findtext("subtitle")
    assert "Plot for movie" in sub and "[B]" not in sub
    assert "&" in first.findtext("title") and "<Cut>" in first.findtext("title")

    w.nav("Browse", 11, {"screenId": "MoviesScreen", "start": 580, "count": 40})
    root = parse(w.data_for(11)["DATA"])
    assert len(root.findall("item")) == 20


def test_other_tabs_and_drilldowns():
    w = started_world()
    w.nav("Browse", 1, {"screenId": "RecentScreen", "tabId": "Recent"})
    assert len(parse(w.data_for(1)["DATA"]).findall("item")) == 50

    w.nav("Browse", 2, {"screenId": "ContinueScreen", "tabId": "Continue"})
    cont = parse(w.data_for(2)["DATA"]).findall("item")
    assert len(cont) == len([m for m in make_movies() if m["movieid"] % 11 == 0])
    assert "left" in cont[0].findtext("subtitle")
    assert "ResumeMovie" in cont[0].findtext("actions_list")

    w.nav("Browse", 3, {"screenId": "GenresScreen", "tabId": "Genres"})
    genres = parse(w.data_for(3)["DATA"]).findall("item")
    names = [g.findtext("title") for g in genres]
    assert "Action" in names and names == sorted(names, key=str.lower)
    assert genres[0].findtext("isLink") == "true"
    gid = genres[0].findtext("id")

    w.nav("SelectItem", 4, {"screenId": "GenresScreen", "id": gid, "itemType": "link"})
    assert w.data_for(4)["DATA"] == "<NextScreen>BrowseScreen</NextScreen>"

    w.nav("Browse", 5, {"screenId": "BrowseScreen", "id": gid, "itemType": "link", "start": 0, "count": 500})
    root = parse(w.data_for(5)["DATA"])
    assert int(root.get("length")) > 0 and root.findall("item")[0].findtext("itemType") == "movie"

    w.nav("Browse", 6, {"screenId": "MoreScreen", "tabId": "More"})
    more = [i.findtext("id") for i in parse(w.data_for(6)["DATA"]).findall("item")]
    assert more == ["unwatched", "sets", "years", "toprated", "random", "all"]

    w.nav("Browse", 7, {"screenId": "BrowseScreen", "id": "sets", "itemType": "link", "start": 0, "count": 100})
    sets = parse(w.data_for(7)["DATA"]).findall("item")
    assert len(sets) == 5 and sets[0].findtext("id").startswith("set:")
    w.nav("Browse", 8, {"screenId": "BrowseScreen", "id": sets[0].findtext("id"), "itemType": "link", "start": 0, "count": 100})
    saga = parse(w.data_for(8)["DATA"]).findall("item")
    years = [int(i.findtext("subtitle")[:4]) for i in saga]
    assert years == sorted(years)

    w.nav("Browse", 9, {"screenId": "BrowseScreen", "id": "years", "itemType": "link", "start": 0, "count": 100})
    yrs = [i.findtext("title") for i in parse(w.data_for(9)["DATA"]).findall("item")]
    assert yrs == sorted(yrs, reverse=True)


def test_details_screen():
    w = started_world()
    w.nav("ViewDetails", 20, {"id": "22", "itemType": "movie"})
    assert w.data_for(20)["DATA"] == "<NextScreen>DetailsScreen</NextScreen>"
    w.nav("GetDetails", 21, {"screenId": "DetailsScreen", "id": "22", "itemType": "movie"})
    root = parse(w.data_for(21)["DATA"])
    assert root.tag == "Details"
    assert root.findtext("id") == "22"
    assert root.findtext("image").startswith("https://image.tmdb.org/t/p/w500/poster22")
    assert root.findtext("release_date") == str(1980 + 22 % 45)
    assert "Stopped at" in root.findtext("description")   # 22 % 11 == 0 -> in progress
    assert root.findtext("default_action") == "PlayMovie"
    assert root.findtext("rating").startswith("★")


def test_fanart_from_nas_uses_kodi_web_server():
    w = started_world(movies_props={"Details Image": "Fanart"})
    w.nav("GetDetails", 30, {"id": "5", "itemType": "movie"})
    img = parse(w.data_for(30)["DATA"]).findtext("image")
    assert img.startswith("http://kodi:secret@10.0.0.50:8080/image/image%3A%2F%2Fsmb")


def test_kodi_only_artwork_mode():
    w = started_world(movies_props={"Artwork Source": "Kodi Web Server Only", "Send Kodi Login With Artwork": "OFF"})
    w.nav("Browse", 31, {"screenId": "MoviesScreen", "start": 0, "count": 1})
    img = parse(w.data_for(31)["DATA"]).find("item/image_list").text
    assert img.startswith("http://10.0.0.50:8080/image/image%3A%2F%2Fhttps%253a")


# ----------------------------------------------------------------- play flow

def test_play_turns_room_on_then_opens_movie():
    w = started_world()
    w.nav("PlayMovie", 40, {"id": "42", "itemType": "movie"}, room=34)
    assert w.data_for(40)["DATA"] == ""

    # Movies -> Kodi driver
    play = [r for r in w.routed if r[2] == "OSKODI_PLAY_MOVIE"]
    assert play and play[-1][3]["MOVIE_ID"] == "42" and play[-1][3]["ROOM_ID"] == "34"
    # Kodi driver -> room 34: select the media player proxy as the video source
    sel = [r for r in w.routed if r[2] == "SELECT_VIDEO_DEVICE"]
    assert sel and sel[-1][1] == 34 and sel[-1][3]["deviceid"] == World.PLAYER_PROXY_ID

    # the room turns the device on; ON must not send Kodi Home during a launch
    connect_ws(w)
    w.main.call("ReceivedFromProxy", 5001, "ON", {})
    assert not w.ws_requests("Input.Home")

    w.advance(3000)
    assert not w.ws_requests("Player.Open"), "opened before the play delay elapsed"
    w.advance(1500)
    opens = w.ws_requests("Player.Open")
    assert len(opens) == 1
    assert opens[0]["params"] == {"item": {"movieid": 42}, "options": {"resume": True}}

    w.ws_reply(opens[0], "OK")
    res = [r for r in w.routed if r[2] == "OSKODI_PLAY_RESULT"]
    assert res and res[-1][3]["OK"] == "1"
    assert "Library Movie Launched" in w.main.events

    # Later ON (after the guard) behaves normally again
    w.advance(31000)
    w.main.call("ReceivedFromProxy", 5001, "ON", {})
    assert w.ws_requests("Input.Home")


def test_play_waits_for_kodi_to_come_online():
    w = started_world()
    w.nav("RestartMovie", 41, {"id": "7", "itemType": "movie"}, room=33)
    w.advance(10000)
    assert not w.ws_requests("Player.Open")       # websocket still down
    connect_ws(w)
    w.advance(2500)
    opens = w.ws_requests("Player.Open")
    assert len(opens) == 1 and opens[0]["params"]["options"]["resume"] is False


def test_play_when_already_watching_is_quick():
    w = started_world()
    connect_ws(w)
    w.main.call("ReceivedFromProxy", 5001, "ON", {})   # room already on Kodi
    w.nav("ResumeMovie", 42, {"id": "11", "itemType": "movie"})
    w.advance(500)
    opens = w.ws_requests("Player.Open")
    assert len(opens) == 1 and opens[0]["params"]["options"]["resume"] is True


def test_play_gives_up_and_reports():
    w = started_world(main_props={"Library Play Timeout (seconds)": "15"})
    w.nav("PlayMovie", 43, {"id": "3", "itemType": "movie"})
    w.advance(20000)
    res = [r for r in w.routed if r[2] == "OSKODI_PLAY_RESULT"]
    assert res and res[-1][3]["OK"] == "0"
    notes = [p for b, c, p in w.mov.proxy_messages if c == "SEND_EVENT" and p.get("NAME") == "DriverNotification"]
    assert notes and "start Movie 0003" in notes[-1]["EVTARGS"]


def test_room_off_setting_and_turn_room_on_off():
    w = started_world(main_props={"Turn Room On When Playing From Library": "OFF"})
    connect_ws(w)
    w.nav("PlayMovie", 44, {"id": "9", "itemType": "movie"})
    assert not [r for r in w.routed if r[2] == "SELECT_VIDEO_DEVICE"]
    w.advance(500)
    assert w.ws_requests("Player.Open")


# ----------------------------------------------------------------- library updates

def test_library_update_notifications_flow_to_movies_driver():
    w = started_world()
    connect_ws(w)
    before = len(w.http_log)
    w.ws_notify("VideoLibrary.OnUpdate", {"item": {"id": 15, "type": "movie"}, "playcount": 1})
    w.pump_http()
    reqs = [r for _, r, _ in w.http_log[before:]]
    assert reqs and reqs[0]["method"] == "VideoLibrary.GetMovieDetails" and reqs[0]["params"]["movieid"] == 15

    w.ws_notify("VideoLibrary.OnRemove", {"id": 16, "type": "movie"})
    assert w.mov.properties_log["Movie Count"] == "599"

    before = len(w.http_log)
    w.ws_notify("VideoLibrary.OnScanFinished", None)
    w.advance(16000)
    assert any(r["method"] == "VideoLibrary.GetMovies" for _, r, _ in w.http_log[before:])


def test_mark_watched_refreshes_screen():
    w = started_world()
    w.nav("MarkWatched", 50, {"id": "1", "itemType": "movie"})
    assert w.data_for(50)["DATA"] == "<RefreshScreen>true</RefreshScreen>"
    sets = [r for _, r, _ in w.http_log if r["method"] == "VideoLibrary.SetMovieDetails"]
    assert sets[-1]["params"] == {"movieid": 1, "playcount": 1}


# ----------------------------------------------------------------- failure states

def test_not_linked_shows_guidance():
    w = started_world(linked=False)
    w.nav("Browse", 60, {"screenId": "MoviesScreen", "start": 0, "count": 50})
    root = parse(w.data_for(60)["DATA"])
    assert "Not linked" in root.findall("item")[0].findtext("title")


def test_http_error_then_retry():
    w = World()
    w.http_fail = 401
    w.start()
    w.advance(200)
    assert "401" in w.mov.properties_log["Library Status"]
    w.nav("Browse", 70, {"screenId": "MoviesScreen", "start": 0, "count": 10})
    items = parse(w.data_for(70)["DATA"]).findall("item")
    assert items[1].findtext("default_action") == "RetryLoad"
    w.http_fail = None
    w.advance(61000)          # automatic retry after an error
    assert w.mov.properties_log["Movie Count"] == "600"


def test_transport_forwarding_and_tap_details_mode():
    w = started_world(movies_props={"Movie Tap Action": "Show Details"})
    connect_ws(w)
    w.nav("Browse", 80, {"screenId": "MoviesScreen", "start": 0, "count": 1})
    assert parse(w.data_for(80)["DATA"]).find("item").findtext("default_action") == "ViewDetails"
    w.mov.call("ReceivedFromProxy", 5001, "PAUSE", {"ROOM_ID": "33"})
    assert w.ws_requests("Input.ExecuteAction")[-1]["params"] == {"action": "pause"}


def test_main_driver_programming_commands():
    w = started_world()
    connect_ws(w)
    w.main.call("ExecuteCommand", "Open Movies Library", {})
    req = w.ws_requests("GUI.ActivateWindow")[-1]
    assert req["params"]["parameters"] == ["videodb://movies/titles/"]
    w.main.call("ExecuteCommand", "LUA_ACTION", {"ACTION": "ACTION_ScanVideoLibrary"})
    assert w.ws_requests("VideoLibrary.Scan")
    w.main.call("ExecuteCommand", "Show Notification", {"Title": "Door", "Message": "Someone is here", "Seconds": "4"})
    assert w.ws_requests("GUI.ShowNotification")[-1]["params"]["displaytime"] == 4000


def test_switcher_acknowledges_input():
    w = started_world()
    w.main.call("ReceivedFromProxy", 5002, "SET_INPUT", {"INPUT": "1001", "OUTPUT": "2000"})
    cmds = [c for b, c, p in w.main.proxy_messages if b == 5002]
    assert cmds[-2:] == ["INPUT_CHANGED", "INPUT_OUTPUT_CHANGED"]


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print("PASS", name)
            except Exception as e:  # noqa: BLE001
                failures += 1
                import traceback
                print("FAIL", name)
                traceback.print_exc()
    print("failures:", failures)
    sys.exit(1 if failures else 0)
