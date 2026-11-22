#!/usr/bin/env bash
# Take one raw rear camera frame per lens position, for choosing the fixed
# focus. Normally run through focus-calibrate.sh. Root is only needed to
# write the lens position; the captures run as the user.
#
#   sudo scripts/focus-sweep.sh <out-dir> [positions...]
#
# REPEATS=<n> in the environment takes n frames per position, each after a
# fresh power-up of the lens, to show how repeatable a position is.
#
# <out-dir> must be writable by the user (about 16 MB per frame). Keep the
# tablet still, with the rear camera looking at something detailed at the
# distance to focus on. WirePlumber is stopped while it runs.
set -uo pipefail

HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
[ "$(id -u)" = 0 ] || { echo "run it with sudo" >&2; exit 2; }
[ $# -ge 1 ] || { echo "usage: sudo $0 <out-dir> [positions...]" >&2; exit 2; }
OUT="$(readlink -f "$1")"
shift
POSITIONS="${*:-0 50 100 150 200 250 300 350 400 450 500 600 700 800 1000}"
REPEATS="${REPEATS:-1}"
VCM=/sys/bus/i2c/devices/i2c-INT347A:00-VCM
PARAM=/sys/module/dw9719/parameters/default_focus

[ -e "$PARAM" ] || { echo "RESULT: NO_LENS_DRIVER ($PARAM missing)"; exit 2; }

UID_USER="${SP7_UID:-${SUDO_UID:-${PKEXEC_UID:-}}}"
[ -n "$UID_USER" ] || { echo "run it with sudo from your own session" >&2; exit 2; }
asuser() {
    runuser -u "$(id -nu "$UID_USER")" -- env \
        XDG_RUNTIME_DIR="/run/user/$UID_USER" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_USER/bus" "$@"
}

# WirePlumber holds the cameras once an app has used them.
asuser systemctl --user stop wireplumber
sleep 1
SAVED="$(cat "$PARAM")"
MARK="$(date '+%Y-%m-%d %H:%M:%S')"
GOOD=0
for pos in $POSITIONS; do
    echo "$pos" > "$PARAM"
    LINE="position $pos:"
    for r in $(seq 1 "$REPEATS"); do
        # the position is applied when the lens powers up again
        for _ in $(seq 1 40); do
            [ "$(cat "$VCM/power/runtime_status" 2>/dev/null)" = suspended ] && break
            sleep 0.25
        done
        FILE="$OUT/pos-$(printf '%04d' "$pos")-$r.raw"
        rm -f "$FILE"
        asuser bash "$HERE/focus-capture.sh" "$FILE" &
        CAP=$!
        sleep 1.2
        MID="$(cat "$VCM/power/runtime_status" 2>/dev/null)"
        wait "$CAP"
        SIZE="$(stat -c %s "$FILE" 2>/dev/null || echo 0)"
        if [ "$SIZE" -gt 0 ]; then
            GOOD=$((GOOD + 1))
            LINE="$LINE ok($MID)"
        else
            LINE="$LINE FAILED($MID)"
        fi
    done
    echo "$LINE"
done
echo "$SAVED" > "$PARAM"
echo "kernel messages during the sweep:"
journalctl -k --no-pager --since "$MARK" | grep -iE 'dw9719|ov8865|csi2|error' | cut -c1-200 | tail -10
asuser systemctl --user start wireplumber
echo "RESULT: $GOOD frames captured, default_focus back at $(cat "$PARAM")"
[ "$GOOD" -gt 0 ]
