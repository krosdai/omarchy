#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch/home" CARGO_HOME="$scratch/home/.cargo" OMARCHY_PATH="$ROOT"
mkdir -p "$HOME" "$scratch/bin"
# The live session's environment is a log, never the host's systemd.
export SYSTEMCTL_LOG="$scratch/systemctl"
cat >"$scratch/bin/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
STUB
chmod +x "$scratch/bin/systemctl"
export PATH="$scratch/bin:$PATH"
user() { "$ROOT/bin/omarchy-region-user" "$@"; }

user cn
grep -qF 'registry = "sparse+https://mirrors.aliyun.com/crates.io-index/"' "$CARGO_HOME/config.toml" ||
  fail "China points cargo at the regional crates.io index" "$(cat "$CARGO_HOME/config.toml")"
user cn
[[ $(grep -c '^\[source.crates-io\]' "$CARGO_HOME/config.toml") == 1 ]] || fail "applying China twice adds one block"
user global
[[ ! -e $CARGO_HOME/config.toml ]] || fail "World removes a cargo config only the region wrote"
pass "the cargo registry follows the region and World removes it"

printf '[build]\njobs = 4\n\n[net]\nretry = 5\n' >"$CARGO_HOME/config.toml"
cp "$CARGO_HOME/config.toml" "$scratch/before.toml"
user cn
user global
cmp "$scratch/before.toml" "$CARGO_HOME/config.toml" || fail "World restores the user's cargo config byte for byte" "$(diff "$scratch/before.toml" "$CARGO_HOME/config.toml")"
pass "the user's own cargo config survives China and World byte for byte"

printf '[source.crates-io]\nreplace-with = "mine"\n' >"$CARGO_HOME/config.toml"
cp "$CARGO_HOME/config.toml" "$scratch/own.toml"
user cn 2>/dev/null
cmp "$scratch/own.toml" "$CARGO_HOME/config.toml" || fail "China leaves a user's own crates.io replacement alone"
rm "$CARGO_HOME/config.toml"
pass "a user's own crates.io replacement is left alone"

: >"$SYSTEMCTL_LOG"
user cn
grep -q '^--user set-environment .*GOSUMDB=sum.golang.google.cn' "$SYSTEMCTL_LOG" || fail "China updates the running session" "$(cat "$SYSTEMCTL_LOG")"
grep -q "MAVEN_ARGS=--global-settings $ROOT/default/regions/cn/maven-settings.xml" "$SYSTEMCTL_LOG" || fail "Maven settings come from OMARCHY_PATH" "$(cat "$SYSTEMCTL_LOG")"
: >"$SYSTEMCTL_LOG"
user global
grep -q '^--user unset-environment .*NPM_CONFIG_REGISTRY' "$SYSTEMCTL_LOG" && ! grep -q 'set-environment' <(grep -v unset "$SYSTEMCTL_LOG") ||
  fail "World clears the running session's registries" "$(cat "$SYSTEMCTL_LOG")"
pass "the running session's registries follow the region"

# Shells read the registries from the marker through env-bootstrap.
printf 'OMARCHY_PATH=%q\n' "$ROOT" >"$scratch/omarchy.conf"
sed "s#/etc/omarchy.conf#$scratch/omarchy.conf#g" "$ROOT/default/bash/env-bootstrap" >"$scratch/env-bootstrap"
shell_env() {
  env -i HOME="$HOME" PATH=/usr/bin:/bin OMARCHY_REGION_FILE="$scratch/region" ${1:+"$1"} \
    sh -c '. "$0"; env' "$scratch/env-bootstrap"
}
rm -f "$scratch/region"
! shell_env | grep -qE '^(NPM_CONFIG_REGISTRY|GOPROXY|GOSUMDB|MAVEN_ARGS)=' || fail "World exports no registries"
printf 'cn\n' >"$scratch/region"
env_cn=$(shell_env)
grep -qx 'GOSUMDB=sum.golang.google.cn' <<<"$env_cn" || fail "China exports a reachable Go checksum database" "$env_cn"
grep -qx 'NPM_CONFIG_REGISTRY=https://registry.npmmirror.com' <<<"$env_cn" || fail "China exports the npm mirror"
grep -qx 'NPM_CONFIG_REGISTRY=https://example.invalid/npm' <<<"$(shell_env NPM_CONFIG_REGISTRY=https://example.invalid/npm)" ||
  fail "a registry the user set first is kept"
printf '../x\n' >"$scratch/region"
! shell_env | grep -q '^GOPROXY=' || fail "a malformed marker exports nothing"
pass "shells export the region's registries only for China, and keep the user's own"
