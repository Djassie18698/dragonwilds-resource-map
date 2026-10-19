#!/usr/bin/env bash
# Offline tests: syntax, settings, the save reader against a frozen save and your current saves, and the whole mod
# against a fake UE4SS. Needs lua5.4. Usage: tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# A runaway test (a loop over something that never ends) fails with "not enough memory" instead of taking the
# machine's memory: 2 GB per process is far more than any test needs.
ulimit -v 2000000
SAVED="${DW_SAVED:-$HOME/.local/share/Steam/steamapps/compatdata/1374490/pfx/drive_c/users/steamuser/AppData/Local/RSDragonwilds/Saved}"

echo "== syntax"
find ResourceMarkers tools tests -name '*.lua' -print0 | xargs -0 -n1 luac5.4 -p
# and the debug build's (its --DEBUG lines uncommented, as tools/debug-build.sh does)
find ResourceMarkers -name '*.lua' -print0 | while IFS= read -r -d '' f; do
    sed -E 's/^([[:space:]]*)--DEBUG /\1/' "$f" | luac5.4 -p - || { echo "  in the debug build of $f"; exit 1; }
done
echo "  OK"

echo "== settings.txt (1.x files keep their layers)"
lua5.4 tests/test-settings.lua

# The fixture is a copy of a world save (it holds players' names, so it isn't in the repository): the exact checks
# and the mock need it; without it they're skipped.
FIXTURE=tests/fixtures/Test.sav
if [ -f "$FIXTURE" ]; then
    echo "== save reader: fixture (exact)"
    lua5.4 tests/test-saves.lua "$FIXTURE" --exact
else
    echo "== (no $FIXTURE: exact save checks and the mock skipped)"
fi

shopt -s nullglob
saves=("$SAVED"/SaveGames/*.sav)
for sav in "${saves[@]}"; do
    echo "== save reader: your save $(basename "$sav")"
    lua5.4 tests/test-saves.lua "$sav"
done
[ ${#saves[@]} -gt 0 ] || echo "== (no saves found in $SAVED/SaveGames, skipped)"

if [ -f "$FIXTURE" ]; then
    echo "== whole mod against a fake UE4SS"
    lua5.4 tests/mock-run.lua "$FIXTURE" | sed 's/^/  /'
    echo "== the same, debug build (its debug lines counted, not shown)"
    dbg="$(mktemp -d)"
    cp -r ResourceMarkers/. "$dbg/"
    tools/debug-build.sh "$dbg"
    if ! DW_MOD="$dbg" lua5.4 tests/mock-run.lua "$FIXTURE" > "$dbg/out.txt" 2>&1; then
        sed 's/^/  /' "$dbg/out.txt"
        rm -rf "$dbg"
        exit 1
    fi
    grep -v ' dbg: ' "$dbg/out.txt" | sed 's/^/  /'
    echo "  ($(grep -c ' dbg: ' "$dbg/out.txt") debug lines)"
    rm -rf "$dbg"
fi
echo "All tests passed."
