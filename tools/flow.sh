#!/usr/bin/env bash
# flow.sh: `devil flow`, a workflow written once as TOML and run by code every time after.
#
# Usage: devil flow list
#        devil flow check [FLOW...]
#        devil flow show [RUN_ID|FLOW]
#        devil flow run FLOW [--base REF] [--spec FILE] [--dry-run]
#
# The logic is lib/flow.py (stdlib only; 3.11+ for tomllib). This shim finds the kit, the host
# root and its cache, the same way every other tool does. Runs land in .claude/cache/runs/.
# Exit: 0 green, 1 a step failed, 2 usage or an invalid flow, 124 a step hit its watchdog.
# Caveat: the host is the cwd's git toplevel, so run from inside a submodule or a nested repo,
# the flow checks that inner repo and writes its runs there; cd to the outer root first.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

if ! have python3 || ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then
  echo "flow: needs python3 3.11 or newer (tomllib)" >&2
  exit 2
fi
FLOW_KIT="$(cd "$DIR/.." && pwd)"
FLOW_ROOT="$(repo_root)"
FLOW_CACHE="$(cache_dir)"
export FLOW_KIT FLOW_ROOT FLOW_CACHE
exec python3 -I "$DIR/lib/flow.py" "$@"
