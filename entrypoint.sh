#!/usr/bin/env bash
# claudebox entrypoint. Two optional, independent setup steps run before Claude:
#
#   CLAUDEBOX_BLOCK_LAN=true  Firewall off the local network. The container can
#                             still reach the public internet but not other hosts
#                             on your LAN, your router, or cloud metadata. Rules
#                             are installed here with CAP_NET_ADMIN, which is then
#                             dropped (via setpriv) so Claude can't flush them —
#                             even as root.
#
#   CLAUDEBOX_DIND=true       Start an isolated, rootless Docker daemon inside the
#                             container so Claude can build/run containers without
#                             the host socket or --privileged. An escape from a
#                             nested container lands in this unprivileged box, not
#                             on the host.
set -euo pipefail

# Tell Claude it's running in a sandbox. Claude refuses
# --dangerously-skip-permissions as root unless this is set; inside this
# container Claude runs as root and the container itself is the sandbox, so the
# flag is safe to allow here.
export IS_SANDBOX=1

FIREWALL_APPLIED=false

apply_lan_firewall() {
    if ! command -v iptables >/dev/null 2>&1; then
        echo "Warning: CLAUDEBOX_BLOCK_LAN=true but iptables is unavailable; LAN is NOT blocked." >&2
        return
    fi

    # Allow DNS to whatever resolvers the container was assigned first, even if
    # they're private. Docker (notably Docker Desktop) often hands the container
    # a private nameserver, so blocking the LAN outright would break name
    # resolution. First-match-wins, so these ACCEPTs precede the REJECTs below.
    while read -r kw addr _; do
        [[ "$kw" == "nameserver" ]] || continue
        iptables -A OUTPUT -d "$addr" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -A OUTPUT -d "$addr" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
    done < /etc/resolv.conf

    # Drop egress to LAN / link-local / metadata ranges. Internet-bound traffic
    # carries a public destination IP and is unaffected, even though it's routed
    # via the private bridge gateway. OUTPUT covers traffic the container sends
    # itself (incl. rootless Docker's userspace networking); FORWARD covers any
    # nested-container traffic that is routed rather than locally generated.
    for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
        iptables -A OUTPUT  -d "$cidr" -j REJECT --reject-with icmp-net-prohibited 2>/dev/null \
            || iptables -A OUTPUT  -d "$cidr" -j DROP
        iptables -A FORWARD -d "$cidr" -j REJECT --reject-with icmp-net-prohibited 2>/dev/null \
            || iptables -A FORWARD -d "$cidr" -j DROP
    done

    FIREWALL_APPLIED=true
}

start_rootless_dockerd() {
    local uid=1000
    local runtime_dir="/run/user/${uid}"
    local sock="${runtime_dir}/docker.sock"

    mkdir -p "$runtime_dir"
    chown node:node "$runtime_dir"
    chmod 700 "$runtime_dir"

    # Launch the rootless daemon as the unprivileged 'node' user in the
    # background. It creates its own user+network namespace via rootlesskit, so
    # it doesn't need (and won't inherit) the parent's CAP_NET_ADMIN.
    setpriv --reuid=node --regid=node --init-groups \
        env HOME=/home/node \
            XDG_RUNTIME_DIR="$runtime_dir" \
            PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            dockerd-rootless.sh >/var/log/dockerd-rootless.log 2>&1 &

    # Point the (root) docker CLI Claude runs at the rootless daemon's socket.
    export DOCKER_HOST="unix://${sock}"

    # Wait up to ~30s for the daemon to come up.
    for _ in $(seq 1 60); do
        if [[ -S "$sock" ]]; then
            return
        fi
        sleep 0.5
    done
    echo "Warning: rootless dockerd did not become ready in time; see /var/log/dockerd-rootless.log" >&2
}

start_rootful_dockerd() {
    # Under Apple `container` the box is its own micro-VM, so a normal rootful
    # daemon is both the simplest option and safe — full privileges stay inside
    # the disposable VM. dockerd defaults to the /var/run/docker.sock the (root)
    # docker CLI already talks to, so no DOCKER_HOST is needed.
    dockerd >/var/log/dockerd.log 2>&1 &

    # Wait up to ~30s for the daemon to accept connections.
    for _ in $(seq 1 60); do
        if docker info >/dev/null 2>&1; then
            return
        fi
        sleep 0.5
    done
    echo "Warning: rootful dockerd did not become ready in time; see /var/log/dockerd.log" >&2
}

if [[ "${CLAUDEBOX_BLOCK_LAN:-false}" == "true" ]]; then
    apply_lan_firewall
fi

if [[ "${CLAUDEBOX_DIND:-false}" == "true" ]]; then
    # Apple container gives the box its own kernel, so it runs a rootful daemon
    # (CLAUDEBOX_DIND_ROOTFUL); Docker uses the rootless daemon to avoid needing
    # host privileges.
    if [[ "${CLAUDEBOX_DIND_ROOTFUL:-false}" == "true" ]]; then
        start_rootful_dockerd
    else
        start_rootless_dockerd
    fi
fi

# Materialise the macOS Keychain credential (forwarded as an env var) into the
# file Claude reads, then drop it from the environment so Claude's own process
# doesn't carry the token. No-op on Linux hosts, where the credential is already
# a file in the mounted ~/.claude.
if [[ -n "${CLAUDEBOX_CREDENTIALS:-}" ]]; then
    mkdir -p /root/.claude
    install -m 600 /dev/null /root/.claude/.credentials.json
    printf '%s' "$CLAUDEBOX_CREDENTIALS" > /root/.claude/.credentials.json
    unset CLAUDEBOX_CREDENTIALS
fi

# If we installed the firewall, drop CAP_NET_ADMIN from the bounding set before
# exec'ing Claude. On exec the kernel recomputes even a root process's permitted
# set as (file caps | root-default) & bounding set, so removing it here means
# Claude starts without it and can't reacquire it to undo the firewall.
if [[ "$FIREWALL_APPLIED" == true ]]; then
    exec setpriv --bounding-set -net_admin claude "$@"
fi

exec claude "$@"
