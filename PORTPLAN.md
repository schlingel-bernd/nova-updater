# nova — porting plan: beyond Fedora Atomic

Audit of nova-updater v2.4.0 and every app in the default catalog at its
latest release, 11 November 2026. Question: what has to change for nova and
the apps to install and work on plain Fedora, Debian, Ubuntu, Arch, openSUSE,
Alpine and WSL2, and on desktops other than GNOME.

Each statement is marked:

- **[run]**: measured in a container on this date.
- **[archive]**: package versions read from the distro's own archive.
- **[read]**: from reading the code (file:line at the app's release tag).
- **[untested]**: reasoning only. Needs a real machine.

IDs: `K*` nova-updater, `A*` apps, `C*` the catalog and manifest
convention, `T*` tests and CI.

---

## 1. Where things stand

### nova-updater itself works almost everywhere already [run]

`tests/repro.sh` is the full suite: 72 checks with root, lists, catalogs,
pins, signed releases and the wrapper.

| Distro (container) | repro.sh | Real install from the network¹ |
|---|---|---|
| Fedora 43 (non-atomic) | — | ✅ |
| Debian 13 | ✅ 72/72 | ✅ |
| Ubuntu 24.04 | ✅ 72/72 | ✅ |
| Arch | ✅ 72/72 | ✅ |
| openSUSE Tumbleweed | ✅ 72/72 | ✅ |
| Alpine + GNU coreutils/util-linux/findutils | ✅ 72/72 | — |
| Alpine, stock BusyBox | ❌ 29/72 | ❌ the root bootstrap refuses; catalogs don't fetch |

¹ The real-install test, as a user: `install.sh install --cli-only`, then the real
catalog over the network, `nova doctor`. Then the root bootstrap from GitHub
(signed v2.4.0) and `nova doctor` as root. Then `nova install syncman`.

Containers have no systemd user session, no polkit agent and no display.
Those parts are covered in §2 from code and the archives.

### The GUI stack decides more than nova does [archive]

| | GTK / libadwaita | Python | pydantic | podman | polkit | GUIs (need Adw ≥ 1.5) |
|---|---|---|---|---|---|---|
| Debian 12 | 4.8 / 1.2 | 3.11 | 1.10 | 4.3 | 122 | ❌ |
| Debian 13 | 4.18 / 1.7 | 3.13 | 2.10 | 5.4 | 126 | ✅ |
| Ubuntu 22.04 | 4.6 / 1.1 | 3.10 | 1.8 | 3.4 | **0.105** | ❌ |
| Ubuntu 24.04 | 4.14 / 1.5 | 3.12 | **1.10** | 4.9 | 124 | ✅ (no Adw.WrapBox; nova-gui falls back) |
| Alpine edge | 4.22 / 1.9 | 3.14 | 2.12 | 5.8 | 127 | ✅ |
| Fedora 43, Arch, Tumbleweed | current | current | 2.x | 5.x | current | ✅ (not probed, rolling or newer than Debian 13) |

On Debian and Ubuntu the typelibs live in `/usr/lib/x86_64-linux-gnu/girepository-1.0/`.
nova and three apps only look in `/usr/lib{,64}/…`, so they never find a GUI there (see K1).

### Proposed support tiers (decision P1)

- **Tier 1.** Everything, in CI: Fedora Atomic (Silverblue/Bluefin), Fedora
  Workstation, Debian 13, Ubuntu 24.04, Arch, openSUSE Tumbleweed.
- **Tier 2.** nova and the CLI apps; GUIs where the stack allows; root
  daemons best effort: Alpine (with the GNU tools, see K5), WSL2 with
  systemd.
- **CLI only, documented.** Debian 12, Ubuntu 22.04: nova and shell-only apps
  work. The GTK apps and the podman/pydantic stack (nova-proxy, nova-fox,
  nova-custodia) do not, and nova should say so rather than fail mid-install
  (C1, C2).
- **Not a target.** WSL1, macOS.

---

## 2. nova-updater

### K1. GUI detection misses Debian/Ubuntu [run]

- **Where:**
  - `bin/nova:1125` (`gui_available`) and `install.sh:63` (`want_gui`) test `/usr/lib64/…` and `/usr/lib/…` only.
  - The same pattern sits in `nova-killswitch/install.sh:45`, `syncman/install.sh:32` and `gnome-monitor/install.sh:31` [read].
- **Effect:** on every Debian and Ubuntu, nova installs CLI-only and passes `NOVA_GUI=0` to every app.
- **Fix:** ask the interpreter rather than the filesystem, and check the version the GUIs actually need:
  ```bash
  python3 -c 'import gi; gi.require_version("Gtk","4.0"); gi.require_version("Adw","1")
  from gi.repository import Adw; import sys; sys.exit(Adw.get_minor_version() < 5)' 2>/dev/null
  ```
  Then add the same check to the `nova-gui` startup, with a plain message when it fails.

### K2. The passwordless rule only knows `wheel`, and needs polkit ≥ 0.106

- **Where:** `data/polkit/50-nova-updater.rules` uses `subject.isInGroup("wheel")`.
- **Effect:**
  - Debian and Ubuntu put admins in `sudo`; `wheel` doesn't exist there. Auto mode silently never works: every system update asks for the password, or is skipped by the timer [read].
  - Ubuntu 22.04's polkit 0.105 doesn't read `.rules` files at all [archive].
- **Fix:**
  - Install time: pick the admin group (`wheel` if it exists, else `sudo`, else `admin`) and write it into the rule.
  - On polkit < 0.106, fall back to manual mode with a message, or ship a `.pkla`. Recommended: manual mode; 22.04 is CLI-only anyway.
  - Same bug in nova-killswitch's D-Bus policy (A1).

### K3. No polkit, no `pkexec`: WSL, servers, Alpine minimal [read]

- **Where:**
  - `as_root` (`bin/nova`) knows `sudo` (with a tty) and `pkexec`. Alpine's default is `doas`. systemd 256+ has `run0`.
  - Auto mode exists only as a polkit rule.
- **Fix:**
  - `as_root`: sudo → doas → run0 → pkexec, by what exists and whether there is a tty.
  - Auto mode without polkit: a sudoers drop-in such as `%<admin> ALL=(root) NOPASSWD: /usr/local/libexec/nova-system-update`, or `doas.conf` (`permit nopass :wheel as root cmd /usr/local/libexec/nova-system-update`). Its `--` / name validation is already the security boundary, exactly as with polkit.
  - `install.sh` picks the mechanism; `nova doctor` reports which one is active.

### K4. No systemd user session: Alpine/OpenRC, WSL without systemd, containers [run]

- **Where:** `install.sh` user phase: background updates are "NOT enabled" (it says so, correctly).
- **Fix:** offer a fallback instead of nothing.
  - A crontab entry (`@daily … nova update --all --quiet`) where `crontab` exists.
  - Otherwise an XDG autostart entry that runs the update once per login.
  - `nova doctor` already notices; let it name the fallback.

### K5. BusyBox (Alpine's default userland) [run]

- **Failing applets:**
  - `timeout --kill-after=N`. `-k N` works everywhere, GNU included, so switch to it.
  - `realpath -e`, `realpath -m` (BusyBox takes no options).
  - `flock -w`.
  - `find -uid`.
  - `sed` with byte ranges (`\xc2[\x80-\x9f]`).
- **Effect:** 43/72 checks fail. The root bootstrap refuses (`install.sh` `running_from_root_clone` → `realpath -m`), and every networked git call fails through `git_net`.
- **Recommended fix (decision P2):** require the GNU tools on Alpine, rather than porting the security-sensitive path code to BusyBox semantics.
  - That means `apk add bash git coreutils util-linux findutils sed grep openssh-keygen`.
  - With them, 72/72 pass [run].
  - nova and `get-nova.sh` should detect BusyBox (`realpath --version` fails) and print that one line instead of failing halfway.
  - Also switch `timeout --kill-after` → `timeout -k`. It's free.

### K6. Fedora-specific wording and hints [read]

- **Where:**
  - `bin/nova:2897` says "git is required (rpm-ostree install git)".
  - `get-nova.sh` says "in the base image on Silverblue/Bluefin".
  - `install.sh` messages mention ostree.
  - Several apps print `rpm-ostree` / `pip install --user` hints. pip fails under PEP 668 on Debian 12+, Ubuntu 24.04, Arch and Alpine.
- **Fix:** one `pkg_hint <pkgs…>` helper that detects rpm-ostree / dnf / apt / pacman / zypper / apk and prints the right command and package names. Ship it in nova; apps can call `nova pkg-hint` or copy it.

| need | Fedora | Debian/Ubuntu | Arch | openSUSE | Alpine |
|---|---|---|---|---|---|
| nova | git | git | git | git-core | bash git coreutils util-linux findutils sed grep |
| signatures (H4) | openssh-clients | openssh-client | openssh | openssh-clients | openssh-keygen |
| nova-gui | python3-gobject libadwaita | python3-gi gir1.2-adw-1 | python-gobject libadwaita | python3-gobject typelib-1_0-Adw-1 | py3-gobject3 libadwaita |

### K7. The first `nova list` after install shows no catalog apps [run]

- **What happens:** on every distro, a fresh install's `nova list` printed only nova-updater. `cmd_list` syncs catalogs only with `--check`, and nothing had fetched the default catalog yet. `nova install <app>` works, because it syncs.
- **Fix:** in `cmd_list`, sync when a registered catalog has no clone yet. That's cheap, because it happens once.

### K8. `~/.local/bin` not on PATH [untested]

- **Where:** Arch's and Alpine's default shell profiles don't add `~/.local/bin`. Debian's `~/.profile` adds it only if it existed at login.
- **Fix:** `install.sh` checks `PATH` after the user phase and prints the line to add, or the command to re-login.

### K9. Desktop integration on KDE / XFCE / headless [read]

- **Already right:**
  - The GNOME app-folder code is skipped where `gsettings` / the schema is missing.
  - `notify-send` is optional.
  - The `.desktop` file and hicolor icon work on every freedesktop desktop.
  - `nova-gui` (libadwaita) runs on KDE and XFCE. It looks like GNOME there, which is fine.
- **Missing:**
  - A tray/status indicator for "updates ready" off GNOME, through StatusNotifierItem. That's nice-to-have, not needed.
  - On KDE, `Adw` follows `org.freedesktop.appearance` through the portal when `xdg-desktop-portal-kde` runs. Leave it alone.

### K10. WSL2 [untested]

- **Expected to work:**
  - The CLI and user scope; with systemd enabled (the default for new Ubuntu WSL installs), the user timer too.
  - `nova-gui` through WSLg.
- **Unknown:**
  - Whether polkit treats a WSL login as `subject.active`. If not, the auto rule never matches, and K3's sudoers route is the answer.
  - Notifications.
- **Needs one real WSL2 Ubuntu 24.04 run:** `get-nova.sh`, `nova-gui`, `nova install syncman`, a timer run.

---

## 3. The catalog and manifest convention

### C1. Apps can't say what they need beyond commands (decision P3)

- **The gap:** `DEPENDS=` lists commands only. What actually breaks on the older distros is:
  - libadwaita ≥ 1.5 (every GUI)
  - pydantic 2 (nova-proxy, nova-fox, nova-custodia)
  - podman ≥ 4.7 with pasta (the same three)
  - Python ≥ 3.12 (nova-proxy's f-string)
  - systemd (killswitch, syncman, nova-proxy's timers)
  - NetworkManager (killswitch)
  - GNOME Shell (gnome-monitor, the extensions)

  None of it is visible before the installer runs.
- **Proposal:** a `REQUIRES=` field with a small, fixed vocabulary nova can check itself, never shell:
  ```
  REQUIRES=systemd networkmanager python>=3.12 podman>=4.7 adw>=1.5 pydantic>=2 desktop=gnome
  ```
- **What nova does with it:**
  - `nova list` and the GUI mark the app "not supported here: needs …".
  - `install` refuses with the reason.
  - `info` shows it.
  - `GUI_REQUIRES=adw>=1.5` lets nova install the CLI half and skip the GUI half on Debian 12, instead of the app's `want_gui` guessing.

### C2. Bluefin-only apps

- **ensconce** is a Bluefin-DX post-install provisioner: `ujust`, `rpm-ostree`, `/etc/yum.repos.d`, `update-ca-trust`, `/var/lib/gdm` [read]. Porting it would mean rewriting it per distro.
- **Recommendation (decision P4):** declare `REQUIRES=rpm-ostree` (C1) so nova hides it elsewhere.

---

## 4. The apps

Effort: S < 1 day, M a few days, L a week or more. Each app's fixes are its
own commits in its own repo.

### A1. nova-killswitch (root nftables daemon, CLI, GTK settings app, GNOME extension)

- **D-Bus policy:** `data/dbus/eu.novanetwork.KillSwitch.conf:34` and `install.sh:182` allow only `wheel`, so every call is denied on Debian/Ubuntu [read]. Pick the group at install time, as in K2.
- **Hardcoded sudo:** `bin/nova-killswitch:88` hardcodes `sudo`; use the same chain as K3.
- **DNS:** steering assumes systemd-resolved (`daemon/nova-killswitchd:1880+`).
  - Debian, Arch, Tumbleweed and Alpine don't run it by default [read].
  - The port-53 backstop probably fails closed, with no DNS off the tunnel [untested].
  - Fix: a resolv.conf / NetworkManager-DNS mode, or `REQUIRES=systemd-resolved`.
- **NetworkManager:** required. Ubuntu Server (netplan/networkd), minimal Arch and Alpine don't have it. → `REQUIRES=networkmanager`.
- **WSL:** the Windows host owns routing; not a target.
- **No systemd:** OpenRC needs an init script. L; only if Alpine is wanted for this app.
- **Kernel:** the paranoid netdev egress hook needs kernel ≥ 5.16. Ubuntu 22.04's 5.15 uses the fallback the daemon already has [read].
- **Extension:** `metadata.json` declares GNOME Shell 45–50 [read].
  - Debian 12 (43) and Ubuntu 22.04 (42) can't load it.
  - Off GNOME, the daemon, CLI and settings app still work.
  - Equivalent: a StatusNotifierItem tray app (KDE native, XFCE through its SNI plugin).
- **Effort:** M; L with OpenRC.

### A2. nova-proxy (gateway containers in rootless podman) and its four plugins

- **Debian 12, Ubuntu 22.04:** unsupported by their stack [archive].
  - Python 3.11/3.10 can't parse `cli.py:247`.
  - pydantic 1.x.
  - podman 4.3/3.4: no pasta, no `secret create --replace`.
- **Ubuntu 24.04:** pydantic is 1.10 [archive]. `install.sh` must build a venv with pydantic 2 under its lib dir; needs `passt`.
- **Debian 13, Arch, Tumbleweed, Fedora Workstation:** packages only.
- **Alpine:** packages are current [archive]; needs subuid/subgid, the `cgroups` service and `modprobe tun` [read].
- **No systemd:** `install.sh:113-147` installs units and continues with `|| true`, so the blocklist timer silently never runs. Refresh stale blocklists on `up`, or use cron.
- **Keyring:** `secrets.py:173` uses the keyring whenever `secret-tool` exists. On XFCE, headless or WSL nothing answers on D-Bus, and `store` fails. Probe the Secret Service and fall back to files.
- **Terminals:** the list (`ui/window.py:634`) lacks `xfce4-terminal` and `x-terminal-emulator`; or use `xdg-terminal-exec`.
- **Plugins:** pure bash installers, so they work wherever nova-proxy does.
  - vpn and myst need `/dev/net/tun` and NET_ADMIN in rootless mode. On WSL2 and Alpine kernels [untested].
  - **9proxy bug on every distro:** `install.sh:37` (`rm -rf "$DEST"`) deletes the user's vendor folder on every update.
- **podman only:** no docker fallback (podman secrets, `--userns keep-id`, pasta). Document it; don't port.
- **Effort:** nova-proxy M; each plugin S.

### A3. nova-fox (browsers in rootless podman)

- **X11 sessions:**
  - Only the Wayland socket is passed (`core/launch.py:284-293`, `:563`), and `entrypoint.sh:34` forces Wayland.
  - So XFCE and Plasma on X11 don't work, although the README says X11 does [read].
  - Fix: mount `/tmp/.X11-unix` with `DISPLAY`/`XAUTHORITY` when there is no Wayland socket. nova-custodia's `session.py:49-58` already does this.
- **Ubuntu 24.04:** pydantic 2 venv (as A2), `passt`.
- **Debian 12, Ubuntu 22.04:** unsupported (as A2).
- **`secret-tool`:** a hard DEPENDS (`nova.manifest:22`), although the code already handles it missing. Make it optional.
- **Undeclared:** `gpg`/`gpgv` are used but not in DEPENDS.
- **Dark mode:** read from GNOME gsettings only (`core/desktop.py:30`); read `org.freedesktop.appearance` through the portal.
- **Works already:**
  - WSLg's Wayland socket.
  - Software rendering without `/dev/dri`.
  - The `systemd-run` fallback.
  - SELinux flags, which are no-ops elsewhere.
- **Effort:** M.

### A4. nova-custodia (distro boxes behind nova-proxy)

- **Ubuntu 24.04:** pydantic and Adw as A2/A3.
- **Undeclared:** `catatonit`. It's a separate package on Alpine and only a Recommends on Debian.
- **Terminals:** the terminal list misses `xfce4-terminal` and `x-terminal-emulator`.
- **WSLg sound:** only `$XDG_RUNTIME_DIR/pulse/native` is checked; honour `$PULSE_SERVER`.
- **Already portable:** X11 and Wayland passthrough, no systemd, no host package manager [read].
- **Effort:** S–M.

### A5. nova-server (fleet configs, install ISOs, SSH management; user scope)

- **GUI:** `Adw.ButtonRow` and `Adw.Spinner` need libadwaita 1.6, and `install.sh` only checks that Adw exists [read].
  - Ubuntu 24.04 (1.5) installs the GUI, which then fails. Check `Adw ≥ 1.6` (C1 `GUI_REQUIRES`).
- **Install hints:** `install.sh:45,47` and `cli.py:1782` hint `rpm-ostree` / `pip --user`; use K6 package names.
- **cpio:** `lib/novaserver/iso.py:263` runs `cpio -A` on the host, never in its toolchain container. BusyBox cpio has no `-A`. Route it through the toolchain.
- **No systemd:** `backup.py:259-283` calls `systemctl --user` unguarded.
- **WSL without a file manager:** `gui:2654` `launch_default_for_uri` has no error handling.
- **Already portable:** podman and docker are both supported; nothing runs as root locally.
- **Effort:** S (M if the GUI must also run on libadwaita < 1.6).

### A6. syncman (two-way rsync folders as systemd user services, plus a panel)

- **No systemd:** the units can't run. Fall back to XDG autostart or a supervised loop.
- **GUI:** the panel needs Adw ≥ 1.5.
- **Already portable:** `syncjob` itself [read]; the install ran on five distros [run].
- **Effort:** S (M with the non-systemd fallback).

### A7. gnome-monitor (display layout profiles)

- **GNOME only by design:** Mutter's DisplayConfig D-Bus API [read]. → `REQUIRES=desktop=gnome`.
- **Equivalents elsewhere:** a KDE backend through `kscreen-doctor` is L; `xrandr` on XFCE/X11 is L.
- **Effort:** S (declare it); L (other backends).

### A8. nova-cli-tools-desktop (pweb, select-server, tethering, torlink)

- **DEPENDS:** `nova.manifest:18` makes `podman` and `iptables` hard dependencies for all four tools.
  - Debian 13 ships nftables without the `iptables` command by default [untested]. Make them per tool.
- **tethering:** uses `iptables -j TTL` and hardcodes `sudo`.
  - nft fallback: `ip ttl set 64` plus the IPv6 hop limit.
  - Use the K3 root chain.
- **Effort:** S.

### A9. ensconce: see C2.

---

## 5. Tests and CI

- **T1:** run `tests/repro.sh` in CI on Fedora, Debian 13, Ubuntu 24.04, Arch, Tumbleweed and Alpine-with-GNU (a matrix job). All pass today, so this only guards against regressions.
  - Mount with `:z` when containers run in parallel: `:Z` relabels the mount privately and the other containers lose access.
- **T2:** a smoke job per distro that does the real networked install used for this audit:
  - user install
  - real catalog
  - root bootstrap from the signed release
  - one real app

  Worth adding as `tests/smoke.sh`; the audit's version lived in a scratch
  directory and is not committed.
- **T3:** a BusyBox job that asserts nova stops with K5's clear message, not halfway.
- **T4:** manual, once per tier-2 target: WSL2 Ubuntu 24.04 (K10), and Alpine on real hardware with OpenRC (K4).

---

## 6. Decisions (answered 11 Nov 2026)

- **P1 — tiers:** as §1. Debian 12 and Ubuntu 22.04 are **CLI only,
  documented**: nova and shell-only apps work; GUI and podman apps report
  "not supported here" through C1 instead of failing mid-install.
- **P2 — Alpine:** **require the GNU tools** (K5). nova and `get-nova.sh`
  detect BusyBox and print the one `apk add` line.
- **P3 — manifest:** **`REQUIRES=` / `GUI_REQUIRES=` with a fixed vocabulary**
  nova checks itself (C1) — never a script from the app.
- **P4 — single-platform apps:** **declare and hide**: ensconce
  `REQUIRES=rpm-ostree`, gnome-monitor `REQUIRES=desktop=gnome`.
- **P5 — nova-killswitch:** **systemd only, declared**
  (`REQUIRES=systemd networkmanager`); no OpenRC init script.
- **P6 — container apps:** **podman only, documented**
  (`REQUIRES=podman>=4.7`); no docker fallback.

Consequences for the work items: K4's OpenRC part shrinks to the user-timer
fallback (cron / autostart) for nova itself; A1's OpenRC work and every docker
port are dropped; C1 becomes the first thing to build after nova's own fixes,
since most app-side items reduce to declaring requirements.

## Status

- **nova-updater 2.5.0 (branch `port-plan`):** K1, K2, K5 (P2), K6, K7, K8,
  T1–T3 done; plus awk/find/ssh-keygen named up front (found by T2). All six
  CI distros pass repro.sh and smoke.sh.
- **Open:** C1 (`REQUIRES=`), the per-app items, K3/K4 (doas/run0/sudoers,
  non-systemd timer fallback), K10/T4 (a real WSL2 and Alpine run).

## 7. Suggested order

1. **nova-updater 2.5.0:**
   - K1, K2 (admin group), K5 (`timeout -k` plus the BusyBox message), K6, K7, K8.
   - T1, T2.

   These make nova itself tier 1 on every listed distro with small changes.
2. **The manifest convention:** C1 in nova, then `REQUIRES=` in each app's manifest. From then on, unsupported apps say so instead of failing.
3. **Per-app fixes, most-used first:**
   - A1's group bug, A2's 9proxy bug: S, and they break real installs today.
   - Then the pydantic venv for Ubuntu 24.04 (A2–A4), X11 for nova-fox (A3), the terminal lists, the keyring probe.
4. **K3/K4:** doas/run0/sudoers and the non-systemd timer fallbacks. Then the WSL2 and Alpine runs (T4).
5. **Later:** a StatusNotifier tray (K9), KDE/X11 backends for the GNOME-only apps.
