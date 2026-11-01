#!/usr/bin/env python3
"""Minify Lua files with LuaSrcDiet (https://github.com/jirutka/luasrcdiet).

LuaSrcDiet removes comments and whitespace and shortens local variable names. On Lua 5.1 it
also checks that each minified file compiles to the same bytecode as the original. Install
it once, into lua_modules/ in the repository root:

    luarocks --tree lua_modules --lua-version=5.1 install luasrcdiet 1.0.0-2

Then:

    python3 tools/minify_lua.py file.lua [...]          # prints the minified code
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCAL_LUASRCDIET = os.path.join(ROOT, "lua_modules", "bin", "luasrcdiet")


def find_luasrcdiet():
    if os.path.isfile(LOCAL_LUASRCDIET):
        return LOCAL_LUASRCDIET
    if shutil.which("luasrcdiet"):
        return "luasrcdiet"
    sys.exit("LuaSrcDiet isn't installed. Run this in the repository root, or pass --no-minify:\n"
             "    luarocks --tree lua_modules --lua-version=5.1 install luasrcdiet 1.0.0-2")


def minify(name, source):
    """source (bytes) minified. name is only used in error messages. Exits on failure."""
    luasrcdiet = find_luasrcdiet()
    with tempfile.TemporaryDirectory() as tmp:
        src, out = os.path.join(tmp, "in.lua"), os.path.join(tmp, "out.lua")
        with open(src, "wb") as f:
            f.write(source)
        result = subprocess.run([luasrcdiet, "--maximum", "--quiet", src, "-o", out],
                                capture_output=True, text=True)
        if result.returncode != 0 or not os.path.isfile(out):
            sys.exit(f"Minifying {name} failed: {(result.stderr or result.stdout).strip()}")
        with open(out, "rb") as f:
            return f.read()


def minify_file(path, data):
    """data minified, if it's a kind of file that can be."""
    if path.endswith(".lua"):
        return minify(path, data)
    if path.endswith(".manifest"):
        # A manifest is a bare table, which LuaSrcDiet only reads as part of a statement.
        result = minify(path, b"return " + data).strip()
        if not result.startswith(b"return"):
            sys.exit(f"Minifying {path} gave something unexpected.")
        return result[len(b"return"):].strip()
    return data


def minify_files(files):
    """(path, bytes) pairs with every file minified that can be."""
    return [(path, minify_file(path, data)) for path, data in files]


if __name__ == "__main__":
    for name in sys.argv[1:]:
        with open(name, "rb") as f:
            sys.stdout.buffer.write(minify(name, f.read()))
