# Full investigation — Kyocera FS-1220MFP on Debian 13

*Version française : [`debugging.fr.md`](debugging.fr.md).*

**Printer:** Kyocera FS-1220MFP, monochrome laser MFP.
**Language:** KPSL / GDI ("host-based") — the printer understands neither PCL
nor PostScript, so the host must rasterize pages and emit a proprietary KPSL
stream via the `rastertokpsl` filter.
**Host:** Debian GNU/Linux 13 (trixie), CUPS 2.4.10, USB connection
(`usb://Kyocera/FS-1220MFP?serial=LBW6Y04191`, USB ID `0482:04fd`).
**Vendor package:** Kyocera "Aquarius MFP EU 3.2 RC2" CD-ROM. The Windows driver
binaries inside are dated **2013-02-21** (`GXDriver 5.2.2621`,
`G-XPS 3.0.2621.0`) — i.e. the Windows 8 era. There is no Windows 8.1/10/11
update for this model.

---

## 1. Problem #1 — nothing prints at all (missing library)

### Symptom

The CUPS queue `Kyocera_FS-1220MFP` exists and accepts jobs, but every job
fails. The filter never even starts.

### Diagnosis

```console
$ ldd /usr/lib/cups/filter/rastertokpsl
    libcupsimage.so.2 => not found
$ /usr/lib/cups/filter/rastertokpsl
/usr/lib/cups/filter/rastertokpsl: error while loading shared libraries:
libcupsimage.so.2: cannot open shared object file: No such file or directory
```

`libcupsimage.so.2` was missing. During Debian 13's 64-bit `time_t` transition
the package was renamed `libcupsimage2` → **`libcupsimage2t64`**, so the old
package name (the filter's dependency) no longer exists.

### Fix

```sh
sudo apt install libcupsimage2t64
```

```console
$ ldd /usr/lib/cups/filter/rastertokpsl | grep cupsimage
    libcupsimage.so.2 => /lib/x86_64-linux-gnu/libcupsimage.so.2
```

A simple test page now prints.

---

## 2. Problem #2 — "real" documents fail (`Filter failed`)

### Symptom

A short test page prints, but a document sent from an application fails. The job
sticks, then:

```
Status: Filter failed
Alerts: cups-filter-crashed
```

In `/var/log/cups/error_log`:

```
[Job 828] PID ... (/usr/lib/cups/filter/rastertokpsl) crashed on signal 6.
**** Error: Page drawing error occurred.
```

sometimes `signal 7 (SIGBUS)`.

### Reproduction

The filter crashes depending on the **length of the job title**. Reproduced
outside CUPS, as the CUPS filter user `lp`:

```console
$ sudo runuser -u lp -- /usr/lib/cups/filter/rastertokpsl.bin 1 user "$TITLE" 1 "$OPTS" raster.file
```

| Title length (bytes) | Result |
|---|---|
| 4 (`test`) | OK |
| 8 … 36 | OK |
| 37 | crash `SIGBUS` |
| 60 | crash |
| 64 (as root/uid 1000) | crash `SIGABRT` — `*** buffer overflow detected ***` |

The threshold is **the same for ASCII and accented text** (36 bytes OK, 37
crashes). Proof with a title made only of accented `é` (2 bytes each):

```
accents: 36 bytes -> ok=3/3
accents: 37 bytes -> ok=0/3
```

> **Buffer overflow or accents?** It is a **buffer overflow** driven by the
> **byte length** of the title. Accents are not the cause; they merely consume
> 2 bytes per character, so the ceiling is reached with fewer visible
> characters. (The `rastertokpsl-re` project also mentions a separate non-ASCII
> encoding bug, but the crash here is length.)

### Root cause (core dump analysis)

Cores are captured by `systemd-coredump`. `coredumpctl info <pid>` and `gdb`
give:

```
#0  0x40c182  mov 0x0(%rbp,%rax,1),%rsi
#1  0x40c3be  cupsGetOption
#2  0x40752e
#3  __libc_start_main
```

At the fault, `rbp` (the `cups_option_t *` array base) holds UTF-16 text instead
of a valid address: the stack buffer holding the **title** overflows into
adjacent variables. A textbook stack buffer overflow in the closed binary.

### Fix (band-aid)

The binary is closed and cannot be patched, so a **wrapper**
([`../filters/rastertokpsl-wrapper.sh`](../filters/rastertokpsl-wrapper.sh))
truncates the title and user name to **28 bytes** (safely below the 36-byte
threshold) on a valid UTF-8 boundary, then `exec`s the real binary, kept as
`/usr/lib/cups/filter/rastertokpsl.bin`.

```sh
#!/bin/sh
orig="/usr/lib/cups/filter/rastertokpsl.bin"
max=28
trunc() { printf '%s' "$1" | head -c "$max" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null; }
if [ "$#" -ge 3 ]; then
    jobid="$1"; user="$2"; title="$3"; shift 3
    title=$(trunc "$title"); [ -z "$title" ] && title="job"
    user=$(trunc "$user");   [ -z "$user" ]  && user="user"
    exec "$orig" "$jobid" "$user" "$title" "$@"
fi
exec "$orig" "$@"
```

Validated as user `lp`, including accented titles and the previously failing
PDF.

Restore the original binary any time with:

```sh
sudo cp -a /usr/lib/cups/filter/rastertokpsl.bin /usr/lib/cups/filter/rastertokpsl
```

> Note: this remains a workaround on a memory-unsafe binary (a heap corruption
> `malloc(): corrupted top size` was also observed on one raster). The durable
> fix is the free reimplementation below.

---

## 3. Free driver — `rastertokpsl-re`

`rastertokpsl-re` is an Apache-2.0 reverse-engineered reimplementation of the
KPSL filter: <https://github.com/sv99/rastertokpsl-re>.

### Build dependencies

```sh
sudo apt install cmake libcups2-dev libcupsimage2-dev
```

### Two portability patches (2015 code, glibc 2.41)

1. `sigset` (a BSD extension) no longer exists — in `src/rastertokpsl.c`:

   ```diff
   -        sigset(SIGTERM, CancelJob);
   +        signal(SIGTERM, CancelJob);
   ```

2. Link against libm (the code uses `ceil`) — in `src/CMakeLists.txt`:

   ```diff
   -target_link_libraries(rastertokpsl-re ${CUPS_LIB} ${CUPSIMAGE_LIB})
   +target_link_libraries(rastertokpsl-re ${CUPS_LIB} ${CUPSIMAGE_LIB} m)
   ```

Both are bundled in [`../patches/rastertokpsl-re-debian13.patch`](../patches/rastertokpsl-re-debian13.patch).

### Build

```sh
cd rastertokpsl-re
mkdir -p build && cd build
cmake .. && make rastertokpsl-re      # -> bin/rastertokpsl-re
```

### Install

```sh
sudo install -o root -g root -m 755 \
    rastertokpsl-re/bin/rastertokpsl-re /usr/lib/cups/filter/rastertokpsl-re
```

The modified PPD `ppd/Kyocera_FS-1220MFPGDI_RE.ppd` points to it:

```
*cupsFilter: "application/vnd.cups-raster 0 /usr/lib/cups/filter/rastertokpsl-re"
```

Create a test queue:

```sh
sudo lpadmin -p Kyocera_RE -E \
    -v 'usb://Kyocera/FS-1220MFP?serial=LBW6Y04191' \
    -P ppd/Kyocera_FS-1220MFPGDI_RE.ppd -D 'Kyocera FS-1220MFP (RE)'
```

### Validation — output parity

`kpslcmp.pl` (from the upstream repo) compares the KPSL produced by the vendor
filter and by the free filter on identical rasters, ignoring user/title/timestamp:

| Raster | Vendor size | RE size | Diff |
|---|---|---|---|
| 1-page test | 5196 B | 5196 B | identical except ~288 B at the end of the stream |
| 2-page PDF | 724116 B | 724116 B | identical except ~3.2 KB at the end of the stream |

Same size, same header; only a small trailing region (end-of-band / end-of-section
command) differs. In practice the free filter prints correctly, including the
79-character title that crashed the vendor filter.

### Switch the main queue to the free filter

```sh
sudo lpadmin -p Kyocera_FS-1220MFP -P ppd/Kyocera_FS-1220MFPGDI_RE.ppd
```

⚠️ *Visual check recommended:* the small trailing difference could be visible on
photos/images (halftone). Text output is fine.

---

## 4. Network sharing (Chromebook / Windows / Android / iOS)

The printer is GDI/KPSL, so it cannot be driven directly over the network. The
Linux host acts as a print server: clients send IPP/PDF, the host converts to
KPSL and prints over USB.

`/etc/cups/cupsd.conf`:

- listen on the LAN: replace `Listen localhost:631` with `Listen 0.0.0.0:631`
  (stacking both fails with `Address already in use` on 127.0.0.1);
- in `<Location />`: add `Allow @LOCAL`.

```sh
sudo systemctl restart cups
ss -ltnp | grep 631     # should show 0.0.0.0:631
```

Clients:

```
ipp://<host-ip>:631/printers/Kyocera_FS-1220MFP
ipp://<hostname>.local:631/printers/Kyocera_FS-1220MFP
```

CUPS also advertises the shared queue over mDNS (Avahi) with `URF` and
`mopria-certified`, so driverless auto-discovery (ChromeOS, Android Mopria,
iOS AirPrint) usually works.

Caveat: the host must stay powered on and awake. Reserve a fixed IP (e.g. via
NetworkManager manual configuration or a router DHCP reservation) and prefer the
`.local` mDNS name.

---

## 5. Suspend / hibernate

The sleep issue is independent of the driver bugs. The printer does not support
remote wakeup, and after a host suspend the USB link can end up stale. A
systemd-sleep hook re-enumerates the USB device on resume by toggling its
`authorized` attribute:

- `../scripts/kyocera-usb-reset.sh`
- `../systemd/kyocera-usb-reset` (installed to `/usr/lib/systemd/system-sleep/`)

---

## 6. Summary of system changes

| Item | Action |
|---|---|
| `libcupsimage2t64` | installed (missing dependency) |
| `/usr/lib/cups/filter/rastertokpsl` | replaced by the anti-overflow wrapper |
| `/usr/lib/cups/filter/rastertokpsl.bin` | original Kyocera binary (backup) |
| `/usr/lib/cups/filter/rastertokpsl-re` | free KPSL filter |
| `/etc/cups/ppd/Kyocera_FS-1220MFP.ppd` | switched to the `_RE` PPD |
| `/etc/cups/cupsd.conf` | `Listen 0.0.0.0:631` + `Allow @LOCAL` |
| `/usr/local/sbin/kyocera-usb-reset.sh` | USB reset helper |
| `/usr/lib/systemd/system-sleep/kyocera-usb-reset` | systemd-sleep hook |

CUPS queue: `Kyocera_FS-1220MFP`, PPD `Kyocera_FS-1220MFPGDI_RE.ppd`.
