#!/usr/bin/env bash
#
# seed-ros-source.sh — pre-seed the ROS 2 apt source the way Canonical's Jetson
# image does, so the rehearsal container sees what a real rig sees.
#
#   scripts/dev/seed-ros-source.sh jetson
#
# The Tegra image ships /etc/apt/sources.list.d/ros2.sources (deb822) before
# fm-setup runs. A rehearsal that starts from a bare jammy image never has it,
# which is how a second, conflicting source written by 40-ros2.sh passed CI and
# broke every first boot (#28). Only the jetson role is seeded: the workstation
# image carries no ROS source.
#
# Container-only by design. It writes into /etc/apt as root, which is exactly
# what a rehearsal container is for and nothing else is.

set -euo pipefail

role="${1:?role}"
[ -e /.dockerenv ] || { echo "not in a container — refusing to seed apt sources" >&2; exit 1; }
[ "$role" = "jetson" ] || exit 0

# A bare image has no curl yet; base-deps installs it later, this runs first.
apt-get install -y -qq curl ca-certificates >/dev/null
keyring=/usr/share/keyrings/ros-archive-keyring.gpg
curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o "$keyring"
cat >/etc/apt/sources.list.d/ros2.sources <<SRC
Types: deb
URIs: http://packages.ros.org/ros2/ubuntu
Suites: jammy
Components: main
Signed-By: $keyring
SRC
echo "seeded /etc/apt/sources.list.d/ros2.sources for $role"
