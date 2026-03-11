# Agent Monitor

macOS floating window that shows active Claude Code, Codex CLI, and terminal sessions as pixel art sprites.

## Tech Stack
- **Swift / AppKit** — native macOS app, no third-party UI framework
- Swift Package Manager executable target
- Built with `swift build`, binary at `.build/debug/AgentMonitor`
- Target platform: `macOS 13+`

## Build / Install
```bash
swift build
```

```bash
swift build -c release
mkdir -p "/Applications/Agent Monitor.app/Contents/MacOS" "/Applications/Agent Monitor.app/Contents/Resources"
cp .build/release/AgentMonitor "/Applications/Agent Monitor.app/Contents/MacOS/AgentMonitor"
cp Info.plist "/Applications/Agent Monitor.app/Contents/Info.plist"
```

NEVER start/launch/open the app. The user will do that.
After code changes, always run `swift build` to verify the project still compiles.

## Host Apps
- `Ghostty` — a terminal emulator. In this app it is treated as a terminal host that can contain Claude/Codex sessions and plain terminal tabs.
- `Solo` / `SoloTerm` — a terminal/process workspace app. In this app it is treated as a host for named Claude/Codex/terminal processes that can be activated through Solo metadata and UI shortcuts.

## Source Layout
- `Sources/App/main.swift` — app entry point
- `Sources/App/AppDelegate.swift` — app lifecycle, polling/animation timers, menu bar item, panel sizing, loading/empty states, attention sound
- `Sources/App/MonitorViews.swift` — session tile rendering, loading placeholder, draggable title bar, close button, panel/content view
- `Sources/Sessions/SessionModels.swift` — `SessionTool`, `SessionState`, `ConversationMatchStatus`, `MonitorSession`, hashed naming
- `Sources/Detection/SessionDetector.swift` — top-level detector orchestration, caches, provider pipeline
- `Sources/Detection/SessionProviders.swift` — provider protocol and the three providers
- `Sources/Detection/ConversationSupport.swift` — conversation metadata structs, transcript activity model, first-prompt title generation
- `Sources/Detection/SessionDetector+ProcessDiscovery.swift` — local/remote process discovery, terminal fallback discovery, CPU smoothing/state heuristics
- `Sources/Detection/SessionDetector+Conversations.swift` — Claude/Codex conversation lookup and metadata parsing
- `Sources/Detection/SessionDetector+Transcripts.swift` — transcript parsing for Claude/Codex activity, cwd lookup, tail readers, prompt cleanup
- `Sources/Hosts/HostRegistry.swift` — host adapter interfaces, registry, and navigation dispatch
- `Sources/Hosts/Shared/HostAccessibility.swift` — shared Accessibility/window helpers for host integrations
- `Sources/Hosts/Ghostty/GhosttyHostIntegration.swift` — Ghostty window/tab matching and activation
- `Sources/Hosts/Solo/SoloHostIntegration.swift` — Solo process activation and shortcut/command palette fallback
- `Sources/Sprites/SpriteCore.swift` — palette, sprite parser, renderer, registry, cache
- `Sources/Sprites/ClaudeSprites.swift` — Claude frames
- `Sources/Sprites/CodexSprites.swift` — Codex frames
- `Sources/Sprites/TerminalSprites.swift` — terminal frames

## Detection Pipeline
- `SessionDetector` builds a `SystemSnapshot` from `ps -eo pid,ppid,tty,etime,%cpu,command`
- Providers run in order:
  - local Claude/Codex sessions
  - remote Claude/Codex sessions reached through interactive `ssh`
  - host-provided terminal fallback sessions for tabs/processes without detected agents
- Only interactive TTYs are shown
- Claude `-p` / `--print` runs are filtered out
- Codex CPU includes descendant process CPU so child work is counted
- Synthetic negative PIDs are used for remote sessions and terminal fallback sessions

## Conversation Matching / Titles
- Claude sessions are matched through `~/.claude/debug`, `~/.claude/projects/...`, and project index data
- Codex sessions are matched by inspecting open `.codex/sessions/*.jsonl` files with `lsof`
- When a transcript is found, the app parses the first real user prompt and derives a short one-word title
- Session subtitles come from cwd folder names when local, or remote host names when remote
- `MonitorSession` is the shared model for Claude, Codex, and terminal sessions

## Activity / State Model
- States: `idle`, `working`, `done`
- Claude/Codex prefer transcript-derived state when a verified conversation transcript is available
- Otherwise state falls back to CPU heuristics with smoothing, hysteresis, and short grace windows
- Claude and Codex use different CPU thresholds
- Terminal fallback sessions only behave as `idle` or `working` in practice; they do not stay in a raised-hand `done` state
- New transitions into `done` play the Glass sound

## Remote / Terminal Support
- Interactive local `ssh` processes are used to discover remote hosts
- Remote snapshots are fetched with a short-timeout `ssh ... ps -eo ...` call and cached briefly
- Remote sessions are paired to remote TTYs by connection order, so matching is best-effort
- Host adapters can provide terminal fallback tiles, using the foreground command or remote host as the title

## Host App Integration
- Clicking a tile tries to jump to the matching host app target
- Requires macOS Accessibility permission
- Ghostty matching uses a mix of:
  - Ghostty child `/usr/bin/login` TTY order
  - AX window/tab enumeration
  - cwd / AXDocument matching
  - window and tab title matching
  - remote host hints
- If exact mapping fails, the app falls back to simply activating Ghostty
- Solo activation uses Solo's process metadata and shortcuts/command palette fallback

## Window / UI
- Borderless non-activating `NSPanel` at `.floating` level
- Shows on all Spaces and alongside fullscreen apps
- Transparent background with rounded dark content view
- Menu bar status item with Show Monitor / Quit
- No dock icon via `NSApp.setActivationPolicy(.accessory)`
- Polls every 2s while visible, every 4s in the background
- Animation runs only when needed
- Initial launch shows a loading placeholder, then `No active sessions` when nothing is detected
- Panel auto-resizes up to 6 columns
