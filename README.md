# AirPrint Server on a Raspberry Pi (Brother HL-2170W)

Turn an old USB-only laser printer into a **driverless network printer** that every
modern device can use — iPad, iPhone, Android, Windows, macOS, Linux, ChromeOS —
using a Raspberry Pi as a print server.

```
iPad ─────┐
Android ──┤
Windows ──┼── IPP / Bonjour ──▶  Raspberry Pi  ──USB──▶  Brother HL-2170W
macOS ────┤                     (CUPS + Avahi
Linux ────┘                      + brlaser)
```

## The problem this solves

The Brother HL-2170W is a **host-based** printer: it has no PostScript or PCL
interpreter, so it relies entirely on a driver on the computer. Brother's drivers
are long unmaintained and won't install on current macOS or Windows, which leaves
a perfectly good laser printer effectively unusable.

A Raspberry Pi fixes this. The open-source **brlaser** driver runs on the Pi, and
CUPS re-publishes the printer as a standards-compliant IPP device. The Pi does all
the driver work, so no client needs a driver — including devices like an iPad that
could never have one.

The result advertises itself as **AirPrint**, **IPP Everywhere** and **Mopria**
simultaneously, which is why every platform sees it natively.

---

## Hardware

| Item | Notes |
| --- | --- |
| Raspberry Pi | Pi 3 Model B or newer. A Pi 3B is plenty — CUPS + Avahi idle under 100 MB. |
| Power supply | **5V / 2.5A minimum.** See the warning below. |
| microSD card | 8 GB or larger |
| Printer connection | USB-B cable to the Pi (simplest), or the printer's own Wi-Fi |
| Network | Pi and clients on the **same subnet** — mDNS does not route |

### ⚠️ Power supply — read this

Under-voltage is the single most common cause of a flaky Pi print server: jobs
that stall halfway, USB devices that vanish, Wi-Fi that drops.

The Pi flags under-voltage when the 5V rail sags below ~4.63V, and on a Pi 3 that
is almost always **resistive loss in a thin micro-USB cable**, not an underpowered
charger. A "2.4A" charger with a cheap 2 m cable will under-volt; a 2.5A supply
with a short captive cable won't.

Use the official Raspberry Pi 5.1V 2.5A PSU, or any 5.1–5.25V / 2.5A+ supply with
a **short, thick, captive** cable. Check with:

```bash
vcgencmd get_throttled
```

`0x0` is healthy. Anything else means trouble:

| Bit | Meaning |
| --- | --- |
| 0 | Under-voltage detected **now** |
| 1 | Arm frequency capped now |
| 2 | Currently throttled |
| 16 | Under-voltage has occurred since boot |
| 18 | Throttling has occurred since boot |

Bits 16–19 are **sticky** — they record that it happened at any point since boot,
so reboot before re-testing a new power supply.

### Pi 3 Wi-Fi note

The Pi 3B's radio is **2.4 GHz only**. Fine on a normal router that bridges both
bands onto one subnet. If your 2.4 and 5 GHz bands are separate isolated SSIDs,
mDNS won't cross and clients won't discover the printer. Wired Ethernet avoids the
question entirely and is the more reliable choice for a print server.

---

## Part 1 — Flash the SD card

Two options; both produce a headless Pi you can SSH into.

### Option A: scripted (macOS)

```bash
chmod +x *.sh

./flash-card.sh                                     # list removable disks
./flash-card.sh --disk /dev/disk4 --wifi "MySSID"   # flash it
./flash-card.sh --disk /dev/disk4 --ethernet        # or wired
```

It downloads the latest Raspberry Pi OS Lite (arm64), verifies the SHA-256, writes
the card, and generates cloud-init first-boot config. You're prompted in the
terminal for the login and Wi-Fi passwords — the login password is SHA-512 hashed
before being written, and nothing is stored on your Mac.

It refuses to write to non-removable media and makes you type `ERASE` to confirm.

### Option B: Raspberry Pi Imager (any platform, most reliable)

1. Install [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. **Choose Device** → your Pi model
3. **Choose OS** → Raspberry Pi OS (other) → **Raspberry Pi OS Lite (64-bit)**
4. **Choose Storage** → the microSD card
5. **Next** → **Edit Settings**:
   - Hostname `airprint`, username + password
   - Configure wireless LAN (SSID, password, **and country** — see below)
   - **Services** tab → Enable SSH → password authentication
6. **Save** → **Yes** → **Yes**

Imager is version-aware and always writes whatever the current OS build expects,
which makes it the safe choice if the scripted path ever breaks.

### ⚠️ Raspberry Pi OS *Trixie* removed `custom.toml`

Trixie (2026-06 and later) **dropped the Bookworm-era `custom.toml` mechanism
entirely**. Verified against the image itself:

| String searched in the OS image | Occurrences |
| --- | --- |
| `custom.toml` | **0** |
| `raspberrypi-sys-mods/firstboot` | **0** |
| `cloud-init` | 1771 |
| `sshswitch` | 23 |

A `custom.toml` dropped on a Trixie card is **silently ignored**. The Pi boots
normally, but no user account is created (the default `pi` account ships with
`lock_passwd: True`) and no Wi-Fi is configured — so it never appears on the
network and you can't log in. Headless provisioning is now done through
cloud-init's NoCloud datasource: `user-data`, `network-config`, `meta-data`.

**Recovering a card already written with `custom.toml`** — convert it in place, no
re-flash, no re-entering passwords:

```bash
python3 write-cloud-init.py /Volumes/bootfs --from-toml
```

This also bumps `instance_id` in `meta-data` so cloud-init re-runs on a card that
has already booted once.

---

## Part 2 — First boot

Insert the card, power on, and wait ~3 minutes. The Pi resizes the filesystem,
reboots, then cloud-init creates your user and joins the network.

```bash
ssh pi@airprint.local
```

If `airprint.local` doesn't resolve, find the Pi's IP in your router's DHCP client
list.

### ⚠️ "Wi-Fi is currently blocked by rfkill"

On Raspberry Pi 3B+ and later, **the Wi-Fi radio is soft-blocked until a WLAN
regulatory country is set.** If provisioning didn't set it, the radio simply stays
off and the Pi never joins any network — with no obvious error.

Fix it from a console (HDMI + keyboard) or over Ethernet:

```bash
sudo raspi-config nonint do_wifi_country US
sudo rfkill unblock wifi
rfkill list                                   # want "Soft blocked: no"
sudo nmcli --ask device wifi connect "MySSID"
hostname -I
```

If `raspi-config nonint …` drops you into the menu instead, navigate:
**5 Localisation Options → L4 WLAN Country → your country → Ok → Finish**.

### Update and enable SSH

```bash
sudo apt-get update && sudo apt-get full-upgrade -y
sudo systemctl enable --now ssh
sudo reboot
```

### Optional: key-based login

From your Mac, so later steps run without password prompts:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub pi@airprint.local
```

---

## Part 3 — Install the print server

Connect the printer to the Pi by USB and power it on, then:

```bash
# from your Mac, in this directory
scp -r . pi@airprint.local:~/airprint-server

ssh pi@airprint.local
cd ~/airprint-server
chmod +x *.sh
sudo ./setup.sh
```

`setup.sh` will:

1. install `cups`, `printer-driver-brlaser`, `avahi-daemon`, `avahi-utils`
   (plus `cups-filters`, `cups-ipp-utils`, `ghostscript`, `snmp` best-effort —
   package names drift between Debian releases)
2. enable sharing with `cupsctl --share-printers --remote-any`
   (remote *administration* stays off)
3. detect the printer — USB first with retries, then mDNS/SNMP, then a
   port-9100 subnet scan
4. create a shared CUPS queue with the right brlaser PPD and make it default

If auto-detection fails:

```bash
./find-printer.sh
sudo ./setup.sh --uri socket://192.168.1.50:9100
```

> Tip: hold **GO** on the HL-2170W for ~3 seconds to print its network config page.

### About the driver

`brlaser` ships PPDs for `br2130` and `br2140` but **not** a separate HL-2170W
entry — the HL-2140 / 2150N / 2170W share one print engine, so `br2140.ppd` is
correct. The queue description will read "Brother HL-2140 series"; that's expected.

---

## Part 4 — Verify

On the Pi:

```bash
./verify.sh
echo "test page" | lp -d BrotherHL2170W
```

From a Mac on the same network — this is what a client actually sees:

```bash
./check-airprint-mac.sh airprint.local
```

A healthy result:

```
  OK   airprint.local responds to ping
  OK   IPP port 631 is open
  OK   AirPrint printers advertised on this network:
         Brother HL-2170W @ airprint
  OK   Advertised with the _universal subtype (what iOS filters on)
```

The Bonjour TXT record should contain all three of these — they're what make it
work everywhere:

```
pdl=application/pdf,...,image/pwg-raster,image/urf
URF=V1.4,CP1,W8,PQ4,RS600,FN3
mopria-certified=1.3
```

---

## Part 5 — Connect your devices

### iPad / iPhone (AirPrint)

Nothing to install. Open anything → **Share** → **Print** → **Select Printer** →
**Brother HL-2170W @ airprint**.

> **Printing from Microsoft 365 on iPad:** Excel *for the web* has an unreliable
> print path in iPadOS Safari (it round-trips through a generated PDF and a pop-up
> window). If Print does nothing, turn off Safari's pop-up blocker, or use
> **File → Export → Download as PDF** and print the PDF from the Files app. The
> Excel iOS app's **⋯ → Print** is the smoothest route — and note that *viewing*
> is free on every M365 plan and screen size, so printing works even without an
> editing licence.

### Android (Mopria)

Built into Android 8+. Settings → Connected devices → Connection preferences →
**Printing** → **Default Print Service** → the printer appears automatically.
No app needed.

### Windows 10 / 11 (IPP class driver)

Settings → Bluetooth & devices → **Printers & scanners** → **Add device** →
"The printer that I want isn't listed" → **Add a printer using an IP address or
hostname** → Device type **IPP Device** → hostname:

```
http://airprint.local:631/printers/BrotherHL2170W
```

Use the IP form if mDNS doesn't resolve on Windows:

```
http://192.168.1.50:631/printers/BrotherHL2170W
```

### macOS

It appears automatically via Bonjour in **System Settings → Printers & Scanners →
Add**. Or from the command line:

```bash
lpadmin -p BrotherHL2170W_AirPrint -E \
  -v 'ipp://airprint.local:631/printers/BrotherHL2170W' \
  -m everywhere -D 'Brother HL-2170W (via Raspberry Pi)'
```

`-m everywhere` uses IPP Everywhere — driverless.

### Linux / ChromeOS

Discovered automatically by CUPS via DNS-SD.

> With several devices using it, give the Pi a **DHCP reservation** on your router.
> Bonjour clients don't care, but Windows may pin the IP address.

---

## Script reference

### `flash-card.sh` (run on macOS)

| Flag | Purpose |
| --- | --- |
| `--disk /dev/diskN` | Target SD card — required to actually write |
| `--wifi SSID` / `--ethernet` | Network mode for first boot |
| `--country CC` | Wi-Fi regulatory domain (default `US`) — **required for the radio to enable** |
| `--hostname NAME` | Default `airprint` → `airprint.local` |
| `--user NAME` | Login account to create (default `pi`) |
| `--arch arm64\|armhf` | OS build; `arm64` suits Pi 3 and later |
| `--image FILE` | Use an already-downloaded `.img.xz` |
| `--force` | Allow writing to non-removable media (dangerous) |

### `setup.sh` (run on the Pi, as root)

| Flag | Purpose |
| --- | --- |
| `--uri URI` | Skip detection: `usb://...` or `socket://<ip>:9100` |
| `--name NAME` | CUPS queue name (default `BrotherHL2170W`) |
| `--location TEXT` | Location label shown to clients |
| `--remote-admin` | Also expose the CUPS web UI on the LAN (off by default) |

### `write-cloud-init.py`

Settings come from the environment so secrets never appear in `argv` (world-readable
via `ps`): `PI_HOSTNAME`, `PI_USER`, `PI_PASSWORD_HASH`, `PI_TIMEZONE`, `WIFI_SSID`,
`WIFI_PASSWORD`, `WIFI_COUNTRY`.

```bash
python3 write-cloud-init.py /Volumes/bootfs               # from environment
python3 write-cloud-init.py /Volumes/bootfs --from-toml   # convert a custom.toml card
```

---

## Troubleshooting

### Pi never appears on the network

Work through these in order — they're ordered by how often they're the cause.

1. **Wi-Fi blocked by rfkill.** No WLAN country set → radio disabled. See Part 2.
2. **`custom.toml` on a Trixie card.** Silently ignored; no user, no Wi-Fi.
   Run `write-cloud-init.py --from-toml`.
3. **Wrong band / isolated SSID.** Pi 3 is 2.4 GHz only; guest networks and AP
   isolation block mDNS.
4. **Power.** Check `vcgencmd get_throttled`.

**Diagnosing from the card itself.** Put it back in your Mac and inspect
`/Volumes/bootfs`:

| Observation | Meaning |
| --- | --- |
| `custom.toml` still present | Not consumed — wrong provisioning mechanism for this OS |
| `cmdline.txt` still contains ` resize` | The Pi has **never** booted |
| ` resize` gone, `PARTUUID` changed | The Pi **did** boot and ran first-boot resize |
| Every file still has the image build date | Nothing ran — suspect power or a dead card |
| `ssh` marker gone | The Pi booted far enough for `sshswitch.service` to enable SSH |

A `cmdline.txt` dated **1979** is a good sign, not a bad one — the Pi has no
real-time clock, so it writes files with an unset clock on first boot.

### iPad says "No AirPrint Printers Found"

1. `./verify.sh` on the Pi, and `./check-airprint-mac.sh` from a Mac
2. Same subnet? mDNS doesn't cross subnets, VLANs, guest networks, or AP isolation
3. Force an explicit AirPrint record: `sudo ./airprint-avahi-fallback.sh BrotherHL2170W`
4. Toggle the iPad's Wi-Fi to flush its Bonjour cache

### `lpinfo` / `cupsctl`: command not found

They live in `/usr/sbin`, which isn't on a normal user's `PATH`. Use `sudo`, or
`export PATH="$PATH:/usr/sbin"`. `verify.sh` and `find-printer.sh` handle this.

### `lpadmin: Bad device-uri`

The detected URI was garbage. Usually a script bug where log output leaked into a
`$(...)` capture — all logging in `setup.sh` goes to **stderr** for exactly this
reason. Check with `sudo lpinfo -v` and pass `--uri` explicitly.

### Printer not detected right after installing CUPS

The USB backend takes a few seconds to enumerate after `cupsd` starts.
`setup.sh` retries for ~12s. If it still misses, re-run it.

### "Filter failed" or blank pages

Wrong PPD. List and re-assign:

```bash
sudo lpinfo -m | grep -i brlaser
sudo lpadmin -p BrotherHL2170W -m 'drv:///brlaser.drv/br2140.ppd'
```

### Pages of garbage text

PostScript is being sent to a host-based printer. Make sure brlaser — not
"Generic PostScript Printer" — is selected at `http://<pi>:631/printers/`.

### Harmless log noise

These appear in `/var/log/cups/error_log` and can be ignored:

- `CreateProfile/CreateDevice failed: … ColorManager …` — `colord` isn't installed
  on Lite, and it's irrelevant for a mono laser
- `Printer drivers are deprecated …` — a CUPS 3 forward-compatibility notice
- `Scheduler shutting down due to program error` around setup time — `cupsd`
  restarting

### Wrong paper size

Defaults to US Letter. For A4:

```bash
sudo lpadmin -p BrotherHL2170W -o media=iso_a4_210x297mm -o PageSize=A4
```

---

## How it works

**CUPS** hosts the queue and does the rendering. Incoming jobs (PDF, JPEG, URF,
PWG-Raster) are converted and handed to **brlaser**, which emits the printer's
native host-based language over USB.

**Avahi** publishes the queue over DNS-SD. iOS looks for the
`_universal._sub._ipp._tcp` subtype plus `image/urf` in the `pdl` list; Android's
Mopria stack looks for `mopria-certified`; Windows and macOS use IPP Everywhere via
`image/pwg-raster`. Modern CUPS advertises all of these automatically for a shared
queue — `airprint-avahi-fallback.sh` exists only for the rare case where it doesn't.

Both `cups` and `avahi-daemon` are enabled as systemd services, so the whole thing
survives reboots with no further intervention.

---

## Files

| File | Purpose |
| --- | --- |
| [flash-card.sh](flash-card.sh) | Flashes Raspberry Pi OS Lite from macOS with headless config |
| [write-cloud-init.py](write-cloud-init.py) | Generates cloud-init `user-data`/`network-config`/`meta-data`; converts obsolete `custom.toml` cards |
| [setup.sh](setup.sh) | Main installer — packages, CUPS config, printer detection, queue creation |
| [find-printer.sh](find-printer.sh) | Locates the printer via USB, mDNS, and a port-9100 scan |
| [verify.sh](verify.sh) | Health check on the Pi — services, queue state, mDNS advertisement |
| [check-airprint-mac.sh](check-airprint-mac.sh) | Run on a Mac to confirm discoverability as a client sees it |
| [airprint-avahi-fallback.sh](airprint-avahi-fallback.sh) | Writes an explicit AirPrint Bonjour record if iOS is fussy |
| [uninstall.sh](uninstall.sh) | Removes the queue and optionally the packages |

---

## Security notes

- `--remote-any` lets any device on your LAN submit print jobs — that's what
  AirPrint requires. Remote **administration** of CUPS is disabled by default, so
  the web UI isn't exposed. Don't run this on an untrusted or public network.
- The login password is SHA-512 hashed before being written to the card. The Wi-Fi
  password is stored in plaintext in `network-config`, because that's how cloud-init
  provisions Wi-Fi and the boot partition is FAT32 (no permissions). Treat the card
  as sensitive until first boot completes.
- `write-cloud-init.py` takes secrets from the environment rather than `argv`, since
  command lines are world-readable through `ps`.
- If you enable passwordless `sudo` for convenience, remember that anyone with shell
  access as that user gets root without re-authenticating. Undo with
  `sudo rm /etc/sudoers.d/010_<user>-nopasswd`.

## Tested configuration

| Component | Version |
| --- | --- |
| Hardware | Raspberry Pi 3 Model B v1.2 |
| OS | Raspberry Pi OS Lite (Trixie / Debian 13), arm64 |
| CUPS | 2.4.10 |
| brlaser | 6.2.7 (`drv:///brlaser.drv/br2140.ppd`) |
| Printer | Brother HL-2170W over USB |
| Clients | iPadOS (AirPrint), macOS (IPP Everywhere) |
