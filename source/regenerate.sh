#!/usr/bin/env bash
# Rebuild the DKMS driver source tree from its upstream parts, to show where
# the dkms/ folder comes from and as the starting point for porting it to a
# newer kernel. Not needed for a normal install: the finished tree is stored
# in this repository.
#
#   source/regenerate.sh <work-dir>
#
# <work-dir> is a scratch folder for the downloads (about 20 MB) and the
# result, <work-dir>/sp7-ipu4p-rfcv2. At the end the result is compared with
# dkms/. Needs git, curl and patch.
#
# Parts:
#   1. linux-media/media-committers at the base commit of the IPU4P series:
#      drivers/media/pci/intel/ipu6 and include/media/ipu6-pci-table.h
#   2. the 12 patches of the IPU4P RFC v2 series (source/ipu4p-rfcv2, from
#      ruslanbay/ipu4-drivers, branch "upstream", commit f0b3dfa)
#   3. one edit for the 7.3 kernel API
#   4. ov5693.c, ov8865.c and dw9719.c as the linux-surface 7.3 kernel builds
#      them, each with its patch from source/sensors
#   5. Kbuild, Makefile and dkms.conf, taken from dkms/
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <work-dir>" >&2; exit 2; }
W="$(readlink -f "$1")"
HERE="$(dirname "$(readlink -f "$0")")"
STORED="$(dirname "$HERE")/dkms"
OUT="$W/sp7-ipu4p-rfcv2"
MEDIA="$W/media-tree"

BASE=27285b099fbc5cb2ae3aef20f3bbd7b3c88b3005
MEDIA_URL=https://gitlab.freedesktop.org/linux-media/media-committers.git

mkdir -p "$W"

echo "=== 1. media tree at $BASE"
if [ ! -d "$MEDIA/.git" ]; then
    git init -q "$MEDIA"
    git -C "$MEDIA" remote add origin "$MEDIA_URL"
    git -C "$MEDIA" config remote.origin.promisor true
    git -C "$MEDIA" config remote.origin.partialclonefilter blob:none
    git -C "$MEDIA" sparse-checkout set drivers/media/pci/intel include/media
    git -C "$MEDIA" fetch -q --depth 1 --filter=blob:none origin "$BASE"
fi
git -C "$MEDIA" am --abort 2>/dev/null || true
git -C "$MEDIA" checkout -q --detach "$BASE"

echo "=== 2. IPU4P RFC v2 series"
git -C "$MEDIA" -c user.name=regenerate -c user.email=regenerate@localhost \
    am -q "$HERE"/ipu4p-rfcv2/v2-00{01,02,03,04,05,06,07,08,09,10,11,12}-*.patch

rm -rf "$OUT"
mkdir -p "$OUT/include/media"
cp "$MEDIA"/drivers/media/pci/intel/ipu6/*.[ch] "$OUT/"
cp "$MEDIA"/include/media/ipu6-pci-table.h "$OUT/include/media/"

echo "=== 3. kernel 7.3 API"
# The snapshot is 7.4-bound, where pad operations gained a
# "const struct v4l2_subdev_client_info *" argument (media commit 7eef49c1).
# The driver never uses it, so drop it to match the 7.3 prototypes.
sed -i '/const struct v4l2_subdev_client_info \*ci,/d' \
    "$OUT/ipu6-isys-csi2.c" "$OUT/ipu6-isys-subdev.c" "$OUT/ipu6-isys-subdev.h"
if grep -q v4l2_subdev_client_info "$OUT"/*.[ch]; then
    echo "compat edit incomplete" >&2
    exit 1
fi

echo "=== 4. sensor and lens drivers"
# driver, last commit touching the file on linux-surface/kernel v7.3-surface,
# SHA-256 of the file at that commit
add_driver() {
    local name="$1" commit="$2" sha256="$3"
    local base="$W/$name.c.upstream"
    local url="https://raw.githubusercontent.com/linux-surface/kernel/$commit/drivers/media/i2c/$name.c"

    [ -f "$base" ] || curl -sfL -o "$base" "$url"
    echo "$sha256  $base" | sha256sum -c -
    cp "$base" "$OUT/$name.c"
    patch -s -p1 --no-backup-if-mismatch "$OUT/$name.c" < "$HERE/sensors/$name-sp7.patch"
}
add_driver ov5693 00a71904ce4a7475cbc48af3319876144d5c3174 \
    bbb12e8e715669037f4a4a164d488df3ec11b5fa78e6b90b04e321d8208fdbc1
add_driver ov8865 f4cdf7ca9a1fdcca413157df19753f388a5a224e \
    4d6aef225d85ba37ff903e60869ec0bb2dfbab6a5cca27bb2ddbefc40b3c0336
add_driver dw9719 d6aaeeec414a455b4420c3e86ab5e9a849e1a6a6 \
    bf4477b809e1f48a5e9f14d2b564cc9df5564a9e0f54b164927afb63511d8645

echo "=== 5. build files"
cp "$STORED"/Kbuild "$STORED"/Makefile "$STORED"/dkms.conf "$OUT/"

echo "=== result: $OUT ($(find "$OUT" -type f | wc -l) files)"
if diff -r "$STORED" "$OUT" > "$W/diff.txt"; then
    echo "RESULT: IDENTICAL to dkms/"
else
    echo "RESULT: DIFFERS from dkms/, see $W/diff.txt"
    exit 3
fi
