#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

zone=$(<"$ROOT/default/regions/cn/timezone")
[[ $zone == "Asia/Shanghai" ]] || fail "China profile names Asia/Shanghai"
[[ -f /usr/share/zoneinfo/$zone ]] || fail "China profile timezone exists in tzdata"
pass "China profile defaults to an existing Asia/Shanghai zone"

# Load the real region_timezone() from the first-boot command.
OMARCHY_PATH="$ROOT"
REGION_MARKER="$scratch/region"
eval "$(sed -n '/^region_timezone() {/,/^}/p' "$ROOT/bin/omarchy-provision-owner")"

[[ -z $(region_timezone) ]] || fail "missing region marker offers no timezone"
for region in global CN ../cn zz ""; do
  printf '%s\n' "$region" >"$REGION_MARKER"
  [[ -z $(region_timezone) ]] || fail "region '$region' offers no timezone"
done
pass "global, unknown, and malformed regions offer no timezone"

printf 'cn\n' >"$REGION_MARKER"
[[ $(region_timezone) == "Asia/Shanghai" ]] || fail "cn region offers Asia/Shanghai"
pass "cn region offers its profile timezone"

grep -qF 'omarchy_prompt_timezone "$(region_timezone)"' "$ROOT/bin/omarchy-provision-owner" ||
  fail "first-boot setup passes the region timezone to the prompt"
pass "first-boot setup preselects the region timezone"
