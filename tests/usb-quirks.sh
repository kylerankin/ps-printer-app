#!/usr/bin/env bash
#
# USB quirk seeding verification for the ps-printer-app FSDK OCI image.
#
# Issue #13 asks the entrypoint to hydrate the persistent USB quirk directory
# from the *installed* CUPS data path instead of a guessed one. core-appliance.sh
# checks the seeded file exists and is preserved across a restart, but not that
# it is the default CUPS quirk table the image ships. This test starts the built
# image the way a user does (nonroot, host network, a fresh empty state volume)
# and checks, from the host:
#   - the packaged default exists at the installed path the entrypoint seeds
#     from, /usr/share/cups/usb/org.cups.usb-quirks;
#   - the seeded file at $USB_QUIRK_DIR/usb (i.e.
#     /var/lib/ps-printer-app/usb/org.cups.usb-quirks) exists, is a readable
#     regular file, and is byte-for-byte that packaged default, so a fresh
#     state seeds the installed defaults rather than an empty or guessed table;
#   - a user edit of that file survives a restart: the entrypoint seeds only a
#     missing file, so the override is not overwritten.
#
# Physical USB printing is not verified: no printer hardware is available.
#
# Environment:
#   IMAGE  image to verify (default ghcr.io/projectbluefin/ps-printer-app:build,
#          the tag `just build` produces)
#   PORT   printer application port (default 18090)
set -euo pipefail

image="${IMAGE:-ghcr.io/projectbluefin/ps-printer-app:build}"
name="ps-printer-app-usb-quirks"
port="${PORT:-18090}"

state_dir="$(mktemp -d)"

# The quirk directory the base libusb backend reads, and the packaged default
# the entrypoint seeds it from.
quirk_state="/var/lib/ps-printer-app/usb/org.cups.usb-quirks"
quirk_packaged="/usr/share/cups/usb/org.cups.usb-quirks"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  podman rm -f "$name" >/dev/null 2>&1 || true
  podman unshare rm -rf "$state_dir" >/dev/null 2>&1 || true
  rm -rf "$state_dir"
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

for tool in podman curl; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done
podman image inspect "$image" >/dev/null 2>&1 || fail "image $image not found; run just build first"

echo "== Appliance start =="
chmod 0777 "$state_dir"
podman run -d \
  --name "$name" \
  --network host \
  -e PORT="$port" \
  -v "$state_dir:/var/lib/ps-printer-app:Z" \
  "$image" >/dev/null
if ! wait_for_http "$port"; then
  podman logs "$name" >&2 || true
  fail "the web interface did not answer on port $port"
fi
echo "  ok: appliance started on port $port"

echo "== The packaged default quirk table exists at the installed CUPS path =="
# The packaged default must live at the installed path the entrypoint seeds
# from. A container that started means its `cp` under `set -e` succeeded, but
# assert it here so a path change fails this test, not the next.
podman exec "$name" /usr/bin/test -f "$quirk_packaged" ||
  fail "the packaged quirk table $quirk_packaged is missing from the image"

# The quirk directory and file must exist in the state volume, and the file
# must be a readable regular table, not a directory or an unreadable file.
podman exec "$name" /usr/bin/test -d "$(dirname "$quirk_state")" ||
  fail "USB quirk directory $(dirname "$quirk_state") is missing"
podman exec "$name" /usr/bin/test -f "$quirk_state" ||
  fail "USB quirk file $quirk_state is missing"
podman exec "$name" /usr/bin/test -r "$quirk_state" ||
  fail "USB quirk file $quirk_state is not readable"

# The seeded file is the default CUPS quirk table: it must be non-empty and
# byte-for-byte the packaged default, so a fresh state seeds the installed
# defaults rather than an empty or guessed table.
podman exec "$name" /usr/bin/test -s "$quirk_state" ||
  fail "the seeded USB quirk table is empty"
if ! podman exec "$name" /usr/bin/cmp -s "$quirk_state" "$quirk_packaged"; then
  podman exec "$name" /usr/bin/bash -c '
    echo "== seeded =="; cat /var/lib/ps-printer-app/usb/org.cups.usb-quirks
    echo "== packaged =="; cat /usr/share/cups/usb/org.cups.usb-quirks
  ' >&2
  fail "the seeded quirk table is not the packaged default at $quirk_packaged"
fi
echo "  ok: $quirk_state is a readable default table, identical to $quirk_packaged"

echo "== Fresh state seeds the default table under USB_QUIRK_DIR/usb =="
podman exec "$name" /usr/bin/bash -c 'printf "%s\n" "# preserved USB quirks" >> /var/lib/ps-printer-app/usb/org.cups.usb-quirks'
podman stop --time 5 "$name" >/dev/null
podman run -d \
  --name "$name" \
  --network host \
  -e PORT="$port" \
  -v "$state_dir:/var/lib/ps-printer-app:Z" \
  "$image" >/dev/null
if ! wait_for_http "$port"; then
  podman logs "$name" >&2 || true
  fail "the web interface did not answer on port $port after restart"
fi
podman exec "$name" /usr/bin/bash -c '
  test "$(tail -n 1 /var/lib/ps-printer-app/usb/org.cups.usb-quirks)" = "# preserved USB quirks"
' || fail "the entrypoint overwrote the persisted USB quirk edit on restart"
echo "  ok: the seeded table is preserved once and a user edit survives restart"

printf 'PASS: %s seeds the default USB quirk table from the installed CUPS path and preserves edits\n' "$image"
