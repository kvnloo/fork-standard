#!/usr/bin/env bash
# tests/test_sync.sh: offline simulation of the mirror sync with local bare repos.
#   upstream.git  stands in for the upstream GitHub repo
#   mirror.git    stands in for the detached mirror (default branch _mirror)
#   fork.git      stands in for our GitHub fork (main = upstream, staging = ours)
# A pre-receive hook on mirror.git and fork.git copies GitHub's rule that pushes adding or
# changing .github/workflows/* need the "workflows" permission (SIM_TOKEN_SCOPES).
# A fake `gh` on PATH records API calls and keeps issue state in a JSON file.
# Runs the real scripts/sync.sh, scripts/alerts.sh, scripts/keepalive.sh, scripts/onboard.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
[[ -n "${KEEP_TMP:-}" ]] && echo "tmp: $T" || trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.invalid
export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

say()  { printf '\n=== %s\n' "$*"; }
pass() { PASS=$((PASS+1)); printf '  PASS %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
eq() { [[ "$1" == "$2" ]]; }
sha() { git --git-dir="$T/$1.git" rev-parse --verify -q "$2" 2>/dev/null || echo none; }
has_ref() { git --git-dir="$T/$1.git" show-ref --verify -q "$2"; }
up_commit() {  # up_commit <branch> <file> <content> <msg>
  git -C "$T/wc" checkout -q "$1" 2>/dev/null || git -C "$T/wc" checkout -q -b "$1"
  mkdir -p "$(dirname "$T/wc/$2")"; printf '%s\n' "$3" > "$T/wc/$2"
  git -C "$T/wc" add -A && git -C "$T/wc" commit -q -m "$4"
}
up_push() { git -C "$T/wc" push -q origin "$@" 2>&1; }

# ---------------------------------------------------------------- fixtures
mkdir -p "$T/bin" "$T/gh"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: logs calls, keeps issues in $GH_FAKE_DIR/issues.json, simulates merge-upstream
S="$GH_FAKE_DIR"; echo "gh $*" >> "$S/calls.log"
[[ -f "$S/issues.json" ]] || echo '[]' > "$S/issues.json"
case "$1 $2" in
  "label create") exit 0 ;;
  "issue list") jq '[.[] | select(.state=="open") | {number,title}]' "$S/issues.json" ;;
  "issue create")
    shift 2; title=""; body=""
    while (($#)); do case "$1" in --title) title="$2"; shift;; --body-file) body="$(cat "$2")"; shift;; esac; shift; done
    n=$(( $(jq length "$S/issues.json") + 1 ))
    jq --argjson n "$n" --arg t "$title" --arg b "$body" '. + [{number:$n,title:$t,body:$b,state:"open"}]' "$S/issues.json" > "$S/i.tmp" && mv "$S/i.tmp" "$S/issues.json"
    echo "https://github.invalid/mirror/issues/$n" ;;
  "issue close")
    jq --argjson n "$3" 'map(if .number==$n then .state="closed" else . end)' "$S/issues.json" > "$S/i.tmp" && mv "$S/i.tmp" "$S/issues.json" ;;
  "api -X")
    path="$4"; branch=""; for a in "$@"; do [[ "$a" == branch=* ]] && branch="${a#branch=}"; done
    case "$path" in
      */merge-upstream)
        F="$GH_FAKE_FORK_GIT"; U="$GH_FAKE_UPSTREAM_GIT"
        new=$(git --git-dir="$U" rev-parse "refs/heads/$branch"); cur=$(git --git-dir="$F" rev-parse "refs/heads/$branch")
        git --git-dir="$F" fetch -q "$U" "refs/heads/$branch:refs/sim/up" || exit 1
        if [[ "$new" == "$cur" ]]; then echo '{"merge_type":"none"}';
        elif git --git-dir="$F" merge-base --is-ancestor "$cur" "$new"; then
          git --git-dir="$F" update-ref "refs/heads/$branch" "$new" "$cur"; echo '{"merge_type":"fast-forward"}'
        else echo 'gh: There are merge conflicts (HTTP 409)' >&2; exit 1; fi ;;
      *) echo '{}' ;;
    esac ;;
  "api repos/"*)
    case "$2" in */actions/workflows) printf '101\n102\n' ;; *) echo '{}' ;; esac ;;
  *) echo "fake gh: unsupported: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
export GH_FAKE_DIR="$T/gh" GH_FAKE_FORK_GIT="$T/fork.git" GH_FAKE_UPSTREAM_GIT="$T/upstream.git"

cat > "$T/pre-receive" <<'EOF'
#!/usr/bin/env bash
# Simulates GitHub: commits that add/change .github/workflows/* need the workflows permission.
case " ${SIM_TOKEN_SCOPES:-contents workflows} " in *" workflows "*) exit 0 ;; esac
z=0000000000000000000000000000000000000000
while read -r old new ref; do
  [[ "$new" == "$z" ]] && continue
  for c in $(git rev-list "$new" --not --all); do
    f=$(git diff-tree --no-commit-id --name-only -r --root "$c" | grep '^\.github/workflows/' | head -1)
    if [[ -n "$f" ]]; then
      echo "refusing to allow a GitHub App to create or update workflow \`$f\` without \`workflows\` permission" >&2
      exit 1
    fi
  done
done
EOF
chmod +x "$T/pre-receive"

# upstream: main (2 commits), feature, tag v0.1
git init -q --bare "$T/upstream.git"
git clone -q "$T/upstream.git" "$T/wc" 2>/dev/null
up_commit main README.md "upstream readme" "A: init"
up_commit main src/app.txt "v1" "B: app"
git -C "$T/wc" tag -a v0.1 -m v0.1
up_commit feature src/feature.txt "feat" "F1: feature"
git -C "$T/wc" checkout -q main
up_push --all >/dev/null; up_push --tags >/dev/null

# mirror: detached repo whose default branch _mirror holds only the caller + README.
# Its commit is dated 60 days back so the keepalive test has something to do.
git init -q --bare "$T/mirror.git"
git clone -q "$T/mirror.git" "$T/mwc" 2>/dev/null
git -C "$T/mwc" checkout -q -b _mirror
mkdir -p "$T/mwc/.github/workflows"
sed -e 's#{{UPSTREAM}}#up/repo#; s#{{FORK}}#kvnloo/fork#; s#{{BRANCH}}##; s#{{CRON}}#17 4 * * *#; s#{{TOOLING}}#kvnloo/fork-standard#' \
  "$ROOT/templates/caller.yml" > "$T/mwc/.github/workflows/mirror.yml"
echo "Detached mirror of up/repo" > "$T/mwc/README.md"
git -C "$T/mwc" add -A
OLD=$(( $(date -u +%s) - 60*86400 ))
GIT_AUTHOR_DATE="@$OLD +0000" GIT_COMMITTER_DATE="@$OLD +0000" git -C "$T/mwc" commit -q -m "chore: mirror workflow"
git -C "$T/mwc" push -q origin _mirror 2>/dev/null
git --git-dir="$T/mirror.git" symbolic-ref HEAD refs/heads/_mirror
MIRROR_HOME=$(sha mirror refs/heads/_mirror)

# fork: GitHub fork of upstream; main == upstream main, staging = our code
git clone -q --bare "$T/upstream.git" "$T/fork.git"
git clone -q "$T/fork.git" "$T/fwc" 2>/dev/null
git -C "$T/fwc" checkout -q -b staging
echo "our feature" > "$T/fwc/ours.txt"; git -C "$T/fwc" add -A; git -C "$T/fwc" commit -q -m "feat: ours"
git -C "$T/fwc" push -q origin staging 2>/dev/null
STAGING=$(sha fork refs/heads/staging)

cp "$T/pre-receive" "$T/mirror.git/hooks/pre-receive"
cp "$T/pre-receive" "$T/fork.git/hooks/pre-receive"

run_sync() {  # run_sync [VAR=value ...]; sets RC, output in $T/sync.log
  env UPSTREAM_URL="$T/upstream.git" MIRROR_URL="$T/mirror.git" FORK_URL="$T/fork.git" \
      FORK_REPO=kvnloo/fork UPSTREAM_REPO=up/repo OUT_DIR="$T/out" SYNC_DATE=2026-11-21 \
      RETRY_SLEEP=0 FORK_SYNC_METHOD=push PATH="$T/bin:$PATH" "$@" \
      bash "$ROOT/scripts/sync.sh" > "$T/sync.log" 2>&1
  RC=$?
  echo "  --- scripts/sync.sh exit=$RC"; sed 's/^/  | /' "$T/sync.log"
}
run_alerts() {
  env OUT_DIR="$T/out" MIRROR_REPO=kvnloo/mirror--up--repo PATH="$T/bin:$PATH" \
      bash "$ROOT/scripts/alerts.sh" > "$T/alerts.log" 2>&1
  ARC=$?
  echo "  --- scripts/alerts.sh exit=$ARC"; sed 's/^/  | /' "$T/alerts.log"
}
mirror_refs() { git --git-dir="$T/mirror.git" for-each-ref --format='%(objectname) %(refname)'; }
gone_count() { git --git-dir="$T/mirror.git" for-each-ref 'refs/heads/_gone/' 'refs/tags/_gone/' | wc -l; }
log_has() { grep -qF -- "$1" "$T/sync.log"; }

# ---------------------------------------------------------------- unit: error classification
say "unit: classify_remote_error"
# shellcheck source=/dev/null
SYNC_LIB_ONLY=1 source "$ROOT/scripts/sync.sh"
set +e +u   # sourcing sync.sh turned on its strict mode; the harness checks exit codes itself
set -u
for s in "remote: Repository not found." "fatal: could not read Username for 'https://github.com': terminal prompts disabled" \
         "fatal: '/x/upstream.git' does not appear to be a git repository" "The requested URL returned error: 451"; do
  check "gone:      $s" eq "$(classify_remote_error "$s")" gone
done
for s in "fatal: unable to access: Could not resolve host: github.com" "The requested URL returned error: 502" "Connection refused"; do
  check "transient: $s" eq "$(classify_remote_error "$s")" transient
done

# ---------------------------------------------------------------- case 1
say "case 1: new upstream commits are mirrored and fork main is fast-forwarded"
echo "  initial sync into an empty mirror:"
run_sync
check "initial sync exit 0" eq "$RC" 0
check "mirror main == upstream main" eq "$(sha mirror refs/heads/main)" "$(sha upstream refs/heads/main)"
check "mirror feature + tag v0.1 present" eval 'has_ref mirror refs/heads/feature && has_ref mirror refs/tags/v0.1'
up_commit main src/app.txt "v2" "C: app v2"
up_commit main src/more.txt "more" "D: more"
git -C "$T/wc" tag -a v1.0 -m v1.0
up_commit topic src/topic.txt "topic" "T1: topic"
up_commit _mirror evil.txt "x" "upstream branch that collides with our reserved name"
git -C "$T/wc" checkout -q main
up_push --all >/dev/null; up_push --tags >/dev/null
FORK_BEFORE=$(sha fork refs/heads/main)
echo "  upstream: +2 commits on main, new branch topic, new tag v1.0, branch named _mirror; fork main at ${FORK_BEFORE:0:7}"
run_sync
check "exit 0" eq "$RC" 0
check "mirror main == upstream main ($(sha upstream refs/heads/main | cut -c1-7))" eq "$(sha mirror refs/heads/main)" "$(sha upstream refs/heads/main)"
check "mirror got branch topic and tag v1.0" eval 'has_ref mirror refs/heads/topic && has_ref mirror refs/tags/v1.0'
check "fork main fast-forwarded to upstream main" eq "$(sha fork refs/heads/main)" "$(sha upstream refs/heads/main)"
check "fork main moved by fast-forward (old tip is ancestor)" git --git-dir="$T/fork.git" merge-base --is-ancestor "$FORK_BEFORE" refs/heads/main
check "fork staging untouched" eq "$(sha fork refs/heads/staging)" "$STAGING"
check "mirror _mirror untouched (upstream _mirror branch skipped)" eq "$(sha mirror refs/heads/_mirror)" "$MIRROR_HOME"
check "collision warning printed" log_has "collides with a reserved mirror name"
check "no _gone refs created" eq "$(gone_count)" 0
echo "  re-run with nothing new (idempotence):"
run_sync
check "re-run exit 0" eq "$RC" 0
check "re-run: 0 new, 0 fast-forward" log_has "mirror: 0 new, 0 fast-forward, 0 rewritten"
check "re-run: fork up to date" log_has "fork: main up to date"
up_push --delete _mirror >/dev/null
run_sync >/dev/null
check "upstream deleting its _mirror branch does not touch ours" eq "$(sha mirror refs/heads/_mirror)" "$MIRROR_HOME"

say "case 1b: same fast-forward through the merge-upstream API path (FORK_SYNC_METHOD=api)"
up_commit main src/e.txt "e" "E: e"; up_push main >/dev/null
: > "$T/gh/calls.log"
run_sync FORK_SYNC_METHOD=api
check "exit 0" eq "$RC" 0
check "gh api -X POST repos/kvnloo/fork/merge-upstream -f branch=main was called" grep -qF "gh api -X POST repos/kvnloo/fork/merge-upstream -f branch=main" "$T/gh/calls.log"
check "fork main == upstream main" eq "$(sha fork refs/heads/main)" "$(sha upstream refs/heads/main)"
echo "  fake gh call log:"; sed 's/^/  | /' "$T/gh/calls.log"

# ---------------------------------------------------------------- case 2
say "case 2: upstream commit touching .github/workflows"
MAIN_BEFORE=$(sha mirror refs/heads/main)
up_commit main .github/workflows/ci.yml "on: push" "W: add upstream CI workflow"
up_commit feature src/feature.txt "feat v2" "F2: feature v2 (no workflow change)"
git -C "$T/wc" checkout -q main; up_push --all >/dev/null
echo "  2a: token WITHOUT the workflows permission (what GITHUB_TOKEN gets):"
run_sync SIM_TOKEN_SCOPES=contents
check "exit 1 (refused refs are a real failure)" eq "$RC" 1
check "clear error names the refused ref" log_has "::error::mirror refused refs/heads/main"
check "GitHub's workflows-permission message surfaced" log_has "without \`workflows\` permission"
check "push-rejected alert payload written" test -f "$T/out/alerts/push-rejected.json"
check "mirror main NOT changed" eq "$(sha mirror refs/heads/main)" "$MAIN_BEFORE"
check "other refs still synced (feature updated, ref-by-ref fallback)" eq "$(sha mirror refs/heads/feature)" "$(sha upstream refs/heads/feature)"
check "fork main not moved; fork-error alert" eval '[[ $(sha fork refs/heads/main) == '"$MAIN_BEFORE"' && -f $T/out/alerts/fork-error.json ]]'
echo "  push-rejected payload:"; jq . "$T/out/alerts/push-rejected.json" | sed 's/^/  | /'
echo "  2b: token WITH the workflows permission (GitHub App with workflows:write):"
run_sync SIM_TOKEN_SCOPES="contents workflows"
check "exit 0" eq "$RC" 0
check "mirror main == upstream main" eq "$(sha mirror refs/heads/main)" "$(sha upstream refs/heads/main)"
check "mirror main contains .github/workflows/ci.yml" git --git-dir="$T/mirror.git" cat-file -e refs/heads/main:.github/workflows/ci.yml
check "fork main fast-forwarded" eq "$(sha fork refs/heads/main)" "$(sha upstream refs/heads/main)"
check "no push-rejected alert, and the kind is marked checked (so alerts.sh closes the issue)" eval '[[ ! -f $T/out/alerts/push-rejected.json ]] && grep -qx push-rejected $T/out/checked.txt'
check "mirror default branch tree is still only README + our caller" eq "$(git --git-dir="$T/mirror.git" ls-tree -r --name-only HEAD | tr '\n' ' ')" ".github/workflows/mirror.yml README.md "

# ---------------------------------------------------------------- case 3
say "case 3: upstream force-push (and a deleted branch, and a moved tag)"
OLD_MAIN=$(sha upstream refs/heads/main); OLD_TOPIC=$(sha upstream refs/heads/topic); OLD_TAG=$(sha upstream refs/tags/v1.0)
git -C "$T/wc" reset -q --hard HEAD~2
up_commit main src/rewrite.txt "rewritten" "X: rewritten history"
git -C "$T/wc" tag -f -a v1.0 -m "v1.0 moved" >/dev/null
up_push --force main >/dev/null; up_push --force v1.0 >/dev/null; up_push --delete topic >/dev/null
FORK_TIP=$(sha fork refs/heads/main)
echo "  upstream: main force-pushed (${OLD_MAIN:0:7} -> $(sha upstream refs/heads/main | cut -c1-7)), topic deleted, tag v1.0 moved"
run_sync SYNC_DATE=2026-11-22
check "exit 0" eq "$RC" 0
check "old main tip kept at refs/heads/_gone/main-2026-11-22" eq "$(sha mirror refs/heads/_gone/main-2026-11-22)" "$OLD_MAIN"
check "mirror main now == rewritten upstream main" eq "$(sha mirror refs/heads/main)" "$(sha upstream refs/heads/main)"
check "deleted branch kept at refs/heads/_gone/topic-2026-11-22" eq "$(sha mirror refs/heads/_gone/topic-2026-11-22)" "$OLD_TOPIC"
check "deleted branch name renamed away (mirror heads track upstream)" eval '! has_ref mirror refs/heads/topic'
check "moved tag: old kept at refs/tags/_gone/v1.0-2026-11-22" eq "$(sha mirror refs/tags/_gone/v1.0-2026-11-22)" "$OLD_TAG"
check "moved tag updated" eq "$(sha mirror refs/tags/v1.0)" "$(sha upstream refs/tags/v1.0)"
check "warning names the rewrite" log_has "::warning::upstream rewrote heads/main"
check "fork main NOT forced (still old upstream tip)" eq "$(sha fork refs/heads/main)" "$FORK_TIP"
check "fork warning explains it was an upstream force-push" log_has "Upstream force-pushed \`main\`"
GONE_N=$(gone_count)
echo "  re-run the same day (dedup):"
run_sync SYNC_DATE=2026-11-22
check "re-run exit 0, no new _gone refs ($GONE_N)" eval '[[ $RC == 0 && $(gone_count) == '"$GONE_N"' ]]'
echo "  second force-push on the same day:"
OLD2=$(sha upstream refs/heads/main)
git -C "$T/wc" commit -q --amend -m "X': amended again"; up_push --force main >/dev/null
run_sync SYNC_DATE=2026-11-22
check "same-day collision gets suffix: _gone/main-2026-11-22.2" eq "$(sha mirror refs/heads/_gone/main-2026-11-22.2)" "$OLD2"
echo "  mirror refs now:"; mirror_refs | sed 's/^/  | /'
# Kevin's manual fix after an upstream rewrite: reset fork main to upstream.
git --git-dir="$T/fork.git" fetch -q "$T/upstream.git" "+refs/heads/main:refs/heads/main"

# ---------------------------------------------------------------- case 4
say "case 4: upstream deleted (or made private)"
mirror_refs > "$T/refs.before"
FORK_TIP=$(sha fork refs/heads/main)
mv "$T/upstream.git" "$T/upstream.git.away"
run_sync
check "exit 0 (job stays green)" eq "$RC" 0
check "mirror refs byte-identical before/after" cmp -s "$T/refs.before" <(mirror_refs)
check "upstream-gone alert payload written" test -f "$T/out/alerts/upstream-gone.json"
check "fork untouched" eq "$(sha fork refs/heads/main)" "$FORK_TIP"
check "stopped before the fork step (fork kinds not checked)" eval '! grep -q fork- $T/out/checked.txt'
echo "  issue payload:"; jq . "$T/out/alerts/upstream-gone.json" | sed 's/^/  | /'
: > "$T/gh/calls.log"; echo '[]' > "$T/gh/issues.json"
run_alerts
check "alerts.sh opened one issue" eq "$(jq '[.[]|select(.state=="open")]|length' "$T/gh/issues.json")" 1
echo "  next scheduled run, upstream still gone:"
run_sync >/dev/null; run_alerts
check "dedup: still exactly one issue, no second create" eval '[[ $(jq length $T/gh/issues.json) == 1 && $(grep -c "issue create" $T/gh/calls.log) == 1 ]]'
check "dedup message printed" grep -qF "already open as #1" "$T/alerts.log"
echo "  upstream comes back:"
mv "$T/upstream.git.away" "$T/upstream.git"
run_sync >/dev/null; run_alerts
check "issue auto-closed when upstream is readable again" eq "$(jq -r '.[0].state' "$T/gh/issues.json")" closed
echo "  fake gh call log:"; sed 's/^/  | /' "$T/gh/calls.log"

say "case 4b: unreachable for a non-gone reason (network) is NOT reported as gone"
run_sync UPSTREAM_URL="http://127.0.0.1:9/nothing.git" RETRIES=2
check "exit 1 after retries" eq "$RC" 1
check "no upstream-gone alert" test ! -f "$T/out/alerts/upstream-gone.json"

# ---------------------------------------------------------------- case 5
say "case 5: fork main diverged (someone committed on the fork's main)"
git -C "$T/fwc" fetch -q origin && git -C "$T/fwc" checkout -q -B main origin/main
echo oops > "$T/fwc/oops.txt"; git -C "$T/fwc" add -A; git -C "$T/fwc" commit -q -m "oops: committed on main"
git -C "$T/fwc" push -q origin main 2>/dev/null
DIVERGED=$(sha fork refs/heads/main)
up_commit main src/g.txt "g" "G: upstream moves on"; up_push main >/dev/null
run_sync
check "exit 0 (mirror fine; fork problem is an alert, not a red job)" eq "$RC" 0
check "mirror main still updated" eq "$(sha mirror refs/heads/main)" "$(sha upstream refs/heads/main)"
check "fork main NOT forced (still the diverged commit)" eq "$(sha fork refs/heads/main)" "$DIVERGED"
check "clear warning printed" log_has "has diverged from upstream"
check "warning says nothing was forced" log_has "NOT forcing"
check "fork-diverged alert payload written" test -f "$T/out/alerts/fork-diverged.json"
echo "  api method on the same diverged fork:"
: > "$T/gh/calls.log"
run_sync FORK_SYNC_METHOD=api
check "api method: merge-upstream NOT called (it could create a merge commit)" eval '! grep -q merge-upstream $T/gh/calls.log'
check "api method: fork main still the diverged commit" eq "$(sha fork refs/heads/main)" "$DIVERGED"

# ---------------------------------------------------------------- keepalive
say "keepalive: 60-day schedule auto-disable"
run_keep() { env MIRROR_URL="$T/mirror.git" KEEPALIVE_DAYS=45 bash "$ROOT/scripts/keepalive.sh" > "$T/keep.log" 2>&1; KRC=$?; sed 's/^/  | /' "$T/keep.log"; }
run_keep
check "keepalive exit 0" eq "$KRC" 0
check "_mirror got an empty fast-forward commit (parent = old tip)" eq "$(sha mirror refs/heads/_mirror^)" "$MIRROR_HOME"
check "tree unchanged" eq "$(sha mirror 'refs/heads/_mirror^{tree}')" "$(sha mirror "$MIRROR_HOME^{tree}")"
K1=$(sha mirror refs/heads/_mirror)
run_keep
check "second run: recent commit, nothing pushed" eq "$(sha mirror refs/heads/_mirror)" "$K1"
echo "  GitHub mode (fake gh): re-enable our workflow, disable upstream workflow files that ran here:"
: > "$T/gh/calls.log"
env MIRROR_URL="$T/mirror.git" MIRROR_REPO=kvnloo/mirror--up--repo WORKFLOW_FILE=mirror.yml GH_TOKEN=fake PATH="$T/bin:$PATH" \
  bash "$ROOT/scripts/keepalive.sh" > "$T/keep.log" 2>&1; KRC=$?; sed 's/^/  | /' "$T/keep.log"
check "housekeeping exit 0" eq "$KRC" 0
check "enable API called for mirror.yml" grep -qF "actions/workflows/mirror.yml/enable" "$T/gh/calls.log"
check "foreign workflows 101 and 102 disabled" eval 'grep -qF "actions/workflows/101/disable" $T/gh/calls.log && grep -qF "actions/workflows/102/disable" $T/gh/calls.log'

# ---------------------------------------------------------------- onboarding
say "onboard.sh (dry run, offline)"
env PATH="$T/bin:$PATH" bash "$ROOT/scripts/onboard.sh" kvnloo/hermex --upstream uzairansaruzi/hermex --branch master --size-kb 57608 > "$T/onb.log" 2>&1; ORC=$?
sed 's/^/  | /' "$T/onb.log"
check "onboard exit 0" eq "$ORC" 0
check "dry run: nothing executed (no gh calls)" eval '! grep -q "repo create" $T/gh/calls.log'
check "prints the repo create command" grep -qF "gh repo create kvnloo/mirror--uzairansaruzi--hermex --public" "$T/onb.log"
awk '/^----- BEGIN caller/{f=1;next}/^----- END caller/{f=0}f' "$T/onb.log" > "$T/caller.yml"
check "rendered caller parses as YAML" python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert d['jobs']['sync']['with']['upstream']=='uzairansaruzi/hermex'" "$T/caller.yml"
check "rendered caller is <= 15 lines" eval '(( $(grep -cv "^\s*\(#.*\)\?$" $T/caller.yml) <= 15 ))'
env bash "$ROOT/scripts/onboard.sh" kvnloo/big --upstream someone/huge --branch main --size-kb 7000000 > "$T/onb2.log" 2>&1; ORC2=$?
check "over 5 GB refused without --allow-large (exit $ORC2)" eval '[[ '"$ORC2"' != 0 ]] && grep -q "owner approval" $T/onb2.log'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
