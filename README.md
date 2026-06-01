# Usage Touch Bar

Real-time **Claude Code, Codex, and OpenCode** usage limits in the macOS Touch
Bar Control Strip — one single background app, no Dock icon, **no menu-bar
icon**.

Ships as a **universal binary**, so the same app runs on both **Apple Silicon
(M-series)** and **Intel** Touch Bar MacBook Pros.

## What it shows

An always-visible Control Strip glyph with a mini gauge per provider. Tap it to
expand the full Touch Bar with each provider's 5-hour and weekly usage, reset
countdowns, and a refresh button. Data auto-refreshes every 20 seconds.

- **Claude** — live limits from Claude Code's `/usage` endpoint (falls back to a
  local estimate from `~/.claude/projects` when offline).
- **Codex** — real rate limits + token telemetry read from
  `~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl`. The collector scans the recent
  rollouts and always shows the globally newest `token_count` event, so a freshly
  created or resumed session never masks fresher usage data.
- **OpenCode** — token usage estimated from `~/.local/share/opencode` storage.

Providers you aren't signed into simply show `–`.

## Requirements

- A Mac **with a Touch Bar**:
  - **Apple Silicon** — M1/M2 13" MacBook Pro (2020 / 2022).
  - **Intel** — MacBook Pro with Touch Bar (2017–2019; 2016 models are limited to
    macOS 12 and below).
- **macOS 13 (Ventura) or newer.**
- **Swift 6 toolchain** (Xcode 16+) to build from source.

The release build is a universal (`arm64` + `x86_64`) Mach-O — no separate Intel
download is needed.

## Install

### Option 0 — Homebrew (CLI + Touch Bar accessory)

```bash
brew install neelashkannan/tap/usage-touchbar
```

That puts `usage-touchbar` on your `PATH`. From any terminal:

```bash
# Start the Touch Bar accessory + silent live refresh loop. Press ^C to exit.
usage-touchbar --touchbar

# One-shot status print (no Touch Bar, no TUI).
usage-touchbar status

# One-shot status print + Touch Bar accessory.
usage-touchbar status --touchbar

# Machine-readable JSON for piping into `jq` or other tools.
usage-touchbar status --json

# Bypass the live-API cache and re-fetch everything.
usage-touchbar refresh

# List providers + their login state.
usage-touchbar providers
```

Run `usage-touchbar help` for the full option list. The same binary is also
the "Touch Bar app" — running `usage-touchbar` with no arguments starts the
permanent-resident mode intended for the LaunchAgent (see Option B below).

### Option A — drag-to-install from the DMG

```bash
./scripts/build-and-sign.sh --dmg
```

This produces `dist/UsageTouchBar-<version>.dmg`. Open it and drag
**UsageTouchBar.app** onto the **Applications** shortcut. The same disk image
installs on both Intel and Apple Silicon Macs.

### Option B — build, sign & install in place

```bash
./scripts/build-and-sign.sh          # universal build → signed → installed to ~/Applications
./scripts/build-and-sign.sh --run    # …and launch it
```

Flags can be combined, e.g. `./scripts/build-and-sign.sh --run --dmg`.

The script:

1. Builds **one universal app bundle** (`UsageTouchBar.app`) containing both
   `arm64` and `x86_64` slices.
2. Signs it with a stable, self-signed identity (created once, reused after).
3. Strips the quarantine flag so Gatekeeper doesn't nag.
4. Installs it to `~/Applications` (user space → no admin password).
5. Installs/refreshes a LaunchAgent so exactly one instance runs and relaunches
   at login.
6. With `--dmg`, also packages a signed, distributable disk image into `dist/`.

You can confirm the architectures of the installed app at any time:

```bash
lipo -archs ~/Applications/UsageTouchBar.app/Contents/MacOS/usage-touchbar
# → x86_64 arm64
```

### About the password prompt

The app reads Claude's OAuth token. To minimize the macOS "allow access" prompt
it reads `~/.claude/.credentials.json` **first** (no Keychain, no prompt) and
only falls back to the Keychain when that file is absent. Because the app is one
bundle signed with a stable identity, clicking **"Always Allow"** once makes the
grant stick across rebuilds — you should not be asked again.

## Configuration

Create `~/.config/usage-touchbar/config.json` to arrange the providers:

```json
{
  "providers": [
    { "id": "claude",   "enabled": true },
    { "id": "codex",    "enabled": true },
    { "id": "opencode", "enabled": false }
  ],
  "claudeFiveHourTokenBudget": 90000000,
  "claudeWeeklyTokenBudget": 440000000,
  "claudePlanLabel": "Max 20x"
}
```

- **Order** — the array order is the left-to-right Touch Bar order.
- **Show / hide** — set `"enabled": false` (or drop the entry) to exclude a
  provider. Omit the whole `providers` array to show all three.
- Changes take effect on the next launch (or via the gear on the expanded Touch
  Bar).

The Claude budgets are only used for the offline estimate; Anthropic does not
publish exact limits, so tune them to your plan.

## Quitting

There is no menu bar, so quit with:

```bash
pkill -x usage-touchbar
```

To stop it relaunching at login, also unload the LaunchAgent:

```bash
launchctl unload ~/Library/LaunchAgents/com.neelashkannan.usage-touchbar.plist
```
