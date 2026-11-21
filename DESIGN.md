# Fork standard and detached upstream mirrors: design

Status: proposal, implemented and tested offline. Nothing exists on GitHub yet. The owner still
decides **scope** (which forks), **location** (which account or org holds the mirrors) and the
**credential** (one GitHub App is recommended below). See "Owner decisions" at the end.

## 1. Goals

The owner's ask, in short:

1. Every fork: `main` (or upstream's default branch) follows upstream exactly. `staging` holds our code.
2. Every fork also gets a backup that has **left the fork network**, so it survives upstream being
   deleted, made private or taken down.
3. Syncing is a **cron job in GitHub Actions running in the detached mirror itself**. No Studio,
   no groot, no cron of ours.
4. **Minimal ownership and technical debt.** It must keep working with nobody touching it.

### Why the fork alone isn't a backup

| Event upstream | What happens to our fork | Mirror |
|---|---|---|
| Public repo deleted | The fork survives (GitHub re-roots the network), but it only has the branches we synced, usually just `main` | Has every branch and tag |
| Made private | The fork is detached and survives, same gap | Same |
| DMCA / takedown | GitHub disables the **whole network, forks included**, when the notice says the forks infringe too | A separate repo; it needs its own notice |
| Force-push wipes history | If we FF'd before, we keep it; otherwise it's gone | `_gone/` keeps every old tip |

## 2. Branch roles in each fork (the "fork standard")

| Branch | Content | Who writes it |
|---|---|---|
| `main` (or upstream's default, e.g. hermex `master`) | Byte-for-byte upstream. Never has our commits. | Only the mirror job, fast-forward only |
| `staging` | Our code. All PRs target it. | Us |
| promotion branches (e.g. `z0/play-release`) | Cut from `staging` on the owner's word | Us |

README rule: on `staging`, `README.md` is byte-identical to upstream's except for **one line**
pointing at `FORK.md`. See `FORK-TEMPLATE.md`. `onboard.sh` creates `staging` from `main` if it's missing.

## 3. Mirror repo layout

One **detached (not a fork) public repo per upstream**, created with `gh repo create` plus a push.

```
<mirror-owner>/<prefix><upstream-owner>--<upstream-repo>     e.g. kvnloo/mirror--rusty4444--ares
  refs/heads/_mirror            DEFAULT branch: README.md + .github/workflows/mirror.yml (the ~12-line caller)
  refs/heads/<branch>           every upstream branch under its own name
  refs/tags/<tag>               every upstream tag
  refs/heads/_gone/<b>-<date>   tips that upstream rewrote or deleted (never dropped)
  refs/tags/_gone/<t>-<date>    tags that upstream moved or deleted
```

Why the default branch is `_mirror`, not upstream's `main`:
- Scheduled workflows only run from the **default branch**. If the default branch were upstream's
  `main`, our workflow file would have to live in upstream's tree (so the mirror wouldn't be a
  copy any more), and upstream's own scheduled workflows would run in our repo.
- `_mirror` shares no history with upstream, so no upstream push can ever touch it. The sync
  treats `_mirror` and `_gone/*` as reserved. If upstream has a branch with one of those names,
  the sync skips it with a warning (tested).

## 4. The sync run

Trigger: daily `schedule`, at a minute and hour derived from a hash of the mirror's name so 300+ mirrors
don't all fire at once, plus `workflow_dispatch`. Daily is enough for a backup. Hourly also works
(public repos have no minute cost) but makes 24× the noise.

`scripts/sync.sh` does all of the work. The workflow only mints tokens and calls it:

1. **Probe upstream** anonymously with `git ls-remote`. Our token is never sent to upstream.
   - Error text means gone or private ("Repository not found", "could not read Username",
     401/403/404/410/451): write an `upstream-gone` alert, **touch nothing, exit 0**.
   - Zero branches: write an `upstream-empty` alert, touch nothing, exit 0. An empty answer is never
     taken as "delete everything".
   - Anything else (DNS, 5xx): retry 3 times, then exit 1. The run goes red only because something
     unexpected happened.
2. **Fetch** the mirror's own refs first, then upstream's. Only the delta comes from upstream.
3. **Plan, ref by ref:**

   | Upstream vs mirror | Action |
   |---|---|
   | new ref | create |
   | same sha | nothing |
   | branch fast-forwards | plain push (git itself refuses non-FF) |
   | branch rewritten, or tag moved | push old tip to `_gone/<name>-<date>`, then update with `--force-with-lease=<ref>:<old>` |
   | ref deleted upstream | push old tip to `_gone/<name>-<date>`, then remove the name with a lease |

   - "No deletes" here means no data is ever dropped. A deleted upstream branch is **renamed**
     into `_gone/`, never pruned. The overwrite or removal only runs once the old sha is
     confirmed to sit under `_gone/` on the mirror.
   - Renaming instead of keeping the old name forever keeps `refs/heads/*` equal to upstream. It
     also avoids git's directory/file ref clash (a deleted `foo` would otherwise block a later
     `foo/bar`) and stops the same deletion being re-detected every day.
   - Dedup: if any `_gone/<name>-YYYY-MM-DD[.N]` already holds the old sha, nothing new is made.
     A second rewrite on the same day gets `.2`, `.3`, and so on.
4. **Push** in batches. If a batch is refused, the sync retries ref by ref, so one bad ref (say,
   a workflow-file change without the permission) can't block the rest. Refused refs raise a
   `push-rejected` alert and exit 1.
5. **Fast-forward the fork's `main`** (or `branch:`), FF only:
   - Pre-check with git: the fork's tip must be an ancestor of upstream's tip. This matters
     because **merge-upstream can return `merge_type: merge`**: on a diverged branch it makes a
     merge commit, which would put a non-upstream commit on `main`.
   - If the check passes: `POST /repos/{fork}/merge-upstream {branch}` (default `api` method,
     server-side, nothing uploaded). The alternative `push` method is `git push` without force.
     Either way a race that turns into a merge is reported.
   - Diverged: **no force**. A `::warning::` plus a `fork-diverged` alert, and the job stays green.
     The message tells the two cases apart:
     - someone committed on `main`: "move them to staging, then reset";
     - upstream force-pushed: "the fork's tip is already archived as `_gone/main-<date>`" plus the
       exact `gh api` command to reset by hand.
6. **Size and LFS notes:** packed size over `size_limit_mb` (default 5000) raises `oversize`. If upstream
   uses LFS, a notice is printed (see §8).
7. **Alerts → issues** (`scripts/alerts.sh`): one open issue per kind, deduped by the title prefix
   `[mirror:<kind>]` and labelled `mirror-alert`. If a kind was checked this run and didn't fire, its
   open issue is **closed automatically**. So when upstream comes back, the gone issue closes itself.
   Kinds: `upstream-gone`, `upstream-empty`, `push-rejected`, `fork-diverged`, `fork-error`, `oversize`.
8. **Housekeeping** (`scripts/keepalive.sh`), covered in §7 and §9.

## 5. Reusable workflow vs one matrix workflow

| | **A. Reusable workflow + caller per mirror** (chosen) | B. One matrix workflow in one repo |
|---|---|---|
| "cron runs in the disconnected fork" | **Yes.** Each mirror has its own schedule. | **No.** The cron runs in the hub and pushes into mirrors |
| Code we own | 1 reusable workflow + 3 scripts in one repo, plus a 12-line caller per mirror that never changes | 1 workflow + scripts; mirrors are passive |
| Upgrades | Callers pin `@v1`; moving the `v1` tag upgrades every mirror | Edit one file |
| Blast radius | One mirror's breakage or 60-day disable affects only that mirror | One disable or broken run stops **all** mirrors |
| Scale | Unlimited; 300+ independent schedules | A matrix caps at **256 jobs per run**: 360 forks needs sharding |
| If the hub repo vanishes | Schedules keep firing but fail loudly (red run + email); mirror data is untouched | Silently stops |
| Credential spread | Secret set in every mirror's environment (§6) | One secret in one repo |
| Onboarding | `scripts/onboard.sh <fork>` (creates repo, caller, env, secret) | One line in a list |

**Pick A.** It's the only option that meets the owner's literal requirement. It isolates failures,
and per-mirror state (alert issues, run history) lives next to the data. The extra cost is the
caller file and a per-repo secret, and `onboard.sh` writes both in one command. Option B's single
point of failure fights "self-sustaining" too.

The hub (this repo, default name `kvnloo/fork-standard`; change `tooling_repo` and the caller's
`uses:` in one place if tek lands it elsewhere) must be **public** so every mirror can call it. It
needs **no schedule of its own**, so the 60-day rule doesn't apply to it.

## 6. Credential

Pushing upstream's history means pushing commits that touch `.github/workflows/*`. GitHub refuses
those unless the token has the **workflows** permission, and the default `GITHUB_TOKEN` can never
get it. Tested in `tests/test_sync.sh` case 2 with a hook that copies the rule.

| | GitHub App + `actions/create-github-app-token` | Fine-grained PAT | Classic PAT |
|---|---|---|---|
| Expiry | Private key doesn't expire; each run mints a **1-hour** token | Can be non-expiring (GitHub allows infinite lifetimes unless an org policy blocks it) | Can be non-expiring; GitHub deletes it after a year unused |
| Scope | Per-permission: Contents RW, Workflows RW, Issues RW, Actions RW, Metadata R; only where installed | Per-permission, chosen repos or all of one owner | `repo` + `workflow` = **every repo the user can reach**, private ones included |
| Identity | `<app>[bot]`; not tied to a person | Acts as the owner | Acts as the owner |
| Leak impact | 1-hour token; key rotates in the App settings | Long-lived token with write to many repos | Worst: full write everywhere |
| Rate limit | Its own, scales with installs | Owner's 5000/h shared with everything | Same |
| Setup | Create the App once, install it, store app id + key | Create the token, store it | Create the token, store it |

**Recommend a GitHub App** (private to the owner's account, "Only on this account"):
- Permissions: Contents RW, Workflows RW, Issues RW, Actions RW, Administration none, Metadata R.
- Install it on **All repositories** of the account, so new mirrors and forks are covered with no
  extra step. If the owner prefers *selected repositories*, `onboard.sh` adds each mirror through
  the installations API when `MIRROR_APP_INSTALLATION_ID` is set.

Where the secret lives, and why it matters:
- Pushing upstream branches **with an App token does trigger** upstream's own `on: push`
  workflows in the mirror. Only `GITHUB_TOKEN` pushes are exempt, and they can't carry the
  workflows permission.
- So the key is stored as an **environment secret** in environment `mirror-sync`, whose deployment
  policy only allows the `_mirror` branch. An upstream workflow on any other branch **can't read it**.
- On top of that, `onboard.sh` sets three things:
  - the Actions policy to *selected actions only* (`actions/checkout`, `actions/create-github-app-token`
    and this reusable workflow), so most upstream workflows fail at setup;
  - the default `GITHUB_TOKEN` to read-only;
  - housekeeping that disables every workflow other than `mirror.yml` after it first shows up.
- Each upstream workflow therefore runs at most once, and can't use our secrets. Its runs are attributed to the App bot,
  so they shouldn't email the owner (to confirm on the first real mirror).
- Each run also leaves a deployment record in the `mirror-sync` environment. That's harmless.

If the mirrors live in a different owner than the forks (e.g. a `kvnloo-mirrors` org), the workflow
mints a second token for the fork owner. That needs the App installed on both accounts, which a
private App can't do. It's one more reason the default is mirrors under the same account with a
`mirror--` prefix.

## 7. Surviving the 60-day schedule auto-disable

GitHub disables schedules in public repos after 60 days without repository activity. A dormant
upstream means no pushes to the mirror, so this will happen. Three layers:

1. **Keepalive commit** (primary, tested): if the newest commit on `_mirror` is older than 45 days,
   push an **empty** commit on top (fast-forward, same tree). That's about 8 tiny commits a year on a
   branch only we own.
2. **Enable API**: each run calls `PUT /actions/workflows/mirror.yml/enable`, a no-op while enabled.
3. **Recovery**: if a schedule was disabled anyway (say the hub was down for 60 days), GitHub emails
   the owner. `scripts/onboard.sh <fork> --reenable` (or `--all forks.txt --reenable`) prints or runs
   `gh workflow enable`.

## 8. Size, LFS, limits

- GitHub asks that repos stay small: ideally under 1 GB, under 5 GB strongly recommended. It refuses
  single pushes over **2 GB** and files over 100 MB (upstream already meets the file limit).
- **Owner rule: over 5 GB needs the owner's approval.** `onboard.sh` refuses (exit 3) unless
  `--allow-large` is passed. The workflow raises an `oversize` alert if a mirror grows past
  `size_limit_mb`.
- From the 11-21 survey of 360 forks: chromium (~63 GB) and ClickHouse (~15 GB) are over 5 GB, 11 more
  are 1-5 GB, and 347 are under 1 GB. See the REPORT for the list.
- Initial pushes over 2 GB (1-5 GB repos) need to go in steps: push older history first (e.g. tags
  oldest to newest), then the branches. Only about 11 repos need this. They're done by hand at
  onboarding, then the daily deltas are small. Not automated, to keep the tooling small.
- **Git LFS: not mirrored** (owner rule: no Git LFS). Branches carry the LFS *pointer files* only. The
  run prints a notice when upstream's `.gitattributes` uses `filter=lfs`. If upstream vanishes, its
  LFS objects go with it.

## 9. Cost

- Public repos: GitHub-hosted standard runners are **free and unmetered**.
- A daily run is about 10-30 s for typical repos (a local real-network run of `uzairansaruzi/hermex`,
  55 refs / 59 MB, took 8 s).
- Private mirrors would burn minutes (360 × 30 × ~1 min ≈ 10,800 min/month, over any free quota),
  and environments with branch policies need a paid plan on private repos. **Mirrors must be public.**
  The forks are public already, so a public mirror doesn't expose anything new.

## 10. Onboarding

Dry run by default; `--apply` executes:

```
scripts/onboard.sh kvnloo/hermex                       # look up the parent, print every command
scripts/onboard.sh kvnloo/hermex --apply               # do it (needs gh auth with repo+workflow)
scripts/onboard.sh --all forks.txt [--apply]           # the whole list; re-runs are safe
```

What it does:
- Size guard.
- `gh repo create` (public, detached).
- Push `_mirror` with the rendered caller and README, and set it as the default branch.
- Create the `mirror-sync` environment and limit it to `_mirror`.
- Set the App id variable and the key secret.
- Set the Actions allowlist and a read-only `GITHUB_TOKEN`.
- Install the App if needed.
- Create the fork's `staging` if missing.
- Dispatch the first run.
- Append the fork to `forks.txt`.

`forks.txt` is the declarative list: one line per fork, `<fork> <upstream> <branch|->`.

## 11. Ownership summary

What we own:
- `.github/workflows/mirror-sync.yml` (a thin wrapper)
- `scripts/sync.sh`, `alerts.sh`, `keepalive.sh` (plain bash + git + jq + gh, all present on `ubuntu-latest`)
- `scripts/onboard.sh`
- `templates/caller.yml`
- `tests/test_sync.sh`
- one GitHub App

No servers, no databases, no cron outside GitHub. Upgrades: tag a new `v1` in the hub. Every
mirror picks it up on its next run.

## 12. Owner decisions (blocking `--apply`, not the code)

1. **Scope:** all 360 forks, or start with the forks that have `staging` (hermes-android, hermex,
   hermes-agent, Telegram)? The 2 forks over 5 GB need explicit approval or exclusion.
2. **Location:** same account with the `mirror--` prefix (default; one App install), or a dedicated
   org (cleaner profile; App must be public or owned by the org, two installs).
3. **Credential:** create the GitHub App (recommended) or accept a fine-grained PAT.
4. **Hub repo:** where this repo lands (`kvnloo/fork-standard` assumed) and tagging `v1`.
5. **glide:** its `main` is our code (1225 ahead). It can't follow the standard until the owner
   decides to move our work to `staging` and reset `main` to upstream. It's commented out in `forks.txt`.
