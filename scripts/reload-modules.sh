#!/usr/bin/env bash
# Swap the running camera modules for the ones DKMS installed, without a
# reboot. A reboot does the same and is the safer way; this is for updating
# an install that already works, and for working on the driver.
#
#   sudo scripts/reload-modules.sh
#
# WirePlumber is stopped while the modules are swapped, which cuts the camera
# in any open app and interrupts sound for a few seconds.
#
# intel_ipu6 itself is left alone if it is already loaded: only its
# intel_ipu6_isys part and the sensor and lens drivers are swapped. After a
# change to intel_ipu6, reboot instead.
set -uo pipefail

[ "$(id -u)" = 0 ] || { echo "run it with sudo" >&2; exit 2; }

VCM=/sys/bus/i2c/devices/i2c-INT347A:00-VCM
UID_USER="${SP7_UID:-${SUDO_UID:-${PKEXEC_UID:-}}}"
asuser() {
    [ -n "$UID_USER" ] || return 0
    runuser -u "$(id -nu "$UID_USER")" -- env \
        XDG_RUNTIME_DIR="/run/user/$UID_USER" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_USER/bus" "$@"
}

MARK="$(date '+%Y-%m-%d %H:%M:%S')"
# WirePlumber keeps the camera nodes open, which pins the modules. Starting
# it again afterwards also makes it read the libcamera tuning files.
asuser systemctl --user stop wireplumber
sleep 1

SWAP=ok
# rmmod, not "modprobe -r", so that intel_ipu6 stays loaded.
if [ -d /sys/module/intel_ipu6_isys ]; then
    rmmod intel_ipu6_isys || SWAP=failed
fi
if [ "$SWAP" = ok ]; then
    for m in ov5693 ov8865 dw9719; do
        if [ -d "/sys/module/$m" ]; then
            rmmod "$m" || SWAP=failed
        fi
    done
fi
if [ "$SWAP" = ok ]; then
    for m in dw9719 ov5693 ov8865 intel_ipu6; do
        modprobe "$m" || SWAP=failed
    done
fi
modprobe intel_ipu6_isys || SWAP=failed
sleep 5

asuser systemctl --user start wireplumber

echo "Kernel messages since the swap:"
journalctl -k --no-pager --since "$MARK" | cut -c1-200 | tail -30
echo
echo "Loaded modules:"
for m in intel_ipu6 intel_ipu6_isys ov5693 ov8865 dw9719; do
    if [ -d "/sys/module/$m" ]; then
        echo "  $m  <-  $(modinfo -n "$m" 2>/dev/null)"
    else
        echo "  $m  NOT LOADED"
    fi
done
for p in ov5693/mirror ov8865/mirror ov8865/vcm dw9719/devnode dw9719/default_focus; do
    echo "  $p = $(cat "/sys/module/${p%/*}/parameters/${p#*/}" 2>/dev/null || echo '(missing)')"
done
echo "  rear lens driver: $(basename "$(readlink "$VCM/driver" 2>/dev/null)" 2>/dev/null || echo none)"

BAD="$(journalctl -k --no-pager --since "$MARK" |
    grep -cE 'Oops|BUG:|WARNING: CPU|Call Trace|general protection|DMAR.*fault')"
if [ "$SWAP" = ok ] && [ "$BAD" -eq 0 ] && ls /dev/media* >/dev/null 2>&1 &&
   [ -e /sys/module/ov5693/parameters/mirror ] &&
   [ -e /sys/module/ov8865/parameters/vcm ] &&
   [ -e /sys/module/dw9719/parameters/default_focus ] &&
   [ -e "$VCM/driver" ]; then
    echo "RESULT: OK, the patched drivers are loaded."
else
    echo "RESULT: NEEDS A REBOOT (swap=$SWAP, kernel warnings=$BAD). A reboot loads the new modules cleanly."
    exit 4
fi
