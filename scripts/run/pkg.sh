#!/usr/bin/env bash
#
# pkg — install a package the machine needs now, recorded like everything else.
#
#   ./run.sh pkg add ffmpeg        install it, and write it into the adhoc ledger
#   ./run.sh pkg list              what the adhoc ledger holds
#   ./run.sh pkg remove            remove everything the adhoc ledger holds
#
# The rule is that no package reaches a First Motive host except through a step.
# In practice a package is sometimes needed before anyone knows whether it is
# permanent, and the honest options were a step written on a guess or an
# `apt install` nobody records. This is the third: the package is installed and
# attributed to `adhoc`, so it is accounted for immediately, `pkg list` is the
# promotion queue, and drift stops reporting it.
#
# It is not an escape from the rule. A package still here next month belongs in
# a step — move it, then `pkg remove` drops the adhoc claim.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

# One ledger for every one-off, rather than one per package: the question this
# answers is "what is on this machine that no step explains", and that is a list.
STEP=adhoc

usage() {
  cat <<'EOF'
pkg — install a one-off package, recorded against the adhoc ledger

Usage: ./run.sh pkg <command>

  add <name>…    install and record
  list           show what the adhoc ledger holds
  remove         remove everything it holds, if nothing else needs it
  -h, --help     show this help

A package that turns out to be permanent belongs in a step. See CONTRIBUTING.md.
EOF
}

main() {
  local cmd="${1:-}"
  [ "$#" -gt 0 ] && shift

  case "$cmd" in
    add)
      # Only the two modes that touch apt need a Linux host. Help and the
      # promotion queue are readable from anywhere, including a laptop reading a
      # rig's ledger over a checkout.
      fm_require_linux
      [ "$#" -gt 0 ] || { fm_err "name what to install"; usage; return 1; }
      fm_apt_install "$STEP" "$@"
      fm_info "promote it to a step when it turns out to be permanent"
      ;;
    list)
      local pkgs
      pkgs="$(fm_ledger_packages "$STEP")"
      if [ -z "$pkgs" ]; then
        fm_ok "no one-off packages on this machine"
        return 0
      fi
      fm_log "adhoc packages — each one is a step waiting to be written"
      printf '%s\n' "$pkgs" | sed 's/^/    /'
      ;;
    remove)
      fm_require_linux
      fm_apt_uninstall "$STEP"
      ;;
    -h|--help|"") usage ;;
    *) fm_err "unknown command: $cmd"; usage; return 1 ;;
  esac
}

main "$@"
