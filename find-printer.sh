#!/usr/bin/env bash
#
# Locate the Brother HL-2170W on the LAN (or on USB) and print the device URI
# you should pass to setup.sh --uri
#
set -euo pipefail

# lpinfo lives in /usr/sbin, which is not on a normal user's PATH.
PATH="$PATH:/usr/sbin:/usr/local/sbin"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

echo
log "1. USB-attached printers"
if command -v lpinfo >/dev/null; then
  lpinfo -v 2>/dev/null | grep -i '^direct' || echo "   (none)"
else
  lsusb 2>/dev/null | grep -i brother || echo "   (none - CUPS not installed yet)"
fi

echo
log "2. mDNS / Bonjour printer advertisements"
if command -v avahi-browse >/dev/null; then
  timeout 6 avahi-browse -rtp _pdl-datastream._tcp 2>/dev/null | grep '^=' | cut -d';' -f7,8 || true
  timeout 6 avahi-browse -rtp _ipp._tcp           2>/dev/null | grep '^=' | cut -d';' -f7,8 || true
else
  echo "   (avahi-utils not installed - run: sudo apt-get install -y avahi-utils)"
fi

echo
log "3. Scanning the local subnet for open port 9100 (raw/JetDirect)"
BASE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' | cut -d. -f1-3 || true)"
if [[ -z "$BASE" ]]; then
  echo "   (could not determine local subnet)"
  exit 0
fi
echo "   subnet: ${BASE}.0/24"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

for host in $(seq 1 254); do
  (
    if timeout 0.4 bash -c "exec 3<>/dev/tcp/${BASE}.${host}/9100" 2>/dev/null; then
      echo "${BASE}.${host}"
    fi
  ) &
done > "$TMP" 2>/dev/null
wait

if [[ -s "$TMP" ]]; then
  while read -r ip; do
    name=""
    if command -v snmpget >/dev/null; then
      name="$(timeout 2 snmpget -v1 -c public -Ovq "$ip" 1.3.6.1.2.1.25.3.2.1.3.1 2>/dev/null | tr -d '"' || true)"
    fi
    printf '   \033[1;32msocket://%s:9100\033[0m  %s\n' "$ip" "$name"
  done < <(sort -t. -k4 -n "$TMP")
  echo
  echo "Use the matching one, e.g.:  sudo ./setup.sh --uri socket://<IP>:9100"
else
  echo "   (nothing found - is the printer powered on and joined to the same Wi-Fi?)"
  echo "   Tip: hold GO on the HL-2170W for ~3s to print its network config page with the IP."
fi
