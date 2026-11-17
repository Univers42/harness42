2026-11-17 · Claude Code 2.1.326 (subscription login) · plugin 1.2.0 against 1.1.1 (`1361f7d`) · Switchyard `fcd2a4f` · fixture `slug`

## Scenario

Two runs, both on the `slug` fixture: a git repo with `slug.py` (`slugify(title)`) and
`test_slug.py` at HEAD.

1. Review only. An uncommitted change adds `max_len`, cuts at `[: max_len - 1]` and filters
   with `[^a-z0-9 ]`. Planted defects: a trailing dash after the cut, the off-by-one, and
   tabs no longer splitting words. The one new test is a happy path. The prompt:

   > Review the uncommitted change against this spec: slugify(title, max_len=40) returns at
   > most max_len characters: lowercase a-z0-9 words joined by single dashes, never ending
   > in a dash. Punctuation is dropped.

2. A whole feature, on a clean clone at HEAD with no remote, `claude -p --model
   claude-opus-5-5 --max-budget-usd 6`, unrouted, Bash allowed except push, `curl`,
   `wget` and `rm -rf`. The kit is loaded with `--plugin-dir`, which replaces the
   installed copy. The prompt:

   > /devil:feature Add an optional max_len parameter (default 40) to slugify in slug.py:
   > the slug is at most max_len characters and never ends in a dash; max_len < 1 raises
   > ValueError. Cover it with tests. pytest is not installed: run the tests with python3.

## Baseline

Run 1: the fan-out the gate replaced. One session spawned `devil:reviewer` and
`devil:security` in parallel on the same diff and spec. Budget $3, read-only tools, Bash
limited to `git`, `devil digest|quality` and `pytest` (not installed, so the agents traced
by hand).

```text
rc=0 seconds=126  num_turns=5  total_cost_usd=1.1527
claude-fable-5-2 (coordinator)  costUSD=0.7165  out=4777
claude-opus-5-5  (two agents)   costUSD=0.4362  out=13336
**Combined verdict: BLOCK.** ... 12 findings: 2 critical, 3 high, 2 medium, 5 low
```

The coordinator called findings 1 to 5 the merge blockers: trailing dash, `max_len <= 0`,
the off-by-one, tabs merging words, no test of any of it.

Run 2, kit at `1361f7d`: the `devil:prompt` skill, a `devil:devil` agent for the risk
verdict (PROCEED-WITH-CONDITIONS), `devil quality --with-tests` twice, and a
`devil:reviewer` agent (APPROVE, two minors). Six tests pass; one commit.

```text
rc=0 seconds=96  num_turns=15  total_cost_usd=0.5286
part            calls  out    cache read  cache write
main loop       10     6815   395946      11459
devil:reviewer  3      1244   28910       16329
devil:devil     2      1618   12919       14820
```

## With skill

Run 1: `devil flow run review --base HEAD --spec spec.md`, the project routed through
Switchyard (`devil route on`), so the one call went to the `devil-review` route.

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

Run 2, kit on the branch: no agents. One `devil flow run gate` (diff, nonempty, ruff
format and check PASS, pytest SKIP and named as such, then the review: APPROVE, two
minors). Eight tests pass; two commits. The review is its own process, so its cost is
added to the session's.

```text
rc=0 seconds=77  num_turns=12  total_cost_usd=0.2596 + flow review 0.0502 = 0.3098
part            calls  out    cache read  cache write
main loop       10     5625   389049      8652
flow review     1      1560   4049        2271
```

Per-part tokens come from the session transcripts, one row per message id; they add up
to the session's `modelUsage` exactly.

## Verdict

Added:

- Run 1: the same five merge blockers for $0.088 against $1.15, 13 times cheaper and 6
  times faster; against the two Opus agents alone ($0.44), 5 times cheaper. The verdict
  is code-checked (exit 1), not read off prose.
- Run 2: the same feature for $0.31 against $0.53 (41% less) in 77 s against 96 s, with
  the same review verdict. The gate's review took 1 call and 7,882 tokens, against the
  reviewer agent's 3 calls and 46,489.

Still missing:

- Run 1: the agents' two mediums (hyphens no longer separate words; existing callers now
  truncated) and five lows (case folding of lookalikes, empty slugs, unbounded input,
  transliteration, `max_len=True`). One combined call trades that breadth for cost; the
  agents stay available for a deeper pass.
- Run 2 is not clean: the old kit's run also took the risk verdict, which the new run
  judged unneeded under the same step-3 text, so part of the gap is the model's choice.
  The main loop costs about the same in both; the saving is the agents.

`flow` is promoted to `stable`: both measured comparisons held. `flow-author` stays
`beta`, because no run has measured writing a flow.

## Routing checks

E2e steps 2 to 4 of the plan, on the real proxy:

- A routed session told to spawn `devil:reviewer`: the main loop's calls went to the
  `switchyard` route (Sonnet), the reviewer's three to `devil-review` (Opus) with
  `delegated: true`. The six rows sum to $0.391821, which is the CLI's `total_cost_usd`
  and `devil route log --session <id>`.
- `devil flow run gate`, routed, on run 1's change: exit 1 on the same blockers. The
  report's cost table (source `switchyard`, $0.102455, one Opus call) matches
  `devil route log --session devil-flow-<id>`.
- `docker stop devil-switchyard`, then a real `claude -p --plugin-dir` start in the routed
  fixture: the `route-guard` hook printed "Switchyard is down ... turned model routing off
  ... restart claude", `off` removed the `.claude/settings.local.json` that `on` had
  created, and no project was left routed. That session still pointed at the proxy and
  retried until killed (10 `api_retry` events): hence the restart. The next start was
  silent and went to Anthropic directly.
- `devil route start` brought the proxy back healthy with all four routes.
