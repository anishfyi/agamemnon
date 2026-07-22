<p align="center">
  <img alt="AgamemnonConsole" src="Sources/Agamemnon/Resources/agamemnon.png" width="120">
</p>

# Agamemnon

Native macOS menu-bar app that tracks what your local AI coding CLIs are actually costing you, and how close they are to their limits.

**Site:** [anishfyi.github.io/agamemnon](https://anishfyi.github.io/agamemnon/)

![Screenshot placeholder](docs/screenshot-placeholder.png)

## What it does

Ten CLIs write token usage somewhere on disk in ten different shapes. Agamemnon reads all of them, prices them correctly, and shows one live picture.

- **Correct cost.** Per model, with the real cache multipliers: cache reads at 0.1x the input rate, 5-minute cache writes at 1.25x, 1-hour writes at 2x. Charging every input-side token at the full rate, as naive accounting does, overstates a cache-heavy agent workload by roughly 3x.
- **Meaningful quota bars.** Windows are measured in input-token-equivalents rather than raw tokens. A raw count is about 95% cache reads, so it tracks cache size instead of spend.
- **Real limits, not guesses.** Claude Code records limit hits in its own transcripts. Agamemnon parses those, shows the actual reset time the CLI reported, and calibrates the limit from what was consumed in the blocks that filled up. Every bar is labelled `measured`, `estimated`, or `user-set` so an assumed number is never mistaken for a real quota.
- **Plan auto-detection.** The subscription tier is read from the CLI's own config, not picked from a menu.
- **Suggestions.** Local heuristics over your history: cache thrashing, 1-hour cache premium paid on sessions that never idle, premium models doing low-output work, sessions long enough that resending history dominates cost, and repeated limit hits. Each finding cites the mechanism behind it.
- **Auto-detect.** Any supported CLI whose data directory exists is monitored. No enumeration needed.

## Requirements

- macOS 13+
- Swift 5.9+ / Xcode Command Line Tools

## Build

```bash
./build.sh
```

This runs the tests, then produces `Agamemnon.app` in the repo root, including a generated `AppIcon.icns`. Debug build: `./build.sh debug`.

Run the tests alone (standalone runner, no XCTest required):

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

| Source | Path | What it yields |
|--------|------|----------------|
| Claude Code (work) | `~/.claude-work/projects/<slug>/<session>.jsonl` | Full usage including the 1-hour vs 5-minute cache split, plus limit-hit events and reset times |
| Claude Code | `~/.claude/projects` | Same, separate profile |
| Claude Code (personal) | `~/.claude-personal/projects` | Same, separate profile |
| Kimi Code CLI | `~/.kimi-code/sessions/*/*/agents/*/wire.jsonl` | `usage.record` lines: `inputOther`, `output`, `inputCacheRead`, `inputCacheCreation` |
| Codex CLI | `~/.codex/sessions/**/rollout-*.jsonl` | Per-turn `last_token_usage`. Cached tokens are a subset of input and are not double counted |
| Gemini CLI | `~/.gemini/tmp/*/chats/session-*.json` | `messages[].tokens` |
| OpenCode | `~/.local/share/opencode/opencode.db` | Usage nested in the `message.data` JSON column |
| Crush | `~/.crush/crush.db` | Session-level totals |
| Copilot CLI | `~/.copilot/session-state/*/events.jsonl` | Output tokens only. Input is not recorded locally, and the card says so |
| Cursor CLI | `~/.cursor/ai-tracking/ai-code-tracking.db` | Activity only. Cursor keeps no token counts on disk at all, so the card shows requests by model and AI-authored lines instead of a fabricated zero |

Paths, enable toggles, plan overrides and per-source limit overrides are editable under Settings.

## How the limits work

Anthropic does not publish subscription limits as token counts, so Agamemnon does not pretend to know them.

1. On first run it seeds a plan-derived estimate and labels the bar `estimated`.
2. It scans your transcripts once for historical limit hits.
3. When the CLI reports hitting a cap, the block that just filled is `[reset - window, reset]`. Summing billable tokens over that block gives a sample of the real limit.
4. The limit becomes the median of those samples and the bar relabels to `measured`. The median rather than the maximum, because blocks vary by roughly 3x and one contaminated block would permanently understate how full the window is.

A session window is a fixed block anchored to the first message after the previous block expired, not a window that slides with the clock. That is why the CLI reports a specific reset time rather than a countdown.

## Privacy

Everything stays on disk, nothing leaves the machine. Agamemnon opens no network connections, and the suggestions engine is deterministic arithmetic over the local cache with no model involved.

Data is cached at `~/Library/Application Support/Agamemnon/agamemnon.db`, migrated from `~/Library/Application Support/Warden/warden.db` on first run.

## License

Personal tool. Use freely on your own machines.
