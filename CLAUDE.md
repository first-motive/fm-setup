# CLAUDE.md

Guidance for AI agents working in this repository.

## The Rule

**No system-level change outside a step in this repo.**

If work requires a package, a sysctl, a udev rule, a systemd unit, a user, or a
group, do not apply it to the host directly. Write it as a step under
`scripts/steps/`, register it in `scripts/manifest.sh`, and run it through
`./install.sh`. An `apt-get install` typed into a terminal is invisible to the
next rebuild; a step is not.

This holds even when the change is one line and the machine is in front of you.
The point is that the machine stays reproducible, and every exception costs the
next person a debugging session.

## Writing A Step

Copy the shape of `scripts/steps/00-system-update.sh`:

1. Strict mode, then source `lib.sh` and `scripts/manifest.sh`.
2. Define `do_check`, `do_install`, `do_uninstall`.
3. End with `fm_dispatch "$@"`.
4. Register it in the role arrays in `scripts/manifest.sh`.

Rules the modes must hold to:

- `check` never mutates and always exits 0. It is safe on a live machine.
- `install` is idempotent. A second run detects the work is done and skips it.
- `uninstall` reverses what install did. Where reversal would break the host —
  a kernel upgrade, a display driver — say so with `fm_warn` and leave it.
- Anything security-sensitive (sudo rules, keys, passwordless access) prompts
  through `fm_confirm`, which auto-declines under `NONINTERACTIVE=1`.
- Pin versions where a version mismatch breaks a runtime. The NVIDIA container
  toolkit packages, for instance, must move in lockstep.

## Verbs

A script under `scripts/run/` is a person-typed verb and must be declared in
`fm.json`. Anything called only by another script belongs elsewhere. CI fails on
an undeclared verb.

## Before Committing

```bash
shellcheck install.sh run.sh lib.sh scripts/manifest.sh scripts/*/*.sh
FM_SELFTEST=1 bash install.sh
```

The self-test proves every manifest entry resolves to a real step file and that
a dry run walks both roles.
