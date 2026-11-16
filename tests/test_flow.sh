#!/usr/bin/env bash
# test_flow.sh - the code-run gate: diff.sh, the flow runner, the single review.
#
# A flow is the workflow an agent used to re-derive every run (diff -> tests ->
# lint -> review -> report), written once and run by code. Every case here runs
# against a throwaway git repo; `claude` is a fake on PATH, so nothing touches
# the network or spends a token.
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
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# A host repo: one commit on main, then a feature branch with a committed
# change, an unstaged edit, an untracked file, an ignored file and run cache.
HOST="$TMP/host"
mkdir -p "$HOST"
git -C "$HOST" init -q -b main
printf 'a\n' >"$HOST/a.txt"
printf 'cache/\n*.log\n' >"$HOST/.gitignore"
git -C "$HOST" add -A && git -C "$HOST" commit -qm base
git -C "$HOST" switch -qc feat
printf 'b\n' >"$HOST/b.txt"
git -C "$HOST" add b.txt && git -C "$HOST" commit -qm b
printf 'a2\n' >>"$HOST/a.txt"
printf 'new\n' >"$HOST/new file.txt"
printf 'noise\n' >"$HOST/x.log"
mkdir -p "$HOST/.claude/cache/runs" && printf 'run\n' >"$HOST/.claude/cache/runs/r.txt"

# --- diff.sh ------------------------------------------------------------------
DIFF="$ROOT/tools/orch/diff.sh"
(cd "$HOST" && bash "$DIFF" --base main "$TMP/d1" >/dev/null 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then ok "diff.sh exits 0"; else no "diff.sh exited $rc"; fi
if [ "$(sort "$TMP/d1/changed.txt" | tr '\n' ,)" = 'a.txt,b.txt,new file.txt,' ]; then
  ok "changed.txt: committed + unstaged + untracked, never ignored or .claude/cache"
else no "changed.txt was: $(tr '\n' , <"$TMP/d1/changed.txt")"; fi
if grep -q '^+a2$' "$TMP/d1/diff.patch" && grep -q '^+b$' "$TMP/d1/diff.patch" && grep -q '^+new$' "$TMP/d1/diff.patch"; then
  ok "diff.patch carries every hunk, the untracked file as an add"
else no "diff.patch is missing a hunk"; fi
if [ "$(cat "$TMP/d1/base.txt")" = "$(git -C "$HOST" rev-parse main)" ]; then ok "base.txt is the merge-base sha"; else
  no "base.txt: $(cat "$TMP/d1/base.txt")"
fi
(cd "$HOST" && bash "$DIFF" "$TMP/d2" >/dev/null 2>&1)
if cmp -s "$TMP/d1/diff.patch" "$TMP/d2/diff.patch"; then ok "no --base defaults to main"; else no "default base differs from main"; fi
for bad in "-p" "nosuchref"; do
  (cd "$HOST" && bash "$DIFF" --base "$bad" "$TMP/d3" >/dev/null 2>&1)
  rc=$?
  if [ "$rc" -eq 2 ]; then ok "--base '$bad' exits 2"; else no "--base '$bad' exited $rc"; fi
done
(cd "$TMP" && bash "$DIFF" "$TMP/d4" >/dev/null 2>&1)
rc=$?
if [ "$rc" -eq 2 ]; then ok "outside a repo exits 2"; else no "outside a repo exited $rc"; fi
CLEAN="$TMP/clean"
git clone -q "$HOST" "$CLEAN" 2>/dev/null && git -C "$CLEAN" switch -q main
(cd "$CLEAN" && bash "$DIFF" --base HEAD "$TMP/d5" >/dev/null 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/d5/diff.patch" ] && [ ! -s "$TMP/d5/changed.txt" ]; then
  ok "no change: exit 0, empty patch and list"
else no "clean tree: rc=$rc"; fi

# --- gate.sh: a row's command cannot eat the rows after it ------------------
printf 'eat|0|cat\nnext|0|true\n' >"$TMP/rows"
(cd "$TMP" && bash "$ROOT/tools/orch/gate.sh" "$TMP/g" "$TMP/rows" >/dev/null 2>&1)
if grep -q '^PASS next' "$TMP/g/summary.txt"; then ok "gate.sh runs rows with stdin closed"; else
  no "a row reading stdin swallowed the next row"
fi

# --- the flow runner ----------------------------------------------------------
FLOW="$ROOT/tools/flow.sh"
FLOWS="$HOST/.claude/flows"
RUNS="$HOST/.claude/cache/runs"
mkdir -p "$FLOWS"
flow() { (cd "$HOST" && bash "$FLOW" "$@"); }
newest() { find "$RUNS" -mindepth 1 -maxdepth 1 -type d -name '2*' | sort | tail -1; }

cat >"$FLOWS/pass.toml" <<'EOF'
description = "every step green; data moves through $FLOW_OUT"
[[step]]
name = "make"
type = "run"
run = '''
echo hello >"$FLOW_OUT/greeting"
env | grep -E '^(FLOW_|DEVIL_FLOW_CHILD=)' | sort >"$FLOW_OUT/env"
pwd >"$FLOW_OUT/cwd"
if read -r line; then echo "stdin: $line" >"$FLOW_OUT/stdin"; fi
command -v devil >"$FLOW_OUT/devil"
'''
timeout = 20
[[step]]
name = "read-it"
type = "assert"
run = 'grep -qx hello "$FLOW_OUT/greeting"'
message = "the greeting did not reach the next step"
[[step]]
name = "fails-on-purpose"
type = "run"
run = "exit 3"
expect = "nonzero"
EOF
mkdir -p "$HOST/sub"
(cd "$HOST/sub" && bash "$FLOW" run pass --base main --spec "$HOST/a.txt" >"$TMP/pass.out" 2>"$TMP/pass.err")
rc=$?
RUN="$(newest)"
if [ "$rc" -eq 0 ]; then ok "a green flow exits 0"; else no "pass flow exited $rc: $(cat "$TMP/pass.err")"; fi
if [ -s "$RUN/out/greeting" ] && grep -q 'PASS read-it' "$RUN/summary.txt"; then
  ok "a step reads what an earlier step wrote to \$FLOW_OUT"
else no "output passing broke"; fi
if grep -qx "FLOW_BASE=$(git -C "$HOST" rev-parse main)" "$RUN/out/env" && grep -qx DEVIL_FLOW_CHILD=1 "$RUN/out/env" &&
  grep -qx "FLOW_SPEC=$RUN/spec.md" "$RUN/out/env" && cmp -s "$RUN/spec.md" "$HOST/a.txt"; then
  ok "steps get the resolved base, the child marker and a copy of the spec"
else no "step env: $(tr '\n' ' ' <"$RUN/out/env")"; fi
if [ "$(cat "$RUN/out/cwd")" = "$HOST" ]; then ok "steps run from the host root, not the caller's cwd"; else
  no "cwd was $(cat "$RUN/out/cwd")"
fi
if [ ! -e "$RUN/out/stdin" ]; then ok "steps run with stdin closed"; else no "a step read stdin"; fi
if [ "$(cat "$RUN/out/devil")" = "$ROOT/bin/devil" ]; then ok "the kit's devil is first on PATH"; else
  no "devil resolved to $(cat "$RUN/out/devil")"
fi
if grep -q 'PASS fails-on-purpose' "$RUN/summary.txt"; then ok 'expect = "nonzero" passes on a failure'; else
  no "expect nonzero did not pass"
fi
if [ "$(sed -n '1p;2p' "$TMP/pass.out" | tr '\n' ' ')" = 'status: done gates: ' ] &&
  grep -qx -- '- fails-on-purpose → 3' "$TMP/pass.out" && grep -qx "report: $RUN/report.md" "$TMP/pass.out"; then
  ok "stdout ends with the agent-brief return block and the report path"
else no "return block: $(cat "$TMP/pass.out")"; fi
if jq -e '.exit == 0 and (.steps | length) == 3 and .brief.status == "done"' "$RUN/report.json" >/dev/null &&
  grep -q '^| read-it | assert | PASS |' "$RUN/report.md"; then
  ok "report.json and report.md agree on the run"
else no "report contents are off"; fi
if [ "$(tail -1 "$RUNS/index.jsonl" | jq -r '"\(.flow) \(.exit) \(.run_id)"')" = "pass 0 $(basename "$RUN")" ]; then
  ok "index.jsonl gets one line per run"
else no "index.jsonl: $(tail -1 "$RUNS/index.jsonl")"; fi

cat >"$FLOWS/stop.toml" <<'EOF'
description = "an assert fails, the step after it never runs"
[[step]]
name = "no"
type = "assert"
run = "test -e nothing-here"
message = "nothing-here is missing"
[[step]]
name = "after"
type = "run"
run = 'touch "$FLOW_OUT/ran"'
EOF
flow run stop >"$TMP/stop.out" 2>/dev/null
rc=$?
RUN="$(newest)"
if [ "$rc" -eq 1 ] && [ ! -e "$RUN/out/ran" ] && grep -q '^SKIP after' "$RUN/summary.txt"; then
  ok "the first failure exits 1 and the steps after it are SKIP"
else no "stop flow: rc=$rc"; fi
if grep -q '^status: blocked' "$TMP/stop.out" && grep -q '^next: nothing-here is missing' "$TMP/stop.out" &&
  grep -qx -- '- after → skipped' "$TMP/stop.out"; then
  ok "a failed assert's message is the next step"
else no "stop return block: $(cat "$TMP/stop.out")"; fi

cat >"$FLOWS/hang.toml" <<'EOF'
description = "a step that never ends, even one expected to fail"
[[step]]
name = "sleep"
type = "run"
run = "sleep 30"
expect = "nonzero"
timeout = 1
EOF
flow run hang >"$TMP/hang.out" 2>/dev/null
rc=$?
if [ "$rc" -eq 124 ] && jq -e '.steps[0].status == "TIMEOUT"' "$(newest)/report.json" >/dev/null; then
  ok "a watchdog kill exits 124, even under expect = nonzero"
else no "hang flow exited $rc"; fi

before="$(find "$RUNS" -mindepth 1 -maxdepth 1 | wc -l)"
flow run stop --dry-run >"$TMP/dry.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'nothing was executed' "$TMP/dry.out" &&
  [ "$(find "$RUNS" -mindepth 1 -maxdepth 1 | wc -l)" -eq "$before" ]; then
  ok "--dry-run prints the plan and creates no run"
else no "dry run: rc=$rc"; fi

# Every invalid flow is refused by check and by run, before anything executes.
bad() { printf 'description = "x"\n%s\n' "$2" >"$FLOWS/$1.toml"; }
bad b-key $'[[step]]\nname = "a"\ntype = "run"\nrun = "true"\ntimout = 5'
bad b-top $'colour = 1\n[[step]]\nname = "a"\ntype = "run"\nrun = "true"'
bad b-name $'[[step]]\nname = "A b"\ntype = "run"\nrun = "true"'
bad b-dup $'[[step]]\nname = "a"\ntype = "run"\nrun = "true"\n[[step]]\nname = "a"\ntype = "run"\nrun = "true"'
bad b-expect $'[[step]]\nname = "a"\ntype = "run"\nrun = "true"\nexpect = 1'
bad b-range $'[[step]]\nname = "a"\ntype = "run"\nrun = "true"\ntimeout = 0'
bad b-bool $'[[step]]\nname = "a"\ntype = "run"\nrun = "true"\nidle = true'
bad b-msg $'[[step]]\nname = "a"\ntype = "assert"\nrun = "true"'
bad b-type $'[[step]]\nname = "a"\ntype = "shell"\nrun = "true"'
bad b-run $'[[step]]\nname = "a"\ntype = "run"\nrun = "  "'
bad b-none ''
bad b-toml '[[step]'
bad b-bash $'[[step]]\nname = "a"\ntype = "run"\nrun = "if then"'
cp "$FLOWS/pass.toml" "$TMP/Bad_Name.toml"
for f in "$FLOWS"/b-*.toml "$TMP/Bad_Name.toml"; do
  n="$(basename "$f" .toml)"
  flow check "$f" >/dev/null 2>"$TMP/check.err"
  rc=$?
  if [ "$rc" -eq 2 ] && [ -s "$TMP/check.err" ]; then ok "check refuses $n"; else no "check $n exited $rc"; fi
done
before="$(find "$RUNS" -mindepth 1 -maxdepth 1 | wc -l)"
flow run b-key >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ] && [ "$(find "$RUNS" -mindepth 1 -maxdepth 1 | wc -l)" -eq "$before" ]; then
  ok "run refuses an invalid flow before creating a run"
else no "run b-key exited $rc"; fi
rm -f "$FLOWS"/b-*.toml
if flow check >/dev/null 2>&1; then ok "check with no names passes every valid flow"; else no "check of all flows failed"; fi
for args in "run pass --base=-p" "run pass --base nosuchref" "run pass --spec nosuch.md" "run nosuch" "run"; do
  # shellcheck disable=SC2086 # word splitting is the point: each string is an argv
  flow $args >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then ok "'$args' exits 2"; else no "'$args' exited $rc"; fi
done

if [ "$(flow show | head -1)" = '# Flow `hang`: TIMEOUT' ] && [ "$(flow show pass | head -1)" = '# Flow `pass`: PASS' ]; then
  ok "show prints the newest report, or the newest of one flow"
else no "show: $(flow show 2>&1 | head -1)"; fi
flow show nosuch >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then ok "show of a flow with no run exits 2"; else no "show nosuch exited $rc"; fi

# Prune keeps the 20 newest runs and touches nothing that is not a real run folder.
for i in $(seq -w 1 25); do mkdir -p "$RUNS/200001${i}-000000-old-1"; done
mkdir -p "$TMP/outside" && touch "$TMP/outside/keep"
ln -s "$TMP/outside" "$RUNS/19990101-000000-link-1"
mkdir -p "$RUNS/not-a-run"
flow run pass >/dev/null 2>&1
if [ "$(find "$RUNS" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | wc -l)" -eq 20 ] &&
  [ ! -e "$RUNS/20000101-000000-old-1" ] && [ -e "$TMP/outside/keep" ] && [ -L "$RUNS/19990101-000000-link-1" ] &&
  [ -d "$RUNS/not-a-run" ] && [ -f "$RUNS/r.txt" ]; then
  ok "prune keeps the 20 newest runs, never a symlink or a foreign file"
else no "prune: $(ls "$RUNS" | tr '\n' ' ')"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
