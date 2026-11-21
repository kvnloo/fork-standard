# fork-standard

Two things for every fork:

1. **Branch standard:** `main` follows upstream exactly, and `staging` holds our code.
2. **Detached backup mirror:** a public non-fork repo that copies all of upstream's branches and
   tags daily and fast-forwards our fork's `main`. Its cron runs in the mirror itself.

| Path | What |
|---|---|
| `DESIGN.md` | The design and its trade-offs: layout, credential, 60-day rule, size, cost, reusable vs matrix |
| `FORK-TEMPLATE.md` | The `FORK.md` template and the README rule (byte-identical plus a one-line pointer) |
| `.github/workflows/mirror-sync.yml` | Reusable workflow (`workflow_call`), a thin wrapper around `scripts/` |
| `templates/caller.yml` | The 12-line caller each mirror keeps on its `_mirror` default branch |
| `scripts/sync.sh` | The sync engine (git only; never forces or drops data) |
| `scripts/alerts.sh` | Alert payloads → deduped `mirror-alert` issues, auto-closed when resolved |
| `scripts/keepalive.sh` | Keeps the schedule alive (60-day rule), quiets upstream workflow files |
| `scripts/onboard.sh` | `onboard.sh <owner/fork>`: dry run by default, `--apply`, `--all forks.txt`, `--reenable` |
| `forks.txt` | The list of forks to mirror |
| `tests/test_sync.sh` | Offline simulation with bare repos (upstream, mirror, fork) |

```
bash tests/test_sync.sh          # needs git, jq, python3 (pyyaml); no network, no GitHub
scripts/onboard.sh kvnloo/hermex # prints what it would do
```
