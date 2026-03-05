# Claude Monitor

macOS floating always-on-top window that shows active Claude Code CLI sessions as pixel art Claude sparkles.

## Tech Stack
- **Swift / AppKit** — native macOS app, no frameworks
- Built with `swift build`, run with `.build/debug/ClaudeMonitor`

## File Structure
- `Sources/main.swift` — entry point
- `Sources/AppDelegate.swift` — lifecycle, polling, animation, menu bar, layout
- `Sources/Sessions.swift` — SessionState, ClaudeSession, ClaudeNamer, SessionDetector
- `Sources/Sprites.swift` — color palette, pixel art frames, renderer, cache
- `Sources/Views.swift` — ClaudeSessionView, MonitorContentView, MonitorPanel, close button
- `Sources/GhosttyIntegration.swift` — extension AppDelegate: jumpTo, AX helpers, tab switching

## Install as macOS App
```bash
swift build -c release
mkdir -p "/Applications/Claude Monitor.app/Contents/MacOS" "/Applications/Claude Monitor.app/Contents/Resources"
cp .build/release/ClaudeMonitor "/Applications/Claude Monitor.app/Contents/MacOS/ClaudeMonitor"
cp Info.plist "/Applications/Claude Monitor.app/Contents/Info.plist"
```
NEVER start/launch/open the app. The user will do it themselves.

## How It Works
- Polls `ps -eo pid,tty,%cpu,command` every 2s on a background queue to find `claude` processes
- Only shows interactive sessions (real TTY, not `??`, not `-p` subagents)
- CPU smoothed over 3 samples with hysteresis (2+ ticks >5% CPU) to avoid false "working" triggers
- Three states: **idle** (waiting), **working** (active CPU), **done** (was working, now needs input — hand raised)

## Sprites
- Claude sparkle shape (4-pointed star like the CLI banner `▐▛███▜▌`), not a human
- Rendered as pixel art arrays using `CGContext` + `NSBitmapImageRep`, pre-cached at launch
- Colors: `C`=orange, `L`=light, `c`=dark, `O`=outline, `G/g`=screen, `K/k`=desk, `B`=keyboard

## Session Names
- Each session gets a persistent 3-letter name (e.g. `hex`, `nyx`, `vox`) hashed from TTY via djb2

## Ghostty Tab Switching
- Finds Ghostty's child `/usr/bin/login` processes sorted by PID = tab order
- Maps session TTY to tab index, simulates `Cmd+N` keypress via `CGEvent`
- Requires Accessibility permission for keystroke simulation

## Window
- `NSPanel` with `.floating` level, borderless, transparent background, draggable
- Rounded dark content view, auto-resizes as sessions appear/disappear
- Menu bar sparkle icon with Show/Quit
- `NSApp.setActivationPolicy(.accessory)` — no dock icon
