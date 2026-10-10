#!/usr/bin/env bash
# tests/repro.sh — reproduces the findings in FIXPLAN.md against the working tree.
#
# Every check asserts BEHAVIOUR, not message text, so it prints
#     BUG  <id>   while the problem is still there
#     ok   <id>   once it is fixed
# and exits non-zero while any BUG is left.
#
# DESTRUCTIVE: it needs root, creates a user called "novatest", and wipes
# /etc/nova-updater, /var/lib/nova-updater and /usr/local/bin/nova.
# Run it in a throwaway container, never on your real machine:
#
#   podman run --rm -v "$PWD":/src:ro,Z fedora:latest bash -c \
#     'dnf -y -q install git-core gawk util-linux shadow-utils procps-ng python3 >/dev/null && bash /src/tests/repro.sh'
#
# gawk matters: fedora:latest ships no awk, and without it remote_target fails
# on every app, so checks "pass" because nothing can be reached at all.
#
#   bash tests/repro.sh F1 F6      # run only some checks (F9 runs as part of F8)
set -uo pipefail

if [[ ! -f /run/.containerenv && ! -f /.dockerenv && ${NOVA_REPRO_FORCE:-0} != 1 ]]; then
    echo "refusing to run outside a container (set NOVA_REPRO_FORCE=1 if this box is disposable)" >&2
    exit 2
fi
[[ $EUID -eq 0 ]] || { echo "must run as root (inside the container)" >&2; exit 2; }
for c in git awk sed grep flock timeout runuser useradd pkill; do
    command -v "$c" >/dev/null || { echo "missing: $c (the suite would report false passes without it)" >&2; exit 2; }
done

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f $SRC/bin/nova ]] || SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f $SRC/bin/nova ]] || { echo "cannot find bin/nova next to this script" >&2; exit 2; }

T=novatest; TH=/home/$T
W=/opt/nova-under-test; STUBS=/opt/nova-stubs; GITROOT=/srv/nova-git; ESC=/tmp/kt-escalations.log
K=$W/bin/nova

id $T >/dev/null 2>&1 || useradd -m -s /bin/bash $T
git config --system safe.directory '*'
git config --system user.email t@example.com
git config --system user.name tester
git config --system init.defaultBranch main
rm -rf $W && mkdir -p $W $STUBS && cp -r "$SRC"/. $W/ && rm -rf $W/.git && chmod -R a+rX $W

stub_systemctl() { printf '#!/bin/sh\nexit %s\n' "${1:-0}" > $STUBS/systemctl; chmod +x $STUBS/systemctl; }
stub_systemctl 0
# pkexec/sudo stub: records what would have been run as root, runs nothing
printf '#!/bin/sh\necho "$*" >> %s\nexit 126\n' "$ESC" > $STUBS/pkexec
cp $STUBS/pkexec $STUBS/sudo; chmod +x $STUBS/pkexec $STUBS/sudo

ku() { runuser -u $T -- env -i HOME=$TH USER=$T PATH=$STUBS:/usr/bin:/bin NOVA_LOCK_WAIT=3 ${KENV:-} bash $K "$@" </dev/null; }
kr() { env -i HOME=/root USER=root PATH=$STUBS:/usr/sbin:/usr/bin:/bin NOVA_LOCK_WAIT=3 ${KENV:-} bash $K "$@" </dev/null; }
urepo() { echo "$TH/.local/share/nova-updater/repos/$1"; }

reset() {
    pkill -u $T sleep 2>/dev/null
    rm -rf $TH/.config/nova-updater $TH/.config/systemd $TH/.local /etc/nova-updater /var/lib/nova-updater \
           /root/.config/nova-updater /usr/local/bin/nova /usr/local/libexec/nova-system-update \
           $GITROOT /tmp/kt-*
    mkdir -p $GITROOT; chown $T $GITROOT; : > $ESC; chmod 666 $ESC
}

# mkapp owner name "SCOPES" [installer-body] [tag]
mkapp() {
    local o=$1 n=$2 sc=$3 body=${4:-'echo "installer: $* scope=$NOVA_SCOPE"'} tag=${5:-v1.0.0}
    local w=/tmp/kt-work-$o-$n; rm -rf "$w"; mkdir -p "$w" $GITROOT/"$o"
    ( cd "$w" && git init -q &&
      printf 'NAME=%s\nDESCRIPTION=desc of %s\nVERSION=%s\nCOMPONENTS=cli gui\nSCOPES=%s\n' "$n" "$n" "${tag#v}" "$sc" > nova.manifest &&
      printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$body" > install.sh &&
      git add -A && git commit -qm init && git tag -a "$tag" -m "$tag" &&
      git clone -q --bare . $GITROOT/"$o"/"$n".git && git remote add origin $GITROOT/"$o"/"$n".git )
    chown -R $T $GITROOT/"$o" "$w"
}
release() { # owner name tag
    ( cd /tmp/kt-work-"$1"-"$2" && sed -i "s/^VERSION=.*/VERSION=${3#v}/" nova.manifest &&
      git commit -qam "release $3" && git tag -a "$3" -m "$3" && git push -q origin HEAD --tags )
}
mkcat() { # owner name url...
    local o=$1 n=$2; shift 2; local w=/tmp/kt-cat-$o-$n; rm -rf "$w"; mkdir -p "$w" $GITROOT/"$o"
    ( cd "$w" && git init -q && printf '%s\n' "$@" > apps.list &&
      printf 'NAME=%s\nDESCRIPTION=test catalog\n' "$n" > catalog.manifest &&
      git add -A && git commit -qm cat && git clone -q --bare . $GITROOT/"$o"/"$n".git )
    chown -R $T $GITROOT/"$o"
}

BUGS=0
bug() { printf 'BUG  %-4s %s\n' "$1" "$2"; BUGS=$((BUGS+1)); }
ok()  { printf 'ok   %-4s %s\n' "$1" "$2"; }
check() { # id description condition-that-means-FIXED...
    local id=$1 d=$2; shift 2
    if "$@"; then ok "$id" "$d"; else bug "$id" "$d"; fi
}
want() { [[ $# -eq 0 ]] && return 0; local x; for x in "$@"; do [[ $x == "$CUR" ]] && return 0; done; return 1; }
ONLY=("$@")
run() { CUR=$1; want ${ONLY[@]+"${ONLY[@]}"} || return 0; reset; "t_$1" 2>/tmp/kt-stderr.log; }

# ---------------------------------------------------------------------------
t_F1() { # a failing installer must not be recorded as installed
    mkapp a bad user 'echo about-to-fail; false'
    ku add $GITROOT/a/bad.git >/dev/null
    ku install bad >/dev/null; local rc=$?
    f() { [[ $rc -ne 0 && ! -f $(urepo bad)/.nova-installed ]]; }
    check F1 "failed installer -> non-zero exit and no installed marker" f
}

t_F2() { # a failing uninstaller must not throw away the clone
    mkapp a app2 user 'if [[ $1 == uninstall ]]; then exit 1; fi; mkdir -p "$NOVA_PREFIX/bin"; touch "$NOVA_PREFIX/bin/app2"'
    ku add $GITROOT/a/app2.git >/dev/null; ku install app2 >/dev/null
    ku uninstall app2 >/dev/null; local rc=$?
    f() { [[ $rc -ne 0 && -d $(urepo app2) ]]; }
    check F2 "failed uninstaller -> non-zero exit and the clone is kept" f
}

t_F3() { # install.sh must only forward --purge when it was given
    runuser -u $T -- env -i HOME=$TH PATH=$STUBS:/usr/bin:/bin bash $W/install.sh uninstall --with-system </dev/null >/dev/null 2>&1
    f() { ! grep -q -- '--purge' $ESC; }
    check F3 "install.sh uninstall --with-system does not purge the system scope" f
}

t_F4() { # the root-owned nova must be able to update itself from the timer
    local w=/tmp/kt-work-self; mkdir -p $w $GITROOT/d
    cp -r $W/. $w/
    ( cd $w && git init -q && git add -A && git commit -qm one && git tag -a v0.0.1 -m v0.0.1 &&
      git commit -q --allow-empty -m two && git tag -a v0.0.2 -m v0.0.2 &&
      git clone -q --bare . $GITROOT/d/nova-updater.git )
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    echo "$GITROOT/d/nova-updater.git" > /etc/nova-updater/apps.list
    local r=/var/lib/nova-updater/repos/nova-updater
    git clone -q $GITROOT/d/nova-updater.git $r && git -C $r checkout -q v0.0.1
    git -C $r rev-parse HEAD > $r/.nova-installed
    kr update --all --system --quiet >/dev/null; local rc=$?
    f() { [[ $rc -eq 0 && "$(git -C $r rev-parse HEAD)" == "$(git -C $w rev-parse 'v0.0.2^{commit}')" ]]; }
    check F4 "root timer run updates the root-owned nova-updater and exits 0" f
}

t_F5() { # update must not ask for root on behalf of system apps that are not installed
    mkapp a usertool user; mkapp a rootsvc "user system"
    mkcat c cat1 $GITROOT/a/usertool.git $GITROOT/a/rootsvc.git
    ku catalog add $GITROOT/c/cat1.git >/dev/null 2>&1
    ku install usertool >/dev/null
    : > $ESC
    ku update >/dev/null; local rc=$?
    f() { [[ $rc -eq 0 && ! -s $ESC ]]; }
    check F5 "'nova update' with no system app installed never escalates" f
}

t_F6() { # a process the installer leaves behind must not keep the scope lock
    mkapp a daemonish user '(sleep 30 >/dev/null 2>&1 &)'
    mkapp a other user
    ku add $GITROOT/a/daemonish.git >/dev/null; ku add $GITROOT/a/other.git >/dev/null
    ku install daemonish >/dev/null
    ku install other >/dev/null; local rc=$?
    f() { [[ $rc -eq 0 ]]; }
    check F6 "lock is free after an installer leaves a background process" f
}

t_F7() { # 'nova install' with no arguments must not install the whole catalog
    mkapp a one user; mkapp a two user
    mkcat c cat1 $GITROOT/a/one.git $GITROOT/a/two.git
    ku catalog add $GITROOT/c/cat1.git >/dev/null 2>&1
    ku install >/dev/null
    f() { [[ ! -f $(urepo one)/.nova-installed && ! -f $(urepo two)/.nova-installed ]]; }
    check F7 "bare 'nova install' installs nothing (needs a name or --all)" f
}

t_F8() { # F8 + F9 share a setup: a system app from a catalog, seen by the user
    mkapp a rootsvc system
    mkcat c cat1 $GITROOT/a/rootsvc.git
    mkdir -p /etc/nova-updater; echo $GITROOT/c/cat1.git > /etc/nova-updater/catalogs.list
    ku catalog add $GITROOT/c/cat1.git >/dev/null 2>&1
    ku list >/dev/null 2>&1
    kr install --system rootsvc >/dev/null
    release a rootsvc v1.1.0
    ku check >/dev/null; local rc=$?
    f9() { [[ $rc -eq 10 ]]; }
    check F9 "'nova check' reports a pending update of a catalog system app (exit 10)" f9
    kr update --system rootsvc >/dev/null
    local line; line="$(ku list --porcelain --check 2>/dev/null | grep '^rootsvc')"
    f8() { [[ "$(cut -f4 <<<"$line")" == installed && "$(cut -f5 <<<"$line")" == 1.1.0 ]]; }
    check F8 "after the system update the user sees it as installed at 1.1.0" f8
}

t_F10() { # only version tags are releases; a pre-release must not beat its release
    mkapp a tagged user
    ( cd /tmp/kt-work-a-tagged && git tag -a v2.0.0-rc1 -m rc &&
      git commit -q --allow-empty -m final && git tag -a v2.0.0 -m final &&
      git commit -q --allow-empty -m wip && git tag wip-test && git push -q origin HEAD --tags )
    ku add $GITROOT/a/tagged.git >/dev/null; ku install tagged >/dev/null
    f() { [[ "$(git -C "$(urepo tagged)" rev-parse HEAD 2>/dev/null)" == "$(git -C /tmp/kt-work-a-tagged rev-parse 'v2.0.0^{commit}')" ]]; }
    check F10 "latest release is v2.0.0, not v2.0.0-rc1 or a non-version tag" f
}

t_F11() { # two catalogs whose repo names collide
    mkapp a alpha user; mkapp b beta user
    mkcat org1 catalog $GITROOT/a/alpha.git; mkcat org2 catalog $GITROOT/b/beta.git
    ku catalog add $GITROOT/org1/catalog.git >/dev/null 2>&1
    ku catalog add $GITROOT/org2/catalog.git >/dev/null 2>&1; local rc=$?
    local names; names="$(ku list --porcelain 2>/dev/null | cut -f1)"
    # fixed = either the second add is refused, or both catalogs really work
    f() { [[ $rc -ne 0 ]] || grep -qx beta <<<"$names"; }
    check F11 "second catalog with the same repo name is refused or fully usable" f
}

t_F11b() { # an installed app must not be silently re-pointed at another repo
    mkapp a shifty user 'echo "installer from A"'
    ku add $GITROOT/a/shifty.git >/dev/null
    ku install shifty >/dev/null
    # a different repo, same basename, with a visibly different installer
    mkapp b shifty user 'touch /tmp/kt-ran-from-B'
    echo "$GITROOT/b/shifty.git" > $TH/.config/nova-updater/apps.list
    ku install shifty >/dev/null 2>&1; local rc=$?
    f() { [[ $rc -ne 0 && ! -e /tmp/kt-ran-from-B ]]; }
    check F11b "an installed app is not silently reinstalled from a changed URL" f
}

t_F12() { # --cli-only must survive more than one update
    mkapp a flav user 'echo "NOVA_GUI=$NOVA_GUI"'
    ku add $GITROOT/a/flav.git >/dev/null
    ku install flav --cli-only >/dev/null
    release a flav v1.0.1; KENV="NOVA_GUI=1" ku update flav >/dev/null
    release a flav v1.0.2
    local out; out="$(KENV="NOVA_GUI=1" ku update flav)"
    f() { grep -q 'NOVA_GUI=0' <<<"$out"; }
    check F12 "a --cli-only install stays cli-only on the second update" f
}

t_F13() { # an unreachable remote is not "up to date"
    mkapp a net user; ku add $GITROOT/a/net.git >/dev/null; ku install net >/dev/null
    mv $GITROOT/a/net.git $GITROOT/a/net.gone
    local out; out="$(ku update net 2>&1)"
    f() { ! grep -qi 'up to date' <<<"$out"; }
    check F13 "update of an unreachable app does not claim 'up to date'" f
}

t_F14() { # --purge has to reach the app's own installer
    mkapp a cfg user 'echo "args=[$*] purge=${NOVA_PURGE:-0}"'
    ku add $GITROOT/a/cfg.git >/dev/null; ku install cfg >/dev/null
    local out; out="$(ku uninstall cfg --purge 2>&1)"
    f() { grep -Eq 'args=\[uninstall --purge\]|purge=1' <<<"$out"; }
    check F14 "'nova uninstall --purge' tells the installer to purge" f
}

t_F15() { # list files are matched by exact URL, not by substring
    mkapp a foo user; mkapp a foo-bar user
    ku add $GITROOT/a/foo-bar >/dev/null
    ku add $GITROOT/a/foo >/dev/null 2>&1; local rc=$?
    f() { [[ $rc -eq 0 ]]; }
    check F15 "adding .../foo works when .../foo-bar is already listed" f
}

t_F16() { # do not ask for a password and then say "unknown app"
    mkapp a rootsvc "user system"
    mkcat c usercat $GITROOT/a/rootsvc.git
    ku catalog add $GITROOT/c/usercat.git >/dev/null 2>&1       # user-level only
    mkdir -p /etc/nova-updater /var/lib/nova-updater
    install -Dm755 $K /usr/local/bin/nova
    : > $ESC
    ku install rootsvc >/dev/null 2>&1
    # 2.0: an install is always authenticated, so instead of refusing, the URL
    # the user was shown goes along (--from) and root records it. What must
    # NOT happen is an escalation by name alone, which is the "password, then
    # unknown app" the finding was about.
    f() { grep -q -- "install --system.*--from $GITROOT/a/rootsvc.git" $ESC; }
    check F16 "a system app root cannot resolve is handed over by URL, not by name alone" f
}

t_F17() { # installing without a systemd user session must still finish
    stub_systemctl 1
    runuser -u $T -- env -i HOME=$TH PATH=$STUBS:/usr/bin:/bin bash $W/install.sh install --cli-only </dev/null >/dev/null 2>&1
    stub_systemctl 0
    f() { [[ -f $TH/.config/nova-updater/catalogs.list ]]; }
    check F17 "install.sh completes when 'systemctl --user' is unavailable" f
}

t_F18() { # a manifest saved with CRLF line endings must still parse
    mkapp a crlf user
    ( cd /tmp/kt-work-a-crlf && sed -i 's/$/\r/' nova.manifest && git commit -qam crlf &&
      git tag -a v1.0.1 -m x && git push -q origin HEAD --tags )
    ku add $GITROOT/a/crlf.git >/dev/null
    ku install crlf >/dev/null 2>&1
    f() { [[ -f $(urepo crlf)/.nova-installed ]]; }
    check F18 "app with a CRLF manifest installs" f
}

t_F19() { # the app-folder glob has to match the ids apps actually use
    f() { ! grep -q "org\.novanetwork\.\*\.desktop" $K; }
    check F19 "sync_app_folder does not look for org.novanetwork.* (apps use eu.novanetwork.*)" f
}

t_S5() { # a name the wrapper accepts must never be able to look like an option
    # Asserted against the pattern itself: with NAME now validated in nova too,
    # there is no longer a route that gets an option-shaped name into the
    # known-apps list to test behaviourally.
    f() { grep -q '\^\[A-Za-z0-9\]\[A-Za-z0-9\._-\]\*\$' $W/data/nova-system-update; }
    check S5 "nova-system-update's name pattern cannot match an option" f
}

t_S1() { # no credential helper on ANY network call, including ls-remote
    command -v python3 >/dev/null || { echo "skip S1   (needs python3)"; return 0; }
    local port=18473 log=/tmp/kt-cred.log
    : > $log; chmod 666 $log
    printf '#!/bin/sh\necho "$*" >> %s\n' "$log" > $STUBS/cred-helper; chmod +x $STUBS/cred-helper
    python3 - "$port" <<'PY' &
import sys, http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="x"'); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
    local srv=$!; sleep 1
    mkapp a private user; ku add $GITROOT/a/private.git >/dev/null; ku install private >/dev/null
    runuser -u $T -- env HOME=$TH git config --global credential.helper $STUBS/cred-helper
    echo "http://127.0.0.1:$port/private.git" > $TH/.config/nova-updater/apps.list
    ku check >/dev/null 2>&1
    kill $srv 2>/dev/null
    runuser -u $T -- env HOME=$TH git config --global --unset credential.helper
    f() { [[ ! -s $log ]]; }
    check S1 "credential helper is never invoked (ls-remote path)" f
}

t_S2() { # root must not resolve apps from a list the user can write
    mkapp mallory evil system 'touch /tmp/kt-ran-as-root'
    mkdir -p $TH/.config/nova-updater /etc/nova-updater /var/lib/nova-updater
    echo $GITROOT/mallory/evil.git > $TH/.config/nova-updater/apps.list; chown -R $T $TH/.config
    env -i HOME=/root XDG_CONFIG_HOME=$TH/.config USER=root PATH=$STUBS:/usr/sbin:/usr/bin:/bin \
        bash $K install --system evil </dev/null >/dev/null 2>&1
    f() { [[ ! -e /tmp/kt-ran-as-root ]]; }
    check S2 "root nova ignores HOME/XDG and user-writable lists" f
}

# ---------------------------------------------------------------------------
# Phase 4 features. Not findings — these assert that what the plan asked for
# actually behaves, so the same harness covers them.
# ---------------------------------------------------------------------------
t_P1() { # pin holds a version across updates; unpin releases it
    mkapp a pinned user 'echo installing'
    ku add $GITROOT/a/pinned.git >/dev/null
    ku install pinned >/dev/null
    release a pinned v1.1.0
    ku pin pinned v1.0.0 >/dev/null 2>&1
    ku update pinned >/dev/null 2>&1
    local held; held="$(sed -n 's/^VERSION=//p' "$(urepo pinned)/nova.manifest" | head -1)"
    ku unpin pinned >/dev/null 2>&1
    ku update pinned >/dev/null 2>&1
    local freed; freed="$(sed -n 's/^VERSION=//p' "$(urepo pinned)/nova.manifest" | head -1)"
    f() { [[ $held == 1.0.0 && $freed == 1.1.0 ]]; }
    check P1 "nova pin holds a version, nova unpin releases it (held=$held freed=$freed)" f
}

t_P8() { # pinning a CATALOG app must leave the list as it found it
    mkapp a catapp user
    mkcat c cat1 $GITROOT/a/catapp.git
    ku catalog add $GITROOT/c/cat1.git >/dev/null 2>&1
    local L=$TH/.config/nova-updater/apps.list
    local before; before="$(cat $L 2>/dev/null || true)"
    ku pin catapp v1.0.0 >/dev/null 2>&1
    local pinned; pinned="$(grep -c 'ref=v1.0.0' $L 2>/dev/null || echo 0)"
    ku unpin catapp >/dev/null 2>&1
    local after; after="$(cat $L 2>/dev/null || true)"
    f() { [[ $pinned -eq 1 && "$before" == "$after" ]]; }
    check P8 "pin then unpin of a catalog app restores apps.list exactly" f
}

t_P2() { # diff shows the installer change an update would bring
    mkapp a dif user 'echo one'
    ku add $GITROOT/a/dif.git >/dev/null; ku install dif >/dev/null
    ( cd /tmp/kt-work-a-dif &&
      sed -i 's/^VERSION=.*/VERSION=1.1.0/' nova.manifest &&
      printf '#!/usr/bin/env bash\nset -euo pipefail\necho two\n' > install.sh &&
      git commit -qam two && git tag -a v1.1.0 -m v1.1.0 && git push -q origin HEAD --tags )
    local out; out="$(ku diff dif 2>&1)"
    f() { grep -q 'install.sh changes' <<<"$out" && grep -q 'echo two' <<<"$out"; }
    check P2 "nova diff shows the installer diff an update would apply" f
}

t_P3() { # info --installer prints the script before anything runs
    mkapp a shown user 'echo "the thing that runs"'
    ku add $GITROOT/a/shown.git >/dev/null
    local out; out="$(ku info --installer shown 2>&1)"
    f() { grep -q 'the thing that runs' <<<"$out" && [[ ! -f $(urepo shown)/.nova-installed ]]; }
    check P3 "nova info --installer shows the script and installs nothing" f
}

t_P4() { # --dry-run must describe the work and do none of it
    mkapp a dry user 'touch /tmp/kt-dry-ran'
    ku add $GITROOT/a/dry.git >/dev/null
    local out rc; out="$(ku install dry --dry-run 2>&1)"; rc=$?
    # and exits 0: the plan's last [[ ]] was false for any user-scope target,
    # so under set -e a dry run of a user app "failed"
    f() { [[ $rc -eq 0 && ! -e /tmp/kt-dry-ran && ! -f $(urepo dry)/.nova-installed ]] &&
          grep -q 'install.sh' <<<"$out" && grep -q 'v1.0.0' <<<"$out"; }
    check P4 "install --dry-run names the installer and ref, runs nothing, exits 0 (rc=$rc)" f
}

t_P5() { # doctor has to actually spot a stale lock and a bad list file
    mkapp a dok user
    ku add $GITROOT/a/dok.git >/dev/null; ku install dok >/dev/null
    local L=$TH/.local/share/nova-updater/lock
    mkdir -p "$(dirname $L)"; : > $L; chown -R $T "$(dirname $L)"
    # Hold the flock from a process that is NOT the pid recorded in the file:
    # the orphaned-fd case from F6, which is the only way a lock can really be
    # stuck (if the recorded holder were gone, the kernel would have released
    # it). Same host fallback acquire_lock uses, so doctor matches on it.
    setsid bash -c "exec 9<>$L; flock 9; sleep 60" >/dev/null 2>&1 &
    local holder=$!
    sleep 1
    printf '%s pid=999999 started=now\n' "$(hostname 2>/dev/null || echo unknown)" > $L
    chown $T $L
    # a system list root would ignore
    mkdir -p /etc/nova-updater; echo "# x" > /etc/nova-updater/apps.list
    chmod 666 /etc/nova-updater/apps.list
    local out rc
    out="$(ku doctor 2>&1)"; rc=$?
    kill $holder 2>/dev/null; pkill -f "flock 9" 2>/dev/null
    f() { [[ $rc -ne 0 ]] && grep -qi 'stale' <<<"$out" &&
          grep -qi 'writable by group or other' <<<"$out"; }
    check P5 "nova doctor finds a stale lock and a world-writable system list" f
}

t_P6() { # a missing dependency is named before the installer runs, and by info
    mkapp a needy user 'echo ran'
    ( cd /tmp/kt-work-a-needy && printf 'DEPENDS=definitely-not-a-real-command\n' >> nova.manifest &&
      git commit -qam deps && git tag -a v1.0.1 -m x && git push -q origin HEAD --tags )
    ku add $GITROOT/a/needy.git >/dev/null
    local ins inf
    ins="$(ku install needy 2>&1)"
    inf="$(ku info needy 2>&1)"
    f() { grep -q 'definitely-not-a-real-command' <<<"$ins" &&
          grep -q 'definitely-not-a-real-command' <<<"$inf"; }
    check P6 "a missing DEPENDS entry is reported by install and by info" f
}

t_P7() { # a shallow metadata clone must not stop you installing an OLDER tag
    # file:// rather than a bare path: git ignores --depth on local clones, so
    # a path remote would never produce the shallow clone this is about.
    mkapp a deep user 'echo "v=$(sed -n "s/^VERSION=//p" nova.manifest|head -1)"'
    release a deep v1.1.0
    release a deep v1.2.0
    ku add "file://$GITROOT/a/deep.git" >/dev/null
    ku list >/dev/null 2>&1                 # shallow metadata clone happens here
    local shallow=no
    [[ -f $(urepo deep)/.git/shallow ]] && shallow=yes
    ku pin deep v1.0.0 >/dev/null 2>&1
    ku install deep >/dev/null 2>&1; local rc=$?
    local got; got="$(sed -n 's/^VERSION=//p' "$(urepo deep)/nova.manifest" 2>/dev/null | head -1)"
    f() { [[ $rc -eq 0 && $got == 1.0.0 ]]; }
    check P7 "an older pinned tag installs from a shallow clone (shallow=$shallow got=$got)" f
}

t_P9() { # an app listed in BOTH lists must stay reachable in both scopes
    # nova-updater's own situation: a user-list entry with no scope filter plus a
    # system-list entry asking for the system scope. app_entries dedups by name,
    # so the second was thrown away and the root half became unreachable — a
    # permanent "update available" that no command could clear.
    mkapp a dual user 'echo "scope=$NOVA_SCOPE"'
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    install -Dm755 $K /usr/local/bin/nova      # something for root to escalate to
    echo "$GITROOT/a/dual.git" > /etc/nova-updater/apps.list
    ku add $GITROOT/a/dual.git >/dev/null
    ku install dual >/dev/null 2>&1
    kr install --system dual >/dev/null 2>&1
    release a dual v1.1.0
    local line scopes status
    line="$(ku list --porcelain --check 2>/dev/null | grep '^dual')"
    scopes="$(cut -f2 <<<"$line")"; status="$(cut -f4 <<<"$line")"
    : > $ESC
    ku update dual >/dev/null 2>&1
    f() { [[ $scopes == *system* && $status == update-available ]] && grep -q dual $ESC; }
    check P9 "an app in both lists shows both scopes and its root half is reachable (scopes=$scopes status=$status)" f
}

t_P10() { # the porcelain must tell the GUI which scopes are actually installed
    mkapp a dualp "user system"
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    echo "$GITROOT/a/dualp.git" > /etc/nova-updater/apps.list
    ku add $GITROOT/a/dualp.git >/dev/null
    ku install dualp --user >/dev/null 2>&1        # the user half only
    local line nf inst pinf
    line="$(ku list --porcelain --no-sync 2>/dev/null | grep '^dualp')"
    nf="$(awk -F'\t' '{print NF}' <<<"$line")"
    inst="$(cut -f13 <<<"$line")"
    ku pin dualp v1.0.0 >/dev/null 2>&1
    pinf="$(ku list --porcelain --no-sync 2>/dev/null | grep '^dualp' | cut -f14)"
    # at least 14: the porcelain is append-only, later fields may follow (P35)
    f() { [[ $nf -ge 14 && $inst == user && $pinf == v1.0.0 ]]; }
    check P10 "porcelain carries installed scopes and the pin (fields=$nf installed='$inst' pinned='$pinf')" f
}

t_P11() { # doctor has to check the user's OWN lists, not only root's
    # They decide which installers run as you, so one anybody local can write
    # is a way to get code executed as you.
    mkapp a ul user
    ku add $GITROOT/a/ul.git >/dev/null
    chmod 666 $TH/.config/nova-updater/apps.list
    local out rc
    out="$(ku doctor 2>&1)"; rc=$?
    f() { [[ $rc -ne 0 ]] &&
          grep -q "$TH/.config/nova-updater/apps.list is writable by group or other" <<<"$out"; }
    check P11 "nova doctor checks the user's own list files too" f
}

t_P12() { # `nova info` and `nova list` must agree about an app's scopes
    # They did not, for an app listed in both lists: list used effective_scopes
    # and info did not, so info reported scopes=user with no installed_system
    # line at all — and the GUI detail view, which is built from info, had no
    # root row to show for an app installed as root.
    mkapp a bothsc user 'echo "scope=$NOVA_SCOPE"'
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    echo "$GITROOT/a/bothsc.git" > /etc/nova-updater/apps.list
    ku add $GITROOT/a/bothsc.git >/dev/null
    ku install bothsc >/dev/null 2>&1
    kr install --system bothsc >/dev/null 2>&1
    local lsc isc isys
    lsc="$(ku list --porcelain --no-sync 2>/dev/null | awk -F'\t' '$1=="bothsc"{print $2}')"
    isc="$(ku info --porcelain bothsc 2>/dev/null | sed -n 's/^scopes=//p')"
    isys="$(ku info --porcelain bothsc 2>/dev/null | sed -n 's/^installed_system=//p')"
    f() { [[ "$lsc" == "$isc" && $lsc == *system* && $isys == 1 ]]; }
    check P12 "info and list agree on scopes (list='$lsc' info='$isc' installed_system='$isys')" f
}

t_P13() { # a user-side pin must not mark the root half update-available for ever
    # Each scope follows its OWN list entry: the user pins, root's list keeps
    # following releases. Comparing both markers against the deduped row's
    # (pinned) target made the root half permanently outdated — both halves
    # sat exactly where their configuration wanted them, `nova update` said
    # "up to date", and nothing cleared the indicator.
    mkapp a dualpin "user system"
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    install -Dm755 $K /usr/local/bin/nova
    echo "$GITROOT/a/dualpin.git" > /etc/nova-updater/apps.list
    ku add $GITROOT/a/dualpin.git >/dev/null
    ku install dualpin --user >/dev/null 2>&1
    kr install --system dualpin >/dev/null 2>&1
    release a dualpin v1.1.0
    ku pin dualpin v1.0.0 >/dev/null 2>&1
    kr update --all --system --quiet >/dev/null 2>&1   # roots timer, unpinned
    local st; st="$(ku list --porcelain --check 2>/dev/null | awk -F'\t' '$1=="dualpin"{print $4}')"
    f() { [[ $st == installed ]]; }
    check P13 "a pinned user half plus roots updated half is 'installed', not stuck (status=$st)" f
}

t_P14() { # `nova version` has to exit 0 on a machine without the system scope
    ku version >/dev/null 2>&1; local rc=$?
    f() { [[ $rc -eq 0 ]]; }
    check P14 "nova version exits 0 with no root copy installed (rc=$rc)" f
}

t_P15() { # a pin value that would corrupt the list file is refused
    mkapp a pv user
    ku add $GITROOT/a/pv.git >/dev/null
    mv $GITROOT/a/pv.git $GITROOT/a/pv.gone      # unreachable: nothing to disprove a typo
    ku pin pv 'v1 --force' >/dev/null 2>&1; local rc=$?
    f() { [[ $rc -ne 0 ]] && ! grep -q 'ref=' $TH/.config/nova-updater/apps.list; }
    check P15 "a pin value with whitespace is refused before touching the list" f
}

t_P16() { # the root phase of the bootstrap must register self-update even under pkexec
    # Under pkexec there is no SUDO_UID, so git refused the user-owned checkout
    # as "dubious ownership", origin_url came back empty, and the root clone
    # was never created — the root-owned nova had nothing to self-update from.
    # The harness runs root with env -i, which is exactly that environment.
    # a USER-owned git checkout (the thing under test), cloned from a
    # root-owned bare repo (so the source itself is not what trips git)
    local src=$TH/checkout; rm -rf $src $GITROOT/self
    cp -r $W $src && chown -R $T $src
    runuser -u $T -- bash -c "cd $src && git init -q && git add -A && git -c user.email=t@e -c user.name=t commit -qm x"
    mkdir -p $GITROOT/self && git clone -q --bare $src $GITROOT/self/nova-updater.git
    runuser -u $T -- git -C $src remote add origin $GITROOT/self/nova-updater.git
    # GIT_CONFIG_SYSTEM=/dev/null: the harness sets safe.directory='*' globally,
    # which would hide exactly the refusal this test is about
    env -i HOME=/root PATH=$STUBS:/usr/sbin:/usr/bin:/bin GIT_CONFIG_SYSTEM=/dev/null \
        bash $src/install.sh install >/dev/null 2>&1
    f() { grep -q 'self/nova-updater' /etc/nova-updater/apps.list 2>/dev/null &&
          [[ -f /var/lib/nova-updater/repos/nova-updater/.nova-installed ]]; }
    check P16 "root bootstrap phase registers nova's own self-update without SUDO_UID" f
}

t_P17() { # an option value from a list must never be glob-expanded
    mkapp a globby user
    ku add $GITROOT/a/globby.git >/dev/null
    sed -i 's|globby.git$|globby.git ref=*|' $TH/.config/nova-updater/apps.list
    # files in nova's cwd that a glob would pick up
    mkdir -p $TH/cwd && touch $TH/cwd/v1.0.0 $TH/cwd/v9.9.9
    local out
    out="$(cd $TH/cwd && ku info globby 2>&1)"
    f() { grep -q 'pinned.*\*' <<<"$out" && ! grep -q 'v9.9.9' <<<"$out"; }
    check P17 "ref=* in a list stays a literal star and is not globbed against the cwd" f
}

t_P18() { # --force cannot ride the passwordless wrapper, so it must escalate directly
    mkapp a frc "user system"
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos /usr/local/libexec
    install -Dm755 $K /usr/local/bin/nova
    printf '#!/bin/sh\necho "WRAPPER $*" >> %s\nexit 0\n' "$ESC" > /usr/local/libexec/nova-system-update
    chmod +x /usr/local/libexec/nova-system-update
    echo "$GITROOT/a/frc.git" > /etc/nova-updater/apps.list
    ku add $GITROOT/a/frc.git >/dev/null
    ku install frc --user >/dev/null 2>&1
    kr install --system frc >/dev/null 2>&1
    : > $ESC; ku update frc >/dev/null 2>&1
    local plain; plain="$(cat $ESC)"
    : > $ESC; ku update frc --force >/dev/null 2>&1
    local forced; forced="$(cat $ESC)"
    # pkexec itself is stubbed and logs its argv, so the wrapper shows up as the
    # program pkexec was asked to run rather than by running
    f() { grep -q 'nova-system-update' <<<"$plain" && ! grep -q 'nova-system-update' <<<"$forced" &&
          grep -q -- '--force' <<<"$forced"; }
    check P18 "plain update uses the wrapper; --force escalates directly and carries the flag" f
}

t_P19() { # a "Nova Tools" folder the user made by hand must be adopted, not duplicated
    # gsettings stub backed by a flat file, so the app-folder logic can run
    # without a GNOME session
    cat > $STUBS/gsettings <<'EOF'
#!/usr/bin/env bash
db=/tmp/kt-gsettings.db; touch "$db"
case "$1" in
  get) k="$2|$3"; v="$(grep -F -- "$k=" "$db" | tail -1 | cut -d= -f2-)"
       if [[ -z $v ]]; then case "$3" in folder-children|apps|categories) echo "@as []";; *) echo "''";; esac
       else echo "$v"; fi ;;
  set) k="$2|$3"; { grep -vF -- "$k=" "$db" || true; } > "$db.tmp"; echo "$k=$4" >> "$db.tmp"; mv "$db.tmp" "$db"
       echo "SET $3" >> /tmp/kt-gsettings.log ;;
  reset-recursively) { grep -vF -- "$2|" "$db" || true; } > "$db.tmp"; mv "$db.tmp" "$db" ;;
esac
EOF
    chmod +x $STUBS/gsettings; : > /tmp/kt-gsettings.db; chmod 666 /tmp/kt-gsettings.db
    : > /tmp/kt-gsettings.log; chmod 666 /tmp/kt-gsettings.log
    local apps=$TH/.local/share/applications; mkdir -p $apps
    touch $apps/eu.novanetwork.One.desktop $apps/eu.novanetwork.Two.desktop; chown -R $T $TH/.local
    local G=org.gnome.desktop.app-folders B=/org/gnome/desktop/app-folders/folders
    # the user dragged One into a folder of their own and named it Nova Tools;
    # an earlier nova then built a second folder with the same name
    $STUBS/gsettings set $G folder-children "['Mine', 'nova-tools']"
    $STUBS/gsettings set "$G.folder:$B/Mine/" name "'Nova Tools'"
    $STUBS/gsettings set "$G.folder:$B/Mine/" apps "['eu.novanetwork.One.desktop']"
    $STUBS/gsettings set "$G.folder:$B/nova-tools/" name "'Nova Tools'"
    $STUBS/gsettings set "$G.folder:$B/nova-tools/" apps "['eu.novanetwork.One.desktop', 'eu.novanetwork.Two.desktop']"
    # the stub replaces the db with mv; in sticky /tmp only the owner may do that
    chown $T /tmp/kt-gsettings.db
    mkapp a fold user
    ku add $GITROOT/a/fold.git >/dev/null
    KENV="DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent" ku install fold >/dev/null 2>&1
    local kids mine
    kids="$($STUBS/gsettings get $G folder-children)"
    mine="$($STUBS/gsettings get "$G.folder:$B/Mine/" apps)"
    f() { [[ $kids != *nova-tools* && $kids == *"'Mine'"* && $mine == *One.desktop* && $mine == *Two.desktop* ]]; }
    check P19 "a user-made Nova Tools folder is adopted and the duplicate removed (children=$kids)" f
    # P21: a second run with nothing to change must write nothing — rewriting
    # identical values gave GNOME Shell a folder to re-render on every tick
    local before after
    before="$(grep -c SET /tmp/kt-gsettings.log || true)"
    KENV="DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent" ku update fold --user >/dev/null 2>&1
    after="$(grep -c SET /tmp/kt-gsettings.log || true)"
    rm -f $STUBS/gsettings
    f21() { [[ ${before:-0} -gt 0 && "${after:-0}" == "${before:-0}" ]]; }
    check P21 "a no-op folder sync writes nothing to dconf (writes: first run $before, second run +$(( ${after:-0} - ${before:-0} )))" f21
}

t_P20() { # an unusable list entry is reported WITH the file it sits in
    mkapp a named user
    ku add $GITROOT/a/named.git >/dev/null
    echo "nova-killswitch" >> $TH/.config/nova-updater/apps.list      # what an old `nova add <name>` wrote
    local out; out="$(ku list --no-sync 2>&1 >/dev/null)"
    f() { grep -q "$TH/.config/nova-updater/apps.list" <<<"$out" && grep -q "'nova-killswitch'" <<<"$out"; }
    check P20 "an unusable entry warning names the list file it came from" f
}

t_P22() { # on a user-only machine a dual-scope app installs its user half and says what the root half needs
    mkapp a halfapp "user system" 'echo "scope=$NOVA_SCOPE"'
    # the bootstrap runs from nova's own checkout in the user's repos dir,
    # which a real install always has and the harness has to provide
    mkdir -p $TH/.local/share/nova-updater/repos && cp -r $W $TH/.local/share/nova-updater/repos/nova-updater
    chown -R $T $TH/.local
    ku add $GITROOT/a/halfapp.git >/dev/null
    : > $ESC
    local out rc; out="$(ku install halfapp 2>&1)"; rc=$?
    # 2.0: the system scope is set up on the spot (one password prompt; the
    # harness's pkexec stub refuses it, so the root half is left, rc != 0).
    f() { [[ $rc -ne 0 && -f $(urepo halfapp)/.nova-installed ]] &&
          grep -q 'install.sh install --with-system' $ESC && grep -q 'root half' <<<"$out"; }
    check P22 "user half installs; the system scope bootstrap is offered with one password" f
}

t_P23() { # --with-system=manual: root-owned nova and lists, nothing that runs as root unattended
    local src=$TH/checkout; rm -rf $src; cp -r $W $src; chown -R $T $src
    rootphase() { env -i HOME=/root PATH=$STUBS:/usr/sbin:/usr/bin:/bin bash $src/install.sh install "$@" >/dev/null 2>&1; }
    rootphase --with-system=manual
    local have_nova=0 have_mode="" stray=0
    [[ -x /usr/local/bin/nova && -f /etc/nova-updater/apps.list ]] && have_nova=1
    have_mode="$(cat /etc/nova-updater/mode 2>/dev/null)"
    for f in /usr/local/libexec/nova-system-update /etc/polkit-1/rules.d/50-nova-updater.rules \
             /etc/systemd/system/nova-updater-system.timer /etc/systemd/system/nova-updater-system.service; do
        [[ -e $f ]] && stray=$((stray+1))
    done
    # an old root timer (nova <= 1.8) must be cleaned up by any mode
    mkdir -p /etc/systemd/system; touch /etc/systemd/system/nova-updater-system.timer
    rootphase --with-system=manual
    [[ -e /etc/systemd/system/nova-updater-system.timer ]] && stray=$((stray+10))
    local doc; doc="$(ku doctor 2>&1)"
    # (the USER timer line always complains under the systemctl stub — only the
    # system-timer complaint is the one manual mode must not raise)
    f() { [[ $have_nova -eq 1 && $have_mode == manual && $stray -eq 0 ]] &&
          grep -q 'manual mode' <<<"$doc" && ! grep -q 'wrapper is missing' <<<"$doc"; }
    check P23 "manual mode installs root nova + lists and no wrapper/polkit; an old root timer is removed (mode=$have_mode stray=$stray)" f
    # P24: the modes are one command apart, in both directions
    # plain --with-system KEEPS the recorded mode (a re-run must never flip a
    # deliberate manual choice back to passwordless); =auto is the switch
    rootphase --with-system=auto       # back to auto: wrapper + rule appear, still no timer
    local up=0; for f in /usr/local/libexec/nova-system-update /etc/polkit-1/rules.d/50-nova-updater.rules; do
        [[ -e $f ]] && up=$((up+1)); done
    [[ -e /etc/systemd/system/nova-updater-system.timer ]] && up=$((up+10))
    local m1; m1="$(cat /etc/nova-updater/mode)"
    rootphase --with-system=manual     # and vanish again
    local down=0; for f in /usr/local/libexec/nova-system-update /etc/polkit-1/rules.d/50-nova-updater.rules; do
        [[ -e $f ]] && down=$((down+1)); done
    f24() { [[ $up -eq 2 && $m1 == auto && $down -eq 0 && "$(cat /etc/nova-updater/mode)" == manual ]]; }
    check P24 "switching auto<->manual adds and removes wrapper + polkit rule, never a root timer (auto=$up/2, manual again=$down/2)" f24
}

t_P25() { # the USER timer updates system halves through the wrapper; unattended it never prompts
    mkapp a both "user system"
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos /usr/local/libexec
    install -Dm755 $K /usr/local/bin/nova
    printf '#!/bin/sh\necho "WRAPPER $*" >> %s\nexit 0\n' "$ESC" > /usr/local/libexec/nova-system-update
    chmod +x /usr/local/libexec/nova-system-update
    echo "$GITROOT/a/both.git" > /etc/nova-updater/apps.list
    ku add $GITROOT/a/both.git >/dev/null
    ku install both --user >/dev/null 2>&1; kr install --system both >/dev/null 2>&1
    release a both v1.1.0
    : > $ESC
    KENV="NOVA_UNATTENDED=1" ku update --all >/dev/null 2>&1; local rc1=$?
    local via; via="$(cat $ESC)"
    f() { [[ $rc1 -eq 0 ]] && grep -q 'nova-system-update' <<<"$via" && grep -q both <<<"$via"; }
    check P25 "unattended 'update --all' reaches the system half through the wrapper (rc=$rc1)" f
    # P26: manual mode (no wrapper): unattended must skip, not prompt, not fail
    rm -f /usr/local/libexec/nova-system-update; : > $ESC
    KENV="NOVA_UNATTENDED=1" ku update --all >/dev/null 2>&1; local rc2=$?
    f26() { [[ $rc2 -eq 0 && ! -s $ESC ]]; }
    check P26 "unattended without the wrapper: system half skipped, nothing escalated, exit 0 (rc=$rc2)" f26
}

t_P27() { # an installer can call the tool it just installed by NAME, on every route to it
    # The routes hand it different PATHs: pkexec gives root
    # /usr/sbin:/usr/bin:/sbin:/bin:/root/bin (no /usr/local/bin), and a user
    # manager without the desktop's environment has no ~/.local/bin. kr and ku
    # in this harness have exactly those gaps; the third route is the real
    # wrapper, run in pkexec's exact environment.
    local body='mkdir -p "$NOVA_PREFIX/bin"
printf "#!/bin/sh\necho probe-ok\n" > "$NOVA_PREFIX/bin/pathprobe-$NOVA_SCOPE"
chmod +x "$NOVA_PREFIX/bin/pathprobe-$NOVA_SCOPE"
pathprobe-$NOVA_SCOPE'
    mkapp a pathprobe "user system" "$body"
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    echo "$GITROOT/a/pathprobe.git" > /etc/nova-updater/apps.list
    ku add $GITROOT/a/pathprobe.git >/dev/null
    ku install pathprobe --user >/dev/null 2>&1; local ru=$?
    kr install --system pathprobe >/dev/null 2>&1; local rs=$?
    install -Dm755 $K /usr/local/bin/nova
    install -Dm755 $W/data/nova-system-update /usr/local/libexec/nova-system-update
    release a pathprobe v1.1.0
    env -i HOME=/root USER=root PATH=/usr/sbin:/usr/bin:/sbin:/bin:/root/bin \
        bash /usr/local/libexec/nova-system-update pathprobe >/dev/null 2>&1
    local want got
    want="$(git -C /tmp/kt-work-a-pathprobe rev-parse 'v1.1.0^{commit}')"
    got="$(head -1 /var/lib/nova-updater/repos/pathprobe/.nova-installed 2>/dev/null)"
    rm -f /usr/local/bin/pathprobe-system
    f() { [[ $ru -eq 0 && $rs -eq 0 && $got == "$want" ]]; }
    check P27 "installer finds its fresh tool by name: user=$ru root=$rs wrapper-update=$([[ $got == "$want" ]] && echo ok || echo FAILED)" f
}

t_P28() { # DEPENDS is checked with the PATH the installer will get, not nova's own
    # nova-fox's plugins declare DEPENDS=nova-fox — a command nova-fox installs
    # into ~/.local/bin. In miniature: provider installs the tool, consumer
    # depends on it, and nova's own PATH (here, like a headless user manager)
    # has no ~/.local/bin.
    mkapp a provider user 'mkdir -p "$NOVA_PREFIX/bin"; printf "#!/bin/sh\n" > "$NOVA_PREFIX/bin/provtool"; chmod +x "$NOVA_PREFIX/bin/provtool"'
    mkapp a consumer user 'echo consumer-ran'
    ( cd /tmp/kt-work-a-consumer && printf 'DEPENDS=provtool\n' >> nova.manifest &&
      git commit -qam deps && git tag -a v1.0.1 -m x && git push -q origin HEAD --tags )
    ku add $GITROOT/a/provider.git >/dev/null; ku add $GITROOT/a/consumer.git >/dev/null
    ku install provider >/dev/null 2>&1
    local out; out="$(ku install consumer 2>&1)"
    f() { [[ -x $TH/.local/bin/provtool ]] && ! grep -q 'not here: provtool' <<<"$out"; }
    check P28 "a DEPENDS command another app put in ~/.local/bin is not reported missing" f
}

t_P29() { # `nova update nova-updater` typed in a terminal escalates ONCE
    # nova-updater's own install.sh, run by nova as the user-half installer,
    # also updated the system half whenever stdin was a terminal — and then
    # nova's dispatch did it again: two root updates, and in manual mode two
    # password prompts. It needs a tty to happen, so the timer never showed it.
    local w=/tmp/kt-work-self; rm -rf $w; mkdir -p $w $GITROOT/d
    cp -r $W/. $w/
    ( cd $w && git init -q && git add -A && git commit -qm one && git tag -a v0.0.1 -m v0.0.1 &&
      git commit -q --allow-empty -m two && git tag -a v0.0.2 -m v0.0.2 &&
      git clone -q --bare . $GITROOT/d/nova-updater.git )
    chown -R $T $GITROOT/d
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    echo "$GITROOT/d/nova-updater.git" > /etc/nova-updater/apps.list
    ku add $GITROOT/d/nova-updater.git >/dev/null
    local u r=/var/lib/nova-updater/repos/nova-updater; u="$(urepo nova-updater)"
    runuser -u $T -- git clone -q $GITROOT/d/nova-updater.git $u
    runuser -u $T -- git -C $u -c advice.detachedHead=false checkout -q v0.0.1
    runuser -u $T -- bash -c "git -C $u rev-parse HEAD > $u/.nova-installed"
    git clone -q $GITROOT/d/nova-updater.git $r
    git -C $r -c advice.detachedHead=false checkout -q v0.0.1
    git -C $r rev-parse HEAD > $r/.nova-installed
    install -Dm755 $K /usr/local/bin/nova        # the system scope exists
    : > $ESC
    # a real pty: the duplicate only happens when stdin is a terminal
    python3 -c 'import pty, sys; pty.spawn(sys.argv[1:])' \
        runuser -u $T -- env -i HOME=$TH USER=$T PATH=$STUBS:/usr/bin:/bin NOVA_LOCK_WAIT=3 \
        bash $K update nova-updater </dev/null >/dev/null 2>&1
    local n; n="$(grep -c 'nova-updater' $ESC || true)"
    f() { [[ ${n:-0} -eq 1 ]]; }
    check P29 "from a terminal the system half of nova-updater is escalated once, not twice (escalations: ${n:-0})" f
}

t_P30() { # installing an app installs the nova app it DEPENDS on first — visibly, no false warning
    # The dependency's whole installation used to run inside miss="$(…)", so its
    # output vanished into the "missing" list and came back as a warning that
    # it was "not here" — even after it had installed fine.
    mkapp a hostapp user 'mkdir -p "$NOVA_PREFIX/bin"; printf "#!/bin/sh\n" > "$NOVA_PREFIX/bin/hostapp"; chmod +x "$NOVA_PREFIX/bin/hostapp"; echo HOST-INSTALLER-RAN'
    mkapp a plugapp user 'echo PLUG-INSTALLER-RAN'
    ( cd /tmp/kt-work-a-plugapp && printf 'DEPENDS=hostapp\n' >> nova.manifest &&
      git commit -qam dep && git tag -a v1.0.1 -m x && git push -q origin HEAD --tags )
    mkcat c cat1 $GITROOT/a/hostapp.git $GITROOT/a/plugapp.git
    ku catalog add $GITROOT/c/cat1.git >/dev/null 2>&1
    local dry; dry="$(ku install plugapp --dry-run 2>&1)"     # says so before doing it
    local out rc; out="$(ku install plugapp 2>&1)"; rc=$?
    f() { [[ $rc -eq 0 && -f $(urepo hostapp)/.nova-installed && -f $(urepo plugapp)/.nova-installed ]] &&
          grep -q 'installs hostapp' <<<"$dry" &&
          grep -q 'HOST-INSTALLER-RAN' <<<"$out" && ! grep -q 'not here' <<<"$out"; }
    check P30 "a plugin's host app: announced by --dry-run, installed first, visibly, no false 'not here'" f
}

t_P31() { # a dependency is only auto-installed in the dependent's own scope
    # A user app needing a system-only app ran install_one for the system scope
    # as the USER; as root, a user-only dependency went into /root/.local.
    mkapp a sysdep system 'echo SYSDEP-RAN'
    mkapp a userapp user 'echo USERAPP-RAN'
    ( cd /tmp/kt-work-a-userapp && printf 'DEPENDS=sysdep\n' >> nova.manifest &&
      git commit -qam dep && git tag -a v1.0.1 -m x && git push -q origin HEAD --tags )
    mkcat c cat1 $GITROOT/a/sysdep.git $GITROOT/a/userapp.git
    ku catalog add $GITROOT/c/cat1.git >/dev/null 2>&1
    mkdir -p /var/lib/nova-updater; : > $ESC
    local out; out="$(ku install userapp 2>&1)"
    f() { [[ -f $(urepo userapp)/.nova-installed && ! -s $ESC ]] &&
          grep -q 'nova install sysdep' <<<"$out" && ! grep -qi 'did not install\|permission denied' <<<"$out"; }
    check P31 "a user app's system-only dependency is not attempted unprivileged; it says 'nova install sysdep'" f
}

t_P32() { # a DEPENDS word is resolved only where the app came from, or in a list on this machine
    # Dependency confusion: catalog A's app says DEPENDS=helper, catalog B lists a
    # repo called helper. Installing B's repo runs code nobody chose — and a
    # hostile catalog could claim any common command name that way.
    mkapp a needer user 'echo NEEDER-RAN'
    ( cd /tmp/kt-work-a-needer && printf 'DEPENDS=helper\n' >> nova.manifest &&
      git commit -qam dep && git tag -a v1.0.1 -m x && git push -q origin HEAD --tags )
    mkapp b helper user 'touch /tmp/kt-confused'
    mkcat c catA $GITROOT/a/needer.git
    mkcat d catB $GITROOT/b/helper.git
    ku catalog add $GITROOT/c/catA.git >/dev/null 2>&1
    ku catalog add $GITROOT/d/catB.git >/dev/null 2>&1
    ku install needer >/dev/null 2>&1
    local confused=no; [[ -e /tmp/kt-confused ]] && confused=yes
    # ...but a repo the user added to their OWN list is their choice: allowed
    ku add $GITROOT/b/helper.git >/dev/null 2>&1
    ku install needer >/dev/null 2>&1
    local chosen=no; [[ -f $(urepo helper)/.nova-installed ]] && chosen=yes
    f() { [[ -f $(urepo needer)/.nova-installed && $confused == no && $chosen == yes ]]; }
    check P32 "no dependency pulled from another catalog (pulled=$confused); one in your own list is (installed=$chosen)" f
}


t_P33() { # a catalog entry reads back as (source, url, options) — no field shift
    # app_entries_raw printed url<TAB>opts<TAB>source. For a catalog entry with
    # no options the two tabs collapse when read (a tab is IFS whitespace), so
    # the catalog's path became the app's "options" and its source read empty:
    # visible as a warning naming no file for a bad catalog line, and fatal to
    # anything keyed on the source, such as finding an app's dependencies.
    mkcat c badcat "nova-killswitch"
    ku catalog add $GITROOT/c/badcat.git >/dev/null 2>&1
    local out; out="$(ku list --no-sync 2>&1 >/dev/null)"
    f() { grep -q "catalogs/badcat/apps.list: 'nova-killswitch'" <<<"$out"; }
    check P33 "an unusable catalog line is reported with its catalog's file, not an empty one" f
}

t_P34() { # a self-update that replaced both copies does not report the fresh root copy as skew
    # The process running `nova update nova-updater` is still the OLD version in
    # memory after both copies on disk were replaced. It compared the new root
    # copy with its own NOVA_VERSION and warned "this one is <old> — update it
    # now". Reproduced exactly: old code in memory (bash -c), new file at $0.
    install -Dm755 $K /usr/local/bin/nova
    install -Dm755 $K $TH/.local/bin/nova; chown -R $T $TH/.local
    local old; old="$(sed 's/^NOVA_VERSION=.*/NOVA_VERSION=0.0.1/' $K)"
    mkapp a skewapp user
    ku add $GITROOT/a/skewapp.git >/dev/null; ku install skewapp >/dev/null 2>&1
    local out; out="$(runuser -u $T -- env -i HOME=$TH USER=$T PATH=$STUBS:/usr/bin:/bin NOVA_LOCK_WAIT=3 \
        bash -c "$old" $TH/.local/bin/nova update skewapp </dev/null 2>&1)"
    f() { ! grep -q 'root-owned copy of nova is' <<<"$out" && grep -q 'skewapp' <<<"$out"; }
    check P34 "no false version-skew warning from the old process that just updated both copies" f
}

t_P35() { # an app's own icon reaches the GUI: list --porcelain field 15 is its ICON=
    # Each app ships its icon and names it in its manifest; the GUI draws that
    # file from the clone (field 11). Appended, so no earlier field moves, and an
    # app without an icon still prints all 15 fields with the last one empty.
    mkapp a iconapp user
    ( cd /tmp/kt-work-a-iconapp && mkdir -p data &&
      printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' > data/iconapp.svg &&
      echo 'ICON=data/iconapp.svg' >> nova.manifest && git add -A )
    release a iconapp v1.1.0
    mkapp a plainapp user
    ku add $GITROOT/a/iconapp.git >/dev/null; ku add $GITROOT/a/plainapp.git >/dev/null
    local out; out="$(ku list --porcelain 2>/dev/null)"     # syncs: the manifests come from the clones
    f() { awk -F'\t' '$1=="iconapp"  && NF==15 && $15=="data/iconapp.svg" && $11!="" {a=1}
                      $1=="plainapp" && NF==15 && $15==""                            {b=1}
                      END {exit !(a && b)}' <<<"$out"; }
    check P35 "list --porcelain appends the app's ICON as field 15 (empty when it has none)" f
}

for t in F1 F2 F3 F4 F5 F6 F7 F8 F10 F11 F11b F12 F13 F14 F15 F16 F17 F18 F19 S1 S2 S5 \
         P1 P2 P3 P4 P5 P6 P7 P8 P9 P10 P11 P12 P13 P14 P15 P16 P17 P18 P19 P20 P22 P23 P25 \
         P27 P28 P29 P30 P31 P32 P33 P34 P35; do run $t; done
reset
echo
if (( BUGS )); then echo "$BUGS finding(s) still reproduce"; exit 1; fi
echo "all checks pass"
