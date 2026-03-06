# Agent Monitor

macOS floating window that shows your active Claude Code CLI sessions as pixel art sprites.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)

## What it does

- Polls running processes to find interactive `claude` CLI sessions
- Shows each session as an animated pixel art Claude sparkle
- Three states: **idle** (waiting), **working** (typing animation), **done** (hand raised, needs your input)
- Click a session to jump to its Ghostty terminal tab/window
- Always-on-top floating panel, no dock icon

## Build & Run

```bash
swift build
.build/debug/AgentMonitor
```

## Install as macOS App

```bash
swift build -c release
mkdir -p "/Applications/Agent Monitor.app/Contents/MacOS" "/Applications/Agent Monitor.app/Contents/Resources"
cp .build/release/AgentMonitor "/Applications/Agent Monitor.app/Contents/MacOS/AgentMonitor"
cp Info.plist "/Applications/Agent Monitor.app/Contents/Info.plist"
```

Then launch from Spotlight (Cmd+Space -> "Agent Monitor") or open from `/Applications`.

## Requirements

- macOS 13+
- Accessibility permission (for Ghostty tab switching via keystrokes)

## Session Names

Each session gets a unique 3-letter name (e.g. `hex`, `nyx`, `vox`) derived from its TTY, so you can tell them apart at a glance.
