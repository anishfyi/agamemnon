# Agamemnon rework

Rework the Warden app in this repo into **Agamemnon**, per the owner directives below. Keep everything that works; change what is listed. Verify with `build.sh` and the test runner before finishing.

## 1. Rename: Warden becomes Agamemnon

- App/display name: **Agamemnon**. Bundle: `Agamemnon.app`. Bundle id: `com.anishfyi.agamemnon`.
- Rename source files and targets where sensible (`WardenApp.swift` -> `AgamemnonApp.swift`, `WardenCore` -> `AgamemnonCore`, `WardenTests` -> `AgamemnonTests`), `build.sh` output, README, comments, menu-bar strings.
- Data dir moves to `~/Library/Application Support/Agamemnon/agamemnon.db`. On first run, if `~/Library/Application Support/Warden/warden.db` exists, move or copy it over (best effort, never crash).
- The GitHub repo is already `anishfyi/agamemnon`; fix any repo URLs in README/docs.

## 2. Sparta icon

- Create a **Spartan helmet** mark, in the same treatment as the kestrel CLI logos: see `/Users/anishfyi/Documents/anishfyi/kestrel/assets/kestrel-dark.svg` and `kestrel-light.svg` for the exact style (single-color geometric mark, dark and light variants).
- Add `assets/agamemnon-dark.svg` and `assets/agamemnon-light.svg`.
- README header: centered `<picture>` block with `prefers-color-scheme` source swap, like kestrel's README.
- App icon + menu-bar template image derived from the helmet (a simple `Assets.xcassets` or programmatic NSImage from the SVG path data; menu-bar icon must be a monochrome template image).

## 3. One real-time spend panel (the point of the app)

The user runs three CLIs and wants to watch token spend live, in priority order:

1. **kimi** (Kimi Code CLI)
2. **cursor cli** (cursor-agent)
3. **claude-work** (Claude Code)

Rework the admin panel Overview into a single real-time dashboard:

- One row/card per source, in that priority order, each showing: input/output/cache tokens, burn rate (tokens/min over last 15 min), estimated cost, and state (ok / warning / critical).
- Two usage windows per source, as progress bars:
  - **5-hour rolling window** (like Claude's session limit): tokens in the last 5h vs a per-source configurable limit.
  - **Weekly rolling window** (last 7 days) vs a per-source configurable limit.
  - Bars turn warning-colored at 70%, critical at 90%, and show the reset time (when the oldest tokens in the window age out).
- A **totals** strip across the top: combined spend today, this week, all-time.
- Default refresh for live feel: 5 seconds (keep it configurable in Settings).
- Limits configurable per source in Settings with sane defaults; persist them.
- Keep cursor honest: if token counts are unavailable, its card shows activity stats and the existing "tokens unavailable" note, never fabricated numbers.

## 4. Invariants

- `build.sh` produces a working `Agamemnon.app`; release build compiles clean.
- Test runner passes; update fixtures/tests for renamed types.
- No em-dashes (U+2014) anywhere.
- Commit as `feat: agamemnon`.
