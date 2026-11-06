#!/usr/bin/env bash
set -euo pipefail

# This appliance starts through the shared printing-base startup library
# (/usr/libexec/printer-app/entrypoint-common.sh) so every safety and bug fix
# made in that one script reaches it. The library validates PORT and the
# web-administration knobs, prepares and secures the state volume, seeds the
# CUPS defaults, and supervises the app; only the app-specific environment
# exports and /run/ps-printer-app stay here. See
# fsdk-containers docs/skills/printing-base.md (rule 8).

app=ps-printer-app
state=/var/lib/ps-printer-app

# Sourcing the library validates the knobs and builds printer_app_args; it does
# not touch state, change the umask, or install traps.
source /usr/libexec/printer-app/entrypoint-common.sh

# Validate PORT, the web-administration knobs and the instance name before any
# state is touched. The library refuses a malformed value with 64 and a setting
# this image cannot honour with 78.
printer_app_validate 'PostScript Printer Application'

# Prepare and secure the state volume, then seed the packaged CUPS defaults.
printer_app_prepare_state "$state" "$app"
printer_app_seed_cups "$state"

# App-specific CUPS/PAPPL environment. These paths are fixed by the image, not
# the volume.
export BACKEND_DIR=/usr/lib/ps-printer-app/backend
export CUPS_SERVERBIN=/usr/lib/ps-printer-app
export CUPS_SERVERROOT="$state/cups"
export FILTER_DIR=/usr/lib/ps-printer-app/filter
export PATH="$FILTER_DIR:$PATH"
export PPD_PATHS="${PPD_PATHS:-/usr/share/ppd/:$state/ppd/}"
export SPOOL_DIR="$state/spool"
export STATE_DIR="$state"
export STATE_FILE="$state/$app.state"
export TESTPAGE_DIR=/usr/share/ps-printer-app
export TMPDIR=/tmp
export USB_QUIRK_DIR="$state"

# The shared base creates /run/dbus and /run/avahi-daemon; this image keeps its
# own /run/ps-printer-app.
mkdir -p /run/ps-printer-app

# Start the app under the shared supervisor (creates /run/dbus and
# /run/avahi-daemon and runs dbus-daemon + avahi-daemon before the app).
printer_app_supervise /run "$app" -o "log-file=$state/$app.log" "${printer_app_args[@]}" server
