#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

fake_bin="$test_tmp/bin"
mkdir -p "$fake_bin" "$test_tmp/omarchy" "$test_tmp/copy"
ln -s "$test_tmp/omarchy" "$test_tmp/omarchy-link"

cat >"$fake_bin/systemctl" <<'SH'
#!/bin/bash

[[ $* == "--user show-environment" ]] || exit 1
[[ ${OMARCHY_TEST_SYSTEMCTL_FAILS:-0} == 1 ]] && exit 1
printf '%s\n' "$OMARCHY_TEST_SESSION_ENV"
SH
chmod +x "$fake_bin/systemctl"

SESSION=0
NOT_SESSION=1

assert_session() {
  local expected="$1" omarchy_path="$2" session_env="$3" description="$4" systemctl_fails="${5:-0}" actual=0

  PATH="$fake_bin:$PATH" \
  OMARCHY_PATH="$omarchy_path" \
  OMARCHY_TEST_SESSION_ENV="$session_env" \
  OMARCHY_TEST_SYSTEMCTL_FAILS="$systemctl_fails" \
    "$ROOT/bin/omarchy-shell-is-session" || actual=$?

  (( actual == expected )) || fail "$description" "expected exit $expected, got $actual"
  pass "$description"
}

assert_session $SESSION "$test_tmp/omarchy" \
  "HOME=/home/user"$'\n'"OMARCHY_PATH=$test_tmp/omarchy" \
  "the shell running from the session's tree is the session shell"

# Test copies run the shell out of a temporary tree on the same display.
assert_session $NOT_SESSION "$test_tmp/copy" \
  "OMARCHY_PATH=$test_tmp/omarchy" \
  "a shell running from another tree is not the session shell"

assert_session $SESSION "$test_tmp/omarchy-link/" \
  "OMARCHY_PATH=$test_tmp/omarchy" \
  "the same tree reached through a symlink or trailing slash still matches"

# Nothing to compare against keeps the recovery every shell had before.
assert_session $SESSION "$test_tmp/copy" \
  "HOME=/home/user" \
  "a session without a recorded path leaves every shell in charge"

assert_session $SESSION "$test_tmp/copy" \
  "" \
  "an unreachable user manager leaves every shell in charge" 1
