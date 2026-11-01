#!/bin/sh
# Builds everything a release publishes into dist/. See tools/make_update.py.
# Options are passed on, e.g. ./build.sh --no-minify.
set -e
cd "$(dirname "$0")"

python3 tools/make_update.py "$@"
