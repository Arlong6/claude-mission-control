# Claude Mission Control

A Mac menubar app to manage many Claude Code projects from one place — like Slack/Teams for your AI coding sessions.

If you're juggling 10+ projects under `~/.claude/projects/`, swapping terminals is a context-switch tax. This app gives you a sidebar of every project, jumps you straight into chat with Claude inside any of them, and pings you on macOS Notifications when work finishes or breaks.

> **Self-use first.** Built in an afternoon for one developer's workflow. Open-sourced because friends asked. No release builds, no signing, no support.

## Features

- **Sidebar of every project** under `~/.claude/projects/`, sorted by last activity (5s auto-refresh)
- **Per-project status badges**: dirty git files, open todos in `tasks/todo.md`, error red dot if the latest `.jsonl` contains errors
- **In-app chat panel** — click a project, see its full conversation history (`.jsonl` parsed in place), type, hit Enter to send. No terminal needed.
- **Auto-approve all tools** (`--permission-mode bypassPermissions`) — works because you're sending messages to your own projects
- **macOS notifications** — task complete, errors, and failures push to Notification Center
- **Global hotkey** — ⌘⇧M from anywhere brings the window forward
- **Three delete actions per project**: hide (just from sidebar), clear sessions (delete `.jsonl` files), hard delete (remove `~/.claude/projects/X/` entirely). Your code under `~/Projects/X/` is **never touched.**
- **Login item** — auto-launches at login, lives in the menubar

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6.2+ (ships with Xcode 16)
- [Claude Code CLI](https://docs.claude.com/claude-code) installed (`claude` on `PATH`)

## Install

```bash
git clone https://github.com/Arlong6/claude-mission-control.git
cd claude-mission-control
./build_app.sh release
open MissionControl.app
```

You'll be prompted to allow notifications on first launch. The "Claude" sparkles icon will appear in your menubar; click it or press ⌘⇧M to open the window.

## Project layout

```
Sources/MissionControl/
├── MissionControlApp.swift   # @main, MenuBarExtra, Window scene, AppDelegate
├── GlobalHotkey.swift        # Carbon RegisterEventHotKey for ⌘⇧M
├── Project.swift             # Project / SessionFile / ProjectMeta models
├── ProjectScanner.swift      # Walks ~/.claude/projects/, extracts cwd from .jsonl
├── MetadataLoader.swift      # git status / todo count / error red dot
├── ProjectStore.swift        # @MainActor store + 5s auto-refresh + delete actions
├── RootView.swift            # HSplitView, toolbar, Settings sheet
├── SidebarView.swift         # Project list + badges + delete menu
├── ChatView.swift            # Conversation history + input + ClaudeBackend wiring
├── JSONLLoader.swift         # Parses Claude Code .jsonl into ChatMessage[]
└── ClaudeBackend.swift       # Wraps `claude --print --resume <sid>` subprocess
```

## Known limits

- Built without code signing or notarization. macOS will warn the first time — right-click the `.app` → Open to bypass Gatekeeper.
- Streaming responses come in as one chunk after `claude` exits, not token-by-token. Good enough for self-use; switch to `--output-format stream-json` if you want true streaming.
- `bypassPermissions` is enabled globally. Don't point this at projects whose tool calls you don't trust.
- "Hard delete" removes Claude session data only. Your code is safe by design — see `ProjectStore.hardDelete` for the path-prefix safety check.

## License

MIT — see [LICENSE](LICENSE).
