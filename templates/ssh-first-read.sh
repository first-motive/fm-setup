# shellcheck shell=bash
# Managed by fm-setup. Written by `fm setup-onboard`; edits are replaced.

case "$-" in
  *i*) ;;
  *) return 0 ;;
esac

[ -n "${SSH_CONNECTION:-}" ] || return 0
[ -f "$HOME/AGENTS.md" ] && [ -r "$HOME/AGENTS.md" ] || return 0

printf '\n'
sed -n '1,35p' "$HOME/AGENTS.md"
printf '\nFull first-read: ~/AGENTS.md\n\n'
