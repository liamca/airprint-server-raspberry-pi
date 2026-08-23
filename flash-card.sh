#!/usr/bin/env bash
#
# Flash Raspberry Pi OS Lite to an SD card from macOS and pre-configure it for
# headless use (hostname, user, SSH, Wi-Fi) so the Pi boots straight onto your
# network with no keyboard or monitor attached.
#
# Usage:
#   ./flash-card.sh                                  # list candidate SD cards
#   ./flash-card.sh --disk /dev/disk4 --wifi "MySSID"
#   ./flash-card.sh --disk /dev/disk4 --ethernet
#
# You will be prompted (in this terminal, never stored) for the new Pi login
# password and the Wi-Fi password.
#
set -euo pipefail

PI_HOSTNAME="airprint"
PI_USER="pi"
ARCH="arm64"
DISK=""
WIFI_SSID=""
WIFI_COUNTRY="US"
USE_WIFI=1
TIMEZONE="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')"
TIMEZONE="${TIMEZONE:-America/Los_Angeles}"
IMAGE_FILE=""
FORCE=0
CACHE_DIR="${HOME}/Downloads/rpi-images"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Flash Raspberry Pi OS Lite for a headless AirPrint server.

  ./flash-card.sh                                  list candidate SD cards
  ./flash-card.sh --disk /dev/disk4 --wifi "MySSID"

Options:
  --disk /dev/diskN   Target SD card. THIS DISK WILL BE ERASED.
  --wifi SSID         Wi-Fi network to join on first boot.
  --ethernet          Skip Wi-Fi setup (Pi will use the wired port).
  --country CC        Wi-Fi regulatory country code (default US).
  --hostname NAME     Pi hostname (default airprint -> airprint.local).
  --user NAME         Login user to create (default pi).
  --arch arm64|armhf  OS build (default arm64; use armhf only for Pi 1/Zero W).
  --image FILE        Use an already-downloaded .img.xz or .img instead of downloading.
  --force             Allow writing to a non-external disk (dangerous).
  -h, --help          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk)     DISK="${2:?}"; shift 2 ;;
    --wifi)     WIFI_SSID="${2:?}"; USE_WIFI=1; shift 2 ;;
    --ethernet) USE_WIFI=0; shift ;;
    --country)  WIFI_COUNTRY="${2:?}"; shift 2 ;;
    --hostname) PI_HOSTNAME="${2:?}"; shift 2 ;;
    --user)     PI_USER="${2:?}"; shift 2 ;;
    --arch)     ARCH="${2:?}"; shift 2 ;;
    --image)    IMAGE_FILE="${2:?}"; shift 2 ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "Unknown argument: $1 (try --help)" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "This script is macOS-only. On Linux/Windows use Raspberry Pi Imager."
[[ "$ARCH" == "arm64" || "$ARCH" == "armhf" ]] || die "--arch must be arm64 or armhf"

# --------------------------------------------------------------- pick disk ---
# The built-in SD slot reports "Internal", so trust Removable/protocol instead.
disk_is_removable() {
  local info removable protocol
  info="$(diskutil info "$1" 2>/dev/null)" || return 1
  removable="$(printf '%s' "$info" | awk -F': *' '/Removable Media/ {print $2; exit}')"
  protocol="$(printf '%s' "$info"  | awk -F': *' '/Protocol:/ {print $2; exit}')"
  [[ "$removable" == Removable* ]] && return 0
  [[ "$protocol" == "Secure Digital" || "$protocol" == "USB" ]] && return 0
  return 1
}

list_disks() {
  echo
  log "Removable disks (SD cards, USB drives):"
  local found=0 dev
  while read -r dev; do
    if disk_is_removable "$dev"; then
      found=1
      echo
      diskutil list "$dev" || true
    fi
  done < <(diskutil list | grep -oE '^/dev/disk[0-9]+')
  [[ $found -eq 1 ]] || echo "  (none found - is the card seated properly?)"
  echo
  echo "Find your card's /dev/diskN above, then re-run:"
  echo "  ./flash-card.sh --disk /dev/diskN --wifi \"YourSSID\""
  echo
  warn "Double-check the number. The wrong one will erase the wrong drive."
}

if [[ -z "$DISK" ]]; then
  list_disks
  exit 0
fi

[[ "$DISK" =~ ^/dev/disk[0-9]+$ ]] || die "--disk must look like /dev/disk4 (whole disk, not a partition like disk4s1)"
diskutil info "$DISK" >/dev/null 2>&1 || die "$DISK not found. Run ./flash-card.sh with no arguments to list disks."

DISK_INFO="$(diskutil info "$DISK")"
DISK_SIZE="$(printf '%s' "$DISK_INFO" | awk -F': *' '/Disk Size/ {print $2; exit}')"
DISK_NAME="$(printf '%s' "$DISK_INFO" | awk -F': *' '/Device \/ Media Name/ {print $2; exit}')"

if ! disk_is_removable "$DISK"; then
  [[ $FORCE -eq 1 ]] || die "$DISK is not removable media. Refusing. (Pass --force only if you are certain.)"
  warn "Writing to non-removable media because --force was given."
fi

if [[ "$DISK_SIZE" == *TB* ]]; then
  [[ $FORCE -eq 1 ]] || die "$DISK is $DISK_SIZE - far too big to be an SD card. Refusing."
fi

# ----------------------------------------------------------------- confirm ---
cat <<EOF

  Target disk : $DISK
  Media       : ${DISK_NAME:-unknown}
  Size        : ${DISK_SIZE:-unknown}

  Hostname    : ${PI_HOSTNAME}.local
  User        : $PI_USER
  Network     : $( [[ $USE_WIFI -eq 1 ]] && echo "Wi-Fi \"${WIFI_SSID:-<prompt>}\" ($WIFI_COUNTRY)" || echo "Ethernet only" )
  OS          : Raspberry Pi OS Lite ($ARCH)

EOF
warn "EVERYTHING ON $DISK WILL BE PERMANENTLY ERASED."
read -r -p 'Type ERASE to continue: ' confirm
[[ "$confirm" == "ERASE" ]] || die "Aborted."

# --------------------------------------------------------------- passwords ---
if [[ $USE_WIFI -eq 1 && -z "$WIFI_SSID" ]]; then
  read -r -p 'Wi-Fi network name (SSID): ' WIFI_SSID
  [[ -n "$WIFI_SSID" ]] || die "SSID required (or use --ethernet)."
fi

read -r -s -p "Password for the new '$PI_USER' account: " PI_PASSWORD; echo
read -r -s -p "Confirm: " PI_PASSWORD2; echo
[[ "$PI_PASSWORD" == "$PI_PASSWORD2" ]] || die "Passwords do not match."
[[ ${#PI_PASSWORD} -ge 8 ]] || die "Use at least 8 characters."

WIFI_PASSWORD=""
if [[ $USE_WIFI -eq 1 ]]; then
  read -r -s -p "Wi-Fi password for \"$WIFI_SSID\": " WIFI_PASSWORD; echo
fi

# Hash the login password so it is never stored in plaintext on the card.
hash_password() {
  local pw="$1" out=""
  for ssl in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl; do
    if command -v "$ssl" >/dev/null 2>&1; then
      out="$(printf '%s' "$pw" | "$ssl" passwd -6 -stdin 2>/dev/null || true)"
      [[ "$out" == \$6\$* ]] && { printf '%s' "$out"; return 0; }
    fi
  done
  # macOS LibreSSL has no -6; fall back to Python's crypt (present through 3.12).
  out="$(PW="$pw" python3 - <<'PY' 2>/dev/null || true
import os, crypt
print(crypt.crypt(os.environ["PW"], crypt.mksalt(crypt.METHOD_SHA512)))
PY
)"
  [[ "$out" == \$6\$* ]] && { printf '%s' "$out"; return 0; }
  return 1
}

PI_PASSWORD_HASH="$(hash_password "$PI_PASSWORD")" \
  || die "Could not hash the password. Install OpenSSL 3 with: brew install openssl@3"
unset PI_PASSWORD PI_PASSWORD2

# ------------------------------------------------------------------ image ---
mkdir -p "$CACHE_DIR"

if [[ -z "$IMAGE_FILE" ]]; then
  log "Resolving latest Raspberry Pi OS Lite ($ARCH)..."
  base="https://downloads.raspberrypi.com/raspios_lite_${ARCH}_latest"
  resolved="$(curl -sIL -o /dev/null -w '%{url_effective}' "$base")"
  [[ "$resolved" == *.img.xz ]] || die "Unexpected download URL: $resolved"
  IMAGE_FILE="$CACHE_DIR/$(basename "$resolved")"

  if [[ -f "$IMAGE_FILE" ]]; then
    log "Using cached image: $IMAGE_FILE"
  else
    log "Downloading $(basename "$resolved") (~500 MB)..."
    curl -fL --progress-bar -o "$IMAGE_FILE.part" "$resolved"
    mv "$IMAGE_FILE.part" "$IMAGE_FILE"
  fi

  if curl -fsL -o "$IMAGE_FILE.sha256" "${resolved}.sha256" 2>/dev/null; then
    log "Verifying checksum..."
    expected="$(awk '{print $1; exit}' "$IMAGE_FILE.sha256")"
    actual="$(shasum -a 256 "$IMAGE_FILE" | awk '{print $1}')"
    [[ "$expected" == "$actual" ]] || die "Checksum mismatch. Delete $IMAGE_FILE and retry."
    log "Checksum OK."
  else
    warn "No published checksum found; skipping verification."
  fi
fi
[[ -f "$IMAGE_FILE" ]] || die "Image not found: $IMAGE_FILE"

# ------------------------------------------------------------------ write ---
RDISK="${DISK/\/dev\/disk//dev/rdisk}"

log "Unmounting $DISK..."
diskutil unmountDisk force "$DISK"

log "Writing image to $RDISK (several minutes; press Ctrl-T for progress)..."
if [[ "$IMAGE_FILE" == *.xz ]]; then
  if command -v xz >/dev/null 2>&1; then
    xz -dc "$IMAGE_FILE" | sudo dd of="$RDISK" bs=4m
  else
    python3 -c 'import lzma,sys,shutil; shutil.copyfileobj(lzma.open(sys.argv[1],"rb"), sys.stdout.buffer)' \
      "$IMAGE_FILE" | sudo dd of="$RDISK" bs=4m
  fi
else
  sudo dd if="$IMAGE_FILE" of="$RDISK" bs=4m
fi
sync

# ------------------------------------------------------- headless config ---
log "Waiting for the boot partition to mount..."
BOOT=""
for _ in {1..30}; do
  for candidate in /Volumes/bootfs /Volumes/boot; do
    [[ -d "$candidate" ]] && { BOOT="$candidate"; break 2; }
  done
  diskutil mountDisk "$DISK" >/dev/null 2>&1 || true
  sleep 1
done
[[ -n "$BOOT" ]] || die "Boot partition never appeared. Re-insert the card and re-run with --image $IMAGE_FILE to configure it."

# Raspberry Pi OS Trixie dropped custom.toml; provisioning is cloud-init now.
log "Writing cloud-init first-boot config to $BOOT"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/write-cloud-init.py" ]] \
  || die "write-cloud-init.py not found next to this script."

# Passed via the environment so secrets never land in argv (visible via ps).
if [[ $USE_WIFI -eq 1 ]]; then
  PI_HOSTNAME="$PI_HOSTNAME" PI_USER="$PI_USER" PI_PASSWORD_HASH="$PI_PASSWORD_HASH" \
  PI_TIMEZONE="$TIMEZONE" WIFI_SSID="$WIFI_SSID" WIFI_PASSWORD="$WIFI_PASSWORD" \
  WIFI_COUNTRY="$WIFI_COUNTRY" \
    python3 "$SCRIPT_DIR/write-cloud-init.py" "$BOOT"
else
  PI_HOSTNAME="$PI_HOSTNAME" PI_USER="$PI_USER" PI_PASSWORD_HASH="$PI_PASSWORD_HASH" \
  PI_TIMEZONE="$TIMEZONE" \
    python3 "$SCRIPT_DIR/write-cloud-init.py" "$BOOT"
fi

unset WIFI_PASSWORD PI_PASSWORD_HASH
sync

log "Ejecting..."
diskutil eject "$DISK"

cat <<EOF

Done.

  1. Put the card in the Raspberry Pi 3 and power it on.
  2. Give it ~3 minutes for the first boot (it expands the filesystem, reboots,
     then cloud-init creates your user and joins the network).
  3. From this Mac:

       ssh ${PI_USER}@${PI_HOSTNAME}.local

  4. Then copy this project over and install the print server:

       scp -r "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ${PI_USER}@${PI_HOSTNAME}.local:~/airprint-server
       ssh ${PI_USER}@${PI_HOSTNAME}.local
       cd ~/airprint-server && chmod +x *.sh && sudo ./setup.sh

Note: network-config on the card holds your Wi-Fi password in plaintext. That is
how cloud-init provisions Wi-Fi; the boot partition is FAT32 and cannot store
permissions, so treat the card as sensitive until first boot completes.
EOF
