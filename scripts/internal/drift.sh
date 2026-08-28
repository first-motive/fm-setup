#!/usr/bin/env bash
#
# drift.sh — report machine state that no step accounts for.
#
#   scripts/internal/drift.sh [steps-dir]
#   scripts/internal/drift.sh [steps-dir] --declared-units   # the parse, alone
#
# The ledger says what each step added. The baseline says what the OS image
# arrived with. Anything manually installed that is in neither got onto this
# machine some other way, and a rebuild from the repos alone will not reproduce
# it. Same for a systemd unit no step declares, and for an uncommitted change
# under /etc.
#
# Reports; never fixes. A machine is repaired by writing the step that explains
# the drift, or by removing what does not belong — both decisions a person
# makes. Always exits 0: this runs at the end of `--check`, which is read-only
# and must not fail because a host has drifted.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT:-$(cd "$_here/../.." && pwd)}"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"

STEPS_DIR="${1:-$FM_ROOT/scripts/steps}"

# Every package any step has claimed on this host, plus the baseline, sorted.
#
# Every sort feeding a comm below pins LC_ALL=C — see fm_ledger_steps in lib.sh
# for what a UTF-8 collation does to a byte-wise merge.
accounted_packages() {
  local step
  if [ -f "$(fm_baseline_file)" ]; then cat "$(fm_baseline_file)"; fi
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    fm_ledger_packages "$step"
  done < <(fm_ledger_steps)
}

# Units the steps declare, read out of their FM_UNITS arrays.
#
# Parsed rather than sourced: a step file ends in `fm_dispatch "$@"`, so sourcing
# one to read a variable would run it. The declaration is a single-line array by
# convention, which is what the step template shows.
declared_units() {
  sed -n 's/^FM_UNITS=(\(.*\))$/\1/p' "$STEPS_DIR"/*.sh 2>/dev/null \
    | tr ' ' '\n' | tr -d '"' | sed '/^$/d' | LC_ALL=C sort -u
}

# Units this host will start on its own. `enabled` alone: a static or generated
# unit is not something anyone chose, and reporting those would bury the ones
# somebody did.
enabled_units() {
  fm_has_cmd systemctl || return 0
  systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' | LC_ALL=C sort -u
}

report_packages() {
  local extra
  extra="$(LC_ALL=C comm -13 <(accounted_packages | LC_ALL=C sort -u) <(fm_apt_manual))"
  if [ -z "$extra" ]; then
    fm_ok "packages: none unaccounted for"
    return 0
  fi
  fm_warn "packages no step accounts for:"
  printf '%s\n' "$extra" | sed 's/^/        /' >&2
  fm_info "record one with 'fm pkg add <name>', or write the step that explains it"
}

report_units() {
  local extra
  fm_has_cmd systemctl || { fm_skip "units (no systemctl)"; return 0; }
  extra="$(LC_ALL=C comm -13 <(declared_units) <(enabled_units))"
  if [ -z "$extra" ]; then
    fm_ok "units: none unaccounted for"
    return 0
  fi
  # Loud but not alarming: most hosts carry enabled units from the OS image that
  # no step will ever declare, and this is the list somebody reads once and then
  # declares or disables.
  fm_warn "enabled units no step declares:"
  printf '%s\n' "$extra" | sed 's/^/        /' >&2
}

report_etc() {
  if [ ! -d /etc/.git ]; then
    fm_skip "/etc history (etckeeper not installed)"
    return 0
  fi
  local dirty
  dirty="$(sudo git -C /etc status --porcelain 2>/dev/null | head -20)"
  if [ -z "$dirty" ]; then
    fm_ok "/etc: committed"
    return 0
  fi
  fm_warn "/etc has uncommitted changes:"
  printf '%s\n' "$dirty" | sed 's/^/        /' >&2
}

main() {
  # One inspection flag, because the unit half of this audit is a parse of the
  # step files and a parse is only trustworthy if something can read its answer
  # back. scripts/dev/test-ledger.sh does exactly that.
  if [ "${2:-${1:-}}" = "--declared-units" ]; then
    declared_units
    return 0
  fi

  fm_log "drift"
  if [ ! -f "$(fm_baseline_file)" ]; then
    fm_warn "no baseline — run the system-update step, then this reports properly"
  fi
  report_packages
  report_units
  report_etc
  return 0
}

main "$@"
