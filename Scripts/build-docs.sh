#!/usr/bin/env bash
#
# Build the DocC documentation archive for PerunSQLite.
#
# SQLite is found through pkg-config. On macOS the headers ship with the SDK, but Homebrew's
# `sqlite` is keg-only, so if it's installed we point PKG_CONFIG_PATH (and CPATH, which clang
# honours for every compilation, as a belt-and-suspenders fallback) at it. On Linux the
# `libsqlite3-dev` pkg-config files land in a standard location and nothing extra is needed.
#
# Usage: ./Scripts/build-docs.sh [extra generate-documentation args]
#   SQLITE_PREFIX=/path overrides the probe.
set -euo pipefail

prefix="${SQLITE_PREFIX:-}"
if [[ -z "$prefix" ]]; then
    for candidate in \
        /opt/homebrew/opt/sqlite \
        /usr/local/opt/sqlite; do
        if [[ -f "$candidate/lib/pkgconfig/sqlite3.pc" ]]; then
            prefix="$candidate"
            break
        fi
    done
fi

# A prefix is optional: without one we rely on the system SDK (macOS) or the standard pkg-config
# path (Linux). Only export the overrides when we actually found a keg-only install.
if [[ -n "$prefix" ]]; then
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export CPATH="$prefix/include${CPATH:+:$CPATH}"
fi

PERUN_BUILD_DOCS=1 \
    swift package generate-documentation --target PerunSQLite "$@"
