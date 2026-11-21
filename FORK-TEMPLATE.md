# FORK.md template and README rule

Every fork gets a `FORK.md` on `staging`, filled in from the template below. This is where everything
fork-specific is written down, so upstream's files stay untouched.

## The README rule

On `staging`, `README.md` is **byte-identical to upstream's README** except for **one added line**
at the very top:

```markdown
> **Fork of [UPSTREAM_OWNER/UPSTREAM_REPO](https://github.com/UPSTREAM_OWNER/UPSTREAM_REPO).** What's different, branch roles and sync: see [FORK.md](FORK.md).
```

- Put nothing else in README: no badges, no rewritten sections, no "our features" list. That all goes in `FORK.md`.
- On `main` (upstream's default branch), README is upstream's, unmodified. `main` never has our commits.
- Check it (should print exactly one added line, the pointer):
  ```bash
  git fetch origin main staging
  git diff origin/main origin/staging -- README.md | grep '^[+-][^+-]'
  ```
- When upstream changes README, take upstream's version when merging `main` into `staging`, then
  re-add the pointer line.

---

## Template (copy below this line into `FORK.md` on `staging`)

```markdown
# FORK.md: OWNER/REPO

Fork of [UPSTREAM_OWNER/UPSTREAM_REPO](https://github.com/UPSTREAM_OWNER/UPSTREAM_REPO).
Detached backup mirror: [MIRROR_OWNER/MIRROR_REPO](https://github.com/MIRROR_OWNER/MIRROR_REPO) (all upstream branches and tags; survives upstream deletion).

## Branch roles

| Branch | What it is | Rules |
|---|---|---|
| `UPSTREAM_DEFAULT` (e.g. `main`) | Exact copy of upstream | Never commit here. Fast-forwarded daily by the mirror's sync job. |
| `staging` | Our code | Default target for all PRs. |
| PROMOTION_BRANCH (e.g. `z0/play-release`) | Release cut from `staging` | Only cut when the owner says so. |

## What this fork adds

<!-- One bullet per feature, newest first. Link the PR. Keep it user-facing. -->
- FEATURE: one line on what it does and why (#PR)

## Differences from upstream that aren't features

<!-- Renamed app id, removed telemetry, CI changes, licence notes, assets replaced, etc. -->
- e.g. App id changed to `io.github.OWNER.APP` so it installs next to upstream's build.

## Syncing with upstream

Automatic: the mirror's workflow runs daily and fast-forwards `UPSTREAM_DEFAULT` to upstream (FF only, never force).
If it can't, an issue labelled `mirror-alert` opens in the mirror repo.

Bring upstream into our code (by hand, as a PR):

    git fetch origin
    git switch -c sync/upstream-YYYY-MM-DD origin/staging
    git merge origin/UPSTREAM_DEFAULT        # resolve conflicts; README: take upstream + re-add the pointer line
    git push -u origin HEAD                  # open a PR into staging

If `UPSTREAM_DEFAULT` ever gets our commits by mistake (the mirror opens a `fork-diverged` issue):

    git switch -c rescue/main-commits origin/UPSTREAM_DEFAULT   # keep the commits, PR them into staging
    git push -u origin HEAD
    gh api -X PATCH repos/OWNER/REPO/git/refs/heads/UPSTREAM_DEFAULT \
      -f sha=$(git ls-remote https://github.com/UPSTREAM_OWNER/UPSTREAM_REPO.git refs/heads/UPSTREAM_DEFAULT | cut -f1) -F force=true

If upstream force-pushed (the issue says the fork's tip is archived as `_gone/...` in the mirror), only the last command is needed.

If upstream disappears: nothing to do. The mirror keeps everything, and its `upstream-gone` issue says so.

## Release / promotion

<!-- How a release is cut from staging (store, tags, artifacts). Owner approval gates. -->
```
