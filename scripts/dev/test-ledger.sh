#!/usr/bin/env bash
#
# test-ledger.sh — exercise the apt ledger against a fake apt.
#
#   ./scripts/dev/test-ledger.sh
#
# The ledger decides what an uninstall is allowed to remove from a provisioned
# machine, which makes it the one part of this repo whose bug is measured in
# packages someone did not ask to lose. Proving it needs a machine to install
# on, or an apt that lies convincingly — this is the second.
#
# A fake apt-get, apt-mark, dpkg and sudo go on PATH ahead of the real ones,
# backed by two files: the installed set and the manual set. FM_STATE_DIR points
# at a temp directory, so nothing here needs root and nothing touches
# /var/lib/fm-setup.
#
# No test framework, for the same reason test-machine.sh has none: this repo has
# no test runner, and a dependency would have to be installed on every machine
# that provisions.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

export FM_STATE_DIR="$TMP/state"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '    %s✓%s %s\n' "${FM_C_GREEN}" "${FM_C_RESET}" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    %s✗%s %s\n' "${FM_C_RED}" "${FM_C_RESET}" "$1"; }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; fi
}

# assert_rc LABEL EXPECTED_CODE COMMAND… — output swallowed, because several
# cases assert on a refusal and its message buries the line that matters.
assert_rc() {
  local label="$1" want="$2"; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  assert_eq "$label" "$want" "$got"
}

# --- The fake machine ------------------------------------------------------
#
# INSTALLED is what dpkg admits to. MANUAL is what apt-mark calls asked-for, so
# an auto-pulled dependency appears in the first and not the second — which is
# the distinction the ledger is built on. REVDEP lines are "package|dependent":
# a simulated removal of the package also removes the dependent, which is how a
# widening removal is staged.

BIN="$TMP/bin"
mkdir -p "$BIN"
export INSTALLED="$TMP/installed" MANUAL="$TMP/manual" REVDEP="$TMP/revdep"
: > "$INSTALLED"; : > "$MANUAL"; : > "$REVDEP"
export PATH="$BIN:$PATH"

cat > "$BIN/dpkg" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "-s" ] || exit 1
grep -qx "$2" "$INSTALLED"
FAKE

cat > "$BIN/apt-mark" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "showmanual" ] || exit 1
cat "$MANUAL"
FAKE

cat > "$BIN/sudo" <<'FAKE'
#!/usr/bin/env bash
exec env "$@"
FAKE

cat > "$BIN/apt-get" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
simulate=0
mode=""
pkgs=()
for arg in "$@"; do
  case "$arg" in
    -s) simulate=1 ;;
    -y|-q) ;;
    update|install|remove) [ -n "$mode" ] || mode="$arg" ;;
    -*) ;;
    *) pkgs+=("$arg") ;;
  esac
done

# Every dependent of a package, transitively, as the removal set apt would take.
revdeps() {
  local seen=("$1") queue=("$1") cur d
  while [ "${#queue[@]}" -gt 0 ]; do
    cur="${queue[0]}"; queue=("${queue[@]:1}")
    while IFS='|' read -r pkg dep; do
      [ "$pkg" = "$cur" ] || continue
      case " ${seen[*]} " in *" $dep "*) continue ;; esac
      seen+=("$dep"); queue+=("$dep")
    done < "$REVDEP"
  done
  printf '%s\n' "${seen[@]}"
}

case "$mode" in
  update) exit 0 ;;
  install)
    for p in "${pkgs[@]:-}"; do
      [ -n "$p" ] || continue
      grep -qx "$p" "$INSTALLED" || echo "$p" >> "$INSTALLED"
      grep -qx "$p" "$MANUAL" || echo "$p" >> "$MANUAL"
      # A dependency arrives installed but never manual.
      while IFS='|' read -r pkg dep; do
        [ "$dep" = "$p" ] || continue
        grep -qx "$pkg" "$INSTALLED" || echo "$pkg" >> "$INSTALLED"
      done < "$REVDEP"
    done
    ;;
  remove)
    all=()
    for p in "${pkgs[@]:-}"; do
      [ -n "$p" ] || continue
      while IFS= read -r r; do
        grep -qx "$r" "$INSTALLED" || continue
        case " ${all[*]:-} " in *" $r "*) continue ;; esac
        all+=("$r")
      done < <(revdeps "$p")
    done
    if [ "$simulate" = 1 ]; then
      for r in "${all[@]:-}"; do [ -n "$r" ] && echo "Remv $r [1.0]"; done
      exit 0
    fi
    for r in "${all[@]:-}"; do
      [ -n "$r" ] || continue
      grep -vx "$r" "$INSTALLED" > "$INSTALLED.tmp" || true; mv "$INSTALLED.tmp" "$INSTALLED"
      grep -vx "$r" "$MANUAL" > "$MANUAL.tmp" || true; mv "$MANUAL.tmp" "$MANUAL"
    done
    ;;
esac
FAKE

chmod +x "$BIN"/*

ledger_of() { fm_ledger_packages "$1" | tr '\n' ' ' | sed 's/ $//'; }

fm_log "apt ledger"

# --- Install records what appeared -----------------------------------------

# libfoo is a dependency of foo: installed, never manual, so it must not land in
# the ledger. Nothing else may remove it, and this step must not claim it.
echo "libfoo|foo" >> "$REVDEP"

fm_apt_install docker foo bar >/dev/null
assert_eq "ledger holds what the step added" "bar foo" "$(ledger_of docker)"
assert_eq "an auto-pulled dependency is not claimed" "" "$(grep -x libfoo "$(fm_ledger_file docker)" || true)"
assert_eq "the dependency is installed all the same" "libfoo" "$(grep -x libfoo "$INSTALLED")"

# --- Install is idempotent -------------------------------------------------

fm_apt_install docker foo bar >/dev/null
assert_eq "a re-run adds nothing" "bar foo" "$(ledger_of docker)"

# A package another step already installed is present, so this step does not
# claim it. Two owners for one package is how an uninstall takes a package the
# other step still needs.
fm_apt_install toolkit foo >/dev/null
assert_eq "a present package is not claimed twice" "" "$(ledger_of toolkit)"

# --- Uninstall refuses to widen --------------------------------------------

# baz is installed by its own step, and foo depends on it, so removing baz would
# take foo — which belongs to docker.
echo "baz|foo" >> "$REVDEP"
fm_apt_install other baz >/dev/null
assert_eq "the other step's ledger" "baz" "$(ledger_of other)"
# A step that claimed nothing holds no ledger, so it is not discoverable either.
assert_eq "every ledger is discoverable" "docker other" "$(fm_ledger_steps | tr '\n' ' ' | sed 's/ $//')"
assert_rc "uninstall refuses when it would widen" 1 fm_apt_uninstall other
assert_eq "the refusal names the extra" "1" \
  "$(fm_apt_uninstall other 2>&1 | grep -c 'would also take foo')"
assert_eq "nothing was removed" "2" "$(grep -cx 'baz\|foo' "$INSTALLED")"
assert_eq "the ledger survives a refusal" "baz" "$(ledger_of other)"

# --- Uninstall removes exactly the ledger ----------------------------------

fm_apt_uninstall docker >/dev/null
assert_eq "the step's packages are gone" "" "$(grep -x 'foo\|bar' "$INSTALLED" || true)"
assert_eq "the dependency is left behind, never autoremoved" "libfoo" "$(grep -x libfoo "$INSTALLED")"
assert_eq "the ledger is gone with them" "false" \
  "$([ -f "$(fm_ledger_file docker)" ] && echo true || echo false)"

# With foo gone, the other step no longer widens.
assert_rc "the same uninstall now succeeds" 0 fm_apt_uninstall other

# --- Nothing to do ---------------------------------------------------------

assert_rc "a step with no ledger is a skip, not a failure" 0 fm_apt_uninstall never-installed
fm_ledger_record ghost gone-by-hand >/dev/null 2>&1 || true
printf 'gone-by-hand\n' > "$(fm_ledger_file ghost)"
assert_rc "a ledger whose packages are already gone succeeds" 0 fm_apt_uninstall ghost
assert_eq "and is cleared" "false" \
  "$([ -f "$(fm_ledger_file ghost)" ] && echo true || echo false)"

# --- A step id is a filename ------------------------------------------------

# Both writers run under sudo, so an id that resolves outside the ledger
# directory would put a root-owned write wherever it pointed.
assert_rc "an id with a slash is refused" 1 fm_ledger_file "../evil"
assert_rc "an empty id is refused" 1 fm_ledger_file ""
assert_rc "uninstall refuses the same id" 1 fm_apt_uninstall "../evil"
assert_eq "and wrote nothing outside the ledger" "false" \
  "$([ -e "$TMP/state/evil" ] && echo true || echo false)"

# --- Drift ------------------------------------------------------------------
#
# The audit's package half, which is the half a fake apt can prove. Units and
# /etc need a real host, and both degrade to a skip where they cannot look.

DRIFT="$FM_ROOT/scripts/internal/drift.sh"
export FM_ROOT
drift_out() { bash "$DRIFT" "$FM_ROOT/scripts/steps" 2>&1; }

# The host arrives with something already installed, as every host does.
echo "coreutils" >> "$INSTALLED"; echo "coreutils" >> "$MANUAL"
fm_baseline_capture >/dev/null
assert_eq "the baseline is captured once" "coreutils" "$(cat "$(fm_baseline_file)")"

fm_apt_install docker foo >/dev/null
assert_eq "a package a step installed is accounted for" "1" \
  "$(drift_out | grep -c 'packages: none unaccounted for')"

# Installed behind the steps' back, which is the whole point of the audit.
echo "sl" >> "$INSTALLED"; echo "sl" >> "$MANUAL"
assert_eq "a package nobody claimed is reported" "1" "$(drift_out | grep -c '^ *sl$')"

# Recording it is what stops the report, without pretending a step exists.
fm_ledger_record adhoc sl
assert_eq "recording it clears the report" "1" \
  "$(drift_out | grep -c 'packages: none unaccounted for')"

# A second capture would adopt everything the steps have since added.
fm_baseline_capture >/dev/null
assert_eq "the baseline is never recaptured" "coreutils" "$(cat "$(fm_baseline_file)")"

# --- Declared units ---------------------------------------------------------
#
# The audit reads FM_UNITS out of the step files with sed rather than sourcing
# them, because a step file ends in fm_dispatch and sourcing one would run it.
# That makes the parse a contract with the step template, so it is held here.

FAKE_STEPS="$TMP/steps"
mkdir -p "$FAKE_STEPS"
printf 'FM_UNITS=(one.service two.timer)\n' > "$FAKE_STEPS/10-a.sh"
printf 'FM_UNITS=("quoted.service")\n'      > "$FAKE_STEPS/20-b.sh"
printf 'echo no units here\n'               > "$FAKE_STEPS/30-c.sh"

assert_eq "units are read from every step that declares them" "one.service quoted.service two.timer" \
  "$(bash "$DRIFT" "$FAKE_STEPS" --declared-units | tr '\n' ' ' | sed 's/ $//')"
assert_rc "the audit runs against a steps dir that declares none" 0 bash "$DRIFT" "$FM_ROOT/scripts/steps"

# --- Result ----------------------------------------------------------------

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  fm_ok "$PASS passed"
else
  fm_err "$FAIL failed, $PASS passed"
  exit 1
fi
