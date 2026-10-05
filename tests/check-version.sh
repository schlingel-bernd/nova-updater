#!/usr/bin/env bash
# tests/check-version.sh — the version lives in three places; keep them equal.
#
# bin/nova's NOVA_VERSION is what `nova version` prints, nova.manifest's VERSION
# is what every other machine sees in `nova list`, and the git tag is what an
# update actually checks out. A release where they disagree tells users they are
# on a version they are not.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

bin="$(sed -n 's/^NOVA_VERSION=//p' bin/nova | head -1)"
man="$(sed -n 's/^VERSION=//p' nova.manifest | head -1)"
rc=0

say_bad() { printf 'check-version: %s\n' "$*" >&2; rc=1; }

[[ -n $bin ]] || say_bad "no NOVA_VERSION in bin/nova"
[[ -n $man ]] || say_bad "no VERSION in nova.manifest"
[[ $bin == "$man" ]] || say_bad "bin/nova says $bin, nova.manifest says $man"

# Only when HEAD itself is tagged: on a normal commit the next tag does not
# exist yet, and demanding one would fail every ordinary push.
if tag="$(git describe --exact-match --tags HEAD 2>/dev/null)"; then
    [[ ${tag#v} == "$bin" ]] || say_bad "tag $tag does not match version $bin"
fi

(( rc )) || printf 'check-version: ok (%s)\n' "$bin"
exit $rc
