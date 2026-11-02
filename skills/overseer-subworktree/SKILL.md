---
name: overseer-subworktree
description: Use when splitting work into separate branches/worktrees (sub-tasks, parallel fixes, one PR per fix) from inside an existing worktree, so Overseer nests them under it.
---

# Sub-worktrees

When the task you're on needs work in a separate branch (a fix that deserves
its own pull request, parallel sub-tasks), create that worktree with:

```sh
~/.omp/agent/skills/overseer-subworktree/overseer-subworktree <branch> [--base <ref>] [--brief -] <<'EOF'
<the brief>
EOF
```

Run it from inside the worktree you're working in. That worktree becomes the
new one's parent, and Overseer's Projects panel shows the new worktree nested
under it. Don't call `wt switch --create` or `git worktree add` directly for
sub-tasks: those worktrees show up at the top level, unrelated to your task.

- `--base` defaults to the repository's default branch, like `wt switch --create`.
  Pass `--base <your branch>` only when the sub-task builds on your unmerged work.
- Worktrunk's hooks run as usual and may ask for approval.
- The last line of output is the new worktree's path.
- Running it from a sub-worktree is fine: Overseer nests everything under the
  top-level worktree.

## Hand the sub-task to its own session

With `--brief -` (stdin) or `--brief <file>`, Overseer starts an omp session in
the new worktree with your brief as its first prompt, so the sub-task runs in
parallel while you keep going. That session knows nothing else, so write the
brief as a handover:

- the task and what "done" means (e.g. a pull request against which base);
- the context it needs: files, decisions already made, constraints;
- what to leave alone, especially work in your worktree;
- how to report: "when the PR is open, or if you're blocked, tell the parent
  with the overseer_family tool (to: parent)".

Without `--brief`, nothing starts; do the work yourself (`cd` there, or a
sub-agent with that working directory).

## Staying in touch

Sessions in the family see each other's news before each prompt (new commits,
files you both edit, their latest note). The `overseer_family` tool lists the
family with intercom addresses and messages them; use intercom `ask` with an
address when you need an answer before continuing. Overseer also tells the
parent when a sub-worktree's session is waiting, failed, or finished with a PR.
