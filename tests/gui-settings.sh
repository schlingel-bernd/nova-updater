#!/usr/bin/env bash
# tests/gui-settings.sh — what Nova Apps does without a display:
# `nova-gui --apply-icon`, which install.sh runs. A gui.conf from before 2.9.0
# moves to settings.json and a chosen icon is drawn again; with the stock
# choice nothing is written. Touches only a temporary folder.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" PYTHONDONTWRITEBYTECODE=1
conf="$XDG_CONFIG_HOME/nova-updater"
icon="$XDG_DATA_HOME/icons/hicolor/scalable/apps/eu.novanetwork.NovaUpdater.svg"
rc=0
ok()  { echo "ok   $1"; }
bug() { echo "BUG  $1"; rc=1; }

python3 gui/nova-gui --apply-icon
if [[ ! -e $icon && ! -e $conf/settings.json ]]; then ok "stock choice: nothing written"; else bug "stock choice wrote files"; fi

mkdir -p "$conf"
printf 'ICON_FILE=\nICON_COLOR=ocean\nICON_STYLE=night\nREFRESH_MINUTES=15\nSHOW_OUTPUT=0\n' > "$conf/gui.conf"
python3 gui/nova-gui --apply-icon
got="$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s.get("kit.icon_color"), s.get("kit.icon_style"), s.get("refresh_minutes"), s.get("kit.show_output"))' "$conf/settings.json")"
if [[ $got == "ocean night 15 False" ]]; then ok "gui.conf moved to settings.json"; else bug "settings.json has: $got"; fi
if [[ ! -e $conf/gui.conf ]]; then ok "gui.conf removed"; else bug "gui.conf is still there"; fi
if grep -q '<svg' "$icon" 2>/dev/null; then ok "the chosen icon is drawn"; else bug "no icon written"; fi

before="$(sha256sum "$icon")"
python3 gui/nova-gui --apply-icon
if [[ "$(sha256sum "$icon")" == "$before" ]]; then ok "a second run changes nothing"; else bug "the icon changed on a second run"; fi

printf 'REFRESH_MINUTES=many\nICON_STYLE=flat\n' > "$conf/gui.conf"
python3 gui/nova-gui --apply-icon
got="$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s.get("refresh_minutes"), s.get("kit.icon_style"))' "$conf/settings.json")"
if [[ $got == "15 flat" ]]; then ok "a broken value is skipped, the rest moves"; else bug "after a broken gui.conf: $got"; fi
exit $rc
