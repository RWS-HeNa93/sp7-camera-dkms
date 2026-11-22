#!/usr/bin/env bash
# Calibrate the rear camera's fixed focus in one go: try several lens
# positions (focus-sweep.sh), find the sharpest one for a part of the picture
# (focus-metric.py) and save it (set-focus.sh).
#
#   sudo scripts/focus-calibrate.sh <out-dir> <region> [positions...]
#
# <out-dir>  scratch folder your user can write to (about 16 MB per frame);
#            delete it afterwards
# <region>   the part of the picture to make sharp: full, top, mid, bot or
#            centre
# positions  lens positions to try, 0-1023 (larger = closer)
#
# With REPEATS=<n> in the environment each position is tried n times and
# judged by its worst frame. Keep the tablet still while it runs: the lens
# position for a given value shifts with the tablet's tilt.
#
# Needs v4l-utils (media-ctl, v4l2-ctl), python3 and ImageMagick (magick).
set -uo pipefail

HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
[ "$(id -u)" = 0 ] || { echo "run it with sudo" >&2; exit 2; }
[ $# -ge 2 ] || { echo "usage: sudo $0 <out-dir> <region> [positions...]" >&2; exit 2; }
OUT="$(readlink -f "$1")"
REGION="$2"
shift 2

UID_USER="${SP7_UID:-${SUDO_UID:-${PKEXEC_UID:-}}}"
[ -n "$UID_USER" ] || { echo "run it with sudo from your own session" >&2; exit 2; }
for tool in media-ctl v4l2-ctl python3 magick; do
    command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 2; }
done
asuser() {
    runuser -u "$(id -nu "$UID_USER")" -- env \
        XDG_RUNTIME_DIR="/run/user/$UID_USER" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_USER/bus" "$@"
}

asuser mkdir -p "$OUT" || exit 2
asuser rm -f "$OUT"/pos-*.raw
SP7_UID="$UID_USER" bash "$HERE/focus-sweep.sh" "$OUT" "$@" || exit 3

echo "=== sharpness per position (region: $REGION)"
RESULT="$(asuser python3 "$HERE/focus-metric.py" "$OUT" "$REGION")" || {
    echo "$RESULT"; echo "RESULT: METRIC_FAILED"; exit 4; }
echo "$RESULT"
BEST="$(echo "$RESULT" | sed -n 's/^BEST \([0-9]\{1,4\}\)$/\1/p')"
if [ -z "$BEST" ] || [ "$BEST" -gt 1023 ]; then
    echo "RESULT: NO_BEST_POSITION"
    exit 4
fi

echo "=== saving default_focus=$BEST"
bash "$HERE/set-focus.sh" "$BEST" || exit 5
echo "RESULT: OK default_focus=$BEST"
