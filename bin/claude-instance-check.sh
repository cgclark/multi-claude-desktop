#!/bin/bash
# claude-instance-check.sh
#
# Lists every running top-level Claude desktop process (helper/renderer
# subprocesses are excluded) and reports which Electron user-data directory
# each one is using.
#
# Exit status:
#   0  two or more distinct user-data directories are in use
#   1  fewer than two (i.e. the dual-instance setup is not actually running)

set -uo pipefail

# Suffix match: catches both /Applications/Claude.app and the standalone
# /Applications/Claude Enterprise.app, while excluding Electron helpers (whose
# executables end in "Claude Helper").
MATCH='/Contents/MacOS/Claude'

printf '%-8s  %-22s  %s\n' 'PID' 'APP' 'USER-DATA-DIR'
printf '%-8s  %-22s  %s\n' '--------' '----------------------' '-----------------------------------------'

dirs=()
found=0

# comm= gives the executable path only, so Electron helpers living under
# Contents/Frameworks/... never match.
while IFS= read -r line; do
    pid=${line%% *}
    exe=${line#* }
    case "$exe" in
        *"$MATCH") ;;
        *) continue ;;
    esac

    # /Applications/Claude Enterprise.app/Contents/MacOS/Claude -> Claude Enterprise
    app=${exe%/Contents/MacOS/Claude}
    app=${app##*/}
    app=${app%.app}

    found=$((found + 1))

    args=$(ps -ww -o command= -p "$pid" 2>/dev/null)

    if [[ "$args" == *--user-data-dir* ]]; then
        # Strip everything up to and including the flag name.
        val=${args#*--user-data-dir}
        # Accept both "--user-data-dir=PATH" and "--user-data-dir PATH".
        val=${val#=}
        val=${val# }
        # Cut at the next flag, if any. Paths may contain spaces, so only a
        # space followed by "--" ends the value.
        case "$val" in
            *" --"*) val=${val%% --*} ;;
        esac
        # Resolve to a canonical absolute path when it exists on disk.
        if [ -d "$val" ]; then
            val=$(cd "$val" 2>/dev/null && pwd -P) || val=${val}
        fi
    else
        val='DEFAULT'
    fi

    printf '%-8s  %-22s  %s\n' "$pid" "$app" "$val"
    dirs+=("$val")
done < <(ps -Aww -o pid=,comm=)

if [ "$found" -eq 0 ]; then
    echo
    echo 'No Claude desktop processes are running.'
fi

distinct=0
if [ "${#dirs[@]}" -gt 0 ]; then
    distinct=$(printf '%s\n' "${dirs[@]}" | sort -u | wc -l | tr -d ' ')
fi

echo
echo "Processes: $found    Distinct user-data dirs: $distinct"

if [ "$distinct" -lt 2 ]; then
    echo 'FAIL: fewer than two distinct user-data directories in use.' >&2
    exit 1
fi

echo 'OK: two or more distinct user-data directories in use.'
exit 0
