#!/usr/bin/env bash
set -euo pipefail

# renovate.json bumps the fsdk-containers junction ref, and registry-actions.yml
# derives the FSDK release from that commit (scripts/fsdk-pin.sh) to label the
# published image. This runs in `just validate`, so a junction bump whose FSDK
# release cannot be read fails its pull request instead of the publish on main.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

junction=elements/fsdk-containers.bst
FSDK_CONTAINERS_REMOTE="${FSDK_CONTAINERS_REMOTE:-https://github.com/projectbluefin/fsdk-containers.git}"

fail() { printf 'source-pins: %s\n' "$*" >&2; exit 1; }
sha40='^[0-9a-f]{40}$'

# The junctioned fsdk-containers commit must name the FSDK release it builds
# on, or publishing could not label the image with it.
junction_ref="$(sed -n -E 's/^ +ref: .*([0-9a-f]{40})$/\1/p' "$junction")"
[[ "$junction_ref" =~ $sha40 ]] || fail "$junction does not pin a full fsdk-containers commit"
# Assign first: a failure inside a here-string's $(...) would not stop set -e.
fsdk_pin="$(scripts/fsdk-pin.sh "$junction_ref" "$FSDK_CONTAINERS_REMOTE")"
read -r fsdk_version fsdk_ref <<< "$fsdk_pin"
[[ -n "$fsdk_version" && "$fsdk_ref" =~ $sha40 ]] \
  || fail "scripts/fsdk-pin.sh printed '$fsdk_pin', not '<fsdk version> <fsdk commit>'"

printf 'OK: FSDK %s@%s via fsdk-containers %s\n' \
  "$fsdk_version" "${fsdk_ref:0:12}" "${junction_ref:0:12}"
