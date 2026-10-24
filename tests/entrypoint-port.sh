#!/usr/bin/env bash
# Exercise the PORT and PRINTER_APP_INSTANCE validation at the top of
# files/container-entrypoint.sh without building or running the OCI image.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
entrypoint="$root/files/container-entrypoint.sh"

# Extract prologue before state_dir setup so checks run on host without root or state mount.
prologue="$(sed '/^state_dir=/,$d' "$entrypoint")"
prologue="$prologue"$'\n'"printf '%s\n' \"\${system_name:-}\""

failures=0

report() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

run() {
  local label="$1" want_status="$2" want_output="$3"
  shift 3
  local status=0 output
  output="$(env -i PATH="$PATH" "$@" bash -c "$prologue" 2>&1)" || status=$?
  if [ "$status" != "$want_status" ]; then
    report "$label: exit status $status, expected $want_status (output: $output)"
    return
  fi
  if ! grep -qF -- "$want_output" <<<"$output"; then
    report "$label: output '$output', expected '$want_output'"
    return
  fi
  printf 'ok: %s\n' "$label"
}

run 'unset PORT is allowed' 0 ''
run 'numeric PORT 18020 is allowed' 0 '' PORT=18020
run 'lowest allowed port 1' 0 '' PORT=1
run 'highest allowed port 65535' 0 '' PORT=65535
run 'leading zero is decimal' 0 '' PORT=018020

run 'non-numeric PORT' 64 'PORT must be numeric' PORT=invalid
run 'trailing text after digits' 64 'PORT must be numeric' PORT=18020abc
run 'leading space' 64 'PORT must be numeric' PORT=' 18020'
run 'negative number' 64 'PORT must be numeric' PORT=-1
run 'hexadecimal port' 64 'PORT must be numeric' PORT=0x4664

run 'port zero' 64 'PORT must be between 1 and 65535' PORT=0
run 'one past the top of the range' 64 'PORT must be between 1 and 65535' PORT=65536
run 'overlong port number' 64 'PORT must be between 1 and 65535' PORT=18446744073709551617

run 'valid PRINTER_APP_INSTANCE is sanitized' 0 'PostScript Printer Application (office-1)' PRINTER_APP_INSTANCE="office 1"
run 'PRINTER_APP_INSTANCE without usable characters is rejected' 64 'PRINTER_APP_INSTANCE must contain at least one letter, digit or underscore' PRINTER_APP_INSTANCE=' -!- '

if [ "$failures" -ne 0 ]; then
  printf '%s check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'All PORT and instance validation checks passed\n'
