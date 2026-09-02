# Dual Claude Desktop Setup (macOS)

Two Claude Desktop instances — **personal** and **enterprise** — running side by side,
each with its own account, its own profile, and its own coloured Dock icon.

Claude Desktop accepts Electron's `--user-data-dir`, so isolating a second profile is
easy. Giving that second instance its own **Dock icon** is not: a thin wrapper `.app`
can't do it, because the running process belongs to whichever bundle it launched. This
repo builds each instance as a standalone copy with its own bundle identity — costing
~2 MB thanks to APFS cloning, rather than a 823 MB duplicate.

**Setup:** edit `inst_id` in `bin/claude-apps-refresh.sh` to your own reverse-DNS ids
(they ship as `com.example.*` placeholders), generate the icon masters, then run it —
see [Rebuild everything from nothing](#rebuild-everything-from-nothing).

Built on Apple Silicon with an APFS volume. Intel Macs: drop the `arch -arm64` pin.

---

## Daily use

| Click | App | Account | Profile |
|---|---|---|---|
| 🟢 **green** | `/Applications/Claude Personal.app` | personal | `~/Library/Application Support/Claude` |
| 🔵 **blue** | `/Applications/Claude Enterprise.app` | enterprise | `~/Library/Application Support/Claude-Enterprise` |
| 🟠 coral | `/Applications/Claude.app` | — | **don't click it** |

**Keep only green and blue in the Dock.** Stock `Claude.app` is the *source* the two
copies are built from, plus the thing that downloads Claude updates. Launching it
starts a third instance on the personal profile — two processes on one database.

Health check any time:

```bash
~/bin/claude-instance-check.sh
```

---

## ⚠️ Recovery after Claude.app updates

**This is the one maintenance task. Read this section.**

### What happens

`Claude Personal.app` and `Claude Enterprise.app` are **point-in-time copies** of
`Claude.app`, made with APFS cloning. They are fully independent once made. When
`Claude.app` updates itself, the copies **do not change** — they keep running the old
version, silently and indefinitely.

Worse: `Claude.app` only updates itself **when it runs**. If you only ever launch the
coloured copies, nothing ever updates anything, and all three freeze at the version
they were built at.

### Symptoms you are stale

- New Claude features appear in release notes but not in your apps
- `claude-apps-refresh.sh --status` shows a version mismatch
- Disk usage creeping up (see *Disk creep* below)

### The routine — do this every few weeks

```bash
# 1. Check for drift
~/bin/claude-apps-refresh.sh --status

# 2. Launch STOCK Claude and let it update itself, then quit it (Cmd-Q).
open -a "/Applications/Claude.app"

# 3. Quit BOTH coloured apps (Cmd-Q). The rebuild refuses to touch a running app.

# 4. Rebuild both copies from the updated source
~/bin/claude-apps-refresh.sh

# 5. Verify
~/bin/claude-apps-refresh.sh --status
~/bin/claude-instance-check.sh
```

Step 2 is the part people forget. Without it there is no new version to rebuild *from*,
and step 4 just rebuilds the same version again.

Rebuilding takes a few seconds and costs ~2 MB per app.

### What a rebuild does and does not touch

| Preserved | Rebuilt from scratch |
|---|---|
| Both profiles (accounts, conversations, settings, MCP config) | The app bundles themselves |
| Icon masters in `~/.local/share/` | Bundle identity, launcher, signature |
| The `_trash` backups | — |

Profiles live **outside** the app bundles, which is why a rebuild is safe. The bundle is
disposable; the profile is the valuable thing.

### Disk creep

Each copy normally costs ~2 MB of real disk because APFS clone-sharing means unchanged
files share blocks with `Claude.app`. **When `Claude.app` updates, that sharing breaks** —
the old blocks are retained for your copies, and real usage climbs toward the full
823 MB each. Rebuilding re-establishes sharing and reclaims the space. Another reason
not to skip the refresh.

Real usage, not the inflated Finder number:

```bash
df -h /
```

Finder will always claim each copy is ~825 MB. Ignore it; the blocks are shared.

### If a rebuild fails partway

The script does `rm -rf` on the target *before* copying, so a failure can leave an app
missing. It is not destructive to your data — just re-run it:

```bash
~/bin/claude-apps-refresh.sh personal      # or: enterprise, or: all
```

If the source itself is broken, reinstall Claude from Anthropic, then rebuild.

### If Claude.app is updated while a copy is running

Nothing breaks. The running copy holds its own cloned files and is unaffected. Quit it
and rebuild at your convenience.

---

## Health check

```bash
~/bin/claude-instance-check.sh
```

Lists every running Claude main process, which app it belongs to, and its profile:

```
PID       APP                     USER-DATA-DIR
74901     Claude Enterprise       …/Application Support/Claude-Enterprise
75300     Claude Personal         …/Application Support/Claude

Processes: 2    Distinct user-data dirs: 2
OK: two or more distinct user-data directories in use.
```

- **Exit 0** — two or more distinct profiles in use.
- **Exit 1** — fewer than two. *Expected* if you only have one app open; it is only a
  fault if you believe both are running.

**The failure it exists to catch:** two processes on the **same** profile. If two rows
show the same `USER-DATA-DIR`, quit one immediately — concurrent writes to one LevelDB
can corrupt it. This happened during setup when stock `Claude.app` stayed running
alongside `Claude Personal`.

It matches executables ending in `/Contents/MacOS/Claude`, so it catches both copies and
excludes the `Claude Helper` processes (which end in `Claude Helper`).

---

## Scripts

All in `~/bin` (ensure it is on your `PATH`).

| Script | What it does |
|---|---|
| `claude-instance-check.sh` | Health check — running instances, apps, profiles |
| `claude-apps-refresh.sh` | Rebuild copies. `all` (default), `personal`, `enterprise`, `--status` |
| `claude-recolor-icon.sh` | Regenerate a coloured icon master: `claude-recolor-icon.sh <hue> <out.icns>` |

Icon masters live outside the bundles so rebuilds keep them:

```
~/.local/share/claude-personal/appicon.icns      green (hue 142)
~/.local/share/claude-enterprise/appicon.icns    blue  (hue 212)
```

Lost one? Regenerate and rebuild:

```bash
~/bin/claude-recolor-icon.sh 212 ~/.local/share/claude-enterprise/appicon.icns
~/bin/claude-apps-refresh.sh enterprise
```

Regeneration is deterministic but not byte-identical to the original master (rounding
differs by up to 10/255 per channel). Visually indistinguishable.

Other hues: red 0 · orange 30 · yellow 55 · teal 175 · purple 275 · pink 320.

---

## How the build works

Each copy is made by `claude-apps-refresh.sh`:

1. **`cp -Rc`** — APFS clonefile copy of `Claude.app`. Unchanged files share blocks, so
   each copy costs ~2 MB real despite reporting ~825 MB.
2. **Patch `Info.plist`** — new `CFBundleIdentifier`, `CFBundleDisplayName`,
   `CFBundleIconFile`, `CFBundleExecutable`.
3. **Install the coloured icon** into `Contents/Resources/appicon.icns`.
4. **Write a launcher** at `Contents/MacOS/launcher` that pins the profile and the CPU
   architecture.
5. **Re-sign** the main binary and the outer bundle, ad-hoc.

### Why each choice — do not "simplify" these

| Choice | Reason |
|---|---|
| `cp -Rc` (clone) | 2 MB instead of 823 MB per copy |
| Re-sign **only** the main binary + outer bundle | The binary's signature seals `Info.plist`, which we edit, so it must be re-signed. Re-signing the 381 MB Electron Framework rewrites it and destroys the clone. Mixed signatures load fine because we sign **without** hardened runtime, so library validation (which demands matching Team IDs) is off |
| `CFBundleName` stays `"Claude"` | Electron derives the helper-app name from it. Anything else fails at launch with `FATAL: Unable to find helper app`. `CFBundleDisplayName` is what the Dock shows |
| Delete `CFBundleIconName` | It points into `Assets.car` (Claude's own icon) and **outranks** `CFBundleIconFile`. Leave it and you get the orange icon back |
| Delete `CFBundleURLTypes` | Stops the copies fighting stock Claude over `claude://` and `msauth://` links |
| `arch -arm64` in the launcher | **Critical.** See below |
| No `--deep` on codesign | `--deep` follows symlinks and would try to re-sign `/Applications/Claude.app` in place |

---

## Traps

### 1. The Rosetta trap (the big one)

**Never `exec` Claude's binary directly from a shell script.** It is a universal binary
(x86_64 + arm64). A script-launched `exec` inherits the wrapper's architecture
preference, which resolves to **x86_64**, and Claude silently runs the Intel slice under
Rosetta on Apple Silicon. Symptoms: painfully slow typing, a renderer pegged at 100%+ CPU.

Use `open -n -a` (LaunchServices picks the native slice) or `arch -arm64` explicitly.
The launcher does the latter.

**How to spot it:** Activity Monitor → **Kind** column. `Apple` = native, `Intel` = Rosetta.
Or:

```bash
lsappinfo list | grep -A1 "pid = <PID>" | grep -o 'Arch=[A-Za-z0-9_]*'
```

### 2. `open -n`, not `open -a`

Without `-n`, LaunchServices *activates* an already-running instance instead of starting
a second one. This mattered more before the copies had distinct identities, but the rule
stands for any manual launch.

### 3. A thin wrapper can never recolour the running Dock tile

The original approach was a 20 KB wrapper `.app` that launched stock Claude with
`--user-data-dir`. It works and costs nothing, but the *running* process belongs to
`Claude.app`, so the Dock always showed the orange icon and the name "Claude". Only a
standalone copy with its own bundle identity gets its own tile. That is the entire
reason these copies exist.

### 4. codesign rejects symlinks that escape the bundle

The icon cannot live outside `Contents/Resources` via a symlink —
`invalid destination for symbolic link in bundle`. Hence icon masters are *copied* in at
build time from `~/.local/share/`.

---

## Recovery scenarios

### Login broken / signed out after a rebuild

Re-signing drops Anthropic's team-scoped entitlements (`keychain-access-groups` for
MSAL/Entra SSO and WebAuthn). Those are prefixed with Anthropic's Team ID and **cannot**
be reproduced under any other signing identity.

**Verified working on the author's setup** — enterprise SSO signs in fine. But if login ever
breaks after an update, this is the first suspect. Expect a keychain prompt after a
rebuild (click **Allow**), and possibly a fresh sign-in.

Fall back to stock Claude while you investigate: launch `/Applications/Claude.app` for
personal, and the profiles are untouched.

### An app won't launch at all

```bash
codesign --verify --strict "/Applications/Claude Enterprise.app"   # should be silent
~/bin/claude-apps-refresh.sh enterprise                            # rebuild
```

Run it from Terminal to see the real error:

```bash
"/Applications/Claude Enterprise.app/Contents/MacOS/launcher"
```

`Unable to find helper app` means `CFBundleName` is no longer `"Claude"`.

### Icon went orange again

`CFBundleIconName` came back (it outranks `CFBundleIconFile`). Rebuild. If the icon is
right in the bundle but stale in Finder, it's the icon cache:

```bash
killall Finder
```

### Profile corrupted / conversations missing

Restore a backup — these are APFS clones, so they cost nothing and restore instantly:

```
~/Library/Application Support/Claude.backup-YYYYMMDD-HHMMSS             (personal)
~/Library/Application Support/Claude-Enterprise.backup-YYYYMMDD-HHMMSS  (enterprise)
```

```bash
# quit the app first
mv "$HOME/Library/Application Support/Claude-Enterprise" "$HOME/Library/Application Support/Claude-Enterprise.bad"
cp -Rc "$HOME/Library/Application Support/Claude-Enterprise.backup-YYYYMMDD-HHMMSS" \
       "$HOME/Library/Application Support/Claude-Enterprise"
```

Take a fresh backup before risky changes — it is free and instant:

```bash
cp -Rc "$HOME/Library/Application Support/Claude-Enterprise" \
       "$HOME/Library/Application Support/Claude-Enterprise.backup-$(date +%Y%m%d-%H%M%S)"
```

### Full teardown — back to one stock Claude

```bash
rm -rf "/Applications/Claude Personal.app" "/Applications/Claude Enterprise.app"
```

Profiles survive. Stock `Claude.app` picks up the personal profile automatically. The
enterprise profile stays on disk; reach it again by rebuilding, or temporarily with:

```bash
open -n -a "/Applications/Claude.app" --args \
  --user-data-dir="$HOME/Library/Application Support/Claude-Enterprise"
```

### Rebuild everything from nothing

If both apps and both icon masters are gone but `Claude.app` and the profiles remain:

```bash
~/bin/claude-recolor-icon.sh 142 ~/.local/share/claude-personal/appicon.icns
~/bin/claude-recolor-icon.sh 212 ~/.local/share/claude-enterprise/appicon.icns
~/bin/claude-apps-refresh.sh
~/bin/claude-instance-check.sh
```

---

## Backups and locations

| What | Where |
|---|---|
| Personal profile backup | `~/Library/Application Support/Claude.backup-YYYYMMDD-HHMMSS` |
| Enterprise profile backup | `~/Library/Application Support/Claude-Enterprise.backup-YYYYMMDD-HHMMSS` |
| Retired thin wrappers + superseded script | `~/Documents/Claude/_trash/` |
| Icon masters | `~/.local/share/claude-personal/`, `~/.local/share/claude-enterprise/` |
| Scripts | `~/bin/claude-*.sh` |

`/Applications/Claude.app` is **never modified** by any of this — every script only reads
it. Verify at any time:

```bash
codesign --verify --strict /Applications/Claude.app && echo "untouched"
```

---

## Credits

The wrapper approach, and the observation that truly distinct running Dock icons require
a full standalone copy, come from
<https://gist.github.com/aoxborrow/5a3a0ac0aa37819cc19439b70a552221>.
