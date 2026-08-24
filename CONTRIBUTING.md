# Contributing

Thanks for contributing.

## Workflow

<!-- fm-render:begin contributing-workflow sha256:4a3ac9a4c1cbb5995c5a0e4d5b6beb580f50090c14bc5170cd21c84ee4635dd0 — rendered by the First Motive render plane — edit the upstream source, not this file -->
Work reaches `main` by merging a pull request with green checks — never by
pushing to it. This holds for everyone, the owner included. The rendered
`.fm/hooks/pre-push` refuses a direct push, a tripwire workflow files an issue
against one that arrives from an unguarded clone, and ADR 0001 in
`first-motive/.github` records the decision.

```text
everyone:  branch -> PR -> green checks -> merge
```

`FM_ALLOW_MAIN_PUSH=1` is the loud escape for an emergency; a push that takes
it is still reported by the tripwire. The repo owner is set in
[`.github/CODEOWNERS`](.github/CODEOWNERS).
<!-- fm-render:end contributing-workflow -->

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
