#!/usr/bin/env bash
#
# test-docker-repo.sh — exercise the docker step's handling of a second entry
# for Docker's apt repo.
#
#   ./scripts/dev/test-docker-repo.sh
#
# apt refuses to read any source list when two entries for the same repo name
# different Signed-By keyrings, and an image that ships Docker preinstalled (the
# AWS Deep Learning AMI) carries its own. The step moves such an entry aside
# before apt sees ours. What has to hold is the selection: every foreign entry
# for Docker's repo, in either apt format, goes; our own entry, an unrelated
# repo, and a commented-out line stay.
#
# Runs against a sources directory in a temp directory, with a transparent sudo
# and a no-op apt on PATH, so nothing here touches /etc/apt and no case needs
# root.
#
# No test framework, for the reason test-machine.sh gives: this repo has no test
# runner, and a dependency would have to be installed on every machine that
# provisions.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"

# The step calls fm_require_linux at source time. The suite says so rather than
# failing halfway through on a developer's Mac.
[ "$(uname -s)" = "Linux" ] || { fm_warn "docker is a Linux step — skipping on $(uname -s)"; exit 0; }

STEP="$FM_ROOT/scripts/steps/30-docker.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '    %s✓%s %s\n' "${FM_C_GREEN}" "${FM_C_RESET}" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    %s✗%s %s\n' "${FM_C_RED}" "${FM_C_RESET}" "$1"; }

# assert_eq LABEL EXPECTED ACTUAL
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; fi
}

# assert_contains LABEL NEEDLE HAYSTACK
assert_contains() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1"; printf '        expected to contain: %s\n' "$2" ;;
  esac
}

exists() { [ -e "$1" ] && echo true || echo false; }

# --- The fake machine -------------------------------------------------------
#
# sudo is transparent, as in test-ledger.sh; apt-get does nothing, because what
# is under test is the sources directory apt would read, not apt.

BIN="$TMP/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"
cat > "$BIN/sudo" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = -n ]; then shift; fi
exec env "$@"
FAKE

cat > "$BIN/apt-get" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE

chmod +x "$BIN"/*

DIR="$TMP/sources.list.d"
export FM_APT_SOURCES_DIR="$DIR"
OURS="$DIR/docker.sources"
AMI_LIST="$DIR/docker.list"
AMI_SOURCES="$DIR/docker-ce.sources"
OTHER="$DIR/nvidia-container-toolkit.list"
COMMENTED="$DIR/old-docker.list"

# stage — lay out the directory as the AWS Deep Learning AMI leaves it, plus our
# own entry and the two that must survive.
stage() {
  rm -rf "$DIR"
  mkdir -p "$DIR"
  cat > "$OURS" <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu noble stable\n' > "$AMI_LIST"
  cat > "$AMI_SOURCES" <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Signed-By: /usr/share/keyrings/docker-archive-keyring.gpg
EOF
  cat > "$OTHER" <<'EOF'
deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /
EOF
  printf '# deb https://download.docker.com/linux/ubuntu noble stable\n' > "$COMMENTED"
}

# run_step_fn FUNCTION… — source the step, then call one of its functions.
#
# `check` as the dispatch argument, as in test-supply-chain.sh: sourcing runs
# fm_dispatch, and check is the mode that changes nothing.
run_step_fn() {
  # shellcheck disable=SC1090
  ( . "$STEP" check >/dev/null 2>&1 || true; "$@" ) 2>&1
}

listing() { find "$DIR" -type f | LC_ALL=C sort; }

fm_log "docker apt repo: foreign entries"

# --- Detection ---------------------------------------------------------------

stage
found="$(run_step_fn foreign_docker_entries | LC_ALL=C sort)"
assert_eq "both foreign entries are found, in either format" \
  "$(printf '%s\n' "$AMI_SOURCES" "$AMI_LIST" | LC_ALL=C sort)" "$found"

# --- check is read-only and says so -----------------------------------------

before="$(listing)"
out="$(bash "$STEP" check 2>&1 || true)"
assert_contains "check names the foreign .list entry" "$AMI_LIST" "$out"
assert_contains "check names the foreign .sources entry" "$AMI_SOURCES" "$out"
assert_eq "check changes nothing" "$before" "$(listing)"
assert_eq "check exits 0" 0 "$(bash "$STEP" check >/dev/null 2>&1; echo $?)"

# --- Cleanup -----------------------------------------------------------------

run_step_fn disable_foreign_docker_entries >/dev/null
assert_eq "the foreign .list entry is moved aside" "false:true" \
  "$(exists "$AMI_LIST"):$(exists "$AMI_LIST.fm-setup-disabled")"
assert_eq "the foreign .sources entry is moved aside" "false:true" \
  "$(exists "$AMI_SOURCES"):$(exists "$AMI_SOURCES.fm-setup-disabled")"
assert_eq "our own entry is left alone" "true" "$(exists "$OURS")"
assert_eq "an unrelated repo is left alone" "true" "$(exists "$OTHER")"
assert_eq "a commented-out entry is left alone" "true" "$(exists "$COMMENTED")"
assert_eq "nothing foreign remains" "" "$(run_step_fn foreign_docker_entries)"

after="$(listing)"
run_step_fn disable_foreign_docker_entries >/dev/null
assert_eq "a second cleanup changes nothing" "$after" "$(listing)"

# --- install cleans up when our entry already exists ------------------------
#
# install skips add_repo once our entry is there, so the cleanup has to run on
# that path too, or a rerun keeps the conflict. Packages and the docker group
# are stubbed out: fm_has_pkg answering no keeps the conflict-removal loop from
# reaching the runner's own packages, and `id -nG` answering with docker takes
# the already-a-member path, so no prompt is reached. The fm_apt_install stub
# reports what apt would have read, because that is the moment the conflict
# used to fail the bootstrap.

stage
ours_before="$(cat "$OURS")"
# shellcheck disable=SC2016  # expanded inside the sourced step, not here
out="$(run_step_fn eval '
  fm_has_pkg() { return 1; }
  id() { if [ "${1:-}" = -nG ]; then echo "$USER docker"; else command id "$@"; fi; }
  fm_apt_install() { if [ -n "$(foreign_docker_entries)" ]; then echo APT_SAW_FOREIGN; else echo APT_SAW_CLEAN; fi; }
  add_repo() { echo ADD_REPO_RAN; }
  do_install' && echo RC=0 || echo RC=1)"
assert_contains "install exits 0" "RC=0" "$out"
assert_contains "foreign entries are gone before apt runs" "APT_SAW_CLEAN" "$out"
assert_eq "install moves the foreign entries aside" "false:false" \
  "$(exists "$AMI_LIST"):$(exists "$AMI_SOURCES")"
assert_eq "install keeps our existing entry as it was" "$ours_before" "$(cat "$OURS")"
case "$out" in
  *ADD_REPO_RAN*) bad "install does not re-add a repo that is present" ;;
  *) ok "install does not re-add a repo that is present" ;;
esac

# --- An earlier move is never overwritten ----------------------------------
#
# The .fm-setup-disabled file is the only copy of the image's entry as it was.
# A second foreign entry under the same name must be left for a person.

stage
printf 'an earlier move\n' > "$AMI_LIST.fm-setup-disabled"
out="$(run_step_fn disable_foreign_docker_entries)"
assert_eq "an existing destination keeps its contents" "an earlier move" \
  "$(cat "$AMI_LIST.fm-setup-disabled")"
assert_eq "the entry behind it is left in place" "true" "$(exists "$AMI_LIST")"
assert_contains "the skip is reported" "already exists" "$out"

# --- A symlinked entry is not touched ----------------------------------------

stage
mv "$AMI_SOURCES" "$TMP/managed.sources"
ln -s "$TMP/managed.sources" "$AMI_SOURCES"
run_step_fn disable_foreign_docker_entries >/dev/null
assert_eq "a symlinked entry stays a symlink in place" "true" \
  "$([ -L "$AMI_SOURCES" ] && echo true || echo false)"

# --- Result ----------------------------------------------------------------

echo
if [ "$FAIL" -eq 0 ]; then
  fm_ok "$PASS passed"
else
  fm_err "$FAIL failed, $PASS passed"
  exit 1
fi
