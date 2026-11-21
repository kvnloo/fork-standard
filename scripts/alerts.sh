#!/usr/bin/env bash
# alerts.sh: turn sync.sh's alert payloads into GitHub issues in the mirror repo.
#   - one open issue per alert kind (dedup key: the "[mirror:<kind>]" title prefix)
#   - a kind that was checked this run and didn't fire gets its open issue closed
# Environment: OUT_DIR (from sync.sh), MIRROR_REPO (owner/name), GH_TOKEN, RUN_URL (optional)
set -euo pipefail
: "${OUT_DIR:?}" "${MIRROR_REPO:?}"
RUN_URL="${RUN_URL:-local run}"
LABEL=mirror-alert

gh label create "$LABEL" -R "$MIRROR_REPO" --color B60205 \
  --description "Opened by the mirror sync workflow" --force >/dev/null 2>&1 || true

open_json="$(gh issue list -R "$MIRROR_REPO" --label "$LABEL" --state open --json number,title --limit 100)"
issue_for() {  # issue_for <kind> -> number of the open issue for that kind, or nothing
  jq -r --arg p "[mirror:$1]" '[.[] | select(.title | startswith($p))][0].number // empty' <<<"$open_json"
}

shopt -s nullglob
for f in "$OUT_DIR"/alerts/*.json; do
  kind="$(jq -r .kind "$f")"
  n="$(issue_for "$kind")"
  if [[ -n "$n" ]]; then
    echo "alert $kind: already open as #$n (dedup, nothing posted)"
    continue
  fi
  jq -r .body "$f" > "$OUT_DIR/body.md"
  gh issue create -R "$MIRROR_REPO" --title "$(jq -r .title "$f")" --body-file "$OUT_DIR/body.md" --label "$LABEL"
  echo "alert $kind: issue opened"
done

[[ -f "$OUT_DIR/checked.txt" ]] || exit 0
while read -r kind; do
  [[ -n "$kind" && ! -f "$OUT_DIR/alerts/$kind.json" ]] || continue
  n="$(issue_for "$kind")"
  [[ -n "$n" ]] || continue
  gh issue close "$n" -R "$MIRROR_REPO" --comment "Resolved: the check passed on $RUN_URL."
  echo "alert $kind: resolved, closed #$n"
done < "$OUT_DIR/checked.txt"
