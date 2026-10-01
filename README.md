# AI Sessions

A macOS menu-bar app that keeps track of every Claude Code and Codex session on
this Mac. It tells you when a session finishes a turn or needs your input, and
one click takes you back to that session's tab.

- **Menu-bar icon and count.** A circle with a number in it. Orange: that many
  sessions need you (a permission prompt, a question, a plan to approve, or a
  finished turn you have not looked at yet). Green: that many finished turns
  you have not looked at, and nothing is waiting. Outline: that many sessions
  are running. Sparkles: all quiet.
- **Menu.** Sessions grouped as *Needs you*, *Running* and *Idle*, each with its
  tab title, project, agent and time in its current state. Hover a row to see
  the agent's last message. Click a row to go to the session. Hold ⌥ and click
  to mark it read without going there.
- **Notifications.** One per session ("AI Track — Claude · coreOS · done in 4m"),
  replaced by the next one. A banner is removed once its session no longer
  needs you: you read it, it starts working again, or you answered its
  question in the editor. A session that ends (tab closed, window reloaded)
  keeps its banner. Click one to go to the session; its buttons are *Open* and
  *Mark as Read*. Turns shorter than 10 seconds are not announced, since you
  were probably watching, and neither is a turn you stopped yourself (Esc in
  Claude, Stop in Codex). A question is always announced.
- **Back to the tab.** A Claude or Codex session in VS Code (or Cursor,
  Windsurf, VSCodium, Insiders, or another VS Code fork) opens in the exact
  editor window that owns it. An editor whose link scheme is unknown is just
  brought to the front. A `claude` running in a terminal brings that terminal
  app to the front.

It needs no hooks and changes nothing in Claude Code, Codex or VS Code: it only
reads the files they already write (see [How it works](#how-it-works)).

## Install

Requires macOS 14 or later and a Swift 6 toolchain (Xcode or the Command Line
Tools).

```sh
~/.ai-sessions/scripts/install.sh
```

This builds `build/AISessions.app` (release build, ad-hoc signed), copies it to
`~/Applications/AISessions.app`, registers it with Launch Services, and
installs the LaunchAgent `local.ai-sessions.menubar`. The agent starts the app
now and at every login, and restarts it if it crashes. Run the script again to
update. To build without installing, use `scripts/build.sh`.

## Uninstall

```sh
~/.ai-sessions/scripts/uninstall.sh           # app + LaunchAgent
~/.ai-sessions/scripts/uninstall.sh --purge   # …and ~/.ai-sessions/state
```

`config.json` and the sources are kept either way.

## First run

1. **Allow notifications.** The first launch asks. Answer the prompt, because
   an unanswered one counts as *deny*. You can change your answer later under
   *Notification Settings…* in the menu, and *Send Test Notification* shows
   what a banner looks like.
2. **VS Code's one-time question, once per extension.** The first time you go
   back to a Claude session, VS Code asks *"Allow 'Claude Code for VS Code'
   extension to open this URI?"*, and the first time you go back to a Codex
   thread it asks the same for *'Codex – OpenAI's coding agent'*. Tick
   **Do not ask me again for this extension** and choose **Open**. Dismissing
   the question opens nothing. To approve both ahead of time, add this to
   VS Code's user `settings.json`:

   ```json
   "extensions.confirmedUriHandlerExtensionIds": ["anthropic.claude-code", "openai.chatgpt"]
   ```
3. **Find the icon.** On a MacBook with a notch, menu-bar items that do not fit
   are hidden behind it. ⌘-drag the icon to the left of other items (the
   position is remembered), or limit which apps may show items under
   *System Settings → Menu Bar*.

## Settings: `~/.ai-sessions/config.json`

Every key is optional, and a missing file means all defaults. Changes take
effect within about 5 seconds, with no restart. A file that is no longer valid
JSON does not reset anything: the app keeps its previous settings and logs a
warning until the file is fixed.

| key | default | meaning |
|---|---|---|
| `notificationsEnabled` | `true` | Post notifications at all |
| `sound` | `true` | Play the default sound with each notification |
| `minTurnSecondsToNotify` | `10` | Shorter finished turns are not announced and not marked unread |
| `claudeConfigDirs` | `["~/.claude"]` | Claude config homes to watch (each has a `sessions/` registry) |
| `codexHomes` | `["~/.codex"]` | Codex homes to watch |
| `codexRecentHours` | `12` | A Codex thread stays listed this long after its last activity |
| `showAutomationSessions` | `false` | Also list (and announce) `claude -p`, SDK runs, `codex exec` and sub-agents |
| `pollIntervalSeconds` | `1.0` | How often to look (limited to 0.25–10) |

```json
{ "minTurnSecondsToNotify": 30, "sound": false }
```

*Pause Notifications* in the menu silences everything without changing the
config. It persists across restarts as the file
`~/.ai-sessions/state/notifications-paused`, so a script can create or delete
that file to do the same (for example, while sharing your screen).

## Files

| path | what |
|---|---|
| `~/Applications/AISessions.app` | the app |
| `~/Library/LaunchAgents/local.ai-sessions.menubar.plist` | starts it at login; restarts it after a crash, never after *Quit* |
| `~/.ai-sessions/config.json` | your settings (not in git) |
| `~/.ai-sessions/state/ai-sessions.log` | the log; rotated to `.1` at 1 MB |
| `~/.ai-sessions/state/launchd.log` | anything the app printed, captured by launchd |
| `~/.ai-sessions/state/state.json` | per-session memory across restarts (what was running, what is unread) |
| `~/.ai-sessions/state/snapshot.json` | the current session list as JSON, for scripts and other tools |
| `~/.ai-sessions/state/notifications-paused` | present while notifications are paused |
| `~/.ai-sessions/state/headless/` | `--headless`'s own state, snapshot and log |

`state/` is readable by you alone (the folder is `0700`, its files `0600`): it
holds session titles, which are often your own prompts, and the agents' last
messages. Notification banners show the last message too.

`~/.ai-sessions` is also the source tree (a Swift package). `state/` and
`config.json` are git-ignored.

## Command line

The app binary doubles as a tool:

```sh
AISESSIONS=~/Applications/AISessions.app/Contents/MacOS/AISessions
$AISESSIONS --headless            # no UI: log events, print sessions, write a snapshot
$AISESSIONS --headless --use-app-state   # …in the menu-bar app's own state files
$AISESSIONS --route claude:9eb4   # print how it would get back to a session (key or unique prefix)
$AISESSIONS --route claude:9eb4 --open   # …and do it
$AISESSIONS --test-notification   # ask the running app for a sample banner (optionally: a session key)
$AISESSIONS --version
```

`--headless` keeps its own `state.json`, snapshot and log under
`state/headless/`, so it can run next to the menu-bar app without undoing the
app's read marks. `--use-app-state` makes it read and write the app's files
instead, which only makes sense while the app is not running.

Set `AI_SESSIONS_HOME=/some/dir` to keep a test run's log and state out of
`~/.ai-sessions`. `AI_SESSIONS_CLAUDE_DIRS` and `AI_SESSIONS_CODEX_HOMES`
(colon-separated) override the watched directories.

## Troubleshooting

- **No notifications.** When macOS blocks or silences the banners, the menu
  shows a row at the top (*Notifications are off — Turn On…*) that opens the
  right settings pane. Otherwise check *System Settings → Notifications → AI
  Sessions* (allowed, banner style), Focus modes, *Pause Notifications* in the
  menu, `notificationsEnabled`, and whether the turn was shorter than
  `minTurnSecondsToNotify` or was one you interrupted. *Send Test
  Notification* in the menu posts a sample banner. The log records the
  permission answer at every start: look for `notifications are allowed` /
  `are not allowed`. A binary run from outside the `.app` (for example
  `.build/release/AISessions`) never posts notifications, and logs that it
  does not.
- **The icon is missing.** It may be hidden behind the notch (see First run).
  Check that the app is running:
  `launchctl print gui/$(id -u)/local.ai-sessions.menubar | grep -E 'state|pid'`.
- **A click opens nothing.** The first Claude link and the first Codex link
  each ask VS Code's one-time question; if it was dismissed, nothing opened.
  Click again and choose **Open**, or pre-approve both (see First run).
- **A click opens the wrong window or a new tab.** Run
  `AISessions --route <key>` to see the plan and the URL. The window id comes
  from the log file the window's extension host holds open, or else from the
  editor's log folder (the newest launches that have windows; the empty
  folders that each `code <path>` launch leaves are skipped, up to 15 of
  them). When neither names the window, the link has no `windowId` and VS
  Code uses its last active window. A session you keep in the Claude sidebar
  opens as an editor tab: the extension's link always opens the session in an
  editor tab, reusing the window's tab when it has one.
- **A click meant for window 1 lands in window 12.** VS Code matches a link's
  `windowId` as a prefix: `windowId=1` goes to the first connected window
  whose id starts with 1 (1, 10–19, 100…), and a window that reloads or opens
  a folder moves to the back of that line. This is a VS Code bug, and no link
  can avoid it. `--route` and the log warn when it can happen
  (`may deliver windowId=1 to window 12`). Reloading the other window puts it
  behind this one again; restarting VS Code numbers its windows afresh.
- **A session is missing.** Automation sessions (`claude -p`, SDK, `codex exec`,
  sub-agents) are hidden unless `showAutomationSessions` is on. Codex threads
  drop off `codexRecentHours` after their last activity. The log's
  `watching …` line at startup names the directories being read.
- **Anything else.** *Open Log* in the menu. Every route, event, reload and
  error is there, and `--headless` prints the same lines live.

## How it works

- **Claude Code** keeps a live-session registry: `~/.claude/sessions/<pid>.json`
  holds each running session's status (`busy`, `idle` or `waiting`) and when it
  changed. A record counts only while its process is alive and started when
  the record says, which guards against stale files and reused pids.
  `waiting` means a question or a permission prompt, except while you have a
  slash-command dialog (/model, /config, …) open in the terminal, which Claude
  also records as `waiting` (`waitingFor: "dialog open"`): that is not a
  question. The session's transcript (`~/.claude/projects/*/<id>.jsonl`, read
  from the end only) supplies the tab title and the last message. The app
  never opens the `.key` files next to the registry.
- **Codex** appends every thread to a rollout file
  (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`): `task_started` means
  running, `task_complete` means idle, and `turn_aborted` is a turn you
  stopped. A turn that writes nothing for 3 hours, or for 2 minutes while no
  `codex` process is alive, is abandoned (its app-server was killed, or VS
  Code quit mid-turn): it turns idle silently. Titles come from Codex's state
  database, opened read-only.
- **The tracker** compares each poll with the previous one. *Running → idle* is
  a finished turn, unless you interrupted it (Esc in Claude, which writes
  `[Request interrupted by user]` to the transcript; Stop in Codex) or it was
  abandoned: those are not announced. *→ waiting* means you are needed,
  *→ running* withdraws stale notifications, and *waiting → idle* (you
  answered in the editor) withdraws the question's banner. What it last saw is
  kept in `state.json`. When the app starts again, a turn that finished while
  it was not running is announced once if it ended in the last 60 minutes
  (for Claude, only in the same process that ran it), a question asked
  meanwhile is announced, and nothing is announced twice.
- **Going back** uses the editors' own URI handlers:
  `vscode://anthropic.claude-code/open?session=<id>&windowId=<n>` reveals the
  Claude tab in the window that owns it, and
  `vscode://openai.chatgpt/local/<thread>` opens the Codex thread (with
  `?windowId=<n>` when several windows are open). The window number comes
  from the log file the window's extension host holds open, or else from the
  editor's log folder. Cursor, Windsurf, VSCodium and Insiders use their own
  schemes; any other VS Code fork is recognised from its own `product.json`
  (`urlProtocol`). For a terminal session, the terminal app is activated (one
  tab cannot be chosen without the Automation permission).
- Polling runs once a second on a background queue. A quiet poll costs a
  directory listing and a few `stat` calls, and files are re-read only when
  they change.

## Development

```sh
swift build                 # debug build
swift test                  # unit tests (fixtures in temp dirs; never your real ~/.claude)
scripts/build.sh            # release .app in build/
```

See `DESIGN.md` for the verified facts behind each signal and the tracker's
rules table.
