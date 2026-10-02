#!/bin/bash
# claude-clear-caches.sh [InstanceName ...]
#
# Clears only regenerable caches from an instance's profile, then relaunches it.
# With no arguments, does every instance in the config.
#
# Chromium holds these directories open, so the instance MUST be quit first --
# deleting them under a live app risks the "Internal error opening backing
# store" class of failure. This script quits it properly and refuses to proceed
# if it will not quit.
#
# Nothing here touches conversations, settings, logins or MCP config: only
# Cache, Code Cache, GPUCache, DawnWebGPUCache, DawnGraphiteCache and
# Shared Dictionary, all of which the app rebuilds on demand.
#
# NOTE: an instance cannot clear itself if a Claude Code session is running
# inside it -- quitting the app ends that session. Run it from Terminal, or from
# a different instance.

set -uo pipefail

CONF="${CLAUDE_INSTANCES_CONF:-$HOME/.config/claude-instances/instances.conf}"
CACHES="Cache|Code Cache|GPUCache|DawnWebGPUCache|DawnGraphiteCache|Shared Dictionary"

[ -f "$CONF" ] || { echo "error: no instance config at $CONF" >&2; exit 1; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

total_before=$(df -k / | tail -1 | awk '{print $4}')
rc=0

while IFS= read -r rawline; do
    rawline="${rawline%%#*}"
    [ -n "$(trim "$rawline")" ] || continue
    IFS='|' read -r n i d h e <<<"$rawline"
    n="$(trim "${n:-}")"; d="$(trim "${d:-}")"; d="${d/#\~/$HOME}"
    [ -n "$n" ] && [ -n "$d" ] || continue

    if [ "$#" -gt 0 ]; then
        want=no
        for arg in "$@"; do
            [ "$(echo "$arg" | tr '[:upper:]' '[:lower:]')" = "$(echo "$n" | tr '[:upper:]' '[:lower:]')" ] && want=yes
        done
        [ "$want" = yes ] || continue
    fi

    app="/Applications/Claude $n.app"
    bid="$(trim "${i:-}")"
    echo "=== Claude $n ==="
    [ -d "$d" ] || { echo "  no profile at $d - skipped"; continue; }

    was_running=no
    if pgrep -f "Claude $n.app/Contents/MacOS/Claude" >/dev/null 2>&1; then
        was_running=yes
        echo "  quitting..."
        /usr/bin/osascript -e "tell application id \"$bid\" to quit" >/dev/null 2>&1
        for _ in $(seq 1 25); do
            pgrep -f "Claude $n.app/Contents/MacOS/Claude" >/dev/null 2>&1 || break
            sleep 1
        done
        if pgrep -f "Claude $n.app/Contents/MacOS/Claude" >/dev/null 2>&1; then
            echo "  ! still running - skipped (quit it with Cmd-Q and re-run)" >&2
            rc=1
            continue
        fi
    fi

    before=$(df -k / | tail -1 | awk '{print $4}')
    oldifs="$IFS"; IFS='|'
    for c in $CACHES; do
        [ -d "$d/$c" ] && rm -rf "$d/$c" && echo "  removed $c"
    done
    IFS="$oldifs"
    after=$(df -k / | tail -1 | awk '{print $4}')
    echo "  reclaimed: $(( (after - before) / 1024 )) MB"

    if [ "$was_running" = yes ] && [ -d "$app" ]; then
        open -a "$app" && echo "  relaunched"
    fi
done < "$CONF"

total_after=$(df -k / | tail -1 | awk '{print $4}')
echo
echo "total reclaimed: $(( (total_after - total_before) / 1024 )) MB"
exit $rc
