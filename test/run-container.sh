#!/usr/bin/env bash
# claudebox test bed for the Apple `container` runtime (macOS 26+, Apple Silicon).
#
# Mirrors test/run.sh but drives Apple `container` and the rootful in-sandbox
# Docker path (CLAUDEBOX_DIND_ROOTFUL). Skips cleanly if `container` isn't
# installed/running, so it's a no-op on Linux CI. Builds a lean image, then
# verifies the firewall, capability drop, network egress, and Docker end to end.
#
# Run this LOCALLY on an Apple Silicon Mac (macOS 26+). GitHub-hosted macOS
# runners can't run it — Apple `container` needs nested virtualization, which
# those runners don't provide; use a self-hosted Mac runner for CI.
#
# Usage: test/run-container.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
IMAGE="${CLAUDEBOX_TEST_IMAGE:-claudebox:test}"
INCONTAINER="$ROOT/test/in-container.sh"

if ! command -v container >/dev/null 2>&1 || ! container system status >/dev/null 2>&1; then
    echo "SKIP: Apple 'container' is not installed/running (needs macOS 26+, Apple Silicon)."
    exit 0
fi

TOTAL=0; FAILED=0
report() { # <rc> <name>
    TOTAL=$((TOTAL + 1))
    if [[ "$1" == 0 ]]; then printf '  \033[32mPASS\033[0m  %s\n' "$2"
    else printf '  \033[31mFAIL\033[0m  %s\n' "$2"; FAILED=$((FAILED + 1)); fi
}

echo "==> Building lean test image ($IMAGE) with container"
if container build -t "$IMAGE" \
    --build-arg INSTALL_GO=false --build-arg INSTALL_RUST=false --build-arg INSTALL_PYTHON=false \
    . > test/build-container.log 2>&1; then
    report 0 "image builds"
else
    report 1 "image builds"
    echo "    build failed — tail of test/build-container.log:"
    tail -15 test/build-container.log | sed 's/^/      /'
    echo "Aborting."; exit 1
fi

echo "==> Firewall rules are installed correctly"
rules="$(container run --rm --cap-add NET_ADMIN --entrypoint bash "$IMAGE" -c '
    eval "$(sed -n "/^apply_lan_firewall()/,/^}/p" /usr/local/bin/claudebox-entrypoint.sh)"
    apply_lan_firewall
    iptables -S OUTPUT
    iptables -S FORWARD' 2>/dev/null)"
miss=0
for r in '10.0.0.0/8' '172.16.0.0/12' '192.168.0.0/16' '169.254.0.0/16'; do
    echo "$rules" | grep -q -- "-A OUTPUT -d $r -j REJECT" || miss=1
    echo "$rules" | grep -q -- "-A FORWARD -d $r -j REJECT" || miss=1
done
report $miss "private ranges REJECTed on OUTPUT + FORWARD"

echo "==> Sandbox: LAN blocked, CAP_NET_ADMIN dropped, internet up"
out="$(container run --rm --cap-add NET_ADMIN -e CLAUDEBOX_BLOCK_LAN=true \
    -v "$INCONTAINER:/root/.local/bin/claude:ro" "$IMAGE" 2>&1)"
rc=$?
report $rc "firewall + cap-drop + egress verified from inside"
[[ $rc == 0 ]] || echo "$out" | sed 's/^/      /'

echo "==> Rootful Docker (--docker under container)"
# How claudebox --docker runs under Apple container: full caps in the micro-VM,
# rootful daemon (CLAUDEBOX_DIND_ROOTFUL). Full power stays inside the VM.
out="$(container run --rm --cap-add ALL \
    -e CLAUDEBOX_DIND=true -e CLAUDEBOX_DIND_ROOTFUL=true \
    -v "$INCONTAINER:/root/.local/bin/claude:ro" "$IMAGE" 2>&1)"
rc=$?
report $rc "rootful daemon starts and runs hello-world"
[[ $rc == 0 ]] || echo "$out" | sed 's/^/      /'

echo
echo "================================="
printf "  %d/%d checks passed\n" "$((TOTAL - FAILED))" "$TOTAL"
echo "================================="
[[ $FAILED == 0 ]]
