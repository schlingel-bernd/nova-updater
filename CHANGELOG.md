# Changelog

Earlier entries are the release commit subjects, which is where this project's
history actually lives.

## 2.2.0 — 2026-10-06

### Added — every app shows its own icon

Each app owns its icon: the file lives in the app's repo and its manifest
names it (`ICON=data/my-tool.svg`). The GUI now draws it in the list, on the
cards and in the detail view — before, only the detail view used it, and
only after `nova info` had loaded; rows and cards always showed a themed glyph.
SVGs go through GTK's icon loader, so they are drawn at the size they are
shown at instead of being scaled down from a bitmap. Only `.svg` and `.png`
files up to 1 MiB inside the app's clone are used: catalogs other people
publish feed this list, for apps nobody has installed yet. Apps without an
icon keep the themed one for their category.

- `nova list --porcelain` appends field 15, the manifest's `ICON` (empty when
  there is none). Fields are append-only, so nothing that reads the earlier 14
  changes.
- nova-updater's own icon now comes from
  [nova-icons](https://github.com/schlingel-bernd/nova-icons) and is named by
  `ICON=`; the desktop entry and the GUI show the same file. The README and the
  manifest template describe how an app ships its icon — nova network apps copy
  theirs from nova-icons `svg/classic/<app-id>.svg`.

### Fixed

- **Installed user apps did not say where they were installed.** The scope
  pills (green USER, yellow ROOT; dimmed where an app is not installed) were
  shown only for apps with a root half, on the theory that a USER pill on every
  row was noise — so nova-fox and the CLI tools showed nothing at all. Every
  app now gets one pill per scope it uses.
- **An installed app whose repo could not be reached looked uninstalled.** The
  GUI offered *Install* for it (which cannot reach the repo either), hid
  *Uninstall* in its detail view and left it out of the Installed filter —
  offline, that was every app. Whether an app is installed now comes from its
  installed scopes, not from its status.
- **"Apps updated" notifications name the version** ("nova-cli-tools-desktop
  1.0.1"). With the name alone, the same release announced on two machines, or
  a banner GNOME kept up while nobody was at the screen, read like an update
  that ran twice.

P35 checks the new porcelain field; P10 no longer pins the field count to 14.

## 2.1.1 — 2026-10-06

One fix, seen on the first real update to 2.1.0.

- **Every self-update ended with a false version-skew warning.**
  `nova update nova-updater` replaces both copies of nova in one run, but the
  process doing it is still the *old* version in memory. It compared the fresh
  root-owned copy with itself and finished with "the root-owned copy of nova
  is 2.1.0; this one is 2.0.0 — to do it now: nova update --system
  nova-updater", advising you to redo what it had just done. The comparison now
  reads this copy's version from the file on disk. P34 reproduces it exactly:
  the old code in memory, the new file at `$0`.

## 2.1.0 — 2026-10-06

### Added — nova apps as dependencies

A `DEPENDS` word that names a nova app is installed first: nova-fox's provider
plugins say `DEPENDS=nova-fox podman`, so `nova install nova-plugin-tor` brings
nova-fox along. This arrived as PR #1 from a cloud session and was merged
untagged; it was reviewed before release, and as merged it

- ran the dependency's installation inside `miss="$(…)"`, so its output
  vanished into the "missing" list: every *successful* dependency install
  ended in a warning that the app was "not here", followed by its own log;
- installed a dependency in whatever scope it declared, so a user app needing
  a system-only app ran a system install unprivileged, and root installed
  user-only dependencies into `/root/.local`;
- resolved the word against **every** registered catalog — dependency
  confusion: if one catalog's app needs `secret-tool` and the binary is not
  there, another catalog listing a repo called `secret-tool` got its installer
  run, without anyone having chosen that app;
- and installed the first app of a dependency cycle twice.

As released it installs in-process, only in the dependent's own scope (and
otherwise names the `nova install` command to run), only from a list that also
names the dependent or from a list on this machine, and keys the cycle check
on the dependent. One planning step answers for `install`, `--dry-run`,
`nova info` and the GUI (`depends_installs=` in the porcelain), so an app nova
is about to install is no longer shown as "missing — the installer may fail".

### Fixed

- **An installer could not call the tool it had just installed — on the
  passwordless route.** pkexec gives root `/usr/sbin:/usr/bin:/sbin:/bin:/root/bin`
  (compiled into polkit), which has no `/usr/local/bin`; Fedora's sudo
  `secure_path` does have it. So nova-killswitch 0.2.0's installer worked from
  a terminal and, on a passwordless update, waited ten seconds and reported
  "the daemon is not answering" while the daemon was up the whole time. Every
  installer now runs with its own prefix first on `PATH` — `~/.local/bin` for
  the user scope, a fixed `/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:
  /sbin:/bin` for the system scope — and the wrapper sets the same for itself.
  Fixing only the wrapper would have left the GUI's pkexec installs and
  user-scope installers under a headless session uncovered.
- **`DEPENDS` is checked in that same `PATH`**, not nova's own, which in a
  user manager without the desktop's environment reported `nova-fox` missing
  for every plugin.
- **`nova update nova-updater` from a terminal updated the root half twice.**
  nova-updater's own `install.sh`, run by nova as the user-half installer, also
  handled the system half whenever stdin was a terminal, and then nova's
  dispatch did it again — two root updates, and in manual mode two password
  prompts. Under nova the script now leaves the system half to nova.
- **`nova install <user app> --dry-run` exited 1** (since 1.3.0): the plan's
  last test was false for any user-scope target, and `set -e` took it as a
  failure. P4 had checked the output but never the exit code.
- **The scripts are executable in git again.** Something reset them to 0644 on
  a development machine before 1.7.0 and a `git add -A` recorded it, so
  1.7.0–2.0.0 shipped `bin/nova`, `install.sh`, `get-nova.sh`, `gui/nova-gui`,
  `templates/install.sh` and the tests non-executable: `./install.sh` from a
  fresh clone said "Permission denied". nova's own paths never noticed — they
  run everything through `bash` or reinstall with `install -m755` — so the
  release gate (`tests/check-version.sh`, also in CI) now checks the modes.
- **Since 1.7.1 every catalog app carried its catalog's file path as its
  "options".** The internal entry list was `url⇥opts⇥source`; for an entry
  without options the two tabs collapse when read (a tab is IFS whitespace),
  so the source landed in `opts` and read back empty. Harmless only by luck —
  a path contains no `key=` — but the 1.7.1 warning for a bad catalog line
  named no file, and anything keyed on the source saw nothing. The empty-able
  field is last now.
- Stale 2.0.0 wording: install.sh still described auto mode as a "root timer",
  manual mode as "no root timer", and the wrapper's no-names path as "what the
  background timer wants".

### Also

- README and the installer template document `PATH` and app dependencies; the
  GUI has an icon for `COMPONENTS=module` and the manifest template lists it.
- `tests/repro.sh` gains P27–P33, each failing on the code it fixes; P4 now
  checks the exit code.

## 2.0.0 — 2026-10-05

Simpler, by removing things. The goal restated: a userspace app manager that
installs root parts with a password, auto-updates them securely from
userspace, and can run password-only if you prefer.

### Removed — the root timer

System halves are now updated by **your** timer: `nova update --all` updates
user halves directly and system halves through the passwordless wrapper —
which polkit grants to wheel users from a user service too, verified on
Bluefin — and nova's own root-owned copy is just another system half. That
removes the root timer, its units, the whole class of "the root copy never
updated itself / drifted / showed a stuck update" bugs that came from two
updaters, and most of what `manual` mode had to switch off. Existing installs
lose the old root timer on their next self-update; `nova doctor` flags one
that is still enabled.

### Changed — installing a root part asks for one password and nothing else

- `nova install nova-killswitch` on a machine without the system scope sets it
  up on the spot (one password) and installs. It no longer refuses.
- If root does not know the app's URL yet, the authenticated install hands it
  over (`--from`) and root records it in its list — an admin typing a password
  for "install this repo as root" is exactly the decision that list exists to
  record. No more "register it for root first". Passwordless updates still
  touch only what the root list names.
- `--with-system=manual` now means one thing: no polkit rule. Every system
  change asks for a password — sudo in a terminal, a dialog in the GUI — and
  the timer leaves system halves for your next interactive update instead of
  prompting at 3am (`NOVA_UNATTENDED=1` in the unit; never prompt from there).

### Why 2.0

The user unit's `ExecStart` changed (`--all` without `--user`), the root units
are gone, and the install refusal that scripts might have relied on is gone.

## 1.8.0 — 2026-10-05

### Added — a system scope without the auto-updater

`--with-system=manual`. The same root-owned copy of nova and the same root
lists, but **no root timer, no polkit rule and no passwordless wrapper**.
Every change to the system scope asks for a password and nothing of nova's
runs as root unattended; the price is that root halves update only when you
ask. For anyone who wants system apps but not a root timer.

- `install.sh install --with-system=manual`, or `=auto` (the default on a
  fresh install). The mode is recorded in `/etc/nova-updater/mode`, so root's
  own self-update keeps it and a plain `--with-system` re-run never flips a
  deliberate choice; the two modes are one explicit command apart in either
  direction, and switching to manual removes the wrapper, rule and timer that
  auto had installed.
- Everything that already fell back to "ask for root" when the wrapper is
  missing — `nova update` of a system app, nova's own system half, the GUI's
  Update button via a polkit dialog — is exactly how manual mode works, so
  there is no second code path to go wrong.
- `nova doctor` and `nova version` say which mode a machine is in, and doctor
  no longer reports a missing system timer as a problem when it is missing on
  purpose — but does report a timer that is *running* in manual mode.
- The version-skew advice and the "no system scope yet" message name the
  manual variant too.

One thing cannot be removed in any mode: the root-owned copy itself. Root
has to execute *something*, and the only alternatives are a user-writable
file (the exact thing the split exists to prevent) or nothing at all (brew's
answer, which cannot install a kill switch). Without timer and rule that copy
is inert until an admin types a password.

The README presents the three tiers — auto (recommended on a desktop),
manual, minimal — and what each can and cannot install.

P23 and P24 cover install, doctor, and switching in both directions.

## 1.7.2 — 2026-10-04

Documentation, and one message.

- **The README now recommends `--with-system` on a desktop**, and says plainly
  which apps need it: anything with a root half — nova-killswitch — installs
  only its desktop part on a user-only install, and only the system scope's
  own timer keeps a root half updated. The minimal install stays documented as
  complete for user-only apps.
- A new section lines nova up against rpm/apt, flatpak and brew. The shape is
  flatpak's — a user installation that needs no root plus an optional system
  installation guarded by polkit and a root-owned helper — and the second copy
  of nova *is* that helper. It looks odd only because nova installs itself
  from git into `~/.local` rather than arriving as a root-owned package.
- When a dual-scope app is installed on a machine with no system scope at all,
  nova now says exactly that — the user half installs, the root half cannot
  until the scope exists, here is the command — instead of "no root-owned list
  names it". P22 covers it.
- `install.sh` and `get-nova.sh` say the same thing in their closing hint and
  header.

## 1.7.1 — 2026-10-04

Two things found on a real machine right after 1.7.0.

- **"ignoring an unusable entry" now names the file.** The warning fired on
  every command for a line that said just `nova-killswitch` — written years
  ago by a `nova add <name>` from before URLs were validated — and gave no
  hint which of four list files held it. It names the file and says what a
  list line is supposed to be.
- **The app-folder sync writes to dconf only when something changes.** It used
  to rewrite name, apps and translate with identical values on every update,
  handing GNOME Shell a folder to re-render for nothing on every timer tick.
  It also collapses a folder id listed twice, which two nova runs appending at
  the same moment could produce. P20 and P21 cover both.

The duplicate "Nova Tools" folder fixed in 1.7.0 only disappears on the next
user-scope install or update after upgrading — the run that installs 1.7.x is
still executing the old code.

## 1.7.0 — 2026-10-04

A third full audit, this time concentrating on the bootstrap, the root
wrapper boundary, the systemd units and untrusted data. Seven findings, all
reproduced before being fixed; `tests/repro.sh` gains P16–P19 (42 checks).

### Fixed

- **The desktop bootstrap never registered root's self-update.** `curl … |
  bash -s -- --with-system` runs the root phase under `pkexec` (stdin is a
  pipe, so there is no tty for sudo). Under sudo, git treats a directory owned
  by `SUDO_UID` as safe; under pkexec there is no `SUDO_UID`, git refused the
  user's checkout as "dubious ownership", `origin_url` came back empty, and
  `register_self` printed "no git origin found". The root clone was never
  created, so the root-owned nova had nothing to self-update from — the F4
  symptom again, silently, on every desktop bootstrap. The sudo path masked it
  in every test until now. One URL is now read with `-c safe.directory`.
- **The "Nova Tools" app folder appeared twice.** If you had moved the apps
  into a folder of your own in the app grid, GNOME gave it its own id and the
  name you typed; nova then built *its* folder (`nova-tools`) with the same
  name and the same apps, and rebuilt it after every update. It now adopts an
  existing folder that already holds any of the apps, then one carrying the
  name, and only otherwise creates its own — and removes a stray `nova-tools`
  next to the adopted one.
- **Timers were enabled before the lists existed.** `enable --now` can fire a
  `Persistent` timer immediately on a machine that has been up longer than
  `OnBootSec`, so `nova update --all` could run while the installer was still
  writing the lists it reads. Both timers are now enabled last.
- **`--force`, `--cli-only` and `--gui` were dropped for the system half.** The
  passwordless wrapper carries names and nothing else — that is what makes it
  safe — so `nova update --force app` forced the user half and quietly did a
  plain update as root. With any such flag nova now asks for root directly and
  says why.
- **List and manifest values were glob-expanded.** `for kv in $opts` also
  globs, so a catalog line carrying `ref=*` was replaced by the names of
  whatever files sat in nova's current directory. Values from other people
  are now split on whitespace and nothing else.
- The version-skew notice sent every mismatch to the password-gated bootstrap.
  A root copy from 1.3.0 on picks a new version up from its own timer, or
  right now with `nova update --system nova-updater` (no password); only a
  copy older than that needs the bootstrap. The advice now depends on which.
- The user-side view of a system app is read out of `/var/lib`, so a root
  umask of 077 made every system app look not-installed from the user side
  with nothing saying why. System clones and markers are made world-readable
  on creation, and `nova doctor` reports ones that are not.

## 1.6.1 — 2026-10-03

The pin warning added in 1.6.0 printed "not this pinv0.1.0" — a bad parameter
expansion glued the word to the value. Seen the first time the warning fired
on a real machine.

## 1.6.0 — 2026-10-03

A fresh full pass over the CLI and GUI.

### Fixed

- **A user-side pin no longer marks the root half update-available for ever.**
  Each scope follows its own list entry — you pin your half, root's list keeps
  following releases — but "is there an update?" was answered against the one
  deduped entry's target. Pin a dual-scope app and the system half became
  permanently "update-available" while `nova update` said "up to date": both
  halves sat exactly where their own configuration wanted them. Outdatedness
  is now computed per scope against that scope's own entry (both list files
  are world-readable, so either side can read the other's pins). Third member
  of the stuck-indicator family, after F8 and the 1.3.1 dedup bug.
- **`nova version` exited 1** on every machine without the system scope — the
  trailing `[[ -n $root_v ]] &&` was the script's last command. Anything
  scripted as `nova version && …` broke.
- **`nova catalog list --porcelain` emitted a two-line app count** for a
  catalog whose apps.list holds only comments: `$(grep -c … || echo 0)`
  captures grep's own `0` *and* the fallback. Found because a new test made
  the identical mistake.
- `nova pin` refused nothing: a value with whitespace — possible whenever the
  remote is unreachable, since "pinning anyway" skips the existence check —
  was written into the space-separated list file and corrupted the entry. The
  shape is validated before anything touches the file.

### Added

- `nova pin`/`unpin` on a dual-scope app now says plainly that the system
  half follows root's own list and names the `nova pin --system` command that
  holds it too.
- **The GUI confirms uninstalls.** Removing a catalog asked first; removing an
  actual app ran its uninstaller on one click.
- README: a section on why the split layout and the two binaries exist at
  all, with the costs and what mitigates them.

## 1.5.2 — 2026-10-03

`nova info` and `nova list` disagreed about an app's scopes, so the GUI detail
view was missing the root half of a dual-scope app.

1.3.1 taught `nova list` to report the scopes an app is actually installed in
as well as the ones it declares. `nova info` was not given the same treatment,
so for nova-updater — listed in both apps.list files by design — `info` reported
`scopes=user` and printed no `installed_system` line at all, while `list` said
`user system`. The detail dialog is built from `info`, so its "What it installs"
section showed only "Into your home directory" even on a machine where the root
half was installed. Plain `nova info` was wrong in the same way.

All three scope computations in `cmd_info` now use the same helper `cmd_list`
does. `tests/repro.sh` gains P12, which asserts the two commands agree.

## 1.5.1 — 2026-10-03

The screenshot viewer added in 1.5.0 had a zoom control it did not need. These
are screenshots of desktop apps, so at that window size they are already at or
near 1:1, and the zoom buttons mostly put chrome in front of the picture.

It is gone, and the viewer is a proper scroller instead:

- a carousel, so shots slide and can be swiped
- the scroll wheel moves between shots now that it is not spent on zooming
- arrow keys, Page Up/Down, space, Home and End
- indicator dots, and a thumbnail strip showing the whole set with the current
  one outlined — so what else there is no longer has to be discovered by
  swiping
- opening a shot from the detail view starts on the one you clicked

Also: the viewer no longer raises on an empty list. Not reachable from the GUI,
which only offers the button when there are screenshots, but it should say "no
screenshots" rather than throw.

## 1.5.0 — 2026-10-03

### Fixed

- **`nova doctor` never checked your own list files.** It only looked at
  `/etc/nova-updater/`, because the root-ownership rule applies there — but
  `~/.config/nova-updater/apps.list` and `catalogs.list` decide which
  installers run as *you*, so one that anybody local can write is a way to get
  code executed as you. Both are checked now, for ownership and for group and
  other write, and it says when they do not exist yet.
- nova-updater's own manifest had no `CATEGORY`, so the GUI fell back to
  showing `COMPONENTS` — the card read "cli gui". It declares `CATEGORY=System`
  now, which is one of the documented categories and already has an icon.

### Added

- **Component chips.** "daemon cli gui gnome-extension" was a line of words;
  each component is now a labelled chip with the icon it already maps to.
- **Screenshots can be read.** The carousel had no spacing between images and
  no way to enlarge one. Images are spaced, each opens a viewer with zoom
  (buttons or the scroll wheel, 25%–400%, or fit), and the viewer steps through
  the whole set.
- **The README is rendered.** It used to be stripped of its code blocks and
  tables and flattened into one dim 4000-character paragraph. Headings,
  emphasis, inline and fenced code, lists, block quotes, rules and tables now
  render as a document, with theme-aware colours; it sits behind an expander
  like the installer, with an "Open" button for a full-window view. Markup is
  escaped before any markdown is interpreted, so a README cannot inject Pango
  tags.

## 1.4.0 — 2026-10-03

The GUI catches up with the CLI, and finally shows which scopes an app is
installed in.

### Added

- **Installed scopes are visible.** For an app that uses both scopes, the list
  rows, the cards and the detail header show a `USER` and a `ROOT` pill, filled
  where that half is installed and dimmed where it is not — so a half-installed
  app says which half, and "partly installed" means something specific. Only
  for apps that use the system scope: a `USER` pill on every row would be
  noise, and for a user-only app the status already says everything.
- The detail view's "What it installs" rows now say **INSTALLED / NOT
  INSTALLED** per scope. `nova info --porcelain` had reported
  `installed_<scope>` all along; nothing in the GUI ever showed it.
- **Before you run it**: the app's installer, and — when an update is waiting —
  what that update changes, both as expanders carrying the CLI's own
  `info --installer` and `diff` output. Loaded only if you open them.
- **Pin and unpin from the GUI**, in an "Updates" group, with a `PINNED` badge
  in the lists.
- **`nova doctor` in a window** you can read, behind a header button, rather
  than buried in the log pane.

### Changed

- `nova list --porcelain` gains two appended fields: 13 is the scopes the app
  is actually installed in, 14 is its `ref=` pin. Existing field positions are
  unchanged.
- `nova info --porcelain` gains `pinned=` and `installer=`; plain `nova info`
  shows `depends` and a pin when there is one.
- The GUI's three near-identical subprocess blocks are one helper. They had
  already drifted — only one closed stdin, so depending on which button you
  pressed, nova could pick `sudo` and prompt in whatever terminal the GUI was
  launched from while the window sat there looking hung.

## 1.3.1 — 2026-10-03

Fixes a bug introduced in 1.3.0.

An app listed in **both** `apps.list` files — which nova-updater itself is, by
design — was shown as belonging only to the scope of whichever entry survived
the dedup. `nova list` labelled nova-updater `scopes=user` while it was
installed in both, so:

- the marker comparison correctly saw that the root half was behind and
  reported `update-available`,
- but `nova update nova-updater` only ever acted on the user half and answered
  "is up to date",
- so the GUI showed an update that nothing the user could do would clear.

The scopes to act on are now the ones the entry and manifest declare *plus any
scope the app is actually installed in*. Something already installed is a fact,
and it outranks what one list entry happened to say. `nova update
<app>` now reaches the root half of such an app, passwordlessly through the
usual wrapper.

## 1.3.0 — 2026-10-03

A full audit of 1.2.1 (see `FIXPLAN.md`), worked through one finding per
commit. `tests/repro.sh` reproduces every finding and now passes.

> **Upgrade note — only if you have the system scope.** The root-owned copy of
> nova could never update itself (see below), so it cannot pick this release up
> on its own. Re-run the bootstrap once:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/schlingel-bernd/nova-updater/main/get-nova.sh | bash -s -- --with-system
> ```
> `nova version` shows both copies and `nova doctor` checks them. Installs
> without the system scope need nothing.

### Fixed — wrong state, data loss, unwanted root prompts

- A failed installer was recorded as installed: the marker was written, nova
  printed "installed" and exited 0, so the next `nova update` saw nothing to
  do. Updates did the same and sent the "Apps updated" notification.
- A failed uninstaller still deleted the clone, leaving the app's files on disk
  with nothing left that knew how to remove them.
- `install.sh uninstall --with-system` passed `--purge` to the root half
  whether or not you asked, deleting `/etc/nova-updater` and
  `/var/lib/nova-updater` including the clones of system apps still installed.
- The root-owned nova never updated itself. Its system-list entry asked for the
  system scope, its manifest declared `SCOPES=user`, the intersection was
  empty — so the timer failed every six hours with "no apps matched" and the
  copy running as root never received a fix.
- A plain `nova update` asked for a password on behalf of system apps that
  were not installed, which on a default install meant every run.
- A background process left behind by an installer kept the scope lock, so
  every later nova command failed with "another nova is already running",
  naming a pid that was gone. Only a reboot cleared it.
- `nova install` with no arguments installed every app in every catalog.

### Fixed — correctness

- System apps showed "update available" for ever: the comparison was against
  the metadata clone in the user's home rather than the installed commit. The
  GUI showed an update count nothing could clear.
- `nova check` missed system apps that came from a catalog, reporting
  "everything is up to date" with exit 0 while an update was pending.
- "Latest release" was whatever sorted last, so a release candidate
  permanently shadowed its own release and a tag like `wip-test` beat every
  version tag.
- Two catalogs whose repos share a name shared one clone directory; removing
  one deleted the other's. An app whose URL changed was reinstalled from the
  old origin, running the old installer and reporting success.
- `--cli-only` was forgotten after one update, so a cli-only app grew a GUI.
- "Up to date" was reported when the remote could not be reached at all.
- `--purge` never reached the app's own installer.
- List files were matched by substring, so `.../foo` counted as present when
  `.../foo-bar` was listed, and purging one dropped the other.
- Installing without a systemd user session aborted half way, after the
  binaries and before the lists and the default catalog.
- A manifest saved with CRLF made the app vanish behind "no apps matched".
- The "Nova Tools" app folder globbed for `org.novanetwork.*` while every app
  uses `eu.novanetwork.*`, so it was always empty.

### Fixed — hardening

- The credential helper was still invoked by `git ls-remote`, which execs git
  directly and bypassed the wrapper meant to prevent exactly that.
- As root, app names were resolved through `HOME` and `XDG_CONFIG_HOME`, so
  with `sudo -E` or a preserved `HOME` root took its instructions from a list
  the calling user can write. Root now reads only root-owned files, and
  refuses one that is group- or world-writable.
- Updating nova ran `sudo bash ~/.local/share/.../install.sh`, a user-writable
  script, as root — with a cached sudo timestamp, without a prompt.
- Catalog URLs were used unvalidated and without `--`; transports are now
  allowlisted.
- The root wrapper's name pattern also matched `--all`, `--force` and
  `--user`, and the polkit rule's stated rationale described a program that
  takes no arguments. It has taken names since 1.1.0.
- The GUI did not escape manifest-derived strings in its detail view, so a
  description containing `&` rendered empty and a manifest could inject markup
  into the row explaining why an app wants root. `ICON`, `SCREENSHOTS` and
  `ABOUT` were joined to the repo path unchecked, so `../` read any file the
  user could read. Installing an app that needs root now asks first.

### Added

- `nova pin <app> <tag>` / `nova unpin <app>` — stay on a tag until you say
  otherwise.
- `nova diff <app>` — the commits, the file stat and the installer's own diff
  that an update would apply.
- `nova info --installer <app>` — print the script before the first install.
- `nova doctor` — stale locks, version skew, list-file ownership, origin
  mismatch, missing timers.
- `--dry-run` for install, update and uninstall.
- Missing `DEPENDS` are named by `nova info` and before an install, which the
  manifest template already promised.
- bash completion for commands, options and app names.
- `tests/repro.sh`, `tests/check-version.sh`, a CI workflow, and a `LICENSE`
  file — the README said GPL-3.0-or-later while the repo shipped no licence.

### Changed

These alter behaviour an app author or a script could rely on:

- `nova install` requires an app name or an explicit `--all`.
- Only tags matching `^v?[0-9]+(\.[0-9]+){0,3}$` count as releases. A repo
  whose tags are not version-shaped now follows HEAD.
- A purging uninstall calls `./install.sh uninstall --purge` and exports
  `NOVA_PURGE=1`.
- Unknown options are an error instead of being treated as app names, and
  options may appear anywhere, including before the command.
- Metadata clones are shallow and fetched in parallel (`NOVA_FETCH_JOBS`).

## 1.2.1 — 2026-10-01

Stop claiming the system scope is missing when it is installed.

## 1.2.0 — 2026-10-01

A stalled fetch could wedge every later command until reboot.

## 1.1.3 — 2026-10-01

The desktop app is Nova Apps, the project stays nova-updater.

## 1.1.2 — 2026-10-01

Ship a real icon instead of borrowing a themed one.

## 1.1.1 — 2026-10-01

The root wrapper only knew about locally-added apps.

## 1.1.0 — 2026-10-01

Updating one system app no longer updates all of them.

## 1.0.2 — 2026-10-01

Only footnote the root marker when something uses it.

## 1.0.1 — 2026-10-01

Installer referenced a desktop file and icon that no longer exist.

## 1.0.0 — 2026-10-01

App explorer, installer and updater for git catalogs.
