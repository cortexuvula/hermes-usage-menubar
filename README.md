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

Requires Xcode command-line tools (`swiftc`), Python 3 with Pillow (for the icon),
and the upstream collector checkout at `~/Development/omarchy-hermes-usage`
(pointed to by `COLLECTOR_SRC` in `build.sh`). Output installs to
`~/Applications/HermesUsage.app`.

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
- Quota export (`hermes-usage-export`) only appears if you separately install the
  companion Hermes plugin (`hermes plugins install <repo>#hermes-usage-export`);
  the app shows `accounts` if those export files exist, otherwise just local stats.
- Numbers shown are "device" scope: they sum across all profiles' stores on this
  machine (matching the upstream collector's semantics), not per-profile.
- Daily attribution is estimated from assistant-message activity (same as upstream).

MIT — see LICENSE (upstream) and HermesUsage.swift.
