#!/usr/bin/env bash
#
# Fallback: publish an explicit AirPrint Avahi service record.
#
# Modern CUPS (2.2+) advertises shared queues over DNS-SD by itself, and that is
# normally enough for iOS. Some setups still need a hand-written record that
# includes the URF/pdl keys iOS insists on. This writes one.
#
#   sudo ./airprint-avahi-fallback.sh <queue-name>
#
set -euo pipefail

PRINTER_NAME="${1:-}"
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

if [[ -z "$PRINTER_NAME" ]]; then
  PRINTER_NAME="$(lpstat -p 2>/dev/null | awk '/^printer/ {print $2; exit}')"
fi
[[ -n "$PRINTER_NAME" ]] || { echo "No queue name given and none found." >&2; exit 1; }
lpstat -p "$PRINTER_NAME" >/dev/null 2>&1 || { echo "Queue '$PRINTER_NAME' does not exist." >&2; exit 1; }

DESC="$(lpstat -l -p "$PRINTER_NAME" 2>/dev/null | awk -F': ' '/Description/ {print $2; exit}')"
DESC="${DESC:-$PRINTER_NAME}"
OUT="/etc/avahi/services/AirPrint-${PRINTER_NAME}.service"

mkdir -p /etc/avahi/services
cat > "$OUT" <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">AirPrint ${DESC} @ %h</name>
  <service>
    <type>_ipp._tcp</type>
    <subtype>_universal._sub._ipp._tcp</subtype>
    <port>631</port>
    <txt-record>txtvers=1</txt-record>
    <txt-record>qtotal=1</txt-record>
    <txt-record>rp=printers/${PRINTER_NAME}</txt-record>
    <txt-record>ty=${DESC}</txt-record>
    <txt-record>note=Raspberry Pi AirPrint</txt-record>
    <txt-record>adminurl=http://%h.local:631/printers/${PRINTER_NAME}</txt-record>
    <txt-record>priority=0</txt-record>
    <txt-record>product=(GPL Ghostscript)</txt-record>
    <txt-record>printer-state=3</txt-record>
    <txt-record>printer-type=0x801046</txt-record>
    <txt-record>Transparent=T</txt-record>
    <txt-record>Binary=T</txt-record>
    <txt-record>Fax=F</txt-record>
    <txt-record>Color=F</txt-record>
    <txt-record>Duplex=F</txt-record>
    <txt-record>Staple=F</txt-record>
    <txt-record>Copies=T</txt-record>
    <txt-record>Collate=F</txt-record>
    <txt-record>Punch=F</txt-record>
    <txt-record>Bind=F</txt-record>
    <txt-record>Sort=F</txt-record>
    <txt-record>Scan=F</txt-record>
    <txt-record>pdl=application/octet-stream,application/pdf,application/postscript,image/jpeg,image/png,image/urf</txt-record>
    <txt-record>URF=W8,SRGB24,CP1,RS600,DM1,FN3</txt-record>
    <txt-record>UUID=$(cat /proc/sys/kernel/random/uuid)</txt-record>
    <txt-record>air=none</txt-record>
  </service>
</service-group>
EOF

chmod 644 "$OUT"
systemctl restart avahi-daemon
echo "Wrote $OUT and restarted avahi-daemon."
echo "Re-check with: ./verify.sh $PRINTER_NAME"
