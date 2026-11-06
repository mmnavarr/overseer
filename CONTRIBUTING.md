# Contributing to Overseer

Thanks for helping. A few things make a contribution easy to land.

## Before you start

- **Open an issue first** for anything bigger than a small fix, so we can check it isn't already built or planned. Bug reports with your Tern and Worktrunk versions (`tern --version`, `wt --version`) and the relevant lines from **Show Overseer's operation log** get fixed fastest.
- **Read [AGENTS.md](AGENTS.md)**, especially [the 50 ms rule](AGENTS.md#the-50-ms-rule-read-this-first). Tern pauses a plugin callback that runs too long, so work has to be queued in small steps.

## Set up

Work in a checkout linked into Tern, not the installed copy:

```sh
tern plugin remove overseer   # if you installed it with `tern plugin install`
git clone https://github.com/mmnavarr/overseer.git && cd overseer
tern plugin link "$PWD"
```

Tern reloads a linked plugin whenever a file in it changes, including inside `.git`. To keep your everyday Overseer steady, smoke-test changes in an isolated Tern window ([how](AGENTS.md#developing)).

## Pull request checklist

- [ ] Tests pass: `python3 -B tests/test_worktree_operation.py -v` and `python3 -B tests/test_subworktree.py -v`.
- [ ] You tried the change in a running Tern (an isolated window is fine) and say in the PR what you checked.
- [ ] User-visible changes bump `version` in `plugin.toml` and `omp/package.json`, and add an entry at the top of [CHANGELOG.md](CHANGELOG.md).
- [ ] External commands live in `worktrunk.luau` as argv arrays, never as shell text.
- [ ] Docs: the [README](README.md) stays short and visual; details belong in [AGENTS.md](AGENTS.md).

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
