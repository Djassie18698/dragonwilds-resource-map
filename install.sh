#!/usr/bin/env bash
# Resource Markers installer for iterative testing.
#
#   ./install.sh            run the offline tests, then install (copy ResourceMarkers/ into the game's UE4SS Mods)
#   ./install.sh --no-test  install without running the tests
#   ./install.sh debug      install a debug build (verbose log lines, F9 layer hunt); add --no-test to skip tests.
#                           ./install.sh installs a release build again.
#   ./install.sh test       offline tests only
#   ./install.sh status     what's installed, UE4SS, launch options, other map mods, game running
#   ./install.sh logs       the mod's lines (warnings and errors) from the last UE4SS.log
#   ./install.sh extract    rebuild data/ (world, foliage, items) from the installed game (after a game update)
#   ./install.sh uninstall  remove the mod from the game
#
# Your settings.txt in the installed copy is kept across installs.
# Override paths with DW_GAME (game folder) and DW_SAVED (the game's Saved folder).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/ResourceMarkers"
GAME="${DW_GAME:-$HOME/.local/share/Steam/steamapps/common/RSDragonwilds}"
WIN64="$GAME/RSDragonwilds/Binaries/Win64"
UE4SS="$WIN64/ue4ss"
DEST="$UE4SS/Mods/ResourceMarkers"
APPID=1374490

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mfail\033[0m  %s\n' "$*"; }

# Hash of the mod's files, to tell whether the installed copy matches the source.
build_id() { (cd "$1" && find Scripts data enabled.txt -type f -print0 | sort -z | xargs -0 sha1sum | sha1sum | cut -c1-12); }

game_running() { pgrep -f 'RSDragonwilds-Win64-Shipping' >/dev/null 2>&1; }

ue4ss_installed() { [ -f "$WIN64/dwmapi.dll" ] && [ -d "$UE4SS/Mods" ]; }

# The game's Steam launch options (empty if none).
launch_options() {
    python3 - "$APPID" <<'EOF'
import glob, os, re, sys
def blocks(s, key):
    for m in re.finditer(r'"%s"\s*\{' % key, s):
        depth, i = 0, m.end() - 1
        for k in range(i, len(s)):
            if s[k] == '{': depth += 1
            elif s[k] == '}':
                depth -= 1
                if depth == 0:
                    yield s[i:k + 1]
                    break
for p in glob.glob(os.path.expanduser('~/.local/share/Steam/userdata/*/config/localconfig.vdf')):
    s = open(p, encoding='utf-8', errors='replace').read()
    for b in blocks(s, sys.argv[1]):
        m = re.search(r'"LaunchOptions"\s+"((?:[^"\\]|\\.)*)"', b)
        if m:
            print(m.group(1).replace('\\"', '"'))
            sys.exit()
EOF
}

check_launch_options() {
    local opts
    opts="$(launch_options || true)"
    if [[ "$opts" == *dwmapi* ]]; then
        ok "launch options load UE4SS ($opts)"
    else
        warn "Steam launch options don't load UE4SS under Proton. In Steam: RuneScape: Dragonwilds > Properties > Launch Options:"
        if [[ "$opts" == *%command%* ]]; then
            printf '          WINEDLLOVERRIDES="dwmapi=n,b" %s\n' "$opts"
        else
            printf '          WINEDLLOVERRIDES="dwmapi=n,b" %s%%command%%\n' "${opts:+$opts }"
        fi
    fi
}

check_other_mods() {
    local m
    for m in LiveMap MiniMap; do
        if [ -f "$UE4SS/Mods/$m/enabled.txt" ] || grep -qsE "^\s*$m\s*:\s*1" "$UE4SS/Mods/mods.txt"; then
            ok "$m is also installed"
        fi
    done
}

cmd_test() {
    bold "Offline tests"
    "$ROOT/tests/run.sh"
}

cmd_install() {
    local debug=""
    if [ "${1:-}" = "debug" ]; then debug=1; shift; fi
    [ "${1:-}" = "--no-test" ] || cmd_test
    bold "Install"
    [ -d "$GAME" ] || { fail "game folder not found: $GAME (set DW_GAME)"; exit 1; }
    if ! ue4ss_installed; then
        fail "UE4SS isn't installed in $WIN64 (needs dwmapi.dll and ue4ss/Mods). Install it first (the Nexus requirement)."
        exit 1
    fi
    game_running && warn "the game is running: changes apply after you restart it"
    mkdir -p "$DEST"
    # The installed copy's own files survive: settings, and what a discovery build collected (never in the source).
    rsync -a --delete --exclude settings.txt --exclude "discovery*.log" --exclude foliage-seen.txt "$SRC/" "$DEST/"
    # ResourceMarkers/ is a release build (its --DEBUG lines are comments; --delete removes a debug install's debug.lua).
    [ -z "$debug" ] || "$ROOT/tools/debug-build.sh" "$DEST"
    local id
    id="$(build_id "$SRC")"
    printf 'build %s%s, installed %s from %s\n' "$id" "${debug:+ (debug)}" "$(date '+%F %T')" "$SRC" > "$DEST/build.txt"
    ok "installed ${debug:+debug }build $id -> $DEST"
    check_launch_options
    check_other_mods
}

cmd_status() {
    bold "Status"
    echo "  game:   $GAME"
    if ue4ss_installed; then
        local ver=""
        [ -f "$UE4SS/UE4SS.log" ] && ver="$(grep -m1 -oE 'UE4SS v[0-9][^ ]*' "$UE4SS/UE4SS.log" || true)"
        ok "UE4SS installed ${ver:+($ver)}"
    else
        fail "UE4SS not installed (needs $WIN64/dwmapi.dll and $UE4SS/Mods)"
    fi
    check_launch_options
    if [ -f "$DEST/build.txt" ]; then
        local installed source
        installed="$(cut -d' ' -f2 "$DEST/build.txt" | tr -d ,)"
        source="$(build_id "$SRC")"
        if [ "$installed" = "$source" ]; then ok "Resource Markers installed, up to date ($(cat "$DEST/build.txt"))"
        else warn "Resource Markers installed but out of date (installed $installed, source $source): run ./install.sh"; fi
        grep -q '(debug)' "$DEST/build.txt" && warn "that's a debug build (verbose log): ./install.sh installs a release build"
    elif [ -d "$DEST" ]; then
        warn "Resource Markers folder exists but wasn't installed by this script: $DEST"
    else
        warn "Resource Markers not installed"
    fi
    [ -d "$UE4SS/Mods" ] && check_other_mods
    check_data_stamp
    if game_running; then echo "  game is running"; else echo "  game is not running"; fi
}

# Whether data/world.lua was extracted from the installed game (same main container size as its stamp).
check_data_stamp() {
    local stamp size
    stamp="$(grep -m1 -oE 'utoc_size = [0-9]+' "$SRC/data/world.lua" | grep -oE '[0-9]+' || true)"
    size="$(stat -c %s "$GAME/RSDragonwilds/Content/Paks/RSDragonwilds-Windows.utoc" 2>/dev/null || true)"
    if [ -z "$stamp" ]; then warn "data/world.lua has no game stamp: run ./install.sh extract"
    elif [ "$stamp" = "$size" ]; then ok "map data extracted from the installed game build"
    else warn "map data is from another game build (the game was updated): run ./install.sh extract"; fi
}

cmd_extract() {
    bold "Extract map data from the game"
    command -v python3 >/dev/null || { fail "needs python3"; exit 1; }
    command -v lua5.4 >/dev/null || { fail "needs lua5.4"; exit 1; }
    python3 "$ROOT/tools/extract/extract.py" --game "$GAME"
}

cmd_logs() {
    bold "UE4SS.log (Resource Markers lines and errors)"
    local log="$UE4SS/UE4SS.log"
    if [ -f "$log" ]; then
        echo "  $log, last written $(date -r "$log" '+%F %T')"
        grep -nE '\[ResourceMarkers\]|ResourceMarkers|Error|error' "$log" | tail -n 80 | sed 's/^/  /' || echo "  (no Resource Markers lines)"
    else
        echo "  no UE4SS.log yet (UE4SS hasn't run)"
    fi
}

cmd_uninstall() {
    bold "Uninstall"
    if [ -d "$DEST" ]; then
        game_running && warn "the game is running: the mod stays loaded until you restart it"
        rm -rf "$DEST"
        ok "removed $DEST"
    else
        ok "not installed"
    fi
}

case "${1:-install}" in
    install|--no-test) cmd_install "${1:-}" ;;
    debug) cmd_install debug "${2:-}" ;;
    test) cmd_test ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    extract) cmd_extract ;;
    uninstall) cmd_uninstall ;;
    -h|--help|help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "unknown command: $1 (try --help)"; exit 2 ;;
esac
