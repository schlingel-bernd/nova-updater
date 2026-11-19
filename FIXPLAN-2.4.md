# nova-updater — fix plan for 2.4

Audit of `schlingel-bernd/nova-updater` at commit `529405d` (tag `v2.3.2`), 7 November 2026,
plus one GUI bug report ("in the GUI we can't install multiple items").
Written to be resumed in a local Claude Code session, one finding at a time.

The previous plan, `FIXPLAN.md` (audit of v1.2.1), is done; this one builds on it.
Its IDs (`F*`, `S*`, `P1`–`P37`) are taken. This plan uses:

| Prefix | Area |
|---|---|
| `H*` | security, high |
| `M*` | security, medium |
| `L*` | security, low |
| `U*` | GUI behaviour |
| `Q*` | speed |

Line numbers refer to `v2.3.2`. They drift as soon as you start editing, so each
finding also names the function.

---

## Resuming this on your own machine

```bash
git clone https://github.com/schlingel-bernd/nova-updater.git   # or: git fetch origin
cd nova-updater
git checkout ccr-b067eef3-yh5605
claude
```

Suggested prompts, in order:

1. `Read FIXPLAN-2.4.md. Do Phase 0 only. Show me the diff before committing.`
2. `Fix H2, H3 and M2 from FIXPLAN-2.4.md. Run tests/repro.sh H2 H3 M2 in the container. One commit per finding.`
3. `Do U1 (the GUI action queue). Tell me the manual test steps when you are done.`
4. Continue finding by finding. After each phase:
   `Run the full tests/repro.sh and shellcheck, then summarise what changed.`

Before Phase 2 and Phase 4, read **Decisions** below — those need an answer from
you, not from Claude.

## Rules for Claude while working on this

Everything in `FIXPLAN.md` → *Working with Claude Code* still applies. The ones that
matter most:

- **Never run `tests/repro.sh` on the host.** It needs root and wipes
  `/etc/nova-updater`, `/var/lib/nova-updater` and `/usr/local/bin/nova`. Container only:
  ```bash
  podman run --rm -v "$PWD":/src:ro,Z fedora:latest bash -c \
    'dnf -y -q install git-core gawk util-linux shadow-utils procps-ng python3 openssl openssh-clients >/dev/null && bash /src/tests/repro.sh'
  ```
- Never run `install.sh`, `get-nova.sh`, `sudo` or `pkexec` on the host to "try something".
  The GUI (`gui/nova-gui`) may be run on the host — it only calls the CLI — but
  do not click Install on anything with a root half while testing.
- One finding per commit, message in the repo's style
  (`2.4.0 — <what the user would have noticed>`), a `CHANGELOG.md` entry per release.
- A fix is done when its check prints `ok` **and** no other check regressed,
  `shellcheck -S warning` is clean, and `python3 -m py_compile gui/nova-gui` passes.
- Do not change the porcelain field order. Append fields only; the GUI indexes by position.
- No new runtime dependencies beyond bash, git, coreutils, util-linux, awk, sed, grep
  (GUI: python3-gobject, GTK4, libadwaita, GdkPixbuf — all already used or in the base image).
- If a fix needs a design decision listed under **Decisions**, stop and ask.

## Invariants

`FIXPLAN.md`'s four still hold:

1. Root never executes a file the user can write, and never reads configuration from a path the user can write.
2. A failed step is never reported as success, in the exit code or in the marker.
3. What `nova info` and `nova list` show is what `nova install` and `nova update` will act on.
4. Nothing asks for a password unless it is about to do root work that can succeed.

Added by this audit:

5. **Nothing from a catalog or a manifest is ever interpreted** — not as a command-line
   option, not as shell code, not as terminal control sequences, not as markup.
6. **A catalog cannot change what root runs for an app that is already installed** —
   not its source (already true), not its ref, not its branch.
7. **Root speaks https only**, except to local paths that root owns all the way up.

---

## Phase 0 — checks first

Add a `t_<ID>` per finding below to `tests/repro.sh` and append the IDs to the
`for t in …` list at the bottom. Confirm each prints `BUG` on the untouched tree
before fixing anything. GUI findings (`U*`) have no container check; each one
lists manual steps instead.

### 0.1 Root fixtures must be root-owned (needed by H1)

H1 makes root refuse a local path unless the path **and every parent directory**
are root-owned and not group/other-writable. Today `reset()` does
`chown $T $GITROOT` and `mkapp` chowns each repo to the test user, and about a
dozen tests put such paths into `/etc/nova-updater/apps.list` (F4, F16 and the
P-series around lines 127, 171, 257, 459, 477, 511, 531, 595, 725, 756, 801, 938).
After H1 they would all fail for the wrong reason.

Add a helper and switch those tests to it:

```bash
ROOTGIT=/srv/nova-git-root      # root:root 0755 all the way up
rootfix() { # owner name -> prints a root-owned copy of $GITROOT/owner/name.git
    mkdir -p "$ROOTGIT/$1"; chmod 755 "$ROOTGIT" "$ROOTGIT/$1"
    rm -rf "$ROOTGIT/$1/$2.git"
    cp -a "$GITROOT/$1/$2.git" "$ROOTGIT/$1/$2.git"
    chown -R root:root "$ROOTGIT/$1/$2.git"; chmod -R go-w "$ROOTGIT/$1/$2.git"
    echo "$ROOTGIT/$1/$2.git"
}
```

…and add `$ROOTGIT` to the `rm -rf` in `reset()`. A test that later calls
`release` on the app must re-run `rootfix` (or push to the root copy) so root sees
the new tag.

Do **not** add an environment variable that lets root skip the ownership check
"for tests". Root reads nothing from the environment (S2, L1); a test escape
hatch would be the first exception.

### 0.2 New checks

| ID | Setup | Fixed when |
|---|---|---|
| H1 | `mkapp a lp system` (user-owned). `echo $GITROOT/a/lp.git > /etc/nova-updater/apps.list`. Also `kr install --system lp --from $GITROOT/a/lp.git`. | `kr list --porcelain --no-sync` has no `lp` row; `/var/lib/nova-updater/repos/lp/.nova-installed` does not exist; the `--from` URL was not appended to `/etc/nova-updater/apps.list`. **Rewrite P36's last clause** (it asserts the opposite — see Decisions D1). |
| H2 | In the user's apps.list: `https://example.invalid/$(touch${IFS}kt-pwned).git` (no clone needed). In a temp cwd, as the test user, with `$W/bin` on `PATH`: `source $W/data/bash-completion/nova; COMP_WORDS=(nova install ""); COMP_CWORD=2; _nova`. | `kt-pwned` was not created in that cwd, and `ku list --porcelain --no-sync` has no row for the entry. |
| H3 | In the user's apps.list: `https://example.invalid/--all.git` and `https://example.invalid/-x.git`. | No name in `ku list --porcelain --no-sync \| cut -f1` starts with `-`; `ku add https://example.invalid/--purge.git` exits non-zero. |
| M1 | `mkapp a dg system`, `release a dg v1.1.0`, root fixture, root catalog listing it (no options). `kr install --system dg`. Then commit `<url> ref=v1.0.0` to the catalog and `kr update --all --system`. Repeat with `branch=main`. | Marker line 1 is still the commit of `v1.1.0` in both cases. |
| M2 | `kr add --system http://example.invalid/x.git`; `echo http://example.invalid/y.git >> /etc/nova-updater/apps.list`; root catalog containing an `http://` line. | `kr add` exits non-zero; neither shows in `kr list --porcelain --no-sync`. (User scope: see Decisions D2.) |
| M3 | `mkapp a esc user` whose `install.sh` contains a raw ESC byte (`printf '\033[8m'` written literally into the file) and a commit subject with one; install, release, `ku diff esc`, `ku info --installer esc`. Same for a catalog whose `catalog.manifest` `NAME=` contains ESC, via `ku catalog list`. | No `$'\e'` byte in any of those outputs. |
| M6 | (a) app whose manifest says `INSTALLER=../../../tmp/kt-outside.sh`, with that file present; (b) app whose `install.sh` is a git symlink to `/tmp/kt-outside.sh`. `ku install` each. | Both exit non-zero and `/tmp/kt-outside.sh` never ran (have it `touch /tmp/kt-ran`). |
| M7 | Root catalog listing two root-fixture apps; install one as root. `kr update --all --system`. Same for the user scope with `ku update`. | No clone directory exists for the app that is not installed, in either scope. |
| L1 | `KENV='NOVA_FETCH_JOBS=PATH[$(touch${IFS}/tmp/kt-l1)]' kr list --porcelain` with a fresh root catalog (so `sync_all_meta` runs). The name must be a *set* variable: under nova's `set -u`, `a[…]` aborts on the unset `a` before the subscript is evaluated. | `/tmp/kt-l1` does not exist. |
| Q1 | Put a `git` wrapper first in `$STUBS` that appends `ls-remote` invocations to `/tmp/kt-lsr.log` and then `exec /usr/bin/git "$@"`. Three system apps installed by root (root fixtures), plus the user's metadata clones of them (`ku list`); then `ku list --porcelain --check`. (Apps installed only in the user scope already get one call each: `refresh_meta` skips a clone with a marker. The duplicate is `refresh_meta` on the user's metadata clone plus the status lookup.) | `ls-remote` was called at most once per URL (3 lines; 6 on 2.3.2). |
| Q4 | Catalog with five apps, none installed, user scope. `ku update`. | No metadata clone was made for any of them (same mechanism as M7). |

---

## Phase 1 — quick, low risk

### H2 — tab completion runs code from catalogs [run]

- **Where:** `data/bash-completion/nova:37` (`compgen -W "$(nova list …)"`);
  `valid_url` (`bin/nova:628-641`); `manifest_name` fallback (`:785-792`).
- **What happens:** `compgen -W` *expands* every word, including `$(…)`. App names
  come from the manifest `NAME` (validated) or, when that is missing/invalid or the
  repo is unreachable, from the URL's basename — which nothing validates.
  `https://evil.example/$(cmd${IFS}args).git` passes `valid_url`, so pressing Tab after
  `nova install ` runs it. `install.sh` installs the same completion for root, so in
  `sudo -i` it runs as root. Verified on 2.3.2 (`valid_url` accepted it; `compgen` executed it).
- **Fix:**
  1. In `valid_url`, after computing `b`:
     ```bash
     [[ $b =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
     ```
     (replaces the `.`/`..`/`/` test, which this covers). `check_lists` already names
     the offending file and line.
  2. In `manifest_name`, apply the same regex to the fallback; return empty if it fails.
  3. Completion — never hand untrusted words to `compgen -W`:
     ```bash
     COMPREPLY=(); local n
     while IFS= read -r n; do
         [[ $n =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $n == "$cur"* ]] && COMPREPLY+=("$n")
     done < <(nova list --porcelain --no-sync 2>/dev/null | cut -f1)
     ```
  4. `data/nova-system-update:42`: the wrapper's `known()` computes basenames itself;
     apply the regex there too.
- **Check:** `tests/repro.sh H2`

### H3 — a repo basename becomes a command-line option in the GUI [run]

- **Where:** same root cause as H2; `gui/nova-gui:1728` (`run_action`), `:762` (`_pin`),
  `:776` and `:782` (`_lazy_text` argv), `:827` (`info --porcelain`).
- **What happens:** `https://evil.example/--all.git` is listed as an app called `--all`.
  Clicking Install runs `nova install --all` — every app in every catalog, system halves
  included — and because the decoy declares `SCOPES=user`, the root confirmation dialog
  is skipped. `--purge`, `--force`, `--system` work the same way. Verified on 2.3.2.
- **Fix:** H2's `valid_url` change closes the source. Independently, every GUI call that
  passes a name puts `"--"` before it:
  `[self.nova, verb, *flags, "--", *names]`, `[nova, "pin", "--", name, ref]`,
  `[nova, "info", "--porcelain", "--", name]`, etc. nova's option loop already
  treats `--` as end of options (2.3.2 `bin/nova:2414`).
- **Check:** `tests/repro.sh H3`; GUI: grep that no `subprocess` argv in `gui/nova-gui`
  has a name without a preceding `"--"`.

### M2 — root accepts `http://` [read]

- **Where:** `GIT_ALLOW_PROTOCOL=https:http:file` (`bin/nova:173`); `valid_url` accepts
  `http://` (`:635`); `--from` (`:2454`).
- **What happens:** a catalog entry (or an `https`→`http` redirect, which git follows
  when `http` is allowed) means root clones and runs an installer fetched in plain text.
  Anyone on the network path gets root.
- **Fix:** as root, `export GIT_ALLOW_PROTOCOL=https:file` (file only matters for the
  root-owned local paths H1 still allows) and reject `http://` in `valid_url`.
  For the user scope see Decisions D2; recommended: reject there too and drop the
  `http://` warnings in `cmd_add` / `catalog add`.
- **Check:** `tests/repro.sh M2`

### M3 — terminal escape sequences hide code from the review commands [read]

- **Where:** `cmd_info --installer` (`cat "$dir/$inst"`, `:1784`); `cmd_diff`
  (`git log`, `git diff`, `:1988-1998`); `catalog_meta` (`:2230-2235`, not run through
  `manifest_get`'s cleaning).
- **What happens:** "read the installer before you run it" is the project's main answer
  to "can I trust this app" (README → *Choosing what you run*). An installer containing
  `ESC[8m` (concealed text), cursor movement or line erasure shows something other than
  what runs. Commit subjects and catalog names reach the terminal raw too.
- **Fix:** one helper, used for every untrusted byte stream that goes to a terminal:
  ```bash
  # show untrusted text without letting it drive the terminal: keep \t and \n,
  # make ESC and every other control byte visible
  safe_text() { LC_ALL=C sed 's/\x1b/^[/g; s/[\x00-\x08\x0b-\x1f\x7f]/?/g'; }
  ```
  `safe_text < "$dir/$inst"`, `git … | safe_text | sed 's/^/  /'`, and
  `catalog_meta` cleans its value the way `manifest_get` does (tabs → space, strip
  `[[:cntrl:]]`). Use `git -c core.quotePath=true` for `diff --stat` file names.
- **Check:** `tests/repro.sh M3`

### U1 — the GUI drops every action while it is busy ("can't install multiple items") [read]

- **Where:** `run_action` (`gui/nova-gui:1714-1716`: `if self.busy or not names: return`);
  `after_action` (`:1780-1785`) → `refresh()` (`:1577-1591`); `set_busy` (`:1787-1798`);
  `DetailDialog._run` (`:731-733`).
- **What happens:**
  1. While an action runs, every other Install/Update/Uninstall click is silently
     ignored. `set_busy` only disables Refresh and Update All, so the buttons look live.
     From the detail dialog it is worse: the dialog closes first, then nothing happens.
  2. When an action finishes, `after_action` immediately starts `refresh()`, which sets
     `busy` again for a full `nova list --porcelain --check` — one network round trip
     per app, serially (see Q1). So after installing one app you wait 10–20 s or more
     before the next click does anything.
  3. Running actions in parallel instead is not the fix: `nova` takes the scope lock, so
     a second process waits `NOVA_LOCK_WAIT` (20 s) and fails. They have to be queued.
- **Fix:** an action queue, separate from the refresh state.
  ```python
  # Window.__init__
  self.queue = []          # pending (verb, names, purge)
  self.acting = False      # a nova action is running
  self.refreshing = False  # list --check is running

  def run_action(self, verb, names, confirmed=False, purge=False):
      if not names:
          return
      # ... existing uninstall / root confirmation, unchanged ...
      self.queue.append((verb, list(names), purge))
      self._mark_queued(names)
      if self.acting or self.refreshing:
          self.toast("Queued: %s %s" % (verb, ", ".join(names)))
          return
      self._next_action()

  def _next_action(self):
      if not self.queue:
          self.acting = False
          self.set_busy(False, "")
          self.refresh()                     # ONCE, after the whole batch
          return False
      verb, names, purge = self.queue.pop(0)
      # fold queued jobs of the same kind into one call: one lock, one password prompt
      while self.queue and self.queue[0][0] == verb and self.queue[0][2] == purge:
          names += self.queue.pop(0)[1]
      self.acting = True
      self.set_busy(True, "%s %s…" % (verb.capitalize(), ", ".join(names)))
      self._spawn([self.nova, verb] + (["--purge"] if purge else []) + ["--"] + names,
                  lambda rc: self._action_done(rc, verb))

  def _action_done(self, rc, verb):
      self.toast("%s finished" % verb.capitalize() if rc == 0
                 else "%s failed — see the output" % verb.capitalize())
      return self._next_action()
  ```
  - `refresh()` sets `self.refreshing`, not `self.busy`; `populate()` clears it and
    calls `_next_action()` if anything was queued meanwhile. An action must not start
    while `list --check` runs: both run git in the same clones under `~/.local/share`.
  - `_mark_queued(names)`: the clicked card's/row's action button shows "Queued" and goes
    insensitive, so a click visibly did something. `populate()` rebuilds them anyway.
  - Folding consecutive same-verb jobs into one `nova install -- a b c` means one
    root confirmation and **one** password prompt (`dispatch` already batches the
    system halves into a single `as_root` call).
  - Root apps clicked one after another each get their own `_confirm_root` dialog
    before they are queued; that is fine.
- **Manual check (laptop, GUI):**
  1. Click Install on two user-only apps within a second → second toast says
     "Queued", the output pane shows **one** `nova install -- a b` (or two in sequence),
     both end up installed, the list refreshes once at the end.
  2. Click Install on an app, then Refresh while it runs → Refresh is ignored or
     queued, never runs concurrently.
  3. Install from the detail dialog while something else runs → it is queued, not lost.

---

## Phase 2 — root isolation

### H1 — a user-owned local repo becomes passwordless root code execution [read]

- **Where:** `entry_ok` (`bin/nova:650-658`) — `local=1` entries skip the ownership
  test; `install --from` (`:2451-2457`) appends any `valid_url` to
  `/etc/nova-updater/apps.list`; `data/nova-system-update:37-44` trusts every name in it.
- **What happens:** once a local path such as `/home/you/dev/app` is in root's list —
  by `nova add --system`, or by `--from`, which the **user-side** (user-writable) nova or
  the GUI composes — any process running as you can commit a new tag there and call
  `pkexec /usr/local/libexec/nova-system-update app`. Root fetches it and runs the
  installer, with no password, forever. That is invariant 1 broken through the
  passwordless channel.
- **Fix:**
  1. A helper, used by `entry_ok` for **every** non-https entry as root, whatever list
     it came from:
     ```bash
     # a local path root may follow: it and every parent root-owned, nobody else can write
     root_owned_chain() { # path
         local p; p="$(realpath -e -- "${1#file://}" 2>/dev/null)" || return 1
         while :; do
             local st owner mode
             st="$(stat -c '%u %a' -- "$p" 2>/dev/null)" || return 1
             read -r owner mode <<<"$st"
             [[ $owner == 0 ]] && (( (8#$mode & 8#022) == 0 )) || return 1
             [[ $p == / ]] && return 0
             p="$(dirname -- "$p")"
         done
     }
     ```
     (`/tmp` is 1777 and fails the test, which is correct.)
  2. `--from`: https only — `[[ $from_url == https://* ]] || die "…"`.
  3. `check_lists`: say why such an entry is ignored, naming the file.
  4. `nova doctor`: report entries in `/etc/nova-updater/apps.list` that root now ignores.
- **Migration:** someone who did `nova add --system /home/…/repo` on purpose loses it.
  Say so in the release notes, with the alternative (`git clone` it to a root-owned
  directory, or push it somewhere https).
- **Tests:** Phase 0.1 first. P36's "the system list's always" clause flips (Decision D1).
- **Check:** `tests/repro.sh H1 P36`

### M1 — a catalog can downgrade or redirect what root installs [read]

- **Where:** `app_entries_raw` (`:321-328`) passes a catalog line's options through;
  `remote_target` (`:846-876`) follows `ref=` / `branch=`; `update_one` (`:1135-1170`).
- **What happens:** for a system app root installed *from a catalog* (no line in
  `/etc/nova-updater/apps.list`), the catalog decides its ref. A compromised catalog
  commits `<url> ref=v0.9.0` and root's next passwordless update "updates" it to an old,
  vulnerable release — or `branch=<anything>` to an untagged branch.
- **Fix:**
  1. As root, strip `ref=` and `branch=` from catalog entries in `app_entries_raw`
     (keep them for local lists, `local=1`). The user scope may keep honouring them —
     the user's own catalog choice, the user's own privileges.
  2. In `update_one`, when the target is a release tag and the installed commit is also
     on a release tag, refuse to move to a lower version unless the *local* entry pins it:
     `warn "<app>: catalog asks for an older release than installed — not downgrading"`.
     The installed tag can be found with `git -C "$dir" describe --tags --exact-match`
     (root can read its own clone).
  3. Catalog README (`nova-catalog`): document that `ref=`/`branch=` in a catalog only
     apply to user-scope installs.
- **Check:** `tests/repro.sh M1`

### M6 — `INSTALLER=` and symlinked installers escape the clone [read]

- **Where:** `run_installer` (`:1014-1045`), `cmd_info --installer` (`:1778-1784`),
  `cmd_diff` (`:1992-1999`).
- **What happens:** `INSTALLER=../../../tmp/x.sh`, or an `install.sh` committed as a
  symlink, makes nova run a file outside the root-owned clone (invariant 1), and makes
  `nova diff` review a different file from the one that runs.
- **Fix:** one resolver used by all three:
  ```bash
  installer_file() { # dir -> absolute path of the installer, or fail
      local inst p; inst="$(manifest_get "$1" INSTALLER install.sh)"
      [[ $inst != /* && $inst != *..* ]] || return 1
      [[ ! -L "$1/$inst" ]] || return 1
      p="$(realpath -e -- "$1/$inst" 2>/dev/null)" || return 1
      [[ $p == "$(realpath -- "$1")"/* && -f $p ]] || return 1
      echo "$p"
  }
  ```
- **Check:** `tests/repro.sh M6`

### M7 / Q4 — `update --all` clones every repo every catalog lists [read]

- **Where:** `collect_targets` (`:1206-1239`) calls `sync_meta` for every entry before
  anything checks whether it is installed.
- **What happens:** root (via the wrapper with no arguments, i.e. every timer run in auto
  mode) clones every catalog-listed repo into `/var/lib/nova-updater/repos` — git network
  and pack parsing as root against any host a catalog names, internal hosts included —
  and the first `nova update` on a new machine is needlessly slow.
- **Fix:** for `update` (not `install`), skip entries where `! is_installed_any "$url"`
  before `sync_meta`. `install --all` keeps today's behaviour.
- **Check:** `tests/repro.sh M7 Q4`

### L1 — root still reads `NOVA_*` from the environment [read]

- **Where:** `NOVA_NET_TIMEOUT` (`:154`), `NOVA_FETCH_JOBS` (`:485`, used in
  `(( running >= max ))` — bash evaluates `a[$(cmd)]` there), `NOVA_LOCK_WAIT`,
  `NOVA_GUI`, `NOVA_DEP_STACK`.
- **What happens:** pkexec and systemd clean the environment; `sudo -E` or an `env_keep`
  does not, and `NOVA_FETCH_JOBS='a[$(…)]'` is command execution. Not a boundary crossing
  for someone who can `sudo -E` anyway, but it contradicts "root derives nothing from the
  environment" (S2) and would matter with a restricted sudoers rule.
- **Fix:** in the `EUID -eq 0` block, `unset NOVA_NET_TIMEOUT NOVA_FETCH_JOBS NOVA_LOCK_WAIT NOVA_GUI NOVA_DEP_STACK`
  (keep `NOVA_UNATTENDED`, which only ever suppresses prompts). Everywhere else, validate
  numerics before arithmetic: `[[ $max =~ ^[0-9]+$ ]] || max=4`.
- **Check:** `tests/repro.sh L1`

### L2 — harden root's git [read]

Defence in depth, no check needed beyond the suite staying green:

- Root git calls get `-c transfer.fsckObjects=true -c core.hooksPath=/dev/null`
  (put them in `GIT_CONFIG_COUNT` alongside the credential helper; `run_installer` already
  unsets that for the app's installer).
- `umask 022` at the top when `EUID` is 0, so later fetches stay world-readable — the
  `chmod -R a+rX` in `sync_repo` (`:1074`) only covers the first clone.

---

## Phase 3 — what the user is shown, and the GUI

### M4 — the user side decides what root installs, and the dialog does not say [read]

- **Where:** `dispatch` (`:1313-1316`, `--from`); `ensure_deps` (`:1734-1755`) as root;
  `_confirm_root` (`gui/nova-gui:1666-1687`).
- **What happens:** the URL root records comes from the user's view (user-writable
  catalogs, user-writable `~/.local/bin/nova`). Root then also installs any `DEPENDS`
  that are nova apps — as root. Neither the URL nor those extra apps appear in the GUI's
  root dialog or the password prompt, and from then on that URL is updated
  passwordlessly.
- **Fix:**
  1. `_confirm_root`: show, per root app, the source URL and the catalog it came from
     (append both as porcelain fields 16–17 — append only), and "also installs as root:
     …" from `info --porcelain`'s `depends_installs`.
  2. CLI escalation prints the same before `as_root`.
  3. Root side: accept `--from` only for https URLs (H1) — and see Decision D4 for
     whether to also require that a root-registered catalog lists it.
- **Check:** manual (GUI) + extend the existing F16 check to assert the URL is printed
  before escalation.

### M5 — bootstrap trusts the user's checkout [read]

- **Where:** `root_nova` (`bin/nova:44`) runs `~/.local/share/…/install.sh` as root when
  the root copy is missing — the GUI reaches this by installing any app with a root half;
  `register_self` (`install.sh:112-125`) registers **the user checkout's origin URL** as
  root's self-update source and copies `bin/nova` from the user checkout.
- **What happens:** whatever controls your account at that moment decides, permanently,
  where root's nova updates itself from.
- **Fix:**
  1. Root-side self-registration uses a hardcoded canonical URL
     (`https://github.com/schlingel-bernd/nova-updater.git`), never `origin_url`.
  2. `root_install` during bootstrap: clone that URL into `/var/lib/nova-updater/repos/nova-updater`
     as root, check out the latest release tag (the same rule as `remote_target`), and
     install `bin/nova`, the wrapper and the polkit rule **from that clone**, not from `$SRC`.
  3. The user-side `root_nova` passes nothing but `install --with-system` to it.
     The bootstrap still runs `bash <user path>/install.sh` as root once (documented
     exception), but what it installs no longer comes from the user's files.
- **Check:** extend P-check around `tests/repro.sh:576` (`self/nova-updater` registration):
  with the user checkout's origin set to a different URL, root's list must still get the
  canonical one. Needs the canonical URL to be overridable **only** by a root-owned file
  for the test (`/etc/nova-updater/self-url`), not by the environment.

### M8 — GUI handles untrusted files loosely [read]

- **Where:** screenshots (`gui/nova-gui:842-858`, `ShotDialog`); README (`:947-951`);
  homepage (`:871-876`).
- **Fix:**
  - Screenshots: same rules as `app_icon_file` (`.png`/`.jpg`/`.jpeg`/`.webp`,
    ≤ 4 MiB on disk, PNG header dimension check ≤ 4096 px), loaded off the main thread
    (see U2's texture loader).
  - README: `f.read(65536)` instead of `.read()`.
  - Homepage: only open `https://` (and `http://` if you like); otherwise show it as
    text, not activatable.
- **Check:** manual — a test app whose manifest points `SCREENSHOTS=` at a 20 MB file and
  `HOMEPAGE=file:///etc/passwd`: no screenshot, homepage row not clickable.

### U2 — icon loading looks wrong [read]

- **Where:** `populate` (`gui/nova-gui:1593-1637`), `tile` / `app_icon_file`
  (`:376-428`), both views bound to one model (`:1258`, `:1264`), `_icon_cache` (`:97-113`).
- **What happens:**
  1. Every refresh (startup, and after **every** install/update/pin/catalog change)
     does `store.remove_all()` and appends one by one: every card and row is destroyed
     and rebuilt, icons blank and reload, scroll position is lost.
  2. The grid (`FlowBox`) **and** the list (`ListBox`) are both bound to the same model,
     so every icon is decoded twice, including for the view that is not visible.
  3. Icons are stat'ed, opened and rasterised on the main thread when first drawn;
     nothing is cached across rebuilds.
  4. An app's own icon is a bare left-aligned `Gtk.Image`; the fallback is a tinted
     rounded tile — mixed shapes in one list.
  5. `_icon_cache` ignores icon-theme changes.
- **Fix:**
  1. Load textures in the worker thread that ran `nova list`, cache them:
     ```python
     from gi.repository import GdkPixbuf
     _tex = {}
     def icon_texture(path, px, scale):            # worker thread
         key = (path, os.stat(path).st_mtime_ns, px * scale)
         t = _tex.get(key)
         if t is None:
             pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, px * scale, px * scale, True)
             t = _tex[key] = Gdk.Texture.new_for_pixbuf(pb)
         return t
     ```
     (`Gdk.Texture.new_for_pixbuf` is deprecated from GTK 4.20; if the target GTK has
     `Gdk.Texture.new_from_bytes`/`Gdk.MemoryTexture`, build from `pb.read_pixel_bytes()`.)
     Pass the textures to `populate` with the parsed rows; widgets use
     `Gtk.Image.new_from_paintable(t)`, inside the same tile container as the fallback
     (tile without the tint class), so every app has the same shape and alignment.
     Use `self.get_scale_factor()` for `scale`.
  2. Replace the model in one go: build the `App` list, then
     `self.store.splice(0, self.store.get_n_items(), items)`. Better still, keep the
     existing `App` objects for unchanged rows (compare the porcelain line) so their
     widgets survive.
  3. Bind only the visible view; bind the other on the breakpoint switch
     (`_set_narrow`). With hundreds of apps, move to `Gtk.GridView`/`Gtk.ListView`
     with a `SignalListItemFactory` (recycled widgets).
  4. Clear `_icon_cache` on `Gtk.Settings` `notify::gtk-icon-theme-name`.
- **Manual check:** open the GUI, scroll halfway, install a user app: the list does not
  jump to the top, icons do not blink, every row's icon sits in the same 46 px tile.

### U3 — multi-select (optional, after U1) [design]

A "Select" toggle in the header puts a check button on each card/row; the header shows
"Install selected (n)" / "Update selected (n)". It calls `run_action(verb, selected)`,
which with U1 becomes one `nova <verb> -- a b c`, one root dialog listing every root app,
one password prompt. See Decision D5 before building it.

---

## Phase 4 — speed (CLI)

The GUI waits on `nova list --porcelain --check`; that is where the time goes.

### Q1 — one `ls-remote` per URL per run, in parallel [read]

- **Where:** `remote_target` (`:846-848`) is called from `refresh_meta`, `cmd_list`,
  `scope_target_sha`, `cmd_check`, `dry_run_plan`, `sync_repo` — the same URL is asked
  2–3 times per run, strictly one after another.
- **Fix:** a per-run cache that survives `$(…)` subshells (a temp dir, not a variable):
  ```bash
  LSR_DIR="$(mktemp -d)"; trap 'rm -rf "$LSR_DIR"' EXIT
  ls_remote() { # url -> cached `git ls-remote` output
      local k; k="$(printf '%s' "$1" | sha1sum)"; k="$LSR_DIR/${k%% *}"
      if [[ ! -f $k ]]; then
          timeout "$LS_REMOTE_TIMEOUT" git ls-remote --quiet -- "$1" > "$k.tmp" 2>/dev/null &&
              mv "$k.tmp" "$k" || { rm -f "$k.tmp"; return 1; }
      fi
      cat "$k"
  }
  ```
  `remote_target` uses `ls_remote`. `cmd_list --check` and `cmd_check` prefetch every URL
  first with the same bounded background-job loop `sync_all_meta` uses
  (`NOVA_FETCH_JOBS`, validated per L1).
- **Expected:** 15 apps, ~10–20 s → ~1–2 s.
- **Check:** `tests/repro.sh Q1`

### Q2 — the GUI shows the local state first [read]

- **Where:** `Window.refresh` (`gui/nova-gui:1577-1591`).
- **Fix:** first `nova list --porcelain --no-sync` (local only, well under a second) →
  `populate`; then `nova list --porcelain --check` in the background → update the status
  pills and the hero in place (with U2.2 that is a diff, not a rebuild). The Refresh
  button only runs the second step.
- **Manual check:** start the GUI with the network off: the list appears at once, then
  the pills turn "Unreachable".

### Q3 — fewer forks [read]

- `dir_name` (`:734-737`) starts `basename` and is called for every entry many times:
  `local b="${1%/}"; b="${b##*/}"; echo "${b%.git}"`.
- `manifest_get` runs in `$(…)` about 12 times per app in `cmd_list`. Parse each manifest
  once into an associative array (`declare -gA MF=()` keyed by `dir|KEY`), same cleaning
  rules, and read from it.
- `app_entries` is rebuilt 3–5 times per command (`check_lists`, `sync_all_meta`,
  `cmd_list`, `resolve` twice). Compute it once per invocation into an array.
- **Check:** suite stays green; measure `time nova list --porcelain --no-sync` before and
  after with ~15 apps and note it in the commit message.

---

## Phase 5 — authenticity (needs decisions first)

### H4 — nothing checks that the code root runs is authentic [read]

- **What happens:** release tags are not signature-checked; root's catalogs follow their
  default branch HEAD (`reset --hard origin/HEAD`, `:271`); the passwordless "auto" mode
  is what `get-nova.sh` installs by default; `release.yml` turns any push to `main` that
  bumps `VERSION` into a tag, with a `contents: write` token and actions pinned by tag
  (`actions/checkout@v4`), not commit. Whoever can push to `main` of any app with a
  system half, compromise an unpinned action, or take over the GitHub account gets root
  on every machine with the system scope within ~6 h, with nobody involved.
- **Fix (outline — see Decision D3):**
  1. Maintainers sign release tags locally: `git tag -s` with an SSH key
     (`gpg.format=ssh`, ideally on a hardware key). `release.yml` stops creating tags and
     only publishes a release for a pushed, signed tag (`on: push: tags: ['v*']`), and
     verifies the signature before publishing.
  2. Root keeps one allowed-signers file per app: `/etc/nova-updater/signers/<name>`.
     Trust on first use at the (authenticated) install, from the tag being installed;
     changing it needs a password (`nova trust --system <app>`).
  3. Before any system-scope install or update:
     ```bash
     git -C "$dir" -c gpg.format=ssh \
         -c gpg.ssh.allowedSignersFile="/etc/nova-updater/signers/$name" \
         verify-tag -- "$tag" || { warn "$name: $tag is not signed by its known key"; return 1; }
     ```
     Untagged apps (HEAD) and `branch=` entries cannot be verified → not updated
     passwordlessly.
  4. Pin every action in `release.yml`/`ci.yml` (and `templates/release.yml`) to a full
     commit SHA. On GitHub: protect `main` (PR + review), on `nova-catalog` too.
  5. Catalogs: optionally the same for catalog commits (`git verify-commit` on
     `origin/HEAD` against `/etc/nova-updater/signers/catalog-<name>`), refusing to move a
     root catalog to an unsigned commit.
- **Check:** new repro checks once the design is settled (unsigned tag → root refuses;
  tag signed by a different key → root refuses; correctly signed → updates).

---

## Decisions — stop and ask before these

- **D1 (H1):** P36 currently asserts that a local path in `/etc/nova-updater/apps.list`
  is *always* followed by root. H1 reverses that. Recommended: reverse it; root-owned
  local paths keep working.
  **Answered (8 Nov 2026): reverse it.** P36 is rewritten in Phase 0.
- **D2 (M2):** refuse `http://` in the user scope too, or only warn? Recommended: refuse
  everywhere — nothing in the catalog uses it.
  **Answered: refuse everywhere.**
- **D3 (H4):** SSH vs GPG signatures; TOFU vs a signer key carried in the catalog line
  (a compromised catalog could then swap keys — TOFU is safer); whether CI may sign (it
  should not; then the CI token is the signing key). Also: keep "auto" as the default
  mode in `get-nova.sh`, or default to `manual`?
  **Answered: SSH signatures (GPG acceptable but not preferred). Keep "auto"
  (passwordless root updates) as the default; it must stay switchable off — `manual`
  mode already does that, so document it next to the default.** TOFU vs catalog key and
  "CI never signs" follow the recommendation above unless revisited.
- **D4 (M4):** should root accept `--from` only when a root-registered catalog lists that
  URL? Safer, but brings back the "run `nova catalog add --system` first" step that 2.x
  removed for user-catalog apps with a root half.
  **Answered: yes, the secure option** — root accepts `--from` only for a URL a
  root-registered catalog lists (or root's own list already names).
- **D5 (U3):** multi-select in both views or only the grid; selection survives a refresh?
  **Answered: no multi-select needed for now.** U1's queue (clicks chained and folded
  into one `nova <verb> -- a b c`) covers installing several apps. U3 is dropped
  unless that turns out not to be enough.

## Not doing: a rewrite in Rust

Recorded so it does not come up again mid-way:

- The slowness is serial network round trips and process forks (Q1–Q3), fixable in bash.
- Silverblue/Bluefin have no `cargo`, so a Rust nova means shipping prebuilt per-arch
  binaries — trust moves to whoever builds them (H4 again) and "an app is a git repo with
  an install.sh" stops being true for nova itself.
- The root-side behaviour was expensive to get right (`FIXPLAN.md`, 37 P-checks).
- If it happens later: only the **root half** (wrapper + system update/install), small,
  with typed argv, signature verification and gix, after signed reproducible release
  builds exist. User CLI and GUI stay as they are.

## Release

- 2.4.0 (minor): H1, H2/H3 (stricter URL names), M1 (catalog `ref=`/`branch=` ignored as
  root), M2 (no `http://`) all change behaviour someone may rely on. Name each in the
  notes, H1's migration first.
- Before tagging: `tests/check-version.sh`, full `tests/repro.sh` in the container,
  shellcheck, `py_compile`, then on a Silverblue/Bluefin VM: GUI install of two apps in a
  row (U1), a user+system app (one password prompt), `nova update` from the timer
  (`systemctl --user start nova-updater.service`) with the system scope in auto mode.
