# Changelog

## v0.2.0 — 2026-05-15

The "ship to other people" release. Adds the iOS companion server, fixes packaging so non-developers can install without a terminal.

### Added

- **iOS Remote pairing** (`Sources/MissionControl/Remote/`)
  - Hand-rolled HTTP/1.1 server on Network.framework — no external deps
  - HMAC-SHA256 signed requests (Bearer fallback for bootstrap)
  - Endpoints: `/projects`, `/sessions/:id/messages`, `/sessions/:id/send`, `/register-device`, `/rules`
  - QR-code pairing payload generator (`mcpocket://pair?host=...&secret=...`)
  - APNs pusher — JWT-signed POSTs straight to `api.push.apple.com`, no third-party relay
  - Settings sheet (⌘,) → iOS Remote tab to configure
- **Push notification rules engine** — quiet hours / per-project / keyword overrides applied before each fan-out
- **Notarization pipeline** (`package/release.sh`) — build → sign → DMG → notarize → staple
- **Hardened-runtime entitlements** (`package/MissionControl.entitlements`) — minimal opt-ins
- **Menubar item** shows iOS remote status: "on (port 27890)" / "off"

### Changed

- `build_app.sh` is now the dev-loop builder; release builds go through `package/release.sh`
- README: full rewrite covering install + iOS remote feature

### Pairs with

- [**MC Pocket**](https://github.com/Arlong6/mc-pocket) iPhone + Apple Watch companion, v0.1.0+

## v0.1.0 — 2026-04-29

First public release. Mac menubar app built in an afternoon: sidebar of every Claude Code project, in-app chat, global hotkey, login item, three delete actions.
