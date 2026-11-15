#!/usr/bin/env bash
set -euo pipefail

# Print "<fsdk-version> <fsdk-commit>" for the freedesktop-sdk release that
# fsdk-containers builds on at the given commit, read from its
# elements/freedesktop-sdk.bst junction (ref: freedesktop-sdk-<version>-<n>-g<sha>).
# registry-actions.yml uses it to stamp the io.projectbluefin.fsdk.* labels on
# the published image; tests/source-pins.sh uses it to prove a junction bump
# still names an FSDK release.
usage() { echo "usage: $0 <fsdk-containers commit> [remote]" >&2; exit 2; }
[[ $# -ge 1 && $# -le 2 ]] || usage
commit="$1"
remote="${2:-https://github.com/projectbluefin/fsdk-containers.git}"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || usage

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" fetch -q --depth 1 "$remote" "$commit"
ref="$(git -C "$tmp" show FETCH_HEAD:elements/freedesktop-sdk.bst | sed -n -E 's/^ *ref: *(.*)$/\1/p' | head -n1)"
if [[ ! "$ref" =~ ^freedesktop-sdk-([0-9]+\.[0-9]+(\.[0-9]+)?)-[0-9]+-g([0-9a-f]{40})$ ]]; then
  printf 'fsdk-containers %s: freedesktop-sdk.bst ref "%s" is not freedesktop-sdk-<version>-<n>-g<commit>\n' \
    "${commit:0:12}" "$ref" >&2
  exit 1
fi
printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
