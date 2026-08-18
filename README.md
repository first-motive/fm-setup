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
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-setup/v0.1.9/install.sh | bash -s -- --workstation
```

To read it first:

```bash
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-setup/v0.1.9/install.sh -o install.sh
less install.sh && bash install.sh --workstation
```

The curl path clones this repo into the machine's workspace — `~/fm/fm-setup`
unless the machine's identity card says otherwise — and hands over to the
checkout, because the manifest and the steps live in the repo, and a provisioned
machine needs them on disk to re-check itself later.

The workspace is not an arbitrary choice of directory. It is the card's
`workspace` field, the one visible parent every First Motive checkout shares,
and it is where the `fm` CLI looks: a copy of this repo kept anywhere else is one
`fm doctor` reports as *not cloned* on the machine that is running it. A checkout
left at the old `~/.first-motive/fm-setup` is moved into the workspace on the
next provisioning run, with a symlink left behind so existing paths still work.

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
TAG=v0.1.9
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

### Cutting A Release

The tag above appears in exactly one machine-readable place — `install.sh`'s
`FM_TAG` — because `install.sh` is the only file that ever arrives on its own,
piped into a shell with no checkout behind it to read a version from. `run.sh`
and the flash seed derive it from there at runtime; the curl one-liners in this
file and in `install.sh`'s header are text a human pastes, so they are generated
from it instead and CI fails a pull request where they disagree.

```bash
scripts/dev/release-tag.sh              # what is pinned now
scripts/dev/release-tag.sh --check      # what CI checks
scripts/dev/release-tag.sh --set vX.Y.Z # bump, then commit and tag
```

### Converging An Appliance

A Jetson in the field is not a machine anyone re-provisions by hand. `fm_ros2`'s
`fm-update-<role>.timer` ticks every ~15 minutes on each rig, and fm-setup is
one of the checkouts it converges. The entry point it calls is this repo's:

```bash
scripts/update.sh          # converge this host's role, non-interactively
scripts/update.sh --check  # what a converge would find, change nothing
```

The role comes from the machine's identity card, so no caller has to know
whether a given rig is a jetson or a workstation. `fm update` uses the same
script after a clean pull.

What that grants is worth stating plainly, because a timer that runs code as
root on every rig unattended is a real risk surface:

- **It follows tags, never a branch.** The timer only ever checks out a newer
  `v*` release tag. A commit merged to `main` and left untagged moves no machine.
- **It refuses to force anything.** A checkout with tracked modifications is
  logged and skipped, never stashed or reset.
- **It runs while nothing is in flight.** A rig mid-take is left alone and
  retried on the next tick.
- **It widens nothing.** The fleet already holds the git credentials and the
  passwordless sudo this uses; no new secret, key, or inbound path is added.

The consequence is that whoever can push a `v*` tag here decides what runs as
root on every rig. That is why `.github/CODEOWNERS` names one reviewer, and why
the tag is cut deliberately rather than on merge.

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
| `--name`, `--user` | identity (defaults `fm-rec-01`, `fm`); the name becomes the hostname, the mDNS name, and the ROS namespace |
| `--fleet`, `--transport`, `--workload` | the rest of the seeded identity card (defaults `prod`, `zenoh`, `recorder`) |
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

## The Machine Identity Card

One file per machine says what that machine is. Everything host-shaped is
derived from it rather than typed a second time somewhere else.

```
/etc/fm/machine.json          Linux
~/.config/fm/machine.json     macOS
```

```json
{
  "schema_version": 1,
  "name": "fm-rec-01",
  "role": "jetson",
  "fleet": "prod",
  "transport": "zenoh",
  "workload": "recorder",
  "workspace": "/home/fm/fm"
}
```

```
name ──┬─→ hostname
       ├─→ mDNS + tailnet name
       └─→ ROS namespace   fm-rec-01 → fm_rec_01   (derived, never typed)

transport ─→ the middleware profile every process on the host sources
workload  ─→ the comms bridge profile      (optional — see below)
workspace ─→ where every First Motive checkout lives
```

The name is shaped `fm-<abbrev>-<nn>`, so a second recorder is `fm-rec-02` and
two rigs can share a LAN. The singular `fm-jetson` this replaces could not
express that, and the collision showed up as topics that silently went nowhere.

```bash
fm machine init --name fm-rec-01   # write the card, align the hostname
fm machine show --json             # read it back, namespace included
fm machine doctor                  # check it against the schema and this host
fm machine reset                   # remove it
```

`init` is idempotent and repairs in place: fields you do not pass keep the value
already on the card, and the hostname is re-aligned to the name on every run.
`doctor` only reports — it never changes the machine, so it is safe on a host
nobody wants touched today.

`./run.sh flash` bakes the card into the cloud-init seed, so a rig boots already
knowing which recorder it is. Pass `--name` when flashing the second card of a
role.

`workload` is the one optional field. It answers what a machine *does*, which
`role` cannot: a recorder rig and a processor rig are both `jetson`, and that
gap is why `FM_BRIDGE_PROFILE` was the last per-host value anyone still typed
into an env file. It is optional because it is genuinely not universal — a GPU
workstation and a laptop run no bridge, and requiring it would force a
meaningless value onto them. Absent means this machine hosts no workload;
`--workload none` clears it when a machine is repurposed.

```bash
fm machine init --name fm-rec-01 --workload recorder
fm machine init --workload none              # repurposed; no bridge any more
```

A flashed card defaults to `recorder`, because a flashed card is a capture rig.
`machine init` has no default, because it also runs on machines with no bridge
at all.

The contract lives in `templates/machine/machine.schema.json`, which is the file
to read when a consumer in another repo needs to know what it may rely on. A
reader that finds a `schema_version` it does not know must refuse the card
rather than guess at it.

The writer is tested, because four other repos read what it produces and none
of them run this repo's CI:

```bash
./scripts/dev/test-machine.sh    # 57 cases, temp file, no root
```

A machine without a card is not broken. A laptop running the desktop app in
client mode has no workspace and needs no card; only a host that provisions,
records, or serves does.

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
├─ internal/            called by another script, never typed
└─ dev/                 developer tooling — not part of provisioning

docs/diagrams/          d2 sources + rendered svg sidecars
templates/              files a step deploys onto the machine
└─ machine/             the identity card's schema — the cross-repo contract
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

### Rehearsing The Converge

`scripts/update.sh` is a different entry point, and a more dangerous one: it is
what fm_ros2's appliance timer runs, as root, on every rig, the moment this
repo's newest `v*` tag moves. `scripts/dev/converge-check.sh` runs that entry
point in a container:

```bash
./scripts/dev/converge-check.sh             # both roles
./scripts/dev/converge-check.sh jetson      # one role
```

Per role it proves the card decides the role, that a machine with no card still
resolves one by detection, and that `install.sh --check` reports on every step.
`--check` changes nothing, which is why this can cover all fourteen steps where
a rehearsal can only afford three.

Run it before cutting a release tag. A tag here is the one action in this repo
with no undo — it reaches every rig unattended — so the path it triggers is the
one that most needs to have been run somewhere first.

Each run finishes by starting a node under every RMW in `FM_ROS_RMW_REQUIRED`.
That check exists because apt is satisfied by any one RMW provider: a role whose
list names Cyclone but not FastDDS installs cleanly, reports nothing, and then
takes every node down at start on a provisioned appliance. Asking for a package
is not the same as asking for a working middleware, so the rehearsal asserts the
second.

CI runs the jetson role on every pull request. That role ships as an appliance,
where a gap in its package list is found by someone standing next to a board.

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
| `FM_SETUP_DIR` | where the curl path clones this repo (default: `fm-setup` inside the card's workspace) |
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
| `FM_REHEARSE_PLATFORM` | container platform for `rehearse.sh` and `converge-check.sh` (default `linux/arm64`; CI sets `linux/amd64` to run native) |
| `FM_CONVERGE_IMAGE` | container image for `converge-check.sh` (default `ubuntu:22.04`) |

## License

Apache 2.0. See [LICENSE](LICENSE).
