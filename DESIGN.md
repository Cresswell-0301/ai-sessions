# AI Sessions — design

A menu-bar app that tracks every Claude Code and Codex session on this Mac,
posts a macOS notification when a session finishes a turn or needs input, and
routes you straight back to that session's tab when you click the notification
or the menu item.

Everything below marked **verified** was observed on this machine
(macOS 26.7, VS Code 1.13x, Claude Code extension 2.1.284, Codex extension
`openai.chatgpt` 26.917 / codex-cli 0.155.0-alpha) on 2026-10-01.

## Signals (zero configuration — no hooks are installed)

### Claude Code: the live-session registry (verified)

Every live Claude process writes `$CLAUDE_CONFIG_DIR/sessions/<pid>.json`
(default `~/.claude/sessions/`). Example:

```json
{"pid":48433,"sessionId":"9eb4895f-b5d9-41d0-8161-864ac0eecf46","cwd":"/Users/nexflo/coreOS",
 "startedAt":1790823548541,"procStart":"Thu Oct  1 02:59:07 2026","version":"2.1.284",
 "peerProtocol":1,"peerFeatures":["notify_idle"],"kind":"interactive","entrypoint":"claude-vscode",
 "pidDomain":"darwin","messagingSocketPath":"/tmp/cc-socks/48433.sock","name":"coreos-e1",
 "nameSource":"derived","nameSince":1790823548541,"status":"busy",
 "updatedAt":1790823673821,"statusUpdatedAt":1790823673821}
```

- `status`: `"busy"` | `"idle"` | `"waiting"`. The Claude VS Code extension
  itself maps `busy → running`, `waiting → waiting`, anything else → `idle`
  (function `jI0` in its `extension.js`). Unknown future values → idle, keep
  the raw string.
- A turn end was observed live: `busy → idle` written ~200 ms after the final
  assistant message hit the transcript. `statusUpdatedAt` (epoch **ms**) is
  the transition time. `updatedAt` does NOT heartbeat — it only moves on
  writes — so liveness must come from the pid, not from timestamps.
- The file is removed on clean exit (`process.on("exit")`). After a crash it
  stays: treat a record as live only if `kill(pid, 0)` succeeds AND the
  process start time matches `procStart` (asctime layout in **UTC**,
  ±2 s, see `ProcessKit.matchesProcStart`). Fallback when `procStart` is
  missing: process start ≤ `startedAt` ≤ process start + 120 s.
- `kind`: `"interactive"` for real sessions. The extension classifies
  (`_I0`): `kind` present and not `"interactive"` → other; entrypoint
  `cli` → terminal, `claude-vscode` → vscode, `claude-desktop`/`-3p` → desktop,
  anything else (`sdk-cli` = `claude -p`, `sdk-ts`, `sdk-py`, `mcp`,
  `local-agent`, GitHub action…) → other. **Non-interactive = automation.**
- NEVER open the sibling `<pid>.<hash>.key` files — they are secrets.
- Process tree (verified): `claude` (pid) → parent `Code Helper (Plugin)`
  = the VS Code **extension host of one window** → `Code` main process.

### Claude Code: transcripts (verified)

`<configDir>/projects/<encoded-cwd>/<sessionId>.jsonl`, JSON lines. Encoding:
`realpath(cwd)` with every non-alphanumeric char replaced by `-`; paths over
200 chars are truncated + hashed — so **locate by globbing**
`<configDir>/projects/*/<sessionId>.jsonl` and cache the hit.
Files reach 20 MB+: read only the tail (last 256 KB; skip the first partial
line), scanning further back in chunks only if a title is still missing.

Entry types that matter (all carry `sessionId`):

| type | payload field | meaning |
|---|---|---|
| `custom-title` | `customTitle` | user renamed the tab ("AI Track") — **the VS Code tab label** |
| `ai-title` | `aiTitle` | generated title ("Session tracking and notifications system") |
| `last-prompt` | `lastPrompt` | the user's last prompt |
| `assistant` | `message.content[]` blocks `{type:"text",text}`, `message.stop_reason` | agent output |

Title precedence: `customTitle` > `aiTitle` > registry `name` (e.g.
`coreos-e1`) > `lastPrompt` > short session id. Last message preview: text of
the last `assistant` entry that has a non-empty text block.

### Codex: rollout files + state DB (verified)

- Default home `~/.codex` (VS Code extension, originator `codex_vscode`).
  `~/.ai-accounts/codex/*` homes hold hourly `codex exec` usage probes
  (originator `codex_exec`) — **not watched by default**, and filtered anyway.
- One `codex app-server` process per VS Code window (child of that window's
  extension host) hosts all threads; there is no per-thread process.
- Rollouts: `<home>/sessions/YYYY/MM/DD/rollout-<timestamp>-<threadId>.jsonl`,
  appended live. Each line `{"timestamp","type","payload"}`.
  - first line `type:"session_meta"`: `payload.id` (thread id), `cwd`,
    `originator`, `source` (string `"vscode"`/`"cli"`/`"exec"`, or an object
    `{"subagent":…}` for sub-agents), `thread_source`, `cli_version`.
  - `type:"event_msg"` with `payload.type`:
    `task_started` → running; `task_complete` (has `turn_id`,
    `last_agent_message`, often empty) → idle; `turn_aborted` → idle (user
    interrupted); `agent_message` (`payload.message`) → preview text;
    `user_message` (`payload.message`). Approval requests may not be
    persisted; if a `*approval_request*`/`request_user_input` event appears,
    treat as waiting.
- Titles: `<home>/state_<N>.sqlite` (highest N; currently `state_5.sqlite`),
  table `threads(id, title, cwd, source, originator, updated_at, archived,
  rollout_path, first_user_message, preview, …)`. Open read-only
  (`file:…?mode=ro`, `SQLITE_OPEN_READONLY`); the DB is in WAL mode and
  written concurrently. Fallback: `<home>/session_index.jsonl`
  `{"id","thread_name","updated_at"}`, then the first `user_message`.
- Codex hooks exist but require a trust review per hook (`hooks.state` hash);
  we do not use them. Legacy `notify` would need a config edit; not used.

## Routing back to a session (verified)

VS Code routes a `vscode://` URI to a specific window when the query contains
`windowId=<n>` (main process `URLHandlerRouter`), otherwise to the last
active window. After the target window handles it, VS Code **force-focuses
that window** (`URLService.handleURL → focusWindow({mode: Force})`).

- **Claude tab**: `vscode://anthropic.claude-code/open?session=<uuid>[&windowId=<n>]`
  → `claude-vscode.primaryEditor.open(session)` → `createPanel`: if that window
  already has a panel for the session it calls `panel.reveal()` (no duplicate);
  a remembered tab after reload is revealed via group focus +
  `workbench.action.openEditorAtIndex`; only otherwise does it open a new tab
  that resumes the session. So the URI must reach the window that owns the
  tab → always add `windowId` when known.
  First use shows VS Code's "Allow 'Claude Code' to open this URI?" dialog
  (Anthropic is not a trusted publisher); tick "Don't ask again" once.
- **Codex thread**: `vscode://openai.chatgpt/local/<threadId>` → the extension
  focuses the Codex sidebar and navigates its webview to the thread. OpenAI
  is a trusted publisher: no dialog. Add `?windowId=<n>` only when more than
  one window is open (the query is forwarded into the webview route).
- **Window id of an extension host**: the newest session dir under
  `~/Library/Application Support/Code/logs/<yyyymmddThhmmss>/` has
  `window<N>/exthost/exthost.log` containing
  `Extension host with pid <PID> started` (verified: window1 ↔ 3819).
  Use the LAST such line per window file (reloads append). Live window count =
  windows whose pid is alive.
- Other editors in the same family use their own scheme and app-data folder
  (Insiders: `vscode-insiders` / `Code - Insiders`; Cursor: `cursor` /
  `Cursor`; Windsurf: `windsurf` / `Windsurf`; VSCodium: `vscodium` /
  `VSCodium`) — derive them from the extension host's app bundle path.
- **Terminal CLI sessions**: activate the nearest GUI-app ancestor of the
  claude process (Terminal, iTerm2, Ghostty…). No tab-level focus (it would
  need Automation permission).

## Architecture

```
Sources/AISessionsCore/            (no AppKit; unit-tested)
  Model.swift        contracts — Agent, SessionKey, ActivityState, SessionHost,
                     Observation, SessionSource, TrackedSession, TrackerEvent
  Config.swift       config.json + env overrides, AppPaths
  Log.swift          file logger (state/ai-sessions.log)
  ProcessKit.swift   sysctl/libproc: isAlive, info (ppid, start), path, ancestors
  Formatting.swift   durations, "ago", one-line previews, project labels
  ClaudeRegistry.swift   parse + validate registry records
  ClaudeTranscript.swift locate transcript, tail-read titles + last message
  ClaudeSource.swift     SessionSource over registry + transcripts
  CodexRollout.swift     incremental rollout reader + event state machine
  CodexSource.swift      SessionSource over rollouts + state DB titles
  VSCodeWindows.swift    extension-host pid → window id; editor family info
  Router.swift           RoutePlan for a TrackedSession (deep link / activate)
  Tracker.swift          engine: merge observations → TrackedSession + events
  StateStore.swift       persisted per-session state (state/state.json)
Sources/AISessions/                (AppKit app)
  main.swift, AppDelegate.swift, StatusMenuController.swift,
  Notifier.swift, RouteExecutor.swift
scripts/  build.sh install.sh uninstall.sh make-icon.swift
deploy/   local.ai-sessions.menubar.plist   Resources/Info.plist
```

Threading: the app ticks the tracker on one serial background queue every
`pollIntervalSeconds` (1 s); sources and the tracker are only touched on that
queue; the UI receives immutable `[TrackedSession]` snapshots on the main
thread.

### Tracker rules

Per `SessionKey`, compare the new observation with the stored one:

| from → to | event | unread |
|---|---|---|
| running → idle | `.finished` (duration = idle.stateSince − turnStartedAt) | true iff duration ≥ `minTurnSecondsToNotify` |
| any → waiting | `.needsInput` | true |
| any → running | `.resumed` | false (user or agent started a new turn) |
| waiting → idle | none | false (the user dealt with it) |
| idle → idle with a newer `stateSince` | none (a turn too short to see) | unchanged |
| present → missing | `.ended` | entry removed |

- A session seen for the first time is adopted silently (no event), unless
  the persisted state says it was `running` and it is now `idle` with a newer
  `stateSince` — a turn finished while the app was not running → `.finished`.
- On the very first run (no `state.json`) nothing is announced.
- `markRead(key)` / `markAllRead()` clear `unread`. Persist on change
  (atomic write), keep records of ended sessions for 24 h then prune.
- Sessions with `interactive == false` are tracked but hidden and never
  announced unless `showAutomationSessions`.
- Display order: waiting, unread, running, idle; within a group most recent
  `lastChange` first.

### App behavior

- Menu-bar item: one fixed-width square symbol with the count drawn inside
  it (a notched MacBook's bar has ~32 pt free right of the notch). Waiting →
  orange `N.circle.fill` (N = everyone who needs you); else unread → green
  `N.circle.fill`; else running → template `N.circle`; else template
  `sparkles`; N > 50 → `ellipsis.circle`. First launch seeds the item's
  `NSStatusItem Preferred Position` (between Spotlight and Battery) so it is
  not appended behind the notch; a ⌘-drag overrides it.
- Menu: sections "Needs you", "Running", "Idle"; each row = state icon +
  title + secondary "project · Claude · 4m"; tooltip = last message; click →
  route + mark read; ⌥-click (alternate) → mark read only. Footer: Mark All as
  Read, Pause/Resume Notifications, Open Log, Open Folder, Notification
  Settings…, Quit.
- Notifications (UserNotifications): one per session (identifier = key, so
  a newer one replaces the older), title = session title, subtitle =
  "Claude · coreOS · done in 4m" / "needs your input", body = last message
  preview. Click → route + mark read. Delivered notifications for a session
  are removed when it is read or resumes.
- Requires a real `.app` bundle, ad-hoc signed, registered with
  LaunchServices, outside `/var/folders`; installed at
  `~/Applications/AISessions.app`. The first launch asks for notification
  permission — answer it (an unanswered prompt counts as "deny").
- Delegate callbacks arrive on a background queue: implement them
  `nonisolated` and hop to the main queue.
- Single instance; started at login by LaunchAgent
  `local.ai-sessions.menubar` (KeepAlive on crash only).

## Testing

`swift test` covers parsing, the tracker state machine, routing plans and
window mapping with fixture files and fake processes. `AISessions --headless`
runs the engine without UI (logs events, writes `state/snapshot.json`);
`AISessions --route <key>` prints (or with `--open`, executes) the route plan.
