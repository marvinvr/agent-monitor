# Agent Monitor

macOS floating window that shows your active Claude Code, Codex CLI, and terminal sessions as pixel art sprites.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)

## What it does

- Polls running processes to find interactive `claude`, `codex`, and host-backed terminal sessions
- Shows each session as an animated pixel art sprite in a floating always-on-top panel
- Three states: **idle**, **working**, **done**
- Click a session to jump to the matching Ghostty or Solo target
- Works with local sessions and basic remote/SSH sessions
- Lives in the menu bar and runs without a dock icon

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

## Requirements

- macOS 13+
- Accessibility permission (for Ghostty/Solo session switching)

## Session Names

Sessions use a short generated name by default. When possible, Agent Monitor also derives a better title from the conversation and shows the current folder or remote host as a subtitle.

## Notes

- The panel resizes automatically as sessions appear or disappear
- On launch it shows a small loading state, then `No active sessions` if nothing is running
- Hovering a session highlights it and tooltips show extra details like PID, CPU, TTY, remote host, and conversation match status
