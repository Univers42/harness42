#!/usr/bin/env bash
# test_quality.sh - quality.sh --logs=DIR keeps what a reviewer needs.
#
# The board alone says "shellcheck FAIL"; the finding with its file:line lived in
# output check() threw away, so every reviewer re-ran the linter to see it. With
# --logs the output survives, one file per gate, and results.tsv indexes them.
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

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "skip - shellcheck not installed; the failing gate under test needs it"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A host repo with one unquoted expansion: shellcheck must fail on it (SC2086).
HOST="$TMP/host"
mkdir -p "$HOST"
git -C "$HOST" init -q
printf '#!/usr/bin/env bash\necho $1\n' >"$HOST/bad.sh"
git -C "$HOST" add bad.sh

# --- without --logs nothing is written --------------------------------------
(cd "$HOST" && bash "$ROOT/tools/quality.sh" --no-audit >"$TMP/plain.txt" 2>&1)
rc=$?
if [ "$rc" -eq 1 ]; then ok "a failing gate still exits 1"; else no "plain run exited $rc"; fi
if ! grep -q 'log:' "$TMP/plain.txt"; then ok "no log note without --logs"; else no "plain board names a log"; fi

# --- with --logs: per-gate log, results.tsv, the FAIL note points at it -----
(cd "$HOST" && bash "$ROOT/tools/quality.sh" --no-audit --logs=../logs >"$TMP/logged.txt" 2>&1)
rc=$?
LOGS="$TMP/logs"
if [ "$rc" -eq 1 ]; then ok "--logs keeps the exit code"; else no "--logs run exited $rc"; fi
if [ -f "$LOGS/results.tsv" ] && head -1 "$LOGS/results.tsv" | grep -q $'^status\tgate\tcategory\tlog$'; then
  ok "results.tsv has its header (relative --logs resolved from the caller's cwd)"
else no "results.tsv missing or headerless under $LOGS"; fi
row="$(grep -P '^FAIL\tshellcheck\t' "$LOGS/results.tsv")"
if [ "$(cut -f4 <<<"$row")" = "$LOGS/shellcheck.log" ]; then ok "the FAIL row names its log"; else no "shellcheck row: '$row'"; fi
if grep -q 'SC2086' "$LOGS/shellcheck.log" && grep -q 'bad.sh' "$LOGS/shellcheck.log"; then
  ok "the log carries the finding and its file"
else no "shellcheck.log lacks the finding"; fi
if grep -q "log: $LOGS/shellcheck.log" "$TMP/logged.txt"; then ok "the board's FAIL note points at the log"; else
  no "board does not name the log"
fi
if [ "$(($(grep -c . "$LOGS/results.tsv") - 1))" -eq "$(grep -cE '(PASS|FAIL|SKIP) \|' "$TMP/logged.txt")" ]; then
  ok "one results.tsv row per board row"
else no "results.tsv and the board disagree on row count"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
