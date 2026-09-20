#!/bin/sh
# Build and install the free KPSL filter for the Kyocera FS-1220MFP.
#
# - compiles rastertokpsl-re (the portability patch must already be applied)
# - installs the filter into CUPS
# - creates/updates a CUPS queue from the _RE PPD
#
# Prerequisites:
#   sudo apt install cmake libcups2-dev libcupsimage2-dev
#   git clone https://github.com/sv99/rastertokpsl-re
#   cd rastertokpsl-re && git apply <this-repo>/patches/rastertokpsl-re-debian13.patch
#
# Usage:
#   RE_DIR=/path/to/rastertokpsl-re ./scripts/install-rastertokpsl-re.sh
#
# Variables (all optional):
#   RE_DIR   path to the rastertokpsl-re checkout  (default: ../rastertokpsl-re)
#   URI      CUPS device URI                        (default: USB FS-1220MFP)
#   QUEUE    CUPS queue name                        (default: Kyocera_RE)
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

RE_DIR="${RE_DIR:-$ROOT/../rastertokpsl-re}"
PPD="$ROOT/ppd/Kyocera_FS-1220MFPGDI_RE.ppd"
URI="${URI:-usb://Kyocera/FS-1220MFP?serial=LBW6Y04191}"
QUEUE="${QUEUE:-Kyocera_RE}"

[ -d "$RE_DIR" ] || {
    echo "rastertokpsl-re not found at: $RE_DIR" >&2
    echo "Clone it and apply the patch, or set RE_DIR=/path/to/rastertokpsl-re" >&2
    exit 1
}

echo ">> build dependencies"
sudo apt-get install -y cmake libcups2-dev libcupsimage2-dev

echo ">> building rastertokpsl-re"
cd "$RE_DIR"
mkdir -p build
cd build
cmake .. >/dev/null
make rastertokpsl-re

echo ">> installing filter"
sudo install -o root -g root -m 755 \
    "$RE_DIR/bin/rastertokpsl-re" /usr/lib/cups/filter/rastertokpsl-re

echo ">> creating/updating queue: $QUEUE"
sudo lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD" \
    -D 'Kyocera FS-1220MFP (free KPSL)'

echo ">> done. Test with:  lp -d $QUEUE -t test /etc/hostname"
