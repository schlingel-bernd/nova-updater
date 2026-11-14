# Writing an app

A nova app is a git repository with two files in its root:

- [`nova.manifest`](https://github.com/schlingel-bernd/nova-updater/blob/main/templates/nova.manifest) — what the app is;
- [`install.sh`](https://github.com/schlingel-bernd/nova-updater/blob/main/templates/install.sh) — how to install, update and uninstall it.

Copy both templates and edit them. Then add the repository to a catalog
([Catalogs](catalogs.md)), or try it locally with `nova add <url>`.

## `nova.manifest`

```ini
NAME=my-tool
DESCRIPTION=Short description of my tool
VERSION=0.1.0
COMPONENTS=cli
CATEGORY=System
SCOPES=user
INSTALLER=install.sh
```

One `KEY=value` per line. A value runs to the end of the line, so put
comments on their own line, never after a value.

| Key | Meaning |
|---|---|
| `NAME` | What users type in `nova install <name>`. Letters, digits, `.`, `_`, `-`; must start with a letter or digit. |
| `DESCRIPTION` | One line. Shown in listings; `nova search` matches it. |
| `VERSION` | Your version. The release tag must be `v<VERSION>`. |
| `AUTHOR`, `HOMEPAGE`, `LICENSE` | Shown in the detail view. `HOMEPAGE` is clickable only if it is `https://`. |
| `COMPONENTS` | What the app installs, e.g. `cli gui daemon service gnome-extension config module`. Shown in listings and used to pick icons. |
| `CATEGORY` | One word for grouping: `Security`, `Network`, `Media`, `Development`, `Office`, `Files`, `Desktop`, `System`, or your own. |
| `TAGS` | Extra search words. |
| `SCOPES` | `user`, `system`, or `user system`. Default `user`. |
| `ROOT_REASON` | One sentence, shown before nova asks for a password. Write one whenever `SCOPES` includes `system`. |
| `DEPENDS` | Commands your installer needs (see below). |
| `ICON` | Repo-relative SVG or PNG, at most 1 MiB. |
| `SCREENSHOTS` | Repo-relative PNG, JPEG or WebP files, at most 4 MiB and 4096 px a side each. |
| `ABOUT` | Repo-relative file shown as the long description. Default `README.md`; the first 64 KiB are shown. |
| `INSTALLER` | The installer, relative to the repository root. Default `install.sh`. Must be a regular file inside the repository (no `..`, no symlink). |

## `install.sh`

nova runs your installer from the repository root:

```bash
./install.sh install      # or update, or uninstall
```

once **per scope** your manifest declares, with these variables:

| Variable | Value |
|---|---|
| `NOVA_SCOPE` | `user` or `system` |
| `NOVA_PREFIX` | `~/.local` (user) or `/usr/local` (system) |
| `NOVA_APP_DIR` | absolute path of the clone |
| `NOVA_ACTION` | `install`, `update` or `uninstall` (same as `$1`) |
| `NOVA_GUI` | `1` or `0` — see below |
| `NOVA_PURGE` | `1` when the user asked for `--purge` (uninstall only) |
| `PATH` | starts with `$NOVA_PREFIX/bin`, so you can call what you just installed by name. For the system scope it is fixed: `/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin`. |

Rules of thumb:

- **Two scopes, two runs.** With `SCOPES=user system`, nova runs the script
  once as you with `NOVA_SCOPE=user` and once as root with
  `NOVA_SCOPE=system`. Do only that half each time. nova-killswitch's
  installer is a worked example.
- **Desktop parts.** When `NOVA_GUI=0`, skip your GUI: the machine has no
  GTK 4 / libadwaita 1.5+, or the user asked for `--cli-only`. nova does not
  skip anything for you.
- **Purge.** On `uninstall --purge` your script is also called as
  `./install.sh uninstall --purge`. Without `--purge`, leave the user's
  settings and data alone.
- **Fail loudly.** A non-zero exit means "not installed": nova keeps the
  previous version recorded and tries again next time.
- **Root.** For the system scope your script already runs as root; don't call
  `sudo`.
- **Missing packages.** `nova pkg-hint <need>` prints the install command
  for the user's distribution (`git`, `ssh-keygen`, `gui`, `gnu-tools`, or
  any package name).

## Dependencies

`DEPENDS` lists commands your installer needs, e.g. `DEPENDS=podman git`.
nova checks each with `command -v`, in the `PATH` your installer will get,
and says what is missing before it runs anything.

When a missing word is the name of a **nova app**, nova installs that app
first. The nova-proxy plugins say `DEPENDS=nova-proxy podman`, so
`nova install nova-plugin-tor` brings nova-proxy along. `--dry-run`,
`nova info` and Nova Apps show which apps an install would bring.

This only happens where it is safe:

- **From your own catalog, or a list on the user's machine.** Another
  catalog cannot claim a name your app depends on.
- **In the same scope.** A user app never pulls in a root install, and root
  never installs a user app. nova prints the `nova install` command instead.
- **At install time.** An update does not add a dependency that a new version
  started to declare, and nothing removes a dependency later.

## Icons and screenshots

Ship your icon in your repository and name it in `ICON=`. Nova Apps draws it
from the clone; nothing is downloaded. Without one, the app gets a themed
icon for its category.

Nova Network apps take their icons from
[nova-icons](https://github.com/schlingel-bernd/nova-icons): copy
`svg/classic/<app-id>.svg` into the repository and point `ICON=` at it. If the
app installs a desktop entry, use the same file there too.

## Releases

nova installs your newest **version tag**:

- a tag counts as a release if it matches `^v?[0-9]+(\.[0-9]+){0,3}$` —
  `v1`, `v1.2`, `1.2.3`, `v1.2.3.4`;
- `v2.0.0-rc1`, `nightly` or `wip` never count, so a pre-release never
  overtakes a release. Users can still ask for one with `ref=v2.0.0-rc1`;
- a repository without any version tag is followed at its default branch.

**Sign your release tags.** Root updates an app's root part without a password
only to tags signed by the key it pinned. Two commands, explained in
[Signed releases](signing.md):

```bash
nova-release setup --key ~/.ssh/my-tool-release    # once
nova-release tag --push                            # per release
```

## Check your app

```bash
nova add https://github.com/you/my-tool.git
nova info my-tool
nova info --installer my-tool
nova install my-tool --dry-run
nova install my-tool
```
