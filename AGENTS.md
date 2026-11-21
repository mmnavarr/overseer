# Overseer for agents

Dense reference for coding agents (and humans) changing Overseer. It favors completeness over brevity. The user-facing overview is [README.md](README.md); keep that one short and put detail here.

Contents: [Runtime model](#runtime-model) · [The 50 ms rule](#the-50-ms-rule-read-this-first) · [Files](#files) · [State](#state) · [Flows](#flows) · [Behavior reference](#behavior-reference) · [Developing](#developing) · [Known limitations](#known-limitations)

## Runtime model

Overseer is a Tern plugin written in Luau. `plugin.toml` declares two entry points:

- `host.luau` runs in Tern's host and renders the `overseer.new-worktree` block: the New worktree page, in a tab of its own, for New worktree and Create sub-worktree. `input.luau` is its Unicode-aware text editing. It also loads `settings.luau`, the `overseer.settings` block: the Settings tab.
- `window.luau` runs once per Tern window. It owns the Projects panel (a canvas that follows you between tabs), event hooks, the background job tracker, coordination relays, the operation log, the Carly export, and Visualize PR canvases.

Three pieces run inside omp, not Tern, and share only Git config and files in the repository's Git directory with the plugin. They make up `omp/`, the omp plugin package `overseer-omp`: `omp/overseer-rails/index.ts` (a TypeScript omp extension, declared in `omp/package.json`), `omp/rules/overseer-worktrees.md` (an omp TTSR rule) and `omp/skills/overseer-subworktree/` (a skill whose script is plain Bash). `omplink.luau` links the package into omp on every load (`omp plugin link`), so agents reach the script at the stable `~/.omp/plugins/node_modules/overseer-omp/skills/overseer-subworktree/overseer-subworktree` wherever Tern installed the plugin. It re-links only when the link leads elsewhere, keeps a disabled package disabled, and then removes the old hand-made `~/.omp/agent` symlinks, only those pointing into an Overseer checkout.

Tern APIs are typed in the definitions Tern generates: `/Applications/Tern.app/Contents/MacOS/tern plugin types <dir>` writes `tern.d.luau`. Read it before using an API you haven't used here.

## The 50 ms rule (read this first)

Tern gives **every window-half callback 50 ms**. Tern's docs say native calls (the `cx` API, `tern.kv`, `tern.fs`, starting a process) don't count and allow 500 ms of wall time with them, but **measured on Tern 0.9.26 they count**: a callback looping on `cx.session:panes()`, `tern.kv.get`, `tern.kv.set`, `tern.fs.exists` or `tern.ui.node` is cut short at 50 ms like pure Lua. Budget wall time, natives included. A callback past the limit is cut short (`pcall` doesn't help, and its `tern.kv` writes can be lost) and Tern **pauses that hook**: 5 s, doubling for each repeat within 10 minutes of the last pause's end, up to 5 minutes. Timers, process results and fetches that come due during a pause wait for it to end; they aren't dropped. Up to 2.6.0 a draw took 35–55 ms in a busy window (17 worktrees, 20 tabs, many agents), nearly all in `render`: `tern.ui.node` converts the whole subtree it's given on every call, so a nested panel paid for each node once per ancestor. `view.luau` now builds its nodes as the same plain `{k, p, c}` tables in Lua (keep it that way; only leaves like `tern.ui.span` stay native). In a 16-worktree, 32-tab test panel that took render from 7.3 to 0.6 ms and a whole draw from 11.6 to 4.8 ms, most of what's left being `cx.canvas:set`. A callback the Mac's sleep interrupts runs over too: overnight logs show a trip at each dark wake, and pauses staying at 5 minutes until morning.

`budget.luau` owns this:

- **Work runs in timer callbacks; every other hook only queues it.** Clicks (`canvas_action`), commands, and tab, pane, focus and agent events call `separately(label, fn)`, `followSoon()` or `followFrom(cx)`, and return. A paused `canvas_action` hook would swallow every click until the pause ends, so it must stay too small to trip. `budget.later(label, ms, fn)` is the only way to start a timer: it labels the callback so a timer pause names it.
- **A timer pause doesn't freeze the panel.** While the timer hook is paused (`timerPaused()`, from `pausedUntil`, which the `budget` event keeps per hook), `userAction` runs clicks and commands in their own hook instead of queuing them, `followFrom` moves the panel from the tab, pane and focus events themselves, and `redraw` draws at once (the first request per callback; later ones wait for the queued draw). Jobs finish from their watchers' process results (see Tick). The New worktree page asks the window through links instead (`tern-overseer:create?…`, `tern-overseer:close`): the window's `tern.route.link` handler runs in the link hook and acts through `userAction` too. Rename is Tern's own prompt (`cx:prompt`), whose answer comes in the `await` hook. Without this a click waited out the pause, up to 5 minutes, and seemed to do nothing.
- **Pauses are logged.** The `budget` event logs `Overseer: Tern paused its <hook> hook for N s after a callback (<label>) ran over 50 ms` and, when the hook resumes, runs `followSoon` to catch the panel up.
- **Make every step safe to cut short.** A callback that's cut short leaves its in-memory state behind and can lose its kv writes. So write the record that says "done" last: `checkJobs` takes a job off the books before deleting its receipt. In-memory "waiting for a result" marks (`entry.loading`, `prLoading`, `linksLoading`, `spinning`) hold when they were set (`claim`/`release`); one with no result 30 s after it was set, or after the process hook's last pause, counts as lost (`lost`), so the next refresh starts again and logs `refresh lost`. Before 2.6.3 a listing result cut short left `loading` set until a reload: no new worktrees, no PR updates, ↻ doing nothing.
- There is **one panel per window**, so a draw costs the same however many sessions are open.
- **Start processes only through `wt.spawn`** (except the wake process and the job watchers, which `unload` must kill, so they keep `tern.process.spawn`'s handle). It starts the process right away and hands the result, or a failure to start, to the caller with a `cx`, logging errors in the callback under the command's name.

Tern runs a window's plugin timers only when something wakes the window: a plugin event, a process's output, a `tern ctl` command. A window that sits idle runs none, the end of a timer pause doesn't wake it (measured on Tern 0.9.28: a 1 s timer chain stood still for a minute after a 5 s pause until the next event), and typing in a terminal seems not to either. So Overseer keeps a wake process (`startWake`: a `/bin/sh` loop printing a line every 5 s, whose `stdout` callback does nothing).

When debugging an overrun, read the log: `exceeded its budget; paused … hook="timer"` is followed by Overseer's line naming the callback that ran over.

## Files

| File | What lives there |
|---|---|
| `window.luau` | Project registry, model building (`model`), drawing (`draw`/`redraw`), the following panel (`slot`, `pin`, `follow`, `followSoon`, `togglePanel`), session binding (`ensureSession`, `openWorktree`), the New worktree page's tab and links (`openNewWorktree`, `closePage`, `createFromPage`), Rename's prompt, background jobs (`launchCreation`, `watchJob`, `checkJobs`, `jobFinished`), ticket links (`ticketOf`, `ticketFor`), Linear workspace lookup, Visualize PR canvases, the Carly export, hooks and the 750 ms `tick`. |
| `budget.luau` | Living with the 50 ms rule: `later` (labelled timer callbacks), `process` and `fetch` (process and fetch results with logged errors), and `describe` (the log line for a `budget` event). |
| `worktrunk.luau` | Every external command: `wt list`, validation, the creation and removal command lines, `git` status, `gh pr list`/`gh pr view`/`gh pr diff`, `linear auth whoami`. Commands are argv arrays started by `spawn`; `find_executable` checks Homebrew, `/usr/local/bin`, `~/.bun/bin` and `~/.local/bin`. |
| `visualize.luau` | Visualize PR: prompt, read-only omp invocation, output extraction, cache. |
| `view.luau` | Pure render: model → Tern UI node tree (rows, badges, tab rows, confirm strips, menus, the notice toast), and the operation log's table (`operationLog`). Actions are Tern's own kinds (`button`, `buttons`, `badge`, `card`, `empty`, `shimmer`, `toast`, `table`, menu rows); no HTML buttons. Its local `ui` builds `node`, `el`, `button` and `card` as plain `{k, p, c}` tables, the shape `tern.ui`'s return, without `tern.ui.node`'s per-call subtree conversion ([the 50 ms rule](#the-50-ms-rule-read-this-first)); row keys' hex paths are cached. |
| `worktree-operation.sh` | The helper that runs `wt switch --create` (mode `create`), `wt switch` on an existing branch (mode `existing`) or `wt remove` in a visible terminal and writes an atomic completion receipt. |
| `host.luau`, `input.luau` | The New worktree page block and its text input. |
| `styles.css`, `icons.css` | Panel layout and status marks only: Tern's kinds draw buttons, badges, cards and menus themselves. The canvas has no `font` prop, so `styles.css` sets the panel in the UI face (`--sans`) and branches and paths back in `--mono`. `icons.css` is **generated** by `icons/generate-css.py` (plugin stylesheets can't load files, so icons are embedded as data URIs). |
| `skills/visual-pr/` | HumanLayer's visual-pr skill, vendored unchanged (MIT). |
| `omp/package.json` | Makes `omp/` the omp plugin package `overseer-omp`; declares the extension. Keep its `version` in step with `plugin.toml`. |
| `omp/skills/overseer-subworktree/` | The omp skill and script for creating worktrees: sub-worktrees of the worktree the script runs in (optionally with a brief for their own session), top-level ones otherwise. |
| `omp/rules/overseer-worktrees.md` | The omp TTSR rule that redirects raw worktree-creating commands to that skill. |
| `omp/overseer-rails/index.ts` | The omp extension behind [coordination](#coordination): family summary before each prompt, the notes board, the `overseer_family` tool and its mailbox. |
| `omplink.luau` | Links `omp/` into omp each time the plugin loads, and removes the old hand-made symlinks; logs to the operation log. |
| `oplog.luau` | The operation log (`ops.log`), reading an operation's terminal, and spotting a creation's step, questions and warnings in it. |
| `settings.luau` | The Settings tab (block `overseer.settings`, opened in a tab by the header's cog or **Overseer Settings** in the palette): General (Ice Box), each project's base branch, Linear workspace and agent coordination, Integrations (whether `gh` and `linear` are installed and signed in, with Install and Connect), and Help & Diagnostics (the guide, the changelog read from `CHANGELOG.md`, the operation log, and diagnostics to copy). It runs in Tern's daemon, whose processes get the Dock's minimal PATH, so it finds CLIs with `wt.find_executable` like the panel does. Tern keeps a block's scroll position between pages, so `openPage` draws the log and changelog short first, which brings them back to the top, and fills them in 30 ms later. |
| `prefs.luau` | Settings shared by both halves: kv `settings` (defaults filled in, wrong types ignored), `settings-rev` (bumped on every change made from Settings; the window's tick watches it to refresh and redraw), and `SETUP`, the Install and Connect commands the window runs in a terminal for the Settings tab (kv `setup-request`). |
| `update.luau` | The header's **Update** button: this copy's version (`plugin.toml`), how it updates (`how`: `install` for a copy `tern plugin install` made, `pull` for a linked Git checkout, nil otherwise), the newest version (`plugin.toml` on the repository's `main`, which is what `tern plugin install` fetches), and the announcement after an update. |
| `tests/test_worktree_operation.py`, `tests/test_subworktree.py` | Real Git/Worktrunk tests for the helper and the sub-worktree script. |

## State

Tern's plugin KV (`~/Library/Application Support/Tern/plugin-data/overseer/kv.json`), via `tern.kv`:

| Key | Shape | Notes |
|---|---|---|
| `projects` | `[{id, name, path, base, linear?}]` | `id` is the repository's shared Git directory, so linked checkouts dedupe. `linear` overrides the CLI workspace. |
| `worktree-names` | `{[projectId]: {[path]: name}}` | Display names. Removed when Overseer deletes the worktree, or when a refresh finds it gone. |
| `sessions` | `{[path]: {id, host, project}}` | Worktree → Tern session binding. A refresh drops bindings of gone worktrees whose session is closed. |
| `icebox` | `{[projectId]: {[path]: true}}` | Parked worktrees. `show-icebox` is the header toggle. |
| `jobs` | `{[id]: {kind = "create" \| "remove", project, receipt, pane, …}}` | Running creations and deletions; creations also carry `branch`, `displayName?`, `parent?` (the branch a sub-worktree goes under), `existing?` (open an existing branch instead of making one from the base) and `agentPrompt?`. Persisted so a plugin reload doesn't lose them. |
| `panel-open`, `panel-share` | `boolean`, `number` | Whether you want the Projects panel shown (the shortcut sets it), and its width as a share of the tab. |
| `agents-finished` | `{[paneId]: "done" \| "failed"}` | Agent turns that ended while their tab wasn't shown. Cleared when the tab is shown, the agent starts again, or the pane closes. |
| `rails` | `{queue, unread, sentAt, checkin, told}` | Coordination relays; see [Flows](#flows). |
| `coordination-migrated` | `{[projectId]: true}` | Repositories already settled by the 2.4.0 opt-in migration (or switched by hand), so it runs once each. |
| `settings`, `settings-rev` | `{icebox}`, `number` | Overseer's settings, and a counter Settings bumps on every change it makes (see `prefs.luau`). |
| `setup-request` | `{run, window, at}` | An Install or Connect clicked in Settings, for the window to run in a terminal (`runSetup`). |
| `update-check`, `update-started` | `{at, latest}`, `{from}` | The newest Overseer version and when it was fetched, and the version an Update click left, so the reloaded copy can say it worked (see [Flows](#flows)). |

Beside the kv store, `ops.log` in the plugin data directory is the operation log: one JSON line per creation, deletion, brief, relay and gone worktree (start, finish, duration, outcome, first warning), newest last, capped at 256 KB. The **Show Overseer's operation log** command (`showLog`) opens its newest 200 entries (`oplog.recent`) as a table in a glimpse canvas (`how = "glimpse"`: over the shown tab, gone at the next click outside it). The same entries go to Tern's log, at info for routine starts and finishes and warn for failures, warnings and "needs you".

Shared with agents through Git config (Worktrunk's per-branch variables): `overseer-parent` (sub-worktree links) and `overseer-lead` (the pane id of a worktree's overseer session).

Files under `tern.plugin.data`: `creation-<id>.status` and `removal-<id>.status` receipts written by the helper, and the `visual-pr/<project>-<pr>-<headsha>.md` outline cache.

In-memory only: the per-project `cache` (worktrees, PRs, gone paths with open sessions, loading/error flags), `rendered` signatures per panel pane, the panel's pane and last tab, the Linear default workspace, open outline canvases.

## Flows

**Refresh.** `refresh` runs `wt list --format=json` per project, beside `refreshLinks` (`wt config state get --format=json`, keeping the `overseer-parent` vars as `entry.parents` and `overseer-lead` as `entry.leads`; a failed read keeps the last links), then, after a successful listing, `refreshPullRequests` (one `gh api graphql` search per GitHub project, at most every 2 minutes, immediately after ↻ or a worktree set change). An open panel refreshes every 15 s from `tick`, a hidden one every 60 s so the coordination relays keep working, and never more often than 20 times the slowest last listing (`listingCost`, up to 2 minutes): `wt list` reads every worktree's status, about 1.3 s and 5 s of CPU in a 17-worktree monorepo. Every step reports to the operation log (`op` `refresh`) only when its state changes: `track` writes `failed` when a step (worktree listing, sub-worktree links, coordination setting, GitHub PR lookup) starts failing or fails differently and `recovered` when it works again; `watchListings` (each tick) writes `stale` once a project has gone 3 minutes without a listing, saying whether `wt list` is unanswered, failing or not being started, and the next listing writes `fresh`; `claim` writes `lost` when it takes over a mark whose result never came. The tick itself writes `tick late` when it runs after a gap of a minute or more not spent with the Mac asleep (`reportGap` subtracts the last sleep, read with `sysctl kern.sleeptime kern.waketime`), noting a timer pause in between.

**Tick.** `tick` runs every 750 ms while the window is awake (the wake process sees to that at least every 5 s) and queues its next run first, so an error can't stop it. Tern never drops the chain: across 50 ms and 500 ms overruns and repeated pauses, the next tick runs once the window wakes. What can't wait for a tick has its own trigger. Each job has a watcher (`watchJob`: a `tern.process.spawn`ed `/bin/sh` loop that ends once the receipt exists, or the helper's PID in `<receipt>.pid` is gone), started with the job and again on load for jobs in kv `jobs`, killed when `checkJobs` takes the job off the books and in `unload`; its exit runs `checkJobs` through `userAction`. The tick's own `checkJobs` is the backstop (a helper that died without a receipt). The panel follows from events (`followFrom`). Up to 2.6.2 the process clock also restarted ticks it thought lost and ran `checkJobs` and `follow` every 5 s while timers were paused; the chains were only asleep, and that work tripped the process hook, which delivers every `wt` and `gh` result. Only its waking was needed. The tick draws only every 5 s (`followSoon(quiet)`); events draw at once. `snapshot(cx)` fetches panes and tabs once per callback for `model`, and builds the agent list from them (`agentBlocks`; see Agent status).

**Coordination.** Opt-in per repository: `overseer.coordination=true` in the repository's shared Git config (`wt.coordination` / `wt.set_coordination`, read beside the links on every refresh into `entry.coordination`). Off, Overseer queues and delivers nothing, drops what was queued, hides **Make overseer session**, **N new**, check-ins and the **Overseer** badge, and the extension stays silent. Turning it on goes through a confirmation card; turning it off doesn't. In 2.4.0, `railsAfterSwitch` keeps it on, once per repository (kv `coordination-migrated`), where coordination was in use before it became opt-in (an `overseer-lead` var or `rails` records for one of its worktrees). Three parts, one shared vocabulary (the `overseer-parent`/`overseer-lead` branch variables and `<git-common-dir>/overseer/`):

- *The omp extension* (`omp/overseer-rails/index.ts`) runs in each interactive omp session in a Tern pane (subagents and the advisor are headless and skip it), and only while `git config --bool overseer.coordination` says `true` (cached like the family). `before_agent_start` reads the family from git config (`worktrunk.state.<branch>.vars.*`, milliseconds where `wt` takes ~0.4 s), diffs each relative's branch tip against what this session last saw (kept as `overseer-rails.seen` session entries, so it survives resume), adds the latest note from the board, and flags files both branches change against `origin/HEAD`. Notes are lines in `<git-common-dir>/overseer/notes.jsonl` (appended once per turn; compacted to the newest 80 past 256 KiB). `overseer_family` action `message` writes one JSON file per recipient branch into `<git-common-dir>/overseer/outbox/` (temp file, then rename) and returns at once; it never waits for a reply.
- *Overseer's relays* (`window.luau`, "Coordination rails"): `onAgentChange` (from `agent_state`/`agent_finished`) records check-ins and relays a sub-worktree's lead going waiting or failed, and remembers a finished turn so `noticeFinished` relays it once its PR is known (once per PR and head commit, within 15 minutes). `noticeMoves` compares each listing's head commits with the last: a parent that moved notifies children containing its old tip when that tip isn't on the base branch. `deliverMail` (every tick) reads each coordinating repository's outbox, queues each message for the recipient branch's worktree with who sent it, and deletes the file (unreadable or undeliverable ones are logged and deleted too). `tell` queues per worktree; `flushRails` hands the queue to the worktree's lead (`leadOf`: `overseer-lead` while its agent runs, else the only agent, any CLI) with `cx.agents:ask`, at most once a minute per pane unless the message is marked urgent (agent mail), three attempts. `syncLeads` keeps `overseer-lead` true for worktrees in a family.
- *Briefs*: `overseer-subworktree --brief` writes `overseer-brief.md` into the new worktree's private Git directory; `startBriefs` renames it to `overseer-brief.started.md` (so a refresh can't start it twice) and runs `tern new session|tab … -- omp @<file>` without switching you away, binding a new session to the worktree.

Kept in kv `rails` (times are `os.time()` seconds): `queue`, `unread`, `sentAt`, `checkin`, `told`. `reconcileGone` drops gone worktrees' records; rate marks expire after a minute.

**Sub-worktrees.** `owners(entry, pending)` maps each worktree to the top of its `overseer-parent` chain among the listed worktrees (a link past the listing stops there, a cycle or a primary checkout as child stays on top); `pending` adds the `parent` of creations still running, so a sub-worktree nests before its link is saved. `model` puts owned worktrees in their owner's `children` (Ice Box ones last; an iced owner parks them; `folded` is in memory; each is marked `owned`) with `childAgent` the most urgent agent among them; unfolded, the view wraps the owner's group and a `c` column of its sub-worktrees in a `t<hex>` lineage column, which draws the tree lines (`styles.css`), and path recovery (`w<hex>.row`, matched at the id's end) works unchanged. Rows mark the active worktree `active` rather than Tern's `pick`, whose accent bar would sit among those lines. **Move under…** offers only top-level worktrees (`cx:pick`), and both it and **Make top-level** go through `setParent`: an optimistic `entry.parents` update, `wt config state vars set|clear`, then `refreshLinks`. **Create sub-worktree…** (top-level, non-primary worktrees with a branch) opens the form in mode `child`; `createWorktree` records the worktree's branch as the job's `parent`, the creation runs like any other (from the project's base branch), and `applyCreated` links it with `setParent` once Worktrunk lists it. Deleting an owner opens the `delete-family` confirmation; **Delete all** queues one `beginRemoval` per sub-worktree with `keepIfDirty` (a dirty one is kept with a toast instead of asking) and then the owner's own.

**Gone worktrees.** After each successful listing, `reconcileGone` treats a recorded path that isn't listed, isn't being deleted and isn't on disk as removed outside Overseer. It drops the path's `worktree-names` and `icebox` entries. If the path's bound session is still open it goes in `entry.gone`, and `model` adds it as a `gone` row (`goneNode` in the view: click switches to the session, the menu offers only **Close session**). Otherwise the binding is dropped. Never closing these sessions automatically is deliberate: an agent that removes its own worktree would be killed before you read its reply.

**The following panel.** Tern panes belong to one tab, and plugins can't add a window-level sidebar, so the window keeps exactly one Projects slot and moves it into whichever tab is shown, left of everything and full height, except the Settings and New worktree tabs, which get the whole tab (`pageTab`). `slot` finds it: the navigator canvas, adopting what a reload left open and closing any extra (and any `overseer.form` pane an Overseer 2 layout brought back). `pin` moves it with `move_to_tab` (or `unpark`) then `move(…, "left")` and steers the split ratio to the remembered share, since Tern resizes in cells and hidden tabs measure differently. `followSoon` queues `follow` on `focus`, `tab_created`, `tab_closed`, `pane_created`, `pane_closed`, `session_ended` (a session another window or `tern kill session` ended fires no `pane_closed` here), `window_start` and every `tick`. Moves work across sessions. Edge cases:

- **Last terminal in a tab closed:** the panel would be left alone, so `follow` parks it; the tab closes as Tern would have, and the next shown tab (or new tab) takes the panel back.
- **Overseer closes a session:** `closeManagedSession` switches away and calls `follow` first, so the panel leaves before the session closes.
- **Tern closes the panel's tab or session:** the panel dies with it. If you wanted it (`panel-open`) and its last tab is gone, `follow` opens a fresh one in the shown tab. If its tab is still there, you closed the panel yourself, and it stays closed until the shortcut.

**Create.** **+**, **Create sub-worktree…** or the **Create worktree** command → `openNewWorktree` opens the page (`overseer.new-worktree`, args: project id, then a sub-worktree's parent path, branch and label) in a new tab, replacing any other page, and remembers the tab you came from (in memory) → the page checks the branch itself (`wt.validate`, in the host, where Overseer's timers can't hold it up: for **New branch** the base exists and the branch exists neither locally nor as `refs/remotes/*/<branch>`; for **Existing branch** it's a local branch no `git worktree list` record holds, or on exactly one remote) and opens `tern-overseer:create?project=…&branch=…&name=…&parent=…&parentBranch=…&existing=1` (`existing` only for **Existing branch**) → the window's link handler, only for links opened from a page's own pane, runs `createFromPage`: `launchCreation` opens a background tab running `worktree-operation.sh` (mode `create`, or `existing` for `wt switch` without `--create` or a base) and records a job, then `closePage` shows the tab you came from and closes the page (a refusal goes back to the page as a `retry` event). Cancel and Esc open `tern-overseer:close`. The page saves nothing; one Tern restores after a restart opens blank. Carly's `ticket_worktree` goes straight to `launchCreation`. Then `trackCreations` (on `tick`) reads the tab's last lines: the newest `◎ Running` step for the row, a question on the last line (Worktrunk's `[y/N]`) or 60 s without output for **Needs you?**; `model` shows the job as a **Creating** row, right away if Worktrunk doesn't list the worktree yet (under its parent for a sub-worktree) → `checkJobs` reads the receipt → `jobFinished` scans the tab's output for warnings (`oplog.warnings`: Worktrunk's ▲/✗ marks and `warn:`/`error:` labels, not its echo of hook commands or its approval header), closes the tab on success, and writes the outcome to `ops.log` → toast, apply the display name and sub-worktree link by branch (`applyCreated`), and for ticket worktrees `startTicketAgent` opens the session and calls `cx.agents:start({command = "omp", prompt = …})`. Creation succeeded means `wt` exited 0; hook warnings are only logged.

**Delete.** `beginRemoval`: `wt.validate_removal` (repository identity and branch from `git worktree list --porcelain -z`, tens of ms; `wt list` took over a second in a large repository) while the row shows **Checking**, then `wt.local_changes` (`git status --porcelain=v1 -z --no-renames` plus `git diff HEAD --numstat`, first 200 entries) → clean: removal job right away. Dirty: the changes fill the confirmation; **Force delete** reruns `beginRemoval` with `force`, which skips the changes, and the helper runs in `force-remove` mode (`wt remove --force`, no cleanliness check). Either way: removal job in a background tab → receipt → close the worktree's session only if the directory is gone, then drop its name, binding and Ice Box entry. Cancelling during a check never starts a deletion (`removalChecks`).

**Agent status.** `cx.agents:list()` costs 7–20 ms (it returns every agent's last reply), too much for each draw, so `agentBlocks` builds the list from the pane list (`kind == "agent"`, 0.1 ms) and a per-pane state kept by the `agent_state` hook. It reads the full list (`listAgents`) only for an agent block no event has covered yet (one open before a reload); the tick rereads it every 30 s in a callback of its own, not a draw, to catch a missed event. A pane the list doesn't report counts as no agent. `onAgentChange` reads it once per state change for the last reply it quotes. `agentActivity` maps each state: `waiting_input` → waiting, `working` → working, otherwise the pane's `agents-finished` mark (done or failed). An `agent_finished` event with result `done` or `failed` sets that mark unless the agent's tab is shown; `agent_state` back to working or waiting clears it, and `markSeen` (after every `follow`) clears marks whose tab is shown or whose pane is gone. For agent CLIs in plain terminals (`omp`, `pi`, `claude`, `codex`, `opencode`, `gemini`, `aider`, `amp`, `cursor-agent`, `crush`, `goose`) it uses the pane's `busy` flag (working only). Per session and tab the state that most needs you wins: waiting, then failed, then done, then working.

**Links.** Ticket and PR icons send `link=<url>`. `cx:open` puts a URL in a browser split beside the focused pane whatever `how` says, so `openLink` moves the new browser pane into a tab of its own.

**Update.** The tick calls `update.check` (cheap until due): every hour, 5 minutes after a failed fetch, and on ↻ when the last try is 5 minutes old, it fetches `https://raw.githubusercontent.com/mmnavarr/overseer/main/plugin.toml` with `tern.fetch` and keeps its version in kv `update-check`, redrawing when it changed. `model` passes `update = {latest, installed}` while `update.available()` (newer, by dotted numbers, than this copy's `plugin.toml`, and `how` known), and the view adds **Update** after the cog. Its click (`runUpdate`) runs `update.command()` in a terminal tab named Update Overseer: `"${TERN_EXE:-tern}" plugin install github.com/mmnavarr/overseer --force` for an installed copy, `git pull --ff-only` in the checkout for a linked one. A command that succeeds closes its tab and Tern reloads the plugin; a failed one leaves the tab open on its error. `update.started` records the version left in kv `update-started`, and the reloaded copy's first tick notifies **Overseer updated** (`update.finished`) and logs `update finished`.

**Toast buttons.** `cx:toast` can't carry a button; a `toast` node in a view can (`action`, `label`, Tern 0.9.14), and its click arrives as an ordinary `canvas_action`, split at `=` into `act` and `value` like any click. So `notify(cx, level, text, sub, button)` puts the toast in the Projects panel: it sets the in-memory `notice` (`{n, at, text, sub, tone, action, label}`) and redraws; `model` passes it on for `NOTICE_KEEP_S` (6 s, past the toast's own 5.2 s) and the view draws it under key `notice<n>`, so each is a new toast. When the panel isn't in the shown tab, `notify` falls back to `cx:toast` with the button's `hint` appended to `sub`. Buttons: **Open** on Worktree created (`open-branch=<branch>:<project id>`; `openBranch` finds the path, since the job only knows the branch; none for ticket worktrees, which open themselves), **Answer** on Needs you and **Show** on a failed creation or deletion (`tab=<pane>`, the setup tab; none when the helper's tab is gone), **Close session** when a deletion left its session open (`close-session=<path>`), and **Undo** on Project removed (`restore-project=<id>`, from `removedProjects`, in memory, back at its old position).

**Remove project.** Drops the project from `projects` and its in-memory cache; refuses while a creation or deletion runs for it. `worktree-names`, `icebox` and `sessions` stay, so adding the repository again brings them back.

**Ticket links.** `ticketOf` takes the first uppercase `ABC-123` in the branch (`%f[%w](%u[%u%d]*%-%d+)%f[%W]`), so `chore/stage-1` doesn't count. The workspace is `project.linear`, else the slug from `linear auth whoami` (looked up once; ↻ retries a failure). URL: `https://linear.app/<workspace>/issue/<id>`.

**Visualize PR.** `wt.pull_request_meta` (`gh pr view --json …`) and `wt.pull_request_diff` (`gh pr diff > file`) write the PR into a temp dir under plugin data. Then `omp -p --no-session --no-extensions --no-skills --no-title --tools=read,grep,glob "<prompt>"` runs in the worktree with a 10-minute timeout. Its stdout from the first Markdown heading becomes the canvas. The read-only guarantee is the tool allow-list. Keep it that way: never add shell, edit or write tools, and never let it call `gh`.

**Carly.** `tern.carly.export("ticket_worktree", …)` validates the id, resolves the project (argument by name or path, else the current session's project), validates the branch and starts creation. It replies once creation *starts* (setup can outlast Carly's 120 s limit). `tern.carly.context` tells Carly the registered project names.

## Behavior reference

What the user sees, precisely. README.md summarizes this; when behavior changes, update both.

### The panel

1. **Show Projects:** <kbd>⌘</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>P</kbd>, or **Show or hide Projects** in the command palette. Press it again while the panel has focus to hide it.
2. **Add a repo:** **+** in the panel's header opens the folder picker. The cog beside **Projects** opens Settings. When a newer Overseer is out, **Update** beside the cog installs it in a terminal tab; a notification says so once it loads.
3. **Open a worktree:** click its row. Its session opens, and the panel comes with it.
4. **New worktree:** **+** next to a project opens the New worktree page in a tab of its own. Pick **New branch** (from the project's base branch; the default) or **Existing branch**, type a branch name and, if you like, a display name; **Create worktree** (or ↵) takes you back where you were. The row appears straight away as **Creating** and becomes a normal row when setup is done. **Cancel** or Esc closes the page.
   - **New branch** refuses a name that's already a branch here or on a remote (Worktrunk would only warn and make an unrelated branch of that name from the base).
   - **Existing branch** takes a local branch that has no worktree yet, or a branch on exactly one remote, which Worktrunk checks out as a local branch tracking it. Overseer never fetches, so a branch pushed since your last fetch isn't found until you fetch.
5. **Everything else is a right-click away** (see [the menus](#the-menus)).

The panel stays on the left of whichever tab you're looking at, across every session, and keeps the width you give it. Each project is a local Git repository, each worktree is a row, and the worktree's open tabs are listed under it. Click a tab row to jump to that tab; hover a worktree row for its branch, path, line counts, ahead/behind and PR.

| You see | It means |
|---|---|
| ● green | A session is open |
| ● pulsing green · amber · red | An agent is working · setup is creating the worktree · it's being deleted |
| ? in an amber circle | An agent is waiting for your answer |
| ✓ in a green circle · ! in a red one | An agent finished · failed while you were elsewhere (clears when you open its tab) |
| ○ hollow | No session yet; click to open one |
| **✱** amber | Uncommitted changes |
| **Conflicts** | A merge or rebase is stuck |
| **Creating** | Setup is running; the row says how long and which step |
| **Needs you?** | Setup is asking a question, or has printed nothing for a minute; click to see it |
| **▾ 3** | Three sub-worktrees; click to fold them |
| **2 new** | Overseer messages for this worktree's agent since you last looked |
| **Worktree gone** | Removed outside Overseer; its session is still open |
| Linear logo · PR icon | The ticket the branch names (`feat/ENG-123-…`) · the PR's state |
| 🧊 | Parked in the Ice Box |
| **Done** · **Failed** on a tab | That tab's agent turn ended while you were elsewhere |
| **Overseer** on a tab | The session Overseer's [coordination](#coordination) messages go to (coordination on) |

Tab names leave out what the row already says: a GitHub pull request tab reads `#123 <title>`, without its author and repository. Hover a tab for its full name.

### The menus

| On a worktree | |
|---|---|
| **Visualize PR** | A reviewer's outline of the branch's pull request ([below](#visualize-a-pr)) |
| **Rename…** | Changes the row's label in a prompt; the branch stays as it is. Blank goes back to the branch name |
| **Create sub-worktree…** | The New worktree page for a worktree on a new branch from the project's base branch, or on an existing branch, nested under this one. Not on the primary checkout or on a sub-worktree |
| **Add to Ice Box** | Parks the worktree at the bottom; 🧊 in the header shows or hides parked ones |
| **Move under…** · **Make top-level** | Makes it a [sub-worktree](#sub-worktrees) of another, or undoes that |
| **Close session** | Stops its programs and closes its tabs at once; the files stay |
| **Delete worktree** | Removes a clean worktree at once. With uncommitted or untracked changes it first lists them, like `git status --short`, and asks you to **Force delete**. Branches are always kept, and the session closes once the directory is gone. A worktree with sub-worktrees asks whether they go too. |

| On a project | |
|---|---|
| **Project settings…** | Opens Settings: the project's base branch (where new worktrees start from), Linear workspace (where ticket links point) and agent coordination |
| **Remove project…** | Stops showing it. The repository, worktrees and sessions stay, and adding it again brings back its names and Ice Box. **Undo** on its notification puts it back right away. |

On a tab, **Make overseer session** picks which of a worktree's agents gets Overseer's messages.

A worktree removed outside Overseer (`wt remove`, `wt merge`, `git worktree remove`) shows as **Worktree gone** while its session is still open, so you can read what its agent last said. Its menu offers only **Close session**.

### Start work from a ticket

Ask Tern's assistant, Carly:

> Create an overseer worktree for ENG-123

Overseer creates `feature/ENG-123` from the project's base branch and opens its session. Then it starts omp with:

> *Please read ticket ENG-123 to understand your task and ask any questions you have before we start*

The project is the one you're in, or name it: *"…for ENG-123 in api"*. If the branch already exists, Carly tells you instead.

### Sub-worktrees

A task's worktree can own the worktrees of its sub-tasks. When an agent splits a job into one branch per fix, the fixes sit under the task instead of scattering through the list:

```text
● Space/Website Fixxer  ▾ 3
  feature/space-website-lurker
  │ ○ fix/website-coingecko-caps
  │ ○ fix/website-drain-on-term ✱
  │ ○ fix/website-logging-levels
```

- **Agents make them.** With the [omp integration](#omp-integration), an agent in a task's worktree creates the worktrees of its sub-tasks as sub-worktrees, and can hand each one a brief so a fresh agent starts on it there. Work started from the primary checkout, or unrelated to the task, gets an ordinary top-level worktree.
- **You make them** with **Create sub-worktree…** on a worktree's menu: the same page as **+**, and the new worktree lands under it.
- **You arrange them** with **Move under…** and **Make top-level**.
- **Each is a full worktree**, with its own session, menu, PR and ticket. Nesting is one level deep.
- **Fold them** with the `▾ N` badge. Folded, it takes the color of the sub-worktree agent that most needs you; the worktree you're in always shows.
- **Deleting the owner asks.** **Delete only this** moves its sub-worktrees to the top level; **Delete all** also removes the ones without uncommitted changes and keeps the rest. Parking the owner in the Ice Box parks them too.

The hierarchy lives in Git config (Worktrunk's per-branch `overseer-parent` variable), so `wt`, agents and every Overseer install see the same tree. Branches stay independent: nesting groups the panel, not Git history.

### Coordination

Off until you turn it on, per repository: **Turn on agent coordination…** on the project's right-click menu (with a confirmation card), **Turn off agent coordination** to stop. Once on, the agents of a task and its sub-worktrees stay aware of each other, whichever side is doing the work:

- **Overseer wakes the task's agent** when a sub-worktree's agent is waiting for an answer, its turn failed, or it finished with a pull request open. A sub-worktree built on its parent's branch hears when that branch moves, so it can rebase. These reach any agent CLI Tern runs.
- **Before each prompt**, an omp agent hears what changed in its family since it last looked: new commits, files both branches touch, and what the others are working on or just finished.
- **omp agents message each other** with the `overseer_family` tool; Overseer delivers the message, and an answer comes back later as a new message.
- **The panel shows it:** **N new** counts Overseer's messages since you last opened that session, and a sub-worktree's row says when its agent last checked in.

Messages inform; they never act. Overseer decides when to send its own from Tern's agent states and Git, never from what an agent wrote, and sends a session at most one a minute (agents' messages go at once). Each worktree has one **overseer session** that receives them: its only agent, or the one you pick with **Make overseer session**. Nothing extra to install: the messages travel through Tern and files in the repository's Git directory.

### Visualize a PR

Overseer fetches the PR's metadata and full diff from GitHub, then has omp write an outline following HumanLayer's [visual-pr](https://github.com/humanlayer/skills) skill: why the change exists, what to watch for, and Mermaid diagrams, file-tree diffs and pseudocode. The local checkout only adds surrounding context. It takes a minute or two, and unchanged PRs reopen instantly from a cache.

It's **read-only by construction**: omp runs with only read/grep/glob tools and no shell, so it can't push, comment or edit anything.

### omp integration

With [omp](https://omp.sh) installed, there's nothing to set up: each time Overseer loads, it links its omp half into omp. That half is `omp/`, an omp plugin package named `overseer-omp`:

| Piece | What it does |
|---|---|
| `overseer-subworktree` skill | Teaches agents to create worktrees the right way: sub-worktrees for their task's sub-tasks, top-level worktrees otherwise |
| `overseer-worktrees` rule | Stops an agent that types a raw `git worktree add` or `wt switch --create` and points it at the skill |
| `overseer-rails` extension | Keeps the agents of a worktree family informed, when [coordination](#coordination) is on |

They load in omp sessions started after the link (`/new` restarts one); `omp plugin list` shows it. `omp plugin disable overseer-omp` turns them off, and Overseer leaves it that way. Overseer also removes the symlinks into `~/.omp/agent` that earlier versions had you make, so omp doesn't load them twice. Using omp without Tern? Link it yourself: `omp plugin link "$PWD/omp"`.

### Architecture

- **Worktrunk owns the worktrees.** Overseer calls `wt` and never passes `--yes` or `--no-hooks`, and passes `--force` only after you confirm the listed changes. Your hooks and approval prompts run in a background tab you can open from the row.
- **Tern owns the sessions.** Overseer remembers which session belongs to which worktree and switches between them.
- **Git config holds the hierarchy.** Sub-worktree links (`overseer-parent`) and each worktree's overseer session (`overseer-lead`) are Worktrunk branch variables that agents read too.
- **The panel follows you.** Tern plugins can't pin a sidebar to the window, so Overseer keeps one Projects panel per window and moves it into whichever tab you're on.
- **Everything else is a read.** PR badges, ticket links, agent status and change counts come from `gh`, `linear`, `git` and Tern's own agent state.

### Safety

- Creation never fetches, pulls, or checks out anything in your primary checkout.
- Deletion rechecks the repository and branch right before it runs, and cleanliness too unless you confirmed a force delete. It never deletes a branch. The primary checkout can't be deleted.
- Ignored files are removed with a deleted worktree's directory, so copy out anything you need first.
- Branch names and paths are passed as arguments, never as shell text.
- What agents say to each other is information only. Nothing Overseer does (creating, deleting, merging, approving) is triggered by an agent's message.

### Troubleshooting

- **A new worktree seems stuck.** Its row says what setup is doing. **Needs you?** means setup is asking a question, often a Worktrunk hook approval, or has printed nothing for a minute. Click the row, or **Answer** on its notification, to open its setup tab.
- **What did Overseer just do?** **Show Overseer's operation log** in the command palette shows every creation, deletion, brief and coordination message, newest first, with when it happened, where, how long it took and how it ended; entries that went wrong have a red dot, and hovering a row shows the full detail. The full file is `ops.log` in Overseer's data directory, and the same entries are in Tern's log (`~/Library/Logs/Tern/tern.log`; search for `Overseer:`).
- **The panel froze for a few seconds.** Tern pauses a plugin's timers when one of its callbacks runs too long (5 s, doubling on repeats up to 5 minutes). Overseer logs `Tern paused its … hook`; meanwhile your clicks, commands, the New worktree page and Rename still work, the panel still follows you between tabs, creations and deletions still finish, and the rest catches up when the pause ends. A draw that comes close logs `slow draw` with where its time went.
- **New worktrees or PR changes don't show up.** Look in the operation log for `refresh` entries: `stale` (no listing for 3 minutes, and why: `wt list` unanswered, failing, or not started), `failed`/`recovered` (a listing, link read or GitHub PR lookup that errors), `lost` (a result that never came back, started again after 30 s). A `tick late` entry means Overseer's timers didn't run for that long while the Mac was awake. None of these means the refresh ran normally.
- **Agents aren't coordinating.** Check that coordination is on for the repository (`git config --get overseer.coordination` prints `true`; the project's menu shows **Turn off agent coordination**), that `omp plugin list` shows `overseer-omp`, and that the agents' sessions started after Overseer linked it (`/new` restarts one). With several agents in a worktree, pick one with **Make overseer session**. Agents' messages that never arrived show in the operation log as `message` entries (`undeliverable`, `unreadable`), deliveries as `relay`.

## Developing

To work on Overseer, use a checkout linked into Tern instead of the installed copy (Tern then reloads the plugin whenever a file in the checkout changes):

```sh
tern plugin remove overseer   # if it was installed with `tern plugin install`
git clone https://github.com/mmnavarr/overseer.git && cd overseer
tern plugin link "$PWD"
```

Run the helper's tests (they use temporary repos, config and approvals):

```sh
python3 -B tests/test_worktree_operation.py -v
python3 -B tests/test_subworktree.py -v
bash -n worktree-operation.sh omp/skills/overseer-subworktree/overseer-subworktree
```

Check the worktree rule fires on the commands it should, and only those:

```sh
omp ttsr test --rule omp/rules/overseer-worktrees.md --source tool --tool bash 'wt switch --create fix/x --no-cd'
omp ttsr test --rule omp/rules/overseer-worktrees.md --source tool --tool bash 'wt switch fix/existing'
```

The extension's pure helpers (`familyFromConfig`, `parseNotes`, `latestNote`, `compactNotes`, `writeMailbox`, `promptNote`, …) are exported, so `bun` can import them for a quick check; end to end, turn coordination on in a test repository (`git config overseer.coordination true`), start an omp session in a Tern pane with `omp -e omp/overseer-rails/index.ts`, and watch `<git-common-dir>/overseer/` and the operation log.

Smoke-test UI changes in an **isolated Tern window** so your real sessions are untouched:

```sh
D=$(mktemp -d); mkdir -p "$D/config"
TERN_CONFIG_DIR="$D/config" tern plugin link "$PWD"
TERN_CONFIG_DIR="$D/config" TERN_DAEMON_SOCKET="$D/daemon.sock" \
  /Applications/Tern.app/Contents/MacOS/tern --control "$D/desktop.sock"
```

Drive it with `tern ctl --control "$D/desktop.sock" …`:

- `ready`, `palette Projects`, `key Enter`, `click X Y [right]`, `shot NAME` (screenshots land in `target/shots/tern/live/`)
- `tree "[data-role=overseer\.worktreeRow]"` returns node rects and text
- `a11y` returns menu items and their bounds
- `carly lua "…"` runs Lua with a window `cx`, and `state` shows the result under `.carly.last_tool`

Seed projects by writing `$D/config/plugin-data/overseer/kv.json` before launch.

Other conventions:

- Editing any file in a linked plugin reloads it in every running Tern. Develop in a separate checkout linked into an isolated window so your everyday Overseer isn't reloaded mid-edit.
- After changing an icon, run `python3 icons/generate-css.py`.
- Bump `version` in `plugin.toml` for user-visible changes and add an entry to [`CHANGELOG.md`](CHANGELOG.md). A change to how the panel or its state is structured is a major version.
- Keep external commands in `worktrunk.luau` as argv arrays. Shell is only used where a redirect is needed, with arguments as `$0…$n`.

## Known limitations

- macOS only (folder picker, paths, Tern desktop).
- Visualize PR fails on PRs whose diff exceeds GitHub's 20,000-line API limit (`gh pr diff` returns HTTP 406). The tab shows the error.
- The panel moves into each tab you switch to, so every switch animates briefly and resizes the terminals in both tabs (full-screen programs redraw). In a tab split top-and-bottom it sits beside the top half.
- A plugin reload during a Visualize PR run, including the one Tern does when you edit a file in a linked plugin, ends the run and leaves its tab on the waiting message. Run it again.
- Multiple Tern windows work but haven't been exhaustively tested together.
- Coordination runs on one machine: the mailbox and notes live in the repository's Git directory. Overseer's wake-ups and briefs reach any agent CLI; the family summary, notes and agent-to-agent messages need omp.
- Agents' messages don't wait for an answer; a reply arrives later as a new message.
- Only a worktree's overseer session is wired to its parent: another agent in the same sub-worktree that gets stuck doesn't wake the parent, though an omp one's notes still reach the family.
- **Needs you?** is read from the setup tab's output, so a setup step that prints nothing for a minute trips it too.
- The worktree rule fires at most once per omp session; after that the agent relies on the skill it read.
