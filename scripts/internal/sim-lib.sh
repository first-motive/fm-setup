#!/usr/bin/env bash
#
# sim-lib.sh — the sim step's pure checks, sourced by scripts/steps/91-sim.sh
# and tested directly by scripts/dev/test-sim.sh.
#
# Nothing here touches the host. Each function takes what it judges as
# arguments or stdin and answers with output and a return code, so the rules
# that decide what reaches a root-started service can be tested without one.
#
# Requires lib.sh (fm_err) to be sourced first.

# The ExecStart fm-sim's template ships, exactly. Anything else is refused.
SIM_TEMPLATE_EXEC='@UV@ run --project @WORKDIR@ fm-sim-agent'

# sim_safe_word WORD — 0 when WORD is safe in a unit's command line or paths.
#
# A space splits an argument, `%` and `$` are expanded by systemd itself, and
# quotes and backslashes change how systemd splits the line, so a value
# carrying one would start the agent with words nobody wrote.
sim_safe_word() {
  case "$1" in
    "" | *[[:space:]]* | *%* | *\$* | *\"* | *\'* | *\\* | *\;*)
      fm_err "refusing '$1' in the agent's unit — no spaces, quotes, %, \$, \\ or ;"
      return 1 ;;
  esac
}

_sim_refuse_line() {  # line reason
  fm_err "fm-sim's unit template is refused — $2"
  fm_err "  line: $1"
  return 1
}

# sim_render_unit TEMPLATE USER WORKDIR EXEC ENV_FILE ORIGIN — the unit, or a refusal.
#
# The template comes from another repo and becomes a root-started service with
# docker rights, so it is parsed against an allowlist rather than trusted.
# Comments and blank lines pass through. Every other line must be a known key in
# a known section, once, with a value in that key's shape:
#
#   [Unit]     Description (no specifiers), After, Wants, Requires (unit names)
#   [Service]  Type (simple|exec), User=@USER@, WorkingDirectory=@WORKDIR@,
#              EnvironmentFile=ENV_FILE, ExecStart exactly SIM_TEMPLATE_EXEC,
#              TimeoutStopSec and RestartSec (seconds), Restart (always|on-failure)
#   [Install]  WantedBy (unit names)
#
# User, WorkingDirectory and ExecStart are then replaced with USER, WORKDIR and
# EXEC. ORIGIN names where the template came from, in a header comment.
sim_render_unit() {
  local text="$1" user="$2" workdir="$3" exec="$4" env_file="$5" origin="$6"
  local line key value section="" seen=" " out word need
  local units_re='^[A-Za-z0-9@._-]+( [A-Za-z0-9@._-]+)*$'
  sim_safe_word "$user" || return 1
  sim_safe_word "$workdir" || return 1
  for word in $exec; do sim_safe_word "$word" || return 1; done

  out="# Rendered by fm-setup's sim step from $origin."
  out+=$'\n'"# Re-run the step rather than editing this file."

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "" | "#"* | ";"*) out+=$'\n'"$line"; continue ;;
      *\\) _sim_refuse_line "$line" "a continued line"; return 1 ;;
      [[:space:]]*) _sim_refuse_line "$line" "an indented line"; return 1 ;;
      "[Unit]" | "[Service]" | "[Install]")
        case "$seen" in *" $line "*) _sim_refuse_line "$line" "a repeated section"; return 1 ;; esac
        seen+="$line "
        section="$line"
        out+=$'\n'"$line"
        continue ;;
      "["*) _sim_refuse_line "$line" "an unknown section"; return 1 ;;
      *=*) ;;
      *) _sim_refuse_line "$line" "not a key=value line"; return 1 ;;
    esac
    [ -n "$section" ] || { _sim_refuse_line "$line" "a key outside any section"; return 1; }
    key="${line%%=*}"
    value="${line#*=}"
    case "$seen" in *" $section$key "*) _sim_refuse_line "$line" "a repeated key"; return 1 ;; esac
    seen+="$section$key "

    case "$section$key" in
      "[Unit]Description")
        case "$value" in *%* | *\$*) _sim_refuse_line "$line" "a specifier in the description"; return 1 ;; esac ;;
      "[Unit]After" | "[Unit]Wants" | "[Unit]Requires" | "[Install]WantedBy")
        printf '%s' "$value" | grep -Eq "$units_re" || { _sim_refuse_line "$line" "not a list of unit names"; return 1; } ;;
      "[Service]Type")
        case "$value" in simple | exec) ;; *) _sim_refuse_line "$line" "an unexpected Type"; return 1 ;; esac ;;
      "[Service]Restart")
        case "$value" in always | on-failure) ;; *) _sim_refuse_line "$line" "an unexpected Restart"; return 1 ;; esac ;;
      "[Service]TimeoutStopSec" | "[Service]RestartSec")
        printf '%s' "$value" | grep -Eq '^[0-9]+$' || { _sim_refuse_line "$line" "not a number of seconds"; return 1; } ;;
      "[Service]User")
        [ "$value" = "@USER@" ] || { _sim_refuse_line "$line" "User must be @USER@"; return 1; }
        line="User=$user" ;;
      "[Service]WorkingDirectory")
        [ "$value" = "@WORKDIR@" ] || { _sim_refuse_line "$line" "WorkingDirectory must be @WORKDIR@"; return 1; }
        line="WorkingDirectory=$workdir" ;;
      "[Service]EnvironmentFile")
        [ "$value" = "$env_file" ] || { _sim_refuse_line "$line" "EnvironmentFile must be $env_file"; return 1; } ;;
      "[Service]ExecStart")
        [ "$value" = "$SIM_TEMPLATE_EXEC" ] || { _sim_refuse_line "$line" "ExecStart must be '$SIM_TEMPLATE_EXEC'"; return 1; }
        line="ExecStart=$exec" ;;
      *) _sim_refuse_line "$line" "a key the allowlist does not hold"; return 1 ;;
    esac
    out+=$'\n'"$line"
  done <<<"$text"

  for need in "[Service]User" "[Service]WorkingDirectory" "[Service]ExecStart" "[Service]EnvironmentFile" "[Install]WantedBy"; do
    case "$seen" in *" $need "*) ;; *) fm_err "fm-sim's unit template is refused — it has no $need"; return 1 ;; esac
  done
  printf '%s\n' "$out"
}

# sim_tree_ok — read `git ls-tree -r` output on stdin; 0 when it lists at least
# one entry and every entry is a plain file (mode 100644 or 100755).
#
# Checked before anything is extracted: a symlink in the tree would let the
# copy point the service at a path outside it, and a submodule is code the pin
# does not cover.
sim_tree_ok() {
  local mode rest count=0
  while read -r mode rest; do
    [ -n "$mode" ] || continue
    case "$mode" in
      100644 | 100755) count=$((count + 1)) ;;
      *) fm_err "refusing a tree entry of mode $mode: ${rest#*$'\t'}"; return 1 ;;
    esac
  done
  [ "$count" -gt 0 ] || { fm_err "the tree is empty"; return 1; }
}

# sim_test_root_ok PREFIX — 0 when PREFIX may stand in for / in a test run.
#
# Honoured only with FM_SIM_TEST=1 and only under the temp directory, so the
# test hook cannot redirect a production install anywhere that matters.
sim_test_root_ok() {
  local prefix="$1" tmp="${TMPDIR:-/tmp}"
  tmp="${tmp%/}"
  [ "${FM_SIM_TEST:-0}" = 1 ] || { fm_err "FM_SIM_TEST_ROOT is set without FM_SIM_TEST=1 — refusing"; return 1; }
  # A temp dir of / would make every path "under" it.
  [ -n "$tmp" ] || { fm_err "no temp directory to hold FM_SIM_TEST_ROOT — refusing"; return 1; }
  case "$prefix" in
    *..*) fm_err "FM_SIM_TEST_ROOT must not hold '..': $prefix"; return 1 ;;
  esac
  [ "${prefix#"$tmp"/}" != "$prefix" ] && [ -n "${prefix#"$tmp"/}" ] && return 0
  fm_err "FM_SIM_TEST_ROOT must sit under $tmp/: $prefix"
  return 1
}
