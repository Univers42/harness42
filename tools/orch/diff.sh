#!/usr/bin/env bash
# diff.sh [--base REF] <outdir> — the change under review, as the next commit would carry it:
# merge-base(REF, HEAD) -> working tree (committed, staged and unstaged), plus every untracked,
# non-ignored file as a new file. `git diff REF` alone misses the files nobody has added yet,
# which is where a fresh feature usually lives.
#
# Writes <outdir>/diff.patch, <outdir>/changed.txt (one path per line) and <outdir>/base.txt
# (the resolved sha). REF defaults to origin/HEAD, then main, then master, then HEAD (only
# uncommitted work). The host's .claude/cache/ is never part of the change: run artifacts live
# there and would otherwise review themselves.
# Caveat: an untracked file is added whole, so a large generated file that is not git-ignored
# lands in the patch at full size; an ignored file is never part of the change, even one that
# should be reviewed. A binary file shows only as "Binary files differ".
# Exit: 0 (an empty change is still 0; changed.txt is then empty), 2 bad usage, not a repo or a
# REF that is not a commit.
set -uo pipefail

die() {
  echo "diff.sh: $*" >&2
  exit 2
}

ref=""
if [ "${1:-}" = --base ]; then
  ref="${2:-}"
  shift 2 || die "--base needs a REF"
  # A ref that starts with '-' would be read by git as an option.
  [[ -n $ref && $ref != -* ]] || die "bad --base '$ref'"
fi
[ $# -eq 1 ] || die "usage: diff.sh [--base REF] <outdir>"
out="$1"

top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git work tree"
mkdir -p "$out" && out="$(cd "$out" && pwd)" || die "cannot create '$1'"
cd "$top" || exit 2

if [ -z "$ref" ]; then
  for cand in "$(git symbolic-ref -q --short refs/remotes/origin/HEAD)" main master HEAD; do
    [ -n "$cand" ] && git rev-parse --verify -q "$cand^{commit}" >/dev/null && ref="$cand" && break
  done
fi

if git rev-parse --verify -q HEAD >/dev/null; then
  git rev-parse --verify -q "$ref^{commit}" >/dev/null || die "'$ref' is not a commit"
  base="$(git merge-base "$ref" HEAD)" || die "no merge-base between '$ref' and HEAD"
else
  base="$(git hash-object -t tree /dev/null)" # no commits yet: everything is new
fi

skip=':(exclude).claude/cache'
git diff --no-color --no-ext-diff --no-textconv "$base" -- . "$skip" >"$out/diff.patch"
git diff --name-only "$base" -- . "$skip" >"$out/changed.txt"
git ls-files --others --exclude-standard -- . "$skip" >>"$out/changed.txt"
# --no-index exits 1 whenever the files differ, which for /dev/null is always: not an error.
while IFS= read -r -d '' f; do
  git diff --no-color --no-ext-diff --no-index -- /dev/null "$f" >>"$out/diff.patch"
done < <(git ls-files -z --others --exclude-standard -- . "$skip")
echo "$base" >"$out/base.txt"

echo "diff.sh: base ${base:0:12} · $(grep -c . "$out/changed.txt") file(s) · $(wc -c <"$out/diff.patch") bytes"
