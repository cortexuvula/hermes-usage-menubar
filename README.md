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
  any exported `accounts` observations in its JSON, but this app's UI does not
  render them yet — it shows local usage only.
- Numbers shown are "device" scope: they sum across all profiles' stores on this
  machine (matching the upstream collector's semantics), not per-profile.
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
