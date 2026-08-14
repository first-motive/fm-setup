# fm-setup

Machine provisioning for First Motive. One repo defines what a First Motive host
is, so any machine can be rebuilt from a clean install without anyone
remembering what was done to the last one.

Two roles:

```
workstation   Ubuntu 26.04, RTX GPU   training, annotation, sim
jetson        Ubuntu 22.04, Orin Nano capture rig
```

fm-setup owns the **machine** layer — drivers, container runtime, ROS 2, users,
kernel tuning. [`fm_ros2`](https://github.com/first-motive/fm-ros2) owns the
workspace layer on top of it.

## Quick Start

On a machine that already has the repo:

```bash
./install.sh --workstation      # provision
./install.sh --check            # report state, change nothing
./install.sh --list             # show the role's steps
```

On a fresh machine, pin the URL to a release tag:

```bash
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-setup/v0.1.7/install.sh | bash -s -- --workstation
```

To read it first:

```bash
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-setup/v0.1.7/install.sh -o install.sh
less install.sh && bash install.sh --workstation
```

The curl path clones this repo to `~/.first-motive/fm-setup` and hands over to
the checkout, because the manifest and the steps live in the repo — and a
provisioned machine needs them on disk to re-check itself later.

### What The Curl Path Trusts

Piping a script into a shell means the script decides what to verify, so it can
never meaningfully verify itself. Being precise about that matters more than a
command that looks secure:

| fetched | verified by |
| --- | --- |
| `install.sh` | nothing — it is already running by the time anything could check it |
| `lib.sh` | `FM_LIB_SHA256`, before it is sourced |
| the checkout (every step script) | `FM_SETUP_SHA`, after the clone |

Both gates are off unless you set them. For a machine you are sitting at, TLS
and this repo are the trust anchor and that is usually enough. For one that
provisions unattended, pin all three by fetching from a commit rather than a
tag — a tag is a name and can be moved by anyone who can push; a commit sha is
the content and cannot:

```bash
TAG=v0.1.7
SHA=<commit sha for that tag>
LIB=<lib.sh sha256 for that tag>

curl -fsSL "https://raw.githubusercontent.com/first-motive/fm-setup/$SHA/install.sh" \
  | env FM_TAG="$TAG" FM_SETUP_SHA="$SHA" FM_LIB_SHA256="$LIB" \
        bash -s -- --workstation
```

Fetching `install.sh` by sha makes the first file immutable too, which is the
part no checksum inside the script can cover. A mismatch on either gate aborts
before the machine is touched.

Every release publishes both values on its
[releases page](https://github.com/first-motive/fm-setup/releases). Derive them
from a clone instead if you would rather not trust a web page:

```bash
git rev-parse "$TAG^{commit}"
git show "$TAG:lib.sh" | shasum -a 256
```

## Flashing The Jetson

The jetson role starts before the OS exists. The `flash` verb writes Canonical's
Ubuntu 22.04 Server image for Jetson Orin to an SD card and replaces the image's
cloud-init seed before the write, so the appliance's first boot needs no
monitor, keyboard, or wizard:

```bash
fm flash --device /dev/disk4                    # or: ./run.sh flash --device …
fm flash --device /dev/disk4 --wifi "rig-lan:psk"

read -rs FM_GH_TOKEN && export FM_GH_TOKEN      # token, without leaking it
fm flash --device /dev/disk4
```

![bring-up](docs/diagrams/bringup.svg)

The card boots as `fm@fm-jetson` — SSH keys injected, password login locked —
and provisions itself: this repo's jetson role, then fm_ros2's recorder service.
The recorder's overlays are private, so that second layer runs unattended only
when `--gh-token` (a read-only fine-grained PAT) was baked at flash time;
without one, first boot stops after the machine layer and leaves the remaining
one-liner in `~/NEXT-STEP.md` on the appliance.

| flag | effect |
| --- | --- |
| `--device` | target disk, whole device; internal disks are refused |
| `--hostname`, `--user` | identity (defaults `fm-jetson`, `fm` — the fleet finds the rig by them) |
| `--ssh-key` | public key to authorize (default: every `~/.ssh/*.pub`) |
| `--wifi ssid:psk` | join wifi on boot; Ethernet needs nothing |
| `--tailscale-authkey` | join the tailnet on first boot — use an ephemeral key |
| `--gh-token` | org access for the recorder's private overlays |
| `--no-provision` | identity only, no first-boot installs |
| `--dry-run` | print the plan, touch nothing |
| `-y`, `--yes` | skip the erase confirmation |

Prerequisites: the board's QSPI must carry NVIDIA's r36.x UEFI firmware — any
Orin that has booted JetPack 6 qualifies. On macOS the seed swap needs a
container runtime (OrbStack or Docker), because the image's rootfs is ext4.
balenaCLI is used to write and validate the card when present; plain `dd`
otherwise.

Pass the two secrets through the environment — `FM_GH_TOKEN` and
`FM_TS_AUTHKEY` — rather than as flags. An argument is visible in the process
table to every user on the machine and is recorded in shell history; `read -rs`
into an exported variable is neither. The flags remain for a scripted caller
that already holds the secret safely.

Whichever way they arrive, both sit in plain text in the card's seed until first
boot consumes them: hand the card straight to the Jetson, and prefer ephemeral,
least-scope credentials.

A write that fails part-way is reported, and the card is read back and compared
to the image before the verb reports success — a reader that drops off the bus
mid-write otherwise leaves a valid partition table over a half-written
filesystem, which fails at boot, far from its cause.

## The Rule

No system-level change outside a step in this repo.

If a machine needs a package, a sysctl, a udev rule, or a user, it goes in a
step and gets committed. The consequence is that the scripts are the
documentation: a prose description of a machine drifts, a script that provisions
it cannot. This applies to people and to AI agents equally — see `CLAUDE.md`.

## Layout

```
install.sh              provisioning front door — role dispatch, flag parsing
run.sh                  verb front door — dispatch to scripts/run/
lib.sh                  shared functions, sourced never executed
fm.json                 verbs mounted onto the fm CLI

scripts/
├─ manifest.sh          step registries + package arrays — data, no logic
├─ steps/               one file per provisioning step, runnable standalone
├─ run/                 person-typed verbs, each declared in fm.json
└─ dev/                 developer tooling — not part of provisioning

docs/diagrams/          d2 sources + rendered svg sidecars
templates/              files a step deploys onto the machine
```

Roles share `scripts/steps/` rather than owning a directory each, so a step both
machines need is written once and listed in both registries.

## Steps

A step is a small script with three modes and no other surface:

| mode | contract |
| --- | --- |
| `check` | report state, change nothing, always exit 0 |
| `install` | make it so, idempotently — a re-run converges |
| `uninstall` | reverse what install did, where reversible |

```bash
bash scripts/steps/00-system-update.sh check      # a step runs standalone
```

Each step sources `lib.sh` and `scripts/manifest.sh`, defines `do_check`,
`do_install`, and `do_uninstall`, then ends with `fm_dispatch "$@"`.

Adding one is two edits: write `scripts/steps/<NN>-<name>.sh`, then register it
in the role's array in `scripts/manifest.sh` as `id|file|default`.

## People

The repo holds no roster. The account that provisions a machine is its
administrator and the only one with sudo; everyone else is added afterwards into
the shared `fm` group, with no ability to change the host.

```bash
./run.sh add-user matt        # account + fm group + /data access, no sudo
sudo deluser --remove-home matt
```

New accounts have no password and log in over Tailscale SSH. The machine's
`CLAUDE.md` reaches them through `/etc/skel`.

## Backups

Before a wipe, copy what cannot be re-made and prove the copy is good:

```bash
./run.sh backup /mnt/ssd              # copy + checksum manifest + read-back verify
./run.sh backup --verify /mnt/ssd     # re-verify later, or after transport
./run.sh backup --restore /mnt/ssd    # copy back to /data, group reapplied
```

Recordings, dataset releases, and run evidence are copied. Model weights and
caches are not — they are downloads, and treating them as precious turns a
backup nobody runs into the plan.

The manifest is plain `sha256sum -c` format at the backup root, readable without
anything from this repo. The copy path verifies before reporting success, and
`--restore` verifies before writing, so a corrupt backup can never overwrite the
only other copy.

## Rehearsing A Role

Provisioning is the one thing this repo cannot test on the machine that writes
it. `scripts/dev/rehearse.sh` runs a role's package steps inside a container of
its target release:

```bash
./scripts/dev/rehearse.sh             # both roles
./scripts/dev/rehearse.sh jetson      # 22.04 aarch64
```

A container is not a machine — no systemd, no devices, no GPU — but it is a real
apt tree of the real release, which is enough to catch the failures that
actually happen: a repo that 404s, a package renamed between releases, a step
whose control flow does not survive to the end.

## Selecting Steps

```bash
./install.sh --workstation --only nvidia,docker    # run these ids only
./install.sh --workstation --skip isaac-sim        # run everything else
./install.sh --workstation --dry-run               # print the plan, touch nothing
./install.sh uninstall --jetson                    # reverse, in reverse order
```

## Environment

| variable | effect |
| --- | --- |
| `FM_SETUP_DIR` | where the curl path clones this repo (default `~/.first-motive/fm-setup`) |
| `FM_LIB_SHA256` | expected sha256 of a fetched `lib.sh`; a mismatch aborts the install |
| `FM_SETUP_SHA` | commit the bootstrapped checkout must be at; a mismatch aborts before provisioning |
| `FM_TAG` | release tag the curl path fetches and clones (default: the current release) |
| `FM_RAW_BASE` | where the curl path fetches `lib.sh` from; overridden in CI to test the pipe against a local checkout |
| `NONINTERACTIVE` | never prompt; security-sensitive steps auto-decline |
| `FM_NO_MODIFY_PATH` | skip shell-profile edits — set this in CI |
| `FM_SELFTEST` | run the CI self-test and provision nothing |
| `FM_GH_TOKEN` | org token `./run.sh flash` bakes into a card, without it reaching history or the process table |
| `FM_TS_AUTHKEY` | tailnet authkey for the same, on the same terms |
| `FM_FLASH_CACHE` | where `./run.sh flash` keeps the downloaded image (default `~/.cache/fm-setup`) |

## License

Apache 2.0. See [LICENSE](LICENSE).
