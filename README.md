# Usage Touch Bar

Native macOS menu bar utility that shows Claude Code and Codex usage details in the Touch Bar.

## Current status

This is an initial working scaffold:

- AppKit menu bar process.
- `NSTouchBar` with two provider buttons: Codex and Claude.
- Selected-provider detail tile with hours used, daily usage percent, reset time, and weekly usage percent.
- Account connection panel that checks local Codex and Claude Code login state before showing usage.
- Manual refresh and 60-second background refresh.
- Local log/state-file collectors with conservative heuristics for token/event counters.
- Popover summary from the menu bar item.
- Small focus host panel that makes the app active so macOS will show its Touch Bar controls.

The provider collectors currently look for local usage files in common locations and count token/event hints. The exact provider quota contracts should be tightened once the real local files or APIs you want to use are confirmed.

## Build and run

```sh
swift build
.build/debug/usage-touchbar
```

The app runs as an accessory/menu bar process. Quit it from the `Usage` menu bar item.

If the menu bar item appears but the Touch Bar does not change, choose **Focus Touch Bar** from the `Usage` menu. macOS only shows an app's Touch Bar content while that app has focus.

## Touch Bar pinning

The app presents its Touch Bar UI by default when the app is active, makes the selected-provider details the principal Touch Bar item, and opens a small focus host panel on launch. The Touch Bar shape is:

```text
[Codex] [Claude]  Codex : 5 hrs usage : 39%
                  Reset : 21:07
                  Weekly usage : 40%
```

macOS does not allow third-party apps to silently pin themselves into the system Control Strip by default. To keep it globally available, pin it manually:

1. Open **System Settings**.
2. Go to **Keyboard**.
3. Open **Touch Bar Settings** or **Customize Control Strip**.
4. Add/pin the app's Touch Bar control if macOS exposes it for your version.

If your macOS version does not expose third-party Control Strip pinning, the reliable behavior is app-scoped Touch Bar content while Usage Touch Bar is active. Public AppKit APIs do not allow an app to silently add itself next to brightness and volume.

## Provider data paths

Initial search paths:

- Claude: `~/.claude`, `~/Library/Application Support/Claude`, `~/Library/Logs/Claude`
- Codex: `~/.codex`, `~/Library/Application Support/Codex`, `~/Library/Logs/Codex`

Login state detection:

- Claude: `~/.claude.json`, `~/.claude/.credentials.json`, `~/.claude/config.json`, `~/.config/claude/credentials.json`
- Codex: `~/.codex/auth.json`, `~/.codex/config.toml`

Next implementation step: replace the heuristic collectors with provider-specific parsers once sample files are available.
