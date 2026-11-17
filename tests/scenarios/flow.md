2026-11-17 · Claude Code 2.1.326 (subscription login) · plugin 1.2.0-pre · Switchyard `fcd2a4f` · fixture `slug`, a planted truncation change

## Scenario

> Review the uncommitted change against this spec: slugify(title, max_len=40) returns at
> most max_len characters: lowercase a-z0-9 words joined by single dashes, never ending in
> a dash. Punctuation is dropped.

Fixture: a git repo with `slug.py` and `test_slug.py` at HEAD, and an uncommitted change
that adds `max_len`, cuts the slug at `[: max_len - 1]` and filters with `[^a-z0-9 ]`.
Planted defects: a trailing dash after the cut, the off-by-one, and tabs no longer
splitting words. The one new test is a happy path.

## Baseline

The fan-out the gate replaced: one `claude -p` session told to spawn `devil:reviewer` and
`devil:security` in parallel on the same diff and spec. Budget $3, read-only tools, Bash
limited to `git`, `devil digest|quality` and `pytest` (pytest was not installed, so the
agents traced by hand).

```text
rc=0 seconds=126  num_turns=5  total_cost_usd=1.1527
claude-fable-5-2 (coordinator)  costUSD=0.7165  out=4777
claude-opus-5-5  (two agents)   costUSD=0.4362  out=13336
**Combined verdict: BLOCK.** ... 12 findings: 2 critical, 3 high, 2 medium, 5 low
```

The coordinator called findings 1 to 5 the merge blockers: trailing dash, `max_len <= 0`,
the off-by-one, tabs merging words, no test of any of it.

## With skill

`devil flow run review --base HEAD --spec spec.md`, the project routed through Switchyard
(`devil route on`), so the one call went to the `devil-review` route.

```text
flow: PASS diff 1s · PASS nonempty 1s · FAIL review exit=1 21s     rc=1 seconds=22
BLOCKER spec slug.py:8 ... the result can end in a dash. slugify("hello world", max_len=7)
MAJOR spec slug.py:8 Off-by-one: the slice uses max_len - 1 ... max_len=0 becomes [:-1]
MAJOR spec slug.py:7 The character class [^a-z0-9 ] keeps only literal spaces ...
MAJOR standards test_slug.py:8 No test covers the new max_len parameter ...
| claude-opus-5-5 | 1 | 5404 | 2295 | $0.0880 |
```

The report's cost table (Switchyard's log for session `devil-flow-<id>`), `devil route
log` for that session, and the CLI's own `total_cost_usd` all read $0.088023. The proxy
logged no warning for the call: `--tools ""` with `--json-schema` works through it.

## Verdict

Added: the same five merge blockers for $0.088 against $1.15, 13 times cheaper and 6
times faster; against the two Opus agents alone ($0.44), 5 times cheaper. The verdict is
code-checked (exit 1), not read off prose.
Still missing: the agents' two mediums (hyphens no longer separate words; existing callers
now truncated) and five lows (case folding of lookalikes, empty slugs, unbounded input,
transliteration, `max_len=True`). One combined call trades that breadth for cost. This is
one run on one 5-line change, so the skills stay `beta`. The agents stay available for a
deeper pass.

## Routing checks

- `docker stop devil-switchyard`, then the SessionStart `route-guard` hook in the routed
  fixture: it printed "Switchyard is down ... turned model routing off ... restart
  claude", and `off` removed `.claude/settings.local.json`, which `on` had created. The
  next start was silent.
- `devil route start` brought the proxy back healthy with all four routes.
