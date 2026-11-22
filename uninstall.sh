#!/usr/bin/env bash
# Surface Pro 7 cameras on Linux: remove everything install.sh installed.
#
#   ./uninstall.sh
#
# Run it as your normal user; it asks for your password once (sudo). The stock
# kernel modules come back, so after the next reboot the cameras are gone
# again. Packages that install.sh pulled in (dkms, kernel headers, ...) and
# the DKMS signing key stay.
set -euo pipefail

HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
NAME=sp7-ipu4p
SUDO="${SUDO:-sudo}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

root_main() {
    [ "$(id -u)" = 0 ] || die "--root-stage is for the script's own use."
    local v f
    say "DKMS package"
    for v in $(dkms status -m "$NAME" 2>/dev/null | sed -n "s|^$NAME/\([^,:]*\)[,:].*|\1|p" | sort -u); do
        dkms remove -m "$NAME" -v "$v" --all
    done
    for f in /usr/src/"$NAME"-*; do
        [ -d "$f" ] || continue
        rm -rf "$f"
        echo "removed $f"
    done

    say "Firmware and settings"
    for f in /usr/lib/firmware/intel/ipu/ipu4p_fw.bin /etc/modprobe.d/sp7-camera.conf \
             /etc/libcamera/ipa/simple/ov5693.yaml /etc/libcamera/ipa/simple/ov8865.yaml; do
        if [ -e "$f" ]; then
            rm -f "$f"
            echo "removed $f"
        fi
    done
    # only if nothing else is in them
    rmdir -p --ignore-fail-on-non-empty /etc/libcamera/ipa/simple 2>/dev/null || true
}

user_main() {
    [ "$(id -u)" != 0 ] || die "run it as your normal user, not as root; it asks for sudo itself."
    local f
    say "Corrected libcamera copy (in your home folder)"
    for f in "$HOME/.config/systemd/user/wireplumber.service.d/sp7-libcamera.conf" \
             "$HOME/.local/bin/sp7-libcamera-fix" \
             "$HOME/.local/lib/libcamera-sp7" \
             "$HOME/.local/share/sp7-libcamera"; do
        if [ -e "$f" ]; then
            rm -rf "$f"
            echo "removed $f"
        fi
    done
    rmdir --ignore-fail-on-non-empty "$HOME/.config/systemd/user/wireplumber.service.d" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true

    say "System part (needs root)"
    $SUDO bash "$HERE/uninstall.sh" --root-stage || die "the system part failed; see the messages above."

    say "Removed"
    cat <<EOF
Reboot to go back to the stock kernel modules. Until then the camera modules
that are loaded keep running.

Left in place: installed packages (dkms, kernel headers, ...) and the DKMS
signing key. To make Secure Boot forget that key (only if nothing else uses
DKMS on this machine):

    sudo mokutil --delete /var/lib/dkms/mok.pub
EOF
}

case "${1:-}" in
    --root-stage) root_main ;;
    "") user_main ;;
    *) echo "usage: ./uninstall.sh" >&2; exit 2 ;;
esac
