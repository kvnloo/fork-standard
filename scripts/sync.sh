#!/usr/bin/env bash
# sync.sh: one mirror sync run. The GitHub workflow is a thin wrapper around this file,
# and tests/test_sync.sh runs it against local bare repos.
#
# What it does:
#   1. Read upstream's refs (anonymous). If upstream is gone, private or empty, write an
#      alert and exit 0 without touching anything.
#   2. Copy upstream branches and tags into the mirror. No ref is ever dropped:
#      - new ref       -> created
#      - fast-forward  -> updated (plain push, git refuses anything else)
#      - rewritten     -> old tip archived as _gone/<name>-<date>, then updated with a lease
#      - deleted       -> old tip archived as _gone/<name>-<date>, then the name is removed
#                         with a lease (a rename; the commit stays reachable)
#   3. Fast-forward our fork's tracking branch (upstream's default unless FORK_BRANCH is set).
#      FF only. If the fork has diverged, warn and raise an alert. Never force.
#
# Environment (required): UPSTREAM_URL, MIRROR_URL
# Environment (optional):
#   FORK_URL             fork to fast-forward ('' = mirror only)
#   FORK_BRANCH          branch to fast-forward ('' = upstream's default branch)
#   FORK_SYNC_METHOD     api (GitHub merge-upstream, needs gh + FORK_REPO) | push (git, FF-only)
#   FORK_REPO            owner/name of the fork (for the api method and messages)
#   UPSTREAM_REPO        owner/name of upstream (messages only)
#   MIRROR_TOKEN, FORK_TOKEN  tokens sent only to MIRROR_URL / FORK_URL (never to upstream)
#   OUT_DIR              where alerts/*.json, checked.txt and summary.md go (default ./out)
#   SYNC_DATE            date used in _gone names (default: today, UTC)
#   SIZE_LIMIT_MB        raise an 'oversize' alert above this packed size (default 5000)
#   DRY_RUN=1            plan only, push nothing
#   RUN_URL              link to the run, used in alert bodies
#
# Exit codes: 0 = mirror is current, or upstream is gone (alert written).
#             1 = some refs could not be pushed, or upstream unreachable for a non-gone reason.
#             2 = usage error.
set -euo pipefail

GONE_PREFIX="_gone"
MIRROR_BRANCH="${MIRROR_BRANCH:-_mirror}"

log()  { printf '%s\n' "$*" >&2; }
warn() { printf '::warning::%s\n' "$*" >&2; }
err()  { printf '::error::%s\n' "$*" >&2; }

# classify_remote_error <stderr text> -> prints "gone" or "transient"
classify_remote_error() {
  local text
  text="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$text" in
    *"repository not found"*|*"not found"*|*"does not appear to be a git repository"*|\
    *"could not read username"*|*"terminal prompts disabled"*|*"authentication failed"*|\
    *"returned error: 401"*|*"returned error: 403"*|*"returned error: 404"*|\
    *"returned error: 410"*|*"returned error: 451"*|*"access denied"*|*"dmca"*)
      echo gone ;;
    *) echo transient ;;
  esac
}

# Library mode: tests source this file to unit-test the functions above.
if [[ "${SYNC_LIB_ONLY:-0}" == 1 ]]; then return 0 2>/dev/null || exit 0; fi

: "${UPSTREAM_URL:?UPSTREAM_URL is required}"
: "${MIRROR_URL:?MIRROR_URL is required}"
FORK_URL="${FORK_URL:-}"
FORK_BRANCH="${FORK_BRANCH:-}"
FORK_SYNC_METHOD="${FORK_SYNC_METHOD:-push}"
FORK_REPO="${FORK_REPO:-$FORK_URL}"
UPSTREAM_REPO="${UPSTREAM_REPO:-$UPSTREAM_URL}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
SYNC_DATE="${SYNC_DATE:-$(date -u +%Y-%m-%d)}"
SIZE_LIMIT_MB="${SIZE_LIMIT_MB:-5000}"
DRY_RUN="${DRY_RUN:-0}"
RUN_URL="${RUN_URL:-local run}"
RETRIES="${RETRIES:-3}"
RETRY_SLEEP="${RETRY_SLEEP:-10}"

case "$FORK_SYNC_METHOD" in api|push) ;; *) err "FORK_SYNC_METHOD must be api or push"; exit 2 ;; esac

export GIT_TERMINAL_PROMPT=0
mkdir -p "$OUT_DIR/alerts"
: > "$OUT_DIR/checked.txt"
: > "$OUT_DIR/summary.md"
rm -f "$OUT_DIR"/alerts/*.json

checked() { echo "$1" >> "$OUT_DIR/checked.txt"; }
summary() { printf '%s\n' "$*" >> "$OUT_DIR/summary.md"; }

# alert <kind> <title> <body>  -> alerts/<kind>.json (issue payload, deduped by alerts.sh)
alert() {
  local kind="$1" title="$2" body="$3"
  jq -n --arg kind "$kind" --arg title "[mirror:$kind] $title" \
        --arg body "$body"$'\n\n'"Run: $RUN_URL"$'\n'"Date: $SYNC_DATE" \
        '{kind:$kind, title:$title, body:$body, labels:["mirror-alert"]}' \
        > "$OUT_DIR/alerts/$kind.json"
  log "alert raised: $kind"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git init -q --bare "$WORK/repo.git"
G=(git --git-dir="$WORK/repo.git")

# Auth: tokens go out as an http.<url>.extraheader scoped to exactly one URL, set through
# GIT_CONFIG_* env so they never show up on a command line or in a remote URL.
cfg_n=0
add_auth() {  # add_auth <url> <token>
  local url="$1" tok="$2" hdr
  [[ -n "$tok" ]] || return 0
  hdr="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$tok" | base64 -w0)"
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::add-mask::${hdr#AUTHORIZATION: basic }"
  export "GIT_CONFIG_KEY_$cfg_n=http.$url.extraheader" "GIT_CONFIG_VALUE_$cfg_n=$hdr"
  cfg_n=$((cfg_n + 1)); export GIT_CONFIG_COUNT=$cfg_n
}
add_auth "$MIRROR_URL" "${MIRROR_TOKEN:-}"
[[ -n "$FORK_URL" ]] && add_auth "$FORK_URL" "${FORK_TOKEN:-}"

# ---------------------------------------------------------------- 1. upstream reachable?
checked upstream-gone; checked upstream-empty
up_refs=""
attempt=1
while :; do
  if up_refs="$("${G[@]}" ls-remote --symref "$UPSTREAM_URL" HEAD 'refs/heads/*' 'refs/tags/*' 2>"$WORK/ls.err")"; then
    break
  fi
  why="$(cat "$WORK/ls.err")"
  if [[ "$(classify_remote_error "$why")" == gone ]]; then
    warn "upstream $UPSTREAM_REPO is gone or private; mirror left untouched"
    log "$why"
    alert upstream-gone "upstream unavailable: $UPSTREAM_REPO" \
"The scheduled sync could not read upstream \`$UPSTREAM_REPO\` (deleted, renamed away, made private, or taken down).

The mirror was **not modified**. It still holds every branch and tag from the last good sync, and it is now the only public copy.

git said:
\`\`\`
$why
\`\`\`

This issue closes itself on the first run where upstream is readable again. To stop syncing, disable the \`mirror\` workflow."
    summary "upstream gone: mirror untouched, alert raised"
    exit 0
  fi
  if (( attempt >= RETRIES )); then
    err "upstream $UPSTREAM_REPO unreachable after $attempt attempts (transient?): $why"
    exit 1
  fi
  log "ls-remote failed (attempt $attempt), retrying in ${RETRY_SLEEP}s: $why"
  sleep "$RETRY_SLEEP"; attempt=$((attempt + 1))
done

if ! grep -q $'\trefs/heads/' <<<"$up_refs"; then
  warn "upstream $UPSTREAM_REPO has no branches; refusing to treat that as 'delete everything'"
  alert upstream-empty "upstream has no branches: $UPSTREAM_REPO" \
"Upstream \`$UPSTREAM_REPO\` answered but has no branches. The mirror was left untouched.
If upstream was wiped on purpose, the mirror is now the only copy."
  summary "upstream empty: mirror untouched, alert raised"
  exit 0
fi

up_default="$(awk '$1=="ref:" && $3=="HEAD" {sub("refs/heads/","",$2); print $2}' <<<"$up_refs")"
FORK_BRANCH="${FORK_BRANCH:-$up_default}"
log "upstream default branch: ${up_default:-unknown}"

# ---------------------------------------------------------------- 2. fetch both sides
# Mirror first (our copy, full), then upstream (only the delta travels from upstream).
"${G[@]}" fetch -q --no-tags "$MIRROR_URL" \
  '+refs/heads/*:refs/mirror/heads/*' '+refs/tags/*:refs/mirror/tags/*' 2>"$WORK/fetch.err" || {
  err "cannot fetch mirror $MIRROR_URL: $(cat "$WORK/fetch.err")"; exit 1; }
"${G[@]}" fetch -q --no-tags "$UPSTREAM_URL" \
  '+refs/heads/*:refs/upstream/heads/*' '+refs/tags/*:refs/upstream/tags/*' 2>"$WORK/fetch.err" || {
  err "cannot fetch upstream $UPSTREAM_URL: $(cat "$WORK/fetch.err")"; exit 1; }

declare -A UP MI
while read -r sha ref; do UP["${ref#refs/upstream/}"]="$sha"; done \
  < <("${G[@]}" for-each-ref --format='%(objectname) %(refname)' refs/upstream/)
while read -r sha ref; do MI["${ref#refs/mirror/}"]="$sha"; done \
  < <("${G[@]}" for-each-ref --format='%(objectname) %(refname)' refs/mirror/)

is_reserved() {  # names the sync owns in the mirror; never taken from upstream
  local name="${1#heads/}"; name="${name#tags/}"
  [[ "$name" == "$MIRROR_BRANCH" || "$name" == "$GONE_PREFIX" || "$name" == "$GONE_PREFIX/"* ]]
}

# gone_name <heads|tags> <name> <old sha>: echoes the archive ref name, or nothing if this
# exact tip is already archived (dedup across runs).
gone_name() {
  local kind="$1" name="$2" old="$3" k base cand n=2 re
  re="^${kind}/${GONE_PREFIX}/$(printf '%s' "$name" | sed 's/[][\.*^$+?(){}|]/\\&/g')-[0-9]{4}-[0-9]{2}-[0-9]{2}(\.[0-9]+)?$"
  for k in "${!MI[@]}"; do
    if [[ "$k" =~ $re && "${MI[$k]}" == "$old" ]]; then return 0; fi
  done
  base="${kind}/${GONE_PREFIX}/${name}-${SYNC_DATE}"; cand="$base"
  while [[ -n "${MI[$cand]:-}" || -n "${PLANNED[$cand]:-}" ]]; do cand="$base.$n"; n=$((n + 1)); done
  echo "$cand"
}

declare -A PLANNED
ARCHIVE=()      # refspecs  <sha>:refs/<kind>/_gone/...
UPDATE=()       # refspecs  for create / fast-forward
FORCED=()       # "<ref> <old> <new>" rewritten upstream; updated with a lease after archive
RENAMED=()      # "<ref> <old>" deleted upstream; removed with a lease after archive
n_new=0 n_ff=0 n_same=0 n_skip=0

for ref in "${!UP[@]}"; do
  new="${UP[$ref]}"
  if is_reserved "$ref"; then warn "upstream ref $ref collides with a reserved mirror name; skipped"; n_skip=$((n_skip+1)); continue; fi
  old="${MI[$ref]:-}"
  if [[ -z "$old" ]]; then UPDATE+=("refs/upstream/$ref:refs/$ref"); n_new=$((n_new+1)); continue; fi
  if [[ "$old" == "$new" ]]; then n_same=$((n_same+1)); continue; fi
  if [[ "$ref" == heads/* ]] && "${G[@]}" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
    UPDATE+=("refs/upstream/$ref:refs/$ref"); n_ff=$((n_ff+1)); continue
  fi
  # Rewritten branch, or a tag that moved: archive the old tip first.
  kind="${ref%%/*}"; name="${ref#*/}"
  g="$(gone_name "$kind" "$name" "$old")"
  if [[ -n "$g" ]]; then ARCHIVE+=("$old:refs/$g"); PLANNED["$g"]=1; fi
  FORCED+=("$ref $old $new")
done

for ref in "${!MI[@]}"; do
  is_reserved "$ref" && continue
  [[ -n "${UP[$ref]:-}" ]] && continue
  old="${MI[$ref]}"; kind="${ref%%/*}"; name="${ref#*/}"
  g="$(gone_name "$kind" "$name" "$old")"
  if [[ -n "$g" ]]; then ARCHIVE+=("$old:refs/$g"); PLANNED["$g"]=1; fi
  RENAMED+=("$ref $old")
done

log "plan: ${n_new} new, ${n_ff} fast-forward, ${#FORCED[@]} rewritten, ${#RENAMED[@]} deleted upstream, ${n_same} unchanged, ${n_skip} skipped, ${#ARCHIVE[@]} archive refs"

# ---------------------------------------------------------------- 3. push to the mirror
checked push-rejected
FAILED=()
# push_refs <label> <git push args...>; batch first, then one by one so that one refused
# ref (say, a workflow file without the workflows permission) can't block the rest.
push_refs() {
  local label="$1"; shift
  local -a opts=() specs=()
  local a
  for a in "$@"; do if [[ "$a" == --* ]]; then opts+=("$a"); else specs+=("$a"); fi; done
  (( ${#specs[@]} )) || return 0
  if [[ "$DRY_RUN" == 1 ]]; then printf 'DRY-RUN push %s: %s\n' "$label" "${specs[*]}" >&2; return 0; fi
  if "${G[@]}" push --porcelain "${opts[@]}" "$MIRROR_URL" "${specs[@]}" >"$WORK/push.out" 2>"$WORK/push.err"; then
    grep -E '^[*+ -]'$'\t' "$WORK/push.out" | sed "s/^/  $label /" >&2 || true
    return 0
  fi
  log "batch push ($label) refused, retrying ref by ref: $(tr '\n' ' ' <"$WORK/push.err")"
  local s ok=0
  for s in "${specs[@]}"; do
    local dst="${s#*:}"; local -a o1=()
    for a in "${opts[@]}"; do [[ "$a" == "--force-with-lease=$dst:"* ]] && o1+=("$a"); done
    if "${G[@]}" push --porcelain "${o1[@]}" "$MIRROR_URL" "$s" >"$WORK/push1.out" 2>"$WORK/push1.err"; then
      grep -E '^[*+ -]'$'\t' "$WORK/push1.out" | sed "s/^/  $label /" >&2 || true
    else
      ok=1; FAILED+=("$dst")
      err "mirror refused $dst: $(cat "$WORK/push1.err" "$WORK/push1.out" | grep -E 'refusing|hook declined' | sed 's/^remote: //; s/[[:space:]]*$//' | head -2 | tr '\n' ' ')"
    fi
  done
  return $ok
}

push_refs archive "${ARCHIVE[@]}" || true
push_refs update "${UPDATE[@]}" || true

# Only overwrite or remove a ref once its old tip is safely archived (this run or earlier).
archived=""
if [[ "$DRY_RUN" != 1 ]] && (( ${#FORCED[@]} + ${#RENAMED[@]} )); then
  archived="$("${G[@]}" ls-remote "$MIRROR_URL" "refs/heads/${GONE_PREFIX}/*" "refs/tags/${GONE_PREFIX}/*" | awk '{print $1}')"
fi
is_archived() { [[ "$DRY_RUN" == 1 ]] || grep -qx "$1" <<<"$archived"; }
lease_opts=(); lease_specs=()
for row in "${FORCED[@]}"; do
  read -r ref old new <<<"$row"
  if is_archived "$old"; then
    lease_opts+=("--force-with-lease=refs/$ref:$old"); lease_specs+=("refs/upstream/$ref:refs/$ref")
  else
    err "not overwriting refs/$ref: old tip $old is not archived"; FAILED+=("refs/$ref")
  fi
done
for row in "${RENAMED[@]}"; do
  read -r ref old <<<"$row"
  if is_archived "$old"; then
    lease_opts+=("--force-with-lease=refs/$ref:$old"); lease_specs+=(":refs/$ref")
  else
    err "not removing refs/$ref: old tip $old is not archived"; FAILED+=("refs/$ref")
  fi
done
push_refs lease "${lease_opts[@]}" "${lease_specs[@]}" || true

for row in "${FORCED[@]}"; do read -r ref old new <<<"$row"; warn "upstream rewrote $ref: old tip $old kept under ${GONE_PREFIX}/, now $new"; done
for row in "${RENAMED[@]}"; do read -r ref old <<<"$row"; warn "upstream deleted $ref: tip $old kept under ${GONE_PREFIX}/"; done

if (( ${#FAILED[@]} )); then
  alert push-rejected "mirror push refused for ${#FAILED[@]} ref(s)" \
"These refs could not be written to the mirror:

$(printf -- '- `%s`\n' "${FAILED[@]}")

The usual cause is a credential without the **workflows** permission: GitHub refuses pushes that add or change \`.github/workflows/*\` unless the token has it. The default GITHUB_TOKEN can never have it. Check that the mirror-sync GitHub App has *Workflows: read and write* and is installed on this repo."
fi

# ---------------------------------------------------------------- 4. size and LFS notes
size_kb="$("${G[@]}" count-objects -v | awk '/^size-pack:/ {print $2}')"
size_mb=$(( (size_kb + 1023) / 1024 ))
checked oversize
if (( size_mb > SIZE_LIMIT_MB )); then
  alert oversize "mirror is ${size_mb} MB (limit ${SIZE_LIMIT_MB} MB)" \
"Packed size is ${size_mb} MB, over the ${SIZE_LIMIT_MB} MB owner limit. Anything over 5 GB needs the owner's approval. GitHub asks for repos to stay under 5 GB and refuses single pushes over 2 GB."
fi
if [[ -n "$up_default" ]] && "${G[@]}" show "refs/upstream/heads/$up_default:.gitattributes" 2>/dev/null | grep -q 'filter=lfs'; then
  echo "::notice::upstream uses Git LFS; only the pointer files are mirrored (owner rule: no LFS)" >&2
  summary "LFS: upstream uses Git LFS; pointer files only, LFS objects not mirrored"
fi

summary "mirror: ${n_new} new, ${n_ff} fast-forward, ${#FORCED[@]} rewritten (archived), ${#RENAMED[@]} deleted upstream (archived), ${n_same} unchanged, ${#FAILED[@]} refused, ${size_mb} MB packed"

# ---------------------------------------------------------------- 5. fast-forward the fork
fork_rc=0
if [[ -n "$FORK_URL" ]]; then
  checked fork-diverged; checked fork-error
  B="$FORK_BRANCH"
  up_tip="${UP[heads/$B]:-}"
  if [[ -z "$up_tip" ]]; then
    warn "upstream has no branch '$B'; fork not synced"
    alert fork-error "upstream has no branch $B" "FORK_BRANCH=\`$B\` doesn't exist upstream (\`$UPSTREAM_REPO\`). Did upstream rename its default branch? Set \`branch:\` in the caller."
  elif ! fork_line="$("${G[@]}" ls-remote "$FORK_URL" "refs/heads/$B" 2>"$WORK/fork.err")"; then
    warn "cannot read fork $FORK_REPO: $(cat "$WORK/fork.err")"
    alert fork-error "cannot read fork $FORK_REPO" "\`git ls-remote\` on the fork failed:
\`\`\`
$(cat "$WORK/fork.err")
\`\`\`"
  elif [[ -z "$fork_line" ]]; then
    warn "fork $FORK_REPO has no branch '$B'; not creating it"
    alert fork-error "fork has no branch $B" "Fork \`$FORK_REPO\` has no \`$B\` branch, so there's nothing to fast-forward. Create it from upstream once by hand."
  else
    fork_tip="${fork_line%%$'\t'*}"
    if [[ "$fork_tip" == "$up_tip" ]]; then
      log "fork $B already at upstream ($up_tip)"; summary "fork: $B up to date"
    elif "${G[@]}" cat-file -e "$fork_tip^{commit}" 2>/dev/null && "${G[@]}" merge-base --is-ancestor "$fork_tip" "$up_tip"; then
      ahead="$("${G[@]}" rev-list --count "$fork_tip..$up_tip")"
      if [[ "$DRY_RUN" == 1 ]]; then
        log "DRY-RUN fork $B: would fast-forward $fork_tip -> $up_tip ($ahead commits)"
      elif [[ "$FORK_SYNC_METHOD" == api ]]; then
        if resp="$(gh api -X POST "repos/$FORK_REPO/merge-upstream" -f branch="$B" 2>"$WORK/api.err")"; then
          mt="$(jq -r '.merge_type // "unknown"' <<<"$resp")"
          if [[ "$mt" == fast-forward || "$mt" == none ]]; then
            log "fork $B fast-forwarded via merge-upstream ($mt, $ahead commits)"; summary "fork: $B fast-forwarded $ahead commits (merge-upstream)"
          else
            warn "merge-upstream on $FORK_REPO:$B returned merge_type=$mt (expected fast-forward); check the fork"
            alert fork-diverged "merge-upstream did a $mt on $FORK_REPO:$B" "merge-upstream answered \`merge_type=$mt\`. Someone probably pushed to the fork's \`$B\` between the pre-check and the call. \`$B\` must only ever hold upstream commits; reset it by hand."
          fi
        else
          warn "merge-upstream failed for $FORK_REPO:$B: $(cat "$WORK/api.err")"
          alert fork-error "merge-upstream failed for $FORK_REPO:$B" "\`POST /repos/$FORK_REPO/merge-upstream\` failed:
\`\`\`
$(cat "$WORK/api.err")
\`\`\`
If upstream changed \`.github/workflows\`, the token needs the workflows permission."
          fork_rc=1
        fi
      else
        if "${G[@]}" push --porcelain "$FORK_URL" "$up_tip:refs/heads/$B" >"$WORK/fpush.out" 2>"$WORK/fpush.err"; then
          log "fork $B fast-forwarded $fork_tip -> $up_tip ($ahead commits)"; summary "fork: $B fast-forwarded $ahead commits (git push, no force)"
        else
          warn "fork push refused for $FORK_REPO:$B: $(tr '\n' ' ' <"$WORK/fpush.err")"
          alert fork-error "fast-forward push refused for $FORK_REPO:$B" "\`git push\` (no force) to the fork was refused:
\`\`\`
$(cat "$WORK/fpush.err")
\`\`\`
If upstream changed \`.github/workflows\`, the token needs the workflows permission."
          fork_rc=1
        fi
      fi
    else
      hint="The fork has commits that upstream doesn't. Move them to \`staging\` (or a branch), then reset \`$B\` to upstream."
      g_hit=""
      for k in "${!MI[@]}"; do [[ "$k" == heads/${GONE_PREFIX}/* && "${MI[$k]}" == "$fork_tip" ]] && g_hit="${k#heads/}"; done
      if [[ -z "$g_hit" ]] && "${G[@]}" cat-file -e "$fork_tip^{commit}" 2>/dev/null; then
        for row in "${FORCED[@]}"; do read -r ref old new <<<"$row"; [[ "$ref" == "heads/$B" ]] && "${G[@]}" merge-base --is-ancestor "$fork_tip" "$old" && g_hit="a _gone/ ref created this run"; done
      fi
      [[ -n "$g_hit" ]] && hint="Upstream force-pushed \`$B\`. The fork's tip is the old upstream tip, already archived in the mirror as $g_hit, so nothing of ours is lost. To follow upstream again, reset by hand: \`gh api -X PATCH repos/$FORK_REPO/git/refs/heads/$B -f sha=$up_tip -F force=true\`."
      warn "fork $FORK_REPO:$B has diverged from upstream (fork $fork_tip, upstream $up_tip); NOT forcing. $hint"
      alert fork-diverged "fork $FORK_REPO:$B diverged from upstream" "\`$B\` on the fork is at \`$fork_tip\`, which isn't an ancestor of upstream \`$up_tip\`. The sync **did not force** anything.

$hint"
      summary "fork: $B DIVERGED, not forced (alert raised)"
    fi
  fi
fi

[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$OUT_DIR/summary.md" >> "$GITHUB_STEP_SUMMARY"
cat "$OUT_DIR/summary.md" >&2
if (( ${#FAILED[@]} )) || (( fork_rc )); then exit 1; fi
exit 0
