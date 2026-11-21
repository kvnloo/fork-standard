#!/usr/bin/env bash
# keepalive.sh: stop GitHub's 60-day inactivity rule from disabling the mirror's schedule.
# If the newest commit on the mirror's default branch (_mirror) is older than KEEPALIVE_DAYS,
# push an empty commit on top of it (fast-forward, no force). The tree doesn't change.
# Then, in GitHub mode: call the workflow "enable" API for our own workflow (a no-op while
# it's enabled), and disable any other workflow that has run here. Those are upstream's own
# workflow files, triggered when the sync pushed upstream branches. Disabling them by id means
# each upstream workflow runs at most once in the mirror.
#
# Environment: MIRROR_URL, MIRROR_TOKEN (optional), MIRROR_BRANCH (default _mirror),
#   KEEPALIVE_DAYS (default 45), NOW (epoch seconds, for tests),
#   MIRROR_REPO + WORKFLOW_FILE + GH_TOKEN (optional: enable API call)
set -euo pipefail
: "${MIRROR_URL:?}"
MIRROR_BRANCH="${MIRROR_BRANCH:-_mirror}"
KEEPALIVE_DAYS="${KEEPALIVE_DAYS:-45}"
NOW="${NOW:-$(date -u +%s)}"
export GIT_TERMINAL_PROMPT=0

if [[ -n "${MIRROR_TOKEN:-}" ]]; then
  hdr="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$MIRROR_TOKEN" | base64 -w0)"
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::add-mask::${hdr#AUTHORIZATION: basic }"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.$MIRROR_URL.extraheader" GIT_CONFIG_VALUE_0="$hdr"
fi

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
git init -q --bare "$W/k.git"
G=(git --git-dir="$W/k.git")
"${G[@]}" fetch -q --depth=1 "$MIRROR_URL" "refs/heads/$MIRROR_BRANCH:refs/heads/$MIRROR_BRANCH"
tip="$("${G[@]}" rev-parse "refs/heads/$MIRROR_BRANCH")"
last="$("${G[@]}" log -1 --format=%ct "$tip")"
age_days=$(( (NOW - last) / 86400 ))

if (( age_days < KEEPALIVE_DAYS )); then
  echo "keepalive: $MIRROR_BRANCH last commit ${age_days}d ago (< ${KEEPALIVE_DAYS}d), nothing to do"
else
  export GIT_AUTHOR_NAME="mirror-sync" GIT_AUTHOR_EMAIL="mirror-sync@users.noreply.github.com"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"
  new="$("${G[@]}" commit-tree "$tip^{tree}" -p "$tip" -m "chore(mirror): keepalive (schedule stays enabled)")"
  "${G[@]}" push -q "$MIRROR_URL" "$new:refs/heads/$MIRROR_BRANCH"
  echo "keepalive: $MIRROR_BRANCH was ${age_days}d old, pushed empty commit $new"
fi

if [[ -n "${MIRROR_REPO:-}" && -n "${WORKFLOW_FILE:-}" && -n "${GH_TOKEN:-}" ]]; then
  gh api -X PUT "repos/$MIRROR_REPO/actions/workflows/$WORKFLOW_FILE/enable" >/dev/null 2>&1 \
    && echo "keepalive: workflow $WORKFLOW_FILE enable call ok" \
    || echo "::notice::keepalive: enable call for $WORKFLOW_FILE failed (needs actions:write); commit keepalive still applies"
  ids="$(gh api "repos/$MIRROR_REPO/actions/workflows" --paginate \
         --jq ".workflows[] | select(.path != \".github/workflows/$WORKFLOW_FILE\" and .state == \"active\") | .id" 2>/dev/null || true)"
  for id in $ids; do
    gh api -X PUT "repos/$MIRROR_REPO/actions/workflows/$id/disable" >/dev/null 2>&1 \
      && echo "housekeeping: disabled upstream workflow $id in the mirror" || true
  done
fi
