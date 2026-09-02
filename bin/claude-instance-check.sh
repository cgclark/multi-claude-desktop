#!/bin/bash
# claude-instance-check.sh
#
# Health check for the multi-instance Claude Desktop setup. Lists every running
# Claude main process, which app it belongs to, and which profile it is using.
#
# Exit status:
#   0  healthy
#   1  PROFILE COLLISION -- two or more processes share one profile directory.
#      This is the dangerous case: concurrent writes to one LevelDB can corrupt
#      it. Quit all but one of the colliding processes now.
#
# A single running instance is NOT an error -- you simply have one app open.
# Use `claude-apps-refresh.sh --list` to see what is configured.

set -uo pipefail

# Suffix match: catches /Applications/Claude.app and every standalone copy
# (Claude Personal.app, Claude Enterprise.app, ...) while excluding Electron
# helpers, whose executables end in "Claude Helper".
MATCH='/Contents/MacOS/Claude'

pids=() apps=() vals=()

while IFS= read -r line; do
    # `ps -o pid=` right-aligns, so short pids carry leading spaces -- splitting
    # on the first space would yield an empty pid, and the args lookup below
    # would then wrongly report the default profile (a phantom collision).
    read -r pid exe <<<"$line"
    [ -n "$pid" ] || continue
    case "$exe" in *"$MATCH") ;; *) continue ;; esac

    app=${exe%/Contents/MacOS/Claude}
    app=${app##*/}
    app=${app%.app}

    args=$(ps -ww -o command= -p "$pid" 2>/dev/null)
    if [[ "$args" == *--user-data-dir* ]]; then
        val=${args#*--user-data-dir}
        val=${val#=}; val=${val# }
        case "$val" in *" --"*) val=${val%% --*} ;; esac
        [ -d "$val" ] && val=$(cd "$val" 2>/dev/null && pwd -P)
    else
        # no flag: Electron's default profile for this app
        val="$HOME/Library/Application Support/Claude"
    fi

    pids+=("$pid"); apps+=("$app"); vals+=("$val")
done < <(ps -Aww -o pid=,comm=)

if [ "${#pids[@]}" -eq 0 ]; then
    echo 'No Claude instances are running.'
    exit 0
fi

# --- find profiles used by more than one process ---
collisions=$(printf '%s\n' "${vals[@]}" | sort | uniq -d)

printf '%-8s  %-22s  %s\n' 'PID' 'APP' 'PROFILE'
printf '%-8s  %-22s  %s\n' '--------' '----------------------' '------------------------------------------'
for i in "${!pids[@]}"; do
    mark=""
    if [ -n "$collisions" ] && printf '%s\n' "$collisions" | grep -qxF "${vals[$i]}"; then
        mark="  <-- COLLISION"
    fi
    printf '%-8s  %-22s  %s%s\n' "${pids[$i]}" "${apps[$i]}" "${vals[$i]/#$HOME/~}" "$mark"
done

distinct=$(printf '%s\n' "${vals[@]}" | sort -u | wc -l | tr -d ' ')
echo
echo "Instances running: ${#pids[@]}    Distinct profiles: $distinct"

if [ -n "$collisions" ]; then
    echo
    echo 'FAIL: these profiles are in use by more than one process:' >&2
    printf '%s\n' "$collisions" | sed "s|$HOME|~|; s/^/  /" >&2
    echo 'Quit all but one of each -- concurrent writes can corrupt the profile.' >&2
    exit 1
fi

echo 'OK: every running instance has its own profile.'
exit 0
