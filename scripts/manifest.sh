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
# once and listed twice.
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
)

# Ubuntu 22.04 on the Jetson Orin Nano: the capture rig.
JETSON_STEPS=(
  "system-update|00-system-update.sh|on"
)
