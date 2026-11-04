---
description: Create worktrees through the overseer-subworktree skill so Tern's Overseer hierarchy holds
condition: '(?:\bgit\s+(?:-C\s+\S+\s+)?worktree\s+add\b|\bwt\s+(?:-C\s+\S+\s+)?switch\b[^\n]*\s(?:--create|-c)\b|\bomp\s+(?:worktree|wt)\s+add\b|worktree-manager\.sh\s+create\b)'
scope: "tool:bash, tool:eval"
---
You are about to create a worktree. Every worktree goes through the `overseer-subworktree` skill (skill://overseer-subworktree), so Tern's Overseer shows the right hierarchy:

- In a worktree (not the primary checkout), for part of that worktree's task → create a sub-worktree with `~/.omp/plugins/node_modules/overseer-omp/skills/overseer-subworktree/overseer-subworktree <branch> [--base <ref>] [--brief -]`.
- In the primary checkout, or for work unrelated to this worktree's task → a top-level `wt switch --create <branch> --no-cd`.
- Never `git worktree add`, `omp worktree add`, or the ce-worktree / git-worktree scripts.

Read the skill if you haven't, decide, then run the matching command. If you had already decided that a top-level `wt switch --create` is right, run it again unchanged.
