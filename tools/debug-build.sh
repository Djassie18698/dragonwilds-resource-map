#!/usr/bin/env bash
# Turns a copy of the mod into a debug build: the "--DEBUG " lines of its scripts become code, like #ifdef DEBUG,
# and tools/debug.lua goes in as Scripts/Modules/debug.lua. In the source, and so in a release install or a plain copy
# of ResourceMarkers/, they're comments. Line numbers stay the same.
# Usage: tools/debug-build.sh <copy of ResourceMarkers/>   (./install.sh debug and tests/run.sh call it)
set -euo pipefail
dir="${1:?usage: debug-build.sh <mod dir>}"
[ -f "$dir/Scripts/main.lua" ] || { echo "not a copy of the mod: $dir" >&2; exit 1; }
find "$dir/Scripts" -name '*.lua' -print0 | xargs -0 sed -i -E 's/^([[:space:]]*)--DEBUG /\1/'
cp "$(dirname "$0")/debug.lua" "$dir/Scripts/Modules/debug.lua"
