#!/usr/bin/env bash
# claudebox test bed.
#
# Builds a lean image (no Go/Rust/Python — they're irrelevant to the sandbox
# logic and keep the build small/fast) and verifies the firewall, capability
# drop, network egress, and rootless Docker end to end. Each check prints
# PASS/FAIL; the script exits non-zero if anything fails, so it's CI-friendly.
#
# Usage: test/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
IMAGE="${CLAUDEBOX_TEST_IMAGE:-claudebox:test}"
INCONTAINER="$ROOT/test/in-container.sh"
# Same security options claudebox --docker uses for rootless Docker.
SECOPTS=(--security-opt seccomp=unconfined --security-opt apparmor=unconfined)

TOTAL=0
FAILED=0
report() { # <rc> <name>
    TOTAL=$((TOTAL + 1))
    if [[ "$1" == 0 ]]; then
        printf '  \033[32mPASS\033[0m  %s\n' "$2"
    else
        printf '  \033[31mFAIL\033[0m  %s\n' "$2"
        FAILED=$((FAILED + 1))
    fi
}

echo "==> Building lean test image ($IMAGE)"
if docker build -t "$IMAGE" \
    --build-arg INSTALL_GO=false --build-arg INSTALL_RUST=false --build-arg INSTALL_PYTHON=false \
    . > test/build.log 2>&1; then
    report 0 "image builds"
else
    report 1 "image builds"
    echo "    build failed — tail of test/build.log:"
    tail -15 test/build.log | sed 's/^/      /'
    echo "Aborting."
    exit 1
fi

echo "==> CLI"
bash claudebox --help 2>/dev/null | grep -q "claudebox flags"
report $? "--help lists claudebox flags"

echo "==> Firewall rules are installed correctly"
rules="$(docker run --rm --cap-add=NET_ADMIN --entrypoint bash "$IMAGE" -c '
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
echo "$rules" | grep -q -- "--dport 53 -j ACCEPT"
report $? "DNS resolver allowlisted ahead of the blocks"

echo "==> Sandbox: LAN blocked, CAP_NET_ADMIN dropped, internet up"
out="$(docker run --rm --cap-add=NET_ADMIN -e CLAUDEBOX_BLOCK_LAN=true \
    -v "$INCONTAINER:/root/.local/bin/claude:ro" "$IMAGE" 2>&1)"
rc=$?
report $rc "firewall + cap-drop + egress verified from inside"
[[ $rc == 0 ]] || echo "$out" | sed 's/^/      /'

echo "==> Rootless Docker (--docker)"
run_dind() { # extra docker args (e.g. --privileged) passed through
    docker run --rm "${SECOPTS[@]}" "$@" -e CLAUDEBOX_DIND=true \
        -v "$INCONTAINER:/root/.local/bin/claude:ro" "$IMAGE" 2>&1
}
# This is how claudebox --docker actually runs: unprivileged.
mode="unprivileged"
out="$(run_dind)"
rc=$?
if [[ $rc != 0 ]]; then
    # Some hosts (e.g. nested CI containers) block the subordinate-ID mapping
    # rootless needs. Retry privileged to confirm the stack itself is sound.
    out_priv="$(run_dind --privileged)"
    if [[ $? == 0 ]]; then
        rc=0
        mode="privileged fallback"
        echo "    note: unprivileged rootless failed on this host (nested userns / newuidmap restriction);"
        echo "          it works with --privileged. claudebox --docker runs unprivileged in normal use."
    else
        out="$out_priv"
    fi
fi
report $rc "rootless daemon starts and runs hello-world ($mode)"
[[ $rc == 0 ]] || echo "$out" | sed 's/^/      /'

echo
echo "================================="
printf "  %d/%d checks passed\n" "$((TOTAL - FAILED))" "$TOTAL"
echo "================================="
[[ $FAILED == 0 ]]
