#!/usr/bin/env bash
#
# Exercise the personal SSH first-read in disposable home directories.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
INSTALLER="$FM_ROOT/scripts/internal/install-ssh-first-read.sh"
SOURCE="$FM_ROOT/templates/ssh-first-read-AGENTS.md"
# shellcheck disable=SC2016
HOOK_LINE='. "$HOME/.fm-ssh-first-read"'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '    %s\n' "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); printf '    %s\n' "FAIL: $1"; }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; fi
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

HOME_ONE="$TMP/home-one"
mkdir -p "$HOME_ONE"
printf 'export KEEP_ME=1\n' >"$HOME_ONE/.profile"

HOME="$HOME_ONE" bash "$INSTALLER" >/dev/null
first_state="$(cksum "$HOME_ONE/AGENTS.md" "$HOME_ONE/.fm-ssh-first-read" "$HOME_ONE/.profile")"
HOME="$HOME_ONE" bash "$INSTALLER" >/dev/null
second_state="$(cksum "$HOME_ONE/AGENTS.md" "$HOME_ONE/.fm-ssh-first-read" "$HOME_ONE/.profile")"

if cmp -s "$SOURCE" "$HOME_ONE/AGENTS.md"; then
  ok "managed AGENTS.md matches its source"
else
  bad "managed AGENTS.md matches its source"
fi
assert_eq "AGENTS.md is personal" "600" "$(file_mode "$HOME_ONE/AGENTS.md")"
assert_eq "the hook is personal" "600" "$(file_mode "$HOME_ONE/.fm-ssh-first-read")"
assert_eq "the profile keeps existing content" "1" "$(grep -cFx 'export KEEP_ME=1' "$HOME_ONE/.profile")"
assert_eq "the profile sources the hook once" "1" "$(grep -cFx "$HOOK_LINE" "$HOME_ONE/.profile")"
assert_eq "a second install converges" "$first_state" "$second_state"

non_ssh="$(HOME="$HOME_ONE" bash --noprofile --norc -c '. "$HOME/.profile"')"
assert_eq "a non-SSH shell stays quiet" "" "$non_ssh"

ssh_output="$(HOME="$HOME_ONE" SSH_CONNECTION='client 1 server 22' \
  bash --noprofile --norc -ic '. "$HOME/.profile"' 2>/dev/null)"
case "$ssh_output" in
  *"# First Motive Workstation - SSH First Read"*"Full first-read: ~/AGENTS.md"*)
    ok "an interactive SSH shell prints the first-read" ;;
  *) bad "an interactive SSH shell prints the first-read" ;;
esac

HOME_TWO="$TMP/home-two"
mkdir -p "$HOME_TWO"
printf '# My own instructions\n' >"$HOME_TWO/AGENTS.md"
HOME="$HOME_TWO" bash "$INSTALLER" >/dev/null
assert_eq "a personal AGENTS.md is preserved" "# My own instructions" "$(cat "$HOME_TWO/AGENTS.md")"

HOME_THREE="$TMP/home-three"
mkdir -p "$HOME_THREE"
printf '#!/usr/bin/env bash\nprintf unsafe\n' >"$HOME_THREE/.fm-ssh-first-read"
HOME="$HOME_THREE" bash "$INSTALLER" >/dev/null 2>&1
if [ -e "$HOME_THREE/.profile" ]; then
  hook_lines="$(grep -cF "$HOOK_LINE" "$HOME_THREE/.profile" || true)"
else
  hook_lines=0
fi
assert_eq "an unmanaged hook is not sourced" "0" "$hook_lines"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
