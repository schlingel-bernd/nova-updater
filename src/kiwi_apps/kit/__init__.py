"""novakit — the shared parts of every Nova Network desktop app.

This folder is the same in every app that uses it: copied unchanged from
github.com/schlingel-bernd/nova-template (tools/kit-update.sh), checked by
tools/kit-check.sh. Change it there, never in an app.

It implements docs/ui-rules.md. An app tells the kit who it is with one
`AppInfo` and gets the header bar, the menu, About, Preferences (Appearance,
Window), the remembered window size, the settings file, the worker and the
job strip with the filling nova.

Nothing in here imports the app it is copied into.
"""

from .info import AppInfo

KIT_VERSION = "0.1.2"

__all__ = ["KIT_VERSION", "AppInfo"]
