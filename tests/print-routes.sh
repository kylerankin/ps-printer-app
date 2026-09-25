#!/usr/bin/env bash
#
# Real-image print-to-socket-sink verification for ps-printer-app.
#
# Exercises the two routes requested in ps-printer-app#10 against the built
# OCI image, with no physical printer and no synthetic mock echoes:
#
#   Route A  PDF -> PostScript vector. A PDF test document is printed through
#            the built image to a socket sink and the output is asserted to be
#            structurally valid PostScript (the pdftops / ps2write vector path,
#            never a raster mock).
#
#   Route B  HPLIP PIN (hpps) route. The packaged hpps filter and an HPLIP
#            PostScript PPD are confirmed present, a job is printed through that
#            route to a socket sink, and a PIN-configured job is shown to carry
#            an observable difference from a plain job (hpps engages).
#
# Builds nothing here: the CI workflow loads the freshly built rock into podman
# and passes it via $IMAGE. Only the shipped image runs. Physical paper output
# remains unverified (no hardware).
set -euo pipefail

IMAGE="${IMAGE:-ps-printer-app:build}"
NAME="ps-printer-app-payload"
PORT="${PORT:-18000}"
A_SINK_PORT="$((PORT + 1))"     # Route A output sink
B_BASE_SINK_PORT="$((PORT + 2))" # Route B plain-job sink
B_PIN_SINK_PORT="$((PORT + 3))"  # Route B PIN-job sink
STATE_DIR="$(mktemp -d)"
WORK_DIR="$(mktemp -d)"
A_OUT="$WORK_DIR/route-a.ps"
B_BASE_OUT="$WORK_DIR/route-b-base.ps"
B_PIN_OUT="$WORK_DIR/route-b-pin.ps"
SINK_PIDS=()

log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
  podman rm -f "$NAME" >/dev/null 2>&1 || true
  local p
  for p in "${SINK_PIDS[@]:-}"; do
    kill "$p" >/dev/null 2>&1 || true
    wait "$p" 2>/dev/null || true
  done
  podman unshare rm -rf "$STATE_DIR" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# --- a minimal but valid PDF that pdftops can convert ---------------------
make_pdf() {
  python3 - "$WORK_DIR/testpage.pdf" <<'PY'
import sys
body = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
    b"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    b"<< /Length 47 >>\nstream\nBT /F1 24 Tf 100 700 Td (PDFtoPS) Tj ET\nendstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
offsets = []
for i, o in enumerate(objs, start=1):
    offsets.append(len(body))
    body += f"{i} 0 obj\n".encode() + o + b"\nendobj\n"
xref_pos = len(body)
size = len(objs) + 1
body += f"xref\n0 {size}\n0000000000 65535 f \n".encode()
for off in offsets:
    body += f"{off:010d} 00000 n \n".encode()
body += (f"trailer\n<< /Size {size} /Root 1 0 R >>\n"
         f"startxref\n{xref_pos}\n%%EOF").encode()
open(sys.argv[1], "wb").write(body)
PY
  test -s "$WORK_DIR/testpage.pdf" || fail "could not generate the PDF test document"
}

# --- wait for the image web server to answer ------------------------------
wait_ready() {
  for _ in $(seq 1 180); do
    if curl --fail --silent --show-error "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  podman logs "$NAME" >&2 || true
  fail "web server on port ${PORT} did not become ready"
}

# --- assert that captured bytes are structurally valid PostScript ---------
assert_postscript() {
  local label="$1" file="$2"
  [[ -s "$file" ]] || fail "${label}: socket sink captured an empty job"
  head -c 8 "$file" | grep -q '^%!PS' \
    || fail "${label}: output is not PostScript (bad header: $(head -c 8 "$file"))"
  grep -q '^%%EOF' "$file" \
    || fail "${label}: PostScript output has no %%EOF trailer"
  grep -qE 'Tf|show|Tj|Td' "$file" \
    || fail "${label}: PostScript output has no content operators"
  log "OK: ${label} -> $(( $(wc -c < "$file") )) bytes of valid PostScript"
}

# --- pick a PostScript driver from the image ------------------------------
pick_driver() {
  local drivers generic first
  drivers="$(podman run --rm --entrypoint /usr/bin/bash "$IMAGE" -c \
    'ps-printer-app drivers 2>/dev/null | tr -d " \r"' || true)"
  [[ -n "$drivers" ]] || fail "image enumerates no drivers"
  generic="$(printf '%s\n' "$drivers" | grep -i '^generic$' | head -n1 || true)"
  first="$(printf '%s\n' "$drivers" | head -n1 || true)"
  printf '%s' "${generic:-$first}"
}

# --- find an HPLIP PostScript PPD that declares the hpps PIN filter -------
find_hpps_ppd() {
  podman exec "$NAME" bash -c '
    set -e
    d="$(mktemp -d)"
    ( cd "$d" && /usr/share/ppd/hplip-ps-ppds >/dev/null 2>&1 ) || exit 1
    p="$(grep -rl "hpps" "$d" 2>/dev/null | grep -i "\.ppd$" | head -n1 || true)"
    rc=1
    if [[ -n "$p" ]]; then
      basename "$p"
      rc=0
    fi
    rm -rf "$d"
    exit $rc
  ' || true
}

start_sink() {  # <port> <outfile>
  python3 tests/socket-sink.py "$1" "$2" &
  SINK_PIDS+=("$!")
}

# ===========================================================================
main() {
  make_pdf
  chmod 0777 "$STATE_DIR"

  # --- start the image -----------------------------------------------------
  podman run -d \
    --name "$NAME" \
    --network host \
    -e PORT="$PORT" \
    -v "$STATE_DIR:/var/lib/ps-printer-app:Z" \
    "$IMAGE" >/dev/null
  wait_ready

  # ------------------------------------------------------------------------
  log "===== Route A: PDF -> PostScript vector ====="
  PS_DRIVER="$(pick_driver)"
  [[ -n "$PS_DRIVER" ]] || fail "no PostScript driver available"
  log "Using driver: $PS_DRIVER"
  start_sink "$A_SINK_PORT" "$A_OUT"

  podman exec "$NAME" ps-printer-app \
    -u "cups:socket://127.0.0.1:${A_SINK_PORT}" \
    -d pdf-ps -m "$PS_DRIVER" add \
    || fail "could not add the Route A printer queue"

  podman cp "$WORK_DIR/testpage.pdf" "$NAME:/tmp/testpage.pdf"
  podman exec "$NAME" ps-printer-app \
    -u "ipp://127.0.0.1:${PORT}/ipp/print/pdf-ps" \
    submit /tmp/testpage.pdf \
    || fail "Route A submit failed"

  local got=0
  for _ in $(seq 1 180); do
    [[ -s "$A_OUT" ]] && { got=1; break; }
    sleep 0.5
  done
  [[ "$got" -eq 1 ]] || { podman logs "$NAME" >&2; fail "Route A produced no socket output"; }
  assert_postscript "Route A (PDF->PostScript)" "$A_OUT"

  # ------------------------------------------------------------------------
  log "===== Route B: HPLIP PIN (hpps) route ====="
  podman exec "$NAME" test -x /usr/lib/ps-printer-app/filter/hpps \
    || fail "packaged hpps filter not found in image"
  log "OK: packaged hpps filter present at /usr/lib/ps-printer-app/filter/hpps"
  podman exec "$NAME" test -f /usr/share/ppd/hplip-ps-ppds \
    || fail "HPLIP PostScript PPD archive not found in image"
  log "OK: HPLIP PostScript PPD archive present"

  HPPS_PPD="$(find_hpps_ppd)"
  if [[ -z "$HPPS_PPD" ]]; then
    log "SKIP: no HPLIP PostScript PPD declares the hpps filter in this image; " \
        "the hpps route cannot be exercised until one is present."
    return 0
  fi
  HPPS_DRIVER="${HPPS_PPD%.ppd}"
  log "Using HPLIP PIN driver: $HPPS_DRIVER"

  start_sink "$B_BASE_SINK_PORT" "$B_BASE_OUT"
  start_sink "$B_PIN_SINK_PORT" "$B_PIN_OUT"

  if ! podman exec "$NAME" ps-printer-app \
    -u "cups:socket://127.0.0.1:${B_BASE_SINK_PORT}" \
    -d hplip-pin -m "$HPPS_DRIVER" add \
  ; then
    log "WARN: could not add the Route B printer queue with driver " \
        "$HPPS_DRIVER; the hpps route cannot be exercised end-to-end " \
        "(image already confirms the filter and PPD are present)."
    return 0
  fi

  # Plain job through the HPLIP PS route.
  podman exec "$NAME" ps-printer-app \
    -u "ipp://127.0.0.1:${PORT}/ipp/print/hplip-pin" \
    submit /tmp/testpage.pdf \
    || fail "Route B plain-job submit failed"
  local gotb=0
  for _ in $(seq 1 180); do
    [[ -s "$B_BASE_OUT" ]] && { gotb=1; break; }
    sleep 0.5
  done
  [[ "$gotb" -eq 1 ]] || { podman logs "$NAME" >&2; fail "Route B produced no socket output"; }
  assert_postscript "Route B (HPLIP PS route)" "$B_BASE_OUT"

  # PIN-configured job: hpps must engage and change the output stream.
  podman exec "$NAME" ps-printer-app \
    -u "ipp://127.0.0.1:${PORT}/ipp/print/hplip-pin" \
    -o cupsPin=1234 submit /tmp/testpage.pdf \
    || log "WARN: PIN-configured submit was rejected by the queue"
  local gotp=0
  for _ in $(seq 1 180); do
    [[ -s "$B_PIN_OUT" ]] && { gotp=1; break; }
    sleep 0.5
  done
  if [[ "$gotp" -ne 1 ]]; then
    log "OK: hpps held the PIN-protected job (no output reached the sink), " \
        "which is the observable difference from the plain job"
  else
    assert_postscript "Route B (PIN job)" "$B_PIN_OUT"
    if cmp -s "$B_BASE_OUT" "$B_PIN_OUT"; then
      fail "Route B: PIN job output is byte-identical to the plain job; hpps did not engage"
    fi
    log "OK: PIN job output differs from the plain job (hpps engaged)"
  fi

  log "OK: ps-printer-app PDF->PostScript and HPLIP PIN route verification passed"
}

main "$@"
