#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

fake_bin="$test_tmp/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/quickshell" <<'SH'
#!/bin/bash

[[ $* == "list --all --json" ]] || exit 1
printf '%s\n' "$OMARCHY_TEST_INSTANCES"
SH

# Each instance answers by its OMARCHY_PATH, looked up in a name=status table.
cat >"$fake_bin/omarchy-shell" <<'SH'
#!/bin/bash

[[ $* == "lock status" ]] || exit 1
while IFS='=' read -r root status; do
  if [[ $root == "$OMARCHY_PATH" ]]; then
    [[ $status == "silent" ]] && exit 1
    printf '%s\n' "$status"
    exit 0
  fi
done <<<"$OMARCHY_TEST_LOCK_STATUS"
exit 1
SH
chmod +x "$fake_bin/quickshell" "$fake_bin/omarchy-shell"

HELD=0
NOT_HELD=1

SECURE='{"secure":true,"requested":true}'
LOCKING='{"secure":false,"requested":true}'
IDLE='{"secure":false,"requested":false}'

instance() {
  printf '{"pid":%s,"config_path":"%s/shell/shell.qml"}' "$1" "$2"
}

assert_held() {
  local expected="$1" instances="$2" statuses="$3" description="$4" expected_holder="${5:-}" actual=0 output

  output=$(PATH="$fake_bin:$PATH" \
    OMARCHY_TEST_INSTANCES="$instances" \
    OMARCHY_TEST_LOCK_STATUS="$statuses" \
    "$ROOT/bin/omarchy-shell-lock-held" 100) || actual=$?

  (( actual == expected )) || fail "$description" "expected exit $expected, got $actual"
  [[ $output == "$expected_holder" ]] || fail "$description" "expected holder '$expected_holder', got '$output'"
  pass "$description"
}

# The healthy desktop shell holds the lock while a test copy starts up.
assert_held $HELD \
  "[$(instance 100 /tmp/test-copy),$(instance 200 /usr/share/omarchy)]" \
  "/tmp/test-copy=$IDLE"$'\n'"/usr/share/omarchy=$SECURE" \
  "a secure lock held by another shell is reported with its holder" \
  "/usr/share/omarchy/shell/shell.qml"

assert_held $HELD \
  "[$(instance 100 /tmp/test-copy),$(instance 200 /usr/share/omarchy)]" \
  "/usr/share/omarchy=$LOCKING" \
  "a lock another shell is still taking counts as held" \
  "/usr/share/omarchy/shell/shell.qml"

# The asking shell's own answer must not count, or a shell would never recover.
assert_held $NOT_HELD \
  "[$(instance 100 /usr/share/omarchy)]" \
  "/usr/share/omarchy=$SECURE" \
  "the asking shell is left out of the search"

assert_held $NOT_HELD \
  "[$(instance 100 /tmp/test-copy),$(instance 200 /usr/share/omarchy)]" \
  "/usr/share/omarchy=$IDLE" \
  "another shell that holds no lock leaves the lock stranded"

# A shell that cannot answer has no lock screen worth preserving.
assert_held $NOT_HELD \
  "[$(instance 100 /tmp/test-copy),$(instance 200 /usr/share/omarchy)]" \
  "/usr/share/omarchy=silent" \
  "an unresponsive shell does not hold the lock"

assert_held $NOT_HELD \
  '[{"pid":200,"config_path":"/home/user/.config/quickshell/bar.qml"}]' \
  "" \
  "a Quickshell instance that is not an Omarchy shell is ignored"

assert_held $NOT_HELD \
  '[]' \
  "" \
  "no other shell means nothing holds the lock"
