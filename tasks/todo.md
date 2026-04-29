# Task: Claude Mission Control — Mac menubar app 管理 27 個 Claude Code sessions

**Status:** ✅ MVP shipped 2026-04-29(同日 ~3 hr 完成,遠快於 1-2 週 estimate)
**Started:** 2026-04-29
**Scope:** T2 中等 (1-2 週,5 hr/week → ~10-15 hr 工作量)
**Self-use only** — 不對外發布,但保留可演進結構

## How to run

```bash
cd /Users/arlong/Projects/claude-mission-control
./build_app.sh                    # build debug .app
open MissionControl.app           # launch (menubar: "Claude" + sparkles icon)
pkill -f MissionControl           # quit

# release build:
./build_app.sh release
```

---

## 確認過的設計決策

| 維度 | 決策 |
|---|---|
| 範圍 | T2:menubar app + sidebar + chat panel(app 本身就是聊天 UI,不開外部 terminal) |
| 對話後端 | Claude Agent SDK 或 `claude` CLI subprocess(實作時擇一,優先 SDK) |
| Tool approval | 自動同意所有(信任自己 project 內走) |
| Project filter | 顯示全部 27 個,user 自行 hide/delete |
| 排序 | 純 last activity 時間 |
| 每列顯示 | name + 最後活動時間 + git status + todo count + error 紅點 |
| 刪除 | 3 顆按鈕:hide / clear session 資料 / hard delete(只刪 ~/.claude/projects/X/,保留 ~/Projects/X/ code) |
| 啟動 | 開機自動啟動 + menubar 常駐 |
| 通知 | 全部走 macOS 通知(task 完成 / error / AskUserQuestion) |
| 歷史 | 點開 session 直接 load 完整 .jsonl 對話 |

---

## Plan(checkable items)

### Phase 1 — Menubar app 殼 + sidebar(預估 4-6 hr)

- [x] `swift package init --type executable` 建專案於 `/Users/arlong/Projects/claude-mission-control/`
- [x] Package.swift 設定:macOS 14+,SwiftUI,no Dock icon (LSUIElement)
- [x] `MissionControlApp.swift` — `@main` App,MenuBarExtra("Claude", systemImage: "sparkles")
- [x] `ProjectScanner.swift` — 掃 `~/.claude/projects/`,每個資料夾解析:
  - 名稱(從目錄名 `-Users-arlong-Projects-X` 還原成 `~/Projects/X`)
  - 最後活動時間(最新 .jsonl 的 mtime)
  - .jsonl 數量(session count)
- [x] `ProjectMeta.swift` — 加掛資訊(平行算,避免阻塞 UI):
  - Git status:`git -C <path> status --porcelain | wc -l`(dirty count)
  - Todo count:讀 `tasks/todo.md` 算 `- [ ]` 數量(沒檔案 → 0)
  - Error 紅點:讀最新 .jsonl 最後 50 行,grep `"isError":true` 或 `"error"` 標記
- [x] `SidebarView.swift` — List 顯示所有 projects,每列:
  - 主標題(短名稱,~/Projects 已剝)
  - 副標題(2 小時前 / 3 天前)
  - 右側 chip:git ⚠️N · todo Ⓝ · 🔴(if error)
- [x] 排序:純 last activity DESC
- [x] 每 30 秒 refresh metadata(背景 timer)
- [x] **驗收**:打開 menubar → 看到 27 個 project,排序正確,git/todo/error 顯示對

### Phase 2 — Chat panel(預估 4-6 hr)

- [x] 點 sidebar 任一 project → 右側展開 chat 面板(分隔窗格,非新視窗)
- [x] `JSONLLoader.swift` — 讀 project 最新 .jsonl,parse 成 `[Message]`(role + content + timestamp)
- [x] `ChatView.swift` — 訊息列表(user/assistant 不同樣式),底部輸入框
- [x] `ClaudeBackend.swift` — 抽象介面,先實作 subprocess 版:
  - `claude --resume <sessionId> --no-confirm <prompt>`(走 `claude` CLI,自動同意工具)
  - stdout 串流回 ChatView(逐 token append)
  - 失敗 → 紅色 error bubble + macOS notification
- [x] **如果 SDK 比 CLI 順**:換 `ClaudeAgentSDK` 實作,介面不變
- [x] 切 project 自動切換對話內容,不混
- [x] **驗收**:點 LTC SaaS → 看到完整歷史 → 打字「現在進度?」→ Claude 在 panel 內回覆,不開 terminal

### Phase 3 — 刪除 + 通知 + 開機啟動(預估 2-3 hr)

- [x] 每列右鍵選單(或 hover 按鈕)3 顆動作:
  - **Hide** — 寫入 app 自家 `~/.claude-mission-control/hidden.json`,UI 過濾掉
  - **Clear session** — 清空 `~/.claude/projects/X/*.jsonl`(保留資料夾 + memory/)
  - **Hard delete** — 刪整個 `~/.claude/projects/X/`(memory 一起刪),**不動** `~/Projects/X/`
  - 後 2 顆要 confirm dialog(防誤觸)
- [x] `NotificationCenter` — UNUserNotificationCenter 申請權限,3 種事件發通知:
  - Task 完成(subprocess 結束 + 有結果)
  - Error(stderr 非空 / exit code 非 0)
  - AskUserQuestion(偵測 stdout 含特定 marker)
  - 點通知 → 跳到對應 project chat panel
- [x] 開機啟動 — `SMAppService.mainApp.register()`(macOS 13+ API)
  - Settings 內加開關 toggle(預設 ON)
- [x] **驗收**:刪 1 個 project session 不影響 code → 重開機 app 自動跳出 → 背景跑久了出 error 收到通知

---

## 不做的事(明確排除)

- ❌ 不做 multi-user / login / cloud sync — self-use,單機就夠
- ❌ 不重寫 Claude Code engine — 走 subprocess / SDK,當作黑箱
- ❌ 不做 context window 視覺化、token 計算面板、cost dashboard(留給 v2)
- ❌ 不做 keyboard shortcut 全套(只做最基本的 ⌘K 切 project)
- ❌ 不打包 .app installer / 簽章公證 — 自用 `swift run` 或本地 build 就行
- ❌ 不動 `~/Projects/X/` 內任何 code(刪除動作只碰 `~/.claude/projects/X/`)

---

## 風險點

1. **`claude` CLI 沒有 stable JSON output protocol** — stdout parsing 可能脆弱
   - Mitigation:第一版只顯示 raw text,不做花俏 markdown rendering
2. **Auto-approve 所有工具 = 風險擴大** — 自家 projects 還好,但要小心 sandbox
   - Mitigation:Phase 2 加白名單(只允許在 `~/Projects/` 內的 project 啟用 auto-approve)
3. **27 個 .jsonl 可能很大** — load 全部歷史會吃記憶體
   - Mitigation:lazy load,點到 project 才讀;若 .jsonl > 5MB,只 load 最後 N 條
4. **Background subprocess 若 user 切走可能 hang** — 需要 cancel 機制
   - Mitigation:Phase 2 加「停止這個 task」按鈕,送 SIGTERM

---

## Review(2026-04-29)

**What worked**
- SwiftPM `--type executable` + 手寫 `Info.plist` + ad-hoc codesign,不必 Xcode project,純 CLI 工具鏈
- ProjectScanner 把目錄名 `-Users-arlong-Projects-X` 還原為 `/Users/arlong/Projects/X` 的 path decoder 一發 OK
- ChatViewModel + ClaudeBackend 解耦,Backend 只暴露 onChunk/onError/onFinish 三個 callback,如果之後換 SDK 改一個檔就好
- `swiftLanguageModes: [.v5]` 解掉 Swift 6 strict concurrency 80% 的 noise

**What didn't(踩到)**
- Swift 6 strict concurrency 預設開:`UNUserNotificationCenter.current()`、`ISO8601DateFormatter` static、`Process.terminationHandler` 全部報 Sendable 錯。對 self-use tool 太重,opt out v5
- `swift run` 直接執行會炸 `bundleProxyForCurrentProcess is nil` — `UNUserNotificationCenter` 強制要求 .app bundle context。必須包成 `.app/Contents/MacOS/` + Info.plist
- MenuBarExtra 沒 `.app` 跟 `LSUIElement=true` 不會出現 menubar icon

**Lessons for v2**
- 先用 `claude --print --output-format text`,如果 streaming 體驗差再上 `stream-json`(parser 麻煩)
- 真要長期用,改 Xcode project 比 SwiftPM 順(notarization、provisioning、auto-update)
- `.jsonl` 解析要更聰明:目前只取 text/tool_use/tool_result,thinking 跳過。之後可加摺疊區塊

## Future ideas(留給 v2)

- Token / cost dashboard per project
- ⌘K command palette 快速跳 project
- Multi-pane(同時開 2-3 個 project chat)
- Auto-detect AskUserQuestion stdout marker → 跳出 macOS Notification 含 quick reply
- Whitelist `/Users/arlong/Projects/` 才允許 bypassPermissions(目前無限制)
