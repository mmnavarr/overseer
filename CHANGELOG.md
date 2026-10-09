# Changelog

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
