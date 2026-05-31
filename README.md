# Usage Touch Bar

Real-time **Claude Code, Codex, and OpenCode** usage limits in the macOS Touch
Bar Control Strip — one single background app, no Dock icon, **no menu-bar
icon**.

## What it shows

An always-visible Control Strip glyph with a mini gauge per provider. Tap it to
expand the full Touch Bar with each provider's 5-hour and weekly usage, reset
countdowns, and a refresh button.

- **Claude** — live limits from Claude Code's `/usage` endpoint (falls back to a
  local estimate from `~/.claude/projects` when offline).
- **Codex** — rate limits from `~/.codex/sessions` rollout telemetry.
- **OpenCode** — token usage estimated from `~/.local/share/opencode` storage.

Providers you aren't signed into simply show `–`.

## Build, sign & install

```bash
./scripts/build-and-sign.sh          # release build → signed → installed to ~/Applications
./scripts/build-and-sign.sh --run    # …and launch it
```

This builds **one** app bundle (`UsageTouchBar.app`), signs it with a stable
self-signed identity, strips the quarantine flag, and installs it to
`~/Applications`.

### About the password prompt

The app reads Claude's OAuth token. To minimize the macOS "allow access" prompt
it now reads `~/.claude/.credentials.json` **first** (no Keychain, no prompt) and
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
- Changes take effect on the next launch.

The Claude budgets are only used for the offline estimate; Anthropic does not
publish exact limits, so tune them to your plan.

## Quitting

There is no menu bar, so quit with:

```bash
pkill -x usage-touchbar
```

## Requirements

- macOS 13+ with a Touch Bar
- Swift 6 toolchain
