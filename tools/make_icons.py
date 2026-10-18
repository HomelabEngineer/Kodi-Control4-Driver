#!/usr/bin/env python3
"""Generate original icon sets for both drivers (Pillow only).

Artwork is drawn here from simple shapes so it can be published freely; it is
deliberately not the Kodi logo.

    python3 tools/make_icons.py
"""
import math
import os

from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SS = 8

DEVICE_SIZES = (20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 300)

PLAYER_TOP = (23, 166, 226)     # sky blue
PLAYER_BOTTOM = (16, 74, 140)   # deep blue
MOVIES_TOP = (240, 120, 60)     # warm orange
MOVIES_BOTTOM = (176, 40, 76)   # cranberry
WHITE = (255, 255, 255, 255)
GLYPH = (236, 240, 244, 255)


def gradient_tile(size, top, bottom, radius_frac=0.22):
    n = size * SS
    grad = Image.new("RGBA", (n, n))
    px = grad.load()
    for y in range(n):
        t = y / max(1, n - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(n):
            px[x, y] = c
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, n - 1, n - 1], radius=int(n * radius_frac), fill=255)
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    return out


def finish(img, size):
    return img.resize((size, size), Image.LANCZOS)


# ------------------------------------------------------------------ glyphs
# Each glyph draws into a square canvas of side n, white strokes.

def g_play(d, n, color=WHITE):
    cx, cy = n * 0.54, n * 0.5
    r = n * 0.26
    pts = [(cx - r * 0.75, cy - r), (cx - r * 0.75, cy + r), (cx + r, cy)]
    d.polygon(pts, fill=color)


def g_tv_play(d, n):
    w = int(n * 0.05)
    d.rounded_rectangle([n * 0.18, n * 0.24, n * 0.82, n * 0.70], radius=n * 0.06, outline=WHITE, width=w)
    d.line([n * 0.40, n * 0.80, n * 0.60, n * 0.80], fill=WHITE, width=w)
    d.line([n * 0.5, n * 0.70, n * 0.5, n * 0.80], fill=WHITE, width=w)
    cx, cy, r = n * 0.515, n * 0.47, n * 0.12
    d.polygon([(cx - r * 0.7, cy - r), (cx - r * 0.7, cy + r), (cx + r, cy)], fill=WHITE)


def g_clapper(d, n):
    w = int(n * 0.05)
    # board
    d.rounded_rectangle([n * 0.20, n * 0.42, n * 0.80, n * 0.78], radius=n * 0.05, outline=WHITE, width=w)
    # clapper arm (tilted)
    ang = math.radians(-14)
    x0, y0 = n * 0.20, n * 0.40
    length, height = n * 0.62, n * 0.12

    def rot(px, py):
        return (x0 + px * math.cos(ang) - py * math.sin(ang), y0 + px * math.sin(ang) + py * math.cos(ang))

    arm = [rot(0, 0), rot(length, 0), rot(length, -height), rot(0, -height)]
    d.polygon(arm, outline=WHITE, width=w)
    for i in range(1, 4):
        a = rot(length * i / 4.0 - n * 0.04, 0)
        b = rot(length * i / 4.0 + n * 0.04, -height)
        d.line([a, b], fill=WHITE, width=w)
    # play triangle on board
    cx, cy, r = n * 0.52, n * 0.60, n * 0.09
    d.polygon([(cx - r * 0.7, cy - r), (cx - r * 0.7, cy + r), (cx + r, cy)], fill=WHITE)


def g_film(d, n, color=GLYPH):
    w = max(2, int(n * 0.06))
    d.rounded_rectangle([n * 0.22, n * 0.18, n * 0.78, n * 0.82], radius=n * 0.05, outline=color, width=w)
    d.line([n * 0.36, n * 0.18, n * 0.36, n * 0.82], fill=color, width=w)
    d.line([n * 0.64, n * 0.18, n * 0.64, n * 0.82], fill=color, width=w)
    for y in (0.32, 0.5, 0.68):
        d.line([n * 0.22, n * y, n * 0.36, n * y], fill=color, width=w)
        d.line([n * 0.64, n * y, n * 0.78, n * y], fill=color, width=w)


def g_clock(d, n, color=GLYPH):
    w = max(2, int(n * 0.06))
    d.ellipse([n * 0.2, n * 0.2, n * 0.8, n * 0.8], outline=color, width=w)
    d.line([n * 0.5, n * 0.5, n * 0.5, n * 0.32], fill=color, width=w)
    d.line([n * 0.5, n * 0.5, n * 0.64, n * 0.58], fill=color, width=w)


def g_continue(d, n, color=GLYPH):
    w = max(2, int(n * 0.06))
    d.arc([n * 0.2, n * 0.2, n * 0.8, n * 0.8], start=-90, end=180, fill=color, width=w)
    cx, cy, r = n * 0.53, n * 0.5, n * 0.12
    d.polygon([(cx - r * 0.7, cy - r), (cx - r * 0.7, cy + r), (cx + r, cy)], fill=color)


def g_tag(d, n, color=GLYPH):
    w = max(2, int(n * 0.06))
    pts = [(n * 0.22, n * 0.22), (n * 0.52, n * 0.22), (n * 0.80, n * 0.50), (n * 0.52, n * 0.78), (n * 0.22, n * 0.48)]
    d.line(pts + [pts[0]], fill=color, width=w, joint="curve")
    r = n * 0.05
    d.ellipse([n * 0.34 - r, n * 0.34 - r, n * 0.34 + r, n * 0.34 + r], fill=color)


def g_more(d, n, color=GLYPH):
    r = n * 0.07
    for x in (0.28, 0.5, 0.72):
        d.ellipse([n * x - r, n * 0.5 - r, n * x + r, n * 0.5 + r], fill=color)


def g_restart(d, n, color=GLYPH):
    w = max(2, int(n * 0.06))
    d.arc([n * 0.22, n * 0.22, n * 0.78, n * 0.78], start=-60, end=240, fill=color, width=w)
    # arrow head at the arc start (top right)
    ax, ay = n * 0.5 + n * 0.28 * math.cos(math.radians(-60)), n * 0.5 + n * 0.28 * math.sin(math.radians(-60))
    s = n * 0.11
    d.polygon([(ax - s, ay - s * 0.2), (ax + s * 0.5, ay - s * 0.9), (ax + s * 0.4, ay + s * 0.6)], fill=color)


def g_info(d, n, color=GLYPH):
    w = max(2, int(n * 0.06))
    d.ellipse([n * 0.2, n * 0.2, n * 0.8, n * 0.8], outline=color, width=w)
    r = n * 0.045
    d.ellipse([n * 0.5 - r, n * 0.34 - r, n * 0.5 + r, n * 0.34 + r], fill=color)
    d.line([n * 0.5, n * 0.45, n * 0.5, n * 0.66], fill=color, width=w)


def g_check(d, n, color=GLYPH):
    w = max(2, int(n * 0.08))
    d.line([(n * 0.24, n * 0.52), (n * 0.42, n * 0.70), (n * 0.78, n * 0.32)], fill=color, width=w, joint="curve")


def glyph_icon(fn, size):
    n = size * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    fn(ImageDraw.Draw(img), n)
    return finish(img, size)


def tile_icon(size, top, bottom, glyph):
    img = gradient_tile(size, top, bottom)
    glyph(ImageDraw.Draw(img), size * SS)
    return finish(img, size)


def write(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)


def build_player():
    base = os.path.join(ROOT, "kodi_player", "www", "icons")
    for s in DEVICE_SIZES:
        write(tile_icon(s, PLAYER_TOP, PLAYER_BOTTOM, g_tv_play), os.path.join(base, f"device_{s}.png"))
    write(tile_icon(16, PLAYER_TOP, PLAYER_BOTTOM, g_tv_play), os.path.join(base, "device_sm.png"))
    write(tile_icon(32, PLAYER_TOP, PLAYER_BOTTOM, g_tv_play), os.path.join(base, "device_lg.png"))


def build_movies():
    base = os.path.join(ROOT, "kodi_movies", "www", "icons")
    for s in DEVICE_SIZES:
        write(tile_icon(s, MOVIES_TOP, MOVIES_BOTTOM, g_clapper), os.path.join(base, f"device_{s}.png"))
    for s in (70, 140, 300):
        write(tile_icon(s, MOVIES_TOP, MOVIES_BOTTOM, g_clapper), os.path.join(base, f"branding_{s}.png"))
    write(tile_icon(16, MOVIES_TOP, MOVIES_BOTTOM, g_clapper), os.path.join(base, "device_sm.png"))
    write(tile_icon(32, MOVIES_TOP, MOVIES_BOTTOM, g_clapper), os.path.join(base, "device_lg.png"))

    glyphs = {
        "tab_movies": g_film,
        "tab_recent": g_clock,
        "tab_continue": g_continue,
        "tab_genres": g_tag,
        "tab_more": g_more,
        "act_play": lambda d, n: g_play(d, n, GLYPH),
        "act_restart": g_restart,
        "act_info": g_info,
        "act_watched": g_check,
    }
    for name, fn in glyphs.items():
        for s in (70, 140, 300):
            write(glyph_icon(fn, s), os.path.join(base, f"{name}_{s}.png"))

    # Row tiles: list rows sit on light or dark themes, so they get a solid tile.
    for name in ("tab_movies", "tab_recent", "tab_continue", "tab_genres", "tab_more"):
        fn = glyphs[name]
        row = name.replace("tab_", "row_")
        for s in (70, 140, 300):
            write(tile_icon(s, MOVIES_TOP, MOVIES_BOTTOM, lambda d, n, fn=fn: fn(d, n, WHITE)), os.path.join(base, f"{row}_{s}.png"))


if __name__ == "__main__":
    build_player()
    build_movies()
    print("icons written")
