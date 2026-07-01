#!/usr/bin/env bash
# Unit tests for the claudebox launcher's decision logic — runtime selection,
# the settings banner, and the runtime-specific run arguments. No real container
# runtime is needed: fake `container`/`docker` executables are placed on PATH.
# Each fake answers the probes claudebox makes (`system status`, `image inspect`)
# and, for `run`, prints the arguments it received so we can assert on them.
#
# Usage: test/unit.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CB="$ROOT/claudebox"
TMPD="$ROOT/test/.unit-tmp"
/bin/rm -rf "$TMPD"; mkdir -p "$TMPD"
trap '/bin/rm -rf "$TMPD"' EXIT

TOTAL=0; FAILED=0
ok()   { TOTAL=$((TOTAL+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && echo "        $2"; }
# assert <desc> <haystack> contains|absent <needle>
assert() {
    local desc="$1" hay="$2" mode="$3" needle="$4"
    if [[ "$mode" == contains ]]; then
        [[ "$hay" == *"$needle"* ]] && ok "$desc" || bad "$desc" "expected to find: $needle"
    else
        [[ "$hay" != *"$needle"* ]] && ok "$desc" || bad "$desc" "expected NOT to find: $needle"
    fi
}

# Create a directory of fake runtime executables. Each records nothing but
# answers probes and echoes `run` args prefixed with its own name.
make_fake() { # <dir> <name>
    local dir="$1" name="$2"
    mkdir -p "$dir"
    cat > "$dir/$name" <<EOF
#!/usr/bin/env bash
case "\$1" in
    system) exit 0 ;;          # 'system status' -> services running
    image)  exit 0 ;;          # 'image inspect X' -> image present (skip build)
    build)  exit 0 ;;
    run)    shift; printf 'RUN:%s %s\n' "$name" "\$*"; exit 0 ;;
    *)      exit 0 ;;
esac
EOF
    chmod +x "$dir/$name"
}

BOTH="$TMPD/both";     make_fake "$BOTH" container; make_fake "$BOTH" docker
DOCKERONLY="$TMPD/dk"; make_fake "$DOCKERONLY" docker
# Base PATH deliberately excludes /usr/local/bin so the *real* `container` on
# this host isn't picked up during auto-detection tests.
BASEPATH="/usr/bin:/bin"

# Run claudebox with a controlled PATH (+ optional leading env assignments).
# Captures stdout in OUT, stderr in ERR. Extra args go to claudebox.
cb() { # <fakedir> [ENV=VAL ...] -- [claudebox args...]
    local fakedir="$1"; shift
    local -a envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift || true   # drop the --
    OUT="$(env PATH="$fakedir:$BASEPATH" ${envs[@]+"${envs[@]}"} bash "$CB" "$@" 2>"$TMPD/err" </dev/null)"
    ERR="$(cat "$TMPD/err")"
}

echo "==> runtime selection"
cb "$BOTH" -- ;                         assert "auto-selects container when present" "$OUT" contains "RUN:container"
cb "$DOCKERONLY" -- ;                   assert "falls back to docker when container absent" "$OUT" contains "RUN:docker"
cb "$BOTH" CLAUDEBOX_RUNTIME=docker -- ; assert "CLAUDEBOX_RUNTIME overrides to docker" "$OUT" contains "RUN:docker"
cb "$BOTH" -- --runtime docker ;        assert "--runtime docker overrides" "$OUT" contains "RUN:docker"

echo "==> --docker is runtime-aware"
cb "$BOTH" -- --docker
assert "container: grants --cap-add ALL"          "$OUT" contains "--cap-add ALL"
assert "container: requests rootful daemon"       "$OUT" contains "CLAUDEBOX_DIND_ROOTFUL=true"
assert "container: no docker-only security-opt"   "$OUT" absent   "seccomp=unconfined"
cb "$BOTH" -- --runtime docker --docker
assert "docker: uses unconfined seccomp/apparmor" "$OUT" contains "seccomp=unconfined"
assert "docker: does NOT request rootful"         "$OUT" absent   "CLAUDEBOX_DIND_ROOTFUL"
assert "docker: does NOT grant --cap-add ALL"     "$OUT" absent   "--cap-add ALL"

echo "==> LAN firewall wiring"
cb "$BOTH" -- ;             assert "default blocks LAN (CLAUDEBOX_BLOCK_LAN)" "$OUT" contains "CLAUDEBOX_BLOCK_LAN=true"
cb "$BOTH" -- ;            assert "default adds NET_ADMIN capability"         "$OUT" contains "--cap-add NET_ADMIN"
cb "$BOTH" -- --allow-lan ; assert "--allow-lan drops the block"             "$OUT" absent   "CLAUDEBOX_BLOCK_LAN=true"

echo "==> settings banner (stderr)"
cb "$BOTH" -- --docker -p 8080:80
assert "banner header present"        "$ERR" contains "claudebox settings:"
assert "banner shows runtime"         "$ERR" contains "runtime      : container"
assert "banner shows LAN blocked"     "$ERR" contains "LAN egress   : blocked"
assert "banner shows rootful docker"  "$ERR" contains "in-sandbox daemon (rootful"
assert "banner shows published port"  "$ERR" contains "8080:80"

echo "==> --host-docker"
cb "$BOTH" DOCKER_SOCK_OVERRIDE=1 -- --host-docker
# On a host with no /var/run/docker.sock this warns; on one with it, it mounts.
if [[ -S /var/run/docker.sock ]]; then
    assert "host socket mounted at /var/run/docker.sock" "$OUT" contains ":/var/run/docker.sock"
else
    assert "warns when no host Docker socket present"    "$ERR" contains "no Docker socket found"
fi
assert "banner flags host-docker mode" "$ERR" contains "host socket (effective host root)"

echo "==> Apple Silicon hint (only meaningful on arm64 macOS)"
if [[ "$(uname)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
    cb "$DOCKERONLY" -- ;  assert "hints to install container when absent" "$ERR" contains "Apple Silicon"
    cb "$BOTH" -- ;        assert "no hint when container is available"    "$ERR" absent   "Apple Silicon"
else
    ok "Apple Silicon hint (skipped: not arm64 macOS)"
fi

echo
echo "================================="
printf "  %d/%d checks passed\n" "$((TOTAL - FAILED))" "$TOTAL"
echo "================================="
[[ $FAILED == 0 ]]
