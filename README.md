# Kyocera FS-1220MFP on modern Linux — driver fix & network sharing

*Read this in [Français](README.fr.md).*

**Goal:** make the Kyocera **FS-1220MFP** (a GDI/"host-based" laser MFP that only
speaks Kyocera's **KPSL** language) print again on a modern Linux system
(tested on **Debian 13 / trixie**, CUPS 2.4.10), and share it over the LAN so
that Chromebooks, Windows PCs, Android phones and iPhones/iPads can print too.

> This repository is **not affiliated with Kyocera**. "Kyocera" and "ECOSYS"
> are trademarks of their respective owners. The vendor driver is old, closed
> and unmaintained; this project documents how to revive it and how to replace
> its broken part with free software.

---

## What was broken (and why)

Two independent problems, both reproduced and root-caused:

1. **Missing shared library.** The CUPS filter `rastertokpsl` could not even
   start because `libcupsimage.so.2` was absent. On Debian 13 the package was
   renamed during the 64-bit `time_t` transition: `libcupsimage2` →
   **`libcupsimage2t64`**. Symptom: every job failed, the filter never ran.

2. **Stack buffer overflow in the closed-source filter.** The proprietary
   `rastertokpsl` copies the *job title* into a small fixed stack buffer. As
   soon as the title is longer than ~36 bytes, it corrupts adjacent memory and
   aborts (`SIGBUS` / `*** buffer overflow detected ***` / `malloc(): corrupted
   top size`). Long file names (typical for e-mail/PDF exports) made every
   "real" print fail, while a short test page worked.

See [`docs/debugging.en.md`](docs/debugging.en.md) (or
[`docs/debugging.fr.md`](docs/debugging.fr.md)) for the full investigation:
`ldd`, `coredumpctl`/`gdb` backtraces, threshold measurements, etc.

## The fix

- **Dependency:** install `libcupsimage2t64`.
- **Buffer overflow:** the closed binary cannot be patched, so a small
  **wrapper** ([`filters/rastertokpsl-wrapper.sh`](filters/rastertokpsl-wrapper.sh))
  truncates the job title and user name to 28 bytes (valid UTF-8) and then
  `exec`s the original binary, kept as `rastertokpsl.bin`.
- **Long-term / free alternative:** build and install
  **`rastertokpsl-re`** (an Apache-2.0 reverse-engineered reimplementation by
  [@sv99](https://github.com/sv99/rastertokpsl-re)), which does not have the
  overflow. Two tiny portability patches for modern glibc are provided in
  [`patches/`](patches/rastertokpsl-re-debian13.patch).
- **Network sharing:** expose the CUPS queue on the LAN
  (`Listen 0.0.0.0:631` + `Allow @LOCAL`) so any IPP/AirPrint/Mopria client can
  print. See section "Network sharing" below.
- **Suspend/hibernate:** a systemd-sleep hook re-enumerates the USB printer on
  resume.

## Tested — what, how, why

Honesty first: the table distinguishes **verified on hardware** from
**documented / expected**.

| Area | What was tested | How | Status |
|---|---|---|---|
| Debian 13, CUPS 2.4.10 | `rastertokpsl` fails to load (`libcupsimage.so.2` missing) | `ldd`, `cupsfilter`, CUPS `error_log` | ✅ verified |
| Dependency fix | install `libcupsimage2t64`, filter loads | `ldd`, test print | ✅ verified |
| Title overflow | crash threshold measured | ran `rastertokpsl.bin` as user `lp` via `runuser`, byte-length sweep | ✅ verified (36 B OK / 37 B crash under `lp`) |
| Wrapper | truncation avoids crash | same sweep through the wrapper | ✅ verified |
| Free filter build | `rastertokpsl-re` compiles on glibc 2.41 | `cmake` + `make`; `sigset`→`signal`, link `-lm` | ✅ verified |
| KPSL output parity | free vs vendor filter | `kpslcmp.pl` on identical rasters (sizes identical; only a small trailing region differs) | ✅ verified |
| USB printing | text page, 2-page PDF, 79-char title | `lp` + physical output | ✅ verified |
| LAN / IPP | CUPS listens on `0.0.0.0:631`, IPP answers, mDNS advertises, job sent over the LAN IP | `ss`, `curl`, `avahi-browse`, `lp -h <ip>` | ✅ verified |
| Scanner (SANE) | device detected, gray **and** color scans produced | `scanimage -L`, `scanimage` (PNG + PNM) | ✅ verified |
| Scanner udev | vendor rule (mode 0666 on *every* USB device) replaced by a Kyocera-only + `scanner`-group rule; scan still works | `ls -l /dev/bus/usb/...`, `scanimage` | ✅ verified |
| Scanner frontend | `simple-scan` installed | `apt`, SANE | ✅ installed (GUI not automated) |
| Chromebook | add printer via IPP / auto-discovery | documented steps | ⚠️ documented, not device-tested |
| Windows 10/11 | add shared printer by URL | documented steps | ⚠️ documented, not device-tested |
| Android / iOS | Mopria / AirPrint discovery | documented steps | ⚠️ documented, not device-tested |
| Suspend resume | USB re-enumeration hook | installed, manually invoked; **not** validated by a real hibernate cycle | ⚠️ partially verified |

Environment used: Debian 13 (trixie), CUPS 2.4.10, Ghostscript 10.05,
`libcupsimage2t64 2.4.10`, printer on USB (`0482:04fd`, serial `LBW6Y04191`).

## Why does it work this way?

The FS-1220MFP is a **host-based (GDI)** printer: it has no PostScript and no
PCL interpreter. The host must rasterize the page and send a proprietary
**KPSL** stream. That is why generic drivers cannot drive it and why the vendor
filter (frozen in **February 2013**, i.e. the Windows 8 era — see
`docs/debugging.en.md`) is load-bearing. CUPS still supports this "PPD + filter"
model, but deprecates it — so keeping a free, maintainable filter is the
durable path.

## Repository layout

```
ppd/        original Kyocera PPD (MIT) + modified PPD for rastertokpsl-re
filters/    our anti-overflow wrapper for the vendor binary
patches/    portability patch for rastertokpsl-re (modern glibc)
scripts/    install / uninstall / USB-reset / Kyocera-SANE helpers
udev/       tightened udev rule for scanner access (scanner group)
systemd/    systemd-sleep hook (USB re-enumeration on resume)
examples/   end-user "how to print" guide (HTML + PDF)
docs/       full investigation write-ups (EN + FR)
```

## Quick start

Prerequisites: Debian 12/13, CUPS, and (for the free filter) `cmake`,
`libcups2-dev`, `libcupsimage2-dev`.

```sh
# 1) the missing CUPS image library
sudo apt install libcupsimage2t64

# 2) free filter + PPD + queue
git clone https://github.com/sv99/rastertokpsl-re
cd rastertokpsl-re && git apply ../patches/rastertokpsl-re-debian13.patch
./../scripts/install-rastertokpsl-re.sh    # builds, installs filter, creates queue

# 3) test
lp -d Kyocera_RE /etc/hostname
```

Full manual procedure and the vendor-wrapper fallback are in
[`docs/debugging.en.md`](docs/debugging.en.md).

## Network sharing (Chromebook / Windows / Android / iOS)

On the CUPS host, edit `/etc/cups/cupsd.conf`:

```
Listen 0.0.0.0:631
...
<Location />
  Order allow,deny
  Allow @LOCAL
</Location>
```

then `sudo systemctl restart cups`. Clients on the same network can then use:

```
ipp://<host-ip>:631/printers/Kyocera_FS-1220MFP
ipp://<hostname>.local:631/printers/Kyocera_FS-1220MFP
```

A ready-to-print user guide is in
[`examples/guide-print-sharing.pdf`](examples/guide-print-sharing.pdf).

**Important:** the Linux host must stay powered on and awake — the printer is
attached to it over USB. It acts as a print server.

## Scanning (SANE) — yes, it works too

The scanner half of the MFP is a separate USB interface (vendor-specific class);
it is **not** supported by the SANE backends shipped with Debian. Kyocera
provides a Linux SANE driver (**v2.2.1511**, 2025, with a native `amd64` `.deb`)
which supports this model out of the box (`kyocera.conf` lists USB ID
`0x0482 0x04FD`, i.e. the FS-1220MFP).

```sh
sudo ./scripts/install-kyocera-sane.sh     # downloads from Kyocera, installs, tightens udev
scanimage -L                               # -> kyocera:libusb:... Kyocera FS-1220 ...
scanimage --resolution 300 --mode Gray -o scan.png
```

Or just use a GUI: `simple-scan` (recommended), `skanlite`, `xsane`,
`gscan2pdf`.

Two caveats, both handled by the script:

1. The Kyocera `.deb` depends on a package literally named `libsane`, which no
   longer exists on modern Debian (the library is provided by `libsane1`). The
   script installs a no-op stand-in so `apt` stays consistent.
2. The driver ships a **security-hostile udev rule** that sets `MODE:="0666"`
   on *almost every USB device*. The script replaces it with a rule limited to
   Kyocera devices (vendor `0482`) and the `scanner` group.

The Kyocera SANE driver is **proprietary, free of charge, and not redistributed
here** — the script downloads it from Kyocera's support site. See
[`CREDITS.md`](CREDITS.md).

**Limitation — the panel [Scan] button does not work on Linux.** On this model
the button triggers a *push* scan ("Direct scan" / "Quick scan": to PDF, e-mail
or folder) that is driven by Kyocera's **Client Tool**, a Windows-only utility.
The SANE backend is *pull*-only (you start the scan from the PC), so pressing
[Scan] on the machine has no effect without that Windows software. The panel
**[Copy]** function, by contrast, works standalone.

## Applicable to other models?

Yes, the **method** generalizes to many abandoned GDI/KPSL Kyocera models (and
to other "host-based" printers from other vendors):

1. Identify the protocol/PDL (here KPSL) and whether an open reimplementation
   exists.
2. Reproduce failures **offline** with `cupsfilter` and the filter directly,
   run under the real CUPS user (`lp`) — many bugs are layout/environment
   dependent.
3. Use `coredumpctl`/`gdb` on the filter rather than guessing.
4. Compare filter outputs byte-for-byte (`kpslcmp.pl`) before trusting a
   reimplementation.
5. Keep the vendor binary as a fallback behind a wrapper; prefer the free filter
   once parity is good enough.

## Sources & licenses

All third-party projects, their licences and the sources consulted are listed
in [`CREDITS.md`](CREDITS.md). This repository's own content is released under
the MIT licence (see [`LICENSE`](LICENSE)); the vendored Kyocera PPD is MIT as
stated in its own header; the `rastertokpsl-re` upstream is Apache-2.0.

## Discussion

- X: https://x.com/nsi_xyz/status/2101553295814783005
- Bluesky: https://bsky.app/profile/nsi.xyz/post/3mvwvbmgdkc2z
- Mastodon: https://mathstodon.xyz/@nsi_xyz/117301859263724242

## A note on cost

The whole diagnosis + rewrite + documentation session was carried out with an
AI assistant (DeepSeek V4.1 Flash) for about **US$ 0.24** — a useful reminder
that the "software" half of planned obsolescence is often cheap to fix when
someone bothers to.
