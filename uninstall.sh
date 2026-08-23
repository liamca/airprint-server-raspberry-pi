#!/usr/bin/env bash
#
# Remove the print queue and the AirPrint Avahi record created by setup.sh.
# Packages are left installed unless you pass --purge-packages.
#
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

PURGE=0
PRINTER_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-packages) PURGE=1; shift ;;
    *) PRINTER_NAME="$1"; shift ;;
  esac
done

if [[ -z "$PRINTER_NAME" ]]; then
  PRINTER_NAME="$(lpstat -p 2>/dev/null | awk '/^printer/ {print $2; exit}')"
fi

if [[ -n "$PRINTER_NAME" ]]; then
  echo "Removing queue: $PRINTER_NAME"
  lpadmin -x "$PRINTER_NAME" || true
  rm -f "/etc/avahi/services/AirPrint-${PRINTER_NAME}.service"
else
  echo "No queue found to remove."
fi

systemctl restart avahi-daemon || true
systemctl restart cups || true

if [[ $PURGE -eq 1 ]]; then
  echo "Removing packages..."
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    cups cups-filters cups-ipp-utils printer-driver-brlaser
  apt-get autoremove -y
fi

echo "Done."
