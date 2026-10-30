#!/usr/bin/env python3
"""Pack zOS into the files that computers update themselves from.

    dist/zos-update.bundle     a serialised Lua table of the system files and every app
    dist/zos-update.manifest   the version, size and SHA-256 of the bundle
    dist/apps/<id>.app         the apps, for App Manager
    dist/zos-apps.manifest     the version, size and SHA-256 of each .app

    python3 tools/make_update.py

Lua files are minified (see minify_lua.py) unless you pass --no-minify.
"""

import argparse
import hashlib
import os
import sys

from make_apps import find_apps, pack
from make_disk import DISK, ROOT, collect_files, lua_string, read_version
from minify_lua import minify_files

FORMAT_VERSION = 1
DEFAULT_OUT_DIR = os.path.join(ROOT, "dist")


def build_bundle(version, minify, packages):
    files = collect_files(os.path.join(DISK, "payload"))
    if minify:
        files = minify_files(files)
    out = [
        "{",
        '  format = "zos-update",',
        f"  formatVersion = {FORMAT_VERSION},",
        f"  version = {lua_string(version.encode())},",
        "  files = {",
    ]
    out += [f"    [{lua_string(path.encode())}] = {lua_string(data)}," for path, data in files]
    out += ["  },", "  apps = {"]
    for app, _, text in packages:
        out.append(f"    [{lua_string(app['id'].encode())}] = {lua_string(text.encode())},")
    out += ["  },", "}"]
    return ("\n".join(out) + "\n").encode("ascii")


def build_manifest(version, bundle):
    sha256 = hashlib.sha256(bundle).hexdigest()
    return f"zos-update {FORMAT_VERSION}\nversion={version}\nsize={len(bundle)}\nsha256={sha256}\nend\n".encode("ascii")


def build_apps_manifest(version, packages):
    """The list of apps. lib/update.lua splits each line on tabs."""
    lines = [f"zos-apps {FORMAT_VERSION}", f"release={version}"]
    for app, manifest, text in packages:
        data = text.encode("ascii")
        fields = [app["id"], manifest["version"], str(len(data)), hashlib.sha256(data).hexdigest(),
                  manifest.get("minZos", ""), manifest["name"], manifest.get("description", "")]
        if any(c in field for field in fields for c in "\t\n"):
            sys.exit(f"apps/{app['id']}: app.manifest can't have tabs or line breaks in these fields")
        lines.append("app=" + "\t".join(fields))
    return ("\n".join(lines) + "\nend\n").encode("utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-o", "--output-dir", default=DEFAULT_OUT_DIR, help="where to write the files (default: dist/)")
    parser.add_argument("--no-minify", action="store_true", help="keep the Lua files' comments and indentation")
    args = parser.parse_args()

    version = read_version()
    packages = []
    for app in find_apps():
        manifest, _, text = pack(app, not args.no_minify)
        packages.append((app, manifest, text))
    bundle = build_bundle(version, not args.no_minify, packages)

    # Written here so the .app files on the release are the ones the list describes.
    os.makedirs(os.path.join(args.output_dir, "apps"), exist_ok=True)
    for app, _, text in packages:
        with open(os.path.join(args.output_dir, "apps", f"{app['id']}.app"), "w", encoding="ascii", newline="\n") as f:
            f.write(text)
    out = os.path.join(args.output_dir, "zos-update.bundle")
    with open(out, "wb") as f:
        f.write(bundle)
    print(f"Wrote {os.path.relpath(out)}: zOS {version}, {len(bundle) / 1024:.0f} KB")

    out = os.path.join(args.output_dir, "zos-update.manifest")
    with open(out, "wb") as f:
        f.write(build_manifest(version, bundle))
    print(f"Wrote {os.path.relpath(out)}")
    out = os.path.join(args.output_dir, "zos-apps.manifest")
    with open(out, "wb") as f:
        f.write(build_apps_manifest(version, packages))
    print(f"Wrote {os.path.relpath(out)}: {len(packages)} apps")


if __name__ == "__main__":
    main()
