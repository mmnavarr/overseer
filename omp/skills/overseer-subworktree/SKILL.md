---
name: overseer-subworktree
description: Use EVERY time you are about to create a git worktree or a new branch in its own directory (wt switch --create, git worktree add, omp worktree add, ce-worktree, git-worktree, parallel sub-tasks, one PR per fix). Decides whether it is a sub-worktree of the current worktree, which Tern's Overseer nests under it, or a top-level worktree, and creates it the right way.
---

# Creating worktrees: sub-worktree or top-level

Tern's Overseer shows worktrees as a hierarchy: a worktree that owns a task,
with the worktrees for that task's sub-tasks nested under it. That hierarchy
only exists if each worktree is created the right way, so decide first, then
use the matching command. This applies to every worktree you create, including
ones a workflow or another skill offers to make for you.

## 1. Decide

Find out where you are:

```sh
[ "$(git rev-parse --path-format=absolute --git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ] \
  && echo primary || echo "worktree: $(git branch --show-current)"
```

| You are in | The new worktree is for | Create |
| --- | --- | --- |
| a worktree (not the primary checkout) | part of the task this worktree exists for: a sub-task, a fix split out into its own PR, parallel work, a spike or follow-up for this task | **sub-worktree** |
| a worktree | something unrelated to this worktree's task, and the user asked for it | top-level |
| the primary checkout | anything | top-level |

When unsure in a worktree, it's a sub-worktree: work you start from a task's
worktree almost always serves that task. The primary checkout owns nothing;
it's the shared base, not a task.

## 2. Create

**Sub-worktree**, from inside the current worktree (any subdirectory works):

```sh
~/.omp/plugins/node_modules/overseer-omp/skills/overseer-subworktree/overseer-subworktree <branch> [--base <ref>] [--brief -] <<'EOF'
<the brief, when you pass --brief ->
EOF
```

The current worktree becomes its parent; Overseer nests the new one under it.
Running it from a sub-worktree is fine: Overseer nests everything under the
top-level owner, one level deep.

**Top-level**:

```sh
wt switch --create <branch> --no-cd [--base <ref>]
```

On Windows, Worktrunk is `git-wt` (`wt` is Windows Terminal): use `git-wt`
wherever this skill says `wt`. Run the sub-worktree script with Git Bash.

Never use `git worktree add`, `omp worktree add`, or the `ce-worktree` /
`git-worktree` scripts for either kind. They put worktrees outside Worktrunk's
layout and record no parent, so the worktree lands in the wrong place in
Overseer, or not in a family at all.

Either way:

- `--base` defaults to the repository's default branch. Pass `--base <your
  branch>` only when the new work builds on unmerged commits in your branch.
- Worktrunk's hooks run as usual and may ask for approval.
- The last line of the sub-worktree script's output is the new worktree's path.

## 3. Hand the sub-task to its own session (sub-worktrees)

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

## Fixing one created the wrong way

A worktree made with plain `wt switch --create` or `git worktree add` for a
sub-task shows up at the top level. Link it to its parent:

```sh
wt config state vars set --branch=<child branch> overseer-parent=<parent branch>
```

(Overseer's **Move under…** menu entry does the same.) A worktree created
outside Worktrunk's layout by `git worktree add` still works once linked, but
prefer recreating it with the commands above when it has no work yet.

## Staying in touch

Sessions in the family see each other's news before each prompt (new commits,
files you both edit, their latest note). The `overseer_family` tool lists the
family with intercom addresses and messages them; use intercom `ask` with an
address when you need an answer before continuing. Overseer also tells the
parent when a sub-worktree's session is waiting, failed, or finished with a PR.
