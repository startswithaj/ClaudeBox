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

# Install Claude Code CLI via native installer
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"

# Create a symlink for fd (Debian names it fdfind)
RUN ln -sf /usr/bin/fdfind /usr/bin/fd

# Default working directory where the host pwd will be mounted
WORKDIR /workspace

ENTRYPOINT ["claude"]
