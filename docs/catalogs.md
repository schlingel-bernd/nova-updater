# Catalogs

A catalog is a git repository with an `apps.list` file: one app repository
per line. The [Nova Network catalog](https://github.com/schlingel-bernd/nova-catalog)
is registered when you install nova.

## Managing catalogs

```bash
nova catalog add https://github.com/you/your-catalog.git
nova catalog list
nova catalog remove https://github.com/you/your-catalog.git
```

Adding a catalog means trusting it: installing one of its apps runs that app's
`install.sh`, and as root if the app has a root part. Catalogs are curated by
whoever maintains them; they are not audited. Add catalogs the way you would
add a package repository.

`nova catalog add --system <url>` registers a catalog for root as well (with
your password). Root installs only apps from its own lists and catalogs; see
[Security](security.md).

## `apps.list`

One git URL per line, optionally followed by options. Lines starting with `#`
are comments.

```
https://github.com/schlingel-bernd/nova-killswitch.git
https://github.com/schlingel-bernd/syncman.git ref=v0.4.0
https://github.com/you/tool.git branch=main
https://github.com/you/dual-app.git scope=user
```

| Option | Effect |
|---|---|
| `ref=<tag>` | Pin to this tag (or branch name). `nova pin` writes this. |
| `branch=<name>` | Follow a branch instead of release tags. |
| `scope=user` / `scope=system` | Install only that part of an app on this machine. This is a filter: the app's manifest still decides which parts exist. |

Only `https://` URLs and local paths are accepted; `http://` is refused. The
repository name (the last part of the URL, without `.git`) must look like a
name: letters, digits, `.`, `_`, `-`, not starting with `.`, `_` or `-`.

### Which entry wins

nova reads, in this order:

1. your own list, `~/.config/nova-updater/apps.list` (`nova add <url>`);
2. root's list, `/etc/nova-updater/apps.list` (`nova add --system <url>`);
3. the catalogs.

The first entry for an app wins, so your own list can pin or replace any
catalog entry. Two different repositories with the same name: the first one
is used, and nova warns about the other.

For root apps, two extra rules apply:

- root ignores `ref=` and `branch=` on **catalog** lines — a catalog chooses
  which repository, never which version. Root's own list can still pin.
- root follows a local path only if it and every directory above it are owned
  by root and not writable by others.

## `catalog.manifest`

A catalog can describe itself in a `catalog.manifest`:

```ini
NAME=nova-catalog
DESCRIPTION=The Nova Network app catalog — open source, no accounts, no lock-in
```

nova shows `NAME` and `DESCRIPTION` in `nova catalog list` and in Nova Apps.

## Running your own catalog

1. Create a git repository with an `apps.list` (and a `catalog.manifest`).
2. Add one line per app. Each app needs a `nova.manifest` and an
   `install.sh` — see [Writing an app](app-authors.md).
3. Push it, and tell people to run `nova catalog add <url>`.

List one line per app, even if the app has a user part and a root part: the
app's manifest declares its parts.
