# Contributing

Thanks for contributing. This repo uses an owner-free-on-main model: the owner
pushes to `main` directly, everyone else works on a branch and opens a pull
request for the owner to merge.

## Workflow

```text
owner:   push main
others:  branch -> PR -> owner merges
```

The merge-to-main rules apply to the owner only. If you are not the owner, you
branch and open a PR — you do not merge.

## The Rule

No system-level change outside a step in this repo. A package, a sysctl, a udev
rule, a user, or a systemd unit belongs in `scripts/steps/` and in the manifest,
not in a terminal on the host. A prose description of a machine drifts; a script
that provisions one cannot.

## Adding A Step

1. Write `scripts/steps/<NN>-<name>.sh` — strict mode, source `lib.sh` and
   `scripts/manifest.sh`, define `do_check` / `do_install` / `do_uninstall`, and
   end with `fm_dispatch "$@"`.
2. Register it in the role arrays in `scripts/manifest.sh` as `id|file|default`.
3. Confirm each mode holds its contract: `check` never mutates and exits 0,
   `install` is idempotent, `uninstall` reverses what it can and warns about
   what it cannot.

A script under `scripts/run/` is a person-typed verb and must be declared in
`fm.json` in the same change. CI fails on an undeclared verb.

## Branch Naming

Name branches `prefix/short-phrase`, where the prefix matches the commit prefix
list below and the phrase is a kebab-case summary.

```text
feat/workstation-role
fix/empty-manifest-crash
docs/step-contract
```

- Lowercase, hyphen-separated.
- No `:` or spaces (invalid in git refs).
- Short — the branch name is a label, not a description.

## Commit Format

Commits are subject-line-only: `prefix: phrase`. Use a lowercase imperative
phrase, no trailing period, no body.

| Prefix     | Use for                                              | Example                          |
| ---------- | --------------------------------------------------- | -------------------------------- |
| `init`     | First commit of a repo (bootstrap only, never after) | `init: scaffold project`         |
| `feat`     | New behavior or content                             | `feat: add workstation role`     |
| `fix`      | Bug fix or content correction                       | `fix: handle empty manifest`     |
| `docs`     | Documentation only                                  | `docs: document step contract`   |
| `refactor` | Behavior-preserving restructure                     | `refactor: extract step gating`  |
| `chore`    | Tooling, deps, housekeeping                         | `chore: bump toolkit pin`        |

Pick the narrowest prefix that fits. If a change spans two, split the commit.

## Tests

Run both before opening a PR:

```bash
shellcheck install.sh run.sh lib.sh scripts/manifest.sh scripts/*/*.sh
FM_SELFTEST=1 bash install.sh
```

## Onboarding

New here? The [First Motive org profile](https://github.com/first-motive#get-started)
has the one-curl setup and the `fm update` sync habit.
