#!/usr/bin/env bash
# onboard.sh <owner/fork> [options]: set up the detached mirror for one fork.
# Dry run by default: prints every gh/git command it would run, plus the files it would push.
# Pass --apply to run them (needs `gh auth login` with repo + workflow scopes). Safe to re-run.
#
#   --upstream owner/name   skip the read-only lookup of the fork's parent
#   --branch name           fork branch to fast-forward (default: upstream's default branch)
#   --size-kb N             upstream size in KB (default: read-only lookup)
#   --mirror-owner name     where mirrors live (default: $MIRROR_OWNER or the fork's owner)
#   --prefix str            mirror repo name prefix (default: $MIRROR_PREFIX or "mirror--")
#   --tooling owner/name    repo with the reusable workflow (default: kvnloo/fork-standard)
#   --allow-large           allow mirrors over 5 GB (owner approval given)
#   --reenable              only print/run the command that re-enables a disabled schedule
#   --all FILE              onboard every line of FILE (forks.txt format)
#   --apply                 actually run the commands
#
# Env for --apply: MIRROR_APP_ID, MIRROR_APP_KEY_FILE (path to the App's .pem),
#   MIRROR_APP_INSTALLATION_ID (only if the App is installed on selected repos, not all).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LIMIT_KB=$((5 * 1024 * 1024))

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

FORK="" UPSTREAM="" BRANCH="" SIZE_KB="" APPLY=0 ALLOW_LARGE=0 REENABLE=0 ALL=""
MOWNER="${MIRROR_OWNER:-}" PREFIX="${MIRROR_PREFIX-mirror--}" TOOLING="kvnloo/fork-standard"
while (($#)); do
  case "$1" in
    --upstream) UPSTREAM="$2"; shift ;;
    --branch) BRANCH="$2"; shift ;;
    --size-kb) SIZE_KB="$2"; shift ;;
    --mirror-owner) MOWNER="$2"; shift ;;
    --prefix) PREFIX="$2"; shift ;;
    --tooling) TOOLING="$2"; shift ;;
    --allow-large) ALLOW_LARGE=1 ;;
    --reenable) REENABLE=1 ;;
    --all) ALL="$2"; shift ;;
    --apply) APPLY=1 ;;
    -h|--help) usage ;;
    -*) echo "unknown option $1" >&2; usage ;;
    *) FORK="$1" ;;
  esac
  shift
done

if [[ -n "$ALL" ]]; then
  rc=0
  pass=(); ((APPLY)) && pass+=(--apply); ((ALLOW_LARGE)) && pass+=(--allow-large); ((REENABLE)) && pass+=(--reenable)
  while read -r f u b _; do
    [[ -z "$f" || "$f" == \#* ]] && continue
    echo "########## $f"
    args=("$f" --upstream "$u" --prefix "$PREFIX" --tooling "$TOOLING")
    [[ -n "$b" && "$b" != "-" ]] && args+=(--branch "$b")
    [[ -n "$MOWNER" ]] && args+=(--mirror-owner "$MOWNER")
    "$0" "${args[@]}" "${pass[@]}" || rc=1
  done < "$ALL"
  exit $rc
fi

[[ "$FORK" == */* ]] || usage

# Read-only lookup over the public API (no auth) for whatever wasn't given.
if [[ -z "$UPSTREAM" || -z "$SIZE_KB" || -z "$BRANCH" ]]; then
  meta="$(curl -fsS "https://api.github.com/repos/$FORK")" || { echo "lookup of $FORK failed; pass --upstream/--branch/--size-kb" >&2; exit 1; }
  UPSTREAM="${UPSTREAM:-$(jq -r '.parent.full_name // empty' <<<"$meta")}"
  [[ -n "$UPSTREAM" ]] || { echo "$FORK is not a fork (no parent); pass --upstream" >&2; exit 1; }
  BRANCH="${BRANCH:-$(jq -r '.parent.default_branch' <<<"$meta")}"
  SIZE_KB="${SIZE_KB:-$(jq -r '.parent.size' <<<"$meta")}"
fi

MOWNER="${MOWNER:-${FORK%%/*}}"
MIRROR="$MOWNER/${PREFIX}${UPSTREAM%%/*}--${UPSTREAM#*/}"
h=$(printf '%s' "$MIRROR" | cksum | cut -d' ' -f1)
CRON="$((h % 60)) $(((h / 60) % 24)) * * *"   # daily, spread so 300 mirrors don't all fire at once

if [[ "$REENABLE" == 1 ]]; then
  cmd="gh workflow enable mirror.yml -R $MIRROR"
  ((APPLY)) && eval "$cmd" || echo "$cmd"
  exit 0
fi

if (( SIZE_KB > LIMIT_KB )) && (( ! ALLOW_LARGE )); then
  echo "REFUSED: $UPSTREAM is $((SIZE_KB / 1024)) MB, over the 5 GB limit. Mirrors over 5 GB need owner approval; re-run with --allow-large once Kevin approves." >&2
  exit 3
fi

D="$(mktemp -d)"
mkdir -p "$D/.github/workflows"
sed -e "s#{{UPSTREAM}}#$UPSTREAM#; s#{{FORK}}#$FORK#; s#{{BRANCH}}#$BRANCH#; s#{{CRON}}#$CRON#; s#{{TOOLING}}#$TOOLING#" \
  "$HERE/templates/caller.yml" > "$D/.github/workflows/mirror.yml"
cat > "$D/README.md" <<EOF
# Detached mirror of [$UPSTREAM](https://github.com/$UPSTREAM)

A backup that has **left the fork network**: it survives upstream being deleted, made private or taken down.

- Upstream branches and tags are under their normal names. This branch (\`_mirror\`) only holds the sync workflow.
- Rewritten or deleted upstream refs are kept under \`_gone/<name>-<date>\`. Nothing is ever dropped.
- Each run also fast-forwards [$FORK](https://github.com/$FORK) \`$BRANCH\` (FF only, never force).
- Problems show up as issues labelled \`mirror-alert\`.

Sync logic: [$TOOLING](https://github.com/$TOOLING). Git LFS objects aren't mirrored (pointer files only).
EOF

echo "# fork:     $FORK  (branch $BRANCH is FF-only from upstream; our code lives on staging)"
echo "# upstream: $UPSTREAM  ($((SIZE_KB / 1024)) MB)"
echo "# mirror:   $MIRROR  (detached, public, default branch _mirror, cron '$CRON')"
echo "# files to push on _mirror (in $D):"
echo "----- BEGIN caller .github/workflows/mirror.yml"; cat "$D/.github/workflows/mirror.yml"; echo "----- END caller"

ENV_JSON='{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
POLICY_JSON="{\"github_owned_allowed\":false,\"verified_allowed\":false,\"patterns_allowed\":[\"actions/checkout@*\",\"actions/create-github-app-token@*\",\"$TOOLING/.github/workflows/mirror-sync.yml@*\"]}"
cmds=(
  "gh repo view $MIRROR >/dev/null 2>&1 || gh repo create $MIRROR --public --disable-wiki --description 'Detached backup mirror of $UPSTREAM (not a fork). Default branch _mirror = sync workflow only.'"
  "git -C $D init -q -b _mirror && git -C $D add -A && git -C $D commit -q -m 'chore(mirror): add sync caller' && git -C $D push -q https://github.com/$MIRROR.git _mirror"
  "gh repo edit $MIRROR --default-branch _mirror --enable-issues --enable-wiki=false --enable-projects=false"
  "gh api -X PUT repos/$MIRROR/environments/mirror-sync --input - <<<'$ENV_JSON'"
  "gh api -X POST repos/$MIRROR/environments/mirror-sync/deployment-branch-policies -f name=_mirror -f type=branch"
  "gh variable set MIRROR_APP_ID --env mirror-sync -R $MIRROR --body \"\$MIRROR_APP_ID\""
  "gh secret set MIRROR_APP_PRIVATE_KEY --env mirror-sync -R $MIRROR < \"\$MIRROR_APP_KEY_FILE\""
  "gh api -X PUT repos/$MIRROR/actions/permissions -F enabled=true -f allowed_actions=selected"
  "gh api -X PUT repos/$MIRROR/actions/permissions/selected-actions --input - <<<'$POLICY_JSON'"
  "gh api -X PUT repos/$MIRROR/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false"
  "[ -z \"\${MIRROR_APP_INSTALLATION_ID:-}\" ] || gh api -X PUT user/installations/\$MIRROR_APP_INSTALLATION_ID/repositories/\$(gh api repos/$MIRROR --jq .id)"
  "gh api repos/$FORK/branches/staging --silent 2>/dev/null || gh api -X POST repos/$FORK/git/refs -f ref=refs/heads/staging -f sha=\$(gh api repos/$FORK/commits/$BRANCH --jq .sha)"
  "gh workflow run mirror.yml -R $MIRROR"
  "grep -q '^$FORK ' $HERE/forks.txt 2>/dev/null || echo '$FORK $UPSTREAM $BRANCH' >> $HERE/forks.txt"
)

if (( APPLY )); then
  : "${MIRROR_APP_ID:?set MIRROR_APP_ID}" "${MIRROR_APP_KEY_FILE:?set MIRROR_APP_KEY_FILE}"
  for c in "${cmds[@]}"; do echo "+ $c"; bash -c "$c"; done
  echo "onboarded $FORK -> $MIRROR"
else
  echo "# DRY RUN: commands that --apply would run:"
  printf '%s\n' "${cmds[@]}"
  rm -rf "$D"
fi
