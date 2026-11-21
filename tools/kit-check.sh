#!/usr/bin/env bash
# kit-check.sh — is this app's copy of the kit unmodified?
#
# The kit (src/<package>/kit) is the same in every Nova app. It is changed in
# nova-template and copied from there (tools/kit-update.sh), never edited in
# an app: an edited copy is how the apps drifted apart before. KIT.sha256
# lists the files of the kit version this app carries.
#
#   tools/kit-check.sh            check; exit 1 if a file differs
#   tools/kit-check.sh --write    (nova-template only) record the current files
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
kit="$(echo src/*/kit)"
[[ -d $kit ]] || { echo "kit-check: no src/<package>/kit here" >&2; exit 1; }
sums() { (cd "$kit" && find . -type f ! -name KIT.sha256 ! -path '*/__pycache__/*' | LC_ALL=C sort | xargs sha256sum); }
if [[ "${1:-}" == --write ]]; then
    sums > "$kit/KIT.sha256"
    echo "kit-check: recorded $(wc -l < "$kit/KIT.sha256") files"
    exit 0
fi
if ! diff <(sums) "$kit/KIT.sha256" >/dev/null; then
    echo "kit-check: $kit differs from the kit it was copied from:" >&2
    diff <(sums) "$kit/KIT.sha256" | sed -n 's/^[<>] [0-9a-f]*  /  /p' | sort -u >&2
    echo "  change the kit in nova-template, then run tools/kit-update.sh here" >&2
    exit 1
fi
echo "kit-check: ok ($(sed -n 's/^KIT_VERSION = "\(.*\)"/\1/p' "$kit/__init__.py"))"
