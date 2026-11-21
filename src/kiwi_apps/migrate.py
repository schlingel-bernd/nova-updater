"""Until 2.8.1 Nova Apps kept its choices in ~/.config/nova-updater/gui.conf
(KEY=value lines). They are in settings.json now, with the kit's. Moved once;
gui.conf is then removed."""

from __future__ import annotations

from . import INFO
from .kit.settings import Store

# old key -> (new key, how to read the old value)
OLD = {
    "ICON_FILE": ("kit.icon_file", str),
    "ICON_COLOR": ("kit.icon_color", str),
    "ICON_STYLE": ("kit.icon_style", str),
    "SHOW_OUTPUT": ("kit.show_output", lambda v: v != "0"),
    "REFRESH_MINUTES": ("refresh_minutes", int),
}


def gui_conf(store: Store) -> bool:
    """True if gui.conf was there and has been moved."""
    path = INFO.config_dir() / "gui.conf"
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return False
    for line in lines:
        key, sep, value = line.partition("=")
        value = value.strip()
        if not sep or key not in OLD or not value:
            continue
        new, read = OLD[key]
        try:
            store.set(new, read(value))
        except (ValueError, KeyError):
            pass
    try:
        path.unlink()
    except OSError:
        pass
    return True
