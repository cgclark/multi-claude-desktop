#!/bin/bash
# claude-stale-check.sh [InstanceName ...]
#
# Health watch for the standalone Claude instances. Checks EVERY instance in
# ~/.config/claude-instances/instances.conf unless names are given.
#
# Catches the three ways this setup degrades without anyone noticing:
#   1. STALE     - /Applications/Claude.app updated; the copy did not. The copy
#                  keeps running the old version indefinitely.
#   2. CLOBBERED - the copy lost its identity (bundle id / launcher / env). The
#                  usual cause is an in-app update accepted inside a copy:
#                  Squirrel replaces the bundle at its own path, which drops the
#                  launcher and silently sends that instance to the DEFAULT
#                  profile.
#   3. BROKEN    - a prerequisite for rebuilding has gone away (missing icon
#                  master, missing tool), so the next rebuild would fail.
#
# It only reads and reports. It never rebuilds: the builder refuses to touch a
# running app, and a background job that quits windows mid-conversation is worse
# than a stale copy.

set -uo pipefail

CONF="${CLAUDE_INSTANCES_CONF:-$HOME/.config/claude-instances/instances.conf}"
ICON_DIR="$HOME/.local/share/claude-instances"
SRC="/Applications/Claude.app"
LOG="$HOME/Library/Logs/claude-stale-check.log"
DELAY="${CLAUDE_STALE_CHECK_DELAY:-45}"
PB=/usr/libexec/PlistBuddy

mkdir -p "$(dirname "$LOG")"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
ver() { "$PB" -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null; }

notify() {
    /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1
}

case "$DELAY" in ''|*[!0-9]*) DELAY=0 ;; esac
[ "$DELAY" -gt 0 ] && sleep "$DELAY"

[ -d "$SRC" ] || { log "source missing: $SRC"; exit 0; }
[ -f "$CONF" ] || { log "config missing: $CONF"; exit 0; }

SRCVER=$(ver "$SRC")
problems=""
checked=0

# Trim without xargs: xargs chokes on apostrophes, which appear in the config's
# own comments (e.g. separated by ';').
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

while IFS= read -r rawline; do
    rawline="${rawline%%#*}"          # strip comments BEFORE splitting
    [ -n "$(trim "$rawline")" ] || continue
    IFS='|' read -r n i d h e <<<"$rawline"
    n="$(trim "${n:-}")"
    [ -n "$n" ] || continue
    i="$(trim "${i:-}")"
    d="$(trim "${d:-}")"
    e="$(trim "${e:-}")"
    d="${d/#\~/$HOME}"

    # optional positional filter
    if [ "$#" -gt 0 ]; then
        want=no
        for arg in "$@"; do
            [ "$(echo "$arg" | tr '[:upper:]' '[:lower:]')" = "$(echo "$n" | tr '[:upper:]' '[:lower:]')" ] && want=yes
        done
        [ "$want" = yes ] || continue
    fi

    checked=$((checked + 1))
    app="/Applications/Claude $n.app"
    launcher="$app/Contents/MacOS/launcher"

    if [ ! -d "$app" ]; then
        problems="$problems; $n: NOT BUILT"
        log "$n: not built"
        continue
    fi

    # --- identity (clobber detection) ---
    bid=$("$PB" -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist" 2>/dev/null)
    exe=$("$PB" -c "Print :CFBundleExecutable" "$app/Contents/Info.plist" 2>/dev/null)
    bad=""
    [ "$bid" = "$i" ]       || bad="$bad bundle-id"
    [ "$exe" = "launcher" ] || bad="$bad executable"
    [ -x "$launcher" ]      || bad="$bad launcher-missing"
    codesign --verify --strict "$app" 2>/dev/null || bad="$bad signature"
    if [ -n "$e" ] && [ -f "$launcher" ]; then
        oldifs="$IFS"; IFS=';'
        for pair in $e; do
            pair="$(echo "$pair" | xargs)"
            [ -n "$pair" ] || continue
            k="${pair%%=*}"
            grep -q "^export $k=" "$launcher" 2>/dev/null || bad="$bad env:$k"
        done
        IFS="$oldifs"
    fi
    if [ -n "$bad" ]; then
        problems="$problems; $n: CLOBBERED($bad)"
        log "$n: CLOBBERED --$bad"
        continue
    fi

    # --- rebuild prerequisites ---
    if [ ! -f "$ICON_DIR/$(echo "$n" | tr '[:upper:]' '[:lower:]').icns" ]; then
        problems="$problems; $n: icon master missing"
        log "$n: icon master missing (rebuild would use the stock icon)"
    fi

    # --- version ---
    v=$(ver "$app")
    if [ "$v" != "$SRCVER" ]; then
        problems="$problems; $n: STALE $v vs $SRCVER"
        log "$n: STALE $v, source is $SRCVER"
    else
        log "$n: ok $v"
    fi
done < "$CONF"

[ "$checked" -gt 0 ] || { log "no instances checked"; exit 0; }

if [ -n "$problems" ]; then
    msg="${problems#; }"
    notify "Claude instances need attention" "$msg -- run claude-apps-refresh.sh"
    exit 1
fi
exit 0
