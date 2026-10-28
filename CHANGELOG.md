# Changelog

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
