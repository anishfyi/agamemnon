# Agamemnon

Native macOS menu-bar app that monitors token usage and token abuse across local AI coding CLIs: Claude Code (claude-work profile), Kimi Code CLI, and Cursor CLI.

![Screenshot placeholder](docs/screenshot-placeholder.png)

## Features

- Live menu-bar title with today's total tokens (e.g. `⛨ 1.2M`), warning color when alerts are active
- Per-source today totals, 5-hour and 7-day burn, burn rate (tokens/min), active alert count
- Admin panel: Overview charts, Sessions table, Abuse alerts, Settings
- Incremental JSONL / SQLite parsers with a local cache at `~/Library/Application Support/Warden/warden.db`
- Abuse rules: burn spike, daily cap, cache-miss anomaly, loop detection
- No network access. No telemetry. Everything stays on disk.

## Requirements

- macOS 13+
- Swift 5.9+ / Xcode Command Line Tools

## Build

```bash
./build.sh
```

This produces `Warden.app` in the repo root. Debug build: `./build.sh debug`.

Run tests (standalone runner; works with Xcode CLT, no XCTest required):

```bash
swift build --product WardenTests && .build/debug/WardenTests
```

## Run

```bash
open Warden.app
```

Unsigned personal-tool distribution. If macOS blocks the app:

```bash
xattr -cr /Applications/Warden.app
# or, from the build directory:
xattr -cr ./Warden.app
```

Quit from the menu-bar dropdown, or pause monitoring without quitting.

## Data sources

| Source | Path | Notes |
|--------|------|-------|
| Claude Code (work) | `~/.claude-work/projects/<slug>/<session>.jsonl` | Priority source. Counts assistant `usage` once per message id. |
| Claude Code | `~/.claude/projects` | Optional, enabled in Settings |
| Claude Code (personal) | `~/.claude-personal/projects` | Optional |
| Kimi Code CLI | `~/.kimi-code/sessions/*/session_*/agents/*/wire.jsonl` | `inputOther` / `output` / cache fields |
| Cursor CLI | `~/.cursor/ai-tracking/ai-code-tracking.db` plus `debug-logs/` and `chats/` | Activity always; token counts only when present locally. Otherwise the UI shows: `cursor: activity only, tokens unavailable` |

Paths and enable toggles are editable under Settings.

## Privacy

Everything stays on disk, nothing leaves the machine. Warden never opens network connections for telemetry or reporting.

## License

Personal tool. Use freely on your own machines.
