#!/usr/bin/env python3
"""Pack each app in apps/ into a .app file that the zOS App Manager installs.

An app's source is a folder, apps/<id>/, holding:

    app.manifest    { name = "Notes", description = "...", version = "1.0", priority = 10, minZos = "2.1" }
    main.lua        the program the desktop runs
    service.lua     optional: started at boot to run in the background
    ...             any other files the app needs (modules, data)

Each one becomes dist/apps/<id>.app, a single serialised Lua table holding every file:

    { format = "zos-app", formatVersion = 1, id = "<id>", files = { ["main.lua"] = "...", ... } }

To get them into the game:

    python3 tools/make_apps.py                  # writes dist/apps/<id>.app for every app
    python3 tools/make_apps.py notes calc       # or only these
    python3 tools/make_apps.py --disk           # also dist/zos-apps-disk.lua, which writes them onto a floppy
    python3 tools/make_apps.py --upload         # also uploads each .app to Pastebin (needs PASTEBIN_DEV_KEY)

Then use App Manager's "Install from disk" with that floppy, or "Install from URL or Pastebin"
with a paste code.

Lua files are minified (see minify_lua.py) unless you pass --no-minify.
"""

import argparse
import datetime
import os
import re
import sys

from make_disk import PASTEBIN_LIMIT, ROOT, build, collect_files, lua_string, read_version, upload, usage_lines
from minify_lua import minify_files

APPS = os.path.join(ROOT, "apps")
DEFAULT_OUT_DIR = os.path.join(ROOT, "dist", "apps")
DISK_OUT = os.path.join(ROOT, "dist", "zos-apps-disk.lua")

FORMAT_VERSION = 1
ID_PATTERN = re.compile(r"^[a-z0-9_-]{1,32}$")
MIN_ZOS = re.compile(r"^\d[\d.]*$")
# Must match validPath in disk/payload/zos/lib/apps.lua.
PATH_PART = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9_.-]*$")

DISK_FINISH = r"""
print("App disk ready" .. (DRIVE and (" and labelled \"" .. LABEL .. "\"") or "") .. ".")
print("Put it in a drive next to a zOS computer and open")
print("App Manager > Install from disk.")
"""


class ManifestError(Exception):
    pass


def parse_lua_value(text):
    """Parse the Lua table literal in an app.manifest: tables, strings, numbers, booleans."""
    pos = 0

    def skip():
        nonlocal pos
        while pos < len(text):
            if text[pos].isspace():
                pos += 1
            elif text.startswith("--[[", pos):
                end = text.find("]]", pos)
                pos = len(text) if end < 0 else end + 2
            elif text.startswith("--", pos):
                end = text.find("\n", pos)
                pos = len(text) if end < 0 else end + 1
            else:
                return

    def fail(what):
        line = text.count("\n", 0, pos) + 1
        raise ManifestError(f"line {line}: {what}")

    def string():
        nonlocal pos
        quote = text[pos]
        pos += 1
        out = []
        escapes = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}
        while pos < len(text) and text[pos] != quote:
            c = text[pos]
            if c == "\n":
                fail("unfinished string")
            if c == "\\":
                pos += 1
                digits = re.match(r"\d{1,3}", text[pos:])
                if digits:
                    out.append(chr(int(digits.group())))
                    pos += len(digits.group())
                    continue
                if pos >= len(text) or text[pos] not in escapes:
                    fail("unsupported escape in string")
                c = escapes[text[pos]]
            out.append(c)
            pos += 1
        if pos >= len(text):
            fail("unfinished string")
        pos += 1
        return "".join(out)

    def value():
        nonlocal pos
        skip()
        if pos >= len(text):
            fail("expected a value")
        c = text[pos]
        if c == "{":
            return table()
        if c in "\"'":
            return string()
        number = re.match(r"-?(0x[0-9a-fA-F]+|\d+\.?\d*(e-?\d+)?|\.\d+)", text[pos:])
        if number:
            pos += len(number.group())
            s = number.group()
            return int(s, 16) if "x" in s else (float(s) if any(ch in s for ch in ".e") else int(s))
        for word, result in (("true", True), ("false", False), ("nil", None)):
            if re.match(word + r"\b", text[pos:]):
                pos += len(word)
                return result
        fail("expected a value")

    def table():
        nonlocal pos
        pos += 1
        result, index = {}, 1
        while True:
            skip()
            if pos < len(text) and text[pos] == "}":
                pos += 1
                return result
            key = re.match(r"([A-Za-z_]\w*)\s*=(?!=)", text[pos:])
            if key:
                pos += len(key.group())
                result[key.group(1)] = value()
            elif text.startswith("[", pos):
                pos += 1
                k = value()
                skip()
                if not text.startswith("]", pos):
                    fail("expected ]")
                pos += 1
                skip()
                if not text.startswith("=", pos):
                    fail("expected =")
                pos += 1
                result[k] = value()
            else:
                result[index] = value()
                index += 1
            skip()
            if pos < len(text) and text[pos] in ",;":
                pos += 1
            elif pos < len(text) and text[pos] == "}":
                continue
            else:
                fail("expected , or }")

    result = value()
    skip()
    if pos != len(text):
        fail("unexpected text after the table")
    return result


def check_manifest(m):
    """Raise ManifestError unless m is a valid manifest. Must match checkManifest in lib/apps.lua."""
    if not isinstance(m, dict):
        raise ManifestError("must be a table, like { name = \"My App\", version = \"1.0\" }")
    if not isinstance(m.get("name"), str) or not m["name"].strip():
        raise ManifestError("needs a name, like name = \"My App\"")
    if not isinstance(m.get("version"), str) or not m["version"].strip():
        raise ManifestError("needs a version string, like version = \"1.0\" (in quotes)")
    for key in ("description", "author"):
        if key in m and not isinstance(m[key], str):
            raise ManifestError(f"{key} must be a string")
    if "priority" in m and (isinstance(m["priority"], bool) or not isinstance(m["priority"], (int, float))):
        raise ManifestError("priority must be a number")
    if "minZos" in m and (not isinstance(m["minZos"], str) or not MIN_ZOS.match(m["minZos"])):
        raise ManifestError("minZos must be a version string, like minZos = \"2.1\" (in quotes)")


def version_key(version):
    """Compares like apps.compareVersions in lib/apps.lua, where missing numbers count as 0."""
    numbers = [int(n) for n in re.findall(r"\d+", version)]
    while numbers and numbers[-1] == 0:
        numbers.pop()
    return numbers


def find_apps():
    """Every apps/<id>/ with an app.manifest, as dicts sorted by id."""
    found = []
    if not os.path.isdir(APPS):
        return found
    for app_id in sorted(os.listdir(APPS)):
        path = os.path.join(APPS, app_id)
        if app_id.startswith(".") or not os.path.isfile(os.path.join(path, "app.manifest")):
            continue
        found.append({"id": app_id, "path": path})
    return found


def pack(app, minify=True):
    """Read and check the app at app["path"]. Returns (manifest, files, .app text) or exits.

    With minify, the .app holds minified Lua files."""
    def fail(message):
        sys.exit(f"apps/{app['id']}: {message}")

    if not ID_PATTERN.match(app["id"]):
        fail("folder name must be 1-32 lowercase letters, digits, - or _ (it becomes the app id)")

    files = collect_files(app["path"])
    names = {path for path, _ in files}
    for path in names:
        if not all(PATH_PART.match(part) for part in path.split("/")):
            fail(f"bad file name '{path}' (use letters, digits, ., - and _)")
    if "main.lua" not in names:
        fail("has no main.lua")

    manifest_text = dict(files)["app.manifest"].decode("utf-8")
    try:
        manifest = parse_lua_value(manifest_text)
        check_manifest(manifest)
    except ManifestError as e:
        fail(f"app.manifest: {e}")
    # It ships with this version of zOS, so nothing could ever install it.
    if version_key(manifest.get("minZos", "0")) > version_key(read_version()):
        fail(f"app.manifest: needs zOS {manifest['minZos']}, but this is zOS {read_version()}")

    packed = minify_files(files) if minify else files

    out = [
        "{",
        '  format = "zos-app",',
        f"  formatVersion = {FORMAT_VERSION},",
        f"  id = {lua_string(app['id'].encode())},",
        "  files = {",
    ]
    for path, data in packed:
        out.append(f"    [{lua_string(path.encode())}] = {lua_string(data)},")
    out += ["  },", "}"]
    return manifest, files, "\n".join(out) + "\n"


def build_disk(packages):
    today = datetime.date.today().isoformat()
    header = [
        f"zOS app disk writer. Generated by tools/make_apps.py on {today}.",
        "Writes these apps onto a floppy, which App Manager installs them from:",
    ] + [f"  {m['name']} {m['version']}" for _, m, _ in packages] + [""] + usage_lines("zos-apps-disk")
    files = [(f"{app['id']}.app", text.encode()) for app, _, text in packages]
    return build(files, title="zOS app disk writer", label="zOS Apps", header=header, finish=DISK_FINISH)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("apps", nargs="*", metavar="app", help="ids of the apps to pack (default: all)")
    parser.add_argument("-o", "--output-dir", default=DEFAULT_OUT_DIR, help="where to write the .app files (default: dist/apps/)")
    parser.add_argument("--disk", action="store_true", help="also write dist/zos-apps-disk.lua, which writes the apps onto a floppy")
    parser.add_argument("--upload", action="store_true", help="also upload each .app to Pastebin (needs PASTEBIN_DEV_KEY)")
    parser.add_argument("--public", action="store_true", help="with --upload: make the pastes public instead of unlisted")
    parser.add_argument("--no-minify", action="store_true", help="keep the Lua files' comments and indentation")
    args = parser.parse_args()

    apps = find_apps()
    if args.apps:
        unknown = set(args.apps) - {app["id"] for app in apps}
        if unknown:
            sys.exit(f"Unknown app(s): {', '.join(sorted(unknown))}. "
                     f"Available: {', '.join(app['id'] for app in apps) or '(none)'}")
        apps = [app for app in apps if app["id"] in args.apps]
    if not apps:
        sys.exit(f"No apps found in {os.path.relpath(APPS)}")

    dev_key = os.environ.get("PASTEBIN_DEV_KEY")
    if args.upload and not dev_key:
        sys.exit("Set PASTEBIN_DEV_KEY to your Pastebin API key (https://pastebin.com/doc_api).")

    os.makedirs(args.output_dir, exist_ok=True)
    packages = []
    for app in apps:
        manifest, files, text = pack(app, not args.no_minify)
        packages.append((app, manifest, text))
        out = os.path.join(args.output_dir, f"{app['id']}.app")
        with open(out, "w", encoding="ascii", newline="\n") as f:
            f.write(text)
        service = ", with a service" if any(path == "service.lua" for path, _ in files) else ""
        print(f"Wrote {os.path.relpath(out)}: {manifest['name']} {manifest['version']}, "
              f"{len(files)} files{service}, {len(text) / 1024:.1f} KB")
        if args.upload:
            code = upload(text, f"zOS app: {manifest['name']} {manifest['version']}", dev_key, args.public)
            print(f"  Uploaded to https://pastebin.com/{code}  (App Manager > Install from URL or Pastebin: {code})")

    if args.disk:
        text = build_disk(packages)
        os.makedirs(os.path.dirname(DISK_OUT), exist_ok=True)
        with open(DISK_OUT, "w", encoding="ascii", newline="\n") as f:
            f.write(text)
        print(f"Wrote {os.path.relpath(DISK_OUT)}: {len(packages)} apps, {len(text) / 1024:.0f} KB program")
        if len(text) > PASTEBIN_LIMIT:
            print(f"  Warning: that's over Pastebin's {PASTEBIN_LIMIT // 1024} KB limit for free accounts.")


if __name__ == "__main__":
    main()
