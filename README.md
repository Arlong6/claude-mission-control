# Claude Mission Control

A Mac menubar app to manage many Claude Code projects from one place — like Slack/Teams for your AI coding sessions. Plus a built-in HTTP server that pairs with the **[MC Pocket iPhone + Apple Watch companion](https://github.com/Arlong6/mc-pocket)** so you can glance at every session from your pocket.

If you're juggling 10+ projects under `~/.claude/projects/`, swapping terminals is a context-switch tax. This app gives you a sidebar of every project, jumps you straight into chat with Claude inside any of them, and pings you on macOS Notifications (or your iPhone, if you pair one) when work finishes or breaks.

## Install

**Pre-built notarized .dmg** (recommended): grab `MissionControl-x.y.z.dmg` from the [Releases page](https://github.com/Arlong6/claude-mission-control/releases), drag to Applications, open.

**Or build from source:**

```bash
git clone https://github.com/Arlong6/claude-mission-control.git
cd claude-mission-control
./build_app.sh release
open MissionControl.app
```

## Features

- **Sidebar of every project** under `~/.claude/projects/`, sorted by last activity (5s auto-refresh)
- **Per-project status badges**: dirty git files, open todos in `tasks/todo.md`, error red dot if the latest `.jsonl` contains errors
- **In-app chat panel** — click a project, see its full conversation history (`.jsonl` parsed in place), type, hit Enter to send. No terminal needed.
- **Auto-approve file edits** by default (`acceptEdits`) — Bash and other risky tools still gate. Set `MISSION_CONTROL_BYPASS_PERMISSIONS=1` to bypass everything.
- **macOS notifications** — task complete, errors, and failures push to Notification Center
- **Global hotkey** — ⌘⇧M from anywhere brings the window forward
- **Three delete actions per project**: hide (just from sidebar), clear sessions (delete `.jsonl` files), hard delete (remove `~/.claude/projects/X/` entirely). Your code under `~/Projects/X/` is **never touched.**
- **Login item** — auto-launches at login, lives in the menubar
- **iOS remote (optional, in ⌘, → iOS Remote)** — pair with [MC Pocket](https://github.com/Arlong6/mc-pocket) on your iPhone/Watch. HMAC-signed transport, no third-party relay. APNs push from Mac directly to Apple. See `Sources/MissionControl/Remote/` for the implementation.

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
├── ClaudeBackend.swift       # Wraps `claude --print --resume <sid>` subprocess
└── Remote/                   # iOS pairing + HTTP server + APNs (optional feature)
    ├── HTTPServer.swift            # NWListener-based minimal HTTP/1.1
    ├── APIRoutes.swift             # /projects, /sessions/:id/*, /rules, /register-device
    ├── APNsPusher.swift            # JWT + POST to api.push.apple.com
    ├── PairingPayload.swift        # mcpocket://pair?... URL + QR rendering
    ├── NotificationRules.swift     # quiet hours / per-project / keywords
    ├── RemoteSettings.swift        # @AppStorage + secret in keychain
    ├── RemoteCoordinator.swift     # lifecycle + push fan-out
    └── RemoteView.swift            # Settings tab UI
```

## Build a release .dmg (for distribution)

The `package/` directory has a notarization pipeline:

```bash
./package/setup-notary.sh         # one-time, stores Apple creds in keychain
./package/release.sh              # build → sign → DMG → notarize → staple
./package/release.sh --skip-notarize   # if you don't have a Developer ID
```

Output lands in `dist/MissionControl-<version>.dmg`. Drop it on the GitHub Releases page so non-developers can install without a terminal.

## Known limits

- Built without code signing or notarization. macOS will warn the first time — right-click the `.app` → Open to bypass Gatekeeper.
- Streaming responses come in as one chunk after `claude` exits, not token-by-token. Good enough for self-use; switch to `--output-format stream-json` if you want true streaming.
- `bypassPermissions` is enabled globally. Don't point this at projects whose tool calls you don't trust.
- "Hard delete" removes Claude session data only. Your code is safe by design — see `ProjectStore.hardDelete` for the path-prefix safety check.

## License

MIT — see [LICENSE](LICENSE).
