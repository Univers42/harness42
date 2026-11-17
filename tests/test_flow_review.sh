#!/usr/bin/env bash
# test_flow_review.sh - the flow's one LLM step: prompt, call, verdict, policy, report.
#
# `claude` is a fake first on PATH whose reply is picked by FAKE_CLAUDE, so no case
# touches the network or spends a token. What is under test is everything around the
# model: what it is shown, how it is called, and what code makes of its answer.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok() {
  echo "ok   - $1"
  PASS=$((PASS + 1))
}
no() {
  echo "FAIL - $1"
  FAIL=$((FAIL + 1))
}

TMP="$(mktemp -d)"
trap 'kill ${SRV:-} 2>/dev/null; rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset ANTHROPIC_API_KEY

HOST="$TMP/host"
mkdir -p "$HOST"
git -C "$HOST" init -q -b main
printf 'a\n' >"$HOST/a.txt"
git -C "$HOST" add -A && git -C "$HOST" commit -qm base
printf 'a2\n' >>"$HOST/a.txt"
RUNS="$HOST/.claude/cache/runs"
FLOWS="$HOST/.claude/flows"
mkdir -p "$FLOWS"

# The fake records its argv (NUL-separated) and stdin, then answers per FAKE_CLAUDE.
FAKE="$TMP/fake"
mkdir -p "$TMP/bin" "$FAKE" "$TMP/nobin"
cat >"$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >"$FAKE_DIR/argv"
printf '%s\n' "${ANTHROPIC_BASE_URL:-}" "${ANTHROPIC_CUSTOM_HEADERS:-}" \
  "betas-off=${CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS:-}" >"$FAKE_DIR/env"
cat >"$FAKE_DIR/stdin"
ok='"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.0123'
clean='"summary":"fine","checked":"inputs and paths"'
case "${FAKE_CLAUDE:-approve}" in
approve) echo "{$ok,\"structured_output\":{\"verdict\":\"APPROVE\",$clean,\"findings\":[]}}" ;;
blocker)
  f='{"area":"standards","severity":"BLOCKER","file":"a.txt","line":2,"finding":"breaks it","fix":"revert"}'
  echo "{$ok,\"structured_output\":{\"verdict\":\"APPROVE\",$clean,\"findings\":[$f]}}"
  ;;
nostruct) echo "{$ok,\"result\":\"plain text\"}" ;;
iserror) echo '{"subtype":"error_max_budget_usd","is_error":true,"result":"over budget","total_cost_usd":3.01}' ;;
badenum) echo "{$ok,\"structured_output\":{\"verdict\":\"LGTM\",$clean,\"findings\":[]}}" ;;
notjson)
  echo boom >&2
  exit 1
  ;;
esac
EOF
chmod +x "$TMP/bin/claude"
export FAKE_DIR="$FAKE" PATH="$TMP/bin:$PATH"

FLOW="$ROOT/tools/flow.sh"
flow() { (cd "$HOST" && bash "$FLOW" "$@"); }
newest() { find "$RUNS" -mindepth 1 -maxdepth 1 -type d -name '2*' | sort | tail -1; }
review() { # review MODE: run the kit's review flow with that fake reply; sets rc and run
  rm -f "$FAKE/argv" "$FAKE/stdin"
  FAKE_CLAUDE="$1" flow run review --base main >"$TMP/out" 2>"$TMP/err"
  rc=$?
  run="$(newest)"
}
argv() { tr '\0' '\n' <"$FAKE/argv"; }

# --- the happy path, and what the model is shown ---------------------------------
printf 'The change must append a line to a.txt.\n' >"$TMP/spec.md"
rm -f "$FAKE/argv"
FAKE_CLAUDE=approve flow run review --base main --spec "$TMP/spec.md" >"$TMP/out" 2>"$TMP/err"
rc=$?
run="$(newest)"
if [ "$rc" -eq 0 ] && grep -q '^status: done' "$TMP/out" &&
  jq -e '.review.verdict == "APPROVE" and .review.cost == {source: "client", usd: 0.0123} and .review.status == "PASS"' \
    "$run/report.json" >/dev/null && [ -f "$run/review/review.json" ]; then
  ok "APPROVE: exit 0, status done, verdict and cost in report.json"
else no "approve: rc=$rc $(tail -3 "$TMP/err")"; fi

nonce="$(sed -n 's/.*=== BEGIN diff.patch \([0-9a-f]*\) ===.*/\1/p' "$FAKE/stdin")"
if [ "${#nonce}" -eq 24 ] && grep -qx "=== END diff.patch $nonce ===" "$FAKE/stdin" &&
  grep -q '^+a2$' "$FAKE/stdin" && grep -q 'must append a line' "$FAKE/stdin" &&
  cmp -s "$FAKE/stdin" "$run/review/prompt.md"; then
  ok "the prompt fences the diff and the spec with a per-run nonce, and is kept"
else no "prompt: nonce='$nonce'"; fi

if argv | grep -qx 'You are the last reader before the merge. You are not a linter — the linter already' &&
  argv | grep -qx 'You attack the code with the source in front of you. You do not guess at the attack' &&
  ! argv | grep -qx 'model: opus'; then
  ok "the system prompt carries both rubric bodies, without their frontmatter"
else no "system prompt: $(argv | grep -c .) argv lines"; fi

if argv | grep -qx -- '--tools' && tr '\0' '\n' <"$FAKE/argv" | grep -A1 -x -- '--tools' | sed -n 2p | grep -qx '' &&
  argv | grep -qx -- '--json-schema' && argv | grep -qx 'mcp__\*' &&
  argv | grep -qx -- '--no-session-persistence' && argv | grep -qx -- '--setting-sources' &&
  ! argv | grep -qx -- '--bare'; then
  ok 'the call has --tools "" and no --bare when no API key is set'
else no "argv: $(argv | grep -- '^--' | tr '\n' ' ')"; fi

rm -f "$FAKE/argv"
(cd "$HOST" && ANTHROPIC_API_KEY=planted-not-real bash "$FLOW" run review --base main) >"$TMP/out" 2>&1
if argv | grep -qx -- '--bare' && ! argv | grep -qx -- '--setting-sources' &&
  ! grep -rq planted-not-real "$TMP/out" "$(newest)"; then
  ok "with an API key the call is --bare, and the key is written nowhere"
else no "api key path: $(argv | grep -- '^--' | tr '\n' ' ')"; fi

# --- code has the last word ---------------------------------------------------------
review blocker
if [ "$rc" -eq 1 ] && jq -e '.review.verdict == "CHANGES_REQUESTED"' "$run/report.json" >/dev/null &&
  grep -q '^next: review asked for changes: BLOCKER a.txt:2 breaks it' "$TMP/out" &&
  grep -q '^| BLOCKER | a.txt:2 | breaks it | revert |' "$run/report.md"; then
  ok "a BLOCKER under an APPROVE is CHANGES_REQUESTED: exit 1, named in next and report.md"
else no "blocker: rc=$rc $(grep '^next' "$TMP/out")"; fi

for mode in nostruct iserror badenum notjson; do
  review "$mode"
  if [ "$rc" -eq 3 ] && grep -q '^next: review gave no verdict (.*fall back to the reviewer and security agents' "$TMP/out" &&
    jq -e '.review.status == "ERROR" and .exit == 3' "$run/report.json" >/dev/null; then
    ok "$mode: no verdict is exit 3, and next says to fall back to the agents"
  else no "$mode: rc=$rc $(grep '^next' "$TMP/out")"; fi
  if [ "$mode" = iserror ]; then
    if jq -e '.review.cost.usd == 3.01' "$run/report.json" >/dev/null; then
      ok "a call that ended in error still records what it cost"
    else no "the iserror run lost its cost"; fi
  fi
done

(cd "$HOST" && PATH="$TMP/nobin:/usr/bin:/bin" bash "$FLOW" run review --base main) >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 3 ] && grep -q 'claude is not on PATH' "$TMP/out"; then
  ok "no claude on PATH is exit 3, not a pass"
else no "no claude: rc=$rc"; fi

# --- a diff over max_diff_bytes is cut by whole files, and the cut is reported ------
cat >"$FLOWS/small.toml" <<'EOF'
description = "review with a small diff cap"
[[step]]
name = "diff"
type = "run"
run = 'devil orch diff ${FLOW_BASE:+--base "$FLOW_BASE"} "$FLOW_OUT"'
[[step]]
name = "review"
type = "review"
max_diff_bytes = 1000
EOF
head -c 3000 /dev/zero | tr '\0' 'x' | fold -w 60 >"$HOST/big.txt"
rm -f "$FAKE/stdin"
FAKE_CLAUDE=approve flow run small --base main >"$TMP/out" 2>&1
rc=$?
run="$(newest)"
if [ "$rc" -eq 0 ] && grep -q '^+a2$' "$FAKE/stdin" && ! grep -q '^+xxxx' "$FAKE/stdin" &&
  grep -q '^Left out, over max_diff_bytes (do not guess): big.txt' "$FAKE/stdin" &&
  jq -e '.review.findings[-1] | .severity == "MAJOR" and .file == "big.txt"' "$run/report.json" >/dev/null &&
  grep -q '^deviations: not reviewed (over max_diff_bytes): big.txt' "$TMP/out"; then
  ok "an oversized file is left out whole, named to the model, as a MAJOR and in deviations"
else no "truncation: rc=$rc $(grep '^deviations' "$TMP/out")"; fi
rm -f "$HOST/big.txt"

# --- the review never runs when it has nothing green to judge ----------------------
cat >"$FLOWS/red.toml" <<'EOF'
description = "a failing gate before the review"
[[step]]
name = "lint"
type = "run"
run = "exit 1"
[[step]]
name = "review"
type = "review"
EOF
rm -f "$FAKE/argv"
FAKE_CLAUDE=approve flow run red >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && [ ! -e "$FAKE/argv" ] && grep -q '^- review → skipped' "$TMP/out" &&
  jq -e '.review == null' "$(newest)/report.json" >/dev/null; then
  ok "a red gate skips the review: claude is never called"
else no "red: rc=$rc"; fi

rm -f "$FAKE/argv"
if flow run gate --dry-run >"$TMP/out" 2>&1 && [ ! -e "$FAKE/argv" ] &&
  grep -q 'claude -p --model opus, budget \$3, no tools' "$TMP/out"; then
  ok "--dry-run shows the review and never calls claude"
else no "dry run: $(tail -2 "$TMP/out")"; fi

# --- check refuses every review the runner could not trust --------------------------
bad() { # bad NAME TOML-AFTER-THE-DIFF-STEP
  printf 'description = "x"\n[[step]]\nname = "d"\ntype = "run"\nrun = "true"\n%s\n' "$2" >"$FLOWS/$1.toml"
}
bad r-notlast $'[[step]]\nname = "r"\ntype = "review"\n[[step]]\nname = "after"\ntype = "run"\nrun = "true"'
bad r-two $'[[step]]\nname = "r1"\ntype = "review"\n[[step]]\nname = "r2"\ntype = "review"'
bad r-escape $'[[step]]\nname = "r"\ntype = "review"\nrubric = ["../../../../etc/passwd"]'
bad r-abs $'[[step]]\nname = "r"\ntype = "review"\nrubric = ["/etc/passwd"]'
bad r-missing $'[[step]]\nname = "r"\ntype = "review"\nrubric = ["agents/nosuch.md"]'
bad r-model $'[[step]]\nname = "r"\ntype = "review"\nmodel = "opus; rm -rf /"'
bad r-route $'[[step]]\nname = "r"\ntype = "review"\nroute = "x $(id)"'
bad r-budget $'[[step]]\nname = "r"\ntype = "review"\nbudget_usd = 500'
bad r-bool $'[[step]]\nname = "r"\ntype = "review"\nbudget_usd = true'
bad r-run $'[[step]]\nname = "r"\ntype = "review"\nrun = "echo hi"'
bad r-short $'[[step]]\nname = "r"\ntype = "review"\ntimeout = 5'
for f in r-notlast r-two r-escape r-abs r-missing r-model r-route r-budget r-bool r-run r-short; do
  if flow check "$f" >/dev/null 2>&1; then no "check accepted $f"; else ok "check refuses $f"; fi
done
rm -f "$FLOWS"/r-*.toml
if flow check gate review >/dev/null 2>&1; then ok "check passes the shipped gate and review flows"; else no "shipped flows fail check"; fi

# --- routed through Switchyard (`devil route on`): the route, the tags, its cost ------
# A real http.server on a free loopback port stands in for Switchyard; it ignores the
# query string, so v1/routing/session-stats is one file.
P="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
WWW="$TMP/www"
mkdir -p "$WWW/v1/routing" && touch "$WWW/health"
echo '{"data":[{"id":"devil-review"},{"id":"my-review"}]}' >"$WWW/v1/models"
priced='"cost":{"known_usd":0.21,"unknown_calls":0,"total_usd":0.21},"calls":1,"prompt_tokens":1200,"completion_tokens":300'
unpriced='"cost":{"known_usd":0,"unknown_calls":1,"total_usd":null},"calls":2,"prompt_tokens":50,"completion_tokens":5'
printf '{"cost":{"known_usd":0.21,"unknown_calls":1,"total_usd":null},"models":{"claude-opus-5-5":{%s},"odd|model":{%s}}}\n' \
  "$priced" "$unpriced" >"$WWW/v1/routing/session-stats"
printf '{"_devilRoute":{"set":{}},"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:%s"}}\n' "$P" >"$HOST/.claude/settings.local.json"
python3 -m http.server --bind 127.0.0.1 --directory "$WWW" "$P" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 50); do curl -fs "http://127.0.0.1:$P/health" >/dev/null && break || sleep 0.1; done

review approve
sid="devil-flow-$(basename "$run")"
if [ "$rc" -eq 0 ] && argv | grep -A1 -x -- '--model' | sed -n 2p | grep -qx devil-review &&
  [ "$(sed -n 1p "$FAKE/env")" = "http://127.0.0.1:$P" ] &&
  grep -qx "x-switchyard-session-id: $sid" "$FAKE/env" && grep -qx 'x-switchyard-origin: devil-flow' "$FAKE/env" &&
  grep -qx 'betas-off=1' "$FAKE/env"; then
  ok "a routed review goes to the devil-review route, tagged, with the betas Switchyard drops off"
else no "routed call: rc=$rc $(tr '\n' ' ' <"$FAKE/env")"; fi
if jq -e --arg s "$sid" '.review.model == "devil-review" and (.review.cost | .source == "switchyard" and
  .session == $s and .usd == null and .known_usd == 0.21 and .unknown_calls == 1 and (.models | length) == 2)' \
  "$run/report.json" >/dev/null &&
  grep -qF 'Total unknown, 1 call(s) unpriced (priced subtotal $0.2100)' "$run/report.md" &&
  grep -qxF '| claude-opus-5-5 | 1 | 1200 | 300 | $0.2100 |' "$run/report.md" &&
  grep -qxF '| odd\|model | 2 | 50 | 5 | unpriced |' "$run/report.md"; then
  ok "the cost is Switchyard's, per model; an unpriced call leaves the total unknown"
else no "routed cost: $(jq -c .review.cost "$run/report.json")"; fi

if flow run review --dry-run >"$TMP/out" 2>&1 &&
  grep -qF "claude -p --model devil-review (Switchyard at http://127.0.0.1:$P), budget" "$TMP/out"; then
  ok "--dry-run of a routed project shows the route and the proxy"
else no "routed dry run: $(grep 'claude -p' "$TMP/out")"; fi

sed 's/^type = "review"$/&\nroute = "my-review"/' "$ROOT/flows/review.toml" >"$FLOWS/review.toml"
review approve
if [ "$rc" -eq 0 ] && argv | grep -A1 -x -- '--model' | sed -n 2p | grep -qx my-review; then
  ok "a host flow's review route is the one called"
else no "custom route: rc=$rc"; fi
sed -i 's/^route = "my-review"$/route = "nosuch"/' "$FLOWS/review.toml"
review approve
if [ "$rc" -eq 3 ] && [ ! -e "$FAKE/argv" ] && grep -q "^next: .*serves no route nosuch" "$TMP/out"; then
  ok "a route the proxy does not serve is exit 3 before any call"
else no "missing route: rc=$rc $(grep '^next' "$TMP/out")"; fi
rm "$FLOWS/review.toml"

rm "$WWW/v1/routing/session-stats"
review approve
if [ "$rc" -eq 0 ] && jq -e '.review.cost | .source == "client" and .usd == 0.0123 and
  (.note | test("has no record of session devil-flow-"))' "$run/report.json" >/dev/null; then
  ok "no record in Switchyard falls back to the client estimate, and says so"
else no "stats fallback: $(jq -c .review.cost "$run/report.json")"; fi

kill "$SRV" && wait "$SRV" 2>/dev/null
review approve
if [ "$rc" -eq 3 ] && [ ! -e "$FAKE/argv" ] &&
  grep -q "^next: review gave no verdict (this project routes through Switchyard at http://127.0.0.1:$P, which is down" "$TMP/out"; then
  ok "routed with the proxy down is exit 3 before any call, and names the fix"
else no "routed down: rc=$rc $(grep '^next' "$TMP/out")"; fi
rm "$HOST/.claude/settings.local.json"

# --- the call kills claude's whole process group when it runs past its timeout ------
(cd "$TMP" && FLOW_ROOT="$TMP" python3 -I -B -c '
import os, sys
sys.path.insert(0, sys.argv[1])
import flow_review
cmd = ["bash", "-c", "sleep 300 & echo $! >" + sys.argv[2] + "; wait"]
rc, out, err = flow_review.call(cmd, "", dict(os.environ), 1)
sys.exit(0 if rc is None else 1)
' "$ROOT/tools/lib" "$TMP/child.pid")
rc=$?
child="$(cat "$TMP/child.pid" 2>/dev/null)"
for _ in 1 2 3 4 5 6 7 8 9 10; do # a killed orphan is gone once init reaps it
  kill -0 "${child:-0}" 2>/dev/null || break
  sleep 0.1
done
if [ "$rc" -eq 0 ] && [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null; then
  ok "a timed-out call is killed with everything it started"
else no "timeout kill: rc=$rc"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
