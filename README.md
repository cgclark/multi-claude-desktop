# Multiple Claude Desktop Instances (macOS)

Run as many Claude Desktop instances as you like — personal, work, a client account, a
scratch profile — side by side, each with its own account, its own profile, and its own
coloured Dock icon.

Claude Desktop accepts Electron's `--user-data-dir`, so isolating a second profile is
easy. Giving each instance its own **Dock icon** is not: a thin wrapper `.app` can't do
it, because the running process belongs to whichever bundle it launched. So each
instance is built as a standalone copy with its own bundle identity — costing **~2 MB**
thanks to APFS cloning, rather than an 823 MB duplicate.

Built on Apple Silicon with an APFS volume. On Intel, drop the `arch -arm64` pin.

---

## Daily use

| Click | App | Profile |
|---|---|---|
| 🟢 green | `/Applications/Claude Personal.app` | `~/Library/Application Support/Claude` |
| 🔵 blue | `/Applications/Claude Enterprise.app` | `~/Library/Application Support/Claude-Enterprise` |
| 🟠 coral | `/Applications/Claude.app` | **don't click it** |

**Keep only the coloured apps in your Dock.** Stock `Claude.app` is the *source* the
copies are built from, plus the thing that downloads Claude updates. Launching it starts
another instance on the personal profile — two processes on one database.

```bash
claude-instance-check.sh      # health check
claude-apps-refresh.sh --list # what's configured
```

---

## Adding an instance

Instances are defined in `~/.config/claude-instances/instances.conf`:

```
# name | bundle id | profile dir | icon hue | env (optional)
Personal   | com.example.claude-personal   | ~/Library/Application Support/Claude            | 142 |
Enterprise | com.example.claude-enterprise | ~/Library/Application Support/Claude-Enterprise | 212 | CLAUDE_CONFIG_DIR=~/.claude-work
```

Add a line and rebuild — the icon is generated automatically from the hue:

```bash
echo 'Client | com.example.claude-client | ~/Library/Application Support/Claude-Client | 320' \
  >> ~/.config/claude-instances/instances.conf
claude-apps-refresh.sh client
```

That produces `/Applications/Claude Client.app` with a pink icon, its own bundle
identity, and an empty profile ready to sign in to. Roughly 2 MB and a few seconds.

Hues: `0` red · `30` orange · `55` yellow · `142` green · `175` teal · `212` blue ·
`275` purple · `320` pink.

### Per-instance environment

The optional 5th column exports environment variables before the app starts —
semicolon-separated `KEY=VALUE` pairs, leading `~` expanded.

**This is the only way to give an instance its own environment.** A macOS `.app` does not
inherit your shell environment, so `export` in `.zshrc` has no effect on a Dock launch.
Because the variables are set before `exec`, everything the app spawns inherits them —
including Claude Code in agent mode.

The motivating case is `CLAUDE_CONFIG_DIR`. Claude Code reads hooks from
`$CLAUDE_CONFIG_DIR/settings.json` and stores agent-mode session history in
`$CLAUDE_CONFIG_DIR/projects/`. Left at the default, every instance shares `~/.claude`, so
hooks from a work instance fire against your personal configuration. Setting it per
instance splits both.

```
Enterprise | com.example.claude-enterprise | …/Claude-Enterprise | 212 | CLAUDE_CONFIG_DIR=~/.claude-work
```

Verify it actually reached the process — a launcher that silently lost the export looks
identical from the outside:

```bash
claude-apps-refresh.sh --verify                        # the export is in the launcher
ps eww -o command= -p <pid> | tr ' ' '\n' | grep CLAUDE_CONFIG_DIR
```

⚠️ **Pointing an instance at a new config dir does not bring its history along.** Agent-mode
sessions live in `$CLAUDE_CONFIG_DIR/projects/<encoded-path>/*.jsonl`. Switch the variable
and the app looks somewhere new — past sessions appear to vanish, though nothing is
deleted. Copy them across before you switch, or afterwards:

```bash
cp -Rc ~/.claude/projects/<dir> ~/.claude-work/projects/
```

Watch for a config dir that already holds a **stale copy** of the same session id: the app
will show the older one and the newer history looks lost. Compare entry counts and last
timestamps rather than file mtimes, which can be misleading.

Rules the builder enforces, because both are silently destructive:

- **Bundle ids must be unique.** Two instances sharing one id are the same app to macOS.
- **Profiles must be unique.** Two instances on one profile can corrupt it.

Changing an instance's bundle id later forces a fresh sign-in for that instance — macOS
treats it as a different app for keychain purposes.

### What is isolated, and what is not

Everything under `~/Library/Application Support/<profile>` is per-instance: account,
conversations, settings, MCP config, caches — **and Cowork files**. On macOS the Cowork
user-files location resolves under Electron's `userData`, which is the profile, so each
instance gets its own by default. `scratch-workspaces/` and `cowork-enabled-cli-ops.json`
live inside the profile directory for the same reason.

(Claude's `NSDocumentsFolderUsageDescription` mentions storing "scheduled tasks, live
artifacts and other Cowork files" in Documents, which is easy to misread. That is a TCC
prompt string. In the app, `getPath('documents')` is used on **Windows only** — on macOS
Documents is never the Cowork location. `~/Documents/Claude`, if you have one, is your own
folder, not something Claude manages.)

Claude Code's config — hooks, agent-mode session history — is **not** in the profile. It
lives in `$CLAUDE_CONFIG_DIR`, default `~/.claude`, which is shared by every instance
unless you set it per instance. See [Per-instance environment](#per-instance-environment).

| | Isolated per instance | Shared |
|---|---|---|
| Account, conversations, settings, MCP config | ✅ | |
| Keychain / login | ✅ | |
| Cowork files, scratch workspaces | ✅ | |
| Claude Code hooks + agent-mode sessions | ✅ *once `CLAUDE_CONFIG_DIR` is set* | ⚠️ otherwise |
| SSH keys, git config, the rest of your home dir | | ⚠️ always |

**The last row is the one that matters** and no amount of configuration here fixes it.
Every instance runs as the same Unix user with the same permissions, so an MCP server or
agent running in one instance can read files belonging to another. This setup gives you
*organisational* separation — separate accounts, separate histories, separate icons — not
a boundary the OS enforces. If you need the latter, for a client with confidentiality
obligations, use a **separate macOS user account**: separate home, keychain, TCC grants
and processes that genuinely cannot read across. In that model each account just runs
stock Claude and this tooling is unnecessary.

**Choosing an explicit Cowork location.** `coworkUserFilesPath` is an optional, persisted,
per-profile config key. Set it if you want a named folder per instance
(`~/Documents/Claude-Client`) rather than the in-profile default — the app verifies a
stored path and falls back if it cannot. That is for your convenience; the default is
already per-instance.

Finally: each instance has a **new bundle identity**, so macOS treats it as a brand-new
app. Expect fresh permission prompts for Documents, Desktop, Downloads, Microphone and
Screen Recording, plus a full first-run setup against an empty profile.

---

## ⚠️ Recovery after Claude.app updates

**This is the one maintenance task.**

### What happens

Each instance is a **point-in-time copy** of `Claude.app`, made with APFS cloning, and
fully independent once made. When `Claude.app` updates itself, the copies **do not
change** — they keep running the old version, silently and indefinitely.

Worse: `Claude.app` only updates itself **when it runs**. If you only ever launch the
coloured copies, nothing updates anything, and everything freezes at the version it was
built at.

### Symptoms you are stale

- New Claude features in the release notes but not in your apps
- `claude-apps-refresh.sh --status` shows a version mismatch
- Disk usage creeping up (see *Disk creep*)

### The routine — every few weeks

```bash
# 1. Check for drift
claude-apps-refresh.sh --status

# 2. Launch STOCK Claude, let it update itself, then quit it (Cmd-Q)
open -a "/Applications/Claude.app"

# 3. Quit every coloured app (Cmd-Q) -- the rebuild refuses to touch a running app

# 4. Rebuild
claude-apps-refresh.sh

# 5. Verify
claude-apps-refresh.sh --status
claude-instance-check.sh
```

Step 2 is the one people skip. Without it there is no new version to rebuild *from*, and
step 4 just reproduces the same version.

### What a rebuild touches

| Preserved | Rebuilt from scratch |
|---|---|
| Every profile (accounts, conversations, settings, MCP config) | The app bundles |
| Instance config and icon masters | Bundle identity, launcher, signature |

Profiles live **outside** the bundles, which is why rebuilding is safe. The bundle is
disposable; the profile is the asset.

### Disk creep

Each instance normally costs ~2 MB real, because APFS clone-sharing means unchanged
files share blocks with `Claude.app`. **A Claude update breaks that sharing** — old
blocks are retained for your copies and real usage climbs toward the full 823 MB each.
Rebuilding re-establishes sharing and reclaims it. Another reason not to skip the refresh.

```bash
df -h /     # real usage; Finder will always claim ~825 MB per copy
```

### If a rebuild fails partway

The builder `rm -rf`s the target *before* copying, so a failure can leave an app missing.
Your data is untouched — just re-run it:

```bash
claude-apps-refresh.sh personal    # or any instance name, or with no argument for all
```

If the source itself is broken, reinstall Claude, then rebuild.

### If Claude.app updates while a copy is running

Nothing breaks. The running copy holds its own cloned files. Quit and rebuild whenever.

### ⚠️ "Update available" *inside* a coloured instance — don't click it

Each copy carries Claude's own updater (Squirrel/ShipIt). Squirrel replaces the bundle
**at its own path** — so an update accepted inside `Claude Enterprise.app` would try to
overwrite *that* app, not stock Claude. The bundle is user-writable, so nothing on the
filesystem stops it.

In practice it will most likely **fail**: ShipIt validates the downloaded app's code
signature against the running one. The copies are ad-hoc signed (no Team ID, identifier
`com.example.claude-*`) while the download is Developer ID signed by Anthropic, so the
check should reject it — possibly with a vague or silent error.

But if it ever *succeeds*, it overwrites the instance's identity:

| | Before | After a successful in-app update |
|---|---|---|
| `CFBundleIdentifier` | `com.example.claude-enterprise` | `com.anthropic.claudefordesktop` |
| `CFBundleExecutable` | `launcher` | `Claude` |
| Icon | your colour | orange |

Losing `CFBundleExecutable=launcher` is the damaging part: the launcher is what injects
`--user-data-dir`. Without it, that app falls back to Electron's **default profile** —
your personal one — so two apps end up on one profile, which is exactly the collision
`claude-instance-check.sh` exists to catch.

**So: dismiss update prompts inside the coloured apps.** Update stock `Claude.app`
instead, then rebuild (see the routine above).

To check whether an instance still has its identity:

```bash
claude-apps-refresh.sh --verify
```

```
Identity check:
  Claude Personal        ok
  Claude Enterprise      CLOBBERED -- bundle-id=com.anthropic.claudefordesktop executable=Claude bad-signature
```

Exit 1 if any instance was clobbered. The fix is always the same — rebuild it.

*(Reasoned from the bundle's updater machinery and signing state, not observed: at the
time of writing there was no pending update to test against.)*

---

## Health check

```bash
claude-instance-check.sh
```

```
PID       APP                     PROFILE
79012     Claude Personal         ~/Library/Application Support/Claude
79210     Claude Enterprise       ~/Library/Application Support/Claude-Enterprise

Instances running: 2    Distinct profiles: 2
OK: every running instance has its own profile.
```

- **Exit 0** — healthy. One instance running is fine; that is not an error.
- **Exit 1** — **profile collision**: two or more processes on one profile, each row
  flagged `<-- COLLISION`. Quit all but one immediately; concurrent writes to one
  LevelDB can corrupt it.

The collision case is the whole point of the check, and it is easy to hit by accident —
launching stock `Claude.app` while `Claude Personal` is open does it, since both default
to the same profile.

It matches executables ending in `/Contents/MacOS/Claude`, catching every copy while
excluding `Claude Helper` processes.

---

## Scripts

In `~/bin` (keep it on your `PATH`).

| Script | What it does |
|---|---|
| `claude-instance-check.sh` | Health check; detects profile collisions |
| `claude-apps-refresh.sh` | Build/rebuild instances. No args = all; or a name; `--status`; `--list`; `--verify` |
| `claude-recolor-icon.sh` | Generate an icon master: `claude-recolor-icon.sh <hue> <out.icns>` |

Config and assets:

```
~/.config/claude-instances/instances.conf     instance definitions
~/.local/share/claude-instances/<name>.icns   icon masters (auto-generated)
```

Icon masters live outside the bundles so rebuilds keep them. Delete one and the next
build regenerates it from the configured hue. Regeneration is deterministic but not
byte-identical to a previous master (rounding differs by up to 10/255 per channel);
visually indistinguishable.

---

## How the build works

For each instance, `claude-apps-refresh.sh`:

1. **`cp -Rc`** — APFS clonefile copy of `Claude.app`. Unchanged files share blocks.
2. **Patches `Info.plist`** — bundle id, display name, icon, executable.
3. **Installs the icon**, generating it from the hue if missing.
4. **Writes a launcher** pinning the profile and the CPU architecture.
5. **Re-signs** the main binary and outer bundle, ad-hoc.

### Why each choice — don't "simplify" these

| Choice | Reason |
|---|---|
| `cp -Rc` (clone) | ~2 MB instead of 823 MB per instance |
| Re-sign **only** main binary + outer bundle | The binary's signature seals `Info.plist`, which we edit, so it must be re-signed. Re-signing the 381 MB Electron Framework rewrites it and destroys the clone. Mixed signatures load fine because we sign **without** hardened runtime, so library validation (which demands matching Team IDs) is off |
| `CFBundleName` stays `"Claude"` | Electron derives the helper-app name from it. Anything else fails at launch with `FATAL: Unable to find helper app`. `CFBundleDisplayName` is what the Dock shows |
| Delete `CFBundleIconName` | Points into `Assets.car` (Claude's own icon) and **outranks** `CFBundleIconFile`. Leave it and the orange icon comes back |
| Delete `CFBundleURLTypes` | Stops copies fighting over `claude://` and `msauth://` links |
| `arch -arm64` in the launcher | **Critical** — see below |
| No `--deep` on codesign | `--deep` follows symlinks and would re-sign `/Applications/Claude.app` in place |

---

## Traps

### 1. The Rosetta trap (the big one)

**Never `exec` Claude's binary directly from a shell script.** It is a universal binary
(x86_64 + arm64). A script-launched `exec` inherits the wrapper's architecture
preference, which resolves to **x86_64**, so Claude silently runs the Intel slice under
Rosetta on Apple Silicon. Symptoms: painfully slow typing, a renderer pegged above 100%
CPU.

Use `open -n -a` (LaunchServices picks the native slice) or `arch -arm64` explicitly.
The generated launcher does the latter.

**Spot it:** Activity Monitor → **Kind** column. `Apple` = native, `Intel` = Rosetta. Or:

```bash
lsappinfo list | grep -A1 "pid = <PID>" | grep -o 'Arch=[A-Za-z0-9_]*'
```

### 2. `open -n`, not `open -a`

Without `-n`, LaunchServices *activates* an already-running instance instead of starting
another. Matters for any manual launch.

### 3. A thin wrapper can't recolour the running Dock tile

The first attempt was a 20 KB wrapper `.app` launching stock Claude with
`--user-data-dir`. It works and costs nothing, but the *running* process belongs to
`Claude.app`, so the Dock showed the orange icon and the name "Claude". Only a standalone
copy with its own identity gets its own tile. That is why these copies exist.

### 4. codesign rejects symlinks that escape the bundle

The icon can't live outside `Contents/Resources` via a symlink —
`invalid destination for symbolic link in bundle`. Masters are *copied* in at build time.

---

## Recovery scenarios

### Login broken / signed out after a rebuild

Re-signing drops Anthropic's team-scoped entitlements (`keychain-access-groups` for
MSAL/Entra SSO and WebAuthn). Those carry Anthropic's Team ID and **cannot** be
reproduced under any other signing identity.

**Verified working on the author's setup** — enterprise SSO signs in fine. If login ever
breaks after an update, this is the first suspect. Expect a keychain prompt after a
rebuild (click **Allow**), and possibly a fresh sign-in.

Fall back to stock Claude while investigating; profiles are untouched.

### An app won't launch

```bash
codesign --verify --strict "/Applications/Claude Enterprise.app"   # should be silent
claude-apps-refresh.sh enterprise
```

Run the launcher from Terminal to see the real error:

```bash
"/Applications/Claude Enterprise.app/Contents/MacOS/launcher"
```

`Unable to find helper app` means `CFBundleName` is no longer `"Claude"`.

### Icon went orange again

`CFBundleIconName` came back — it outranks `CFBundleIconFile`. Rebuild. If the bundle is
right but Finder is stale, it's the icon cache: `killall Finder`.

### Profile corrupted / conversations missing

Restore a backup. These are APFS clones — free to make, instant to restore:

```bash
# quit the app first
mv "$HOME/Library/Application Support/Claude-Enterprise" \
   "$HOME/Library/Application Support/Claude-Enterprise.bad"
cp -Rc "$HOME/Library/Application Support/Claude-Enterprise.backup-YYYYMMDD-HHMMSS" \
       "$HOME/Library/Application Support/Claude-Enterprise"
```

Take one before any risky change — free and instant:

```bash
cp -Rc "$HOME/Library/Application Support/Claude-Enterprise" \
       "$HOME/Library/Application Support/Claude-Enterprise.backup-$(date +%Y%m%d-%H%M%S)"
```

### Removing an instance

```bash
rm -rf "/Applications/Claude Client.app"
# then delete its line from ~/.config/claude-instances/instances.conf
```

The profile survives; delete it separately if you actually want the data gone.

### Full teardown — back to one stock Claude

```bash
rm -rf "/Applications/Claude Personal.app" "/Applications/Claude Enterprise.app"
```

Profiles survive. Stock `Claude.app` picks up the personal profile automatically. Reach
another profile temporarily with:

```bash
open -n -a "/Applications/Claude.app" --args \
  --user-data-dir="$HOME/Library/Application Support/Claude-Enterprise"
```

### Rebuild everything from nothing

If the apps and icon masters are gone but `Claude.app`, the config, and the profiles
remain:

```bash
claude-apps-refresh.sh          # icons regenerate from the configured hues
claude-instance-check.sh
```

---

## Locations

| What | Where |
|---|---|
| Instance config | `~/.config/claude-instances/instances.conf` |
| Icon masters | `~/.local/share/claude-instances/<name>.icns` |
| Scripts | `~/bin/claude-*.sh` |
| Profile backups | `~/Library/Application Support/Claude*.backup-*` |

`/Applications/Claude.app` is **never modified** — every script only reads it:

```bash
codesign --verify --strict /Applications/Claude.app && echo "untouched"
```

---

## Credits

The wrapper approach, and the observation that truly distinct running Dock icons require
a full standalone copy, come from
<https://gist.github.com/aoxborrow/5a3a0ac0aa37819cc19439b70a552221>.
