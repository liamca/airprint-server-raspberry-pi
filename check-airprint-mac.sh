#!/usr/bin/env bash
#
# From a Mac on the same network, check that the Pi's AirPrint queue is
# discoverable and reachable - i.e. what an iPad would see.
#
#   ./check-airprint-mac.sh [pi-host-or-ip]
#
set -uo pipefail

PI="${1:-airprint.local}"
SAMPLE_SECS=6

pass() { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }
info() { printf '  \033[1;34m..\033[0m   %s\n' "$*"; }

echo
echo "AirPrint reachability from this Mac"
echo "-----------------------------------"

if ping -c 2 -t 3 "$PI" >/dev/null 2>&1; then
  pass "$PI responds to ping"
else
  fail "$PI is not reachable"
fi

if nc -z -G 3 -w 3 "$PI" 631 >/dev/null 2>&1; then
  pass "IPP port 631 is open"
else
  fail "IPP port 631 is closed"
fi

# dns-sd browses continuously, so sample it in the background and stop it.
browse() {
  local type="$1" out
  out="$(mktemp)"
  dns-sd -B "$type" >"$out" 2>&1 &
  local pid=$?
  pid="$(jobs -p | tail -n1)"
  sleep "$SAMPLE_SECS"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  grep -E 'Add' "$out" | sed 's/^/       /'
  rm -f "$out"
}

echo
info "Bonjour _ipp._tcp (${SAMPLE_SECS}s sample)..."
IPP_OUT="$(browse _ipp._tcp)"
if [[ -n "$IPP_OUT" ]]; then
  pass "AirPrint printers advertised on this network:"
  echo "$IPP_OUT"
else
  fail "No _ipp._tcp advertisements seen from this Mac"
fi

echo
info "AirPrint _universal subtype (${SAMPLE_SECS}s sample)..."
# dns-sd spells subtypes "<type>,<subtype>", not the Avahi "_sub" form.
UNI_OUT="$(browse '_ipp._tcp,_universal')"
if [[ -n "$UNI_OUT" ]]; then
  pass "Advertised with the _universal subtype (what iOS filters on):"
  echo "$UNI_OUT"
else
  fail "Not advertised as _universal - iOS may not list it"
fi

echo
echo "If both Bonjour checks pass, the iPad will see the printer."
