# Usage Touch Bar

Native macOS menu bar utility that shows Claude Code and Codex usage details in the Touch Bar.

## Current status

- AppKit menu bar process.
- `NSTouchBar` with two provider buttons: Codex and Claude.
- Selected-provider detail tile with color-graded progress bars for the rolling
  5-hour and weekly limit windows, the consumed percentage, and the reset countdown.
- Account connection panel that checks local Codex and Claude Code login state before showing usage.
- Manual refresh and 60-second background refresh.
- Popover summary from the menu bar item.
- Small focus host panel that makes the app active so macOS will show its Touch Bar controls.

### How usage is read

The collectors parse the providers' real local telemetry — no estimates for Codex:

- **Codex** reads the latest session rollout files in `~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl`
  and uses the most recent `token_count` event. That event carries the account-wide
  `rate_limits.primary` (5-hour window) and `rate_limits.secondary` (weekly window) with
  `used_percent` and `resets_at`, plus cumulative token totals and the plan type.
- **Claude Code** does not expose a rate-limit percentage, so usage is the real
  total token throughput (including cache reads — what `/usage` reflects) from the
  per-message `usage` totals in `~/.claude/projects/**/*.jsonl`, aggregated over the
  rolling 5-hour and 7-day windows. The token total is exact; the **percentage is an
  estimate** against configurable budgets (Anthropic publishes no token figures).
  Override the budgets and plan label by creating `~/.config/usage-touchbar/config.json`:

  ```json
  {
    "claudeFiveHourTokenBudget": 90000000,
    "claudeWeeklyTokenBudget": 440000000,
    "claudePlanLabel": "Max 20x"
  }
  ```



## Build and run

```sh
swift build
.build/debug/usage-touchbar
```

The app runs as an accessory/menu bar process. Quit it from the `Usage` menu bar item.

If the menu bar item appears but the Touch Bar does not change, choose **Focus Touch Bar** from the `Usage` menu. macOS only shows an app's Touch Bar content while that app has focus.

## Touch Bar pinning

On macOS versions that expose the private Control Strip API, the app pins one
always-visible item in the Control Strip showing both providers as
`[app icon] %` pairs (using the real Anthropic and OpenAI/Codex app icons):

```text
 34%   39%
```

It is a single slot because macOS only surfaces one app item in the collapsed
Control Strip — a second item stays hidden behind the `<` expander — and it
hard-caps an item's width, clipping wide *text* titles (so the label is drawn as
a scalable image instead). Tapping the summary expands the full usage bar over
the strip, which has per-provider Codex/Claude buttons and the detail tile:

```text
[Codex] [Claude]  Claude  5h ▓▓▓░ 39%  Wk ▓░ 12%  ↻ 2h   [Refresh]
```

macOS controls where system-tray items sit in the Control Strip, so the exact
position (relative to the emoji/Siri keys) is chosen by the OS and can't be
pinned by the app.

When the Control Strip API is unavailable, the app presents its Touch Bar UI
while active, makes the selected-provider details the principal item, and opens
a small focus host panel on launch.

macOS does not allow third-party apps to silently pin themselves into the system Control Strip by default. To keep it globally available, pin it manually:

1. Open **System Settings**.
2. Go to **Keyboard**.
3. Open **Touch Bar Settings** or **Customize Control Strip**.
4. Add/pin the app's Touch Bar control if macOS exposes it for your version.

If your macOS version does not expose third-party Control Strip pinning, the reliable behavior is app-scoped Touch Bar content while Usage Touch Bar is active. Public AppKit APIs do not allow an app to silently add itself next to brightness and volume.

## Provider data paths

Usage data sources:

- Claude: `~/.claude/projects/**/*.jsonl` (per-message `usage` token totals)
- Codex: `~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl` (`token_count` rate-limit events)

Login state detection:

- Claude: `~/.claude.json`, `~/.claude/.credentials.json`, `~/.claude/config.json`, `~/.config/claude/credentials.json`
- Codex: `~/.codex/auth.json`, `~/.codex/config.toml`

