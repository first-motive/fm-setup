# CLAUDE.md

Managed by fm-setup. Edit it in the fm-setup repo, not here — this copy is
replaced on the next provisioning run.

## The Rule On This Machine

**No system-level change outside a step in fm-setup.**

That means no `apt install`, no `pip install` into the system Python, no
`systemctl enable`, no edit under `/etc`, no new user or group, and no sysctl
change applied by hand. If the work needs one, add a step to fm-setup, commit
it, and run it:

```bash
cd ~/.first-motive/fm-setup
./install.sh --check          # what state is this machine in?
./install.sh --only <step>    # apply one step
```

The rule binds people and AI agents equally. An agent that installs a package to
unblock itself has made this machine unreproducible, and the next person to
rebuild it will not know what was done or why.

One account on this machine has sudo: the administrator who provisioned it. If a
command needs root and you are not that account, it does not belong in your
session — it belongs in an fm-setup step.

## What Belongs Where

| layer | repo | examples |
| --- | --- | --- |
| machine | `fm-setup` | drivers, docker, ROS distro, users, sysctl, udev |
| workspace | `fm_ros2` | colcon workspace, packages, launch, services |
| your work | your own checkout | anything under your home directory |

Your home directory is yours. Virtual environments, checkouts, scratch data, and
per-user tooling need no ceremony — the rule is about state shared by everyone
on the box.

## Shared Data

`/data` is group-owned by `fm` and setgid, so a file written there stays
readable by the team. Put recordings, dataset releases, and run evidence in it.
Do not keep them in a home directory, where nobody else can reach them and a
user removal takes them with it.

## Before You Change Anything Shared

1. Check whether a step already covers it: `./install.sh --list`.
2. If not, write one — see `CONTRIBUTING.md` in fm-setup.
3. Commit, then run it. The commit is the record of what this machine is.
