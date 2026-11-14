# nova-updater documentation

nova-updater installs open-source apps from **git catalogs** and keeps them up
to date. Its command is `nova`; its desktop app is **Nova Apps** (`nova-gui`).

An app is a git repository with a `nova.manifest` file and an `install.sh`
script. A catalog is a git repository that lists apps. nova clones an app,
checks out its newest release tag, runs its installer, and updates it in the
background. It updates itself the same way.

## Pages

| Page | For | What it covers |
|---|---|---|
| [Install](install.md) | everyone | supported systems, the two install modes, packages per distro, uninstalling |
| [Using nova](usage.md) | everyone | every command, Nova Apps, background updates, settings |
| [Catalogs](catalogs.md) | everyone | adding catalogs, `apps.list`, pins and overrides |
| [Security](security.md) | everyone | what runs as root, when you type a password, what nova checks |
| [Writing an app](app-authors.md) | app authors | `nova.manifest`, `install.sh`, dependencies, icons, releases |
| [Signed releases](signing.md) | app authors, maintainers | `nova-release`, keys, changing keys |
| [Development](development.md) | contributors | tests, CI, releasing nova-updater itself |

The source of these pages is the `docs/` folder of
[schlingel-bernd/nova-updater](https://github.com/schlingel-bernd/nova-updater).
The pages link to each other with relative links, so the folder can be built
on its own or copied into a larger site.
