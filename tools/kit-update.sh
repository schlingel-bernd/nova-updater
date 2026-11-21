#!/usr/bin/env bash
# kit-update.sh — bring this app's copy of the kit to a nova-template release.
#
#   tools/kit-update.sh            the newest release tag
#   tools/kit-update.sh v0.2.0     that tag
#   tools/kit-update.sh ../nova-template   a local checkout, as it is
#
# Replaces src/<package>/kit as a whole. Read the kit's changes before you
# commit (git diff), run the app, then tools/kit-check.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
kit="$(echo src/*/kit)"
[[ -d $kit ]] || { echo "kit-update: no src/<package>/kit here" >&2; exit 1; }
from="${1:-}"
tmp=""
trap '[[ -n $tmp ]] && rm -rf "$tmp"' EXIT
if [[ -d $from ]]; then
    src="$from"
else
    tmp="$(mktemp -d)"
    url=https://github.com/schlingel-bernd/nova-template.git
    tag="${from:-$(git ls-remote --tags --refs "$url" 'v*' | sed 's|.*refs/tags/||' | sort -V | tail -1)}"
    [[ -n $tag ]] || { echo "kit-update: nova-template has no release tag" >&2; exit 1; }
    git clone -q --depth 1 --branch "$tag" "$url" "$tmp"
    src="$tmp"
    echo "kit-update: nova-template $tag"
fi
[[ -f $src/src/nova_template/kit/KIT.sha256 ]] || { echo "kit-update: no kit in $src" >&2; exit 1; }
rm -rf "$kit"
cp -r "$src/src/nova_template/kit" "$kit"
find "$kit" -name __pycache__ -type d -prune -exec rm -rf {} +
bash tools/kit-check.sh
