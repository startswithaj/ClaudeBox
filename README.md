<p align="center">
  <img src="assets/claudebox-social-2x-2560x1280.png" alt="ClaudeBox" width="100%">
</p>

# ClaudeBox

Run Claude Code in a sandboxed Docker container.

It works exactly the same as running `claude` locally — same interactive interface, same commands, same config. Your project directory is mounted in so Claude can read and edit your files, and your `~/.claude` config is shared so settings, memory, and auth persist between sessions.

By default the container is sandboxed: it can reach the public internet but **not your local network** (other machines, your router, cloud metadata endpoints), and it has **no access to Docker** unless you ask for it. This makes it a reasonable place to run Claude with `--dangerously-skip-permissions`. See [Sandboxing](#sandboxing).

> **Note (macOS):** If you use a Claude subscription (Pro/Max), your auth token lives in the macOS Keychain, which the container can't read directly. claudebox reads it and forwards it into the container automatically, so auth just works. If that ever fails (you'll see a warning), run `/login` once inside the container — the token is then saved to `~/.claude` and persists across sessions.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed and running

## Prebuilt images

Each release is published to GitHub Container Registry for `linux/amd64` and `linux/arm64`, so you can skip the local build. You still need the `claudebox` wrapper script (see [Setup](#setup) below) — the prebuilt image just saves it from building one.

Pull a release and tag it as the local image the wrapper looks for:

```bash
docker pull ghcr.io/startswithaj/claudebox:latest
docker tag ghcr.io/startswithaj/claudebox:latest claudebox
```

Now run `claudebox` as usual — it finds the local `claudebox` image and won't rebuild. Pin a specific version with a tag like `:v1.0.0` instead of `:latest`. To update later, re-pull and re-tag.

> The prebuilt image includes all optional languages (Go, Python, Rust). For a smaller image — or to go back to building from source — run `claudebox --build` (see [Custom builds](#custom-builds)).

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

Publish a port so you can reach a server Claude starts inside the container. For example, if Claude runs a web frontend on port 3000 in the container, map it out and open it in your browser:

```bash
claudebox -p 3000:3000
# then visit http://localhost:3000 on your machine
```

The format is `-p HOST:CONTAINER`. Repeat the flag for multiple ports — say a frontend and its API:

```bash
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
claudebox --ssh -p 3000:3000 --docker --resume
```

## Flags

| Flag | Description |
|------|-------------|
| `--docker` | Start an isolated rootless Docker daemon inside the container (safe; host Docker untouched) |
| `--host-docker` | Mount the host Docker socket — grants host-root power and escapes the sandbox; use only when you need the host's daemon |
| `--allow-lan` | Allow the container to reach your local network (the LAN firewall is on by default) |
| `--ssh` | Forward your local SSH agent into the container for git over SSH |
| `-p`, `--port <host:container>` | Publish a container port to your host so you can reach it — e.g. `-p 3000:3000`, then open http://localhost:3000 (repeatable) |
| `--build` | (Re)build the image before launching |
| `--with <list>` | With `--build`, include only these optional languages: `go`, `python`, `rust` |
| `--help`, `-h` | Show usage and exit |

Any other arguments are passed straight through to Claude Code (e.g. `--resume`, `--model`, `--print`, `--dangerously-skip-permissions`).

## Sandboxing

claudebox is built to run Claude — including in `--dangerously-skip-permissions` mode — without giving it a path to your local network or host machine.

### Network isolation

By default, egress to private/LAN ranges (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`) is dropped inside the container, so Claude can reach the public internet but not other machines on your network, your router's admin page, or cloud metadata endpoints. DNS still works (the container's own resolvers are allowlisted).

The firewall is installed by the container's entrypoint, which then drops the `CAP_NET_ADMIN` capability before launching Claude — so Claude itself cannot flush or alter the rules, even running as root.

Allow LAN access if you actually need it (e.g. hitting a service on your host):

```bash
claudebox --allow-lan
```

### Docker access

Claude has no access to Docker unless you opt in. Two modes:

```bash
# Isolated, rootless Docker daemon inside the container. Safe: it has its own
# image cache and containers, can't see or touch your host's Docker, and a
# breakout from a nested container lands in the sandbox, not on your host.
claudebox --docker

# Mount the host's Docker socket. DANGEROUS: this is effectively root on your
# host — it lets the container escape the sandbox and bypass the LAN firewall.
# Only use it when you specifically need the host's daemon (e.g. pushing to a
# local registry or driving the host's Kubernetes) and trust the session.
claudebox --host-docker
```

`--docker` is the right choice for most "Claude needs to build/run a container" tasks. Reach for `--host-docker` only when the work genuinely targets the host's Docker.

## What's in the box

The base image always includes:

- **Node.js** 24 + npm (required by Claude Code)
- **Git**, git-lfs, ssh
- **Build tools** (gcc, cmake, pkg-config)
- **Search tools** (ripgrep, fd, jq)
- **Claude Code CLI**
- **Deno**
- **Rootless Docker** (daemon + CLI, started on demand with `--docker`)

Optional (included by default, configurable with `--with`):

- **Go** 1.24
- **Python** 3 + pip + venv
- **Rust** (stable via rustup)

## Experimental: macOS VM backend

`claudebox` sandboxes Claude in a **Linux container**. For a sandbox that mirrors
your Mac's userland exactly (BSD tools, Keychain, macOS paths) there's an
experimental **macOS VM** backend, `claudebox-vm`, built on [tart]. It clones a
prepared macOS base image, boots it, and runs Claude over SSH with your project
and credentials forwarded in. See **[claudebox-vm.md](claudebox-vm.md)** for
dependencies and setup. (Prototype — Apple Silicon only.)

Your `~/.claude` is shared into the guest so config and sessions persist, with one
exception: `settings.json` is copied in one-way instead of shared read-write. Its
`hooks` and `statusLine.command` entries are shell commands Claude executes, so a
writable share would let a sandboxed agent edit them and have that command run on
your host the next time you start Claude there. Copying it in keeps the guest's
config working while making sure guest edits can't escape back to the host.

[tart]: https://tart.run

## Testing

There are three suites. Run them after changing the Dockerfile, the entrypoint, or the `claudebox` wrapper:

```bash
test/unit.sh           # launcher logic — no runtime needed
test/run.sh            # Docker integration
test/run-container.sh  # Apple container integration (macOS only)
```

- **`test/unit.sh`** exercises the launcher's decision logic with fake `container`/`docker` executables on `PATH`, so it needs no real runtime and runs anywhere: runtime selection (`--runtime`, `CLAUDEBOX_RUNTIME`, auto-detect), the `--docker` rootful-vs-rootless split, LAN wiring, the settings banner, `--host-docker`, and the Apple Silicon hint.
- **`test/run.sh`** builds a lean image with Docker and verifies the sandbox end to end — the firewall rules, the `CAP_NET_ADMIN` drop, internet egress, LAN blocking, and rootless Docker (`--docker`). On hosts that block the user-namespace mapping rootless Docker needs (e.g. some nested CI containers), the rootless test automatically falls back to `--privileged` and says so — normal `claudebox --docker` runs unprivileged.
- **`test/run-container.sh`** is the same end-to-end check driven through Apple `container` and the rootful in-sandbox Docker path. It **skips cleanly** when `container` isn't installed.

Each exits non-zero if any check fails.

**CI note:** `unit.sh` and `run.sh` run on GitHub-hosted `ubuntu-latest`. `run-container.sh` must be run **locally on an Apple Silicon Mac** (macOS 26+) — GitHub-hosted macOS runners can't run it because Apple `container` needs nested virtualization, which those runners don't provide. Run it on your dev Mac before releasing changes that touch the container-runtime paths.
