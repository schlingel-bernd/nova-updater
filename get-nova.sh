#!/usr/bin/env bash
# nova-updater bootstrap — install with one line.
#
# Recommended, and what you get with no options: the user scope plus the
# root-owned system scope, one password prompt. Apps with a root half —
# nova-killswitch — need it:
#
#   curl -fsSL https://raw.githubusercontent.com/schlingel-bernd/nova-updater/main/get-nova.sh | bash
#
# The same without any passwordless action — every system change asks for
# your password:
#
#   curl -fsSL https://raw.githubusercontent.com/schlingel-bernd/nova-updater/main/get-nova.sh | bash -s -- --with-system=manual
#
# Minimal, 100% user-level, no root ever (complete for user-only apps):
#
#   curl -fsSL https://raw.githubusercontent.com/schlingel-bernd/nova-updater/main/get-nova.sh | bash -s -- --minimal
#
# Clones straight into nova's own repo cache (so self-update just works),
# checks out the latest release tag, and runs the normal installer.
set -euo pipefail

# Everything is inside main(), which is called on the very last line. Piping a
# script into bash executes whatever has arrived so far, so a download cut off
# part way through would otherwise run a prefix of this — a half-finished
# clone, or a checkout with no install after it. Nothing happens until the
# whole file is here.
# nova-updater's release key (docs/signing.md): every release tag is signed with it.
# The same line as .github/allowed_signers and install.sh's — tests/check-version.sh
# keeps the three equal.
NOVA_SIGNER='schlingel-bernd namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOgQc/J6GUopStnNbqhY0QM/k5krVteKyWj4e6qyZX+r'
CANONICAL_REPO="https://github.com/schlingel-bernd/nova-updater.git"

# Refuse a release that is not signed by that key: this script is often the
# first nova code on a machine, and the tag it checks out is what then runs.
verify_release() { # dir tag
    if [[ $REPO != "$CANONICAL_REPO" ]]; then
        echo ":: $REPO is not nova-updater's own repo — its signature is not checked"
        return 0
    fi
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        echo ":: note: no ssh-keygen, so the release signature is not checked here"
        return 0
    fi
    local f rc=0; f="$(mktemp)"
    printf '%s\n' "$NOVA_SIGNER" > "$f"
    git -C "$1" -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$f" verify-tag -- "$2" >/dev/null 2>&1 || rc=$?
    rm -f "$f"
    if (( rc )); then
        echo "error: $2 is not signed by nova-updater's release key — refusing to install it" >&2
        return 1
    fi
    echo ":: $2 is signed by nova-updater's release key"
}

main() {
    local REPO DIR tag
    REPO="${NOVA_REPO:-https://github.com/schlingel-bernd/nova-updater.git}"
    DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nova-updater/repos/nova-updater"

    command -v git >/dev/null 2>&1 || {
        # this script runs before nova is here to ask, so the hint is inline
        local how="your package manager"
        if command -v dnf >/dev/null; then how="sudo dnf install git"
        elif command -v apt-get >/dev/null; then how="sudo apt install git"
        elif command -v pacman >/dev/null; then how="sudo pacman -S git"
        elif command -v zypper >/dev/null; then how="sudo zypper install git-core"
        elif command -v apk >/dev/null; then how="doas apk add bash git coreutils util-linux findutils sed grep"
        fi
        echo "error: git is required — $how" >&2
        exit 1
    }

    if [[ -d "$DIR/.git" ]]; then
        echo ":: refreshing existing clone in $DIR"
        git -C "$DIR" fetch --quiet --tags origin
        git -C "$DIR" reset --hard --quiet origin/HEAD
    else
        echo ":: cloning $REPO"
        mkdir -p "$(dirname "$DIR")"
        git clone --quiet -- "$REPO" "$DIR"
    fi

    # Same release rule nova itself uses: the latest VERSION tag, HEAD if there
    # is none. Only tags shaped like v1.2.3 count — version:refname sorts
    # v2.0.0-rc1 after v2.0.0, and a stray tag like wip-test after everything.
    tag="$(git -C "$DIR" tag --sort=version:refname \
           | grep -E '^v?[0-9]+(\.[0-9]+){0,3}$' | tail -1 || true)"
    if [[ -n $tag ]]; then
        echo ":: checking out release $tag"
        git -C "$DIR" -c advice.detachedHead=false checkout --quiet --force "$tag"
        verify_release "$DIR" "$tag" || exit 1
    fi

    # The recommended install is the default here, so the one line people copy
    # stays short. install.sh itself keeps the user scope as its default: a
    # script run from a clone, or by the tests, must not ask for a password
    # unless told to. --minimal is this bootstrap's way of saying "user only".
    local args=() a want_system=1
    for a in "$@"; do
        case "$a" in
            --minimal|--user-only) want_system=0 ;;
            --with-system|--with-system=*) want_system=0; args+=("$a") ;;
            *) args+=("$a") ;;
        esac
    done
    (( want_system )) && args=(--with-system "${args[@]}")
    exec bash "$DIR/install.sh" install "${args[@]}"
}

main "$@"
