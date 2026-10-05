#!/usr/bin/env bash
# install.sh — template installer for nova-managed tools
#
# nova runs this from the repo root as:  ./install.sh install|update|uninstall
# with these environment variables set:
#   NOVA_SCOPE    user | system   — ONCE PER SCOPE your manifest declares
#   NOVA_PREFIX   ~/.local (user)  or  /usr/local (system)
#   NOVA_APP_DIR  absolute path of this repo's clone
#   NOVA_ACTION   same as $1
#   NOVA_GUI      0 on a headless machine or with --cli-only
#   NOVA_PURGE    1 when the user asked for --purge (uninstall only); your
#                 script is also called as `./install.sh uninstall --purge`
#
# If your manifest says SCOPES=user system, this script is invoked TWICE — once
# with NOVA_SCOPE=user (as the user) and once with NOVA_SCOPE=system (as root).
# Branch on it and do only that half each time; see the nova-killswitch
# installer for a worked example.
#
# For SCOPE=system apps this script already runs as root — no sudo needed.
set -euo pipefail

# fallbacks so the script also works standalone (without nova)
NOVA_SCOPE="${NOVA_SCOPE:-user}"
if [[ $NOVA_SCOPE == system ]]; then
    NOVA_PREFIX="${NOVA_PREFIX:-/usr/local}"
else
    NOVA_PREFIX="${NOVA_PREFIX:-$HOME/.local}"
fi
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP=my-tool   # keep in sync with NAME in nova.manifest

do_install() {
    # --- CLI tool example -------------------------------------------------
    install -Dm755 "$SRC/bin/$APP" "$NOVA_PREFIX/bin/$APP"

    # --- GTK GUI example (uncomment) ---------------------------------------
    # nova exports NOVA_GUI=0 on headless machines — skip GUI parts then:
    # if [[ "${NOVA_GUI:-1}" == 1 ]]; then
    #     install -Dm755 "$SRC/gui/$APP-gui" "$NOVA_PREFIX/bin/$APP-gui"
    #     install -Dm644 "$SRC/data/$APP.desktop" "$NOVA_PREFIX/share/applications/$APP.desktop"
    # fi

    # --- GNOME extension example (SCOPE=user, TYPE=gnome-extension) --------
    # UUID="my-ext@nova-network"
    # EXT_DIR="$HOME/.local/share/gnome-shell/extensions/$UUID"
    # mkdir -p "$EXT_DIR" && cp -r "$SRC/src/." "$EXT_DIR/"
    # gnome-extensions enable "$UUID" || true   # takes effect after re-login

    # --- system config / services example (SCOPE=system) --------------------
    # install -Dm600 "$SRC/conf/wg0.conf" /etc/wireguard/wg0.conf
    # install -Dm644 "$SRC/systemd/$APP.service" /etc/systemd/system/$APP.service
    # systemctl daemon-reload && systemctl enable --now "$APP.service"
    :
}

do_update() {
    # most tools can simply reinstall; add migrations here if needed
    do_install
}

do_uninstall() {
    rm -f "$NOVA_PREFIX/bin/$APP"
    # rm -f "$NOVA_PREFIX/bin/$APP-gui" "$NOVA_PREFIX/share/applications/$APP.desktop"
    # gnome-extensions disable "$UUID" || true; rm -rf "$EXT_DIR"
    # systemctl disable --now "$APP.service" || true; rm -f /etc/systemd/system/$APP.service

    # Only on --purge: an ordinary uninstall leaves the user's configuration
    # alone, so reinstalling later picks up where they left off.
    if [[ "${NOVA_PURGE:-0}" == 1 ]]; then
        : # rm -rf "$HOME/.config/$APP"   (or /etc/$APP for NOVA_SCOPE=system)
    fi
    :
}

case "${1:-install}" in
    install)   do_install ;;
    update)    do_update ;;
    uninstall) do_uninstall ;;
    *) echo "usage: $0 install|update|uninstall [--purge]" >&2; exit 1 ;;
esac
