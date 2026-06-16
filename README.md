# claudebox

Run Claude Code in a sandboxed Docker container.

It works exactly the same as running `claude` locally — same interactive interface, same commands, same config. Your project directory is mounted in so Claude can read and edit your files, and your `~/.claude` config is shared so settings, memory, and auth persist between sessions.

> **Note (macOS):** If you use a Claude subscription (Pro/Max), your auth token is stored in the macOS Keychain, which the container can't access. You'll need to re-authenticate with `/login` the first time you launch claudebox. After that, the token is saved to `~/.claude` and persists across sessions.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed and running

## Setup

1. Clone the repo:

```bash
git clone https://github.com/youruser/claudebox.git
```

2. Add it to your PATH (pick one):

```bash
# bash
echo 'export PATH="$PATH:$HOME/claudebox"' >> ~/.bashrc
source ~/.bashrc

# zsh
echo 'export PATH="$PATH:$HOME/claudebox"' >> ~/.zshrc
source ~/.zshrc
```

Adjust the path if you cloned it somewhere other than `$HOME/claudebox`.

3. (Optional) Alias `claude` to `claudebox`:

```bash
# bash
echo 'alias claude="claudebox"' >> ~/.bashrc
source ~/.bashrc

# zsh
echo 'alias claude="claudebox"' >> ~/.zshrc
source ~/.zshrc
```

## Usage

```bash
# Just run it — the Docker image builds automatically on first launch
claudebox
```

All arguments are passed through to Claude Code:

```bash
claudebox --resume
claudebox --print "explain this repo"
claudebox --model sonnet
```

### Port forwarding

Expose ports from the container to your machine (useful when Claude spins up a dev server):

```bash
claudebox -p 3000:3000
claudebox -p 3000:3000 -p 8080:8080
```

### SSH agent forwarding

Forward your local SSH agent into the container for git operations over SSH:

```bash
claudebox --ssh
```

### Custom builds

Rebuild the image at any time:

```bash
claudebox --build
```

Only include specific languages to keep the image smaller:

```bash
claudebox --build --with go,python
claudebox --build --with rust
```

Available tools: `go`, `python`, `rust`. All are included by default.

Node.js and npm are always included as they are required by Claude Code.

### Combining flags

Claudebox flags and Claude flags can be mixed freely:

```bash
claudebox --ssh -p 3000:3000 --resume
```

## What's in the box

The base image always includes:

- **Node.js** 24 + npm (required by Claude Code)
- **Git**, git-lfs, ssh
- **Build tools** (gcc, cmake, pkg-config)
- **Search tools** (ripgrep, fd, jq)
- **Claude Code CLI**

Optional (included by default, configurable with `--with`):

- **Go** 1.24
- **Python** 3 + pip + venv
- **Rust** (stable via rustup)
