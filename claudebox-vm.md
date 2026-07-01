# claudebox-vm

Run Claude Code inside an isolated **macOS virtual machine** (a host-parity
sandbox), instead of a Linux container. Because the guest is real macOS, the
sandbox mirrors your Mac's userland exactly — BSD tools, Keychain, macOS paths —
which a Linux container can't do. It's built on [tart], which drives Apple's
Virtualization.framework: an APFS copy-on-write clone of a prepared base image,
headless boot, and SSH.

> **Status: prototype.** It works end to end (clone → boot → SSH → mount → seed
> credentials → run Claude), but expect rough edges. See Caveats.

## Dependencies

You need all of these on the host:

| Dependency | Why | Install / note |
| --- | --- | --- |
| **Apple Silicon Mac** | Virtualization.framework macOS guests are arm64 only | M1 or newer |
| **macOS 13+** (host) | Required by tart / the framework | Sonoma+ recommended |
| **Homebrew** | to install tart | https://brew.sh |
| **tart** | runs the VM | `brew install cirruslabs/cli/tart` (see note below) |
| **~60 GB free disk** | the macOS base image is ~50 GB, plus a running clone | check `df -h /System/Volumes/Data` |
| **An SSH keypair** | non-interactive login to the guest | `~/.ssh/id_ed25519` (or generate one) |
| **`sshpass`** | only for the one-time base prep (first login uses `admin`/`admin`) | `brew install sshpass` |
| **A prepared base VM** named `claudebox-base` | the template that gets cloned per run | one-time setup below |
| **Claude credential in your Keychain** | forwarded into the VM so Claude is logged in | already there if you use Claude Code on macOS |

Note: newer Homebrew gates third-party taps, so you may need to trust the tap
first:

```sh
brew trust cirruslabs/cli
brew install cirruslabs/cli/tart
```

## One-time base setup

`claudebox-vm` clones a prepared base image called `claudebox-base` on every run.
Build it once:

```sh
# 1. Pull a minimal macOS base (vanilla = smallest; ~50 GB on disk)
tart clone ghcr.io/cirruslabs/macos-sequoia-vanilla:latest claudebox-base

# 2. Boot it headless to provision it
tart run claudebox-base --no-graphics &
ip=$(tart ip claudebox-base)      # wait a few seconds for it to appear

# 3. Trust your SSH key (first login is admin/admin via sshpass)
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@"$ip" \
  "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < ~/.ssh/id_ed25519.pub

# 4. Install the Claude CLI in the guest
ssh admin@"$ip" 'curl -fsSL https://claude.ai/install.sh | bash'

# 5. Shut it down cleanly — this is now your golden base
tart stop claudebox-base
```

Optionally provision the base further (brew, dotfiles, tools) to match your host
— that's the "mirror my Mac" step, and it's manual: the base drifts from your
host until you re-provision.

## Usage

```sh
claudebox-vm [flags] [claude args...]
```

From any project directory. Each run: APFS-clones the base, boots it, mounts the
project at its real host path, links your `~/.claude` and copies `~/.claude.json`
in, seeds the Claude Keychain credential, runs Claude, then **deletes the clone
on exit**.

Examples:

```sh
claudebox-vm                       # interactive Claude TUI, in a macOS VM
claudebox-vm --print "hello"       # non-interactive
claudebox-vm --cpus 6 --memory 12288
claudebox-vm --keep                # don't delete the clone on exit (debug)
```

### Flags and env

| Flag | Env | Default |
| --- | --- | --- |
| `--base <name>` | `CLAUDEBOX_VM_BASE` | `claudebox-base` |
| `--cpus <n>` | `CLAUDEBOX_VM_CPUS` | `4` |
| `--memory <MiB>` | `CLAUDEBOX_VM_MEMORY` | `8192` |
| `--user <name>` | `CLAUDEBOX_VM_USER` | `admin` |
| `--keep` | — | off (clone is deleted on exit) |
| — | `CLAUDEBOX_VM_PASS` | `admin` (guest Keychain unlock password) |

Any unrecognized args are passed through to `claude`.

## What crosses into the VM

- **The project**, mounted at its real host path (so Claude's session files line
  up with a native run).
- **`~/.claude/`**, mounted read-write (settings, memory, sessions) — note this
  means Claude in the VM writes back to your host `~/.claude`.
- **`~/.claude.json`**, copied in (account state + settings; needed for the TUI
  to show you as logged in).
- **One Keychain item** — `Claude Code-credentials` only — seeded into the guest
  Keychain over SSH. No other Keychain entries or secrets are copied.

## Caveats

- **Boot time** is ~30–60s per run (the CoW clone is instant; macOS boot is the
  cost).
- **`~/.claude` is read-write**, so the VM mutates your host `~/.claude`.
- The guest Keychain unlock uses the base image's default password (`admin` for
  cirruslabs images) via `CLAUDEBOX_VM_PASS`.
- macOS EULA allows at most **2 macOS VMs per physical Mac**.
- No in-VM LAN firewall yet (the container backend blocks LAN egress; the VM
  backend does not — it's on the TODO list).

[tart]: https://tart.run
