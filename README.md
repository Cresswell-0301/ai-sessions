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
- **Usage-limit alerts.** When the Claude account you are working on reaches
  90% of its session or weekly limit, a banner says so, when the limit resets
  and which account to switch to. With your own Telegram bot connected, the
  same alert reaches your phone. See [Usage-limit alerts](#usage-limit-alerts).
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
| `usageAlertsEnabled` | `true` | Read the usage dashboard and alert at the threshold |
| `usageAlertThreshold` | `90` | Percent of a limit that triggers an alert (1–100) |
| `usageDashboardURL` | `"http://127.0.0.1:8787"` | Where the ai-accounts dashboard runs |
| `usagePollSeconds` | `60` | How often to read it (limited to 15–3600) |
| `telegramAlerts` | `true` | Also send usage alerts to the connected Telegram chat |
| `usageAlertAccounts` | `["current"]` | Whose limits alert: `"current"` (the account in use), `"all"`, or accounts by dashboard label (`"trimo"`), tool and label (`"codex:nexxaflo"`) or email |
| `usageExcludeFile` | `"~/.ai-accounts/.suggest-exclude.json"` | The dashboard's opt-outs from its "Use first" pick, honoured by the alerts' advice |

```json
{ "minTurnSecondsToNotify": 30, "sound": false }
```

*Pause Notifications* in the menu silences everything without changing the
config. It persists across restarts as the file
`~/.ai-sessions/state/notifications-paused`, so a script can create or delete
that file to do the same (for example, while sharing your screen).

## Usage-limit alerts

The ai-accounts dashboard (`http://127.0.0.1:8787`) already reads every Claude
and Codex account's limits. Once a minute the app reads the dashboard's last
scan (`GET /data.json`) and announces a limit of **the account in use** the
moment it reaches the threshold (90%): a banner such as *cresswell-nexxatech:
Claude weekly limit at 91% — resets in 2d 4h — Most room now: looiytube2*,
whose click opens the dashboard, and a Telegram message if you connected a bot.
The app never talks to Anthropic or OpenAI itself: the dashboard holds the
accounts' sign-ins.

- **The account in use** is the one Claude Code is signed into for the
  watched config dirs (`claudeConfigDirs`, normally `~/.claude`), read from
  its `~/.claude.json` (`oauthAccount.emailAddress`, an address, not a
  credential) and matched to the dashboard's row with the same email. Sign in
  to another account (`/login`) and the alerts follow it within a minute; if
  that account is already over the threshold, that is announced at once. The
  other accounts still show in the menu, for choosing where to switch.
- **Codex** has no such address outside its credentials file, so a Codex
  account alerts only when you name it: `"usageAlertAccounts": ["current",
  "codex:nexxaflo"]`. `["all"]` brings back alerts for every account.
- **Once per crossing.** A limit alerts again only after it drops below the
  threshold in the same period, or when a new period starts. A restart does
  not repeat an alert, and the very first reading only records what is
  already over, on every account, including one the dashboard could not
  refresh at that moment.
- **Only fresh readings count.** A number the dashboard did not read just
  now never alerts and never re-arms an alert: an inferred 0% after a reset,
  an old reading kept while a run is under way ("stale"), or any reading of
  a period whose reset has passed. A lower number with a different reset,
  before the alerted period is over, is another limit, not a drop (Codex
  shows the limit its last run hit). A Codex refusal that loses its date on
  the reset's own day ("try again at 6:33 PM") is the same week.
- **Pause Notifications** silences the banner, not Telegram: a limit about to
  stop your work should still reach your phone.
- **Usage limits** in the menu shows the account in use and its limits, then
  every other account, fullest first; ✓ marks the accounts that alert. Hover a
  row for when its limits reset; click it to open the dashboard.

### Telegram

*Usage limits › Set Up Telegram Alerts…* walks you through it:

1. In Telegram, open **@BotFather**, send `/newbot` and pick a name. It replies
   with a token such as `123456789:AAH…`. Paste it into the setup's field (⌘V).
2. Click **Open @yourbot** and press **START** in Telegram. The link carries a
   code that is new for each setup, so only the chat that pressed Start on
   this Mac's link is connected; anyone else who finds the bot is ignored. No
   START button? Send the bot the `/start <code>` line that the dialog shows.
3. Confirm the name it found. A first message, with every account's usage,
   arrives right away. The token is also cleared from the clipboard.

**What the messages say.** An alert names the limit that crossed, then the
account's session and weekly limits with when each renews ("Session 64% ·
renews in 3h 27m (13:50)"), the account to **use first** — the dashboard's own
pick, leaving out the account that just crossed and any account already at the
threshold — and the one with the **most usage left**, then every account's
limits with when they renew (◀ marks the one this Mac uses).

**The Usage button.** *📊 Usage* stays under the chat: tap it (or send
`/usage`) any time for the same report about now. An alert carries a *📊 Usage
now* button too. Only your own chat is answered; anyone else who finds the bot
gets nothing. The app listens with Telegram's long polling while Telegram is
connected, steps aside while the setup runs, and does not answer taps made while
the Mac was asleep or the app was not running (they would be old).

The token is kept in `state/telegram.json`, readable by you alone, and never in
`config.json` or the log. Use a bot made only for these alerts: the setup reads
the bot's incoming messages, so a bot that sends them to a webhook, or that
another program reads, cannot be used.

A message that cannot be sent (no network, Telegram busy) waits in
`state/telegram-outbox.json` and is tried again after 30 s, then 1, 2, 4 minutes
and so on, up to every 15 minutes, for 6 hours. Meanwhile the submenu says why
and how many wait. When Telegram refuses for good (the token was revoked, the
bot was blocked), the message is dropped and a banner says so, once; *Set Up
Telegram Again…* fixes it. *Send Test Message to Telegram* checks the
connection, and *Disconnect Telegram…* forgets the bot and anything waiting.

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
| `~/.ai-sessions/state/usage-alerts.json` | which usage limits were already announced, per period |
| `~/.ai-sessions/state/telegram.json` | the Telegram bot token and chat, once you connect one |
| `~/.ai-sessions/state/telegram-outbox.json` | Telegram alerts waiting to be tried again |

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
$AISESSIONS --usage               # every account's usage limits, as the alerts see them
$AISESSIONS --usage-report        # print the report the Telegram 📊 Usage button sends (sends nothing)
$AISESSIONS --telegram-test       # send a test message to the connected Telegram chat
$AISESSIONS --version
```

`--headless` keeps its own `state.json`, snapshot and log under
`state/headless/`, so it can run next to the menu-bar app without undoing the
app's read marks. `--use-app-state` makes it read and write the app's files
instead, which only makes sense while the app is not running.

Set `AI_SESSIONS_HOME=/some/dir` to keep a test run's log and state out of
`~/.ai-sessions`. `AI_SESSIONS_CLAUDE_DIRS` and `AI_SESSIONS_CODEX_HOMES`
(colon-separated) override the watched directories, and
`AI_SESSIONS_USAGE_URL` the dashboard's address.

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
- **No usage alerts.** *Usage limits* in the menu says *dashboard not
  reachable* while the ai-accounts dashboard is down: check
  `http://127.0.0.1:8787`. It says *can't tell which account is in use* when
  `~/.claude.json` names no account, and *… is not on the dashboard* when the
  account you are signed into has no row there (add it on the dashboard).
  `AISessions --usage` prints what the alerts see and which account they
  follow. An account already over the threshold when the app first read the
  dashboard was recorded, not announced; it alerts after its next reset.
- **Telegram stays quiet.** The submenu's Telegram row turns into *not
  delivering* with the reason, and the log has a `usage alert not sent`
  line for each try. *Send Test Message to Telegram* or
  `AISessions --telegram-test` tries at once.
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
