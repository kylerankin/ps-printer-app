#!/usr/bin/env bash
#
# Foomatic-RIP PIN job verification for the ps-printer-app OCI image.
#
# The README promises that the manufacturer PostScript PPDs shipped in the
# image are usable, "in most cases PIN-protected printing".  A PIN-protected
# PostScript queue is not a plain PostScript queue: the PPD carries
# "*FoomaticRIPOption ... CmdLine A" options and the job-level JCL is emitted
# by foomatic-rip, which has to be present, has to be found through the PPD's
# "*cupsFilter:" line, and has to be handed the job's vendor option values.
# Checking that the foomatic-rip binary exists checks none of that.
#
# This test therefore exercises the feature the way a user reaches it:
#
#   * --in-image extracts a representative OEM PostScript PPD that carries the
#     PIN options out of the shipped PPD archive and drives foomatic-rip
#     directly, so the JCL the filter emits for a given option set is pinned
#     down deterministically and the negative cases are covered;
#   * the default mode submits a real IPP job with the PIN options set to a
#     printer whose device URI is a TCP socket sink, so the same JCL is proven
#     to survive the whole spooling chain, and checks that the PIN does not
#     end up in the application's diagnostics.
#
# Usage:
#   tests/foomatic-pin.sh             verify one image end to end
#   tests/foomatic-pin.sh --in-image  filter chain proof only, run inside the image
#
# Environment:
#   IMAGE       image reference to verify
#               (default ghcr.io/projectbluefin/ps-printer-app:latest)
#   RUNTIME     container runtime (default podman)
#   NAME        container name (default ps-printer-app-foomatic-pin)
#   PORT        printer application port (default 18040), the sink uses PORT+1000
#   IMAGE_PULL  set to 1 to pull IMAGE even when it already exists locally
#
# What this can and cannot claim: it proves that the shipped filter chain turns
# the configured PIN and user code into the job-level JCL of the OEM PPD and
# that the result reaches the device URI.  It does not prove that a printer
# honours that JCL, and it is not physical validation - no printer hardware is
# available to anyone working on this repository.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The representative OEM PPD: a Ricoh PostScript PPD from the Foomatic
# database, which is the family the PIN support in the PPD files exists for.
# It declares a locked print job type, a numeric PIN and a numeric user code,
# all of them Foomatic command line options, and the locked print job type
# emits the "{secureprint}" and "{setuserinfo}" operators.  The Aficio 2045 is
# used rather than, say, the Aficio 2051 because PAPPL refuses to create a
# printer from PPDs whose full-bleed sizes have an imageable area larger than
# the paper ("Invalid driver bottom/top margins value"), so such a PPD cannot
# reach a real queue.
ppd_member="Ricoh/PS/Ricoh-Aficio_2045_PS.ppd"
driver_make_and_model="RICOH Aficio 2045 (en)"
ppd_archive="/usr/share/ppd/foomatic-ps-ppds"
filter_dir="/usr/lib/ps-printer-app/filter"
log_file="/var/lib/ps-printer-app/ps-printer-app.log"
job_file="/usr/share/ps-printer-app/testpage.ps"

# Option keywords and the values used for them, as they appear in the PPD.
# The enumerated values are choices the PPD itself offers, so they are also
# reachable over IPP; the custom values exercise the
# "*ParamCustom..."/"*FoomaticRIPOptionPrototype" path, which is the one a user
# typing a PIN of their own takes.
pin_keyword="LockedPrintPassword"
pin_choice="4001"
pin_custom="4242"
usercode_keyword="UserCode"
usercode_choice="1001"
usercode_custom="1234"
jobtype_keyword="JobType"
jobtype_locked="LockedPrint"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

# Assert that a captured output carries an expected JCL fragment, or that it
# does not.  The fragments are matched literally because the JCL is PostScript
# text and a regular expression would have to escape it.
assert_output_has() {
  local file="$1" fragment="$2" what="$3"

  if ! grep -aFq -- "$fragment" "$file"; then
    printf 'expected JCL fragment not found: %s\n' "$fragment" >&2
    printf -- '--- %s (first 2048 bytes) ---\n' "$file" >&2
    head -c 2048 -- "$file" >&2 || true
    printf '\n--- end ---\n' >&2
    fail "$what"
  fi
}

assert_output_lacks() {
  local file="$1" fragment="$2" what="$3"

  if grep -aFq -- "$fragment" "$file"; then
    printf 'unexpected JCL fragment found: %s\n' "$fragment" >&2
    fail "$what"
  fi
}

# Run foomatic-rip the way the spooling chain runs it: PPD in the environment
# selects CUPS mode, the job id, user, title and copies are the first four
# arguments, the option string is the fifth and the input file is the sixth.
# The back and side channels are connected to /dev/null, as CUPS does.
run_rip() {
  local ppd="$1" options="$2" input="$3" output="$4" log="$5"

  if ! PPD="$ppd" DEVICE_URI="file:/dev/null" \
    "$filter_dir/foomatic-rip" 1 test test 1 "$options" "$input" \
    3</dev/null 4<>/dev/null \
    >"$output" 2>"$log"; then
    cat "$log" >&2
    fail "foomatic-rip failed for options '$options'"
  fi
  if [[ ! -s "$output" ]]; then
    cat "$log" >&2
    fail "foomatic-rip produced no output for options '$options'"
  fi
}

# ---------------------------------------------------------------------------
# In-image filter chain proof
# ---------------------------------------------------------------------------

check_pin_filter_chain() {
  local tool uri ppd fragment

  for tool in grep head cut cat mktemp rm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "$tool is missing from the image, so the PIN filter chain cannot be checked"
    fi
  done

  if [[ ! -x "$filter_dir/foomatic-rip" ]]; then
    fail "$filter_dir/foomatic-rip is missing, so no PIN-protected queue can print"
  fi
  note "  ok: $filter_dir/foomatic-rip is present"

  if [[ ! -x "$ppd_archive" ]]; then
    fail "$ppd_archive is missing, so the manufacturer PPDs cannot be reached"
  fi

  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT

  # Pull the PPD out of the shipped archive by the name it is archived under,
  # rather than by an index that depends on the Foomatic release.
  uri="$("$ppd_archive" list | grep -F -- "$ppd_member" | head -n 1 | cut -d'"' -f2)"
  if [[ -z "$uri" ]]; then
    fail "$ppd_archive does not ship $ppd_member"
  fi
  "$ppd_archive" cat "$uri" > "$work_dir/pin.ppd"
  if [[ ! -s "$work_dir/pin.ppd" ]]; then
    fail "could not extract $ppd_member from $ppd_archive"
  fi
  ppd="$work_dir/pin.ppd"
  note "  ok: extracted $ppd_member from $ppd_archive"

  # The PPD has to route PostScript through foomatic-rip, otherwise the JCL is
  # never generated, and it has to carry the PIN options as command line
  # arguments of the locked print job type.
  assert_output_has "$ppd" "application/vnd.cups-postscript 0 foomatic-rip" \
    "$ppd_member does not send PostScript through foomatic-rip"
  for fragment in \
    "*FoomaticRIPOption $pin_keyword: password CmdLine A" \
    "*FoomaticRIPOption $usercode_keyword: string CmdLine A" \
    "*FoomaticRIPOption $jobtype_keyword: enum CmdLine A" \
    "*FoomaticRIPOptionPrototype $pin_keyword: \"/lppswd(%s)def" \
    "*FoomaticRIPOptionPrototype $usercode_keyword: \"/usrcode(%s)def"; do
    assert_output_has "$ppd" "$fragment" "$ppd_member does not declare '$fragment'"
  done
  # The locked print job type is the only place the secure print operator
  # appears, so its presence in the captured output is unambiguous evidence
  # that the locked print JCL was emitted and not another job type's JCL.
  if [[ "$(grep -acF -- "secureprint" "$ppd")" != 1 ]]; then
    fail "$ppd_member does not have exactly one secureprint JCL block"
  fi
  note "  ok: $ppd_member declares the PIN options and one locked print JCL block"

  printf '%s\n' \
    "%!PS-Adobe-3.0" \
    "%%Pages: 1" \
    "%%Page: 1 1" \
    "newpath 10 10 moveto 60 60 lineto stroke" \
    "showpage" \
    "%%EOF" > "$work_dir/page.ps"

  # A PIN and a user code of the user's own choosing: the filter has to build
  # the JCL from the option prototypes with the values it was given.
  run_rip "$ppd" \
    "$pin_keyword=$pin_custom $usercode_keyword=$usercode_custom $jobtype_keyword=$jobtype_locked" \
    "$work_dir/page.ps" "$work_dir/custom.prn" "$work_dir/custom.log"
  assert_output_has "$work_dir/custom.prn" "/lppswd($pin_custom)def" \
    "the PIN was not inserted into the locked print JCL"
  assert_output_has "$work_dir/custom.prn" "/usrcode($usercode_custom)def" \
    "the user code was not inserted into the locked print JCL"
  assert_output_has "$work_dir/custom.prn" "{setuserinfo}" \
    "the locked print JCL does not set the user information"
  assert_output_has "$work_dir/custom.prn" "{secureprint}" \
    "the locked print JCL does not request secure printing"
  note "  ok: a custom PIN and user code reach the locked print JCL"

  # The enumerated choices of the PPD are the values a user picks in the web
  # interface, and the values this test sets over IPP.
  run_rip "$ppd" \
    "$pin_keyword=$pin_choice $usercode_keyword=$usercode_choice $jobtype_keyword=$jobtype_locked" \
    "$work_dir/page.ps" "$work_dir/choice.prn" "$work_dir/choice.log"
  assert_output_has "$work_dir/choice.prn" "/lppswd($pin_choice)def" \
    "the enumerated PIN was not inserted into the locked print JCL"
  assert_output_has "$work_dir/choice.prn" "/usrcode($usercode_choice)def" \
    "the enumerated user code was not inserted into the locked print JCL"
  assert_output_has "$work_dir/choice.prn" "{secureprint}" \
    "the enumerated locked print choice does not request secure printing"
  note "  ok: an enumerated PIN and user code reach the locked print JCL"

  # Negative controls: the JCL has to follow the options instead of being
  # emitted unconditionally.  With the PPD defaults no secure print is
  # requested, and asking for a locked print without a PIN must not invent one.
  run_rip "$ppd" "" "$work_dir/page.ps" "$work_dir/default.prn" "$work_dir/default.log"
  assert_output_lacks "$work_dir/default.prn" "{secureprint}" \
    "the locked print JCL is emitted even though the job type is not locked"
  assert_output_lacks "$work_dir/default.prn" "/lppswd($pin_choice)def" \
    "a PIN is emitted even though none was configured"

  run_rip "$ppd" "$jobtype_keyword=$jobtype_locked" \
    "$work_dir/page.ps" "$work_dir/nopin.prn" "$work_dir/nopin.log"
  assert_output_has "$work_dir/nopin.prn" "{secureprint}" \
    "the locked print JCL is missing for the locked print job type"
  assert_output_lacks "$work_dir/nopin.prn" "/lppswd($pin_custom)def" \
    "a PIN is emitted even though the job carried none"
  assert_output_lacks "$work_dir/nopin.prn" "/usrcode($usercode_custom)def" \
    "a user code is emitted even though the job carried none"
  note "  ok: the JCL follows the job options instead of being emitted unconditionally"

  note "  ok: the PIN filter chain emits the expected job-level JCL"
}

work_dir=""

if [[ "${1:-}" == "--in-image" ]]; then
  if [[ $# -ne 1 ]]; then
    fail "--in-image does not take further arguments"
  fi
  check_pin_filter_chain
  exit 0
fi
if [[ $# -ne 0 ]]; then
  fail "unexpected argument: $1"
fi

# ---------------------------------------------------------------------------
# Host orchestration: real image, real IPP job, real socket sink
# ---------------------------------------------------------------------------

image="${IMAGE:-ghcr.io/projectbluefin/ps-printer-app:latest}"
runtime="${RUNTIME:-podman}"
name="${NAME:-ps-printer-app-foomatic-pin}"
port="${PORT:-18040}"
sink_port=$(( port + 1000 ))

printer="pin-test"

state_dir="$(mktemp -d)"
in_image_dir="$(mktemp -d)"
sink_out="$(mktemp)"
sink_log="$(mktemp)"
diagnostics="$(mktemp)"
sink_pid=""

cleanup() {
  "$runtime" rm --force "$name" >/dev/null 2>&1 || true
  if [[ -n "$sink_pid" ]]; then
    kill "$sink_pid" >/dev/null 2>&1 || true
    wait "$sink_pid" 2>/dev/null || true
  fi
  if [[ "$runtime" == podman ]]; then
    "$runtime" unshare rm -rf "$state_dir" >/dev/null 2>&1 || true
  fi
  rm -rf "$state_dir" "$in_image_dir" >/dev/null 2>&1 || true
  rm -f "$sink_out" "$sink_log" "$diagnostics"
}
trap cleanup EXIT

wait_ready() {
  for _ in $(seq 1 60); do
    if curl --fail --silent "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Look up a vendor option by the compacted form of its name, so that the test
# does not depend on how the application spells the human readable PPD option
# text as an IPP attribute name: "locked-print-password-4-8-digits" and
# "lockedprintpassword" both compact to a name starting with
# "lockedprintpassword".
find_option() {
  local listing="$1" prefix="$2" name compact

  while read -r name; do
    compact="${name//[^a-zA-Z0-9]/}"
    if [[ "${compact,,}" == "$prefix"* ]]; then
      printf '%s' "$name"
      return 0
    fi
  done < <(printf '%s\n' "$listing" |
    sed -n 's/^ *-o \([^=]*\)=.*/\1/p' | sort -u)
  return 1
}

# Pick the first enumerated value of an option that is neither the "none"
# default nor the "custom" escape hatch, so that the value is a real choice of
# the PPD rather than an empty setting.
find_option_value() {
  local listing="$1" name="$2" value compact

  while read -r value; do
    compact="${value//[^a-zA-Z0-9]/}"
    compact="${compact,,}"
    if [[ -z "$compact" || "$compact" == "none" || "$compact" == "custom"* ]]; then
      continue
    fi
    printf '%s' "$value"
    return 0
  done < <(printf '%s\n' "$listing" |
    sed -n "s/^ *-o ${name}=\([^ ]*\).*/\1/p" | sort -u)
  return 1
}

# The value of a keyword option such as the job type, matched by the compacted
# form of the value so that "LockedPrint" and "locked-print" both match.
find_keyword_value() {
  local listing="$1" name="$2" wanted="$3" value compact

  while read -r value; do
    compact="${value//[^a-zA-Z0-9]/}"
    if [[ "${compact,,}" == "$wanted" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done < <(printf '%s\n' "$listing" |
    sed -n "s/^ *-o ${name}=\([^ ]*\).*/\1/p" | sort -u)
  return 1
}

for tool in "$runtime" curl python3 grep sed sort cut head wc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    fail "required tool not found: $tool"
  fi
done
[[ -r "$script_dir/socket-sink.py" ]] || fail "socket sink not found: $script_dir/socket-sink.py"

if [[ "${IMAGE_PULL:-0}" == 1 ]] || ! "$runtime" image inspect "$image" >/dev/null 2>&1; then
  note "Pulling $image"
  "$runtime" pull "$image" || fail "unable to obtain image $image"
fi

note "== Filter chain proof inside $image =="
# The image runs as nonroot, which cannot enter mktemp's 0700 directory.
chmod 0755 "$in_image_dir"
cp "$script_dir/foomatic-pin.sh" "$in_image_dir/"
chmod 0755 "$in_image_dir/foomatic-pin.sh"
"$runtime" run --rm --entrypoint /usr/bin/bash \
  --volume "$in_image_dir:/tests:ro,Z" \
  "$image" /tests/foomatic-pin.sh --in-image

note "== Real IPP job with a PIN through foomatic-rip into the socket sink =="

# The sink stands in for the printer on the host; the container shares the
# host network, so the device URI the application dials is loopback.  It takes
# one connection and exits once the socket backend closes it.
chmod 0777 "$state_dir"
python3 "$script_dir/socket-sink.py" "$sink_port" "$sink_out" >"$sink_log" 2>&1 &
sink_pid=$!
sleep 1

"$runtime" run --detach --name "$name" --network host \
  --env "PORT=$port" \
  --volume "$state_dir:/var/lib/ps-printer-app:Z" \
  "$image" >/dev/null

if ! wait_ready; then
  "$runtime" logs "$name" >&2 || true
  fail "the printer application did not serve HTTP on port $port"
fi
note "  ok: the printer application serves HTTP on port $port"

system_uri="ipp://127.0.0.1:${port}/ipp/system"
printer_uri="ipp://127.0.0.1:${port}/ipp/print/${printer}"

drivers="$("$runtime" exec "$name" /usr/bin/ps-printer-app drivers)"
driver="$(printf '%s\n' "$drivers" | grep -F -- "\"$driver_make_and_model\"" | head -n 1 | cut -d' ' -f1)"
if [[ -z "$driver" ]]; then
  printf '%s\n' "$drivers" >&2
  fail "the application does not offer the $driver_make_and_model driver from $ppd_member"
fi
note "  ok: the application offers the OEM driver '$driver'"

if ! "$runtime" exec "$name" /usr/bin/ps-printer-app \
  -u "$system_uri" \
  -d "$printer" \
  -m "$driver" \
  -v "cups:socket://127.0.0.1:${sink_port}" add; then
  "$runtime" exec "$name" cat "$log_file" >&2 || true
  fail "could not add printer $printer with the $driver driver"
fi

options="$("$runtime" exec "$name" /usr/bin/ps-printer-app -u "$printer_uri" options)"
if [[ -z "$options" ]]; then
  fail "the application reported no options for printer $printer"
fi

pin_name="$(find_option "$options" "lockedprintpassword" || true)"
usercode_name="$(find_option "$options" "usercode" || true)"
jobtype_name="$(find_option "$options" "jobtype" || true)"
if [[ -z "$pin_name" || -z "$usercode_name" || -z "$jobtype_name" ]]; then
  printf '%s\n' "$options" >&2
  fail "printer $printer does not expose the PIN, user code and job type options"
fi
pin_value="$(find_option_value "$options" "$pin_name" || true)"
usercode_value="$(find_option_value "$options" "$usercode_name" || true)"
jobtype_value="$(find_keyword_value "$options" "$jobtype_name" "lockedprint" || true)"
if [[ -z "$pin_value" || -z "$usercode_value" || -z "$jobtype_value" ]]; then
  printf '%s\n' "$options" >&2
  fail "printer $printer does not offer usable PIN, user code and locked print values"
fi
note "  ok: printer $printer exposes $pin_name=$pin_value, $usercode_name=$usercode_value and $jobtype_name=$jobtype_value"

if ! "$runtime" exec "$name" /usr/bin/ps-printer-app \
  -u "$printer_uri" \
  -o "$pin_name=$pin_value" \
  -o "$usercode_name=$usercode_value" \
  -o "$jobtype_name=$jobtype_value" \
  submit "$job_file" >/dev/null; then
  fail "the application refused the PIN-protected job"
fi
note "  ok: the PIN-protected job was accepted over IPP"

# The sink exits once the socket backend closes its connection, so every byte
# of the job is in the capture before it is checked.
for _ in $(seq 1 120); do
  if ! kill -0 "$sink_pid" 2>/dev/null; then
    break
  fi
  sleep 0.5
done
if kill -0 "$sink_pid" 2>/dev/null || [[ ! -s "$sink_out" ]]; then
  "$runtime" exec "$name" /usr/bin/ps-printer-app -u "$printer_uri" jobs >&2 || true
  "$runtime" exec "$name" cat "$log_file" >&2 || true
  cat "$sink_log" >&2 || true
  fail "the PIN-protected job did not arrive complete on the socket sink"
fi
wait "$sink_pid" || fail "the socket sink failed: $(cat "$sink_log")"
sink_pid=""

assert_output_has "$sink_out" "/lppswd($pin_value)def" \
  "the PIN did not survive the IPP, filter and backend chain"
assert_output_has "$sink_out" "/usrcode($usercode_value)def" \
  "the user code did not survive the IPP, filter and backend chain"
assert_output_has "$sink_out" "{setuserinfo}" \
  "the locked print JCL did not survive the IPP, filter and backend chain"
assert_output_has "$sink_out" "{secureprint}" \
  "the secure print request did not survive the IPP, filter and backend chain"
note "  ok: $(wc -c <"$sink_out") bytes captured on the socket sink carry the locked print JCL"

jobs_output=""
for _ in $(seq 1 120); do
  jobs_output="$("$runtime" exec "$name" /usr/bin/ps-printer-app -u "$printer_uri" jobs)"
  if [[ "$jobs_output" == *"completed"* ]]; then
    break
  fi
  sleep 0.5
done
if [[ "$jobs_output" != *"completed"* ]]; then
  printf '%s\n' "$jobs_output" >&2
  fail "the PIN-protected job never reached the completed state"
fi
note "  ok: the PIN-protected job reached the completed state"

# The PIN and the user code are secrets, so whatever the application writes for
# diagnostics must not carry them.  The application logs at ERROR level by
# default, which means this check guards the diagnostics that are on by default
# against a change that starts writing job option values at that level or above.
"$runtime" exec "$name" cat "$log_file" >"$diagnostics" ||
  fail "could not read the application log $log_file"
"$runtime" logs "$name" >>"$diagnostics" 2>&1 ||
  fail "could not read the container log of $name"
for secret in "$pin_value" "$usercode_value"; do
  # Match whole words only: the 4 and 8 digit secrets would otherwise hit
  # digits inside random values such as the service cookie in the startup line.
  if grep -aFwq -- "$secret" "$diagnostics"; then
    grep -anFw -- "$secret" "$diagnostics" >&2 || true
    fail "the job secret $secret is written to the application diagnostics"
  fi
done
note "  ok: $(wc -c <"$diagnostics") bytes of diagnostics carry neither the PIN nor the user code"

note "PASS: $image turns a PIN and a user code into the OEM PPD's locked print JCL and delivers it to the socket sink"
