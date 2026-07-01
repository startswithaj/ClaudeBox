#!/usr/bin/env bash
# Runs INSIDE the container in place of `claude` (run.sh mounts it over the
# claude binary). The real entrypoint has already applied the firewall, started
# rootless Docker, and dropped CAP_NET_ADMIN before exec'ing this — so here we
# assert the resulting state matches what the CLAUDEBOX_* env vars requested.
# Exits non-zero if any expected condition fails, so the container's exit code
# is the test result.
status=0
pass(){ echo "  ✓ $*"; }
fail(){ echo "  ✗ $*"; status=1; }

echo "[internet] public egress + DNS resolution"
code="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' https://api.anthropic.com 2>/dev/null || echo 000)"
if [[ "$code" =~ ^[1-9][0-9][0-9]$ ]]; then pass "api.anthropic.com -> HTTP $code"; else fail "no internet ($code)"; fi

if [[ "${CLAUDEBOX_BLOCK_LAN:-false}" == "true" ]]; then
    echo "[firewall] CAP_NET_ADMIN dropped (cannot alter rules)"
    if iptables -L >/dev/null 2>&1; then fail "iptables usable — CAP_NET_ADMIN was NOT dropped"; else pass "iptables unusable"; fi

    echo "[firewall] LAN / link-local / metadata unreachable"
    blocked=true
    for ip in 10.0.0.1 192.168.0.1 169.254.169.254; do
        if curl -sS --connect-timeout 4 -o /dev/null "http://${ip}" 2>/dev/null; then fail "reached ${ip}"; blocked=false; fi
    done
    [[ "$blocked" == true ]] && pass "10.x / 192.168.x / 169.254.x all blocked"
fi

if [[ "${CLAUDEBOX_DIND:-false}" == "true" ]]; then
    # rootful under Apple container (its own micro-VM), rootless under Docker
    if [[ "${CLAUDEBOX_DIND_ROOTFUL:-false}" == "true" ]]; then
        mode="rootful"; dind_log="/var/log/dockerd.log"
    else
        mode="rootless"; dind_log="/var/log/dockerd-rootless.log"
    fi
    echo "[dind] $mode daemon reachable + runs a container"
    if docker version >/dev/null 2>&1 && docker run --rm hello-world 2>/dev/null | grep -qi "hello from docker"; then
        pass "$mode docker ran hello-world"
    else
        fail "$mode docker not working"
        echo "      --- $(basename "$dind_log") (tail) ---"
        tail -8 "$dind_log" 2>/dev/null | sed 's/^/      /'
    fi
fi

echo "RESULT: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit $status
