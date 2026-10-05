#!/usr/bin/env bash
# nova-updater bootstrap — install with one line.
#
# Recommended on a desktop: the user scope plus the root-owned system scope
# (one password prompt). Apps with a root half — nova-killswitch — need it:
#
#   curl -fsSL https://raw.githubusercontent.com/derlocke-ng/nova-updater/main/get-nova.sh | bash -s -- --with-system
#
# The same without a root timer or any passwordless action — every system
# change asks for your password:
#
#   curl -fsSL https://raw.githubusercontent.com/derlocke-ng/nova-updater/main/get-nova.sh | bash -s -- --with-system=manual
#
# Minimal, 100% user-level, no root ever (complete for user-only apps):
#
#   curl -fsSL https://raw.githubusercontent.com/derlocke-ng/nova-updater/main/get-nova.sh | bash
#
# Clones straight into nova's own repo cache (so self-update just works),
# checks out the latest release tag, and runs the normal installer.
set -euo pipefail

# Everything is inside main(), which is called on the very last line. Piping a
# script into bash executes whatever has arrived so far, so a download cut off
# part way through would otherwise run a prefix of this — a half-finished
# clone, or a checkout with no install after it. Nothing happens until the
# whole file is here.
main() {
    local REPO DIR tag
    REPO="${NOVA_REPO:-https://github.com/derlocke-ng/nova-updater.git}"
    DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nova-updater/repos/nova-updater"

    command -v git >/dev/null 2>&1 || {
        echo "error: git is required (in the base image on Silverblue/Bluefin)" >&2
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
    fi

    exec bash "$DIR/install.sh" install "$@"
}

main "$@"
