#!/usr/bin/env bash
#
# Print-route verification for the ps-printer-app FSDK OCI image
# (projectbluefin/ps-printer-app#10).
#
# Drives the two filter routes the issue names through the built image, with
# the CUPS socket backend writing to a TCP sink on the host:
#
#   Route A  PDF -> PostScript vector. A generated PDF is submitted over IPP to
#            a printer on the generic PostScript driver. The job must complete,
#            run pdftops and no raster filter, and deliver structurally valid
#            PostScript: a %!PS-Adobe header, one page and a %%EOF trailer.
#
#   Route B  HPLIP hpps secure (PIN) printing. A printer is added with an HPLIP
#            PostScript PPD whose *cupsFilter is hpps and which declares the
#            HPPinPrnt and HPFIDigit..HPFTDigit PIN options. A plain job and a
#            PIN job must both complete through hpps; only the PIN job may
#            carry hpps' @PJL SET HOLD=ON / HOLDTYPE=PRIVATE / HOLDKEY=<pin>
#            lines. The application log, at the Informational level, must
#            record the hpps run of the PIN job and none of its PIN options,
#            and the container log must not carry them either.
#
# Physical paper output is not verified: no printer hardware is available.
#
# Environment:
#   IMAGE  image to verify (default ghcr.io/projectbluefin/ps-printer-app:build,
#          the tag `just build` produces)
#   NAME   container name (default ps-printer-app-routes)
#   PORT   printer application port (default 18060); the sinks use PORT+1
#          (Route A) and PORT+2 (Route B)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${IMAGE:-ghcr.io/projectbluefin/ps-printer-app:build}"
name="${NAME:-ps-printer-app-routes}"
port="${PORT:-18060}"
pdf_sink_port="$((port + 1))"
hpps_sink_port="$((port + 2))"

pdf_printer="route-pdf"
hpps_printer="route-hpps"
# HP Color LaserJet M553: *cupsFilter "application/vnd.cups-postscript 0 hpps",
# secure printing through HPPinPrnt and the four HPFIDigit..HPFTDigit digits.
hpps_ppd="hplip-ps-ppds:0/hp-color_laserjet_m553-ps.ppd"
hpps_driver="hp--color-laserjet-m-553--recommended-en"
# The application's IPP names for HPPinPrnt and the four digit options.
pin_digits=(5 8 3 6)
pin="5836"
pin_attributes=(
  secure-printing=on
  "first-digit=${pin_digits[0]}"
  "second-digit=${pin_digits[1]}"
  "third-digit=${pin_digits[2]}"
  "fourth-digit=${pin_digits[3]}"
)

state_dir="$(mktemp -d)"
work_dir="$(mktemp -d)"
sink_pid=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  podman rm -f "$name" >/dev/null 2>&1 || true
  if [[ -n "$sink_pid" ]]; then
    kill "$sink_pid" >/dev/null 2>&1 || true
    wait "$sink_pid" 2>/dev/null || true
  fi
  podman unshare rm -rf "$state_dir" >/dev/null 2>&1 || true
  rm -rf "$state_dir" "$work_dir"
}
trap cleanup EXIT

wait_for_http() {
  local response
  for _ in $(seq 1 60); do
    if response="$(curl --fail --silent --show-error "http://127.0.0.1:${port}/" 2>/dev/null)" &&
      [[ "$response" == *'<title>PostScript Printer Application</title>'* ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# First value of one attribute from an ipp-request.py response.
ipp_value() {
  local wanted="$1" line
  while IFS= read -r line; do
    if [[ "$line" == "$wanted="* ]]; then
      line="${line#*=}"
      printf '%s' "${line%%,*}"
      return 0
    fi
  done
  return 1
}

app_log() {
  podman exec "$name" /usr/bin/cat /var/lib/ps-printer-app/ps-printer-app.log
}

add_printer() { # PRINTER DRIVER SINK_PORT
  podman exec "$name" /usr/bin/ps-printer-app \
    -u "ipp://127.0.0.1:${port}/ipp/system" \
    -d "$1" \
    -m "$2" \
    -v "cups:socket://127.0.0.1:${3}" add ||
    fail "could not add printer $1 with the $2 driver"
}

# Submit FILE over IPP to PRINTER through a fresh socket sink on SINK_PORT and
# wait for the job to complete and the sink to drain into OUTPUT.  Sets job_id
# and job_log, the application log lines written since the submission (job ids
# are per printer, so the log is scoped by time, not by id).  Extra arguments
# are NAME=KEYWORD job attributes.
print_job() { # PRINTER SINK_PORT OUTPUT FILE MIME_TYPE [NAME=KEYWORD ...]
  local printer="$1" sink_port="$2" output="$3" file="$4" mime="$5"
  shift 5
  local uri="ipp://127.0.0.1:${port}/ipp/print/${printer}" response status job_state="" log_start
  job_id=""
  job_log=""
  log_start="$(app_log | wc -l)"

  python3 "$script_dir/socket-sink.py" "$sink_port" "$output" >"$output.sink-log" 2>&1 &
  sink_pid=$!
  sleep 1

  response="$(python3 "$script_dir/ipp-request.py" "$uri" print-job "$file" "$mime" "$@")" ||
    fail "Print-Job to $printer failed"
  status="$(ipp_value status <<<"$response")"
  job_id="$(ipp_value job-id <<<"$response")" || job_id=""
  if [[ "$status" != 0x0000 && "$status" != 0x0001 ]] || [[ ! "$job_id" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$response" >&2
    fail "Print-Job to $printer returned status $status and job-id '$job_id'"
  fi

  for _ in $(seq 1 120); do
    job_state="$(python3 "$script_dir/ipp-request.py" "$uri" get-job-attributes "$job_id" | ipp_value job-state)" ||
      job_state=""
    # 9 completed, 7 canceled, 8 aborted (RFC 8011, section 5.3.7)
    [[ "$job_state" == 7 || "$job_state" == 8 || "$job_state" == 9 ]] && break
    sleep 0.5
  done
  if [[ "$job_state" != 9 ]]; then
    app_log >&2 || true
    cat "$output.sink-log" >&2 || true
    fail "job $job_id on $printer ended in job-state '$job_state', expected 9 (completed)"
  fi
  for _ in $(seq 1 20); do
    kill -0 "$sink_pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$sink_pid" 2>/dev/null; then
    fail "the socket sink for job $job_id on $printer never saw the connection close"
  fi
  wait "$sink_pid" || fail "the socket sink for job $job_id on $printer failed"
  sink_pid=""
  [[ -s "$output" ]] || fail "job $job_id on $printer delivered no bytes to the socket sink"
  for _ in $(seq 1 20); do
    job_log="$(app_log | tail -n "+$((log_start + 1))")"
    [[ "$job_log" == *"[Job $job_id] Completed"* ]] && return 0
    sleep 0.5
  done
  printf '%s\n' "$job_log" >&2
  fail "the application log never records job $job_id on $printer completing"
}

# The PostScript document in OUTPUT, starting at its %!PS-Adobe header: the
# bytes before it are the PJL preamble a driver may prepend.
assert_postscript() { # LABEL OUTPUT
  local label="$1" output="$2"
  LC_ALL=C grep -aq '^%!PS-Adobe-3\.0' "$output" || fail "$label: no %!PS-Adobe-3.0 header"
  LC_ALL=C grep -aq '^%%Pages: 1$' "$output" || fail "$label: the PostScript does not declare one page"
  LC_ALL=C grep -aq '^%%Page: 1 1$' "$output" || fail "$label: the PostScript carries no page 1"
  LC_ALL=C grep -aq 'showpage' "$output" || fail "$label: the PostScript never paints a page (no showpage)"
  LC_ALL=C grep -aq '^%%EOF' "$output" || fail "$label: the PostScript has no %%EOF trailer"
}

# The PJL preamble of OUTPUT: every line before the PostScript header.
pjl_header() {
  LC_ALL=C awk '/^%!PS-Adobe/ { exit } { print }' "$1" | LC_ALL=C tr -d '\033\r'
}

for tool in podman curl python3 awk; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done
podman image inspect "$image" >/dev/null 2>&1 || fail "image $image not found; run just build first"

# A one-page PDF with a line of Helvetica text, so that Route A has vector
# content for pdftops to convert.
python3 - "$work_dir/route.pdf" <<'PY'
import sys

content = b"BT /F1 24 Tf 72 700 Td (ps-printer-app print route) Tj ET"
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
    b"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
body = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
offsets = []
for number, obj in enumerate(objects, start=1):
    offsets.append(len(body))
    body += b"%d 0 obj\n" % number + obj + b"\nendobj\n"
xref = len(body)
body += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
body += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
body += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
with open(sys.argv[1], "wb") as handle:
    handle.write(body)
PY

echo "== Appliance start =="
chmod 0777 "$state_dir"
podman run -d \
  --name "$name" \
  --network host \
  -e PORT="$port" \
  -v "$state_dir:/var/lib/ps-printer-app:Z" \
  "$image" >/dev/null
if ! wait_for_http; then
  podman logs "$name" >&2 || true
  fail "web interface on port $port did not answer"
fi

# The default log level records errors only. Informational records each job's
# filter chain, which is the evidence that a route ran the intended filters.
cookie_file="$work_dir/cookies"
logs_page="$(curl --fail --silent --show-error --cookie-jar "$cookie_file" "http://127.0.0.1:${port}/logs")" ||
  fail "the web interface logs page did not answer"
session="${logs_page#*name=\"session\" value=\"}"
session="${session%%\"*}"
[[ -n "$session" && "$session" != "$logs_page" ]] || fail "the logs page carries no web interface session token"
curl --fail --silent --show-error \
  --cookie "$cookie_file" \
  --data-urlencode "session=$session" \
  --data 'log_level=Informational' \
  "http://127.0.0.1:${port}/logs" >/dev/null || fail "could not set the Informational log level"
logs_page="$(curl --fail --silent --show-error "http://127.0.0.1:${port}/logs")"
[[ "$logs_page" == *'<option value="Informational" selected'* ]] || fail "the log level did not change to Informational"
echo "  ok: web interface answers, application log level set to Informational"

echo "== Route A: PDF -> PostScript vector =="
add_printer "$pdf_printer" generic "$pdf_sink_port"
pdf_out="$work_dir/route-pdf.out"
print_job "$pdf_printer" "$pdf_sink_port" "$pdf_out" "$work_dir/route.pdf" application/pdf
pdf_job="$job_id"
head -c 11 "$pdf_out" | LC_ALL=C grep -aq '^%!PS-Adobe-' ||
  fail "Route A: the generic driver output does not start with a %!PS-Adobe header"
assert_postscript "Route A" "$pdf_out"
LC_ALL=C grep -aq '^%%Creator: GPL Ghostscript .*(ps2write)' "$pdf_out" ||
  fail "Route A: the PostScript was not written by Ghostscript ps2write"
pdf_log="$job_log"
[[ "$pdf_log" == *"cfFilterChain: Running filter: pdftops"* ]] ||
  { printf '%s\n' "$pdf_log" >&2; fail "Route A: job $pdf_job did not run pdftops"; }
if grep -q 'Running filter: .*raster' <<<"$pdf_log"; then
  printf '%s\n' "$pdf_log" >&2
  fail "Route A: job $pdf_job rasterized the PDF instead of converting it to vector PostScript"
fi
echo "  ok: PDF job $pdf_job completed through pdftops (ps2write), $(wc -c <"$pdf_out") bytes of one-page PostScript"

echo "== Route B: HPLIP hpps secure printing =="
ppd="$(podman exec "$name" /usr/share/ppd/hplip-ps-ppds cat "$hpps_ppd")" ||
  fail "the HPLIP PostScript PPD archive does not provide $hpps_ppd"
grep -qx '\*cupsFilter: "application/vnd.cups-postscript 0 hpps"' <<<"$ppd" ||
  fail "$hpps_ppd does not route through hpps"
for option in HPPinPrnt HPFIDigit HPSEDigit HPTHDigit HPFTDigit; do
  grep -q "^\*OpenUI \*${option}/" <<<"$ppd" || fail "$hpps_ppd does not declare the $option option"
done
nickname="$(grep -m1 '^\*NickName:' <<<"$ppd")" || fail "$hpps_ppd has no *NickName"
nickname="${nickname#*\"}"
nickname="${nickname%\"*}"
podman exec "$name" /usr/bin/test -x /usr/lib/ps-printer-app/filter/hpps || fail "the hpps filter is not installed"

add_printer "$hpps_printer" "$hpps_driver" "$hpps_sink_port"
hpps_uri="ipp://127.0.0.1:${port}/ipp/print/${hpps_printer}"
attributes="$(python3 "$script_dir/ipp-request.py" "$hpps_uri" get-printer-attributes)" ||
  fail "Get-Printer-Attributes on $hpps_uri failed"
model="$(ipp_value printer-make-and-model <<<"$attributes")" || model=""
[[ "$model" == "$nickname" ]] || fail "printer $hpps_printer reports '$model', not the $hpps_ppd NickName '$nickname'"
for supported in secure-printing-supported=on first-digit-supported=0 fourth-digit-supported=0; do
  grep -q "^${supported%%=*}=.*${supported#*=}" <<<"$attributes" ||
    fail "printer $hpps_printer does not offer ${supported%%-supported*}"
done
echo "  ok: $hpps_printer uses $hpps_ppd ($model), hpps route, PIN options offered"

plain_out="$work_dir/route-hpps-plain.out"
print_job "$hpps_printer" "$hpps_sink_port" "$plain_out" "$work_dir/route.pdf" application/pdf
plain_job="$job_id"
plain_log="$job_log"
pin_out="$work_dir/route-hpps-pin.out"
print_job "$hpps_printer" "$hpps_sink_port" "$pin_out" "$work_dir/route.pdf" application/pdf "${pin_attributes[@]}"
pin_job="$job_id"
pin_log="$job_log"

assert_postscript "Route B plain job" "$plain_out"
assert_postscript "Route B PIN job" "$pin_out"
plain_pjl="$(pjl_header "$plain_out")"
pin_pjl="$(pjl_header "$pin_out")"
for header in "$plain_pjl" "$pin_pjl"; do
  # hpps writes the job name header and hands over to PostScript.
  if [[ "$header" != *'%-12345X@PJL JOBNAME=hplip_'* || "$header" != *'@PJL ENTER LANGUAGE=POSTSCRIPT'* ]]; then
    printf '%s\n' "$header" >&2
    fail "Route B: a job's PJL preamble was not written by hpps"
  fi
done
if [[ "$plain_pjl" == *'@PJL SET HOLD'* ]]; then
  printf '%s\n' "$plain_pjl" >&2
  fail "Route B: the plain job $plain_job is held for a PIN"
fi
for line in '@PJL SET HOLD=ON' '@PJL SET HOLDTYPE=PRIVATE' "@PJL SET HOLDKEY=${pin}"; do
  if ! grep -qx -- "$line" <<<"$pin_pjl"; then
    printf '%s\n' "$pin_pjl" >&2
    fail "Route B: the PIN job $pin_job has no '$line' in its PJL preamble"
  fi
done
echo "  ok: plain job $plain_job and PIN job $pin_job completed through hpps; only the PIN job is held with HOLDKEY=$pin"

for job_log in "$plain_log" "$pin_log"; do
  if [[ "$job_log" != *"cfFilterChain: Running filter: hpps"* ]]; then
    printf '%s\n' "$job_log" >&2
    fail "Route B: the application log does not record a job running hpps"
  fi
done
if leak="$(grep -Ei 'HOLDKEY|digit|PinPrnt|secure-printing' <<<"$pin_log")"; then
  printf '%s\n' "$leak" >&2
  fail "Route B: the application log records the PIN job's PIN options"
fi
if leak="$(podman logs "$name" 2>&1 | grep -Ei 'HOLDKEY|digit|PinPrnt|secure-printing')"; then
  printf '%s\n' "$leak" >&2
  fail "Route B: the container log records the PIN job's PIN options"
fi
echo "  ok: the application log records the hpps run of job $pin_job; neither it nor the container log has its PIN options"

printf 'PASS: %s prints PDF as vector PostScript and holds hpps PIN jobs\n' "$image"
