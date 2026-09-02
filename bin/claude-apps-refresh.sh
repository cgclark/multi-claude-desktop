#!/bin/bash
# claude-apps-refresh.sh
#
# Build any number of standalone Claude Desktop instances from /Applications/Claude.app.
# Each gets its own bundle identity, so each has its own coloured Dock icon, its own
# Cmd-Tab entry, and its own profile.
#
#   claude-apps-refresh.sh              # build/rebuild every configured instance
#   claude-apps-refresh.sh personal     # just one, by name
#   claude-apps-refresh.sh --status     # versions only, build nothing
#   claude-apps-refresh.sh --list       # show configured instances
#
# Instances are defined in ~/.config/claude-instances/instances.conf --
# add a line there and re-run; no need to edit this script.
#
# RUN THIS AFTER EVERY Claude.app UPDATE. The copies are point-in-time snapshots and
# keep running the OLD version until rebuilt. Note that Claude.app only updates itself
# when IT runs, so launch stock Claude occasionally, let it update, quit it, then rebuild.
#
# Design notes -- each learned the hard way:
#   cp -c              APFS clonefile; unchanged files share blocks with Claude.app, so
#                      each instance costs ~2MB real despite Finder reporting ~825MB.
#   sign main binary   ONLY the main binary + outer bundle are re-signed. The binary's
#                      signature seals Info.plist, which we edit, so it must be.
#                      Re-signing the 381MB Electron Framework would rewrite it and
#                      destroy the clone. Mixed signatures load fine because we sign
#                      WITHOUT hardened runtime, so library validation (which demands
#                      matching Team IDs) is off.
#   CFBundleName       stays "Claude": Electron derives the helper app name from it, and
#                      anything else fails with "Unable to find helper app".
#                      CFBundleDisplayName is what the Dock shows.
#   CFBundleIconName   DELETED -- it points into Assets.car (Claude's own icon) and
#                      outranks the CFBundleIconFile we set.
#   arch -arm64        MANDATORY in the launcher on Apple Silicon. The binary is
#                      universal, and a script-launched exec otherwise inherits x86_64
#                      and runs the Intel slice under Rosetta -- catastrophically slow.
#
# /Applications/Claude.app is only ever read.

set -euo pipefail

SRC="/Applications/Claude.app"
CONF="${CLAUDE_INSTANCES_CONF:-$HOME/.config/claude-instances/instances.conf}"
ICON_DIR="$HOME/.local/share/claude-instances"
RECOLOR="$(dirname "$0")/claude-recolor-icon.sh"
PB=/usr/libexec/PlistBuddy

[ -d "$SRC" ]  || { echo "error: $SRC not found -- reinstall Claude." >&2; exit 1; }
[ -f "$CONF" ] || { echo "error: no instance config at $CONF" >&2; exit 1; }

SRCVER=$($PB -c "Print :CFBundleShortVersionString" "$SRC/Contents/Info.plist" 2>/dev/null || echo "?")

# --- load config ---
names=() ids=() dirs=() hues=()
while IFS= read -r line; do
    line="${line%%#*}"
    [ -z "${line// }" ] && continue
    IFS='|' read -r n i d h <<<"$line"
    n="$(echo "$n" | xargs)"; i="$(echo "$i" | xargs)"
    d="$(echo "$d" | xargs)"; h="$(echo "$h" | xargs)"
    [ -n "$n" ] && [ -n "$i" ] && [ -n "$d" ] || { echo "error: malformed line: $line" >&2; exit 1; }
    d="${d/#\~/$HOME}"
    names+=("$n"); ids+=("$i"); dirs+=("$d"); hues+=("${h:-212}")
done < "$CONF"

[ ${#names[@]} -gt 0 ] || { echo "error: no instances configured in $CONF" >&2; exit 1; }

# --- sanity: duplicate ids or profiles would be silently destructive ---
for a in "${!names[@]}"; do
    for b in "${!names[@]}"; do
        [ "$a" -ge "$b" ] && continue
        [ "${ids[$a]}" = "${ids[$b]}" ] && { echo "error: duplicate bundle id ${ids[$a]}" >&2; exit 1; }
        [ "${dirs[$a]}" = "${dirs[$b]}" ] && { echo "error: ${names[$a]} and ${names[$b]} share a profile -- that can corrupt it" >&2; exit 1; }
    done
done

short() { echo "${1}" | tr '[:upper:]' '[:lower:]'; }
app_path() { echo "/Applications/Claude $1.app"; }
icon_path() { echo "$ICON_DIR/$(short "$1").icns"; }

list() {
    printf '  %-14s %-34s %-8s %s\n' NAME "BUNDLE ID" HUE PROFILE
    for i in "${!names[@]}"; do
        printf '  %-14s %-34s %-8s %s\n' "${names[$i]}" "${ids[$i]}" "${hues[$i]}" "${dirs[$i]/#$HOME/~}"
    done
}

status() {
    printf '  %-22s %s\n' "Claude.app (source)" "$SRCVER"
    for i in "${!names[@]}"; do
        app="$(app_path "${names[$i]}")"
        if [ -d "$app" ]; then
            v=$($PB -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist" 2>/dev/null || echo "?")
            [ "$v" = "$SRCVER" ] && note="up to date" || note="STALE -- rebuild"
        else
            v="-"; note="not built"
        fi
        printf '  %-22s %-12s %s\n' "Claude ${names[$i]}" "$v" "$note"
    done
}

build_one() {
    local idx="$1"
    local name="${names[$idx]}" bid="${ids[$idx]}" datadir="${dirs[$idx]}" hue="${hues[$idx]}"
    local dest icon
    dest="$(app_path "$name")"; icon="$(icon_path "$name")"

    if pgrep -f "Claude $name.app/Contents/MacOS/Claude" >/dev/null 2>&1; then
        echo "  ! Claude $name is running -- quit it (Cmd-Q) and re-run" >&2
        return 1
    fi

    # generate the icon master on first build, or if it went missing
    if [ ! -f "$icon" ]; then
        mkdir -p "$ICON_DIR"
        if [ -x "$RECOLOR" ]; then
            echo "  generating icon for $name (hue $hue)"
            "$RECOLOR" "$hue" "$icon" >/dev/null || { echo "  ! icon generation failed" >&2; return 1; }
        else
            echo "  ! no icon at $icon and claude-recolor-icon.sh not found" >&2
            return 1
        fi
    fi

    local before after
    before=$(df -k / | tail -1 | awk '{print $4}')
    rm -rf "$dest"
    cp -Rc "$SRC" "$dest"                       # APFS clone

    $PB -c "Set :CFBundleIdentifier $bid"                "$dest/Contents/Info.plist"
    $PB -c "Set :CFBundleDisplayName Claude $name"       "$dest/Contents/Info.plist"
    $PB -c "Set :CFBundleIconFile appicon"               "$dest/Contents/Info.plist"
    $PB -c "Set :CFBundleExecutable launcher"            "$dest/Contents/Info.plist"
    for k in CFBundleIconName CFBundleURLTypes NSUserActivityTypes; do
        $PB -c "Delete :$k" "$dest/Contents/Info.plist" 2>/dev/null || true
    done
    cp "$icon" "$dest/Contents/Resources/appicon.icns"

    local archpin=""
    [ "$(uname -m)" = "arm64" ] && archpin="/usr/bin/arch -arm64 "
    {
        printf '#!/bin/bash\n'
        printf 'set -uo pipefail\n'
        printf 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"\n'
        printf 'DATA_DIR=%q\n' "$datadir"
        printf 'mkdir -p "$DATA_DIR"\n'
        printf 'exec %s"$HERE/Claude" --user-data-dir="$DATA_DIR" "$@"\n' "$archpin"
    } > "$dest/Contents/MacOS/launcher"
    chmod +x "$dest/Contents/MacOS/launcher"

    plutil -lint "$dest/Contents/Info.plist" >/dev/null

    codesign --force -s - "$dest/Contents/MacOS/Claude" 2>/dev/null
    codesign --force -s - "$dest" 2>/dev/null
    codesign --verify --strict "$dest" 2>/dev/null || { echo "  ! signature invalid" >&2; return 1; }

    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest" 2>/dev/null || true
    mkdir -p "$datadir"
    after=$(df -k / | tail -1 | awk '{print $4}')
    printf '  built %-22s %s   real cost: %s MB\n' "Claude $name" "$SRCVER" "$(( (before-after)/1024 ))"
}

usage_names() { local o="" i; for i in "${!names[@]}"; do o="$o|$(short "${names[$i]}")"; done; printf '%s' "${o#|}"; }

verify() {
    # Detects an instance clobbered by Claude's own in-app updater. Squirrel
    # replaces the bundle AT ITS OWN PATH, so an update applied from inside a
    # copy would overwrite our identity -- reverting the bundle id, icon and,
    # critically, CFBundleExecutable, which is what injects --user-data-dir.
    # The instance would then silently open the DEFAULT profile.
    local bad=0 i
    for i in "${!names[@]}"; do
        local name="${names[$i]}" app problems=""
        app="$(app_path "$name")"
        if [ ! -d "$app" ]; then
            printf '  %-22s not built\n' "Claude $name"; continue
        fi
        local id exe
        id=$($PB -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist" 2>/dev/null || echo "?")
        exe=$($PB -c "Print :CFBundleExecutable" "$app/Contents/Info.plist" 2>/dev/null || echo "?")
        [ "$id"  = "${ids[$i]}" ] || problems="$problems bundle-id=$id"
        [ "$exe" = "launcher" ]   || problems="$problems executable=$exe"
        [ -x "$app/Contents/MacOS/launcher" ] || problems="$problems launcher-missing"
        [ -f "$app/Contents/Resources/appicon.icns" ] || problems="$problems icon-missing"
        # DATA_DIR is written %q-escaped, so unescape it before comparing
        local dd=""
        dd=$(grep '^DATA_DIR=' "$app/Contents/MacOS/launcher" 2>/dev/null | head -1 | cut -d= -f2-)
        [ -n "$dd" ] && eval "dd=$dd" 2>/dev/null || dd=""
        [ "$dd" = "${dirs[$i]}" ] || problems="$problems wrong-profile"
        codesign --verify --strict "$app" 2>/dev/null || problems="$problems bad-signature"
        if [ -n "$problems" ]; then
            printf '  %-22s CLOBBERED --%s\n' "Claude $name" "$problems"; bad=1
        else
            printf '  %-22s ok\n' "Claude $name"
        fi
    done
    if [ "$bad" -ne 0 ]; then
        echo
        echo 'An instance lost its identity -- most likely Claude'"'"'s in-app updater ran inside it.' >&2
        echo 'Rebuild it, then update via stock Claude.app instead:' >&2
        echo "  $(basename "$0")" >&2
        return 1
    fi
    return 0
}

case "${1:-all}" in
    --status|-s) echo "Versions:"; status; exit 0 ;;
    --list|-l)   echo "Configured in ${CONF/#$HOME/~}:"; list; exit 0 ;;
    --verify|-v) echo "Identity check:"; verify; exit $? ;;
    all) sel=(); for i in "${!names[@]}"; do sel+=("$i"); done ;;
    *)
        want="$(short "$1")"; sel=()
        for i in "${!names[@]}"; do
            [ "$(short "${names[$i]}")" = "$want" ] && sel+=("$i")
        done
        [ ${#sel[@]} -gt 0 ] || { echo "usage: $(basename "$0") [all|$(usage_names)|--status|--list|--verify]" >&2; exit 2; }
        ;;
esac

echo "Source: Claude.app $SRCVER"
rc=0
for i in "${sel[@]}"; do build_one "$i" || rc=1; done
echo
status
echo
echo "/Applications/Claude.app untouched. Launch the coloured apps, not stock Claude."
exit $rc
