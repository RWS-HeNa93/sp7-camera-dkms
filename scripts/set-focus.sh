#!/usr/bin/env bash
# Set the rear camera's fixed focus position.
#
#   sudo scripts/set-focus.sh <position>
#
# <position> is 0-1023; larger values focus closer. It is written to
# /etc/modprobe.d/sp7-camera.conf (dw9719 default_focus), so it survives a
# reboot, and to the running driver, where it is used the next time the rear
# camera starts. scripts/focus-calibrate.sh finds a good value.
set -euo pipefail

CONF=/etc/modprobe.d/sp7-camera.conf
PARAM=/sys/module/dw9719/parameters/default_focus

[ "$(id -u)" = 0 ] || { echo "run it with sudo" >&2; exit 2; }
POS="${1:-}"
if [[ ! $POS =~ ^[0-9]{1,4}$ ]] || [ "$POS" -gt 1023 ]; then
    echo "usage: sudo $0 <position 0-1023>" >&2
    exit 2
fi
grep -qE '^options dw9719 .*default_focus=' "$CONF" 2>/dev/null ||
    { echo "no 'options dw9719 ... default_focus=' line in $CONF" >&2; exit 2; }

sed -i -E "s/^(options dw9719 .*default_focus=)-?[0-9]+/\1$POS/" "$CONF"
if [ -e "$PARAM" ]; then
    echo "$POS" > "$PARAM"
    echo "default_focus=$POS saved in $CONF; running driver: $(cat "$PARAM")" \
         "(used the next time the rear camera starts)"
else
    echo "default_focus=$POS saved in $CONF; the dw9719 driver is not loaded, so it applies after a reboot"
fi
