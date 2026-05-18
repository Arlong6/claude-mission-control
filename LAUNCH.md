# Launch playbook — Mission Control

For the Mac app side. The iOS companion (mc-pocket) has its own launch plan in [mc-pocket/LAUNCH.md](https://github.com/Arlong6/mc-pocket/blob/main/LAUNCH.md); do that **after** this one settles.

---

## When to fire

Submit on a **Tuesday or Wednesday between 7-9am US Pacific** — that's the empirically lowest-competition Show HN window (peaks Europe morning + US dev wake-up). For Taiwan time that's **roughly 22:00-00:00 the same Mon/Tue night**.

Avoid: Monday (post-weekend flood), Friday (everyone gone), any major Apple/Anthropic announcement day.

---

## 1. Pre-launch checklist (do these 30 min before submitting)

- [ ] GitHub repo description matches v0.2.0 reality (no "self-use" wording)
- [ ] `v0.2.0` release page has the notarized `.dmg` attached and downloads cleanly
- [ ] README's first 2 paragraphs read well when someone scrolls **without context**
- [ ] You have ~6 hours to be online and reply to comments
- [ ] Browser tabs open: HN submit page, your release page, your X/Threads draft
- [ ] HN account ≥ 1 week old with ≥ 1 karma (else post may be auto-deadduped)

---

## 2. The Show HN post

### Title (pick one — recommended is bolded)

| Style | Text |
|---|---|
| Direct | `Show HN: Mission Control – a Mac menubar app for many Claude Code sessions` |
| Slack-analogy | `Show HN: Slack-like sidebar for all your Claude Code projects` |
| **With a number** | **`Show HN: One menubar app to manage 20+ Claude Code projects on macOS`** |

> HN favors specificity. The number framing reads as "this person has a real pain" instead of "this person wrote a generic tool."

### URL field

`https://github.com/Arlong6/claude-mission-control`

Not the release page. HN voters click into source.

### First comment (post within 30 seconds of submission, as the OP)

```
Author here. The honest origin: I had 20+ projects under
~/.claude/projects/ on my Mac. Switching terminals to check which one
was waiting on a permission prompt, which errored two hours ago, which
was still running a long task — it added up to a real context-switch
tax every day.

Mission Control is a SwiftUI menubar app that gives you a sidebar of
every project, sorted by last activity, with status badges (git dirty
files, open todos, error red dot). Click any project to open an in-app
chat panel — `.jsonl` is parsed in place, you type and hit Enter,
Claude responds. No terminal jump.

A few choices that might be useful to read in the source:

- Auto-approve `acceptEdits` by default; Bash/risky tools still gate.
  There's a `MISSION_CONTROL_BYPASS_PERMISSIONS=1` if you really want
  to YOLO.
- Three delete actions per project: hide (sidebar only), clear sessions
  (.jsonl), hard delete (remove ~/.claude/projects/X/). Your code under
  ~/Projects/X/ is never touched.
- Global ⌘⇧M from anywhere (Carbon RegisterEventHotKey).
- Optional iOS companion (MC Pocket): the Mac side runs a hand-rolled
  HTTP/1.1 server on Network.framework with HMAC-SHA256 signed requests.
  Push notifications fire from your Mac directly to api.push.apple.com
  with a JWT — no third-party relay, no analytics. iOS app is open
  source too but not on the App Store yet:
  https://github.com/Arlong6/mc-pocket

Notarized .dmg on the release page, MIT licensed. macOS 14+, needs the
`claude` CLI on PATH.

Happy to talk about: the SwiftUI Window vs MenuBarExtra split, why I
ditched FSEventStream for polling, the Swift 6 strict concurrency tax
during the iOS Remote build, or anything else.
```

---

## 3. The first hour decides everything

The first 60 minutes of votes determines whether HN's ranking algorithm pushes you to the front page. Be **at the keyboard**.

- Reply to every substantive comment within **15 minutes**
- Never be defensive. If a commenter is wrong, explain the tradeoff calmly. If they're right, say so and add it to a TODO list.
- Don't engage with hostile / low-effort comments. Downvote silently is fine.
- If someone asks "why didn't you use X?" — give the honest reason (usually: tried it, hit Y, switched). HN respects empirically-derived choices.

### Things people will ask, that I have answers ready for

- **"Why not just use [iTerm sessions / tmux / Warp / Cursor]?"** → Different axis. Those let you switch one terminal at a time. MC shows you all sessions at a glance, like a Slack workspace sidebar.
- **"Doesn't Anthropic ship Remote Control now?"** → Yes (2.1.110). That's terminal-mirror, one session at a time. MC is the portfolio view of that.
- **"Why Swift and not Tauri/Electron?"** → 1 MB binary vs 100 MB. Native macOS feel. SwiftUI 6 is genuinely good now.
- **"Is this actually faster than `tail -f`?"** → For 1 session no. For 20+ sessions with cross-project search (⌘F), yes.
- **"What about Windows/Linux?"** → Not planned. Carbon hotkey + macOS Notifications are core; a port would be a different app.

---

## 4. Twitter / X (post right after HN, not before)

Tweet 1 (hook):
```
shipped a Mac menubar app for managing many Claude Code sessions

20 projects, one sidebar, status badges per project, in-app chat
panel so you don't context-switch terminals

Show HN today: <HN link>
GitHub: https://github.com/Arlong6/claude-mission-control
```

Tweet 2 (visual): drop one of A1/A2/A3 from `mc-screenshots-raw/`

Tweet 3 (the iOS hook for future readers):
```
also a SwiftUI iPhone+Watch companion (open source, not on App Store
yet) that pairs over your local network with HMAC-signed requests and
APNs push direct from your Mac — no relay, no analytics

https://github.com/Arlong6/mc-pocket
```

---

## 5. After the dust settles (~24 hr later)

Take a snapshot of:
- HN: final rank, comments, GitHub stars gained
- GitHub: stars, forks, issues, traffic graph
- X/Threads: impressions, follower delta
- Release page: download count of v0.2.0 dmg

Then decide:
- **>200 HN points or >100 stars** → mc-pocket App Store submission is worth the 1.5-2 hour push. Ride the wave.
- **>500 HN points or >300 stars** → write a "lessons learned" follow-up post on personal blog/X 2-3 days later.
- **<50 points, <20 stars** → fine. The tool still works for you. You can re-pitch with a different angle in 3-6 months ("I've been daily-driving this for X months — here's what I learned").

---

## 6. What NOT to do

- Don't ask friends to upvote — HN detects and shadowbans
- Don't reply to your own comment to bump it
- Don't post on multiple HN accounts
- Don't crosspost to /r/programming the same day (wait 24+ hours)
- Don't write defensive "but actually" replies — even when you're right
