<p align="center">
  <img alt="AgamemnonConsole" src="Sources/Agamemnon/Resources/agamemnon.png" width="120">
</p>

# Agamemnon

Native macOS menu-bar app that monitors token spend across local AI coding CLIs: **Kimi Code CLI**, **Cursor CLI (cursor-agent)**, and **Claude Code (claude-work profile)**.

**Site:** [anishfyi.github.io/agamemnon](https://anishfyi.github.io/agamemnon/)

![Screenshot placeholder](docs/screenshot-placeholder.png)

## Features

- Live menu-bar helmet icon with today's total tokens, warning color when alerts are active
- Real-time spend dashboard: per-source cards in priority order (kimi, cursor, claude-work)
- Input/output/cache tokens, burn rate (tokens/min over last 15 min), estimated cost, and state (ok / warning / critical)
- 5-hour and weekly rolling window progress bars with configurable per-source limits
- Totals strip: combined spend today, this week, all-time
- Sessions table, abuse alerts, and configurable settings (default refresh: 5 seconds)
- Incremental JSONL / SQLite parsers with a local cache at `~/Library/Application Support/Agamemnon/agamemnon.db`
- Migrates data from `~/Library/Application Support/Warden/warden.db` on first run
- No network access. No telemetry. Everything stays on disk.

## Requirements

- macOS 13+
- Swift 5.9+ / Xcode Command Line Tools

## Build

```bash
./build.sh
```

This produces `Agamemnon.app` in the repo root. Debug build: `./build.sh debug`.

Run tests (standalone runner; works with Xcode CLT, no XCTest required):

```bash
swift build --product AgamemnonTests && .build/debug/AgamemnonTests
```

## Run

```bash
open Agamemnon.app
```

Unsigned personal-tool distribution. If macOS blocks the app:

```bash
xattr -cr /Applications/Agamemnon.app
# or, from the build directory:
xattr -cr ./Agamemnon.app
```

Quit from the menu-bar dropdown, or pause monitoring without quitting.

## Data sources

| Source | Path | Notes |
|--------|------|-------|
| Kimi Code CLI | `~/.kimi-code/sessions/*/session_*/agents/*/wire.jsonl` | Priority source. `inputOther` / `output` / cache fields |
| Cursor CLI | `~/.cursor/ai-tracking/ai-code-tracking.db` plus `debug-logs/` and `chats/` | Activity always; token counts only when present locally. Otherwise the UI shows: `cursor: activity only, tokens unavailable` |
| Claude Code (work) | `~/.claude-work/projects/<slug>/<session>.jsonl` | Counts assistant `usage` once per message id |
| Claude Code | `~/.claude/projects` | Optional, enabled in Settings |
| Claude Code (personal) | `~/.claude-personal/projects` | Optional |

Paths, enable toggles, and per-source window limits are editable under Settings.

## Privacy

Everything stays on disk, nothing leaves the machine. Agamemnon never opens network connections for telemetry or reporting.

## License

Personal tool. Use freely on your own machines.
