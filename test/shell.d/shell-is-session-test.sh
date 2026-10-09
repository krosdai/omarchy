#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

fake_bin="$test_tmp/bin"
session="$test_tmp/omarchy"
copy="$test_tmp/copy"
mkdir -p "$fake_bin" "$session/shell" "$copy/shell"
ln -s "$session" "$test_tmp/omarchy-link"

cat >"$fake_bin/systemctl" <<'SH'
#!/bin/bash

[[ $* == "--user show-environment" ]] || exit 1
[[ ${OMARCHY_TEST_SYSTEMCTL_FAILS:-0} == 1 ]] && exit 1
printf '%s\n' "$OMARCHY_TEST_SESSION_ENV"
SH

cat >"$fake_bin/quickshell" <<'SH'
#!/bin/bash

[[ $* == "list --all --json" ]] || exit 1
printf '%s\n' "${OMARCHY_TEST_INSTANCES:-[]}"
SH
chmod +x "$fake_bin/systemctl" "$fake_bin/quickshell"

SESSION=0
NOT_SESSION=1

instance() {
  printf '{"pid":%s,"launch_time":"%s","config_path":"%s/shell/shell.qml"}' "$1" "$2" "$3"
}

assert_session() {
  local expected="$1" omarchy_path="$2" session_env="$3" instances="$4" description="$5" systemctl_fails="${6:-0}" actual=0

  PATH="$fake_bin:$PATH" \
  OMARCHY_PATH="$omarchy_path" \
  OMARCHY_TEST_SESSION_ENV="$session_env" \
  OMARCHY_TEST_INSTANCES="$instances" \
  OMARCHY_TEST_SYSTEMCTL_FAILS="$systemctl_fails" \
    "$ROOT/bin/omarchy-shell-is-session" 100 || actual=$?

  (( actual == expected )) || fail "$description" "expected exit $expected, got $actual"
  pass "$description"
}

alone="[$(instance 100 2026-10-08T18:00:00 "$session")]"

assert_session $SESSION "$session" \
  "HOME=/home/user"$'\n'"OMARCHY_PATH=$session" "$alone" \
  "the shell running from the session's tree is the session shell"

# Test copies run the shell out of a temporary tree on the same display.
assert_session $NOT_SESSION "$copy" \
  "OMARCHY_PATH=$session" "[$(instance 100 2026-10-08T18:00:00 "$copy")]" \
  "a shell running from another tree is not the session shell"

assert_session $SESSION "$test_tmp/omarchy-link/" \
  "OMARCHY_PATH=$session" "$alone" \
  "the same tree reached through a symlink or trailing slash still matches"

# A shell from the session's tree started by hand without -n duplicates it.
assert_session $NOT_SESSION "$session" \
  "OMARCHY_PATH=$session" \
  "[$(instance 50 2026-10-08T09:00:00 "$session"),$(instance 100 2026-10-08T18:00:00 "$session")]" \
  "a later duplicate of the session's tree is not the session shell"

assert_session $SESSION "$session" \
  "OMARCHY_PATH=$session" \
  "[$(instance 100 2026-10-08T09:00:00 "$session"),$(instance 150 2026-10-08T18:00:00 "$session")]" \
  "the first shell launched from the session's tree stays the session shell"

assert_session $NOT_SESSION "$session" \
  "OMARCHY_PATH=$session" \
  "[$(instance 50 2026-10-08T18:00:00 "$session"),$(instance 100 2026-10-08T18:00:00 "$session")]" \
  "shells launched in the same second are ordered by pid"

assert_session $SESSION "$session" \
  "OMARCHY_PATH=$session" \
  "[$(instance 50 2026-10-08T09:00:00 "$copy"),$(instance 100 2026-10-08T18:00:00 "$session")]" \
  "an older shell from another tree does not displace the session shell"

# Nothing to compare against keeps the recovery every shell had before.
assert_session $SESSION "$copy" \
  "HOME=/home/user" "[$(instance 100 2026-10-08T18:00:00 "$copy")]" \
  "a session without a recorded path leaves the shell in charge"

assert_session $SESSION "$copy" \
  "" "[]" \
  "an unreachable user manager and instance list leave the shell in charge" 1
