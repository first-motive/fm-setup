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
  "docker|30-docker.sh|on"
  "ros2|40-ros2.sh|on"
  "udev-rules|45-udev-rules.sh|on"
  "dds-tuning|50-dds-tuning.sh|on"
  "tailscale|60-tailscale.sh|on"
)

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
FM_ROS_APT_WORKSTATION=(
  ros-lyrical-desktop
  ros-lyrical-foxglove-bridge
  python3-rosdep
  python3-colcon-common-extensions
  python3-vcstool
)

FM_ROS_APT_JETSON=(
  ros-humble-ros-base
  python3-rosdep
  python3-colcon-common-extensions
  python3-vcstool
)

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
