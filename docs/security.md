# Security

Installing an app runs that app's `install.sh` — as root, if the app has a
root part. nova cannot make that safe; nothing can. What it does is make sure
the code that runs is the code you chose, from the source you chose, and that
you can read it first.

## When you type a password

| | Needs root | Asks for your password |
|---|---|---|
| Anything in the user part | no | no |
| **Installing** an app with a root part | yes | yes |
| **Uninstalling** it | yes | yes |
| **Updating** it | yes | **no**, if the release is signed by the key root pinned for the app (auto mode); otherwise yes |

Before any password prompt, nova shows, for each root app:

- why it needs root (the manifest's `ROOT_REASON`);
- its repository URL and where that entry came from (your list, root's list,
  or which catalog);
- which other apps it would install as root as dependencies.

Nova Apps shows the same in its confirmation dialog. In manual mode
(`--with-system=manual`), every change to a root app asks for your password.

## What root will install

Root installs and updates an app only from a source **it lists itself**:
`/etc/nova-updater/apps.list` and the catalogs registered for root. The Nova
Network catalog is registered for root during the install.

An app with a root part from anywhere else — your own list, or a catalog only
you added — installs its user part and tells you the command that registers
the source for root:

```bash
nova add --system https://github.com/you/app.git
```

That asks for your password and names the URL. Nova Apps offers it as
**Register and Install**.

Root also refuses:

- `http://` URLs (only `https://` and local paths);
- a local repository that is not owned by root all the way up — whoever can
  write it would decide what root runs;
- `ref=` and `branch=` on catalog lines (a catalog cannot move root to an old
  release or a branch);
- a release **older** than the one installed, unless root's own list pins it
  (`nova pin --system <app> <tag>`);
- an installer outside the app's clone (`INSTALLER=../…`, or a symlink);
- any `NOVA_*` setting from its environment, except `NOVA_UNATTENDED`.

Root's git checks every object it downloads and runs no git hooks.

## Signed releases

Updates without a password run new code as root that nobody looked at. So they
only happen for releases root can check.

- **Pinning.** Root keeps one SSH signing key per app, in
  `/etc/nova-updater/signers/<app>`. It is pinned when you install the app
  with your password, from the key that signed that release. (On machines from
  before nova 2.4, it is pinned from the release already installed.)
- **Signed by that key:** updates without a password.
- **Unsigned, a branch, or no release tags:** updates only with your password,
  and nova says it could not verify the release.
- **Signed by another key, or unsigned after earlier releases were signed:**
  refused, with or without a password.

If an app's maintainer really changed their key:

```bash
nova trust --system <app>     # forget the pinned key
nova update <app>             # with your password: pins the key of the new release
```

nova-updater itself is checked the same way, and more: `get-nova.sh` and the
root setup refuse a nova-updater release that is not signed by its release
key, before they install anything. Then root pins that key.

Checking signatures needs `ssh-keygen`; `nova doctor` tells you when it is
missing. How app authors sign their releases is in
[Signed releases](signing.md).

What a signature does **not** do: it proves a release was made by someone
holding the key. It does not prove the release is harmless — a maintainer can
sign something bad, and a stolen key signs as well as the real one. Reading the
installer and the diff is what lets you see a change:

```bash
nova info --installer <app>
nova diff <app>
nova pin <app> <tag>
```

## The passwordless helper

In auto mode, updates of root apps go through one program,
`/usr/local/libexec/nova-system-update`. A polkit rule lets members of the
admin group run exactly that program without a password: `wheel` on Fedora,
Arch, openSUSE and Alpine; `sudo` on Debian and Ubuntu. The rule needs an
**active** session; a VM or remote desktop session can report as inactive.

The helper takes app names, never options or paths. Every name must already be
an app root knows. Names are passed after `--`, and the helper asks nova for
signed releases only. The worst a caller can ask for is an update of an app
the administrator already chose, to a release signed by its pinned key.

Where polkit is missing, or older than 0.106 (Ubuntu 22.04), nova sets up
manual mode and says why.

## Why nova has two copies

**Root must never run a file you can write.** Otherwise anything running as
you could change it and become root on the next update. nova lives in
`~/.local/bin`, which you own — so the root part needs its own root-owned copy
in `/usr/local/bin`, with its own clones in `/var/lib/nova-updater/repos`.

Other tools solve the same problem the same way:

| | Install without root | Install as root | What runs as root |
|---|---|---|---|
| dnf, apt | — | always | `/usr/bin/dnf`, installed by the distribution |
| flatpak | `--user`, in `~/.local/share/flatpak` | `--system`, in `/var/lib/flatpak` | `flatpak-system-helper`, authorised by polkit |
| brew | in a directory you own | — (refuses to run as root) | nothing |
| nova | user part, in `~/.local` | root part, in `/var/lib` and `/usr/local` | the root-owned copy of nova, through the polkit helper or `sudo` |

nova's shape is flatpak's. The root-owned copy is nova's
`flatpak-system-helper`.

The cost is that two copies can drift apart. `nova version` shows both,
`nova doctor` warns, and the background updates keep the root copy current.

### Setting up the root part

The first install of the root part is the one time a script from your home
directory runs as root, because no root-owned copy exists yet to do it. Even
then, that script only:

1. clones nova-updater as root into `/var/lib/nova-updater/repos/nova-updater`,
2. checks out the newest release and checks its signature,
3. hands over to the `install.sh` in that clone.

The root-owned nova, the helper and the polkit rule come from root's own
clone. Root updates itself from
`https://github.com/schlingel-bernd/nova-updater.git`, never from your copy or its
`origin`.

A fork can be used instead: put its `https://` URL in a root-owned
`/etc/nova-updater/self-url`, and its release keys in a root-owned
`/etc/nova-updater/self-signers`, before setting up the root part.

## Reporting a problem

Open an issue on
[schlingel-bernd/nova-updater](https://github.com/schlingel-bernd/nova-updater/issues).
The audits behind the current design are
[FIXPLAN.md](https://github.com/schlingel-bernd/nova-updater/blob/main/FIXPLAN.md)
(1.3) and
[FIXPLAN-2.4.md](https://github.com/schlingel-bernd/nova-updater/blob/main/FIXPLAN-2.4.md).
