import sys

from .. import INFO, migrate
from ..kit import icon
from ..kit.settings import Store

# What main.py declares; the icon step below needs them without importing gi.
_DEFAULTS = {"refresh_minutes": 0}

if sys.argv[1:] == ["--apply-icon"]:
    # install.sh, after it put the stock icon back. Needs no display: it
    # moves a gui.conf from before 2.9.0 and redraws a chosen icon.
    store = Store(INFO, _DEFAULTS)
    migrate.gui_conf(store)
    error = icon.apply(INFO, store) if icon.is_custom(store) else None
    if error:
        print(f"nova-gui: {error}", file=sys.stderr)
    sys.exit(1 if error else 0)

from .main import main  # noqa: E402 - gi only when a window is wanted

sys.exit(main())
