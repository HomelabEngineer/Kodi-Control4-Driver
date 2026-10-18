#!/usr/bin/env python3
"""Generate kodi_movies/driver.xml.

The UI capability repeats near-identical screen blocks, so it is generated
rather than hand-maintained. Run from the repo root:  python3 tools/gen_movies_xml.py
"""
import os

NS = "kodi_os_movies"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "kodi_movies", "driver.xml")

ICON_SIZES = (20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 300)


def icon(name, size):
    return f"controller://driver/{NS}/icons/{name}_{size}.png"


def icon_group(gid, name, sizes=(70, 140, 300)):
    lines = [f'        <IconGroup id="{gid}">']
    for s in sizes:
        lines.append(f'          <Icon width="{s}" height="{s}">{icon(name, s)}</Icon>')
    lines.append("        </IconGroup>")
    return "\n".join(lines)


def param(name, ptype, value=None):
    v = f"<Value>{value}</Value>" if value is not None else ""
    return f"              <Param><Name>{name}</Name><Type>{ptype}</Type>{v}</Param>"


LIST_DEF = """          <List>
            <ItemDefaultActionProperty>default_action</ItemDefaultActionProperty>
            <ItemActionIdsProperty>actions_list</ItemActionIdsProperty>
            <TitleProperty>title</TitleProperty>
            <SubTitleProperty>subtitle</SubTitleProperty>
            <ImageProperty>image_list</ImageProperty>
            <LengthProperty>duration</LengthProperty>
            <IsLink><Property>isLink</Property><ValidValues><Value>true</Value></ValidValues></IsLink>
            <IsHeader><Property>isHeader</Property><ValidValues><Value>true</Value></ValidValues></IsHeader>
          </List>"""


def list_screen(sid, paged):
    params = [
        param("screenId", "SYSTEM", "screenId"),
        param("tabId", "SYSTEM", "tabId"),
        param("screenDepth", "SYSTEM", "screenDepth"),
        param("id", "FIRST_SELECTED", "id"),
        param("itemType", "FIRST_SELECTED", "itemType"),
    ]
    if paged:
        params += [param("start", "DATA_OFFSET"), param("count", "DATA_COUNT")]
    return f"""        <Screen xsi:type="ListScreenType">
          <Id>{sid}</Id>
          <DataCommand>
            <Name>Browse</Name>
            <Type>PROTOCOL</Type>
            <Params>
{chr(10).join(params)}
            </Params>
          </DataCommand>
          <RequiresRefresh>true</RequiresRefresh>
          <PaginationStyle>{"OFFSET" if paged else "NONE"}</PaginationStyle>
{LIST_DEF}
        </Screen>"""


DETAILS_SCREEN = """        <Screen xsi:type="DetailScreenType">
          <Id>DetailsScreen</Id>
          <DataCommand>
            <Name>GetDetails</Name>
            <Type>PROTOCOL</Type>
            <Params>
""" + "\n".join([
    param("screenId", "SYSTEM", "screenId"),
    param("tabId", "SYSTEM", "tabId"),
    param("id", "FIRST_SELECTED", "id"),
    param("itemType", "FIRST_SELECTED", "itemType"),
]) + """
            </Params>
          </DataCommand>
          <DefaultActionProperty>default_action</DefaultActionProperty>
          <TitleProperty>title</TitleProperty>
          <SubTitleProperty>subtitle</SubTitleProperty>
          <ImageProperty>image</ImageProperty>
          <AttributionImage>attribution_image</AttributionImage>
          <YearProperty>release_date</YearProperty>
          <RatingProperty>rating</RatingProperty>
          <LengthProperty>duration</LengthProperty>
          <Paragraph>
            <HeaderTxt>Plot</HeaderTxt>
            <ContentProperty>description</ContentProperty>
          </Paragraph>
        </Screen>"""


def action(aid, name, command, params=None, icon_id=None):
    p = ""
    if params:
        p = "\n            <Params>\n" + "\n".join(params) + "\n            </Params>"
    ic = f"\n          <IconId>{icon_id}</IconId>" if icon_id else ""
    return f"""        <Action>
          <Id>{aid}</Id>
          <Name>{name}</Name>{ic}
          <Command>
            <Name>{command}</Name>
            <Type>PROTOCOL</Type>{p}
          </Command>
        </Action>"""


ITEM_PARAMS = [
    param("screenId", "SYSTEM", "screenId"),
    param("tabId", "SYSTEM", "tabId"),
    param("id", "FIRST_SELECTED", "id"),
    param("itemType", "FIRST_SELECTED", "itemType"),
]

ACTIONS = [
    action("SelectItem", "Open", "SelectItem", ITEM_PARAMS),
    action("PlayMovie", "Play", "PlayMovie", ITEM_PARAMS, "act_play"),
    action("ResumeMovie", "Resume", "ResumeMovie", ITEM_PARAMS, "act_play"),
    action("RestartMovie", "Play From Beginning", "RestartMovie", ITEM_PARAMS, "act_restart"),
    action("ViewDetails", "Details", "ViewDetails", ITEM_PARAMS, "act_info"),
    action("MarkWatched", "Mark as Watched", "MarkWatched", ITEM_PARAMS, "act_watched"),
    action("MarkUnwatched", "Mark as Unwatched", "MarkUnwatched", ITEM_PARAMS, "act_watched"),
    action("RetryLoad", "Try Again", "RetryLoad", ITEM_PARAMS),
]

TABS = [
    ("Movies", "Movies", "tab_movies", "MoviesScreen"),
    ("Recent", "Recent", "tab_recent", "RecentScreen"),
    ("Continue", "Continue", "tab_continue", "ContinueScreen"),
    ("Genres", "Genres", "tab_genres", "GenresScreen"),
    ("More", "More", "tab_more", "MoreScreen"),
]


def tabs():
    out = ["      <Tabs>"]
    for tid, name, ic, sid in TABS:
        out.append(f"""        <Tab>
          <Id>{tid}</Id>
          <Name>{name}</Name>
          <IconId>{ic}</IconId>
          <ScreenId>{sid}</ScreenId>
        </Tab>""")
    out.append("      </Tabs>")
    return "\n".join(out)


def device_icons():
    return "\n".join(
        f'        <Icon width="{s}" height="{s}">{icon("device", s)}</Icon>' for s in ICON_SIZES
    )


def prop_list(name, items, default):
    its = "".join(f"<item>{i}</item>" for i in items)
    return f"""      <property>
        <name>{name}</name>
        <type>LIST</type>
        <default>{default}</default>
        <items>{its}</items>
      </property>"""


def prop_ro(name, default=""):
    return f"""      <property>
        <name>{name}</name>
        <type>STRING</type>
        <readonly>true</readonly>
        <default>{default}</default>
      </property>"""


PROPERTIES = "\n".join([
    prop_ro("Driver Version"),
    prop_ro("Kodi Player", "Not linked"),
    prop_ro("Library Status", "Not loaded"),
    prop_ro("Movie Count", "0"),
    prop_list("Movie Tap Action", ["Play Movie", "Show Details"], "Play Movie"),
    prop_list("Resume Behavior", ["Use Kodi Driver Setting", "Always Resume", "Always Start From Beginning"], "Use Kodi Driver Setting"),
    prop_list("Default Sort", ["Title", "Year (Newest First)", "Date Added (Newest First)", "Rating"], "Title"),
    prop_list("List Subtitle", ["Year, Runtime and Plot", "Year, Runtime and Genre", "Year and Runtime", "Plot", "Genre"], "Year, Runtime and Plot"),
    prop_list("Hide Watched Movies", ["OFF", "ON"], "OFF"),
    prop_list("Show Watched Marker", ["ON", "OFF"], "ON"),
    prop_list("Recently Added Count", ["25", "50", "100", "200"], "50"),
    prop_list("Details Image", ["Poster", "Fanart"], "Poster"),
    prop_list("Artwork Source", ["Internet When Available", "Kodi Web Server Only"], "Internet When Available"),
    prop_list("Send Kodi Login With Artwork", ["ON", "OFF"], "ON"),
    prop_list("Auto Refresh (minutes)", ["0", "30", "60", "180", "720"], "60"),
    prop_list("Debug Mode", ["OFF", "ON"], "OFF"),
])

XML = f"""<?xml version="1.0" encoding="UTF-8"?>
<devicedata>
  <copyright>Open Source (MIT License)</copyright>
  <creator>Open Source</creator>
  <manufacturer>Kodi</manufacturer>
  <name>Kodi Movies</name>
  <model>Kodi Movies (Open Source)</model>
  <created>10/18/2026 12:00 PM</created>
  <modified>10/18/2026 12:00 PM</modified>
  <version>100</version>
  <control>lua_gen</control>
  <driver>DriverWorks</driver>
  <minimum_os_version>3.1.0</minimum_os_version>
  <small image_source="c4z">icons/device_sm.png</small>
  <large image_source="c4z">icons/device_lg.png</large>
  <composer_categories>
    <category>media_player</category>
  </composer_categories>

  <proxies qty="1">
    <proxy proxybindingid="5001" name="Kodi Movies" image_source="c4z" small_image="icons/device_sm.png" large_image="icons/device_lg.png">media_service</proxy>
  </proxies>

  <capabilities>
    <hide_in_list_nav>False</hide_in_list_nav>
    <hide_in_media>True</hide_in_media>
    <digital_audio_support>False</digital_audio_support>
    <can_scan_media>False</can_scan_media>
    <media_type>2</media_type>
    <!-- Opening Kodi Movies only browses. The room is switched to Kodi when a movie is picked. -->
    <ui_selects_device>False</ui_selects_device>
    <list_nowplaying_non_c4>True</list_nowplaying_non_c4>
    <list_no_nowplaying>True</list_no_nowplaying>

    <navigator_display_option proxybindingid="5001">
      <display_icons>
{device_icons()}
      </display_icons>
    </navigator_display_option>

    <UI xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" proxybindingid="5001">
      <DeviceIcon>device</DeviceIcon>
      <BrandingIcon>branding</BrandingIcon>

      <Icons>
{icon_group("device", "device")}
{icon_group("branding", "branding")}
{icon_group("tab_movies", "tab_movies", (70, 140))}
{icon_group("tab_recent", "tab_recent", (70, 140))}
{icon_group("tab_continue", "tab_continue", (70, 140))}
{icon_group("tab_genres", "tab_genres", (70, 140))}
{icon_group("tab_more", "tab_more", (70, 140))}
{icon_group("act_play", "act_play", (70, 140))}
{icon_group("act_restart", "act_restart", (70, 140))}
{icon_group("act_info", "act_info", (70, 140))}
{icon_group("act_watched", "act_watched", (70, 140))}
      </Icons>

{tabs()}

      <Screens>
{list_screen("MoviesScreen", True)}
{list_screen("RecentScreen", False)}
{list_screen("ContinueScreen", False)}
{list_screen("GenresScreen", False)}
{list_screen("MoreScreen", False)}
{list_screen("BrowseScreen", True)}
{DETAILS_SCREEN}
      </Screens>

      <NowPlaying>
        <List>
          <ItemDefaultActionProperty>default_action</ItemDefaultActionProperty>
          <ItemActionIdsProperty>actions_list</ItemActionIdsProperty>
          <TitleProperty>title</TitleProperty>
          <SubTitleProperty>subtitle</SubTitleProperty>
          <ImageProperty>image_list</ImageProperty>
          <LengthProperty>duration</LengthProperty>
          <IsHeader><Property>isHeader</Property><ValidValues><Value>true</Value></ValidValues></IsHeader>
        </List>
      </NowPlaying>

      <Actions>
{chr(10).join(ACTIONS)}
      </Actions>
    </UI>
  </capabilities>

  <connections>
    <connection>
      <id>5001</id>
      <facing>6</facing>
      <type>2</type>
      <connectionname>Kodi Movies</connectionname>
      <consumer>False</consumer>
      <audiosource>False</audiosource>
      <videosource>False</videosource>
      <linelevel>False</linelevel>
      <classes>
        <class><classname>MediaService</classname></class>
      </classes>
    </connection>
    <!--
      Route to the room through the Kodi driver's virtual switcher, the same way
      shipping media services bind into their player's virtual amp. These
      autobind when both drivers are in the project.
    -->
    <connection proxybindingid="5001">
      <id>1</id>
      <facing>6</facing>
      <type>1</type>
      <connectionname>Kodi Movies Link</connectionname>
      <consumer>False</consumer>
      <audiosource>False</audiosource>
      <videosource>False</videosource>
      <linelevel>False</linelevel>
      <idautobind>73103</idautobind>
      <classes>
        <class><classname>LINK_OSKODI_MOVIES</classname><autobind>True</autobind></class>
      </classes>
    </connection>
    <connection proxybindingid="5001">
      <id>2001</id>
      <type>5</type>
      <connectionname>Kodi Movies AV</connectionname>
      <consumer>False</consumer>
      <linelevel>False</linelevel>
      <idautobind>73104</idautobind>
      <classes>
        <class><classname>RF_OSKODI_MOVIES</classname><autobind>True</autobind></class>
      </classes>
    </connection>
    <!-- Driver-to-driver control link to the Kodi player driver. -->
    <connection>
      <id>3900</id>
      <facing>6</facing>
      <type>1</type>
      <connectionname>Kodi Player</connectionname>
      <consumer>True</consumer>
      <linelevel>False</linelevel>
      <idautobind>73105</idautobind>
      <classes>
        <class><classname>OSKODI_PLAYER_LINK</classname><autobind>True</autobind></class>
      </classes>
    </connection>
  </connections>

  <config>
    <documentation file="www/documentation.html"/>
    <script file="driver.lua"/>

    <actions>
      <action><name>Refresh Library</name><command>RefreshLibrary</command></action>
      <action><name>Re-link to Kodi Player</name><command>Relink</command></action>
    </actions>

    <events>
      <event><id>1</id><name>Movie Selected</name><description>A movie was picked to play from a Navigator or Halo</description></event>
    </events>

    <properties>
{PROPERTIES}
    </properties>
  </config>
</devicedata>
"""

with open(OUT, "w", encoding="utf-8") as f:
    f.write(XML)
print("wrote", OUT)
