# Warden

A native macOS menu-bar app that monitors token usage and token abuse across local AI coding CLIs: **Claude Code (claude-work profile)**, **Kimi Code CLI**, and **Cursor CLI (cursor-agent)** — with a full admin panel.

This file is the build spec. Implement the app described here, completely.

## Product

- **Name:** Warden
- **Form:** macOS menu-bar app (LSUIElement agent app, no Dock icon) + an "admin panel" main window opened from the menu.
- **Stack:** Swift 5.9+, SwiftUI, Swift Charts, SQLite (via SQLite3 C API or GRDB if you add a package — prefer zero external deps, use SQLite3 directly). Xcode project or SwiftPM executable that produces an `.app` bundle (a `Makefile` or `build.sh` that yields `Warden.app` is required; an Xcode project is welcome but not required). Target macOS 13+.
- **Unsigned distribution**, like a personal tool: document `xattr -cr /Applications/Warden.app` in the README.

## Data sources (verified facts — do not guess)

### 1. Claude Code, `claude-work` profile (PRIORITY SOURCE)
- Transcripts: `~/.claude-work/projects/<slug>/<session-uuid>.jsonl`, one JSON object per line.
- Assistant-message lines carry: `"usage":{"input_tokens":N,"cache_creation_input_tokens":N,"cache_read_input_tokens":N,"output_tokens":N}` plus a `"timestamp"` (ISO 8601) and `"model"` on the message.
- Also support `~/.claude/projects` and `~/.claude-personal/projects` as optional extra profiles (configurable).
- Count each message once (dedupe by message `id` if present).

### 2. Kimi Code CLI
- Session wire logs: `~/.kimi-code/sessions/*/session_*/agents/*/wire.jsonl`, one JSON object per line.
- Usage objects look like: `"usage":{"inputOther":N,"output":N,"inputCacheRead":N,"inputCacheCreation":N}` with a timestamp on the enclosing record.

### 3. Cursor CLI (`cursor-agent`)
- Local activity DB: `~/.cursor/ai-tracking/ai-code-tracking.db` (SQLite; tables include `ai_code_hashes`, `scored_commits`, `conversation_summaries`) — use it for activity/commit-level stats.
- Token-level usage: investigate `~/.cursor/debug-logs/` and `~/.cursor/chats/`; extract token counts if present. If real token counts are not locally available, the app must say so honestly in the UI ("cursor: activity only, tokens unavailable") instead of fabricating numbers.
- Never block the other two sources on cursor parsing.

## Features

### Menu bar
- Live menu-bar title: today's total tokens across sources, compact format (e.g. `⛨ 1.2M`).
- Dropdown: per-source today totals, 5-hour and 7-day burn (Claude-style windows), current burn rate (tokens/min over last 15 min), active alert count, buttons: Open Warden (admin panel), Pause/Resume monitoring, Quit.
- Menu-bar icon/title turns warning-colored when an alert is active.

### Admin panel (main window)
Tabs or sidebar sections:
1. **Overview** — stacked area/bar chart of tokens per source per hour (last 24h) and per day (last 30d); cards: today, this week, all-time, est. cost.
2. **Sessions** — table of recent sessions (source, project/cwd, start, duration, tokens in/out/cache, est. cost), sortable, clickable for per-session message-count detail.
3. **Abuse** — alert list with rules engine. Built-in rules (all thresholds configurable):
   - **Burn spike:** tokens/min > 3× the trailing 7-day hourly average.
   - **Daily cap:** source total today > configurable cap (default 5M tokens).
   - **Cache-miss anomaly:** cache_read / total_input ratio drops below 30% over a rolling 20-message window (thrashing indicator).
   - **Loop detection:** > 50 billable messages in a session within 10 minutes (runaway agent).
   - Alerts can be acknowledged; firing shows a macOS notification (UNUserNotificationCenter) and menu-bar warning state.
4. **Settings** — source paths (editable, with defaults above), per-source enable toggles, pricing table (per-model USD per 1M input/output tokens, editable JSON, sensible defaults for Claude/Kimi/GPT model families), alert thresholds, polling interval (default 30s), launch-at-login toggle (SMAppService).

### Engine
- Poll + watch: re-parse changed files only (track file offsets / mtimes); persist parsed aggregates to a local SQLite cache at `~/Library/Application Support/Warden/warden.db` so restarts are cheap.
- All parsing must be tolerant: skip malformed lines, never crash on a partial write.
- No network access required. No telemetry.

## Quality bar
- Compiles cleanly with `xcodebuild` or `swift build` (whichever the project uses) on stock macOS + Xcode CLT; `build.sh` must produce a runnable `Warden.app`.
- Unit tests for the three parsers (fixture JSONL/SQLite under `Tests/`), run via `swift test` or a test target.
- README: screenshot placeholder, features, build/run instructions, data-source documentation, privacy note ("everything stays on disk, nothing leaves the machine").
- No em-dashes (U+2014) anywhere in the repo. Use commas, colons, or periods instead.
