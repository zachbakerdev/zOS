#!/bin/sh
# Builds everything into dist/: the app packages, the app disk writer and the setup disk writer.
# Options are passed to both scripts, e.g. ./build.sh --no-minify (or --upload, --public).
set -e
cd "$(dirname "$0")"

python3 tools/make_apps.py --disk "$@"
python3 tools/make_disk.py "$@"
