# Sources, credits and third-party licences

This repository documents and packages a fix. It reuses, references or links the
following projects and sources. Nothing proprietary is redistributed: the
vendor filter binary (`rastertokpsl`) is **not** included here; only our own
scripts and configuration are.

## Software reused / built upon

| Project | Licence | Use in this repo |
|---|---|---|
| [**sv99/rastertokpsl-re**](https://github.com/sv99/rastertokpsl-re) | Apache-2.0 | Free KPSL filter. We provide a small portability patch ([`patches/rastertokpsl-re-debian13.patch`](patches/rastertokpsl-re-debian13.patch)) that modifies this upstream code. The patch is therefore a derivative work and stays under Apache-2.0. |
| [JBIG-KIT](https://www.cl.cam.ac.uk/~mgk25/jbigkit/) (bundled inside rastertokpsl-re) | GPL-2.0 | Bi-level image compression library. Not redistributed here; pulled through the upstream repo at build time. |
| **Kyocera PPD** `Kyocera_FS-1220MFPGDI.ppd` | MIT (see the licence text embedded in the PPD header) | Vendor description file, redistributed here with its original header intact. Sourced from the Kyocera CD-ROM *“Aquarius MFP EU 3.2 RC2”* / Kyocera support downloads. |
| [CUPS](https://github.com/OpenPrinting/cups) | Apache-2.0 | Printing system: PPD/filter model, IPP server, `cupsfilter`, backends. |
| [Debian `libcupsimage2t64`](https://packages.debian.org/trixie/libcupsimage2t64) | (CUPS, Apache-2.0) | Provides the missing `libcupsimage.so.2`. |
| Ghostscript (`gstoraster` / `pdftoraster` path) | AGPL-3.0 | Converts PDF/PostScript to CUPS raster before the KPSL filter. |
| **Kyocera SANE Driver** v2.2.1511 | proprietary, **free of charge — not redistributed here** | Scanner backend for Kyocera MFPs. Downloaded at install time from Kyocera's support site by `scripts/install-kyocera-sane.sh`. |
| [SANE](http://www.sane-project.org/) (`sane-backends`, Debian `libsane1`) | GPL-2.0-or-later / LGPL-2.0-or-later | Scanner access library and API. |
| [`simple-scan`](https://gitlab.gnome.org/GNOME/simple-scan) | GPL-3.0 | Optional GUI scanning frontend. |

The dummy `libsane` package built by `scripts/install-kyocera-sane.sh` is our own
work (MIT); it exists only to satisfy the Kyocera `.deb` dependency on the
historical package name.

The `kpslcmp.pl` / `data_kpslcmp.pl` comparison scripts used for validation come
from the `rastertokpsl-re` project (Apache-2.0).

## Documentation and community sources consulted

- openSUSE Forums — *“How I got my Kyocera Ecosys FS-1220MFP working on OpenSuse TW”*:
  confirmed that the correct approach is the vendor PPD + `rastertokpsl` filter.
  <https://forums.opensuse.org/t/how-i-got-my-kyocera-ecosys-fs-1220mfp-working-on-opensuse-tw/195999>
- Arch Linux BBS — *“Filtering for Kyocera FS-1061DN printer fails”* (same GDI/KPSL
  family): <https://bbs.archlinux.org/viewtopic.php?id=272961>
- Linux Mint Forums — *“Kyocera FS-1220MFP debugging”* (jobs stuck in “processing”):
  <https://forums.linuxmint.com/viewtopic.php?t=432668>
- Kyocera Document Solutions — product support / downloads page for the FS-1220MFP,
  including the **SANE Driver (2.2.1511)** and the CD ISO image:
  <https://www.kyoceradocumentsolutions.eu/en/support/downloads.name-L2V1L2VuL21mcC9GUzEyMjBNRlA=.html>
- Debian package tracker and `libcupsimage2t64` details (the `t64` rename):
  <https://packages.debian.org/trixie/libcupsimage2t64>

## Tools used during the investigation

`ldd`, `cupsfilter`, `cupsd` / CUPS `error_log`, `lpadmin`, `lp`, `lpstat`,
`runuser`, `systemd-coredump` / `coredumpctl`, `gdb`, `avahi-browse`, `curl`,
`7z` (ISO inspection), `pdfinfo`/`pdftotext`, `scanimage`, ImageMagick
`identify`, headless Google Chrome (HTML→PDF).

## Licensing of this repository's own content

Unless stated otherwise, the files authored for this repository (README, docs,
wrapper, scripts, systemd hook, modified PPD) are released under the **MIT**
licence — see [`LICENSE`](LICENSE).

Trademarks belong to their owners. This project is not affiliated with or
endorsed by Kyocera.
