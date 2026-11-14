# nova-updater

Install and update open-source apps from **git catalogs** — on Fedora
Silverblue and Bluefin, Fedora, Debian, Ubuntu, Arch, openSUSE and Alpine.

An app is a git repository with a `nova.manifest` and an `install.sh`. A
catalog is a git repository that lists apps. `nova` clones an app, checks out
its newest release, runs its installer, and keeps it updated in the
background — itself included. No accounts, no store, no vendor.

- **`nova`** — the command-line tool
- **Nova Apps** (`nova-gui`) — the desktop app: browse, search, install, and
  read an app's installer before it runs
- **Root parts done carefully** — apps that need root (a firewall daemon, say)
  are installed by a root-owned copy of nova, only from sources root lists,
  and updated without a password only to releases signed by a key root pinned

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/schlingel-bernd/nova-updater/main/get-nova.sh | bash
```

This sets up the user part and the root part, with one password prompt. For
your home directory only — no root, no password, ever — add `-s -- --minimal`:

```bash
curl -fsSL https://raw.githubusercontent.com/schlingel-bernd/nova-updater/main/get-nova.sh | bash -s -- --minimal
```

| Tested on every push | |
|---|---|
| Fedora Silverblue, Bluefin, Fedora, Debian 13, Ubuntu 24.04, Arch, openSUSE Tumbleweed | everything |
| Alpine | everything, with the GNU tools: `doas apk add bash git coreutils util-linux findutils sed grep openssh-keygen` |
| Debian 12, Ubuntu 22.04 (tested, not on every push) | `nova` and command-line apps; their libadwaita is too old for the GUIs |

Packages per distribution, manual mode, uninstalling and WSL:
[docs/install.md](docs/install.md).

## Use

```bash
nova list                    # every app you can install
nova install <app>           # install it
nova update                  # update everything (the background timer does this too)
nova info --installer <app>  # read the script before it runs
nova doctor                  # when something is wrong
nova-gui                     # the desktop app
```

All commands: [docs/usage.md](docs/usage.md).

## Documentation

| | |
|---|---|
| [Install](docs/install.md) | supported systems, packages, install modes, uninstall |
| [Using nova](docs/usage.md) | commands, Nova Apps, background updates, settings, scripting |
| [Catalogs](docs/catalogs.md) | adding catalogs, `apps.list`, pins and overrides |
| [Security](docs/security.md) | what runs as root, when you type a password, signed releases |
| [Writing an app](docs/app-authors.md) | `nova.manifest`, `install.sh`, dependencies, icons, releases |
| [Signed releases](docs/signing.md) | `nova-release`: signing your app's releases in two commands |
| [Development](docs/development.md) | tests, CI, releasing nova-updater |

Release notes: [CHANGELOG.md](CHANGELOG.md).

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
