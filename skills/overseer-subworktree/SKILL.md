---
name: overseer-subworktree
description: Use when splitting work into separate branches/worktrees (sub-tasks, parallel fixes, one PR per fix) from inside an existing worktree, so Overseer nests them under it.
---

# Sub-worktrees

When the task you're on needs work in a separate branch (a fix that deserves
its own pull request, parallel sub-tasks), create that worktree with:

```sh
~/.omp/agent/skills/overseer-subworktree/overseer-subworktree <branch> [--base <ref>]
```

Run it from inside the worktree you're working in. That worktree becomes the
new one's parent, and Overseer's Projects panel shows the new worktree nested
under it. Don't call `wt switch --create` or `git worktree add` directly for
sub-tasks: those worktrees show up at the top level, unrelated to your task.

- `--base` defaults to the repository's default branch, like `wt switch --create`.
  Pass `--base <your branch>` only when the sub-task builds on your unmerged work.
- Worktrunk's hooks run as usual and may ask for approval.
- The last line of output is the new worktree's path; work there (`cd`, or a
  sub-agent with that working directory).
- Running it from a sub-worktree is fine: Overseer nests everything under the
  top-level worktree.
