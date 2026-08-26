#!/usr/bin/env bash
#
# manifest.sh — the single source of truth for what fm-setup provisions.
# Data only, no logic. Sourced by the front doors and by every step.
#
# A registry entry is an "id|file|default" string:
#   id       stable handle used by --only / --skip / --list
#   file     script under scripts/steps/
#   default  on | off — whether the step runs in a plain role install
#
# Order is install order. Uninstall walks each registry in reverse.
#
# Roles share the steps/ directory rather than owning a directory each, so a
# step both machines need (system update, tailscale, DDS buffers) is written
# once and listed twice. Where a shared step differs by role — the ROS distro —
# the difference is a pair of variables here, not a pair of scripts.
#
# Indexed arrays of pipe-delimited strings, not associative arrays: the format
# stays readable in a diff and portable to older bash.
#
# Every array here is read by a sourcing script, never by this file.
# shellcheck disable=SC2034

# --- Step registries -------------------------------------------------------

# Ubuntu 26.04 on the GPU workstation: training, annotation, and sim.
WORKSTATION_STEPS=(
  "system-update|00-system-update.sh|on"
  "base-deps|10-base-deps.sh|on"
  "workspace|12-workspace.sh|on"
  "fm-cli|15-fm-cli.sh|on"
  "nvidia|20-nvidia.sh|on"
  "docker|30-docker.sh|on"
  "nvidia-container|35-nvidia-container-toolkit.sh|on"
  "ros2|40-ros2.sh|on"
  "dds-tuning|50-dds-tuning.sh|on"
  "tailscale|60-tailscale.sh|on"
  "users|70-users.sh|on"
  "agent-ruleset|80-agent-ruleset.sh|on"
  "isaac-sim|90-isaac-sim.sh|on"
)

# Ubuntu 22.04 on the Jetson Orin Nano: the capture rig.
#
# Canonical's Ubuntu Server image, not the JetPack SDK: 22.04 is what Humble
# supports natively, and every sensor on the rig is USB or Ethernet, so nothing
# here depends on NVIDIA's multimedia stack.
#
# No GPU steps. The driver and the container toolkit are the workstation's
# concern; the Jetson records, it does not train.
#
# No users or agent-ruleset either. The rig is a single-purpose appliance
# reached over the tailnet, not a box people work on, so it needs no roster and
# no shared /data. Add both here the day someone develops on it directly.
JETSON_STEPS=(
  "system-update|00-system-update.sh|on"
  "base-deps|10-base-deps.sh|on"
  "workspace|12-workspace.sh|on"
  "fm-cli|15-fm-cli.sh|on"
  "docker|30-docker.sh|on"
  "ros2|40-ros2.sh|on"
  "udev-rules|45-udev-rules.sh|on"
  "dds-tuning|50-dds-tuning.sh|on"
  "tailscale|60-tailscale.sh|on"
)

# --- Machine identity ------------------------------------------------------
#
# One file per machine says what that machine is, and everything host-shaped is
# derived from it: the ROS namespace, the zenoh profile, the compose
# environment, the systemd unit names, the workspace path. Before it, the same
# facts were spread across .fm_ros2.json, .fm_tui.json, four /etc/fm-*.env
# files, and a handful of constants in this manifest — which is why two machines
# could disagree about themselves.
#
# The card is data, never logic. `./run.sh machine init` writes it, `./run.sh
# machine doctor` validates it, and every reader treats it as read-only.

# Where the card lives, per platform. Linux puts it in /etc because it describes
# the host rather than the person logged into it, and services read it before
# anyone logs in at all. macOS has no /etc a user may write, so it follows XDG.
FM_MACHINE_FILE_LINUX=/etc/fm/machine.json
FM_MACHINE_FILE_MACOS="${XDG_CONFIG_HOME:-$HOME/.config}/fm/machine.json"

# Bumped when a field changes meaning or disappears. A reader that finds a
# version it does not know must refuse the file rather than guess.
FM_MACHINE_SCHEMA_VERSION=1

# The card's contract, kept next to the writer that produces it. Validated by
# `machine doctor`, and the file to read when a consumer in another repo needs
# to know what it may rely on.
FM_MACHINE_SCHEMA=templates/machine/machine.schema.json

# Roles a card may declare. The two provisioning roles plus `mac`, which
# fm-setup never provisions — a laptop still needs a name, a fleet, and a
# workspace to point at.
FM_MACHINE_ROLES=(workstation jetson mac)

# Middleware profiles a card may declare. zenoh is the supported path; dds-lan
# is the labelled escape hatch for hardware that has not been through the
# transport migration.
FM_MACHINE_TRANSPORTS=(zenoh dds-lan)

# What a machine does in the stack, where that selects a comms bridge profile.
#
# Optional on the card, and deliberately so: a GPU workstation and a laptop run
# no bridge, and requiring this would force one of these onto them. It exists
# because `role` cannot answer the question — a recorder rig and a processor rig
# are both `jetson`, which left FM_BRIDGE_PROFILE as the last per-host value
# anyone still typed into an env file by hand.
FM_MACHINE_WORKLOADS=(recorder processor robot)

# Names are fm-<abbrev>-<nn>, so two recorders on one LAN are fm-rec-01 and
# fm-rec-02 rather than one fm-jetson and a collision. The abbreviation follows
# the role; entries are "role|abbrev".
FM_MACHINE_NAME_ABBREV=(
  "jetson|rec"
  "workstation|ws"
  "mac|mac"
)

# The fleet a machine joins when nobody says otherwise. Machines discover, sync,
# and converge only within their own fleet, so a rig on a bench cannot be
# adopted by production by accident.
FM_MACHINE_FLEET_DEFAULT=prod

# The single visible parent directory every First Motive checkout lives under.
# One directory the owner can see and back up, rather than eight scattered
# across a home directory — and the value readers take the workspace from, so
# that no repo ever hardcodes ~/fm_ros2 again.
FM_MACHINE_WORKSPACE_DEFAULT="$HOME/fm"

# This repo's own directory name inside that workspace.
#
# It has to be exactly what fm-tools' repo registry calls fm-setup's local_dir,
# because that is how `fm doctor` and `fm status` find the checkout: they build
# <workspace>/<local_dir> and look. A directory named anything else is a repo
# doctor reports as "not cloned" on the very machine it provisioned.
FM_SETUP_CHECKOUT_NAME=fm-setup

# Where the curl bootstrap used to put the checkout, before the workspace was a
# declared fact rather than a per-repo habit. Named so the bootstrap can adopt
# one instead of leaving a second copy of this repo on disk for someone to edit
# by mistake.
#
# Read-only by now: the bootstrap resolves the checkout through fm_setup_dir,
# which is always <workspace>/fm-setup, and only ever moves a directory found
# here into it. Two steps in the curl-pipe CI job hold both halves — that the
# unpinned default lands in the workspace, and that a checkout already here is
# adopted rather than duplicated — because the drift this comment used to
# describe was a comment, a bootstrap, and a check each claiming something
# different.
FM_SETUP_LEGACY_DIR="$HOME/.first-motive/fm-setup"

# --- Target OS -------------------------------------------------------------

# The Ubuntu release each role is built for, checked before any step runs.
#
# Role detection keys off a Tegra marker alone, so every non-Jetson Linux box
# resolves to `workstation` whatever Ubuntu it is running. Without this pair the
# 22.04 machine waiting to be re-imaged provisions as a workstation, adds the ROS
# apt source successfully, and then dies on `ros-lyrical-*` packages that do not
# exist for jammy — leaving a half-provisioned host rather than a refusal.
FM_OS_CODENAME_WORKSTATION=resolute
FM_OS_CODENAME_JETSON=jammy

# --- Base packages ---------------------------------------------------------

# Apt packages every later step assumes are present.
FM_APT_BASE=(
  ca-certificates
  curl
  git
  gnupg
  jq
  lsb-release
  software-properties-common
)

# --- GPU -------------------------------------------------------------------

# Pinned, not left to `ubuntu-drivers autoinstall`. Isaac Sim tracks driver
# branches and refuses to start on a too-new one, so the driver moves when we
# decide it moves.
FM_NVIDIA_DRIVER=nvidia-driver-580-open

# Container GPU passthrough. All four packages pin to one version — they move in
# lockstep and an unpinned mix breaks the runtime hook.
FM_NVIDIA_CONTAINER_VERSION=1.19.1-1
FM_NVIDIA_CONTAINER_APT=(
  nvidia-container-toolkit
  nvidia-container-toolkit-base
  libnvidia-container-tools
  libnvidia-container1
)

# Image used by the documented GPU smoke test.
FM_CUDA_SMOKE_IMAGE=nvidia/cuda:12.8.0-base-ubuntu22.04

# --- Docker ----------------------------------------------------------------

FM_DOCKER_APT=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)

# Distro packages that conflict with Docker's own. Removed before installing.
FM_DOCKER_CONFLICTS=(
  docker.io
  docker-doc
  docker-compose
  docker-compose-v2
  podman-docker
  containerd
  runc
)

# --- ROS 2 -----------------------------------------------------------------

# The distro follows the role. Lyrical is tier-1 on 26.04; the Jetson stays on
# Humble because its Ubuntu is 22.04.
FM_ROS_DISTRO_WORKSTATION=lyrical
FM_ROS_DISTRO_JETSON=humble

# Version of the ros2-apt-source package that installs ROS's apt entry and its
# current signing key. Pinned rather than resolved to "latest" so two machines
# provisioned months apart get the same source definition.
#
# 1.2.0 is the first release carrying a resolute (26.04) asset. 1.1.0 stops at
# noble, so the workstation would have 404'd mid-provision on a release that
# looked fine because the Jetson's jammy asset does exist.
FM_ROS_APT_SOURCE_VERSION=1.2.0

# sha256 per codename, checked before dpkg sees the download. The .deb differs
# per codename, so one scalar could only ever match one role — entries are
# "codename|sha256".
#
# Regenerate after a version bump:
#   curl -fsSL https://github.com/ros-infrastructure/ros-apt-source/releases/download/<v>/ros2-apt-source_<v>.<codename>_all.deb | shasum -a 256
FM_ROS_APT_SOURCE_SHA256_MAP=(
  "jammy|767884cf4ed03116b9d64438930a832ed854147ae435279a7924dfdf60f94433"
  "resolute|a275b9b819874e745a928e83e39c429fa4d607159285c4ef3ebcf75afa732ee3"
)

# The workstation is a compute box that people also develop on: the desktop
# variant for rviz and the demos, the build tooling for colcon workspaces, and
# the Foxglove bridge for inspecting a live graph from a laptop.
#
# Both RMWs are named explicitly, and both roles carry both, so a rig and the
# workstation can meet on either middleware.
#
# Naming FastDDS is not redundant. `rmw-implementation` is satisfied by any one
# provider, so asking for Cyclone alongside the base install lets apt settle
# that dependency with Cyclone and never pull FastDDS at all. The recorder then
# starts, reads the FastDDS pin from fm_ros2's dds-lan profile, and every node
# exits with "failed to load shared library 'librmw_fastrtps_cpp.so'" — at node
# start, on a provisioned appliance, which is the worst place to find out. An
# earlier version of this comment asserted that FastDDS stayed the default; a
# Jetson bring-up proved otherwise.
#
# Cyclone is here for fm_ros2's zenoh comms profile, which sets
# RMW_IMPLEMENTATION=rmw_cyclonedds_cpp (scripts/env/comms-zenoh.sh). The
# package names follow the role's distro, like everything else in these lists.
FM_ROS_APT_WORKSTATION=(
  ros-lyrical-desktop
  ros-lyrical-foxglove-bridge
  ros-lyrical-rmw-fastrtps-cpp
  ros-lyrical-rmw-cyclonedds-cpp
  python3-rosdep
  python3-colcon-common-extensions
  python3-vcstool
)

# The rig gets the Foxglove bridge for the same reason the workstation does: it
# is how a screenless appliance is inspected from a laptop, and fm_ros2's
# recorder service launches it on boot as part of the default viewer profile.
# Without it the whole service exits, not just the viewer.
FM_ROS_APT_JETSON=(
  ros-humble-ros-base
  ros-humble-rmw-fastrtps-cpp
  ros-humble-rmw-cyclonedds-cpp
  ros-humble-foxglove-bridge
  python3-rosdep
  python3-colcon-common-extensions
  python3-vcstool
)

# RMW implementations a provisioned host must be able to start a node under.
#
# This is the requirement; the apt lists above are one way of meeting it. Stated
# separately because the failure it guards against is a package missing from
# those lists, which installs cleanly and reports nothing — apt is satisfied by
# any one RMW provider, so the shortfall only appears when a node starts and
# exits with "failed to load shared library 'librmw_<name>.so'".
#
# fm_ros2 pins FastDDS in its dds-lan profile and Cyclone in its zenoh profile,
# so both must load on either role. scripts/dev/rehearse.sh asserts it.
FM_ROS_RMW_REQUIRED=(
  rmw_fastrtps_cpp
  rmw_cyclonedds_cpp
)

# --- fm CLI ----------------------------------------------------------------

# The cross-repo CLI (fm list/status/doctor/update/setup). A machine that hosts
# several fm_ros2 checkouts is exactly where `fm status` beats remembering which
# directory is which, so it belongs on both roles.
#
# Installed as an isolated uv tool from a pinned git tag, which is what
# fm-tools' own install.sh does. Pinned here rather than tracking latest: two
# machines provisioned months apart should get the same CLI.
FM_TOOLS_REPO=first-motive/fm-tools
FM_TOOLS_VERSION=v0.8.1

# uv installs the tool. It is not in Ubuntu's archive, so it comes from Astral's
# installer, pinned to a version rather than "latest" for the same reason.
#
# Trust boundary, stated plainly because the installer is a piped script: TLS
# and Astral are the anchor. The download is checksummed only if a sha is
# pinned below — leave it empty and the step warns rather than pretends.
FM_UV_VERSION=0.9.29
FM_UV_INSTALLER_SHA256=

# --- People and data -------------------------------------------------------

# Everyone who works on the machine is in this group, and /data is group-owned
# by it. Services run as their own system user, not as a person.
FM_GROUP=fm

# No roster lives here. Who works on a machine changes far more often than how
# the machine is built, and a name in a committed file is stale the day someone
# joins or leaves.
#
# The administrator is whoever provisions the machine — the account behind the
# sudo that ran install.sh — and is the only account granted sudo. Everyone else
# is added afterwards, with `./run.sh add-user <name>`, into the fm group and
# nothing more.

# Shared storage. Recordings and dataset releases are irreplaceable and belong
# here rather than in a home directory, where a user removal would take them.
FM_DATA_DIR=/data
FM_DATA_SUBDIRS=(
  recordings
  dataset-releases
  runs
  models
)

# What `./run.sh backup` copies to external storage before a wipe: the things
# that cannot be re-made. `models` is absent on purpose — weights are downloads,
# and treating them as precious turns a backup nobody runs into the plan.
FM_BACKUP_SOURCES=(
  recordings
  dataset-releases
  runs
)

# --- Isaac Sim -------------------------------------------------------------

# Containerised because NVIDIA ships native Isaac Sim for 22.04 and 24.04 only,
# and the workstation runs 26.04. Pinned to a tag: a moving `latest` would
# change what a sim run means between two days.
FM_ISAAC_IMAGE=nvcr.io/nvidia/isaac-sim:4.5.0

# Isaac Sim rebuilds its shader and asset caches from cold on every start unless
# they live on the host. Entries are "host-subdir|container-path"; the host side
# hangs off FM_ISAAC_CACHE_DIR.
FM_ISAAC_CACHE_DIR="$HOME/.cache/isaac-sim"
FM_ISAAC_CACHE_MAP=(
  "kit|/isaac-sim/kit/cache"
  "ov|/root/.cache/ov"
  "pip|/root/.cache/pip"
  "glcache|/root/.cache/nvidia/GLCache"
  "computecache|/root/.nv/ComputeCache"
  "logs|/root/.nvidia-omniverse/logs"
  "data|/root/.local/share/ov/data"
  "documents|/root/Documents"
)

# The image refuses to start without both. Setting them here rather than in the
# launch wrapper keeps the acceptance visible in the manifest, where it is
# reviewed, instead of buried in a docker run line.
FM_ISAAC_ACCEPT_EULA=Y
FM_ISAAC_PRIVACY_CONSENT=Y

# --- Networking ------------------------------------------------------------

# CycloneDDS asks for a 128 MB socket receive buffer and treats a shortfall as
# fatal. 134217728 = 128 MiB.
FM_DDS_RMEM_MAX=134217728

# The Livox MID-360 ships at a fixed address and expects the host on the same
# /24. Used by ./run.sh lidar-net, which puts them on a dedicated interface.
FM_LIDAR_IP=192.168.1.131
FM_LIDAR_HOST_IP=192.168.1.10

# --- Flashable images ------------------------------------------------------
#
# One pinned image per role, so `./run.sh flash --role <role>` never has to be
# told what to write. The names are role-suffixed scalars rather than a map, the
# same shape FM_OS_CODENAME_* already uses: flash resolves the pair by
# indirection on the role, and a role with no pin fails loudly instead of
# resolving to some other role's image.
#
# Both are pinned by sha256. An upstream image refresh must break loudly here,
# not change what a flash means silently.

# Canonical's preinstalled Ubuntu Server image for Jetson Orin — the OS the
# jetson role provisions on top of. Flashed with its cloud-init seed replaced
# inside the rootfs, so the appliance boots configured.
FM_IMAGE_URL_JETSON="https://cdimage.ubuntu.com/releases/jammy/release/nvidia-tegra/ubuntu-22.04-preinstalled-server-arm64+tegra-jetson.img.xz"
FM_IMAGE_SHA256_JETSON=27c54b9f3a23b4c8a6a8490cc41281061b359fea031c44ebdf7932316331f68a

# Ubuntu Desktop for the GPU workstation. The desktop ISO rather than the server
# one because the workstation is a box people sit at — rviz, Isaac Sim, and the
# annotation tooling all want a session — and its installer carries the
# `ubuntu-desktop-minimal` source the autoinstall seed selects.
#
# The ISO is written raw and the seed rides in a second FAT partition, so there
# is no decompression step and nothing to loop-mount: an ISO's filesystem is
# read-only, and remastering one on macOS would mean xorriso in a container.
FM_IMAGE_URL_WORKSTATION="https://releases.ubuntu.com/26.04/ubuntu-26.04-desktop-amd64.iso"
FM_IMAGE_SHA256_WORKSTATION=487f87faaf547ea30e0aba4d5b53346292571256b25333a978db1692bcee9dd2

# Size of the FAT partition `flash` appends after a raw-written ISO to carry the
# autoinstall seed. The seed is a few kilobytes; the floor is what mkfs.fat and
# the two partition tools will accept for a FAT16 volume without complaint.
FM_FLASH_CIDATA_SIZE_MB=64

# Rootfs partition start, in 512-byte sectors, of the exact Jetson image above.
# That image ships its cloud-init seed baked into the ext4 rootfs (datasource
# NoCloud, seed dir wins over any FAT drop-in), so ./run.sh flash loop-mounts
# the rootfs at this offset to replace the seed before writing the card. A
# constant of the pinned image: re-derive with `fdisk -l` on an image bump.
FM_JETSON_ROOTFS_OFFSET=104448

# The account `flash` creates on either role's machine. Not the machine's
# identity — that is the card, derived from --name and baked into the seed —
# only the human-shaped login every First Motive box answers on.
FM_FLASH_USER=fm

# What each role's first boot asks fm_ros2 to install, as "role|flag".
#
# The machine layer's flag is the role itself (`--jetson`, `--workstation`), so
# it is derived rather than listed. The workspace layer's is not: a rig records
# and a workstation processes, and neither name follows from the other. One
# table here rather than a case in each seed builder, so a role added later is a
# line in this file.
FM_FLASH_WORKSPACE_FLAG=(
  "jetson|--recorder"
  "workstation|--processor"
)

# First-boot provisioning: the two install layers cloud-init chains after the
# card's first boot. Machine layer first, workspace layer second.
#
# The machine layer is a base rather than a whole URL, because the ref that
# completes it is this repo's release tag and that tag is written down in one
# place only, install.sh — `flash` joins the two through fm_release_tag. This
# line read `main` until now, which meant a rig flashed on a Tuesday provisioned
# itself from whatever had merged that morning. An appliance nobody is standing
# next to is the last place an unreleased commit should land, and the first
# place it would go unnoticed.
#
# The workspace layer is a base for the same reason, resolved the same way. It
# read `main` while the paragraph above was already written about the other half:
# the argument applied to one of the two layers and not to its neighbour, so a
# card pinned its machine layer and left the ROS stack floating.
# Written by the first-boot script when a layer fails, holding the step's name.
# `machine doctor` reads it, so a rig that stopped mid-provision says so on the
# first command anyone runs rather than looking done from the outside.
FM_FIRST_BOOT_FAILED=/var/lib/fm/first-boot-failed

FM_SETUP_RAW_BASE="https://raw.githubusercontent.com/first-motive/fm-setup"
FM_ROS2_RAW_BASE="https://raw.githubusercontent.com/first-motive/fm-ros2"
FM_ROS2_REPO_URL="https://github.com/first-motive/fm-ros2.git"
