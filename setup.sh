#!/usr/bin/env bash
#
# Turn a Raspberry Pi (Raspberry Pi OS / Debian) into an AirPrint server
# for a Brother HL-2170W (or any other brlaser-supported Brother mono laser).
#
# Usage:
#   sudo ./setup.sh                          # auto-detect the printer (USB or network)
#   sudo ./setup.sh --uri socket://192.168.1.50:9100
#   sudo ./setup.sh --name Office --remote-admin
#
set -euo pipefail

PRINTER_NAME="${PRINTER_NAME:-BrotherHL2170W}"
PRINTER_LOCATION="${PRINTER_LOCATION:-Home}"
PRINTER_DESC="${PRINTER_DESC:-Brother HL-2170W}"
PRINTER_URI=""
ENABLE_REMOTE_ADMIN=0
ADMIN_USER="${SUDO_USER:-${USER:-pi}}"

# All logging goes to stderr so $(...) capture of a function's result stays clean.
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --uri URI          Device URI for the printer (skips auto-detection).
                     e.g. socket://192.168.1.50:9100  or  usb://Brother/HL-2170W?serial=...
  --name NAME        CUPS queue name (default: BrotherHL2170W). Letters/digits/_- only.
  --location TEXT    Human readable location shown on the iPad.
  --remote-admin     Also expose the CUPS web admin UI to the LAN (off by default).
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uri)          PRINTER_URI="${2:?--uri needs a value}"; shift 2 ;;
    --name)         PRINTER_NAME="${2:?--name needs a value}"; shift 2 ;;
    --location)     PRINTER_LOCATION="${2:?--location needs a value}"; shift 2 ;;
    --remote-admin) ENABLE_REMOTE_ADMIN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "Unknown argument: $1 (try --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this with sudo: sudo $0 $*"
[[ "$PRINTER_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "Queue name must contain only letters, digits, '_' and '-'."
command -v apt-get >/dev/null || die "This script targets Debian/Raspberry Pi OS (apt-get not found)."

# ---------------------------------------------------------------- packages ---
install_packages() {
  log "Installing CUPS, brlaser and Avahi..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    cups \
    printer-driver-brlaser \
    avahi-daemon \
    avahi-utils

  # Package names drift between Debian releases; these are helpful but optional.
  for pkg in cups-filters cups-ipp-utils ghostscript snmp; do
    apt-get install -y --no-install-recommends "$pkg" >/dev/null 2>&1 \
      || warn "Optional package '$pkg' unavailable, continuing."
  done
}

# ------------------------------------------------------------ cups config ---
configure_cups() {
  log "Configuring CUPS sharing..."
  systemctl enable --now cups >/dev/null
  systemctl enable --now avahi-daemon >/dev/null

  # Wait for the scheduler socket before talking to it.
  for _ in {1..20}; do
    cupsctl >/dev/null 2>&1 && break
    sleep 0.5
  done

  # --remote-any lets the iPad (and any LAN device) submit jobs.
  # Remote *admin* stays off unless explicitly requested.
  if [[ $ENABLE_REMOTE_ADMIN -eq 1 ]]; then
    cupsctl --share-printers --remote-any --remote-admin
    warn "CUPS web admin is now reachable at http://$(hostname).local:631/ - keep this off untrusted networks."
  else
    cupsctl --share-printers --remote-any --no-remote-admin
  fi

  if id -u "$ADMIN_USER" >/dev/null 2>&1; then
    usermod -aG lpadmin "$ADMIN_USER" || true
  fi
}

# ------------------------------------------------------ printer detection ---
detect_uri() {
  log "Looking for the printer..."

  # The USB backend can take a few seconds to enumerate after CUPS starts.
  local usb
  for _ in 1 2 3 4 5 6; do
    usb="$(lpinfo -v 2>/dev/null | awk '/^direct / {print $2}' \
          | grep -iE '^usb://.*brother' | head -n1 || true)"
    [[ -n "$usb" ]] && { echo "$usb"; return 0; }
    sleep 2
  done

  # 2. Advertised on the network via mDNS / SNMP (CUPS backends).
  local net
  net="$(lpinfo -v 2>/dev/null \
        | awk '/^network / {print $2}' \
        | grep -Ei 'brother|hl-?21' | head -n1 || true)"
  if [[ -n "$net" ]]; then
    # dnssd:// URIs can break when the printer changes name; prefer raw socket.
    local ip
    ip="$(printf '%s' "$net" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)"
    if [[ -n "$ip" ]]; then echo "socket://$ip:9100"; else echo "$net"; fi
    return 0
  fi

  # 3. Brute-force the local /24 for an open JetDirect port.
  local base
  base="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' | cut -d. -f1-3 || true)"
  if [[ -n "$base" ]]; then
    log "Scanning ${base}.0/24 for port 9100 (raw printing)..."
    local found=""
    for host in $(seq 1 254); do
      ( timeout 0.4 bash -c "exec 3<>/dev/tcp/${base}.${host}/9100" 2>/dev/null \
        && echo "${base}.${host}" ) &
    done > /tmp/airprint-scan.$$ 2>/dev/null
    wait
    found="$(head -n1 /tmp/airprint-scan.$$ 2>/dev/null || true)"
    rm -f /tmp/airprint-scan.$$
    if [[ -n "$found" ]]; then echo "socket://${found}:9100"; return 0; fi
  fi

  return 1
}

# ------------------------------------------------------------ ppd / model ---
detect_model() {
  # brlaser ships PPDs for the HL-21xx family; fall back to the generic one.
  local m
  for pattern in 'brlaser.*2170' 'brlaser.*2140' 'HL-2170' 'brlaser'; do
    m="$(lpinfo -m 2>/dev/null | grep -iE "$pattern" | head -n1 | awk '{print $1}' || true)"
    [[ -n "$m" ]] && { echo "$m"; return 0; }
  done
  return 1
}

# --------------------------------------------------------------- add queue ---
add_printer() {
  local uri="$1" model="$2"

  log "Adding queue '$PRINTER_NAME'"
  log "  device : $uri"
  log "  driver : $model"

  lpadmin -p "$PRINTER_NAME" \
          -v "$uri" \
          -m "$model" \
          -D "$PRINTER_DESC" \
          -L "$PRINTER_LOCATION" \
          -o printer-is-shared=true \
          -o media=na_letter_8.5x11in \
          -o PageSize=Letter \
          -E

  cupsenable "$PRINTER_NAME"
  cupsaccept "$PRINTER_NAME"
  lpadmin -d "$PRINTER_NAME"
}

# -------------------------------------------------------------------- main ---
main() {
  install_packages
  configure_cups

  if [[ -z "$PRINTER_URI" ]]; then
    PRINTER_URI="$(detect_uri || true)"
  fi
  [[ -n "$PRINTER_URI" ]] || die "Could not find the printer. Run ./find-printer.sh, then re-run with --uri socket://<IP>:9100"
  [[ "$PRINTER_URI" =~ ^(usb|socket|ipp|ipps|dnssd|lpd|http|https):// ]] \
    || die "Detected device URI looks wrong: '$PRINTER_URI'"

  local model
  model="$(detect_model || true)"
  [[ -n "$model" ]] || die "No brlaser PPD found. Check that 'printer-driver-brlaser' installed correctly."

  add_printer "$PRINTER_URI" "$model"

  systemctl restart cups
  systemctl restart avahi-daemon

  log "Done."
  echo
  echo "  Queue      : $PRINTER_NAME"
  echo "  Device URI : $PRINTER_URI"
  echo "  CUPS UI    : http://$(hostname -I | awk '{print $1}'):631/printers/$PRINTER_NAME"
  echo
  echo "Next: run ./verify.sh, then open something on the iPad and tap Share -> Print."
  echo "If the iPad does not see it, run: sudo ./airprint-avahi-fallback.sh $PRINTER_NAME"
}

main "$@"
