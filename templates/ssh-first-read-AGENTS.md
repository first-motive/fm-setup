# First Motive Workstation - SSH First Read

Managed by fm-setup. Edit the source in the fm-setup repository. Managed copies
are replaced when `fm setup-onboard` runs again.

Read this before you inspect or change the host.

## Establish Live State

1. Run `id -un; hostname` to confirm the account and host.
2. Run `fm machine show --json` to read the machine identity card.
3. Run `fm root --json`, `fm list --json`, `fm commands --json`,
   `fm status --json`, and `fm doctor --json` for the live workspace.

Continue only when the account, machine role, workspace, and repository state
are clear.

## Work Boundaries

- `~/fm` is the personal workspace for branches, tools, and experiments.
- The machine card names the shared workspace used by services.
- `/data` is team-readable storage for recordings, releases, and run evidence.
- Persistent host changes belong in a committed `fm-setup` step.
- Use the privileged maintenance account only for an approved shared change.

## Route The Work

- Read the nearest repository `AGENTS.md`, `CONTEXT.md`, and task documents.
- Use the installed `first-motive` skill to choose the owning repository.
- Use `fm-machine` for host state and `fm-bootstrap` for setup entry points.
- Read `~/CLAUDE.md` for the full machine rule and recovery commands.

Treat the live host and repository checks as current evidence. Keep recorded
architecture separate from installed and runtime proof.
