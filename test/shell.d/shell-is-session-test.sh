#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

test_tmp=$(mktemp -d)
older_pid=""
newer_pid=""

cleanup() {
  [[ -n $older_pid ]] && kill "$older_pid" 2>/dev/null || true
  [[ -n $newer_pid ]] && kill "$newer_pid" 2>/dev/null || true
  rm -rf "$test_tmp"
}
trap cleanup EXIT

fake_bin="$test_tmp/bin"
session="$test_tmp/omarchy dev"
copy="$test_tmp/copy"
mkdir -p "$fake_bin" "$session/shell" "$copy/shell"
ln -s "$session" "$test_tmp/omarchy-link"

# The manager's raw environment, as busctl reports it.
cat >"$fake_bin/busctl" <<'SH'
#!/bin/bash

[[ ${OMARCHY_TEST_BUSCTL_FAILS:-0} == 1 ]] && exit 1
jq -cn --arg env "$OMARCHY_TEST_SESSION_ENV" '{type: "as", data: ($env | split("\n") | map(select(length > 0)))}'
SH

cat >"$fake_bin/quickshell" <<'SH'
#!/bin/bash

[[ $1 == "list" && $2 == "-p" && $4 == "--json" ]] || exit 1
[[ $3 == "$OMARCHY_PATH/shell" ]] || { echo '[]'; exit 0; }
jq -cn --arg pids "${OMARCHY_TEST_PIDS:-}" '$pids | split(" ") | map(select(length > 0) | {pid: tonumber})'
SH
chmod +x "$fake_bin/busctl" "$fake_bin/quickshell"

# Real processes, so their start times come from /proc like a shell's would.
sleep 60 &
older_pid=$!
sleep 0.05
sleep 60 &
newer_pid=$!

SESSION=0
OTHER_TREE=1
DUPLICATE=2

assert_session() {
  local expected="$1" omarchy_path="$2" session_env="$3" shell_pid="$4" pids="$5" description="$6" busctl_fails="${7:-0}" actual=0

  PATH="$fake_bin:$PATH" \
  OMARCHY_PATH="$omarchy_path" \
  OMARCHY_TEST_SESSION_ENV="$session_env" \
  OMARCHY_TEST_PIDS="$pids" \
  OMARCHY_TEST_BUSCTL_FAILS="$busctl_fails" \
    "$ROOT/bin/omarchy-shell-is-session" "$shell_pid" || actual=$?

  (( actual == expected )) || fail "$description" "expected exit $expected, got $actual"
  pass "$description"
}

assert_session $SESSION "$session" \
  "HOME=/home/user"$'\n'"OMARCHY_PATH=$session" "$older_pid" "$older_pid" \
  "the shell running from the session's tree is the session shell"

# Test copies run the shell out of a temporary tree on the same display.
assert_session $OTHER_TREE "$copy" \
  "OMARCHY_PATH=$session" "$older_pid" "$older_pid" \
  "a shell running from another tree is not the session shell"

assert_session $SESSION "$test_tmp/omarchy-link/" \
  "OMARCHY_PATH=$session" "$older_pid" "$older_pid" \
  "the same tree reached through a symlink or trailing slash still matches"

# A shell from the session's tree started by hand without -n duplicates it.
assert_session $DUPLICATE "$session" \
  "OMARCHY_PATH=$session" "$newer_pid" "$older_pid $newer_pid" \
  "a later duplicate defers to the older shell from the session's tree"

assert_session $SESSION "$session" \
  "OMARCHY_PATH=$session" "$older_pid" "$older_pid $newer_pid" \
  "the oldest shell from the session's tree stays the session shell"

# Once the older shell is gone, the duplicate inherits the session.
assert_session $SESSION "$session" \
  "OMARCHY_PATH=$session" "$newer_pid" "$newer_pid 999999999" \
  "a listed shell that has exited does not hold the session"

# Nothing to compare against keeps the recovery every shell had before.
assert_session $SESSION "$copy" \
  "HOME=/home/user" "$older_pid" "$older_pid" \
  "a session without a recorded path leaves the shell in charge"

assert_session $SESSION "$copy" \
  "" "$older_pid" "$older_pid" \
  "an unreachable user manager leaves the shell in charge" 1
