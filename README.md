# fm-setup

Machine provisioning for First Motive. One repo defines what a First Motive host
is, so any machine can be rebuilt from a clean install without anyone
remembering what was done to the last one.

Four roles:

```
workstation   Ubuntu 26.04, RTX GPU          training, annotation, sim
jetson        Ubuntu 22.04, Orin Nano        capture rig
trainer       Ubuntu 26.04, cloud GPU        training only
sim-cloud     Ubuntu 24.04/26.04, cloud GPU  sim runs, unattended
```

`trainer` and `sim-cloud` are the roles hardware detection cannot find — a cloud
GPU instance looks exactly like a tower — so each is named with its flag and
recorded on the machine's card, which every converge afterwards reads.
`sim-cloud` is provisioned only by fm-sim's AWS stack; see
[Cloud Sim Host](#cloud-sim-host).

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
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-setup/v0.1.40/install.sh | bash -s -- --workstation
```

To read it first:

```bash
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-setup/v0.1.40/install.sh -o install.sh
less install.sh && bash install.sh --workstation
```

The curl path clones this repo into the machine's workspace — `/opt/fm/fm-setup`
unless the machine's identity card says otherwise — and hands over to the
checkout, because the manifest and the steps live in the repo, and a provisioned
machine needs them on disk to re-check itself later.

Every package a step installs is recorded against that step, in a ledger under
`/var/lib/fm-setup/pkgs`. That is what lets one step be uninstalled without
taking another's dependencies with it: a removal that would reach outside the
step's own ledger aborts and names what it would have taken. `--check` ends by
reporting drift — packages, units enabled since the machine was provisioned, and
`/etc` changes that no step accounts for — and `fm pkg add <name>` records a one-off so it is accounted for
from the moment it lands.

The workspace is not an arbitrary choice of directory. It is the card's
`workspace` field, the one visible parent every First Motive checkout shares,
and it is where the `fm` CLI looks: a copy of this repo kept anywhere else is one
`fm doctor` reports as *not cloned* on the machine that is running it. A checkout
left at the old `~/.first-motive/fm-setup` is moved into the workspace on the
next provisioning run, with a symlink left behind so existing paths still work.

There are two workspaces on a shared machine, and the difference matters:

| whose | where | named by |
| --- | --- | --- |
| the machine's | `/opt/fm`, group `fm`, mode 3775 | the card |
| a person's | `~/fm` | their own `FM_HOME` |

The machine's is what the card names and what services read, so it lives outside
every home directory — a home is mode 700 on Ubuntu, and a workspace inside one
is readable by exactly one account. A person's own outranks the card, which is
why `fm setup-onboard` writes `FM_HOME` and nothing else has to. A machine
provisioned before this split keeps `/home/fm/fm` until `fm machine init` moves
its card; `machine doctor` says so in the meantime, and `/home/fm/fm` stays
reachable afterwards through a symlink.

Mode 3775 hands a new checkout the right group and no write bit, so a clone made
under the default umask of 022 is one only its cloner can update — and the
symptom is quiet. `git fetch` fails on `.git/FETCH_HEAD` for everybody else,
while `fm doctor` keeps reporting the repo up to date from refs that stopped
moving. The workspace step repairs that: each checkout is set to group `fm`,
group-writable files and directories, setgid on the directories so the next
file lands the same way, and `core.sharedRepository=group` so git keeps
creating them that way. Files, not only directories — git rewrites
`.git/FETCH_HEAD` in place, so a writable directory around a `644` file changes
nothing. `--check` names a checkout the group cannot write.

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
TAG=v0.1.40
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

The front door is `fm release`, not a script in this repo. It checks that CI is
green on the commit a tag would land on before anything is tagged, and only then
delegates to `scripts/dev/cut-release.sh` here:

```bash
fm release --repo fm-setup                    # is the next tag safe to cut?
fm release --repo fm-setup --cut -- --apply   # gate, then cut and push the tag
```

Calling the script directly skips that gate, which is why a hook blocks it and
points back at the verb. What the verb delegates to:

```bash
scripts/dev/cut-release.sh              # print the plan, change nothing
scripts/dev/cut-release.sh --apply      # create and push the tag
scripts/dev/cut-release.sh --set vX.Y.Z # prepare the bump commit for a PR
```

The release is two halves. A tag a rig resolves at flash time is one; the
version written into the files a human pastes from is the other.

The tag appears in exactly one machine-readable place — `install.sh`'s `FM_TAG` —
because `install.sh` is the only file that ever arrives on its own, piped into a
shell with no checkout behind it to read a version from. `run.sh` and the flash
seed derive it from there at runtime; the curl one-liners in this file and in
`install.sh`'s header are text a human pastes, so they are generated from it
instead and CI fails a pull request where they disagree. `release-tag.sh` owns
that half, and `cut-release.sh` reads it rather than repeating it:

```bash
scripts/dev/release-tag.sh              # what is pinned now
scripts/dev/release-tag.sh --check      # what CI checks
scripts/dev/release-tag.sh --set vX.Y.Z # bump the pinned version, for a PR
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

## Flashing A Machine

Both roles start before the OS exists. The `flash` verb writes the role's pinned
image to removable media and puts a seed on it that answers every question the
first boot would otherwise ask, so neither machine needs a monitor, a keyboard,
or a wizard.

```bash
# The capture rig — an SD card for the Jetson.
fm flash --device /dev/disk4                    # or: ./run.sh flash --device …
fm flash --device /dev/disk4 --wifi "rig-lan:psk"

read -rs FM_GH_TOKEN && export FM_GH_TOKEN      # token, without leaking it
fm flash --device /dev/disk4
```

```bash
# The GPU workstation — a USB stick for Ubuntu Desktop.
read -rs FM_FLASH_PASSWORD_HASH && export FM_FLASH_PASSWORD_HASH
fm flash --role workstation --device /dev/disk4 --name fm-ws-01
```

The workstation's password is a console login, so the installer wants it already
hashed. Generate one with `mkpasswd --method=SHA-512 --rounds=4096`. It is the
one credential a workstation needs and a rig does not: the rig's account is
locked and reached by key alone, while somebody sits down in front of a
workstation.

![one-shot flash](docs/diagrams/one_shot_flash.svg)

The media boots as `fm@<name>` — SSH keys injected, password login locked — and
provisions itself: this repo's role, then fm_ros2's workspace layer (the
recorder service on a rig, the processor on a workstation). Those overlays are
private, so that second layer runs unattended only when `--gh-token` (a
read-only fine-grained PAT) was baked at flash time; without one, first boot
stops after the machine layer and leaves the remaining one-liner in
`~/NEXT-STEP.md` on the machine.

The two roles differ in one place a person can see. The Jetson image carries its
cloud-init seed inside its own root filesystem, so `flash` replaces it there and
the card boots straight through. An ISO's filesystem is read-only, so the
workstation's seed rides in a second FAT partition labelled `CIDATA` written
after the ISO — which the installer finds, but only once its boot menu has been
told to go ahead. That is one keypress on the machine, and the only part of a
workstation rebuild that is not unattended. Removing it means remastering the
ISO with an `autoinstall` kernel argument, which is
[issue #36](https://github.com/first-motive/fm-setup/issues/36).

Both layers are pinned to a release tag, resolved at flash time and baked into
the card: this repo's from its own `install.sh`, fm_ros2's from the newest `v*`
tag on its remote. A card therefore provisions the same way in a month as it
does today, whatever has merged since. `flash --dry-run` prints both refs, since
that claim is only worth anything if you can read which two it means.

| flag | effect |
| --- | --- |
| `--role` | `jetson` (default) or `workstation`; picks the image, the seed, and the install chain |
| `--device` | target disk, whole device; internal disks are refused |
| `--name`, `--user` | identity (defaults `fm-rec-01` / `fm-ws-01`, and `fm`); the name becomes the hostname, the mDNS name, and the ROS namespace |
| `--fleet`, `--transport`, `--workload` | the rest of the seeded identity card (defaults `prod`, `zenoh`, and the role's own workload) |
| `--ssh-key` | public key to authorize (default: every `~/.ssh/*.pub`) |
| `--password-hash` | console password, already hashed — workstation only, and required there |
| `--wifi ssid:psk` | join wifi on boot — jetson only; the workstation is a wired box |
| `--tailscale-authkey` | join the tailnet on first boot — use an ephemeral key |
| `--gh-token` | org access for the private overlays |
| `--no-provision` | identity only, no first-boot installs |
| `--dry-run` | print the plan, touch nothing |
| `-y`, `--yes` | skip the erase confirmation |

A name has to match its role: `fm-rec-01` is a jetson and `fm-ws-01` is a
workstation, and `flash` refuses the pair that disagrees rather than baking a
card whose topics land under the wrong namespace.

Prerequisites, jetson: the board's QSPI must carry NVIDIA's r36.x UEFI firmware
— any Orin that has booted JetPack 6 qualifies. On macOS the seed swap needs a
container runtime (OrbStack or Docker), because the image's rootfs is ext4.

Prerequisites, workstation: `sgdisk` on the machine doing the flashing, for the
seed partition — `brew install gptfdisk` on macOS, `apt install gdisk` on Ubuntu.
The workstation itself needs nothing beyond the stick: boot it, pick the stick
from the firmware's boot menu, and confirm the autoinstall when it asks. Then
leave it alone — the install, the reboot, and both provisioning layers run
without anyone there. Follow them the same way a rig is followed:

```bash
ssh fm@fm-ws-01.local tail -f /var/log/fm-first-boot.log
```

balenaCLI is used to write and validate the media when present; plain `dd`
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
  "workspace": "/opt/fm"
}
```

```
name ──┬─→ hostname
       ├─→ mDNS + tailnet name
       └─→ ROS namespace   fm-rec-01 → fm_rec_01   (derived, never typed)

transport ─→ the middleware profile every process on the host sources
workload  ─→ the comms bridge profile      (optional — see below)
robot     ─→ which robot this machine is   (robot role only — see below)
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
into an env file. It is optional because it is genuinely not universal — a
machine that runs no bridge needs no value, and requiring one would force a
meaningless answer onto it. Absent means this machine hosts no workload;
`--workload none` clears it when a machine is repurposed.

A Mac is `cockpit`. Under the zenoh transport its DDS graph is loopback-only, so
without a bridge its ROS tools see nothing the fleet publishes; the `cockpit`
profile is the mirror of a rig's — the fleet's published set in, teleop commands
out.

The GPU tower is `workstation`. It runs the sim and the dataset engine together,
so its bridge is the union of `robot` and `processor`; `processor` alone left it
holding a session and publishing no joint states (fm-comms#20). That bridge runs
Humble and cannot see the Jazzy nodes of a sim run, so a workstation such as
fm-ws-01 that hosts sim runs keeps `--workload workstation` and adds fm-comms'
second, Jazzy bridge from its fm-comms checkout (`install.sh --role bridge-sim`, at
the fm-comms release `FM_COMMS_TAG` names). The sim step prints that command when the unit is not
running; it does not run it, because fm_ros2 owns the workstation's fm-comms.

A sim host is `sim`. fm-comms renders `bridge-sim.json5` for it, which carries
the run's state outward and nothing inward; the run itself is driven through the
sim agent (see [Sim Host](#sim-host)).

```bash
fm machine init --name fm-rec-01 --workload recorder
fm machine init --workload cockpit           # a Mac: its own bridge
fm machine init --workload workstation       # the GPU tower: robot + processor (+ bridge-sim for sim runs)
fm machine init --workload sim               # a sim host: bridge-sim.json5
fm machine init --workload none              # repurposed; no bridge any more
```

`robot` is the second optional field, and the one a `robot` card must carry. A
robot arrives on its vendor's own OS and is adopted rather than flashed, so
fm-setup provisions nothing on it and the card is all the fleet knows about it.
The field names which robot it is, because `role` cannot: an Anvil workcell and
an Axol are both robots and share not one interface. fm-comms selects the anvil
bridge profile from it, and the robot agent selects its adapter from it.

```bash
fm machine init --name fm-rob-01 --role robot --robot anvil-openarm-v2 \
  --workload robot
fm machine init --name fm-rob-02 --role robot --robot axol
```

`fm device adopt` runs that command as one of its five steps, so the card is
written the same way whether a person types it or the adopt flow does.

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
it cannot. This applies to people and to AI agents equally. The managed
`CLAUDE.md` holds the full rule, and personal onboarding prints `~/AGENTS.md`
at SSH login as its first-read router.

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
├─ machine/             the identity card's schema — the cross-repo contract
└─ tailscale/           tailnet policy the operator applies by hand
```

Roles share `scripts/steps/` rather than owning a directory each, so a step more
than one role needs is written once and listed in each registry.

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
the shared `fm` group, with no ability to change the host. Who is on a machine
is answered by two live things — the tailnet ACL and the `fm` group — and by
nothing in this repo, because a name in a committed file is stale the day
someone joins or leaves.

Onboarding one person has three owners, in this order:

```
tailnet ACL   →   administrator        →   the person
maps them         ./run.sh add-user        fm setup-onboard
to a unix         account, fm group,       tools, workspace, sign-in
account           /data, no sudo
```

### 1. The ACL Maps A Person To An Account

Tailscale SSH decides who may log in as whom, and it needs to be told that
`matt@ubundi.co.za` is the unix account `matt`. Without a rule naming the
account, a new passwordless user cannot log in at all — the account exists and
nothing can reach it. One `accept` rule per person:

```jsonc
{
  "action": "accept",
  "src":    ["matt@ubundi.co.za"],
  "dst":    ["tag:ssh-server"],
  "users":  ["matt"]
}
```

`tag:ssh-server` is the tag the machines carry — confirm a host's own with
`tailscale status --json | jq .Self.Tags` before writing a rule against it.

The administrator's own account is reachable under `"action": "check"` instead,
which re-authenticates before each session. Everything about who may log in
lives here; this repo holds none of it.

### 2. The Administrator Creates The Account

```bash
./run.sh add-user matt        # account + fm group + /data access, no sudo
sudo deluser --remove-home matt
```

New accounts have no password and log in over Tailscale SSH. The machine's
`CLAUDE.md` reaches them through `/etc/skel`.

`bash scripts/steps/70-users.sh check` warns when a workstation's `fm` group
holds nobody but the administrator. A rebuild takes every account with it, so
that warning is the only thing on a freshly reinstalled machine that says the
team is gone.

### 3. The Person Onboards Themselves

Everything after the account belongs to the person whose account it is — the
tools land in their home, and the credentials are theirs to type.

```bash
fm setup-onboard
```

One command, and no checkout of your own. The `fm` CLI is on every account's
`PATH` from `/usr/local/bin`, and it mounts this verb from the machine's own
`/opt/fm/fm-setup` — which is readable to the whole `fm` group, so a newcomer
with an empty home has both before they have installed anything.

That CLI is root-owned, installed once into `/opt/fm-tools` against the system
Python. Nothing about it resolves through anybody's home: a home is mode 750
here, and a `fm` that reached into one would be a command the rest of the team
could see and could not run. Upgrading it is an administrator's job, which is
what keeps one pinned version on the box rather than nine drifting.

`onboard` uses no sudo and writes nothing outside the home directory. It puts
`~/.local/bin` on `PATH`, installs uv and the `fm` CLI through the same step
provisioning uses, installs Claude Code, creates `~/fm`, and writes `FM_HOME` —
which is what makes every tool resolve *your* workspace rather than the
machine's. Both settings live in `~/.fm-profile`, which `~/.profile` sources at
the end and `~/.bashrc` sources at the **top**: the stock `~/.bashrc` returns on
its fourth line when the shell is not interactive, so a line below that guard
reaches a prompt and misses `ssh host command`, CI, and agents. It also tells
git that the machine's checkouts under `/opt/fm` are safe to read — they belong
to the service account, and git refuses another account's repository as
"dubious ownership", which is enough to make `fm doctor` report a configured
push guard as off. It installs a personal `~/AGENTS.md` and a login-only hook
that prints its first 35 lines during interactive SSH login. Non-SSH shells and
remote commands stay quiet. An existing personal `~/AGENTS.md` is preserved and
becomes the displayed first-read.

On a machine whose CLI is not system-wide yet, clone and run it from the
checkout instead:

```bash
git clone https://github.com/first-motive/fm-setup ~/fm/fm-setup
cd ~/fm/fm-setup && ./run.sh onboard
```

The last step is signing in as yourself, which no script can do for you:

```bash
claude                        # then /login
gh auth login                 # then re-run onboard for the org skills
git config --global user.name "Your Name"
git config --global user.email you@ubundi.co.za
```

Then open a new shell, or `. ~/.profile`, so `PATH` and `FM_HOME` take effect.
Until you do, `fm` and `claude` are not on `PATH` in the shell you ran
`onboard` from.

Claude Code is installed unpinned, because it updates itself in place. The
`fm` CLI is pinned in `scripts/manifest.sh`, because two machines provisioned
months apart should agree about it.

Cloning the org skill set needs GitHub auth `onboard` cannot supply. Run
without it, `onboard` prints the two commands and exits 0; run it again after
`gh auth login` and it finishes the job.

The re-run is `/opt/fm/fm-setup/run.sh onboard`, not `fm setup-onboard`. The
CLI mounts a repo's verbs from the workspace it resolves, and the first run
writes `FM_HOME` — so from the next shell onwards that workspace is yours, which
holds no `fm-setup` and has no reason to. The machine's checkout is readable by
everyone, so calling it by path always works. The seam closes if `fm` falls back
to the card's workspace for a repo your own does not carry; that lives in
fm-tools.

## Robots

A robot is the one machine this repo does not provision. It arrives on the
vendor's OS with the vendor's accounts, and `fm device adopt` layers five things
onto it — so there is no step chain for a robot, and what it needs from here is
one verb.

```bash
./run.sh robot-sudo                 # grant it to the account running this
./run.sh robot-sudo --user anvil    # or to another account
./run.sh robot-sudo --dry-run       # print the rule, write nothing
./run.sh robot-sudo --remove        # take it away
```

Deploying a new agent is `git pull` in a checkout the account already owns, then
one `systemctl restart` it does not. That restart is the only reason a password
gets typed on a robot, and typing it is what stops `fm device update` from
working unattended. So the rule this writes names those units, those verbs, and
nothing else:

```
/etc/sudoers.d/fm-robot-services

  <user> ALL=(root) NOPASSWD: \
      /usr/bin/systemctl start|stop|restart|status|is-active fm-robot-agent
      /usr/bin/systemctl start|stop|restart|status|is-active fm-zenoh-bridge
      /usr/local/sbin/fm-comms-set
```

`fm-comms-set` is installed by the same verb. The Anvil's domain and interface
live in two files — the loader's `.env.config`, owned by the account the agent
runs as, and `/etc/fm-comms.env`, owned by root because two systemd units read
it. The agent writes both or neither, so without a way across that line a paired
write fails at staging and the two are left disagreeing, which is exactly what
the pairing exists to prevent.

The writer takes a key and a value, accepts three keys
(`FM_ROS_DOMAIN_ID`, `ROS_DOMAIN_ID`, `FM_DDS_IFACE`), checks each value, and
reads no path from its caller. Setting the domain sets both spellings, because
the installer keeps them equal. An account that reaches it can change three
values and nothing else on the host — which is why the grant names that path
rather than the file, or root.

The account can restart the fleet's own services and cannot become root. On a
workcell Anvil and Almond are still responsible for, that distinction is the
point — `ALL=(ALL) NOPASSWD:ALL` here would hand a fleet account the run of
somebody else's machine.

Commands are matched by absolute path, because that is the only form sudo
matches, and the units are spelled out rather than globbed: `fm-*` would also
cover whatever unit somebody adds under that prefix next, and a grant that
widens on its own is not a grant anybody reviewed. `daemon-reload` is absent for
the same reason — it re-reads the vendor's unit files too, and no deploy needs
it.

The generated rule is checked with `visudo -c` before it is installed, and again
in CI, because a malformed file in `/etc/sudoers.d` breaks sudo for every account
on the host, including the one that would have to repair it. Confirm what an
account may do with `sudo -l -U <name>`.

## Sim Host

The `sim` step (`scripts/steps/91-sim.sh`, on in the workstation role) makes a
workstation a sim host: the fm-sim image and fm-sim's sim agent, run by systemd.
Whether the host can run Isaac Sim 4.5 is `isaac-sim`'s check, which reports the
driver against Isaac's minimum, the GPU, and the GPU inside a container.

| Part | What the step does |
| --- | --- |
| Image | pulls `ghcr.io/first-motive/fm-sim@<FM_SIM_IMAGE_DIGEST_DEFAULT>`, or the `jazzy` tag while no digest is pinned; with `FM_SIM_CONTROLLERS=1`, the private controllers image instead (below) |
| Agent | fetches fm-sim at `FM_SIM_COMMIT_DEFAULT` as root, copies its `agent/` into `/opt/fm-sim-agent`, builds its venv, and writes the unit from fm-sim's template |
| Bridge | reports which bridge the card selects; `workload: "sim"` selects fm-comms' `bridge-sim.json5`, and on `workload: "workstation"` it checks for `fm-zenoh-bridge-sim.service`, the Jazzy bridge that carries the sim topics, and prints the `install.sh --role bridge-sim` command for the workstation's fm-comms checkout when it is not running; any other workload is warned about |

**The `fm-sim` account is in the docker group, and that group is
root-equivalent:** a member can start a container that mounts the host's
filesystem. Root sources this fm-setup checkout, which is trusted as it is for
every step. Beyond that, the three things the sim step brings in for the agent —
its code, the uv that builds its venv, and its unit template — come only from
pinned sources root fetches and keeps in root-owned places:

- Root fetches the pinned commit itself, from GitHub, into
  `/opt/fm-sim-agent/src.git`, with a scrubbed environment and replace objects
  off. A workspace checkout of fm-sim, if there is one, is never read. With no
  commit pinned, the step installs no agent.
- The commit's `agent/` tree is listed first and refused if it holds a symlink
  or a submodule. It is then copied with `git archive` into
  `/opt/fm-sim-agent/project`, root:root, directories 755 and files 644.
- Root builds the venv with a uv downloaded at `FM_UV_VERSION` and checked
  against `FM_SIM_UV_SHA256_MAP` — never the operator's own uv — with no uv
  config file, no inherited index, and a fixed PATH (`uv sync --frozen
  --no-editable`). The service starts `/opt/fm-sim-agent/venv/bin/fm-sim-agent`
  and runs no uv and no build.
- fm-sim's template is parsed against an allowlist
  (`scripts/internal/sim-lib.sh`): known sections and keys, each once, every
  value in its expected shape, `User=@USER@`, and `ExecStart` exactly as fm-sim
  ships it. The step then replaces `ExecStart` with the installed entrypoint
  and this host's flags: `--image`, `--runs-dir /data/sim-runs`,
  `--models-dir /data/sim-models`, `--assets-dir /data/sim-assets`, and
  `FM_SIM_AGENT_FLAGS` (`--gpus` and the
  memory, process, duration and free-disk limits). Host networking and host IPC
  are the agent's default.
- `/data/sim-models` and `/data/sim-assets` are created before the agent starts,
  because the agent will not start without them. The step refuses a symlink or a
  file at either path, and refuses an fm-sim commit without both flags. Root sets the owner and mode
  only on a directory it has just made, because any fm member can rename another
  directory to that path. It reports a wrong mode on one already there and leaves
  the repair to a person.
- The docker grant is asked for and auto-declines under `NONINTERACTIVE=1`.
  Without a pinned image digest the step writes the unit but grants nothing and
  enables nothing. The unit starts once `/etc/fm-comms.env` exists.
- Every privileged command is checked; one that fails stops the step with exit
  1 before anything is recorded as installed.

One input is not pinned yet: fm-sim's `[build-system]` names `hatchling`
without a version, and root runs that build backend once at install time. Pinning
it is a follow-up in fm-sim.

The tailnet ACL on the router's 7447 is the boundary on who can call the agent.

```
/etc/systemd/system/fm-sim-agent.service    rendered from fm-sim's template
/opt/fm-sim-agent/src.git                   root's fetch of the pinned commit
/opt/fm-sim-agent/{project,venv,bin/uv}     the agent, its venv, and the pinned uv (root:root)
/var/cache/fm-sim-agent/                    root's uv cache for that build
/var/lib/fm-sim/                            the account's home; nothing installed there
/data/sim-runs/                             run summaries and MCAPs (fm-sim:fm, 2770)
/data/sim-models/                           object packs every run mounts read-only (root:fm, 2775)
/data/sim-assets/                           USD assets each Isaac run mounts read-only (root:fm, 2775)
```

Members of the `fm` group copy object packs in by hand, as
`/data/sim-models/<pack>/{best.xml,best.bin,pack.yaml}`. The agent's account is
outside that group, so it reads through the bits for others: run
`chmod -R a+rX` on a pack that was copied from a private directory. The pinned
agent refuses a run while the tree holds a symlink or a directory it cannot read,
so copy real files. Uninstall leaves the directory and its packs in place, and
`./run.sh backup` does not cover them.

Fetch SimReady assets with fm-sim's `tools/fetch_simready.py --assets-dir
/data/sim-assets`, from a checkout at the pinned commit. The same rules apply.

```bash
bash scripts/steps/91-sim.sh install --dry-run   # the plan and the rendered unit; changes nothing
./install.sh --workstation --check --only sim,isaac-sim
./scripts/dev/test-sim.sh                        # stand-in sudo, systemctl, curl, uv, docker; no root
```

### Controllers Image

`ghcr.io/first-motive/fm-sim-controllers` is a private overlay of the public
image that adds the fm_skills, classical, policy_serve, and fastwam controllers.
A host runs it only when it opts in; every other host keeps the public image.
The manifest pins it by `FM_SIM_CONTROLLERS_IMAGE_DIGEST_DEFAULT`, the index
built on the public pin, and `FM_SIM_CONTROLLERS_IMAGE_DIGEST` overrides that
pin on the command line, checked against the same `sha256:<64 hex>` shape.

The pull needs a GHCR login with a token that can read first-motive packages,
made once by the operator who runs the step. fm-setup never logs in or handles
the token:

```bash
docker login ghcr.io
FM_SIM_CONTROLLERS=1 ./install.sh --workstation --only sim
FM_SIM_CONTROLLERS=1 ./install.sh --workstation --check --only sim
```

Without the login, the pull fails with a warning and the agent's runs cannot
start. Re-running without `FM_SIM_CONTROLLERS=1` returns the unit to the
public image. The `sim-cloud` role takes the switch from its stack's host.env
and logs itself in for one pull with a GHCR token the stack keeps in SSM (see
below), since nobody is at a cloud host to run `docker login`.

### Cloud Sim Host

The `sim-cloud` role is a sim host on a cloud GPU instance. fm-sim's AWS stack
(`infra/aws/sim/` in fm-sim) launches the instance, writes
`/etc/fm-sim-cloud/host.env`, fetches this repo at the commit it pins, and runs,
as root:

```bash
set -a; . /etc/fm-sim-cloud/host.env; set +a
NONINTERACTIVE=1 timeout 60m /opt/fm/fm-setup/install.sh --sim-cloud
```

The role must finish unattended: a failure terminates the instance. It accepts
Ubuntu 24.04 (the stack's default AWS Deep Learning Base GPU AMI) and 26.04, and
installs no GPU driver; the image ships one.

| host.env | What the role does with it |
| --- | --- |
| `FM_MACHINE_NAME` | the card's name (`sim-cloud` by default; the agent serves `fm/sim/sim_cloud/*`), the hostname, and the tailnet name |
| `FM_SETUP_SHA` | refuses to run unless this checkout's `HEAD` is that commit |
| `FM_SIM_COMMIT`, `FM_SIM_IMAGE_DIGEST` | the sim step's agent commit and image digest |
| `FM_ROUTER_ENDPOINT` | `FM_ROUTER_ENDPOINT` in `/etc/fm-comms.env`, which the agent's and the bridge's units read |
| `FM_TS_AUTHKEY_SSM_PARAMETER`, `FM_SIM_CLOUD_REGION` | where the Tailscale auth key is read from |
| `FM_TS_TAG` | the tag the node advertises (`tag:sim-cloud`) |
| `FM_SIM_CONTROLLERS` (optional) | `1` runs the private controllers image (OpenArm, `fm_skills`); empty or `0` the public one |
| `FM_SIM_CONTROLLERS_IMAGE_DIGEST` (optional) | the controllers image digest; empty uses this checkout's pin |
| `FM_GHCR_TOKEN_SSM_PARAMETER`, `FM_GHCR_USERNAME` | with `FM_SIM_CONTROLLERS=1`: where the GHCR token (Packages: read) is read from, and the login it belongs to |

With `FM_SIM_CONTROLLERS=1` the sim step reads the token through the instance
role into a 0600 file in a 0700 directory under `/run`, hands it to
`docker login ghcr.io --password-stdin` with a `DOCKER_CONFIG` inside that
directory, pulls the pinned controllers digest, and shreds the directory,
whether the pull worked or not. The token never reaches argv or the log, and no
docker config outlives the pull; the pulled image stays, so runs need no login. A pull
that fails stops the role, since a host without its image cannot serve a run.
The bridge's `/etc/fm-comms.env` names the same image.

`install.sh` checks every one of these, and the checkout's commit, before any
step runs, and names each one that is missing or malformed. `scripts/update.sh`
(what `fm update` runs) reads the required variables from host.env as data when
its caller has not exported them; a checkout pulled past `FM_SETUP_SHA` is still
refused, since the stack pins the commit.

The steps are the trainer's less five, plus the sim workload and five of the
role's own (`./install.sh --sim-cloud --list`). It drops `system-update` and
`nvidia`, because an upgrade on a fresh instance can move the image's driver
under the loaded module; `etckeeper`, because `/etc`'s history ends with the
instance; and `fm-policy` and `ffmpeg`, because nothing on a sim host trains.

| Step | What it does |
| --- | --- |
| `sim-cloud-host` | repeats the host.env check; makes apt wait for the lock first-boot upgrades hold |
| `sim-cloud-card` | writes the card (role `sim-cloud`, workload `sim`) through `machine init`, which also sets the hostname |
| `tailscale-authkey` | reads the auth key from SSM and joins with `--advertise-tags=$FM_TS_TAG`, without Tailscale SSH |
| `comms-bridge` | fetches fm-comms at `FM_COMMS_COMMIT` (the commit of `FM_COMMS_TAG`, the tag fm_ros2 pins) into `/opt/fm-comms` as root; places `/etc/fm-comms.env` from its example with the router, `FM_ROS_DISTRO=jazzy`, and the image; and runs fm-comms' own `install.sh --role bridge`, which enables `fm-zenoh-bridge.service` with the `bridge-sim` profile the card selects |
| `sim` | as on a workstation, except the docker grant is given without a prompt |
| `sim-cloud-ready` | fails the role unless docker and the driver answer, the agent is enabled and stays active, the bridge is enabled and active, `fm-sim` holds the docker grant, and the node carries the tag |

`fm-cli` installs the CLI for the account running the role, and not the
machine-wide `/usr/local/bin/fm`: that install asks first, and an unattended
run declines.

The bridge is the one fm-comms ships: `bridge-sim` publishes a run's state
outward and subscribes to nothing, on a DDS graph confined to loopback. The
step names no profile, interface, or allow-list of its own.

**The auth key never reaches the log.** cloud-init copies the run's output to
the instance's console. aws writes the key into a 0600 file in a 0700
directory under `/run`, a tmpfs; tailscale reads it from there
(`--auth-key=file:…`), so argv holds only the path; and the file is shredded
whether the join worked or not. Its shape is checked without printing it.

**The docker grant is not asked for when the role runs unattended.** That is
its stack's bootstrap, on an instance launched to serve sim runs, where an
agent without the grant serves nothing; choosing the role is the decision to
grant it. A person running the role interactively is asked, as on a
workstation.

**What the role does not do**, because another owner does it:

- The metadata-service block. Runs use host networking as the agent's account,
  `fm-sim`. The stack's bootstrap creates that account before the role runs, with
  the sim step's own `useradd` flags, and installs an `iptables` owner-match rule
  dropping its traffic to `169.254.169.254`; root keeps its access for the idle
  check. The sim step finds the account and leaves it, and no step touches
  `iptables`.
- The tailnet ACL. No step can change the tailnet's policy, so
  [`templates/tailscale/sim-cloud-acl.hujson`](templates/tailscale/sim-cloud-acl.hujson)
  holds the grant the role needs — `tag:sim-cloud` to the router on tcp/7447,
  nothing else — for the operator to merge into the policy file once. The auth
  key in SSM must be tagged `tag:sim-cloud`, pre-authorised, ephemeral, and
  given an expiry.

```bash
./install.sh --sim-cloud --list
scripts/update.sh            # `fm update` on the host: reads host.env itself, then converges
./scripts/dev/test-sim-cloud.sh     # stand-in aws, tailscale, sudo, systemctl; no root, no network
```

## Host Agent

The `host-agent` step (`scripts/steps/93-host-agent.sh`, on in the workstation
role) publishes the workstation's load on the fabric, so anyone can open it in
fm-desktop's Devices view and see whether the tower is free without opening an
SSH session. The agent's code is this repo's [`host-agent/`](host-agent/README.md).

```
fm-host-agent (fm-host)  ── every 30 s ─►  fm/host/<host>/load          fm-desktop
        │                 ◄── query ─────  fm/host/<host>/disk-users    Devices
        │                 ◄── query ─────  fm/host/<host>/sim           Simulation
        │ systemctl start (polkit: the scan unit)
        │ systemctl start|stop|restart (polkit: fm-sim-agent.service)
        ▼
fm-host-disk-scan (root, oneshot) ──► /var/lib/fm-host-agent/disk-users.json
```

### What It Publishes

`<host>` is the identity card's name with `-` turned into `_` (`fm_ws_01`), as
fm-sim-agent derives it. Every body is JSON; sizes are bytes and times are Unix
seconds.

```
fm/host/<host>/load         published every 30 s, also a queryable; a query wakes a fresh publish
  {ok, host, t, version,
   cpu:    {percent, cores, load: [1m, 5m, 15m]},
   memory: {used, total},
   gpus:   [{index, name, util, mem_used, mem_total,
             processes: [{pid, user, name, mem}]}],
   mounts: [{path, used, total}],
   users:  [{user, cpu_percent, rss, sessions}]}

fm/host/<host>/disk-users   queryable, request {refresh?: bool}
  {ok, state: "idle" | "scanning", scanned_at: t | null,
   roots: ["/data", "/home"], users: [{user, bytes}]}

fm/host/<host>/sim          queryable, request {action?: "status" | "start" | "stop" | "restart"}
  {ok, unit: "fm-sim-agent.service", installed: bool, state: systemd ActiveState}
```

- `users` lists login accounts (uid 1000 and up, except nobody), with CPU summed over their
  processes (so above 100% on several cores) and their login sessions.
- A GPU process is named by its `comm`, never its command line, whose arguments
  can carry tokens.
- A mount's `total` is used plus free-to-users, so `used / total` is `df`'s
  Use% and a full disk reads as 100%.
- `load` is published every 30 s. A `load` query answers with the last reading
  at once and wakes the agent to publish a fresh one, at most once per 2 s, so
  Devices fills in on opening and its Refresh button costs one read.
- `sim` reads the sim agent unit, and a `start`, `stop` or `restart` queues that
  change with `systemctl --no-block` and answers with the state systemd reports
  at once (often `activating`); ask again to see where it settled. A host
  without the unit answers `installed: false` and refuses every change. Changes
  are at least 5 seconds apart; one sooner is refused `too_soon`. This is how
  fm-desktop's Simulation screen starts a stopped workstation sim agent.
- `disk-users` replies with the last report and whether a scan is running. No
  report yet, one older than 15 minutes, or `refresh: true` starts a scan, and
  only that query waits, on `systemctl start --no-block`, for at most 5 seconds.
  Starts are at least 5 minutes apart, and a refresh inside that window is
  refused with `too_soon`. A restarted agent takes the last start from the
  report's `scanned_at`, so a restart does not open the window early. When a
  scan ends, the agent publishes the same body on `fm/host/<host>/disk-users`.
- A refusal is a Zenoh error reply carrying `{ok: false, error: {code,
  message}}`, as fm-sim-agent sends.

Anyone on the tailnet who can reach the router's 7447 can read these keys: who
is logged in, what they run on the GPUs, and how much disk each account holds.
A `disk-users` query can also start a root scan, at most once every 5 minutes.
The tailnet ACL is the boundary, as it is for the sim agent.

### Privilege Model

The agent holds no privilege. The `fm-host` account is a system account with no
home, no login and no group beyond its own — not docker, not fm — and the agent
reads only what any account may: `/proc`, the NVIDIA driver, `statvfs`, the
identity card, `/etc/fm-comms.env`, and the scan's report.

Counting every account's files needs root, so that one job is a root oneshot,
`fm-host-disk-scan.service`, which the agent may start but not change:

- A polkit rule (`50-fm-host-agent.rules`) lets `fm-host` start that unit and
  nothing else. Every other systemd action it asks for falls through to
  polkit's defaults, which refuse an account with no session.
- The scan runs the code in `/opt/fm-host-agent`, which root copies out of this
  checkout, refusing anything but plain files and directories, and keeps
  root:root, directories 755 and files 644. Root builds the venv with the uv the
  sim step pins (`FM_UV_VERSION`, checked against `FM_SIM_UV_SHA256_MAP`), with
  no uv config file and a fixed PATH (`uv sync --frozen --no-editable`). Every
  install hands the tree and `/var/lib/fm-host-agent` back to root and closes
  them to other writers; `check` flags any file in either that root does not
  own alone.
- The scan keeps only the capability to read past file modes, writes only into
  `/var/lib/fm-host-agent`, has no network, and runs at idle CPU and I/O
  priority. It follows no symlink, stays on each root's filesystem, and counts a
  hard-linked file once, up to 500,000 of them; past that, a file is counted
  once per name.

`host-agent/pyproject.toml` pins its build backend (`hatchling==1.32.4`), which
root runs once at install time; fm-sim's is not pinned yet.

```
/etc/systemd/system/fm-host-agent.service       the agent (User=fm-host)
/etc/systemd/system/fm-host-disk-scan.service   the root scan, started on request
/etc/polkit-1/rules.d/50-fm-host-agent.rules    fm-host may start the scan, nothing else
/opt/fm-host-agent/{project,venv,bin/uv}        the agent, its venv, and the pinned uv (root:root)
/var/cache/fm-host-agent/                       root's uv cache for that build
/var/lib/fm-host-agent/disk-users.json          the scan's report (root:root, 644)
```

```bash
bash scripts/steps/93-host-agent.sh install --dry-run   # the plan; changes nothing
./install.sh --workstation --check --only host-agent
./scripts/dev/test-host-agent.sh                        # stand-in sudo, systemctl, curl, uv; no root
```

## The Data Root

Every machine that holds episodes lays out the same tree inside the workspace
its card names, so a path in a manifest, a training config, or somebody's notes
means the same thing on all of them:

```
<workspace>/data/
├─ recordings/     raw MCAP episodes off the rigs
├─ processed/      manifests and clean RLDS
├─ annotations/    labels and annotation run directories
├─ releases/       dataset release packs
├─ staged/         B2 stage-ins (episodes/, lerobot/)
├─ hf/             HF_HOME cache — datasets and weights, evictable
└─ policies/       per-run training output
```

Every directory is group `fm`, mode 3775 — group write so the team shares one
tree, setgid so an episode written by one person stays usable by the next,
sticky so removing an entry needs ownership of it.

The tree is machine-owned: nothing in it is a repo and nothing in it is synced.
It is resolved from the identity card and never from `FM_HOME`, because a
machine has one data tree that the whole team and every service share, while
`FM_HOME` is a person's own workspace.

Both of those are tested, because the converge timer lays the tree out unattended
on every tag and the recordings in it are what nobody can re-make:

```bash
./scripts/dev/test-data-root.sh   # temp workspace, no root
```

## Backups

Before a wipe, copy what cannot be re-made and prove the copy is good:

```bash
./run.sh backup /mnt/ssd              # copy + checksum manifest + read-back verify
./run.sh backup --verify /mnt/ssd     # re-verify later, or after transport
./run.sh backup --restore /mnt/ssd    # copy back to /data, group reapplied
```

The backup includes recordings, processed outputs, annotations and reviews,
release packs, training outputs in `models/` and `policies/`, and archive
ledgers and operator evidence. Nested receipt paths are preserved. Downloaded
weights in `hf/` and `fm-data-runs/_model-views/` are excluded.

For the newer data tree, add `--workspace-data` to each command. Its root comes
from the machine card's workspace, independent of `FM_HOME`. These backups use
a separate `-workspace-data` directory so they cannot mix with legacy `/data`
backups. No command moves the live data tree.

### Configure The Archive

The users step declares the legacy shared directories; the data-root step
declares the workspace data tree. Both preserve data on uninstall. Service
installation stays in `fm-ros2`, through `fm install fm-ros2 --processor --service`.
The installer derives uploader roots from the processor environment and
preserves explicit values on repeat runs.

Before enabling derived uploads, approve the retention rule and the scopes in
[fm-data's archive contract](https://github.com/first-motive/fm-data/blob/main/fm_data_archive/ARCHIVE_LAYOUT.md).
Keep the reader and writer credentials in their separate mode-600 service
environment files on the processor. Run `fm archive preflight --json` there.
Only then explicitly enable `FM_ARCHIVE_UPLOADER_DERIVED_ENABLED` through
`./install.sh --workstation --only archive-derived`. The step runs the provider
preflight first, changes only that flag, and restarts only the uploader. Local
deletion stays disabled. An install or release does not grant either approval.

The manifest is plain `sha256sum -c` format at the backup root, readable without
anything from this repo. The copy path verifies before reporting success, and
`--restore` verifies before writing, so a corrupt backup can never overwrite the
only other copy.

## Rehearsing A Role

Provisioning is the one thing this repo cannot test on the machine that writes
it. `scripts/dev/rehearse.sh` runs a role's package steps inside a container of
its target release:

```bash
./scripts/dev/rehearse.sh             # every role
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
./scripts/dev/converge-check.sh             # every role
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
| `FM_HOME` | your own workspace root; outranks the machine card, which names the machine's |
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
| `FM_FLASH_PASSWORD_HASH` | hashed console password for `flash --role workstation`, on the same terms |
| `FM_FLASH_CACHE` | where `./run.sh flash` keeps the downloaded image (default `~/.cache/fm-setup`) |
| `FM_REHEARSE_PLATFORM` | container platform for `rehearse.sh` and `converge-check.sh` (default `linux/arm64`; CI sets `linux/amd64` to run native) |
| `FM_CONVERGE_IMAGE` | container image for `converge-check.sh` (default `ubuntu:22.04`) |

## License

Apache 2.0. See [LICENSE](LICENSE).
