#!/bin/bash
# claude-apps-refresh.sh
#
# Rebuild the standalone Claude instances from /Applications/Claude.app:
#
#   Claude Personal.app    green   profile ~/Library/Application Support/Claude
#   Claude Enterprise.app  blue    profile ~/Library/Application Support/Claude-Enterprise
#
# Each is a full copy with its OWN bundle identity, so each gets its own coloured
# Dock icon and Cmd-Tab entry instead of masquerading as the stock orange Claude.
#
# RUN THIS AFTER EVERY Claude.app UPDATE. The copies are point-in-time snapshots
# and keep running the OLD version until rebuilt.
#
#   claude-apps-refresh.sh              # rebuild both
#   claude-apps-refresh.sh personal     # rebuild one
#   claude-apps-refresh.sh --status     # versions only, build nothing
#
# HEADS UP: /Applications/Claude.app only updates itself when IT runs. If you
# never launch it, both copies freeze at the current version forever. --status
# compares versions so you can see drift; launch stock Claude occasionally to
# let it update, then rebuild.
#
# Design notes -- each learned the hard way:
#   cp -c              APFS clonefile; unchanged files share blocks with
#                      Claude.app, so each copy costs ~5MB real despite Finder
#                      reporting ~825MB.
#   sign main binary   ONLY the main binary + outer bundle get re-signed. The
#                      binary's signature seals Info.plist, which we edit, so it
#                      must be. Re-signing the 381MB Electron Framework would
#                      rewrite it and destroy the clone. Mixed signatures load
#                      fine because we sign WITHOUT hardened runtime, so library
#                      validation (which demands matching Team IDs) is off.
#   CFBundleName       stays "Claude": Electron derives the helper app name from
#                      it, and anything else fails with "Unable to find helper
#                      app". CFBundleDisplayName is what the Dock shows.
#   CFBundleIconName   DELETED -- it points into Assets.car (Claude's own icon)
#                      and outranks the CFBundleIconFile we set.
#   arch -arm64        MANDATORY in the launcher. The binary is universal, and a
#                      script-launched exec otherwise inherits x86_64 and runs
#                      the Intel slice under Rosetta -- catastrophically slow.
#                      Activity Monitor's "Kind" column is the tell.
#
# /Applications/Claude.app is only ever read.

set -euo pipefail

SRC="/Applications/Claude.app"
PB=/usr/libexec/PlistBuddy
[ -d "$SRC" ] || { echo "error: $SRC not found -- reinstall Claude." >&2; exit 1; }
SRCVER=$($PB -c "Print :CFBundleShortVersionString" "$SRC/Contents/Info.plist" 2>/dev/null || echo "?")

# name | bundle id | data dir | icon master
inst_name=("Claude Personal" "Claude Enterprise")
inst_id=("com.example.claude-personal" "com.example.claude-enterprise")
inst_dir=("$HOME/Library/Application Support/Claude" \
          "$HOME/Library/Application Support/Claude-Enterprise")
inst_icon=("$HOME/.local/share/claude-personal/appicon.icns" \
           "$HOME/.local/share/claude-enterprise/appicon.icns")

installed_version() {   # $1 = app path
    [ -d "$1" ] && $PB -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || echo "-"
}

status() {
    printf '  %-22s %s\n' "Claude.app (source)" "$SRCVER"
    for i in "${!inst_name[@]}"; do
        app="/Applications/${inst_name[$i]}.app"
        v=$(installed_version "$app")
        if [ "$v" = "-" ]; then note="not built"
        elif [ "$v" = "$SRCVER" ]; then note="up to date"
        else note="STALE -- rebuild"; fi
        printf '  %-22s %-12s %s\n' "${inst_name[$i]}" "$v" "$note"
    done
}

build_one() {
    local name="$1" bid="$2" datadir="$3" icon="$4"
    local dest="/Applications/$name.app"

    [ -f "$icon" ] || { echo "  ! icon master missing: $icon" >&2; return 1; }
    if pgrep -f "$name.app/Contents/MacOS/Claude" >/dev/null 2>&1; then
        echo "  ! $name is running -- quit it (Cmd-Q) and re-run" >&2
        return 1
    fi

    local before after
    before=$(df -k / | tail -1 | awk '{print $4}')
    rm -rf "$dest"
    cp -Rc "$SRC" "$dest"

    $PB -c "Set :CFBundleIdentifier $bid"       "$dest/Contents/Info.plist"
    $PB -c "Set :CFBundleDisplayName $name"     "$dest/Contents/Info.plist"
    $PB -c "Set :CFBundleIconFile appicon"      "$dest/Contents/Info.plist"
    $PB -c "Set :CFBundleExecutable launcher"   "$dest/Contents/Info.plist"
    for k in CFBundleIconName CFBundleURLTypes NSUserActivityTypes; do
        $PB -c "Delete :$k" "$dest/Contents/Info.plist" 2>/dev/null || true
    done
    cp "$icon" "$dest/Contents/Resources/appicon.icns"

    # launcher pins the profile and the architecture
    {
        printf '#!/bin/bash\n'
        printf 'set -uo pipefail\n'
        printf 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"\n'
        printf 'DATA_DIR=%q\n' "$datadir"
        printf 'mkdir -p "$DATA_DIR"\n'
        printf 'exec /usr/bin/arch -arm64 "$HERE/Claude" --user-data-dir="$DATA_DIR" "$@"\n'
    } > "$dest/Contents/MacOS/launcher"
    chmod +x "$dest/Contents/MacOS/launcher"

    plutil -lint "$dest/Contents/Info.plist" >/dev/null

    codesign --force -s - "$dest/Contents/MacOS/Claude" 2>/dev/null
    codesign --force -s - "$dest" 2>/dev/null
    codesign --verify --strict "$dest" 2>/dev/null || { echo "  ! signature invalid" >&2; return 1; }

    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest" 2>/dev/null || true
    mkdir -p "$datadir"
    after=$(df -k / | tail -1 | awk '{print $4}')
    printf '  built %-20s %s   real cost: %s MB\n' "$name" "$SRCVER" "$(( (before-after)/1024 ))"
}

case "${1:-all}" in
    --status|-s) echo "Versions:"; status; exit 0 ;;
    personal)   sel=(0) ;;
    enterprise) sel=(1) ;;
    all)        sel=(0 1) ;;
    *) echo "usage: $(basename "$0") [all|personal|enterprise|--status]" >&2; exit 2 ;;
esac

echo "Source: Claude.app $SRCVER"
rc=0
for i in "${sel[@]}"; do
    build_one "${inst_name[$i]}" "${inst_id[$i]}" "${inst_dir[$i]}" "${inst_icon[$i]}" || rc=1
done
echo
status
echo
echo "/Applications/Claude.app untouched. Launch the coloured apps, not stock Claude."
exit $rc
