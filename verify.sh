#!/usr/bin/env bash
#
# Health check: is this Pi actually acting as an AirPrint server?
#
set -uo pipefail

# cupsctl/lpinfo live in /usr/sbin, which is not on a normal user's PATH.
PATH="$PATH:/usr/sbin:/usr/local/sbin"

PRINTER_NAME="${1:-}"

pass() { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
info() { printf '  \033[1;34m..\033[0m   %s\n' "$*"; }
FAILED=0

echo
echo "AirPrint server check"
echo "---------------------"

for svc in cups avahi-daemon; do
  if systemctl is-active --quiet "$svc"; then pass "$svc is running"; else fail "$svc is NOT running (sudo systemctl start $svc)"; fi
done

if [[ -z "$PRINTER_NAME" ]]; then
  PRINTER_NAME="$(lpstat -p 2>/dev/null | awk '/^printer/ {print $2; exit}')"
fi

if [[ -z "$PRINTER_NAME" ]]; then
  fail "No print queues configured (run sudo ./setup.sh)"
else
  pass "Queue found: $PRINTER_NAME"

  if lpstat -p "$PRINTER_NAME" 2>/dev/null | grep -q 'disabled'; then
    fail "Queue is disabled (sudo cupsenable $PRINTER_NAME)"
  else
    pass "Queue is enabled"
  fi

  if lpstat -a "$PRINTER_NAME" 2>/dev/null | grep -q 'accepting'; then
    pass "Queue is accepting jobs"
  else
    fail "Queue is rejecting jobs (sudo cupsaccept $PRINTER_NAME)"
  fi

  if lpstat -l -p "$PRINTER_NAME" >/dev/null 2>&1; then
    info "Device URI: $(lpstat -v "$PRINTER_NAME" 2>/dev/null | sed 's/.*: //')"
  fi
fi

SHARE_STATE="$(cupsctl 2>/dev/null || sudo -n cupsctl 2>/dev/null || true)"
if printf '%s' "$SHARE_STATE" | grep -q '_share_printers=1'; then
  pass "Printer sharing is on"
elif [[ -z "$SHARE_STATE" ]]; then
  info "Cannot read CUPS config without root - see the mDNS check below instead"
else
  fail "Printer sharing is off (sudo cupsctl --share-printers --remote-any)"
fi

echo
info "Checking mDNS advertisement (what the iPad looks for)..."
if command -v avahi-browse >/dev/null; then
  ADV="$(timeout 6 avahi-browse -rtp _ipp._tcp 2>/dev/null | grep '^=' | grep -i "$(hostname)" || true)"
  if [[ -n "$ADV" ]]; then
    pass "_ipp._tcp advertised by this host"
    echo "$ADV" | sed 's/^/       /'
  else
    fail "This host is not advertising _ipp._tcp - try: sudo ./airprint-avahi-fallback.sh $PRINTER_NAME"
  fi
else
  info "avahi-utils not installed, skipping"
fi

echo
if [[ -n "$PRINTER_NAME" && $FAILED -eq 0 ]]; then
  echo "Looks good. Send a test page with:"
  echo "  echo 'AirPrint test' | lp -d $PRINTER_NAME"
fi
exit $FAILED
