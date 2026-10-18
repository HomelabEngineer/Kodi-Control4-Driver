#!/usr/bin/env python3
"""Build both drivers into dist/.

    python3 build.py            # regenerate Movies driver.xml + icons, test, package
    python3 build.py --no-test  # skip the Lua test suite

Package filenames are NOT versioned: Composer derives a driver's asset namespace
(controller://driver/<name>/...) from the .c4z filename, so a renamed package
loses its icons. The version lives in each driver.xml <version>.
"""
import os
import re
import subprocess
import sys
import zipfile

from lxml import etree

ROOT = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(ROOT, "dist")

DRIVERS = [
    ("kodi_player", "kodi_os_player.c4z"),
    ("kodi_movies", "kodi_os_movies.c4z"),
]

SKIP = {".DS_Store", "__pycache__"}


def check_driver(folder, package):
    namespace = package[:-4]
    xml_path = os.path.join(folder, "driver.xml")
    tree = etree.parse(xml_path)  # raises on malformed XML
    text = open(xml_path, encoding="utf-8").read()

    problems = []
    for ref in sorted(set(re.findall(r"controller://driver/([^/]+)/([^<\"]+)", text))):
        ns, rel = ref
        if ns != namespace:
            problems.append(f"asset namespace {ns!r} does not match package {namespace!r}")
        if not os.path.exists(os.path.join(folder, "www", rel)):
            problems.append(f"missing asset www/{rel}")
    for tag in ("small", "large"):
        el = tree.find(tag)
        if el is not None and not os.path.exists(os.path.join(folder, "www", el.text)):
            problems.append(f"missing {tag} icon www/{el.text}")
    script = tree.find("config/script")
    if script is None or not os.path.exists(os.path.join(folder, script.get("file"))):
        problems.append("missing driver script")
    doc = tree.find("config/documentation")
    if doc is not None and not os.path.exists(os.path.join(folder, doc.get("file"))):
        problems.append("missing documentation file")
    ids = [c.findtext("id") for c in tree.findall("connections/connection")]
    dupes = {i for i in ids if ids.count(i) > 1}
    if dupes:
        problems.append(f"duplicate connection ids {sorted(dupes)}")
    return problems


def package(folder, name):
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, name)
    if os.path.exists(out):
        os.remove(out)
    count = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for base, dirs, files in os.walk(folder):
            dirs[:] = sorted(d for d in dirs if d not in SKIP)
            for f in sorted(files):
                if f in SKIP:
                    continue
                full = os.path.join(base, f)
                arc = os.path.relpath(full, folder).replace(os.sep, "/")
                z.write(full, arc)
                count += 1
    return out, count


def main():
    subprocess.check_call([sys.executable, os.path.join(ROOT, "tools", "gen_movies_xml.py")])
    subprocess.check_call([sys.executable, os.path.join(ROOT, "tools", "make_icons.py")])

    if "--no-test" not in sys.argv:
        subprocess.check_call([sys.executable, os.path.join(ROOT, "tests", "test_drivers.py")])

    failed = False
    for sub, name in DRIVERS:
        folder = os.path.join(ROOT, sub)
        problems = check_driver(folder, name)
        if problems:
            failed = True
            for p in problems:
                print(f"[{sub}] {p}")
            continue
        out, count = package(folder, name)
        print(f"built {os.path.relpath(out, ROOT)} ({count} files, {os.path.getsize(out) // 1024} KB)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
