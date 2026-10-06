# nova-updater

Install and update open-source apps from **git catalogs**, on Fedora Silverblue /
Bluefin and other ostree systems. An app is just a git repo with a
`nova.manifest` and an `install.sh`; `nova` clones it, checks out its latest
release tag, runs its installer, and keeps it updated in the background —
including itself.

No accounts, no store, no vendor. A catalog is a repo you can read, fork and
send a pull request to.

- **`nova`** — the CLI (needs `git`, coreutils, `util-linux` for `flock`, and
  `awk`; all are in the Silverblue/Bluefin base image)
- **`nova-gui`** — the desktop app, **Nova Apps** in your app grid: search,
  filter and browse the catalogs, with a detail view per app
- **releases are git tags** — apps follow their latest *version* tag, meaning
  one shaped like `v1.2.3`. Pre-releases and scratch tags are never picked up
  by accident; untagged repos follow HEAD
- **catalogs** — add as many as you like, managed through ordinary git
- **systemd timers** — background updates for user apps and, opt-in, system apps

## Install

**Recommended** — the user scope plus the root-owned system scope, one
password prompt:

```bash
curl -fsSL https://raw.githubusercontent.com/schlingel-bernd/nova-updater/main/get-nova.sh | bash -s -- --with-system
```

**Minimal** — 100 % user-level: `~/.local`, no root, no password, ever:

```bash
curl -fsSL https://raw.githubusercontent.com/schlingel-bernd/nova-updater/main/get-nova.sh | bash
```

Anything that is only files in your home — the CLI tools, ensconce — is
complete on the minimal install. An app with a **root half** (nova-killswitch:
a root firewall daemon plus a desktop part) needs the system scope; if it is
not there yet, `nova install nova-killswitch` sets it up on the spot with one
password. Prefer to type a password for *every* system change instead of
granting passwordless updates? `--with-system=manual` installs the same thing
without the polkit rule; one command switches either way.

Then register a catalog:

```bash
nova catalog add https://github.com/schlingel-bernd/nova-catalog.git
nova list
```

## Use

```bash
nova list [--check]        # everything this machine knows about
nova search vpn            # find an app across every registered catalog
nova info nova-killswitch  # what it installs, and whether it needs root
nova install <app>         # a name, or an explicit --all
nova update                # everything with a new release
nova uninstall <app>       # --purge also drops its config
nova-gui                   # the desktop app ("Nova Apps")
```

Before you run something, and when something goes wrong:

```bash
nova info --installer <app> # print the script an install would run
nova diff <app>             # what an update would change, installer included
nova pin <app> v1.2.0       # stay there; nova unpin <app> to follow releases
nova install <app> --dry-run # scope, URL, ref, installer path — and do nothing
nova doctor                 # stale locks, version skew, bad list files, timers
```

## One app, one line — even when it needs root

Some apps are only a binary in `~/.local/bin`. Others — a VPN kill switch, say —
are a root daemon **and** a desktop app **and** a GNOME extension. Those halves
install in different places with different privileges, and that distinction is
real: **root must never execute a file the user can write**, so system apps are
cloned as root into `/var/lib` and user apps into `~/.local`.

What you should not have to care about is *expressing* it. The app declares it:

```ini
COMPONENTS=daemon cli gui gnome-extension
SCOPES=user system
ROOT_REASON=installs a root firewall daemon, its D-Bus policy and two systemd units
```

A catalog lists that app **once**. `nova` reads the manifest, installs each half
correctly, and shows one row:

```
NAME                 SCOPES       COMPONENTS             VERSION   STATUS
nova-killswitch      user+system* daemon cli gui gnome-… 0.1.0     installed
* needs root for part of the install
```

Before asking for your password it tells you what the password is *for* — that
is what `ROOT_REASON` is. `nova info <app>` shows it any time.

`scope=` on a catalog line still exists, but only as a **filter**: "on this
machine, install just the user half". It is not a declaration.

## The app convention

Put a [`nova.manifest`](templates/nova.manifest) and an
[`install.sh`](templates/install.sh) in your repo root:

```ini
NAME=my-tool
DESCRIPTION=Short description
# COMPONENTS: cli gui daemon service gnome-extension config …
COMPONENTS=cli
# SCOPES: user, system, or both
SCOPES=user
VERSION=0.1.0
HOMEPAGE=https://…
LICENSE=GPL-3.0-or-later
INSTALLER=install.sh
```

A value runs to the end of the line — comments go on their own line, never
after a value. A description may legitimately contain a `#`, so nova cannot
strip trailing comments. Copied with `COMPONENTS=cli  # … gui …` on one line,
the comment became part of the value and the app was treated as having a GUI.

`nova` runs your installer once **per declared scope**, with:

| env var | value |
|---|---|
| `NOVA_SCOPE` | `user` or `system` |
| `NOVA_PREFIX` | `~/.local` or `/usr/local` |
| `NOVA_APP_DIR` | absolute path of the clone |
| `NOVA_ACTION` | `install` \| `update` \| `uninstall` |
| `NOVA_GUI` | `0` on a headless machine, or with `--cli-only` |
| `NOVA_PURGE` | `1` when the user asked for `--purge` (uninstall only) |
| `PATH` | begins with `$NOVA_PREFIX/bin`, so your installer can call what it just installed by name, whichever way it was reached — a terminal, the GUI, or the passwordless update. For the system scope it is fixed (`/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin`), not inherited |

On a purging uninstall your script is also called as `./install.sh uninstall
--purge`, so you can branch on either. Without `--purge`, leave the user's
configuration where it is.

A dual-scope installer branches on `NOVA_SCOPE` and does only that half each
time. `COMPONENTS` containing `gui` is what makes `nova` skip desktop parts
where there is no GTK stack.

### Depending on another app

`DEPENDS` lists commands your installer needs — `DEPENDS=podman git`. nova
checks each one with `command -v` (in the `PATH` your installer will get) and
says what is missing before it runs anything. When a missing word is the name
of a **nova app**, nova installs that app first: nova-fox's provider plugins
say `DEPENDS=nova-fox podman`, so `nova install nova-plugin-tor` brings
nova-fox along. `nova install … --dry-run`, `nova info` and the GUI all show
which apps an install would bring.

Only where it is safe to:

- **from your own catalog, or a list on this machine.** A dependency is looked
  up only in a list that also names your app, or in one the user keeps
  locally. Otherwise one catalog could claim a common name another catalog's
  app depends on, and get its installer run without anyone choosing it.
- **in the same scope.** A user-scope app never pulls in a system install by
  itself (that needs a password the user did not expect to give), and root
  never installs a user app. nova names the `nova install` command instead.
- **at install time.** An update does not add a dependency that a new version
  started declaring; nothing removes a dependency when its last user goes.

Release by tagging: `git tag v1.3.0 && git push --tags`.

A tag counts as a release only if it matches `^v?[0-9]+(\.[0-9]+){0,3}$` —
`v1`, `v1.2`, `1.2.3` and `v1.2.3.4` all qualify. `v2.0.0-rc1`, `nightly` and
`wip-test` do not, so a pre-release never overtakes the release it precedes.
Someone who wants one can ask for it by name with `ref=v2.0.0-rc1` on their
`apps.list` line. A repo with no version tag follows its default branch.

## Catalogs

A catalog is a git repo with an `apps.list` and, optionally, a
`catalog.manifest` describing itself:

```ini
NAME=nova-catalog
DESCRIPTION=The Nova Network app catalog — open source, no accounts, no lock-in
HOMEPAGE=https://github.com/schlingel-bernd/nova-catalog
MAINTAINER=schlingel-bernd
```

```bash
nova catalog add https://github.com/you/your-catalog.git
nova catalog list
nova catalog remove <url>
```

Local `apps.list` entries always beat catalog entries, so a machine can pin or
override anything.

### Trust

Installing an app **runs that repo's `install.sh`**, and an app declaring the
system scope runs it **as root**. `nova` says so when you add a catalog, and
`nova info` tells you what an app is before you install it. Catalogs are curated
by whoever maintains them — they are not audited. Add catalogs you trust, the
same way you would add a package repository.

## Choosing what you run

Installing an app runs that repo's `install.sh`, as root when it declares the
system scope. None of this changes that — it exists to make the choice
deliberate rather than automatic.

Shipped in 1.3.0:

- [x] **`nova pin <app> <tag>` / `nova unpin`** — the existing `ref=` entry
      option as a first-class command, so code only changes when you say so.
      The cheapest real protection there is.
- [x] **`nova diff <app>`** — what changed between the installed commit and the
      one an update would move you to, *before* updating. For a catalog of
      small tools this is the strong one: a forty-line installer change is
      something you can actually read, so the installer's diff is shown in
      full.
- [x] **`nova info --installer <app>`** — the script that is about to run,
      before the first install.

Still planned:

- [ ] **A hosted registry of trusted catalogs** — `nova catalog browse` listing
      known catalogs with their maintainer, so catalogs can be discovered
      instead of pasted from somewhere. Catalogs stay opt-in either way.
- [ ] **Signature verification** — `signer=<fingerprint>` on a registry entry,
      checked with `git verify-tag` before an installer runs.

A note on that last one, because it is easy to oversell: a signature proves a
tag was made by someone holding a particular key. With a pinned fingerprint
that catches an account takeover, a repo transfer, or a typosquatted URL. It
does **not** catch a maintainer who ships something malicious — that signature
is perfectly valid — nor a stolen key, nor an installer that fetches more code
at install time. Signing narrows *who may publish*; it says nothing about *what
the published thing does*. Pinning and diffs are the ones that let you see the
change.

## Why the split layout

| piece | location | why |
|---|---|---|
| `nova`, `nova-gui`, user apps | `~/.local` | no root, survives an ostree rebase |
| root-owned `nova` copy (opt-in) | `/usr/local/bin` (= writable `/var/usrlocal`) | the **root** update timer must never execute a *user-writable* file, or any process running as you could edit it and become root on the next tick |
| system app repos / config | `/var/lib`, `/etc` | writable on ostree, root-owned |

The immutable `/usr` is never touched. If you never install a system app,
nothing outside your home is ever written.

### Why two copies — and how rpm, apt, flatpak and brew do the same job

Every installer that can touch the system answers one question: **what runs as
root, and who can edit that file?** Line nova up against the others and the
shape stops looking strange.

| | install without root | install as root | the thing that runs as root |
|---|---|---|---|
| **rpm/dnf, apt** | none — everything is system-wide | always | `/usr/bin/dnf`, root-owned because the distro shipped it |
| **flatpak** | `--user` → `~/.local/share/flatpak` | `--system` → `/var/lib/flatpak` | `flatpak-system-helper`, a root daemon that polkit authorises per request |
| **brew** | `/home/linuxbrew/.linuxbrew`, owned by *you*; brew refuses to run as root | none | nothing — a formula that needs a root service tells you to do that part yourself |
| **nova** | user scope → `~/.local` | system scope → `/var/lib` + `/usr/local` | the root-owned copy of nova, reached only through the polkit-gated wrapper or sudo |

So the *shape* is flatpak's: a user installation needing no root, plus an
optional system installation guarded by polkit and a root-owned helper. What
makes nova look odd is only that its user copy lives in `~/.local/bin` — because
nova installs **itself**, from git, with no package. Flatpak's binary is
root-owned because the distro installed it; nova's is yours because *you* did.
And root must never execute a file you can write — anything running as you
could edit it and own root on the next timer tick — so the system scope needs
its own root-owned copy. That second copy *is* nova's `flatpak-system-helper`,
not a duplicate for its own sake.

The two coherent alternatives are the other rows. Be a package —
`rpm-ostree install nova-updater` would give one root-owned `/usr/bin/nova` and
no second copy — at the price of layering on an ostree system, a reboot for
every nova update, and depending on the very thing this exists to avoid. Or be
brew — never touch the system — which is exactly the minimal install above,
and which cannot install a kill switch.

The split has real costs, and nova carries tooling for each: the copies can
drift (`nova version` shows both, `nova doctor` warns, and your timer updates
the root copy like any other system half),
nova manages itself in both scopes at once (each scope follows its own list
entry, so a pin on one half never silently holds or blocks the other), and
the one bootstrap exception — `install --with-system` running a user-writable
script as root once, password-gated — exists because no root-owned copy is
there yet to do it instead.

## Background updates

One timer, yours: `nova-updater.timer` runs `nova update --all` every six
hours as you. User halves it updates directly; system halves — nova's own
root-owned copy included — go through the passwordless helper. There is no
root timer: nothing of nova's runs as root except on behalf of your update.
In `manual` mode the timer leaves system halves for your next interactive
`nova update`, where you type the password.

### Root, and when you are asked for a password

| | needs root | asks for a password |
|---|---|---|
| anything in the user scope | no | no |
| **updating** a system app | yes | **no** — your own update timer does it through one fixed-purpose helper that polkit grants to `wheel` users (with `--with-system=manual`: yes, every time) |
| **installing** a system app | yes | yes |
| **uninstalling** a system app | yes | yes |

A plain `nova install` never touches root: the default install is entirely
`~/.local`, and the system scope only exists if you set it up with
`--with-system`. Only an app that declares `SCOPES=… system` needs it, and
`nova info <app>` tells you why before you are asked.

Passwordless system *updates* go through `/usr/local/libexec/nova-system-update`,
which the polkit rule authorises by exact path. It takes app names but treats
them as a **selection**: every name must look like a name (never an option) and
must already appear in the root-owned `/etc/nova-updater/apps.list` or a
catalog registered for root, and anything else is refused — so the worst a
caller can ask for is an update of an app the administrator already trusts.
With no names it updates every one of them.

The rule requires an **active** session in `wheel`, not a local one: VM and
remote desktop sessions can report as non-local.

## Notes

- `nova check` exits `10` when updates are available (script-friendly).
- `nova list` fetches app metadata the first time so it can show descriptions
  and components; `--no-sync` skips that. `nova list --check` and `nova sync`
  also bring those cached clones up to the release an install would use, so a
  listing describes what you would get rather than what was current when the
  app was first seen.
- Whether an app has an update is decided by comparing the remote against the
  commit recorded in each scope's own marker file, so a system app updated by
  root shows as up to date for the user too.
- `nova install` needs an app name or an explicit `--all`. `nova update` with
  no arguments means everything already installed.
- Concurrent runs are prevented with per-scope lock files. A command waits
  briefly (`NOVA_LOCK_WAIT`, 20s) rather than failing instantly, since the
  usual collision is the background timer; if it still cannot get the lock it
  names the host and pid holding it. Every network git call is bounded by
  `NOVA_NET_TIMEOUT` (180s) so a stalled fetch cannot hold the lock forever.
- The GUI is a thin layer over `nova list --porcelain` — the CLI is the single
  source of truth. It shows which scopes an app is actually installed in, can
  pin and unpin, and shows an app's installer and an update's diff before you
  run either.
- `nova list --porcelain` fields are positional and only ever appended to, so
  anything parsing it keeps working. Field 13 is the scopes an app is installed
  in, 14 is its pin.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).

Release notes are in [CHANGELOG.md](CHANGELOG.md); the 1.3.0 audit that
produced most of them is in [FIXPLAN.md](FIXPLAN.md).
