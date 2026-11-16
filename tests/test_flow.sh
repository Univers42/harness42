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

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
