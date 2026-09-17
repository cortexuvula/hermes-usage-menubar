# Hermes Usage — macOS menu bar app

A native macOS port of [r0b0tlab/omarchy-hermes-usage](https://github.com/r0b0tlab/omarchy-hermes-usage).
The original is an Omarchy (Linux/Quickshell) plugin that shows Hermes Agent usage
in the desktop agents panel. This port keeps the exact same collector (pure Python
stdlib, reads Hermes's local SQLite `state.db`) and replaces the Quickshell QML
panel with a SwiftUI menu bar app.

## What it shows

- Menu bar: today's total tokens next to a gauge icon
- Popover: today's tokens/prompts/sessions, 7-day token bars, per-model breakdown,
  all-time tokens/calls/estimated cost, per-provider tokens + cost
- Auto-refresh every 15 minutes + manual Refresh button
- Everything is local: reads `~/.hermes/state.db` (and `~/.hermes/profiles/*/state.db`),
  no network, no credentials
- Accounts/quota section: per-provider quota windows or USD credit, reset time,
  and freshness — or an honest empty state when no snapshot is available

## Panel appearance and contrast

The popover uses opaque, appearance-specific backgrounds: light `#F2F2F2`
(`[242,242,242]`), dark `#1E1E1E` (`[30,30,30]`). The previous translucent
material made every contrast ratio depend on the desktop behind the panel;
on a real composite (a dark panel over a bright desktop) no dark or mid text
at any reachable hue could hit 4.5:1. Opaque backgrounds are what make stable
contrast guarantees possible — composited measurements land exactly on the
authored sRGB values.

### Text palette

Neutral text colours, measured on their own opaque backgrounds:

| Tier | Light | Contrast | Dark | Contrast |
|---|---|---|---|---|
| Primary | `#1D1D1F` | 15.034:1 | `#FFFFFF` | 16.671:1 |
| Secondary | `#5A5A60` | 6.118:1 | `#C7C7CC` | 9.899:1 |
| Tertiary | `#6E6E73` | 4.530:1 | `#B0B0B8` | 7.739:1 |

Accents are per-appearance and graphic-only — never used as text colour:

| Purpose | Light | Contrast | Dark | Contrast |
|---|---|---|---|---|
| Warning / caution | `#B25E00` | 4.174:1 (3:1 non-text ✓) | `#FF9F0A` | 8.110:1 |
| Success / healthy | `#0A6B2E` | 5.945:1 | `#30D158` | 8.246:1 |

Status colour is carried on supplementary glyphs that are hidden from
VoiceOver (accessibility-element set to `false`). The status is announced
once, from the words. Colour is supplementary; the words are the message.

### Footer and warning wording

The bare em dash that previously stood alone in the footer was replaced with
"Not updated". The dash's 1 px stroke reached only ~70% of its authored
colour at 1×, rendering 3.1964:1 where the authored value is 6.118:1. The
⚠️ emoji previously embedded in the call-coverage warning text was removed,
leaving a single decorative, AX-hidden glyph as the only warning marker.

### Text size

The app renders at fixed type sizes and does not follow the macOS preferred
reading size. macOS exposes no public API for menu bar apps to read or
observe the user's preferred reading size; Apple's own `dynamicTypeSize`
documentation states that on macOS the value cannot be changed by users and
does not affect text size.

## Verification (candidate ca9030f)

Fresh native screen-composited verification, bound to `candidateSha ca9030f…`
and executable `dad40c1d…`; verdict record at
`candidate-ca9030f-opaque-evidence/checks.json`.

| Category | Samples | Failures |
|---|---|---|
| Required cells | 54 / 54 | 0 |
| ICC→sRGB-converted text samples | 96 | 0 |
| Supplementary glyph samples | 36 | 0 |

Minimum ratio across all samples: **4.5350:1**. Footer region: 6.1180:1
light / 9.8993:1 dark, identical across three backdrops.

**What this does not cover:** no VoiceOver speech traversal was performed;
this is not whole-app WCAG conformance; native tooltip visuals were not
measured; the accounts/quota section's populated states were outside this
candidate's matrix (nine empty/subset states were measured: overview, totals,
models, providers, workloads, feedback, fallback, noStores, stale) — the later
fix candidate `1a1f37b` does measure populated quota states, see
"Fixed findings (previously known-open)" below.

## Accounts / quota section

The accounts/quota section shows per-provider quota windows or USD credit
with reset time and freshness. When no quota snapshot is available, the
section renders an honest empty state. The empty state means *no quota
snapshot is available* — not that the plugin is uninstalled, and not that
access was denied. A "denied" status appears only as an explicit exported
status from the companion plugin.

Observations carry a 600 s TTL while the collector runs every 900 s, so the
UI expires them independently while the panel is open. The ordinary Refresh
button rereads local files only and never silently opts into network or
credential access.

The companion export plugin (`hermes-usage-export`) is not installed on this
machine, which is why the section currently shows its empty state.

## Fixed findings (previously known-open)

Both findings that previously shipped as code with their fix pending
(tracked in `t_72bea24b`) are now fixed, and the fix was verified natively
before it landed:

1. **Nil `resetAt`** renders "Reset time unavailable" instead of the bare
   em dash. The collector retains `reset is None` windows as valid data, so
   nil stays distinct from "no reset scheduled" — the wording, not a dash,
   carries that distinction.
2. **Stale allowance during window crossing.** A quota window that crosses
   its `resetAt` while the panel is open now renders "reset passed — awaiting
   re-observation" and omits the percentage entirely, in the visible row
   **and** in its accessibility announcement (4.535:1 light / 7.739:1 dark
   rendered ink for the crossed message; 6.118:1 / 9.899:1 for the timing
   text).

Measured on the fix (`fix/b6-findings@1a1f37b`, landed as `622c71d…`; the
machine verdict record is the `checks.json` attached to kanban task
`t_9933b8dc`): 66/66 screen-composited cells, 126 ICC→sRGB-converted text
samples plus 36 supplementary glyph samples, 0 failures, `captureMethod:
screen-composited`. Both reset transitions were captured by periodic probing
on a single process and window per appearance (same process and window
throughout, no recollection), and neither announced nor displayed the stale
percentage.

**What this does not cover:** measured at the Default reading size only;
native AX enumeration, not VoiceOver speech traversal; probe continuity
sampled approximately every 4 s rather than continuous video; Light and Dark
appearances on three owned backdrops (255/128/32) only. The 44 pt timing
column no longer wraps: with a nil `resetAt`, "Reset time unavailable"
renders complete on **one line** beneath its label and percentage, on a
**312×79** pt row against the normal row's **312×64** pt, with the percentage
right edge unchanged (0 pt measured ink delta). Measured rendered ink for that
line: 6.118:1 light / 9.899:1 dark. That layout landed as `62f7e52` on `main`
and was verified natively before landing (`t_024a0553`: 7/7 required cells,
0 failures), so the former wrap is no longer a follow-up.
This machine still has no snapshot export installed, so the section renders
its empty state here and the three populated states above were exercised from
synthetic producer-shaped snapshots.

## Build

```bash
./build.sh
```

Builds from the checkout the script lives in (no hard-coded paths). Requires
Xcode command-line tools (`swiftc`), Python 3 with Pillow (for the icon), and
the upstream collector checkout. The current target is **arm64 (Apple
Silicon) only**.

Configuration (environment variables):

| Variable | Default | Purpose |
|---|---|---|
| `COLLECTOR_SRC` | `~/Development/omarchy-hermes-usage` | Upstream collector checkout |
| `HERMES_USAGE_INSTALL_DIR` | `~/Applications` | Install destination (redirect for CI/testing) |
| `HERMES_USAGE_SRC` | script's directory | Source root (rarely needed) |

All inputs are validated before any previous build output is removed.
Output installs to `~/Applications/HermesUsage.app` by default.

## Start at login

A LaunchAgent is already installed at
`~/Library/LaunchAgents/ca.andrehugo.hermes-usage.plist` (runs the app at login).
Remove it with:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/ca.andrehugo.hermes-usage.plist
rm ~/Library/LaunchAgents/ca.andrehugo.hermes-usage.plist
```

## Notes / differences from the Omarchy original

- The collector (`collector/hermes-usage.py`) is used unmodified; the Linux-only
  pidfd supervision (`launch.py`/`bootstrap.py`) is not needed — the app runs the
  collector directly via `/usr/bin/python3 -B ... --force`.
- Quota export (`hermes-usage-export`) is a separate, optional Hermes plugin
  (`hermes plugins install <repo>#hermes-usage-export`); the collector includes
  any exported `accounts` observations in its JSON. The app now renders
  per-provider quota windows or USD credit when a snapshot is available; see
  "Accounts / quota section" above.
- Numbers shown are "device" scope: they sum across all profiles' stores on this
  machine (matching the upstream collector's semantics), not per-profile.
  **For diagnostics:** the collector's `scope` field is an *intent* label, not a
  measurement of which store was read — a run under
  `HERMES_HOME=~/.hermes/profiles/<name>` reports `scope: device` over that
  profile's own figures (illustrated in a single minute: ~2.1M profile-scoped
  against ~8.2M device-wide, both labelled `scope: device`). Print the effective
  `HERMES_HOME` alongside any number you quote, and treat a quoted count as a
  timestamped observation rather than a value to compare against — the totals grow
  as work happens. The app itself launches from LaunchAgent context with no
  override, so the figures it shows are device-wide.
- Daily attribution is estimated from assistant-message activity (same as upstream).

MIT — see LICENSE (upstream) and HermesUsage.swift.

## Known app behaviour: a failed copy empties the clipboard

`Copy usage summary` is the only clipboard writer. Its path calls
`NSPasteboard.clearContents()` before writing the receipt, so if the write is
then **rejected** — a pasteboard-server failure, not a no-data or formatting
case, since the receipt is built before the clipboard is touched — the clipboard
is left empty rather than retaining what it held.

Restoring the previous contents would require the app to **read** your clipboard
first. This app otherwise never reads it, and that guarantee is worth more than
covering a rare failure, so the behaviour is documented here rather than fixed.
Reordering the code does not help: the receipt is already constructed before the
clipboard is touched, and the clear/write pair is atomic from the app's side.

## Known collector caveat (unmodified upstream behavior)

The bundled collector is kept byte-identical to upstream
(`omarchy-hermes-usage`). Its SQLite fallback path (`hermes-usage.py`
`connect()`) is not strictly read-only at the filesystem level: if a store
file disappears between discovery and connection, the plain
`sqlite3.connect()` fallback creates a 0-byte database at that path before
`PRAGMA query_only` engages. The window is milliseconds, the effect is an
empty file inside the user's own `~/.hermes`, and no data is read or
written beyond that. A fail-closed open belongs upstream; this repo tracks
upstream for the collector rather than diverging.
