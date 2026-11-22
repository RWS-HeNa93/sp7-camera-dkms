#!/usr/bin/env bash
# Capture one raw full-resolution frame from the rear camera (run as the
# user). Used by focus-sweep.sh.
#
#   focus-capture.sh <output-file>
#
# Fixed exposure and gain, so that frames taken at different lens positions
# differ only in sharpness. The output is one 3264x2448 frame of 16-bit
# samples (Bayer BGGR, 10 significant bits).
set -uo pipefail

OUT="$1"
MD=/dev/media0
W=3264
H=2448
# the sensor's entity name ends in its I2C address, e.g. "ov8865 2-0010"
SENSOR="$(media-ctl -d $MD -p | grep -oE 'ov8865 [0-9]+-[0-9a-f]{4}' | head -n 1)"
CSI='Intel IPU6 CSI2 0'
SUB="$(media-ctl -d $MD -e "$SENSOR")"
VID="$(media-ctl -d $MD -e 'Intel IPU6 ISYS Capture 0')"
TMP="$OUT.tmp"
LOG="$OUT.log"

# keep what the tools say; v4l2-ctl exits 0 even when streaming never starts
exec 2>"$LOG"

# libcamera normally enables this link; after a module reload nothing has yet
media-ctl -d $MD -l "\"$CSI\":1 -> \"Intel IPU6 ISYS Capture 0\":0 [1]" >/dev/null
media-ctl -d $MD -V "\"$SENSOR\":0 [fmt:SBGGR10_1X10/${W}x${H}]" >/dev/null
media-ctl -d $MD -V "\"$CSI\":0 [fmt:SBGGR10_1X10/${W}x${H}]" >/dev/null
media-ctl -d $MD -V "\"$CSI\":1 [fmt:SBGGR10_1X10/${W}x${H}]" >/dev/null
v4l2-ctl -d "$SUB" --set-ctrl horizontal_flip=1,vertical_flip=1,analogue_gain=1024 >/dev/null
EXPMAX="$(v4l2-ctl -d "$SUB" -l | grep -oE 'exposure .*max=[0-9]+' | grep -oE 'max=[0-9]+' | cut -d= -f2)"
v4l2-ctl -d "$SUB" --set-ctrl exposure="$EXPMAX" >/dev/null

# 8 frames: the lens needs a few frames to settle after power-up
timeout 20 v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BG10 \
    --stream-mmap=4 --stream-count=8 --stream-to="$TMP" >/dev/null
RC=$?
if [ -s "$TMP" ]; then
    tail -c $((W * H * 2)) "$TMP" > "$OUT"
    rm -f "$LOG"
else
    RC=1
fi
rm -f "$TMP"
exit $RC
