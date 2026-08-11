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
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-setup/v0.1.0/install.sh | bash -s -- --workstation
```

To read it first:

```bash
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-setup/v0.1.0/install.sh -o install.sh
less install.sh && bash install.sh --workstation
```

The curl path clones this repo to `~/.first-motive/fm-setup` and hands over to
the checkout, because the manifest and the steps live in the repo — and a
provisioned machine needs them on disk to re-check itself later.

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
└─ run/                 person-typed verbs, each declared in fm.json
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
| `FM_TAG` | ref the curl path fetches and clones (default `main`; pin a release tag) |
| `NONINTERACTIVE` | never prompt; security-sensitive steps auto-decline |
| `FM_NO_MODIFY_PATH` | skip shell-profile edits — set this in CI |
| `FM_SELFTEST` | run the CI self-test and provision nothing |

## License

Apache 2.0. See [LICENSE](LICENSE).
