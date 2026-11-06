#!/usr/bin/env bash
# Source the shared printing-base startup library at the exact revision the
# image builds from, so the host-only entrypoint tests exercise the same code
# the container runs. The library lives in the fsdk-containers junction, which
# is not checked out on the host, so it is fetched at the pinned junction ref.
#
# Usage (source once per test):
#   source ./source-printing-base.sh
# Then call the library's functions, e.g. printer_app_validate
# 'PostScript Printer Application'.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Offline runs: PRINTER_APP_ENTRYPOINT_COMMON names a local copy of the library
# (it must match the pinned junction ref); no network is used.
if [[ -n "${PRINTER_APP_ENTRYPOINT_COMMON:-}" ]]; then
  if [[ ! -r "$PRINTER_APP_ENTRYPOINT_COMMON" ]]; then
    printf 'source-printing-base: PRINTER_APP_ENTRYPOINT_COMMON=%s is not readable\n' \
      "$PRINTER_APP_ENTRYPOINT_COMMON" >&2
    exit 1
  fi
  export LIB="$PRINTER_APP_ENTRYPOINT_COMMON"
  source "$LIB"
  return 0
fi

# The junction ref is pinned in the build graph, not on disk.
junction_ref="$(
  sed -nE 's/^[[:space:]]*ref:[[:space:]]*([0-9a-f]+)[[:space:]]*$/\1/p' \
    "$repo_root/elements/fsdk-containers.bst" | head -n1
)"
if [[ -z "$junction_ref" ]]; then
  printf 'source-printing-base: no junction ref in elements/fsdk-containers.bst\n' >&2
  exit 1
fi

# Fetch the library at that exact ref and source it. This is the single source
# of truth the image builds from, so the host test can never drift from it.
library="$(mktemp)"
trap 'rm -f "$library"' EXIT
if ! curl -fsSL --max-time 30 \
  "https://raw.githubusercontent.com/projectbluefin/fsdk-containers/$junction_ref/elements/printing/files/entrypoint-common.sh" \
  -o "$library"; then
  printf 'source-printing-base: cannot fetch the shared entrypoint library at %s\n' "$junction_ref" >&2
  exit 1
fi
export LIB="$library"
source "$library"
