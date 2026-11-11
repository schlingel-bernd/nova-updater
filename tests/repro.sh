#!/usr/bin/env bash
# tests/repro.sh — reproduces the findings in FIXPLAN.md and FIXPLAN-2.4.md
# against the working tree.
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
#     'dnf -y -q install git-core gawk util-linux shadow-utils procps-ng python3 openssl openssh-clients >/dev/null && bash /src/tests/repro.sh'
#
# gawk matters: fedora:latest ships no awk, and without it remote_target fails
# on every app, so checks "pass" because nothing can be reached at all.
# openssl makes S1's https test server (nova refuses http:// since 2.4);
# openssh-clients is git's SSH signature check, which root relies on (H4).
#
#   bash tests/repro.sh F1 F6      # run only some checks (F9 runs as part of F8)
set -uo pipefail

if [[ ! -f /run/.containerenv && ! -f /.dockerenv && ${NOVA_REPRO_FORCE:-0} != 1 ]]; then
    echo "refusing to run outside a container (set NOVA_REPRO_FORCE=1 if this box is disposable)" >&2
    exit 2
fi
[[ $EUID -eq 0 ]] || { echo "must run as root (inside the container)" >&2; exit 2; }
for c in git awk sed grep flock timeout runuser useradd pkill openssl ssh-keygen; do
    command -v "$c" >/dev/null || { echo "missing: $c (the suite would report false passes without it)" >&2; exit 2; }
done

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f $SRC/bin/nova ]] || SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f $SRC/bin/nova ]] || { echo "cannot find bin/nova next to this script" >&2; exit 2; }

T=novatest; TH=/home/$T
W=/opt/nova-under-test; STUBS=/opt/nova-stubs; GITROOT=/srv/nova-git; ESC=/tmp/kt-escalations.log
# repos root may follow: root-owned and not group/other-writable all the way
# up (H1). $GITROOT is the test user's, so anything root reads lives here.
ROOTGIT=/srv/nova-git-root
K=$W/bin/nova

id $T >/dev/null 2>&1 || useradd -m -s /bin/bash $T
# auto mode grants the wrapper to the admin group (K2); openSUSE's image has
# none, and without one the bootstrap rightly falls back to manual mode
grep -q '^wheel:' /etc/group || grep -q '^sudo:' /etc/group || groupadd -r wheel
git config --system safe.directory '*'
git config --system user.email t@example.com
git config --system user.name tester
git config --system init.defaultBranch main
# https://nova.test/<owner>/<name>.git is $GITROOT/<owner>/<name>.git: nova sees
# an https URL (root takes nothing else from the user side since H1), git
# fetches from the local fixture. .test is reserved, so nothing real is shadowed.
git config --system "url.$GITROOT/.insteadOf" https://nova.test/
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
           $GITROOT $ROOTGIT /tmp/kt-*
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
# Two release-signing keys (H4), made once per run and kept outside /tmp/kt-*,
# which reset() clears: KEYA is "the project's" key, KEYB someone else's.
KEYS=/opt/nova-keys; KEYA=$KEYS/a; KEYB=$KEYS/b
if [[ ! -f $KEYA ]]; then
    mkdir -p $KEYS
    ssh-keygen -q -t ed25519 -N '' -C kt-a -f $KEYA; ssh-keygen -q -t ed25519 -N '' -C kt-b -f $KEYB
fi
# resign owner name tag key -> replace an app's (mkapp) tag with a signed one
resign() {
    ( cd /tmp/kt-work-"$1"-"$2" &&
      git -c gpg.format=ssh -c user.signingkey="$4" tag -f -s "$3" -m "$3" "$3^{commit}" >/dev/null &&
      git push -q -f origin "refs/tags/$3" )
}
# release_signed owner name tag key -> like release, with an SSH-signed tag
release_signed() {
    ( cd /tmp/kt-work-"$1"-"$2" && sed -i "s/^VERSION=.*/VERSION=${3#v}/" nova.manifest &&
      git commit -qam "release $3" &&
      git -c gpg.format=ssh -c user.signingkey="$4" tag -s "$3" -m "$3" &&
      git push -q origin HEAD --tags )
}
# rootfix owner name -> prints the path of a root-owned copy of $GITROOT/owner/name.git
# Root follows a local path only if it and every parent are root-owned (H1).
# Re-run it after `release` (or any push) so root sees the new commits. There is
# deliberately no environment switch that lets root skip the check for tests.
rootfix() {
    mkdir -p "$ROOTGIT/$1"; chmod 755 "$ROOTGIT" "$ROOTGIT/$1"
    rm -rf "$ROOTGIT/$1/$2.git"
    cp -a "$GITROOT/$1/$2.git" "$ROOTGIT/$1/$2.git"
    chown -R root:root "$ROOTGIT/$1/$2.git"; chmod -R go-w "$ROOTGIT/$1/$2.git"
    echo "$ROOTGIT/$1/$2.git"
}
# selffix -> a root-owned, release-tagged repo of the tree under test, named
# in /etc/nova-updater/self-url. Since M5 root installs nova only from its own
# clone of that source (by default the real GitHub repo), so without this a
# root bootstrap in a test would install the published release, not this tree.
selffix() {
    local w=/tmp/kt-work-selffix v
    v="$(sed -n 's/^VERSION=//p' $W/nova.manifest | head -1)"
    rm -rf $w; mkdir -p $w; cp -r $W/. $w/
    ( cd $w && git init -q && git add -A && git commit -qm self && git tag -a "v$v" -m "v$v" )
    mkdir -p $ROOTGIT/self; chmod 755 $ROOTGIT $ROOTGIT/self
    rm -rf $ROOTGIT/self/nova-updater.git
    git clone -q --bare $w $ROOTGIT/self/nova-updater.git; chmod -R go-w $ROOTGIT/self/nova-updater.git
    mkdir -p /etc/nova-updater; echo "$ROOTGIT/self/nova-updater.git" > /etc/nova-updater/self-url
}
# ulist line... -> the test user's own apps.list, exactly these lines
ulist() {
    mkdir -p $TH/.config/nova-updater
    printf '%s\n' "$@" > $TH/.config/nova-updater/apps.list
    chown -R $T $TH/.config; chmod 644 $TH/.config/nova-updater/apps.list
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
    local u; u="$(rootfix d nova-updater)"
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    echo "$u" > /etc/nova-updater/apps.list
    local r=/var/lib/nova-updater/repos/nova-updater
    git clone -q $u $r && git -C $r checkout -q v0.0.1
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
    local app cat; app="$(rootfix a rootsvc)"   # root follows a local path only if root owns it (P36, H1)
    mkcat c cat1 "$app"; cat="$(rootfix c cat1)"
    mkdir -p /etc/nova-updater; echo "$cat" > /etc/nova-updater/catalogs.list
    ku catalog add "$cat" >/dev/null 2>&1
    ku list >/dev/null 2>&1
    kr install --system rootsvc >/dev/null
    release a rootsvc v1.1.0; rootfix a rootsvc >/dev/null
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
    # 2.0 handed root the URL the user was shown (--from) and root recorded it.
    # 2.4 (D4): root installs only sources it already lists. For one it does
    # not, nothing is escalated — no password for work root would refuse, and
    # never an escalation by name alone — and the user is told how to register
    # it. Once root lists it, the escalation names the app and says, before
    # the password, where it comes from (M4).
    mkdir -p /etc/nova-updater /var/lib/nova-updater
    install -Dm755 $K /usr/local/bin/nova
    mkapp a hsvc system
    local hu=https://nova.test/a/hsvc.git      # https (nova.test, see the top)
    ulist "$hu"
    : > $ESC
    local out1; out1="$(ku install hsvc 2>&1)"
    local unknown_ok=no
    [[ ! -s $ESC ]] && grep -q "nova add --system $hu" <<<"$out1" && unknown_ok=yes
    # a user-owned local path from a user catalog: no escalation at all either
    mkapp a rootsvc "user system"
    mkcat c usercat $GITROOT/a/rootsvc.git
    ku catalog add $GITROOT/c/usercat.git >/dev/null 2>&1       # user-level only
    : > $ESC
    ku install rootsvc >/dev/null 2>&1
    local local_ok=no; [[ ! -s $ESC ]] && local_ok=yes
    # root lists it now: escalated by name, the source printed first
    echo "$hu" > /etc/nova-updater/apps.list
    : > $ESC
    local out2; out2="$(ku install hsvc 2>&1)"
    local known_ok=no
    grep -q -- "install --system hsvc" $ESC && ! grep -q -- '--from' $ESC &&
        grep -q "hsvc from $hu" <<<"$out2" && known_ok=yes
    f() { [[ $unknown_ok == yes && $local_ok == yes && $known_ok == yes ]]; }
    check F16 "unknown source: no password, says 'nova add --system' ($unknown_ok); local path: no password ($local_ok); listed: escalated by name with its source shown ($known_ok)" f
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
    # https with a throwaway certificate: nova refuses http:// (M2), so a plain
    # http server would make this pass without nova ever asking it anything
    local port=18473 log=/tmp/kt-cred.log hits=/tmp/kt-s1-hits.log
    : > $log; chmod 666 $log; : > $hits
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
        -keyout /tmp/kt-s1.key -out /tmp/kt-s1.crt >/dev/null 2>&1
    printf '#!/bin/sh\necho "$*" >> %s\n' "$log" > $STUBS/cred-helper; chmod +x $STUBS/cred-helper
    python3 - "$port" "$hits" <<'PY2' &
import sys, ssl, http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(sys.argv[2], "a").write(self.path + "\n")
        self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="x"'); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain("/tmp/kt-s1.crt", "/tmp/kt-s1.key")
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY2
    local srv=$!; sleep 1
    mkapp a private user; ku add $GITROOT/a/private.git >/dev/null; ku install private >/dev/null
    runuser -u $T -- env HOME=$TH git config --global credential.helper $STUBS/cred-helper
    runuser -u $T -- env HOME=$TH git config --global http.sslVerify false
    echo "https://127.0.0.1:$port/private.git" > $TH/.config/nova-updater/apps.list
    ku check >/dev/null 2>&1
    kill $srv 2>/dev/null
    runuser -u $T -- env HOME=$TH git config --global --unset credential.helper
    runuser -u $T -- env HOME=$TH git config --global --unset http.sslVerify
    f() { [[ -s $hits && ! -s $log ]]; }
    check S1 "credential helper is never invoked (ls-remote path; server asked: $(wc -l < $hits) time(s))" f
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
    local u; u="$(rootfix a dual)"
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    install -Dm755 $K /usr/local/bin/nova      # something for root to escalate to
    echo "$u" > /etc/nova-updater/apps.list
    ku add "$u" >/dev/null
    ku install dual >/dev/null 2>&1
    kr install --system dual >/dev/null 2>&1
    release a dual v1.1.0; rootfix a dual >/dev/null
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
    local u; u="$(rootfix a dualp)"
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    echo "$u" > /etc/nova-updater/apps.list
    ku add "$u" >/dev/null
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
    local u; u="$(rootfix a bothsc)"
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    echo "$u" > /etc/nova-updater/apps.list
    ku add "$u" >/dev/null
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
    local u; u="$(rootfix a dualpin)"
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    install -Dm755 $K /usr/local/bin/nova
    echo "$u" > /etc/nova-updater/apps.list
    ku add "$u" >/dev/null
    ku install dualpin --user >/dev/null 2>&1
    kr install --system dualpin >/dev/null 2>&1
    release a dualpin v1.1.0; rootfix a dualpin >/dev/null
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

t_P16() { # the root phase of the bootstrap registers nova's own self-update, from root's own source
    # Under pkexec there is no SUDO_UID; the root phase must still register
    # self-update (the harness runs root with env -i, which is that environment).
    # M5: and what it registers and installs is root's choice — self-url here,
    # the canonical URL otherwise — never the user checkout's origin or files.
    selffix
    local src=$TH/checkout; rm -rf $src
    cp -r $W $src && echo '# USER-CHECKOUT-COPY' >> $src/bin/nova && chown -R $T $src
    runuser -u $T -- bash -c "cd $src && git init -q && git add -A && git -c user.email=t@e -c user.name=t commit -qm x"
    runuser -u $T -- git -C $src remote add origin https://nova.test/elsewhere/nova-updater.git
    # GIT_CONFIG_SYSTEM=/dev/null: the harness sets safe.directory='*' globally,
    # which would hide a "dubious ownership" refusal of the user's checkout
    env -i HOME=/root PATH=$STUBS:/usr/sbin:/usr/bin:/bin GIT_CONFIG_SYSTEM=/dev/null \
        bash $src/install.sh install >/dev/null 2>&1
    local reg=no own=no marker=no
    grep -qx "$ROOTGIT/self/nova-updater.git" /etc/nova-updater/apps.list 2>/dev/null &&
        ! grep -q elsewhere /etc/nova-updater/apps.list && reg=yes
    [[ -f /usr/local/bin/nova ]] && ! grep -q USER-CHECKOUT-COPY /usr/local/bin/nova && own=yes
    [[ -f /var/lib/nova-updater/repos/nova-updater/.nova-installed ]] && marker=yes
    f() { [[ $reg == yes && $own == yes && $marker == yes ]]; }
    check P16 "root bootstrap registers root's own source, not the checkout's origin ($reg), installs nova from its own clone ($own), marks it ($marker)" f
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
    local u; u="$(rootfix a frc)"
    echo "$u" > /etc/nova-updater/apps.list
    ku add "$u" >/dev/null
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
    local hu=https://nova.test/a/halfapp.git
    ku add "$hu" >/dev/null
    : > $ESC
    local out rc; out="$(ku install halfapp 2>&1)"; rc=$?
    # 2.4 (D4): root installs only sources it lists, so the root half waits for
    # an explicit `nova add --system` — no password is asked for here at all
    local first=no
    [[ $rc -ne 0 && -f $(urepo halfapp)/.nova-installed && ! -s $ESC ]] &&
        grep -q "nova add --system $hu" <<<"$out" && first=yes
    # ...and that step sets the system scope up on the spot (one password; the
    # harness's pkexec stub refuses it)
    : > $ESC
    ku add --system "$hu" >/dev/null 2>&1
    local boot=no; grep -q 'install.sh install --with-system' $ESC && boot=yes
    # An app from the DEFAULT catalog needs no registering: the bootstrap gives
    # root that catalog, so `nova install` sets the scope up with one password.
    # (The real catalog URL is mapped onto a fixture for this check only.)
    mkapp a defapp "user system"
    mkcat c defcat https://nova.test/a/defapp.git
    local dc=https://github.com/schlingel-bernd/nova-catalog.git
    git config --system "url.$GITROOT/c/defcat.git.insteadOf" "$dc"
    ku catalog add "$dc" >/dev/null 2>&1
    : > $ESC
    ku install defapp >/dev/null 2>&1
    git config --system --unset "url.$GITROOT/c/defcat.git.insteadOf"
    local defboot=no; grep -q 'install.sh install --with-system' $ESC && defboot=yes
    f() { [[ $first == yes && $boot == yes && $defboot == yes ]]; }
    check P22 "user half installs, root half asks for no password (ok=$first); 'nova add --system' bootstraps (ok=$boot); a default-catalog app bootstraps directly (ok=$defboot)" f
}

t_P23() { # --with-system=manual: root-owned nova and lists, nothing that runs as root unattended
    selffix                      # root installs from its own clone of this tree (M5)
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
    local u; u="$(rootfix a both)"
    echo "$u" > /etc/nova-updater/apps.list
    ku add "$u" >/dev/null
    ku install both --user >/dev/null 2>&1; kr install --system both >/dev/null 2>&1
    release a both v1.1.0; rootfix a both >/dev/null
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
    resign a pathprobe v1.0.0 $KEYA            # the wrapper updates signed releases only (H4)
    local u; u="$(rootfix a pathprobe)"
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    echo "$u" > /etc/nova-updater/apps.list
    ku add "$u" >/dev/null
    ku install pathprobe --user >/dev/null 2>&1; local ru=$?
    kr install --system pathprobe >/dev/null 2>&1; local rs=$?
    install -Dm755 $K /usr/local/bin/nova
    install -Dm755 $W/data/nova-system-update /usr/local/libexec/nova-system-update
    release_signed a pathprobe v1.1.0 $KEYA; rootfix a pathprobe >/dev/null
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
    # The provider plugins declare DEPENDS=nova-proxy — a command nova-proxy
    # installs into ~/.local/bin. In miniature: provider installs the tool, consumer
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
    local src; src="$(rootfix d nova-updater)"
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    echo "$src" > /etc/nova-updater/apps.list
    ku add "$src" >/dev/null
    local u r=/var/lib/nova-updater/repos/nova-updater; u="$(urepo nova-updater)"
    runuser -u $T -- git clone -q "$src" $u
    runuser -u $T -- git -C $u -c advice.detachedHead=false checkout -q v0.0.1
    runuser -u $T -- bash -c "git -C $u rev-parse HEAD > $u/.nova-installed"
    git clone -q "$src" $r
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
    # the old code in a file and SOURCED, with $0 still the path on disk: a
    # `bash -c "$old"` stopped working once bin/nova outgrew the kernel's
    # 128 KiB limit for one argument
    sed 's/^NOVA_VERSION=.*/NOVA_VERSION=0.0.1/' $K > /tmp/kt-old-nova; chmod 644 /tmp/kt-old-nova
    mkapp a skewapp user
    ku add $GITROOT/a/skewapp.git >/dev/null; ku install skewapp >/dev/null 2>&1
    local out; out="$(runuser -u $T -- env -i HOME=$TH USER=$T PATH=$STUBS:/usr/bin:/bin NOVA_LOCK_WAIT=3 \
        bash -c 'source /tmp/kt-old-nova "$@"' $TH/.local/bin/nova update skewapp </dev/null 2>&1)"
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
    # NF>=15: append-only, later fields follow (16 origin, 17 root-known: M4)
    f() { awk -F'\t' '$1=="iconapp"  && NF>=15 && $15=="data/iconapp.svg" && $11!="" {a=1}
                      $1=="plainapp" && NF>=15 && $15==""                            {b=1}
                      END {exit !(a && b)}' <<<"$out"; }
    check P35 "list --porcelain appends the app's ICON as field 15 (empty when it has none)" f
}

t_P36() { # root follows a local path only if root owns it, all the way up — catalog or its own list
    # valid_url accepted /path and file:// from any source. A trusted catalog
    # that lists a user-writable directory would have had root clone and run
    # whatever its owner put there, on the next passwordless update.
    mkapp a localapp "system"                      # $GITROOT/a is owned by the test user
    mkcat c rootcat $GITROOT/a/localapp.git
    kr catalog add --system $GITROOT/c/rootcat.git >/dev/null 2>&1
    local userowned rootowned
    userowned="$(kr list --porcelain 2>/dev/null | cut -f1)"
    # root-owned all the way up (H1), at the same path the catalog names
    chown root:root $GITROOT; chown -R root:root $GITROOT/a
    rootowned="$(kr list --porcelain 2>/dev/null | cut -f1)"
    chown $T $GITROOT; chown -R $T $GITROOT/a
    # D1 (FIXPLAN-2.4): the system list gets the same rule. Anyone who can
    # write the repo could otherwise have root run it, without a password.
    kr catalog remove --system $GITROOT/c/rootcat.git >/dev/null 2>&1
    mkdir -p /etc/nova-updater; echo "$GITROOT/a/localapp.git" > /etc/nova-updater/apps.list
    local listuser listroot
    listuser="$(kr list --porcelain --no-sync 2>/dev/null | cut -f1)"
    rootfix a localapp > /etc/nova-updater/apps.list
    listroot="$(kr list --porcelain --no-sync 2>/dev/null | cut -f1)"
    f() { ! grep -qx localapp <<<"$userowned" && grep -qx localapp <<<"$rootowned" &&
          ! grep -qx localapp <<<"$listuser" && grep -qx localapp <<<"$listroot"; }
    check P36 "as root, a local path counts only when root owns it all the way up, from a catalog or from root's own list" f
}

t_P37() { # uninstalling without a systemd user session must still remove the files
    # `systemctl --user daemon-reload` ran unguarded under set -e, so over ssh
    # or in a container the uninstall stopped there with every binary in place.
    runuser -u $T -- env -i HOME=$TH PATH=$STUBS:/usr/bin:/bin bash $W/install.sh install --cli-only </dev/null >/dev/null 2>&1
    stub_systemctl 1
    runuser -u $T -- env -i HOME=$TH PATH=$STUBS:/usr/bin:/bin bash $W/install.sh uninstall </dev/null >/dev/null 2>&1
    stub_systemctl 0
    f() { [[ ! -e $TH/.local/bin/nova ]]; }
    check P37 "install.sh uninstall completes when 'systemctl --user' is unavailable" f
}

# ---------------------------------------------------------------------------
# FIXPLAN-2.4.md. Same rule: each prints BUG on 2.3.2 and ok once fixed.
# The GUI findings (U*) have no check here; the plan lists manual steps.
# ---------------------------------------------------------------------------
t_H1() { # a user-owned local repo must never become something root runs
    # Anyone running as the user could commit a new tag there and have the
    # passwordless wrapper install it as root.
    mkapp a lp system 'touch /tmp/kt-h1-ran'
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    echo "$GITROOT/a/lp.git" > /etc/nova-updater/apps.list
    local listed m1=no m2=no appended=no doctor=no
    listed="$(kr list --porcelain --no-sync 2>/dev/null | cut -f1)"
    local doc; doc="$(kr doctor 2>&1)"        # exits 1 here, so not in a pipeline
    grep -q "root ignores '$GITROOT/a/lp.git'" <<<"$doc" && doctor=yes
    kr install --system lp >/dev/null 2>&1
    [[ -f /var/lib/nova-updater/repos/lp/.nova-installed ]] && m1=yes
    # the same path handed over by the user side, as the GUI's --from does
    rm -rf /var/lib/nova-updater/repos/lp /tmp/kt-h1-ran; : > /etc/nova-updater/apps.list
    kr install --system lp --from "$GITROOT/a/lp.git" >/dev/null 2>&1
    [[ -f /var/lib/nova-updater/repos/lp/.nova-installed ]] && m2=yes
    grep -q "$GITROOT/a/lp.git" /etc/nova-updater/apps.list && appended=yes
    f() { ! grep -qx lp <<<"$listed" && [[ $m1 == no && $m2 == no && $appended == no && $doctor == yes ]]; }
    check H1 "root ignores a user-owned local repo, from its list or --from (via list: installed=$m1; --from: installed=$m2 recorded=$appended; doctor says so: $doctor)" f
}

t_H2() { # pressing Tab must never run code from a catalog
    # compgen -W expands every word it is given, $(…) included, and an app
    # name falls back to the URL's basename, which nothing validated.
    ulist 'https://example.invalid/$(touch${IFS}kt-pwned).git'
    local bin=/tmp/kt-h2bin cwd=/tmp/kt-h2cwd
    mkdir -p $bin $cwd; chown $T $cwd
    # bin/nova may have lost its exec bit on the way here; completion needs `nova` on PATH
    printf '#!/bin/sh\nexec bash %s "$@"\n' "$K" > $bin/nova; chmod 755 $bin/nova
    runuser -u $T -- env -i HOME=$TH USER=$T PATH=$bin:/usr/bin:/bin bash -c \
        "cd $cwd && source $W/data/bash-completion/nova && COMP_WORDS=(nova install '') && COMP_CWORD=2 && _nova" \
        </dev/null >/dev/null 2>&1
    local pwned=no; [[ -e $cwd/kt-pwned ]] && pwned=yes
    local rows; rows="$(ku list --porcelain --no-sync 2>/dev/null | cut -f1)"
    f() { [[ $pwned == no ]] && ! grep -qF '$(' <<<"$rows"; }
    check H2 "a \$(…) in a URL's basename is neither run by completion (ran=$pwned) nor listed as a name" f
}

t_H3() { # a repo's basename must never become a command-line option
    # The GUI runs `nova install <name>`: an app called --all installed everything.
    ulist https://example.invalid/--all.git https://example.invalid/-x.git
    local names; names="$(ku list --porcelain --no-sync 2>/dev/null | cut -f1)"
    ku add https://example.invalid/--purge.git >/dev/null 2>&1; local rc=$?
    f() { ! grep -q '^-' <<<"$names" && [[ $rc -ne 0 ]]; }
    check H3 "no listed name starts with '-', and 'nova add …/--purge.git' is refused (rc=$rc)" f
}

t_M1() { # a catalog must not choose an older ref, or a branch, for what root installed
    mkapp a dg system
    release a dg v1.1.0
    ( cd /tmp/kt-work-a-dg && git commit -q --allow-empty -m 'untagged work' && git push -q origin HEAD )
    local app cat; app="$(rootfix a dg)"
    mkcat c dgcat "$app"; cat="$(rootfix c dgcat)"
    kr catalog add --system "$cat" >/dev/null 2>&1
    kr install --system dg >/dev/null 2>&1
    local want m=/var/lib/nova-updater/repos/dg/.nova-installed got_ref got_branch
    want="$(git -C /tmp/kt-work-a-dg rev-parse 'v1.1.0^{commit}')"
    catset() { ( cd /tmp/kt-cat-c-dgcat && printf '%s\n' "$1" > apps.list &&
                 git commit -qam "$1" && git push -q "$cat" HEAD:main ); }
    catset "$app ref=v1.0.0"
    kr update --all --system >/dev/null 2>&1
    got_ref="$(head -1 $m 2>/dev/null)"
    catset "$app branch=main"
    kr update --all --system >/dev/null 2>&1
    got_branch="$(head -1 $m 2>/dev/null)"
    # and the remote itself: deleting the newest tag must not roll root back
    catset "$app"
    git -C "$app" tag -d v1.1.0 >/dev/null
    kr update --all --system >/dev/null 2>&1
    local got_deleted; got_deleted="$(head -1 $m 2>/dev/null)"
    st() { [[ $1 == "$want" ]] && echo stayed || echo moved; }
    f() { [[ -n $want && $got_ref == "$want" && $got_branch == "$want" && $got_deleted == "$want" ]]; }
    check M1 "root stays on v1.1.0 when its catalog says ref=v1.0.0 ($(st "$got_ref")), branch=main ($(st "$got_branch")), or v1.1.0 is deleted upstream ($(st "$got_deleted"))" f
}

t_M2() { # https only — root (invariant 7) and, per D2, the user too
    mkdir -p /etc/nova-updater
    kr add --system http://example.invalid/x.git >/dev/null 2>&1; local rc=$?
    echo http://example.invalid/y.git >> /etc/nova-updater/apps.list
    mkcat c httpcat http://example.invalid/z.git
    local cat; cat="$(rootfix c httpcat)"
    kr catalog add --system "$cat" >/dev/null 2>&1
    local names; names="$(kr list --porcelain --no-sync 2>/dev/null | cut -f1)"
    ku add http://example.invalid/ux.git >/dev/null 2>&1; local urc=$?
    ku catalog add http://example.invalid/ucat.git >/dev/null 2>&1; local crc=$?
    ulist http://example.invalid/uy.git
    local unames; unames="$(ku list --porcelain --no-sync 2>/dev/null | cut -f1)"
    f() { [[ $rc -ne 0 && $urc -ne 0 && $crc -ne 0 ]] && ! grep -qxE 'x|y|z' <<<"$names" && ! grep -qxE 'ux|uy' <<<"$unames"; }
    check M2 "http:// refused: root add (rc=$rc), user add (rc=$urc), catalog add (rc=$crc); listed as root: $(grep -xE 'x|y|z' <<<"$names" | tr '\n' ' ')user: $(grep -xE 'ux|uy' <<<"$unames" | tr '\n' ' ')" f
}

t_M3() { # nothing untrusted reaches the terminal with its escape sequences intact
    local e=$'\033'
    mkapp a esc user "echo visible # ${e}[8mconcealed"
    ku add $GITROOT/a/esc.git >/dev/null; ku install esc >/dev/null 2>&1
    ( cd /tmp/kt-work-a-esc && sed -i 's/^VERSION=.*/VERSION=1.1.0/' nova.manifest &&
      printf 'echo also # %s[2Khidden\n' "$e" >> install.sh &&
      git commit -qam "harmless ${e}[8msubject" && git tag -a v1.1.0 -m v1.1.0 && git push -q origin HEAD --tags )
    local diff inst cat
    diff="$(ku diff esc 2>&1)"
    inst="$(ku info --installer esc 2>&1)"
    mkcat c esccat
    ( cd /tmp/kt-cat-c-esccat && printf 'NAME=nice%s[8mcat\nDESCRIPTION=ok\n' "$e" > catalog.manifest &&
      git commit -qam name && git push -q $GITROOT/c/esccat.git HEAD:main )
    ku catalog add $GITROOT/c/esccat.git >/dev/null 2>&1
    cat="$(ku catalog list 2>&1)"
    local where=""
    [[ $diff == *"$e"* ]] && where+="diff "
    [[ $inst == *"$e"* ]] && where+="info-installer "
    [[ $cat == *"$e"* ]] && where+="catalog-list "
    f() { [[ -z $where ]]; }
    check M3 "no raw ESC from an installer, a commit subject or a catalog NAME (found in: ${where:-nowhere})" f
}

t_M6() { # the installer that runs is a regular file inside the clone
    printf '#!/bin/sh\ntouch /tmp/kt-ran\n' > /tmp/kt-outside.sh; chmod 755 /tmp/kt-outside.sh
    # (a) INSTALLER= climbs out of the clone
    mkapp a m6a user
    ( cd /tmp/kt-work-a-m6a && echo 'INSTALLER=../../../../../../../../../../tmp/kt-outside.sh' >> nova.manifest &&
      git commit -qam out && git tag -a v1.0.1 -m x && git push -q origin HEAD --tags )
    ku add $GITROOT/a/m6a.git >/dev/null
    ku install m6a >/dev/null 2>&1; local rca=$? rana=no
    [[ -e /tmp/kt-ran ]] && rana=yes; rm -f /tmp/kt-ran
    # (b) install.sh is a symlink to a file outside it
    mkapp a m6b user
    ( cd /tmp/kt-work-a-m6b && rm install.sh && ln -s /tmp/kt-outside.sh install.sh &&
      git add -A && git commit -qm link && git tag -a v1.0.1 -m x && git push -q origin HEAD --tags )
    ku add $GITROOT/a/m6b.git >/dev/null
    ku install m6b >/dev/null 2>&1; local rcb=$? ranb=no
    [[ -e /tmp/kt-ran ]] && ranb=yes
    f() { [[ $rca -ne 0 && $rcb -ne 0 && $rana == no && $ranb == no ]]; }
    check M6 "an installer outside the clone is refused: INSTALLER=../ (rc=$rca ran=$rana), symlink (rc=$rcb ran=$ranb)" f
}

t_M7() { # update clones only what is installed, as root and as the user
    # root: every catalog-listed repo cloned and parsed as root on every timer run
    mkapp a m7in system; mkapp a m7out system
    local a1 a2 cat; a1="$(rootfix a m7in)"; a2="$(rootfix a m7out)"
    mkcat c m7cat "$a1" "$a2"; cat="$(rootfix c m7cat)"
    kr catalog add --system "$cat" >/dev/null 2>&1
    kr install --system m7in >/dev/null 2>&1
    rm -rf /var/lib/nova-updater/repos/m7out
    kr update --all --system >/dev/null 2>&1
    local rootclone=no; [[ -e /var/lib/nova-updater/repos/m7out ]] && rootclone=yes
    # user
    mkapp a u7in user; mkapp a u7out user
    mkcat c u7cat $GITROOT/a/u7in.git $GITROOT/a/u7out.git
    ku catalog add $GITROOT/c/u7cat.git >/dev/null 2>&1
    ku install u7in >/dev/null 2>&1
    rm -rf "$(urepo u7out)"
    ku update >/dev/null 2>&1
    local userclone=no; [[ -e $(urepo u7out) ]] && userclone=yes
    f() { [[ -f /var/lib/nova-updater/repos/m7in/.nova-installed && -f $(urepo u7in)/.nova-installed &&
             $rootclone == no && $userclone == no ]]; }
    check M7 "update does not clone an app that is not installed (root cloned it: $rootclone, user: $userclone)" f
}

t_L1() { # root reads no NOVA_* tuning from the environment
    mkapp a l1app system
    local app cat; app="$(rootfix a l1app)"
    mkcat c l1cat "$app"; cat="$(rootfix c l1cat)"
    kr catalog add --system "$cat" >/dev/null 2>&1
    rm -rf /var/lib/nova-updater/repos/l1app        # so sync_all_meta has work to do
    # PATH, not an arbitrary name: under set -u an unset array name aborts
    # before the subscript is evaluated, a set one does not
    KENV='NOVA_FETCH_JOBS=PATH[$(touch${IFS}/tmp/kt-l1)]' kr list --porcelain >/dev/null 2>&1
    f() { [[ ! -e /tmp/kt-l1 ]]; }
    check L1 "NOVA_FETCH_JOBS from the environment is not evaluated as root" f
}

t_Q1() { # one ls-remote per URL per run
    # The common GUI case: system apps root installed, seen by the user, who has
    # a metadata clone of each. refresh_meta asks once, the status asks again.
    local n u urls=()
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    for n in qa qb qc; do mkapp a $n system; u="$(rootfix a $n)"; urls+=("$u"); done
    printf '%s\n' "${urls[@]}" > /etc/nova-updater/apps.list
    for n in qa qb qc; do kr install --system $n >/dev/null 2>&1; done
    ku list >/dev/null 2>&1                     # the user's metadata clones
    : > /tmp/kt-lsr.log; chmod 666 /tmp/kt-lsr.log
    printf '#!/bin/sh\ncase " $* " in *" ls-remote "*) echo "$*" >> /tmp/kt-lsr.log ;; esac\nexec /usr/bin/git "$@"\n' > $STUBS/git
    chmod +x $STUBS/git
    ku list --porcelain --check >/dev/null 2>&1
    rm -f $STUBS/git
    local calls inst=0; calls="$(wc -l < /tmp/kt-lsr.log)"
    for n in qa qb qc; do [[ -f /var/lib/nova-updater/repos/$n/.nova-installed ]] && inst=$((inst+1)); done
    f() { [[ $inst -eq 3 && $calls -ge 1 && $calls -le 3 ]]; }
    check Q1 "list --check asks each of 3 remotes once (ls-remote calls: $calls, root-installed: $inst/3)" f
}

t_Q4() { # a plain 'nova update' with nothing installed fetches nothing
    local n urls=()
    for n in q4a q4b q4c q4d q4e; do mkapp a $n user; urls+=("$GITROOT/a/$n.git"); done
    mkcat c q4cat "${urls[@]}"
    ku catalog add $GITROOT/c/q4cat.git >/dev/null 2>&1
    ku update >/dev/null 2>&1
    local made=0; for n in q4a q4b q4c q4d q4e; do [[ -e $(urepo $n) ]] && made=$((made+1)); done
    f() { [[ $made -eq 0 ]]; }
    check Q4 "'nova update' with none of 5 catalog apps installed makes no clone (made: $made)" f
}

t_H4() { # root updates without a password only to releases signed by the key it pinned
    mkdir -p /etc/nova-updater /var/lib/nova-updater/repos
    install -Dm755 $K /usr/local/bin/nova
    install -Dm755 $W/data/nova-system-update /usr/local/libexec/nova-system-update
    wrap() { env -i HOME=/root USER=root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
                 bash /usr/local/libexec/nova-system-update "$1" >/dev/null 2>&1; }
    at() { head -1 /var/lib/nova-updater/repos/$1/.nova-installed 2>/dev/null; }
    is() { [[ "$(at "$1")" == "$(git -C /tmp/kt-work-a-"$1" rev-parse "$2^{commit}")" ]] && echo "$2" || echo "not-$2"; }
    local r=()
    # (a) unsigned: installs with a password; the wrapper does not update it, a password does
    mkapp a h4u system; rootfix a h4u >> /etc/nova-updater/apps.list
    kr install --system h4u >/dev/null 2>&1
    release a h4u v1.1.0; rootfix a h4u >/dev/null
    wrap h4u;                          r+=("unsigned/wrapper=$(is h4u v1.0.0)")
    kr update --system h4u >/dev/null 2>&1; r+=("unsigned/password=$(is h4u v1.1.0)")
    # (b) signed by the project's key: pinned at install, the wrapper updates it
    mkapp a h4s system; resign a h4s v1.0.0 $KEYA; rootfix a h4s >> /etc/nova-updater/apps.list
    kr install --system h4s >/dev/null 2>&1
    local pinned=no; [[ -s /etc/nova-updater/signers/h4s ]] && pinned=yes; r+=("pinned=$pinned")
    release_signed a h4s v1.1.0 $KEYA; rootfix a h4s >/dev/null
    wrap h4s;                          r+=("signed/wrapper=$(is h4s v1.1.0)")
    # (c) signed by another key: refused with or without a password, until `nova trust`
    release_signed a h4s v1.2.0 $KEYB; rootfix a h4s >/dev/null
    wrap h4s;                          r+=("otherkey/wrapper=$(is h4s v1.1.0)")
    kr update --system h4s >/dev/null 2>&1; r+=("otherkey/password=$(is h4s v1.1.0)")
    kr trust --system h4s >/dev/null 2>&1
    kr update --system h4s >/dev/null 2>&1; r+=("trusted-again=$(is h4s v1.2.0)")
    # (d) an unsigned tag of an app whose releases are signed: refused, password or not
    release a h4s v1.3.0; rootfix a h4s >/dev/null
    kr update --system h4s >/dev/null 2>&1; r+=("unsigned-after-signed=$(is h4s v1.2.0)")
    # (e) installed before 2.4 (no pin): the wrapper pins the installed release's key
    mkapp a h4m system; resign a h4m v1.0.0 $KEYA; rootfix a h4m >> /etc/nova-updater/apps.list
    kr install --system h4m >/dev/null 2>&1; rm -f /etc/nova-updater/signers/h4m
    release_signed a h4m v1.1.0 $KEYA; rootfix a h4m >/dev/null
    wrap h4m;                          r+=("migration=$(is h4m v1.1.0)")
    f() { [[ ${r[*]} != *=not-* && " ${r[*]} " == *" pinned=yes "* ]]; }
    check H4 "signed releases: ${r[*]}" f
}

t_K7() { # right after install, `nova list` shows the apps of the registered catalog
    # install.sh registers the default catalog without fetching it; the first
    # `nova list` printed nova-updater alone on every distro (PORTPLAN K7)
    mkapp a k7one user; mkapp a k7two user
    mkcat c k7cat $GITROOT/a/k7one.git $GITROOT/a/k7two.git
    mkdir -p $TH/.config/nova-updater
    echo "$GITROOT/c/k7cat.git" > $TH/.config/nova-updater/catalogs.list; chown -R $T $TH/.config
    local offline names
    offline="$(ku list --porcelain --no-sync 2>/dev/null | cut -f1 | tr '\n' ' ')"
    names="$(ku list --porcelain 2>/dev/null | cut -f1 | tr '\n' ' ')"
    f() { [[ $names == *k7one* && $names == *k7two* && $offline != *k7one* ]]; }
    check K7 "first 'nova list' fetches a never-fetched catalog (listed: ${names:-nothing}); --no-sync stays offline" f
}

for t in F1 F2 F3 F4 F5 F6 F7 F8 F10 F11 F11b F12 F13 F14 F15 F16 F17 F18 F19 S1 S2 S5 \
         P1 P2 P3 P4 P5 P6 P7 P8 P9 P10 P11 P12 P13 P14 P15 P16 P17 P18 P19 P20 P22 P23 P25 \
         P27 P28 P29 P30 P31 P32 P33 P34 P35 P36 P37 \
         H1 H2 H3 M1 M2 M3 M6 M7 L1 Q1 Q4 H4 K7; do run $t; done
reset
echo
if (( BUGS )); then echo "$BUGS finding(s) still reproduce"; exit 1; fi
echo "all checks pass"
