#!/usr/bin/env python3
"""Pack each app in apps/ into a .za file that the zOS App Manager installs.

An app's source is a folder, apps/<id>/, holding:

    app.manifest    { name = "Notes", description = "...", version = "1.0.0", priority = 10, minZos = "1.0.0" }
    main.lua        the program the desktop runs
    service.lua     optional: started at boot to run in the background
    ...             any other files the app needs (modules, data)

Each one becomes dist/apps/<id>.za, as described in specs/formats/ZA_FORMAT.md:

    { ["za:metadata"] = { version = 1, id = "<id>" }, ["main.lua"] = "...", ... }

To get them into the game:

    python3 tools/make_apps.py                  # writes dist/apps/<id>.za for every app
    python3 tools/make_apps.py notes calc       # or only these
    python3 tools/make_apps.py --upload         # also uploads each .za to Pastebin (needs PASTEBIN_DEV_KEY)

Then copy a .za onto a floppy for App Manager's "Install from disk", or use "Install from URL or
Pastebin" with a paste code.

Lua files and manifests are minified (see minify_lua.py) unless you pass --no-minify.
"""

import argparse
import os
import re
import sys
import urllib.parse
import urllib.request

from minify_lua import minify_files

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPS = os.path.join(ROOT, "apps")
DEFAULT_OUT_DIR = os.path.join(ROOT, "dist", "apps")

FORMAT_VERSION = 1
ID_PATTERN = re.compile(r"^[a-z0-9_-]{1,32}$")
MAX_PATH = 128
# Major.minor.patch, and nothing else. Must match versionParts in src/.zos/lib/apps.lua.
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
# Must match validPath in src/.zos/lib/apps.lua.
PATH_PART = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9_.-]*$")

class ManifestError(Exception):
    pass


def read_version():
    with open(os.path.join(ROOT, "src", ".zos", "lib", "system.lua"), encoding="ascii") as f:
        for line in f:
            if line.strip().startswith("VERSION = "):
                version = line.split('"')[1]
                if not VERSION.fullmatch(version):
                    sys.exit(f"system.VERSION must be major.minor.patch, like 1.0.0, not {version}")
                return version
    sys.exit("src/.zos/lib/system.lua has no VERSION")


def collect_files(root):
    """Every file under root, as (posix path relative to root, bytes), sorted by path."""
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            if name.startswith("."):
                continue
            full = os.path.join(dirpath, name)
            with open(full, "rb") as f:
                files.append((os.path.relpath(full, root).replace(os.sep, "/"), f.read()))
    files.sort()
    return files


def lua_string(data):
    """A double-quoted Lua string for these bytes, in printable ASCII only."""
    out = ['"']
    for byte in data:
        char = chr(byte)
        if char in '"\\':
            out.append("\\" + char)
        elif 0x20 <= byte <= 0x7E:
            out.append(char)
        else:
            out.append("\\%03d" % byte)  # always 3 digits, so a following digit isn't absorbed
    out.append('"')
    return "".join(out)


def upload(text, name, dev_key, public):
    """Upload to Pastebin and return the paste's code."""
    body = urllib.parse.urlencode({
        "api_dev_key": dev_key,
        "api_option": "paste",
        "api_paste_code": text,
        "api_paste_name": name,
        "api_paste_format": "lua",
        "api_paste_private": "0" if public else "1",  # 1 = unlisted
    }).encode()
    with urllib.request.urlopen("https://pastebin.com/api/api_post.php", body, timeout=60) as resp:
        result = resp.read().decode().strip()
    if not result.startswith("http"):
        sys.exit(f"Pastebin upload failed: {result}")
    return result.rsplit("/", 1)[-1]


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
        raise ManifestError("must be a table, like { name = \"My App\", version = \"1.0.0\" }")
    if not isinstance(m.get("name"), str) or not m["name"].strip():
        raise ManifestError("needs a name, like name = \"My App\"")
    if not isinstance(m.get("version"), str) or not VERSION.fullmatch(m["version"]):
        raise ManifestError("needs a major.minor.patch version, like version = \"1.0.0\" (in quotes)")
    for key in ("description", "author"):
        if key in m and not isinstance(m[key], str):
            raise ManifestError(f"{key} must be a string")
    if "priority" in m and (isinstance(m["priority"], bool) or not isinstance(m["priority"], (int, float))):
        raise ManifestError("priority must be a number")
    if "minZos" in m and (not isinstance(m["minZos"], str) or not VERSION.fullmatch(m["minZos"])):
        raise ManifestError("minZos must be a major.minor.patch version, like minZos = \"2.1.0\" (in quotes)")


def version_key(version):
    """Compares like apps.compareVersions in lib/apps.lua."""
    return [int(n) for n in version.split(".")]


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
    """Read and check the app at app["path"]. Returns (manifest, files, .za text) or exits.

    With minify, the .za holds minified files."""
    def fail(message):
        sys.exit(f"apps/{app['id']}: {message}")

    if not ID_PATTERN.match(app["id"]) or app["id"] == "zos":
        fail("folder name must be 1-32 lowercase letters, digits, - or _ (it becomes the app id)")

    files = collect_files(app["path"])
    names = {path for path, _ in files}
    for path in names:
        if len(path.encode()) > MAX_PATH or not all(PATH_PART.match(part) for part in path.split("/")):
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
    if version_key(manifest.get("minZos", "0.0.0")) > version_key(read_version()):
        fail(f"app.manifest: needs zOS {manifest['minZos']}, but this is zOS {read_version()}")

    packed = minify_files(files) if minify else files

    out = ["{", f'  ["za:metadata"] = {{ version = {FORMAT_VERSION}, id = {lua_string(app["id"].encode())} }},']
    out += [f"  [{lua_string(path.encode())}] = {lua_string(data)}," for path, data in packed]
    out.append("}")
    return manifest, files, "\n".join(out) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("apps", nargs="*", metavar="app", help="ids of the apps to pack (default: all)")
    parser.add_argument("-o", "--output-dir", default=DEFAULT_OUT_DIR, help="where to write the .za files (default: dist/apps/)")
    parser.add_argument("--upload", action="store_true", help="also upload each .za to Pastebin (needs PASTEBIN_DEV_KEY)")
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
    for app in apps:
        manifest, files, text = pack(app, not args.no_minify)
        out = os.path.join(args.output_dir, f"{app['id']}.za")
        with open(out, "w", encoding="ascii", newline="\n") as f:
            f.write(text)
        service = ", with a service" if any(path == "service.lua" for path, _ in files) else ""
        print(f"Wrote {os.path.relpath(out)}: {manifest['name']} {manifest['version']}, "
              f"{len(files)} files{service}, {len(text) / 1024:.1f} KB")
        if args.upload:
            code = upload(text, f"zOS app: {manifest['name']} {manifest['version']}", dev_key, args.public)
            print(f"  Uploaded to https://pastebin.com/{code}  (App Manager > Install from URL or Pastebin: {code})")


if __name__ == "__main__":
    main()
