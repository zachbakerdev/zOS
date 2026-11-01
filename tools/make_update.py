#!/usr/bin/env python3
"""Build everything a GitHub release publishes, and that computers update themselves from.

    dist/zos.zi                the system image, from ./package
    dist/zos-update.manifest   the version, size and SHA-256 of zos.zi
    dist/apps/<id>.za          every app in apps/
    dist/zos-apps.manifest     the version, size and SHA-256 of each .za
    dist/install.lua           the installer

    python3 tools/make_update.py

The manifests are described in specs/libs/UPDATE.md. Every file is minified (see minify_lua.py)
unless you pass --no-minify.
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys

from make_apps import ROOT, find_apps, pack, read_version
from minify_lua import minify

FORMAT_VERSION = 1
DEFAULT_OUT_DIR = os.path.join(ROOT, "dist")


def build_manifest(version, image):
    sha256 = hashlib.sha256(image).hexdigest()
    return f"zos-update {FORMAT_VERSION}\nversion={version}\nsize={len(image)}\nsha256={sha256}\nend\n".encode("ascii")


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


def write(path, data):
    with open(path, "wb") as f:
        f.write(data)
    print(f"Wrote {os.path.relpath(path)}: {len(data) / 1000:.1f} KB")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-o", "--output-dir", default=DEFAULT_OUT_DIR, help="where to write the files (default: dist/)")
    parser.add_argument("--no-minify", action="store_true", help="keep the files' comments and indentation")
    args = parser.parse_args()

    version = read_version()
    # Emptied first, so that an app that's been removed can't be published by accident.
    apps_dir = os.path.join(args.output_dir, "apps")
    shutil.rmtree(apps_dir, ignore_errors=True)
    os.makedirs(apps_dir)

    zi = os.path.join(args.output_dir, "zos.zi")
    subprocess.run([os.path.join(ROOT, "package"), "-o", zi] + (["--no-minify"] if args.no_minify else []), check=True)
    with open(zi, "rb") as f:
        write(os.path.join(args.output_dir, "zos-update.manifest"), build_manifest(version, f.read()))

    packages = []
    for app in find_apps():
        manifest, _, text = pack(app, not args.no_minify)
        packages.append((app, manifest, text))
        write(os.path.join(apps_dir, f"{app['id']}.za"), text.encode("ascii"))
    write(os.path.join(args.output_dir, "zos-apps.manifest"), build_apps_manifest(version, packages))

    with open(os.path.join(ROOT, "install.lua"), "rb") as f:
        installer = f.read()
    write(os.path.join(args.output_dir, "install.lua"), installer if args.no_minify else minify("install.lua", installer))


if __name__ == "__main__":
    main()
