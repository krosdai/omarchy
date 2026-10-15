#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/fixtures/sudo-boundary-test.sh"
copy_boundary_file bin/omarchy-region
copy_boundary_file bin/omarchy-region-current
copy_boundary_file bin/omarchy-apply-pacman
mkdir -p "$SUDO_TEST_ROOT/default/regions"
cp -r "$ROOT/default/regions/cn" "$SUDO_TEST_ROOT/default/regions/"

# Root's writes under /etc land in a capture tree; the marker the reader sees
# is the capture's, so the switch reads back what it wrote.
export SUDO_TEST_CAPTURE="$boundary_tmp/capture"
export OMARCHY_REGION_FILE="$SUDO_TEST_CAPTURE/etc/omarchy/region"
mkdir -p "$SUDO_TEST_CAPTURE/etc/pacman.d"
for command in cp install rm; do
  /usr/bin/rm -f "$SUDO_TEST_ROOT/bin/$command"
  cat >"$SUDO_TEST_ROOT/bin/$command" <<STUB
#!/bin/bash
set -euo pipefail
printf 'step:$command %s\n' "\$*" >>"\$SUDO_TEST_LOG"
if [[ \${REGION_TEST_FAIL:-} == "$command \${!#}" && ! -e \$SUDO_TEST_CAPTURE/failed ]]; then : >"\$SUDO_TEST_CAPTURE/failed"; exit 1; fi
args=()
for arg in "\$@"; do
  [[ \$arg == /etc/* ]] && arg=\$SUDO_TEST_CAPTURE\$arg
  args+=("\$arg")
done
exec /usr/bin/$command "\${args[@]}"
STUB
  chmod +x "$SUDO_TEST_ROOT/bin/$command"
done
for name in omarchy-channel-current omarchy-region-user curl; do
  cat >"$SUDO_TEST_ROOT/bin/$name" <<STUB
#!/bin/bash
printf 'step:$name %s\n' "\$*" >>"\$SUDO_TEST_LOG"
if [[ \${REGION_TEST_FAIL:-} == "$name" && ! -e \$SUDO_TEST_CAPTURE/failed ]]; then : >"\$SUDO_TEST_CAPTURE/failed"; exit 1; fi
[[ $name != omarchy-channel-current ]] || echo stable
STUB
  chmod +x "$SUDO_TEST_ROOT/bin/$name"
done

start_global() {
  reset_boundary
  unset REGION_TEST_FAIL
  /usr/bin/rm -f "$SUDO_TEST_CAPTURE/etc/omarchy/region" "$SUDO_TEST_CAPTURE/failed"
  /usr/bin/cp "$ROOT/default/pacman/pacman-stable.conf" "$SUDO_TEST_CAPTURE/etc/pacman.conf"
  /usr/bin/cp "$ROOT/default/pacman/mirrorlist-stable" "$SUDO_TEST_CAPTURE/etc/pacman.d/mirrorlist"
}
switch() { "$SUDO_TEST_ROOT/bin/omarchy-region" "$1" >"$boundary_tmp/output" 2>&1; }

start_global
switch china || fail "switching to China failed" "$(<"$boundary_tmp/output")"
[[ $(<"$SUDO_TEST_CAPTURE/etc/omarchy/region") == cn ]] || fail "China writes the marker"
grep -qxF 'Server = https://pkgs.omarchy.cn/stable/$arch' "$SUDO_TEST_CAPTURE/etc/pacman.conf" || fail "China puts pkgs.omarchy.cn in pacman.conf"
[[ $(head -1 "$SUDO_TEST_CAPTURE/etc/pacman.d/mirrorlist") == 'Server = https://stable-mirror.omarchy.cn/$repo/os/$arch' ]] || fail "China puts its Arch mirror first"
python3 - "$SUDO_TEST_LOG" <<'PY'
import sys
events = open(sys.argv[1]).read().splitlines()
index = lambda prefix: next(i for i, e in enumerate(events) if e.startswith(prefix))
checks = [i for i, e in enumerate(events) if e.startswith('step:curl ')]
assert len(checks) == 2, events
assert max(checks) < index('sudo -N cp -f /etc/pacman.conf /etc/pacman.conf.bak'), events
assert index('step:omarchy-region-user cn') < index('sudo -N install '), events
assert index('sudo -N install ') == max(i for i, e in enumerate(events) if e.startswith('sudo -N ')), events
assert not any(e.startswith('sudo ') and ('bash' in e or 'omarchy-' in e) for e in events), events
PY
assert_boundary_cold "switch to China"
pass "China checks its mirrors, switches pacman and tools, and records the region last, as plain root copies"

reset_boundary
switch world || fail "switching to World failed" "$(<"$boundary_tmp/output")"
[[ ! -e $SUDO_TEST_CAPTURE/etc/omarchy/region ]] || fail "World removes the marker"
cmp "$ROOT/default/pacman/pacman-stable.conf" "$SUDO_TEST_CAPTURE/etc/pacman.conf" || fail "World restores pacman.conf byte for byte"
cmp "$ROOT/default/pacman/mirrorlist-stable" "$SUDO_TEST_CAPTURE/etc/pacman.d/mirrorlist" || fail "World restores the mirrorlist byte for byte"
grep -q '^step:omarchy-region-user global' "$SUDO_TEST_LOG" || fail "World reverts the developer tools"
! grep -q '^step:curl' "$SUDO_TEST_LOG" || fail "World needs no regional server"
assert_boundary_cold "switch to World"
pass "World restores today's pacman files byte for byte and removes the marker"

for failure in curl "cp /etc/pacman.d/mirrorlist" omarchy-region-user "install /etc/omarchy/region"; do
  start_global
  export REGION_TEST_FAIL=$failure
  if switch china; then
    fail "switching succeeds although $failure failed"
  fi
  [[ ! -e $SUDO_TEST_CAPTURE/etc/omarchy/region ]] || fail "a failed $failure leaves a China marker"
  cmp "$ROOT/default/pacman/pacman-stable.conf" "$SUDO_TEST_CAPTURE/etc/pacman.conf" || fail "a failed $failure leaves pacman.conf switched"
  cmp "$ROOT/default/pacman/mirrorlist-stable" "$SUDO_TEST_CAPTURE/etc/pacman.d/mirrorlist" || fail "a failed $failure leaves the mirrorlist switched"
  assert_boundary_cold "failed $failure"
done
pass "any failure leaves the machine on its previous region"

start_global
if switch moon; then fail "an unknown region is accepted"; fi
! grep -q '^sudo -N' "$SUDO_TEST_LOG" || fail "an unknown region reached privileged work"
pass "an unknown region is refused before any privileged work"
