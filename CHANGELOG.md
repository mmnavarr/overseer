# Changelog

## 2.4.0 (2026-11-06)

- **Agent coordination is opt-in, per repository.** Turn it on with **Turn on agent coordination…** on a project's right-click menu, and off from the same place. Off, Overseer sends no wake-ups or relays, and hides **Brief sub-worktrees…**, **Make overseer session**, **N new**, check-ins and the **overseer** badge; omp agents get no family summary. Sub-worktrees themselves work either way. Repositories that already used coordination keep it on when you update; every other repository starts off.
- **No more pi-intercom or Bun.** Overseer hands its messages to agents through Tern itself, so wake-ups and briefs now reach any agent CLI, not just omp. omp agents' `overseer_family` messages go through a mailbox in the repository's Git directory, which Overseer delivers, and the notes board is a file beside it. The one thing lost: an agent can no longer block waiting for another's answer; replies arrive as new messages. You can uninstall pi-intercom if nothing else uses it.

## 2.3.3 (2026-11-06)

- **Fixed: coordination with Worktrunk 0.81.** Worktrunk 0.81 moved a worktree's commit to `head` and its ahead/behind counts to `default_branch` and `upstream` in `wt list`'s JSON. Overseer only read the old names, so on 0.81 sub-worktrees were never told their parent's branch moved, a task's agent could miss a sub-worktree finishing with new commits on its pull request, and row tooltips lost their ahead/behind counts. Overseer now reads both, and is tested with Worktrunk 0.40 and 0.81 ([#4](https://github.com/mmnavarr/overseer/issues/4)).
- **Install with one command.** `tern plugin install github.com/mmnavarr/overseer`, with no clone; `--force` updates it. Working on Overseer itself still uses a linked checkout (see CONTRIBUTING.md).
- The README is shorter and leads with an animated tour; the full reference moved to AGENTS.md, and there are now contributing notes and issue forms.

## 2.3.2 (2026-11-06)

- **⌘T in a worktree's session follows Settings › New tabs and splits open.** With Agent chosen, the new tab runs your agent command in the worktree, as ⌘T does everywhere else; before, it always opened a shell.

## 2.3.1 (2026-11-05)

- **Worktree creations and deletions no longer get stuck.** Overseer's 750 ms tick, which notices a finished creation or deletion, could stop for an hour without any error, leaving rows on **creating** or **deleting** long after Worktrunk was done. Overseer now restarts the tick whenever it's more than 5 s late, checked from every click, tab, focus and agent event and from a second clock that doesn't depend on Tern's timers. Each restart is recorded in the operation log (`tick restarted`).
- **The Projects panel keeps following you.** When Tern paused Overseer's timers after a slow draw (5 s, doubling up to minutes on repeats), the panel stayed behind in its old tab and only the shortcut brought it back. It now keeps moving into the tab you're on during a pause, and finished jobs are wrapped up then too.
- **Fewer pauses to begin with.** The panel no longer redraws on every tick (only on changes, and every 5 s for its clocks), and a draw reads the window's panes, tabs and agents once instead of three times each. A draw that still comes close to Tern's budget logs where its time went.

## 2.3.0 (2026-11-04)

Requires Tern 0.9.9.

- **A new worktree shows while it's being made.** Its row appears as soon as setup starts, saying **creating**, how long it has run and the step it's on, instead of only when everything is done. If setup asks a question, such as a Worktrunk hook approval waiting in its background tab, or prints nothing for a minute, the row says **needs you?** and a notification tells you once; clicking the row opens the setup tab.
- **An operation log.** Overseer records each worktree creation and deletion, brief, relay and worktree removed outside it (when, how long, how it ended, and a setup's first warning) in `ops.log` in its data directory, and in Tern's log. **Show Overseer's operation log** in the command palette opens it. Nothing about it shows in the panel.
- **omp gets Overseer's skill, rule and extension on its own.** `omp/` is now an omp plugin package, `overseer-omp`, holding the `overseer-subworktree` skill, the `overseer-worktrees` rule and the `overseer-rails` extension. Each time Overseer loads with omp installed, it links that package into omp (`omp plugin link`), re-pointing an older install's link and keeping it disabled if you disabled it, then removes the symlinks into `~/.omp/agent` the README used to ask for. Installing Overseer is all it takes; the skill's script moved to `~/.omp/plugins/node_modules/overseer-omp/skills/overseer-subworktree/overseer-subworktree`.
- **Every worktree an agent creates lands in the right place.** The `overseer-subworktree` skill now governs all worktree creation: work for the current worktree's task becomes its sub-worktree, while work started in the primary checkout, or unrelated work, gets a top-level worktree (the script refuses to nest under the primary checkout). A new omp rule, `overseer-worktrees`, stops an agent that writes `git worktree add`, `wt switch --create`, `omp worktree add` or the `ce-worktree`/`git-worktree` scripts before the command runs, and points it at the skill.
- **Coordination between a worktree's sessions and its sub-worktrees'.** With the new `overseer-rails` omp extension and pi-intercom, each session hears what changed in its family before each prompt (new commits, files both branches edit, the others' latest notes), and agents message each other with the `overseer_family` tool. Overseer wakes the parent when a sub-worktree's session is waiting, fails, or finishes with a pull request, and tells sub-worktrees built on their parent's branch when it moves. **Brief sub-worktrees…** sends them your message; `overseer-subworktree --brief` starts a sub-worktree's session on a brief. Each worktree's **overseer** session gets the messages (**Make overseer session** picks one when there are several), and rows show **N new** messages and when a sub-worktree last checked in.
- **Sub-worktrees.** A worktree can own others, shown nested under its row like a file tree, with a line from its dot to each one, and a `▾ N` badge that folds them (folded, it takes the color of the sub-worktree agent that most needs you). The active worktree keeps its tinted outline but no longer gets Tern's accent bar, which stood among the tree lines. omp agents create them with the new `overseer-subworktree` skill, which records the worktree it runs in as the owner; **Move under…** and **Make top-level** adopt or release existing ones. Deleting an owner asks whether its sub-worktrees go too: **Delete all** removes the clean ones and keeps any with uncommitted changes. The link lives in Worktrunk's per-branch `overseer-parent` variable, so `wt` and agents see it.
- **The panel looks like Tern again.** Tern 0.9.9 gives HTML buttons its own chip look, which turned the project toggle and the header's **+**, ↻ and 🧊 into tall boxed chips. Every action is now Tern's own button: the header's Add project, Refresh and Ice Box toggle sit in one toolbar (Refresh spins while it works, the Ice Box toggle shows when it's on), the project's **+** and the ⓘ are quiet icon buttons, and the project name folds with a chevron instead of a boxed `▾`. Badges (Primary, conflicts, deleting, worktree gone, the worktree count) are Tern's badges.
- **People's text in the UI face.** The panel and the forms draw labels, names and tab titles in Tern's sans face, as Tern's own views do; branches, paths and the change list stay monospaced.
- **Right-click menus have icons and sections.** Worktree menus group Visualize PR, Rename… and the Ice Box apart from Close session and a red **Delete worktree**; project menus put Remove project… below the settings.
- **Confirmations are Tern cards.** Force delete asks in a red card with a danger button, and its file list colors status codes, paths and line counts with the theme. Remove project asks in an accent card. The confirm button spins while the worktree is being checked.
- **Loading, empty and error states are designed.** Loading worktrees shimmers, a project with no worktrees offers Refresh, a failed listing shows its message in an error card with Retry, and a first run shows one Add your first project button.
- **The form uses Tern's fields.** Labels, the required mark and validation errors sit on each field; Back and Submit show their **esc** and **⏎** keys.
- **Tab states can't be squeezed out.** A long tab name used to crush its **done** or **failed** label; the name now truncates and the state shows as a green **done** or red **failed** badge.
- **Shorter tab names.** A GitHub pull request tab reads `#2796 feat(webapp): …` instead of `feat(webapp): … by user · Pull Request #2796 · owner/repo`, other GitHub tabs drop their ` · owner/repo`, and omp titles drop the ` · #123` the row's PR icon already shows. The full name is in the tooltip.
- **Delete worktree deletes clean worktrees straight away.** A worktree with uncommitted or untracked changes now lists them (like `git status --short`, with line counts) instead of refusing, and **Force delete** removes the worktree with them. Branches are still always kept.
- **Close session closes straight away**, without asking first. The worktree's files stay either way.
- **Sessions of worktrees removed outside Overseer are flagged.** Removing a worktree with `wt remove`, `wt merge` or `git worktree remove` (yourself or through an agent) used to leave its session open and its records behind for good. On the next refresh a worktree that is neither listed nor on disk now shows as **worktree gone** under its project if its session is still open: clicking it still shows the session, and **Close session** on its menu closes it. Its display name and Ice Box entry are dropped, and so is the session record once the session is closed.
- **Fixed:** Projects could fail with `Cannot read Worktrunk JSON: Worktrunk could not determine working-tree status for …/fallow-audit-base-…`. `fallow audit` briefly registers a worktree in the temp directory while it checks out its comparison base; Overseer now leaves those out of the worktree list.

## 2.2.0 (2026-10-28)

Requires Tern 0.9.6.

- **Agents that need you stand out.** A worktree whose agent is asking you something shows a yellow **?** instead of a dot. One whose agent finished while you were looking elsewhere shows a green **✔**, and one whose turn failed shows a red **!**; both clear once you open the agent's tab. Every status mark, dots included, now fills the same 12 px square so names stay aligned. On tab rows a yellow dot marks the waiting agent, and finished turns say **done** or **failed**. The marks update the moment an agent's state changes instead of on the next refresh.
- **Ticket and pull request links open in a tab of their own** instead of splitting the pane you're in.
- **Remove project** on a project's right-click menu stops showing it in Projects. The repository, its worktrees and open sessions stay, and adding it again brings back its display names and Ice Box.
- **No more self-reloads.** Tern 0.9.6 pauses a plugin hook for a few seconds after an overrun instead of switching it off until reload, and only counts the plugin's own Lua against the budget. Overseer's watchdog and self-reload are gone; pauses are logged (`Overseer: Tern paused its <hook> hook …`) and the panel catches up when the hook resumes.
- Processes start straight away instead of one per timer callback.

## 2.1.0 (2026-10-27)

- **Overseer recovers on its own when Tern switches part of it off.** Tern turns off any part of a plugin whose callback runs past 50 ms, until the plugin reloads, and a busy Tern makes that happen several times a day however little the callback does. Projects then stopped refreshing, forms stayed on "Returning to Projects…" or "Working…", and finished worktrees went unnoticed until you reloaded the plugin. Overseer now notices when its timers or process results have stopped and reloads itself (at most every 30 seconds), logging which callback was cut short. Clicks, commands and tab changes now only queue their work, so the click handler, which Overseer can't watch, stays too small to overrun.
- **Fixed:** a form could stay on "Returning to Projects…" or "Working…" forever when the step that opened or finished it was cut short. A form that can no longer answer now puts Projects back, a finished form keeps its record until Projects is back, and a new worktree is never launched twice when its form finishes again after a reload.
- **Fixed:** a finished worktree job cut short at the wrong moment could be reported as failed. A job now leaves the job list before its receipt is deleted.
- Callbacks that take 30 ms or more are logged (`Overseer: <step> took N ms of its 50 ms budget`).

## 2.0.1 (2026-10-13)

- **Fixed:** Projects could freeze (stop refreshing, never finish a new worktree) or answer every click with `Nothing handles "…" here` until the plugin reloaded. While Tern was busy, such as during a worktree's dependency install, starting the background commands for a refresh could take longer than the 50 ms Tern allows a plugin callback, and Tern then switched that part of Overseer off. Each command now starts in a callback of its own.

## 2.0.0 (2026-10-09)

The Projects panel is now one panel per window that follows you, instead of one panel per worktree session.

### Changed

- **The panel follows you.** It sits on the left of whichever tab you're looking at, in any session, and comes along when you switch tabs, open a tab or open a worktree. Before, each worktree session had its own panel beside its first terminal, and a new tab started without one.
- **Your width travels with it.** Drag the panel's edge once; every tab uses that width, and it's remembered across restarts. It starts at 30% of the tab.
- **Forms follow too.** New worktree, Rename, Change base branch and Set Linear workspace still open in the panel's place, and now move with it.
- **The shortcut shows or hides.** <kbd>⌘</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>P</kbd> shows and focuses the panel, or hides it when it already has focus. The command is now **Show or hide Projects**. A hidden panel stays hidden in new tabs until you show it again.
- **Opening a worktree no longer opens a panel in its session.** The one panel moves there instead.
- **Closing the last terminal in a tab** closes the tab as Tern normally does; the panel moves to the tab shown next.
- **Close session** (from Overseer) moves the panel out of the session first. If Tern closes the session holding the panel, Overseer reopens the panel in the next tab you see, unless you had closed it yourself.

### Upgrading

Nothing to do. The first time 2.0 runs, it keeps one of the panels you already had open and closes the others.

### Trade-offs

Tern plugins can't add a window-level sidebar, so the panel is a regular pane that moves between tabs. Each switch briefly animates, and resizes the terminals in the tab you leave and the tab you arrive in. In a tab split top-and-bottom, the panel sits beside the top half.

## 1.10.2 (2026-10-08)

- Slightly smaller type across the panel and forms, a smaller **Projects** heading, and no divider under the header.

## 1.10.1 (2026-10-08)

- First public release: projects and Worktrunk worktrees with a Tern session per worktree, agent activity, pull request and Linear ticket badges, background creation and deletion, Ice Box, ticket worktrees from Carly, and Visualize PR.
- Ticket links use Linear's official logo mark.
