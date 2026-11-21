#!/usr/bin/env bash
# tests/smoke.sh — a real install on whatever distro this container is,
# over the network (PORTPLAN T2). repro.sh stubs the network, systemctl and
# pkexec and checks behaviour in detail; this one checks that the plain path a
# new user takes works here at all:
#
#   1. install.sh as a user (CLI)               -> ~/.local/bin/nova
#   2. the first `nova list`                    -> the real default catalog's apps (K7)
#   3. the root bootstrap, from a root-owned tagged copy of THIS tree
#      (named in /etc/nova-updater/self-url, as M5 requires)  -> /usr/local/bin/nova
#   4. `nova doctor` as root                    -> exits 0
#   5. `nova install syncman` as the user       -> installed (a real app, real installer)
#
# DESTRUCTIVE in the same way as repro.sh (creates a user, writes /etc and
# /usr/local). Container only, needs network:
#
#   podman run --rm -v "$PWD":/src:ro,z debian:13 bash -c \
#     'apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null && bash /src/tests/smoke.sh'
set -uo pipefail

if [[ ! -f /run/.containerenv && ! -f /.dockerenv && ${NOVA_REPRO_FORCE:-0} != 1 ]]; then
    echo "refusing to run outside a container (set NOVA_REPRO_FORCE=1 if this box is disposable)" >&2
    exit 2
fi
[[ $EUID -eq 0 ]] || { echo "must run as root (inside the container)" >&2; exit 2; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
U=novasmoke; UH=/home/$U
FAILS=0
ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" | sed 's/^/     /'; FAILS=$((FAILS+1)); }

id $U >/dev/null 2>&1 || useradd -m -s /bin/bash $U 2>/dev/null || adduser -D -s /bin/bash $U
asu() { # command, as the user, with a login-like minimal environment
    if command -v runuser >/dev/null 2>&1; then
        runuser -u $U -- env -i HOME=$UH USER=$U PATH="$UH/.local/bin:/usr/local/bin:/usr/bin:/bin" bash -c "$1"
    else
        su $U -s /bin/bash -c "env -i HOME=$UH USER=$U PATH=$UH/.local/bin:/usr/local/bin:/usr/bin:/bin bash -c '$1'"
    fi
}
git config --system user.email smoke@example.com 2>/dev/null || true
git config --system user.name smoke 2>/dev/null || true

# 1
cp -r "$SRC" $UH/nova-src && chown -R $U $UH/nova-src
out="$(asu 'cd ~ && bash nova-src/install.sh install --cli-only' 2>&1)"
if [[ -x $UH/.local/bin/nova ]]; then ok "user install"; else fail "user install" "$out"; fi

# 2
out="$(asu 'nova list --porcelain' 2>&1)"
n="$(grep -c $'\t' <<<"$out" || true)"
if (( n >= 5 )); then ok "first nova list shows the catalog ($n apps)"; else fail "first nova list shows the catalog ($n apps)" "$out"; fi

# 3: a root-owned, release-tagged copy of this tree, so the bootstrap installs
# what is being tested rather than the published release
v="$(sed -n 's/^VERSION=//p' "$SRC/nova.manifest" | head -1)"
w=/srv/nova-smoke-work; r=/srv/nova-smoke/nova-updater.git
rm -rf $w /srv/nova-smoke; mkdir -p $w /srv/nova-smoke; cp -r "$SRC"/. $w/; rm -rf $w/.git
( cd $w && git init -q && git add -A && git commit -qm smoke && git tag -a "v$v" -m "v$v" ) >/dev/null
git clone -q --bare $w $r; chown -R root:root /srv/nova-smoke; chmod -R go-w /srv/nova-smoke; chmod 755 /srv/nova-smoke
mkdir -p /etc/nova-updater; echo $r > /etc/nova-updater/self-url
out="$(bash "$SRC/install.sh" install --with-system 2>&1)"
if [[ -x /usr/local/bin/nova ]] && grep -q "NOVA_VERSION=$v" /usr/local/bin/nova; then
    ok "root bootstrap ($(grep -o '([a-z]* mode)' <<<"$out" | head -1))"
else
    fail "root bootstrap" "$out"
fi

# 4
out="$(/usr/local/bin/nova doctor 2>&1)"; rc=$?
if (( rc == 0 )); then ok "nova doctor as root"; else fail "nova doctor as root (rc=$rc)" "$(grep -v '^\s*ok' <<<"$out")"; fi

# 5
out="$(asu 'nova install syncman' 2>&1)"
if [[ -f $UH/.local/share/nova-updater/repos/syncman/.nova-installed ]]; then ok "nova install syncman"
else fail "nova install syncman" "$out"; fi

echo
if (( FAILS )); then echo "$FAILS smoke step(s) failed"; exit 1; fi
echo "smoke test passes"
