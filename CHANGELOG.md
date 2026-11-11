# Changelog

What changed in each Overseer release, newest first. Settings › Help & Diagnostics › Changelog shows the same.

## 2.4.4 (2026-11-11)

### Changed

- An agent that finished while you were elsewhere shows a green check alone, no longer a white check in a green circle that looked like an open session's dot
- Settings is titled Overseer Settings

### Fixed

- Tab dots are round: they were drawn slightly taller than wide
- A working agent's tab dot glows instead of a ring that sat off its centre
- A busy terminal's tab dot is the small amber dot instead of a full-size one

## 2.4.3 (2026-11-11)

Requires Tern 0.9.15

### Added

- **Settings**: the cog in the Projects header, or Overseer settings in the palette, opens a tab with the Ice Box switch, each project's base branch, Linear workspace and agent coordination, and your GitHub and Linear sign-ins with Install and Connect buttons
- **Changelog** in Settings › Help & Diagnostics
- Buttons on Overseer's notifications while Projects is showing: Open on a created worktree, Answer on a setup that may need you, Show on a failed creation or deletion, Close session when a deletion left its session open, and Undo on a removed project
- The Ice Box can be turned off in Settings › General
- Diagnostics to copy for a bug report in Settings › Help & Diagnostics

### Changed

- The operation log opens over the tab you're in, as a table, newest first, instead of in `less` in a new tab
- The Projects panel redraws in about 4 ms, down from as much as 40 ms while agents were busy

## 2.4.2 (2026-11-09)

### Fixed

- The Projects panel keeps the width you gave it in tabs that already have splits, instead of arriving at the wrong width and forgetting changes; thanks to [@cxxzsh](https://github.com/cxxzsh) ([#5](https://github.com/mmnavarr/overseer/pull/5))

## 2.4.1 (2026-11-06)

### Changed

- Waiting, finished and failed agents show as filled circles with a `?`, check or `!`, sized and centred like the other dots
- Deleting pulses red and creating pulses amber, like a working agent's green pulse, and the Deleting badge is red
- Labels start with a capital: Done, Failed, Overseer, Creating, Needs you?, Deleting, Checking, Conflicts, Worktree gone, Running, No pane
- The primary checkout's row shows just its folder, since its Primary badge already says what it is
- Confirmation cards ask their question as the title, and the agent coordination card lists what turning it on does
- The README tour, screenshots and social card show the new marks

## 2.4.0 (2026-11-06)

### Changed

- **Agent coordination is opt-in per repository**: turn it on or off from the project's right-click menu. Off, Overseer sends no wake-ups or relays and hides Brief sub-worktrees…, Make overseer session, N new, check-ins and the Overseer badge. Repositories that already used it stay on
- **No more pi-intercom or Bun**: Overseer hands its messages to agents through Tern, so wake-ups and briefs reach any agent CLI, and omp agents' messages go through a mailbox in the repository's Git directory
- An agent can no longer wait for another agent's answer; replies arrive as new messages
- pi-intercom can be uninstalled if nothing else uses it

## 2.3.3 (2026-11-06)

### Added

- **One-line install**: `tern plugin install github.com/mmnavarr/overseer`, no clone; `--force` updates it

### Changed

- A shorter README led by an animated tour; the full reference moved to AGENTS.md, with contributing notes and issue forms

### Fixed

- Coordination with Worktrunk 0.81, which renamed the fields for a worktree's commit and ahead/behind counts: parent-moved notices, finished-with-PR relays and tooltip counts work again ([#4](https://github.com/mmnavarr/overseer/issues/4))

## 2.3.2 (2026-11-06)

### Fixed

- ⌘T in a worktree's session follows Settings › New tabs and splits open: with Agent chosen it starts your agent in the worktree instead of a shell; thanks to [@sinkr](https://github.com/sinkr) ([#2](https://github.com/mmnavarr/overseer/pull/2))

## 2.3.1 (2026-11-05)

### Fixed

- Worktree creations and deletions no longer get stuck on Creating or Deleting: Overseer restarts its tick when it's more than 5 s late and logs `tick restarted`
- The Projects panel keeps following you while Tern has paused Overseer's timers, and finished jobs wrap up meanwhile
- Fewer pauses: the panel redraws only on changes and every 5 s, and reads the window's panes, tabs and agents once per draw; a draw that comes close to Tern's limit logs where its time went

## 2.3.0 (2026-11-04)

Requires Tern 0.9.9

### Added

- **Sub-worktrees**: a worktree can own others, nested under its row with tree lines and a ▾ N badge that folds them. Agents create them with the overseer-subworktree skill; Move under… and Make top-level rearrange them, and deleting an owner asks about its sub-worktrees
- **Coordination** between a worktree's sessions and its sub-worktrees': family news before each prompt, the overseer_family tool for messages, wake-ups when a sub-worktree's agent waits, fails or opens a pull request, and Brief sub-worktrees…
- **Operation log**: every creation, deletion, brief and relay with when, how long and how it ended; Show Overseer's operation log in the palette
- A new worktree shows while it's made: Creating with its time and step, and Needs you? when setup asks something or goes quiet for a minute
- omp gets Overseer's skill, rule and extension by itself: Overseer links its `overseer-omp` package into omp each time it loads
- The `overseer-worktrees` omp rule points agents that type a raw worktree command at the skill
- Worktrees removed outside Overseer show as Worktree gone while their session is still open

### Changed

- The panel uses Tern's own buttons, badges, cards and fields, and Tern's sans face for names and labels
- Right-click menus have icons and sections
- Delete worktree deletes a clean worktree at once, and lists uncommitted changes before Force delete; branches are always kept
- Close session closes without asking
- Loading, empty and error states are designed, with Refresh and Retry
- Shorter tab names: a GitHub pull request tab reads `#123 title`
- Tab states show as Done and Failed badges that a long name can't squeeze out

### Fixed

- Projects no longer fails on the temporary worktrees `fallow audit` creates

## 2.2.0 (2026-10-28)

Requires Tern 0.9.6

### Added

- **Agents that need you stand out**: a yellow ? when one asks you something, and a green check or red ! when one finished or failed while you were elsewhere
- **Remove project** on a project's right-click menu; adding the repository again brings back its names and Ice Box

### Changed

- Ticket and pull request links open in a tab of their own
- Overseer no longer reloads itself: Tern 0.9.6 pauses an overrunning hook for a moment instead of switching it off
- Processes start at once instead of one per timer callback

## 2.1.0 (2026-10-27)

### Changed

- Overseer reloads itself, at most every 30 s, when Tern switches part of it off after a slow callback; clicks, commands and tab changes only queue their work
- Callbacks of 30 ms or more are logged

### Fixed

- Forms no longer hang on Returning to Projects… or Working…, and a new worktree is never launched twice
- A finished job cut short at the wrong moment is no longer reported as failed

## 2.0.1 (2026-10-13)

### Fixed

- Projects no longer freezes, or answers clicks with `Nothing handles "…" here`, while Tern is busy: each background command starts in a callback of its own

## 2.0.0 (2026-10-09)

### Changed

- **One Projects panel per window**, following you to whichever tab you're on, instead of one per worktree session
- The width you drag it to applies to every tab and is remembered; it starts at 30%
- Forms move with the panel
- ⌘⌥⇧P shows the panel, or hides it when it has focus; the command is now Show or hide Projects
- Closing a tab's last terminal closes the tab, and the panel moves to the next one
- Close session moves the panel out first; if Tern closes the panel's session, it reopens in the next tab you see
- Each tab switch animates briefly and resizes both tabs' terminals, and in a top-and-bottom split the panel sits beside the top half
- Nothing to do when upgrading: the first run keeps one of your open panels and closes the rest

## 1.10.2 (2026-10-08)

### Changed

- Slightly smaller type across the panel and forms, a smaller Projects heading, and no divider under the header

## 1.10.1 (2026-10-08)

### Added

- First public release: projects and Worktrunk worktrees with a Tern session per worktree, agent activity, pull request and Linear ticket badges, background creation and deletion, the Ice Box, ticket worktrees from Carly, and Visualize PR
- Ticket links use Linear's official logo mark
