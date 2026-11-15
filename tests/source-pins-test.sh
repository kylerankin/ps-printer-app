#!/usr/bin/env bash
set -euo pipefail

# Regression test for tests/source-pins.sh: run it in a scratch copy of the
# project against a local fsdk-containers remote, so it needs no network.
# Publishing reads the FSDK release with the same scripts/fsdk-pin.sh, so a
# junction this accepts is one publishing can label, and one it rejects would
# have failed the publish on main.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

project="$tmp/project"
remote="$tmp/fsdk-containers"
mkdir -p "$project/tests" "$project/scripts" "$project/elements"
cp "$root/tests/source-pins.sh" "$project/tests/"
cp "$root/scripts/fsdk-pin.sh" "$project/scripts/"

g() { git -C "$remote" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
git init -q "$remote"
g config uploadpack.allowAnySHA1InWant true

fsdk_sha=0123456789abcdef0123456789abcdef01234567
# Commit an fsdk-containers tree whose elements/freedesktop-sdk.bst carries the
# given ref line (none when empty) and print its commit.
fsdk_commit() {
  rm -rf "$remote/elements"
  if [[ -n "$1" ]]; then
    mkdir -p "$remote/elements"
    printf 'kind: junction\nsources:\n  - kind: git_repo\n    url: gitlab:freedesktop-sdk/freedesktop-sdk.git\n    %s\n' \
      "$1" > "$remote/elements/freedesktop-sdk.bst"
  fi
  g add -A
  g commit -q --allow-empty -m "freedesktop-sdk.bst: ${1:-none}"
  g rev-parse HEAD
}

# Pin the scratch project's junction to the given ref line. Callers assign
# commits first: a failure inside an argument's $(...) would not stop set -e.
pin() {
  printf 'kind: junction\nsources:\n  - kind: git_repo\n    url: github:projectbluefin/fsdk-containers.git\n    track: main\n    %s\n' \
    "$1" > "$project/elements/fsdk-containers.bst"
}

check() { FSDK_CONTAINERS_REMOTE="file://$remote" "$project/tests/source-pins.sh" > "$tmp/out" 2>&1; }

accepts() {
  check || { cat "$tmp/out" >&2; echo "source-pins-test: rejected: $1" >&2; exit 1; }
  grep -qxF "$2" "$tmp/out" || { cat "$tmp/out" >&2; echo "source-pins-test: wrong output for: $1" >&2; exit 1; }
}

rejects() {
  if check; then
    cat "$tmp/out" >&2
    echo "source-pins-test: accepted: $1" >&2
    exit 1
  fi
}

release="$(fsdk_commit "ref: freedesktop-sdk-26.08.4-0-g${fsdk_sha}")"
pin "ref: ${release}"
accepts 'a release tag' "OK: FSDK 26.08.4@${fsdk_sha:0:12} via fsdk-containers ${release:0:12}"

pin "ref: main-0-g${release}"
accepts 'a described junction ref' "OK: FSDK 26.08.4@${fsdk_sha:0:12} via fsdk-containers ${release:0:12}"

# Publishing used to accept only -0-g; fsdk-pin.sh takes any commit count.
ahead="$(fsdk_commit "ref: freedesktop-sdk-26.08-3-g${fsdk_sha}")"
pin "ref: ${ahead}"
accepts 'commits past a release tag' "OK: FSDK 26.08@${fsdk_sha:0:12} via fsdk-containers ${ahead:0:12}"

bare="$(fsdk_commit "ref: ${fsdk_sha}")"
pin "ref: ${bare}"
rejects 'a bare FSDK commit'

tag_only="$(fsdk_commit "ref: freedesktop-sdk-26.08.4")"
pin "ref: ${tag_only}"
rejects 'an FSDK tag without a commit'

no_version="$(fsdk_commit "ref: freedesktop-sdk-next-0-g${fsdk_sha}")"
pin "ref: ${no_version}"
rejects 'an FSDK tag without a version'

no_junction="$(fsdk_commit '')"
pin "ref: ${no_junction}"
rejects 'an fsdk-containers commit without elements/freedesktop-sdk.bst'

pin "ref: $(printf '%040d' 0)"
rejects 'an fsdk-containers commit that does not exist'

pin "ref: ${release:0:12}"
rejects 'an abbreviated junction ref'

pin 'track: main'
rejects 'a junction without a ref'

echo 'source-pins-test: OK'
