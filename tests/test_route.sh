#!/usr/bin/env bash
# test_route.sh - `devil route`: the Switchyard template, the proxy's docker argv, and the
# per-project on/off that must restore settings.local.json exactly.
#
# `docker` and `curl` are fakes on PATH, so nothing builds, listens or reaches the network.
# HOME, XDG and git config are throwaway, so the developer's global gitignore cannot hide
# the "not git-ignored" refusal.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTE="$ROOT/tools/route.sh"
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
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SECRET="sk-ant-planted-$$-never-print"
mkdir -p "$TMP/bin" "$TMP/home"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" XDG_STATE_HOME="$TMP/state"
export GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 ANTHROPIC_API_KEY="$SECRET"
export FAKE="$TMP" PATH="$TMP/bin:$PATH"
unset DEVIL_SWITCHYARD_REF DEVIL_SWITCHYARD_PORT

# docker: logs its argv; an image exists if $FAKE/image, a dry-run fails if $FAKE/badconf,
# and `run -d` makes the proxy healthy.
cat >"$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/docker.log"
case "$1 $2" in
"image inspect") [ -f "$FAKE/image" ] ;;
"inspect -f") exit 1 ;;
*)
  case " $* " in
  *" --dry-run "*) if [ -f "$FAKE/badconf" ]; then echo "invalid server config" >&2; exit 1; fi; echo "server OK" ;;
  *" -d "*) touch "$FAKE/healthy" ;;
  esac ;;
esac
SH
# curl: /health answers while $FAKE/healthy exists; session-stats answers for "s1" only.
cat >"$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
*/health) [ -f "$FAKE/healthy" ] ;;
*session_id=s1) echo '{"session_id":"s1","cost":{"total_usd":0.5}}' ;;
*) exit 22 ;;
esac
SH
chmod +x "$TMP/bin/docker" "$TMP/bin/curl"

run() { (cd "${HOST:-$TMP}" && bash "$ROUTE" "$@") >>"$TMP/out" 2>&1; }

# --- the template ---------------------------------------------------------------
TPL="$ROOT/templates/switchyard/routes.toml"
check "template parses; one client, Anthropic only, forward_auth" "python3 -I -c '
import sys, tomllib
c = tomllib.load(open(sys.argv[1], \"rb\"))[\"llm_clients\"]
assert list(c) == [\"anthropic\"], c
assert c[\"anthropic\"][\"base_url\"] == \"https://api.anthropic.com\"
assert c[\"anthropic\"][\"forward_auth\"] is True' '$TPL'"
check "template holds no key and names no key variable" "! grep -qE 'api_key|sk-' '$TPL'"

# --- usage and settings ---------------------------------------------------------
run
check "no subcommand is exit 2" "[ $? -eq 2 ]"
run --help
check "--help is exit 0" "[ $? -eq 0 ]"
DEVIL_SWITCHYARD_REF=main run status
check "a ref that is not a full sha is exit 2" "[ $? -eq 2 ]"
DEVIL_SWITCHYARD_PORT=80 run status
check "a privileged port is exit 2" "[ $? -eq 2 ]"

# --- the proxy ------------------------------------------------------------------
run build
check "build pins the full commit" "grep -q 'build -t devil-switchyard:fcd2a4f .*Switchyard-nvidia.git#fcd2a4feeb6a2a0e36cbea00ee69a1469000221f' '$TMP/docker.log'"
run start
check "start without the image is exit 1" "[ $? -eq 1 ]"
touch "$TMP/image" "$TMP/badconf"
run start
check "start with invalid routes is exit 2" "[ $? -eq 2 ]"
check "invalid routes never start a container" "! grep -q ' -d ' '$TMP/docker.log'"
check "start seeds the routes from the template" "cmp -s '$TPL' '$TMP/state/devil/switchyard/routes.toml'"
rm -f "$TMP/badconf"
: >"$TMP/docker.log"
run start
check "start is exit 0" "[ $? -eq 0 ]"
check "the dry-run comes before the container" "grep -n -e '--dry-run' -e ' -d ' '$TMP/docker.log' | head -1 | grep -q -e '--dry-run'"
RUNLINE="$(grep ' -d ' "$TMP/docker.log")"
for want in "-p 127.0.0.1:4123:4000" "--read-only" "--cap-drop ALL" \
  "--security-opt no-new-privileges" "/config/routes.toml:ro"; do
  if [[ "$RUNLINE" == *"$want"* ]]; then ok "run argv has $want"; else no "run argv has $want"; fi
done

# --- on / off in a project ------------------------------------------------------
HOST="$TMP/host"
SETTINGS="$HOST/.claude/settings.local.json"
mkdir -p "$HOST/.claude" && git -C "$HOST" init -q
printf '{"permissions":{"allow":["Bash(ls)"]},"env":{"FOO":"1","ANTHROPIC_MODEL":"opus"}}\n' >"$SETTINGS"
cp "$SETTINGS" "$TMP/orig.json"
run on
check "on refuses a settings file git would commit (exit 1)" "[ $? -eq 1 ]"
check "a refused on leaves the file unchanged" "cmp -s '$SETTINGS' '$TMP/orig.json'"
echo ".claude/settings.local.json" >"$HOST/.gitignore"
rm -f "$TMP/healthy"
run on
check "on with the proxy down is exit 1" "[ $? -eq 1 ]"
check "on with the proxy down leaves the file unchanged" "cmp -s '$SETTINGS' '$TMP/orig.json'"
touch "$TMP/healthy"
run on
check "on is exit 0" "[ $? -eq 0 ]"
check "on points the project at the loopback proxy" "[ \"\$(jq -r .env.ANTHROPIC_BASE_URL '$SETTINGS')\" = http://127.0.0.1:4123 ]"
check "on keeps unrelated keys" "[ \"\$(jq -r .env.FOO '$SETTINGS')\" = 1 ]"
run stop
check "stop is refused while a project is routed (exit 1)" "[ $? -eq 1 ]"
check "the refusal names the project" "grep -q 'still on in $HOST' '$TMP/out'"
rm -f "$TMP/healthy"
run off
check "off works with the proxy down" "[ $? -eq 0 ]"
check "on then off restores the file exactly" "[ \"\$(jq -S . '$SETTINGS')\" = \"\$(jq -S . '$TMP/orig.json')\" ]"
touch "$TMP/healthy"
run on
jq '.env.ANTHROPIC_MODEL = "mine"' "$SETTINGS" >"$TMP/edited.json" && cp "$TMP/edited.json" "$SETTINGS"
run off
check "off refuses a key the user changed since on (exit 1)" "[ $? -eq 1 ]"
check "a refused off keeps the user's edit" "cmp -s '$SETTINGS' '$TMP/edited.json'"
rm -f "$SETTINGS"
run on
check "on creates a missing settings file" "jq -e ._devilRoute.created '$SETTINGS' >/dev/null"
run off
check "off deletes the file that on created" "[ ! -e '$SETTINGS' ]"
run stop
check "stop runs once no project is routed" "[ $? -eq 0 ]"
echo '{not json' >"$SETTINGS"
run on
check "on with invalid JSON is exit 2" "[ $? -eq 2 ]"
rm -f "$SETTINGS"

# --- log ------------------------------------------------------------------------
run log --session 'bad id'
check "log rejects a malformed session id (exit 2)" "[ $? -eq 2 ]"
run log --session s1
check "log --session prints the proxy's stats" "grep -q '\"total_usd\": 0.5' '$TMP/out'"
mkdir -p "$TMP/state/devil/switchyard/log"
echo '{"ts":"t","route_id":"switchyard","tier":"capable","model":"claude-opus-5-5","delegated":false,"total_tokens":9,"cost":{"usd":0.25,"source":"estimated"}}' \
  >"$TMP/state/devil/switchyard/log/routing.jsonl"
row="$(cd "$HOST" && bash "$ROUTE" log | tail -1)"
want=$'t\tswitchyard\tcapable\tclaude-opus-5-5\tfalse\t-\t9\t0.25'
if [ "$row" = "$want" ]; then ok "log prints one TSV row per call"; else no "log prints one TSV row per call: $row"; fi

# --- secrets ----------------------------------------------------------------------
check "the API key never reaches any output or docker argv" "! grep -qF '$SECRET' '$TMP/out' '$TMP/docker.log'"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
