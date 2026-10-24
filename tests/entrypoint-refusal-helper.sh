#!/usr/bin/env bash
# Regression test for expect_refusal in tests/instance-isolation.sh.
#
# Source-slices the ACTUAL expect_refusal function from tests/instance-isolation.sh
# and verifies under "set -euo pipefail" that:
#   1. Streaming multi-line container logs (>pipe buffer) with a match on line 1
#      succeed without SIGPIPE (exit code 141) on the logging process.
#   2. Single-line diagnostics succeed.
#   3. A missing diagnostic fails closed with exit 1.
#   4. An unexpected container exit code (non-64) fails closed with exit 1.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
isolation_script="$script_dir/instance-isolation.sh"
slice_file="$(mktemp "$script_dir/.expect-refusal-slice.XXXXXX")"

cleanup() {
  rm -f -- "$slice_file"
}
trap cleanup EXIT

if [ ! -f "$isolation_script" ]; then
  printf 'FAIL: %s not found\n' "$isolation_script" >&2
  exit 1
fi

# Source-slice the actual expect_refusal function from instance-isolation.sh into a file, then source it
sed -n '/^expect_refusal() {/,/^}/p' "$isolation_script" >"$slice_file"
source "$slice_file"

prefix="test-inst"
image="test-image"
containers=()

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

stub_run_exit=64
stub_logs_mode="multiline_streaming"

# Stub podman to simulate container exit 64 and streaming logs
podman() {
  local cmd="$1"
  shift
  if [ "$cmd" = "run" ]; then
    return "$stub_run_exit"
  elif [ "$cmd" = "logs" ]; then
    case "$stub_logs_mode" in
      multiline_streaming)
        printf 'PRINTER_APP_SERVER_OPTIONS: unrecognized option "bogus-option"\n'
        # Stream >64KB in chunks without sleep; if pipe is closed early, write fails
        python3 -u -c '
import sys
for _ in range(500):
    sys.stdout.write("Valid options are: none dnssd-host no-multi-queue raw-socket usb-printer no-web-interface web-log web-network web-remote web-security no-tls\n")
    sys.stdout.flush()
'
        ;;
      singleline)
        printf 'PORT must be between 1 and 65535\n'
        ;;
      missing)
        printf 'Some other log output without diagnostic\n'
        ;;
    esac
  fi
}

failures=0

report() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# 1. Multi-line streaming logs matching line 1: succeeds without SIGPIPE
containers=()
stub_run_exit=64
stub_logs_mode="multiline_streaming"
if ( expect_refusal "multiline streaming log" 'unrecognized option "bogus-option"' ) >/dev/null; then
  printf 'ok: actual expect_refusal succeeds on multi-line streaming log tail without SIGPIPE\n'
else
  report "expect_refusal failed on multi-line streaming logs"
fi

# 2. Single-line log output: succeeds
containers=()
stub_run_exit=64
stub_logs_mode="singleline"
if ( expect_refusal "singleline port" "PORT must be between 1 and 65535" ) >/dev/null; then
  printf 'ok: actual expect_refusal succeeds on single-line diagnostic\n'
else
  report "expect_refusal failed on single-line diagnostic"
fi

# 3. Missing diagnostic: fails closed
containers=()
stub_run_exit=64
stub_logs_mode="missing"
if ( expect_refusal "missing diagnostic" "completely-absent-string" ) >/dev/null 2>&1; then
  report "expect_refusal unexpectedly passed when diagnostic was missing"
else
  printf 'ok: actual expect_refusal fails when diagnostic is missing\n'
fi

# 4. Container non-64 exit: fails closed
containers=()
stub_run_exit=1
stub_logs_mode="singleline"
if ( expect_refusal "bad exit" "PORT must be between 1 and 65535" ) >/dev/null 2>&1; then
  report "expect_refusal unexpectedly passed when container exit was 1 instead of 64"
else
  printf 'ok: actual expect_refusal fails when container exit code is not 64\n'
fi

# 5. refusal_status=78 accepts 78 and rejects the default 64
containers=()
stub_run_exit=78
if ( refusal_status=78 expect_refusal "config refusal" "PORT must be between 1 and 65535" ) >/dev/null; then
  printf 'ok: actual expect_refusal accepts exit 78 when refusal_status=78\n'
else
  report "expect_refusal failed on exit 78 with refusal_status=78"
fi
if ( expect_refusal "config refusal default" "PORT must be between 1 and 65535" ) >/dev/null 2>&1; then
  report "expect_refusal unexpectedly passed exit 78 without refusal_status"
else
  printf 'ok: actual expect_refusal rejects exit 78 by default\n'
fi

if [ "$failures" -ne 0 ]; then
  printf '%s check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'All source-sliced expect_refusal regression checks passed\n'
