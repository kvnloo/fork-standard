# fork-standard (runner)

Public runner for Kevin's fork backups. It holds only `.github/workflows/fork-backups.yml`, which runs
daily on free public Actions minutes. All code, tests and docs live in the private `kvnloo/home` repo
under `tools/fork-standard/` (cataloged in its `map/`). Don't edit here; edit there and run
`tools/fork-standard/scripts/publish-runner.sh`.

What it does: every fork of `kvnloo/*` that holds our commits gets a detached `kvnloo/<fork>-backup`
repo. That backup syncs itself daily: upstream branches + tags, upstream PR heads (`_pr/<n>`), our
fork's branches (`_fork/<branch>`), issues/PRs/comments as JSON (`_meta`), and it fast-forwards the
fork's `main` to upstream. Nothing is dropped. The runner also re-registers and re-dispatches any
backup whose sync stopped, and goes red when anything failed.
