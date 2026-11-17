---
name: flow-author
description: >
  Write a repeated workflow once as a flow file (TOML), so code runs it every time after
  and no agent re-derives its steps. Use when the same sequence of commands, checks and
  one review keeps being done by hand or by a fan-out of agents.
  Auto-triggers on: "write a flow", "make this a flow", "automate this workflow"
allowed-tools: Read, Write, Bash
metadata:
  stage: beta
  since: "1.2.0"
---

# Flow author

An agent that runs the same five commands every session pays for them every session. Write
them down once as a flow, check it, and from then on `devil flow run <name>` is one shell
call. The shipped flows are the model: `flows/gate.toml` and `flows/review.toml`.

## Where it goes

- `<host>/.claude/flows/<name>.toml` for one project. A host flow wins over a kit flow of
  the same name, so a project can replace `gate` with its own.
- `flows/<name>.toml` in the kit, for every project.
- `<name>` matches `^[a-z][a-z0-9-]*$`; it is the name `devil flow run` takes.

## The shape

```toml
description = "what the flow proves, in one line"

[[step]]
name = "diff"
type = "run"
run = 'devil orch diff ${FLOW_BASE:+--base "$FLOW_BASE"} "$FLOW_OUT"'
timeout = 120

[[step]]
name = "nonempty"
type = "assert"
run = 'test -s "$FLOW_OUT/changed.txt"'
message = "nothing changed against the base"

[[step]]
name = "review"
type = "review"
model = "opus"
budget_usd = 3
```

| Type | Keys | Does |
| --- | --- | --- |
| `run` | `run`, `expect` (0 or `"nonzero"`), `timeout` (300), `idle` (120) | a bash body under the watchdog; `idle = 0` for a step that is silent for minutes |
| `assert` | `run`, `message` (required), `timeout` (30) | a fast check; on failure the caller reads `message` |
| `review` | `model` (`opus`), `route` (`devil-review`), `budget_usd` (3), `timeout` (600), `max_diff_bytes` (200000), `rubric` | one headless `claude -p` with no tools, judged against `rubric` (default: the reviewer and security agents); `route` replaces `model` when the project is routed (`devil route on`) |

A body runs from the host root with `set -eo pipefail` and stdin closed. Each step sees
`FLOW_RUN_ID`, `FLOW_RUN_DIR`, `FLOW_OUT`, `FLOW_BASE`, `FLOW_ROOT`, `FLOW_SPEC` and the
kit's `bin/` first on PATH, so `devil` resolves.

## Rules

- One review at most, and it is the last step: it judges what ran before it, and the
  first failure stops the flow, so a review only ever sees a green run.
- A step hands data on as a file in `$FLOW_OUT` and the next step reads it by name. A
  review reads `out/diff.patch`, `out/changed.txt` and `quality/results.tsv`; a flow
  with a review needs a step that writes the diff.
- Every step is bounded: a `timeout` that fits it, never the maximum "to be safe".
- No secrets in a body: a step's script and log are kept in the run folder.
- No unpinned network call: a body that fetches `latest` runs a different flow each day.
- A `rubric` names files inside the kit; a host flow cannot send other files to the model.

## Check before it runs

```sh
devil flow check <name>            # shape, keys, ranges, bash -n of every body
devil flow run <name> --dry-run    # every step as it would run; nothing executes
```

`check` proves the shape, not that a command exists or ends, so read the dry run. Then run
the flow once for real and read `devil flow show <name>` before handing it to anyone; the
`flow` skill covers running it and acting on its exit code.

## Without `devil`

On a host with no `devil` on PATH a flow file is documentation: run its steps by hand in
order, stop at the first failure, and give the review step to the `reviewer` and
`security` agents.

## Report

| Flow | File | Steps | `check` | First run exit |
| --- | --- | ---: | --- | ---: |
| | | | | |

- The workflow the flow replaces, and the agent calls it no longer needs.
- Every `timeout` and `idle` chosen, and why each one fits its step.
