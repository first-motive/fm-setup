# Contributing

Thanks for contributing.

## Workflow

<!-- fm-render:begin contributing-workflow sha256:0b338cf09d4d1b502e22336f5422ce7326b73d01761b04fd581159748aea6bb4 — rendered by the First Motive render plane — edit the upstream source, not this file -->
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

Coding agents follow the same path and merge their own PRs once checks are
green. `gh pr merge --admin` is allowed when a required review is the only
blocker; it is never used to get past a failing check.
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
4. If the step enables a systemd unit, name it in an `FM_UNITS=(…)` array in the
   step file. The drift audit reads that array to tell an enabled unit somebody
   chose from one nobody did.

### Packages Go Through The Ledger

A step never calls `apt-get` directly:

```bash
fm_apt_install <step-id> <pkg>…    # install, and record what actually appeared
fm_apt_uninstall <step-id>         # remove only what this step's ledger holds
```

The step id is the same string as the manifest id, in both calls. A mismatch
means an uninstall silently removes nothing.

`fm_apt_install` records the difference the install made — the manual apt set
before and after — into `/var/lib/fm-setup/pkgs/<step>`. `fm_apt_uninstall`
simulates the removal first and refuses, naming the extras, if it would reach a
package outside that file. That refusal is the point: `apt-get remove` on a
step's declared list takes every reverse-dependent with it, which is how
removing the container toolkit used to take Docker.

Never `apt-get autoremove` and never `purge` from an uninstall. Both reach past
the step by design.

Two cases cannot go through the helper, and both record explicitly with
`fm_ledger_record <step-id> <pkg>…`: a pinned `name=version` install, whose
presence check the helper cannot read, and a vendor installer that adds its own
repo. Both are commented where they appear.

### One-Off Packages

A package needed now, before anyone knows whether it is permanent:

```bash
fm pkg add ffmpeg     # installed and recorded against the adhoc ledger
fm pkg list           # what is waiting to be promoted to a step
```

It is not an escape from the rule — it is the rule's cheap path. The package is
accounted for immediately, and drift stops reporting it. A package still there
next month belongs in a step.

### Drift

`./install.sh --check` ends with a drift report: manually installed packages in
neither the baseline nor any ledger, units enabled since the baseline that no
step declares, and uncommitted changes under `/etc`. It reports and never fixes
— the repair is a step, or a removal, and both are decisions a person makes.

Both baselines are captured once, by the system-update step, before anything
else has run. They are what a machine arrived with: about sixty packages and a
hundred enabled units nobody chose. Without them every one of those reads as
drift, and a report that long is one nobody reads.

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

Run these checks before opening a PR:

```bash
shellcheck install.sh run.sh lib.sh scripts/manifest.sh scripts/*/*.sh templates/*.sh
FM_SELFTEST=1 bash install.sh
./scripts/dev/test-ledger.sh
./scripts/dev/test-ssh-first-read.sh
./scripts/dev/test-supply-chain.sh
```

Two pins in `scripts/manifest.sh` are maintained by hand and go stale when
upstream rotates: `FM_NVIDIA_KEY_FPR`, the fingerprint of the key signing the
container toolkit repo, and `FM_TAILSCALE_INSTALLER_SHA256`, the checksum of the
installer script Tailscale serves at one unversioned URL. A provision that stops
on either prints the command to re-derive it. Read what changed before updating
the constant — that is the whole point of the check.

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --show-keys --with-colons | awk -F: '/^fpr:/ { print $10; exit }'
curl -fsSL https://tailscale.com/install.sh | sha256sum
```

## Onboarding

New here? The [First Motive org profile](https://github.com/first-motive#get-started)
has the one-curl setup and the `fm update` sync habit.
