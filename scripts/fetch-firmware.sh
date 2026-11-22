#!/usr/bin/env bash
# Download Intel's IPU4P firmware and check it.
#
#   scripts/fetch-firmware.sh <output-file>
#
# The firmware belongs to Intel and is not ours to redistribute, so it is not
# in this repository. Microsoft publishes it inside the Surface camera driver
# package "Intel - Camera - 42.18362.3.16827" in the Microsoft Update Catalog:
#
#   https://www.catalog.update.microsoft.com/Search.aspx?q=42.18362.3.16827
#
# This script downloads that package (31 MB), checks its SHA-256, takes
# cpd_component_signed.bin out of it and checks that file's SHA-256 too.
# Nothing is installed: the result is written to <output-file>.
#
# Needs curl or wget, and cabextract or 7z. (bsdtar cannot unpack this file.)
set -euo pipefail

CAB_URL='https://catalog.s.download.windowsupdate.com/c/msdownload/update/driver/drvs/2025/01/dba9022d-a496-4f09-b989-4815f8e83643_32fc2322514685244f80f83e323b794e93621066.cab'
CAB_SHA256=0f46902d75ddac03096e6668eaf067ae83bcff31cee026725a8506fe5c5e8738
FW_NAME=cpd_component_signed.bin
FW_SHA256=ff2c36cc81a5c726508b22970c2e2538ff06107dc5a72c93401403c227e5157f

die() { echo "fetch-firmware: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: $0 <output-file>"
OUT="$1"

manual() {
    cat >&2 <<EOF

Get the firmware by hand instead:
  1. Open https://www.catalog.update.microsoft.com/Search.aspx?q=42.18362.3.16827
     and download any of the listed packages (they are the same file).
  2. Extract $FW_NAME from the .cab file.
  3. Run: ./install.sh --firmware /path/to/$FW_NAME
EOF
    exit 1
}

command -v cabextract >/dev/null || command -v 7z >/dev/null ||
    die "needs cabextract or 7z to unpack the .cab file"
command -v curl >/dev/null || command -v wget >/dev/null || die "needs curl or wget"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading the driver package from Microsoft (31 MB) ..."
if command -v curl >/dev/null; then
    curl -fL --retry 3 -sS -o "$TMP/pkg.cab" "$CAB_URL" || { echo "download failed" >&2; manual; }
else
    wget -q -O "$TMP/pkg.cab" "$CAB_URL" || { echo "download failed" >&2; manual; }
fi
echo "$CAB_SHA256  $TMP/pkg.cab" | sha256sum -c --quiet - ||
    { echo "the downloaded package is not the expected file" >&2; manual; }

# The package is only unpacked after its checksum matched. (cabextract warns
# about extra bytes at the end of the file: that is the package's signature.)
mkdir "$TMP/x"
if command -v cabextract >/dev/null; then
    cabextract -q -F "$FW_NAME" -d "$TMP/x" "$TMP/pkg.cab" 2>"$TMP/unpack.log" || cat "$TMP/unpack.log" >&2
else
    7z e -y -o"$TMP/x" "$TMP/pkg.cab" "$FW_NAME" >"$TMP/unpack.log" 2>&1 || cat "$TMP/unpack.log" >&2
fi
[ -f "$TMP/x/$FW_NAME" ] || { echo "could not unpack $FW_NAME from the package" >&2; manual; }
echo "$FW_SHA256  $TMP/x/$FW_NAME" | sha256sum -c --quiet - ||
    { echo "the firmware in the package is not the expected file" >&2; manual; }

install -m644 "$TMP/x/$FW_NAME" "$OUT"
echo "Firmware written to $OUT (SHA-256 matches)."
