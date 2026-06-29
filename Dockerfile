# Docker CLI (+ buildx/compose plugins) sourced from the official multi-arch image
FROM docker:28-cli AS dockercli

# Rootless Docker daemon + extras. The dind-rootless image bundles both the
# daemon binaries (dockerd/containerd/runc) and the rootless launcher/rootlesskit.
FROM docker:28-dind-rootless AS dindrootless

FROM node:24-bookworm

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install core tools and languages
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Version control
    git \
    git-lfs \
    # Networking & HTTP
    curl \
    wget \
    ca-certificates \
    openssh-client \
    # Firewall for LAN egress blocking (CAP_NET_ADMIN is dropped afterwards via
    # setpriv, which ships with the base image's util-linux)
    iptables \
    # Rootless Docker prerequisites: uidmap provides the setuid
    # newuidmap/newgidmap helpers; slirp4netns + iproute2 (the `ip` command)
    # provide rootless networking
    uidmap \
    slirp4netns \
    iproute2 \
    # Build essentials
    build-essential \
    cmake \
    pkg-config \
    # Searching & file tools
    ripgrep \
    fd-find \
    jq \
    tree \
    less \
    file \
    zip \
    unzip \
    # Shell & terminal
    bash \
    bash-completion \
    tmux \
    # Process tools
    procps \
    htop \
    # Editors (for git commit messages etc.)
    vim-tiny \
    && rm -rf /var/lib/apt/lists/*

# Optional languages (all enabled by default, disable with --build-arg INSTALL_X=false)
ARG INSTALL_PYTHON=true
ARG INSTALL_GO=true
ARG INSTALL_RUST=true

# Install Python
RUN if [ "$INSTALL_PYTHON" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            python3 python3-pip python3-venv \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# Install Go
ARG GO_VERSION=1.24.2
RUN if [ "$INSTALL_GO" = "true" ]; then \
        curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xzf -; \
    fi
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"

# Install Rust
RUN if [ "$INSTALL_RUST" = "true" ]; then \
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; \
    fi
ENV PATH="/root/.cargo/bin:${PATH}"

# Install Deno (installs to $DENO_INSTALL/bin)
ENV DENO_INSTALL=/usr/local
RUN curl -fsSL https://deno.land/install.sh | sh

# Docker CLI (Docker-out-of-Docker: talks to the host daemon via the mounted
# /var/run/docker.sock). Copied from the official image above — client only, no daemon.
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins /usr/local/libexec/docker/cli-plugins

# Docker daemon + runtime for rootless Docker (started on demand by the entrypoint
# when claudebox is run with --docker). Lets the sandbox run its own isolated
# Docker without mounting the host socket or using --privileged.
COPY --from=dindrootless /usr/local/bin/dockerd /usr/local/bin/dockerd
COPY --from=dindrootless /usr/local/bin/containerd /usr/local/bin/containerd
COPY --from=dindrootless /usr/local/bin/containerd-shim-runc-v2 /usr/local/bin/containerd-shim-runc-v2
COPY --from=dindrootless /usr/local/bin/runc /usr/local/bin/runc
COPY --from=dindrootless /usr/local/bin/docker-proxy /usr/local/bin/docker-proxy
COPY --from=dindrootless /usr/local/bin/docker-init /usr/local/bin/docker-init
COPY --from=dindrootless /usr/local/bin/rootlesskit /usr/local/bin/rootlesskit
# The dind-rootless image no longer ships the launcher script, so vendor the
# version-matched one from moby. It drives rootlesskit with the builtin port
# driver, so no separate rootlesskit-docker-proxy helper is needed.
RUN curl -fsSL https://raw.githubusercontent.com/moby/moby/v28.5.2/contrib/dockerd-rootless.sh \
        -o /usr/local/bin/dockerd-rootless.sh \
    && chmod +x /usr/local/bin/dockerd-rootless.sh

# The rootless daemon runs as the unprivileged 'node' user (uid 1000, already
# present in the base image). Grant it a subordinate uid/gid range for the
# user-namespace mapping rootless Docker needs.
RUN echo "node:100000:65536" > /etc/subuid \
    && echo "node:100000:65536" > /etc/subgid

# Install Claude Code CLI via native installer
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"

# Create a symlink for fd (Debian names it fdfind)
RUN ln -sf /usr/bin/fdfind /usr/bin/fd

# Default working directory where the host pwd will be mounted
WORKDIR /workspace

# Entrypoint installs the optional LAN firewall, drops CAP_NET_ADMIN, then execs claude
COPY entrypoint.sh /usr/local/bin/claudebox-entrypoint.sh
RUN chmod +x /usr/local/bin/claudebox-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/claudebox-entrypoint.sh"]
