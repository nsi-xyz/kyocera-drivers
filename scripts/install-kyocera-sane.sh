#!/bin/sh
# Install the Kyocera SANE driver to use the scanner half of a Kyocera MFP
# (tested with the FS-1220MFP on Debian 13), and tighten its udev rule.
#
# The driver itself is proprietary (free of charge) and is NOT redistributed
# here: it is downloaded from Kyocera's support site. See CREDITS.md.
#
# Usage:  sudo ./scripts/install-kyocera-sane.sh
#
# Variables (optional):
#   WORK   working directory for the download/extraction (default /tmp/kyocera-sane)
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
WORK="${WORK:-/tmp/kyocera-sane}"
URL="https://www.kyoceradocumentsolutions.eu/content/dam/download-center-cf/eu/drivers/all/SANE_Driver_zip.download.zip"

mkdir -p "$WORK"
cd "$WORK"

echo ">> downloading Kyocera SANE driver"
curl -fsSL -o SANE_Driver.zip "$URL"
unzip -o SANE_Driver.zip >/dev/null

echo ">> installing libsane"
apt-get install -y libsane1

# Modern Debian/Ubuntu no longer ships a package literally named "libsane"
# (the library is in "libsane1"), which makes the Kyocera .deb uninstallable.
# Provide a no-op stand-in that depends on libsane1.
if ! dpkg -l libsane 2>/dev/null | grep -q '^ii'; then
    echo ">> creating dummy 'libsane' package"
    rm -rf dummy
    mkdir -p dummy/DEBIAN
    cat > dummy/DEBIAN/control <<'EOF'
Package: libsane
Version: 1.3.1
Architecture: all
Maintainer: local <root@localhost>
Depends: libsane1
Section: libs
Priority: optional
Description: transitional dummy package providing "libsane" for kyocera-sane
EOF
    dpkg-deb --build --root-owner-group dummy libsane_1.3.1_all.deb >/dev/null
    dpkg -i libsane_1.3.1_all.deb
fi

echo ">> installing Kyocera SANE driver"
dpkg -i kyocera-sane_2.2.1511_amd64.deb

echo ">> tightening the udev rule (vendor rule granted 0666 to every USB device)"
cp -a /etc/udev/rules.d/40-scanner-permissions.rules \
      /etc/udev/rules.d/40-scanner-permissions.rules.vendor-bak 2>/dev/null || true
install -o root -g root -m 644 \
    "$ROOT/udev/40-scanner-permissions.rules" \
    /etc/udev/rules.d/40-scanner-permissions.rules
udevadm control --reload-rules
udevadm trigger

echo ">> done."
echo "   Make sure your user is in the 'scanner' group:"
echo "       sudo usermod -aG scanner \"\$USER\"   # then log out / back in"
echo "   Test:  scanimage -L"
