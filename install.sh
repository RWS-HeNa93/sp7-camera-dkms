#!/usr/bin/env bash
# Surface Pro 7 cameras on Linux: installer.
#
#   ./install.sh [options]
#
# Run it from a terminal as your normal user. It asks for your password once
# (sudo) for the system part. See README.md for what gets installed.
set -euo pipefail

HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
NAME=sp7-ipu4p
VER=rfcv2
KVER="$(uname -r)"
FW=/usr/lib/firmware/intel/ipu/ipu4p_fw.bin
FW_SHA256=ff2c36cc81a5c726508b22970c2e2538ff06107dc5a72c93401403c227e5157f
MODULES="intel-ipu6 intel-ipu6-isys ov5693 ov8865 dw9719"
SUDO="${SUDO:-sudo}"

FIRMWARE=
OVERWRITE=no
LIBCAMERA_FIX=yes
RELOAD=no
FORCE=no
STAGE=user
USER_ID=
STATE=

usage() {
    cat <<EOF
usage: ./install.sh [options]

  --firmware FILE      use this copy of the firmware (cpd_component_signed.bin)
                       instead of downloading it from Microsoft
  --overwrite-config   replace files in /etc/modprobe.d and /etc/libcamera that
                       you have changed (default: keep yours)
  --no-libcamera-fix   leave out the corrected copy of libcamera for WirePlumber
  --reload             swap the running modules at the end instead of asking
                       for a reboot (interrupts camera and sound for a moment)
  --force              install even if this is not a Surface Pro 7
  -h, --help           show this text
EOF
}

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --firmware) [ $# -ge 2 ] || die "--firmware needs a file"; FIRMWARE="$2"; shift ;;
        --overwrite-config) OVERWRITE=yes ;;
        --no-libcamera-fix) LIBCAMERA_FIX=no ;;
        --reload) RELOAD=yes ;;
        --force) FORCE=yes ;;
        -h|--help) usage; exit 0 ;;
        # used by the script itself when it restarts as root
        --root-stage) STAGE=root ;;
        --uid) USER_ID="$2"; shift ;;
        --state) STATE="$2"; shift ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

firmware_ok() { echo "$FW_SHA256  $1" | sha256sum -c --quiet - >/dev/null 2>&1; }

# ---------------------------------------------------------------- user part

preflight() {
    local found=no d product
    if [[ ! $KVER =~ ^7\.3\..*surface ]]; then
        die "the running kernel is $KVER.
This driver source is for the linux-surface 7.3 kernel only and DKMS would skip
it on any other. See 'Other kernels' in README.md."
    fi
    for d in /sys/bus/pci/devices/*; do
        if [ "$(cat "$d/vendor" 2>/dev/null)" = 0x8086 ] &&
           [ "$(cat "$d/device" 2>/dev/null)" = 0x8a19 ]; then
            found=yes
        fi
    done
    product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    if [ "$found" = no ] || [ "$product" != "Surface Pro 7" ]; then
        echo "This was made for and tested on the Surface Pro 7 only."
        echo "  this machine:          ${product:-unknown}"
        echo "  Intel IPU4P (8086:8a19): $([ "$found" = yes ] && echo present || echo not found)"
        [ "$FORCE" = yes ] || die "not a Surface Pro 7; --force installs anyway."
    fi
}

user_libcamera_fix() {
    say "Corrected libcamera copy for WirePlumber (in your home folder)"
    install -Dm755 "$HERE/libcamera-fix/sp7-libcamera-fix" "$HOME/.local/bin/sp7-libcamera-fix"
    install -Dm644 "$HERE/libcamera-fix/bayer_unpacked.frag.stock" \
        "$HOME/.local/share/sp7-libcamera/bayer_unpacked.frag.stock"
    install -Dm644 "$HERE/libcamera-fix/bayer_unpacked.frag.fixed" \
        "$HOME/.local/share/sp7-libcamera/bayer_unpacked.frag.fixed"
    install -Dm644 "$HERE/libcamera-fix/wireplumber-sp7-libcamera.conf" \
        "$HOME/.config/systemd/user/wireplumber.service.d/sp7-libcamera.conf"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "installed; WirePlumber applies it at its next start"
}

user_main() {
    [ "$(id -u)" != 0 ] || die "run it as your normal user, not as root; it asks for sudo itself."
    preflight
    if [ -n "$FIRMWARE" ]; then
        [ -f "$FIRMWARE" ] || die "$FIRMWARE: no such file"
        FIRMWARE="$(readlink -f "$FIRMWARE")"
        firmware_ok "$FIRMWARE" || die "$FIRMWARE is not the expected firmware
(SHA-256 should be $FW_SHA256)."
    fi

    [ "$LIBCAMERA_FIX" = no ] || user_libcamera_fix

    STATE="$(mktemp -d)"
    trap 'rm -rf "$STATE"' EXIT
    say "System part (needs root)"
    local args=(--root-stage --uid "$(id -u)" --state "$STATE")
    [ -z "$FIRMWARE" ] || args+=(--firmware "$FIRMWARE")
    [ "$OVERWRITE" = no ] || args+=(--overwrite-config)
    [ "$RELOAD" = no ] || args+=(--reload)
    $SUDO bash "$HERE/install.sh" "${args[@]}" || die "the system part failed; see the messages above."

    if [ "$LIBCAMERA_FIX" = yes ]; then
        say "libcamera"
        "$HOME/.local/bin/sp7-libcamera-fix" || true
        "$HOME/.local/bin/sp7-libcamera-fix" --status || true
    fi

    local mok reloaded
    mok="$(cat "$STATE/mok" 2>/dev/null || echo unknown)"
    reloaded="$(cat "$STATE/reload" 2>/dev/null || echo no)"
    say "Installed"
    case "$mok" in
        queued)
            cat <<EOF
Now reboot. A blue "MOK management" screen appears once:
  1. Enroll MOK  ->  Continue  ->  Yes
  2. enter the one-time password you just chose
  3. Reboot
Without this step Secure Boot refuses to load the camera modules.
EOF
            ;;
        manual)
            cat <<EOF
Secure Boot is on and the key DKMS signs the modules with is not enrolled yet.
Run this in a terminal, choose a one-time password, then reboot and enroll the
key on the blue "MOK management" screen (Enroll MOK -> Continue -> Yes):

    sudo mokutil --import $(cat "$STATE/cert" 2>/dev/null || echo /var/lib/dkms/mok.pub)
EOF
            ;;
        unsigned)
            cat <<EOF
Secure Boot is on, but DKMS did not sign the modules, so the kernel will refuse
to load them. Set up module signing for DKMS (see "Module signing" in its
documentation) and run ./install.sh again, or turn Secure Boot off.
EOF
            ;;
        *)
            if [ "$reloaded" = ok ]; then
                echo "The new modules are loaded; no reboot needed."
            else
                echo "Now reboot, so that the new camera modules replace the stock ones."
            fi
            ;;
    esac
    echo
    echo "Then open a camera app. 'Check it works' in README.md lists what to look at."
}

# ---------------------------------------------------------------- root part

root_deps() {
    say "Build tools"
    local need_extractor=no p missing=() tools=""
    if [ -z "$FIRMWARE" ] && ! { [ -f "$FW" ] && firmware_ok "$FW"; } &&
       ! command -v cabextract >/dev/null && ! command -v 7z >/dev/null; then
        need_extractor=yes
    fi

    if command -v dnf >/dev/null && command -v rpm >/dev/null; then
        local pkgs=(dkms make gcc binutils openssl mokutil python3 curl
                    "kernel-surface-devel-${KVER%."$(uname -m)"}")
        [ "$need_extractor" = no ] || pkgs+=(cabextract)
        for p in "${pkgs[@]}"; do
            rpm -q --quiet "$p" || missing+=("$p")
        done
        if [ ${#missing[@]} -gt 0 ]; then
            echo "installing: ${missing[*]}"
            dnf install -y --setopt=install_weak_deps=False "${missing[@]}" ||
                die "dnf could not install these packages. kernel-surface-devel comes from the
linux-surface repository and has to match the running kernel ($KVER)."
        else
            echo "all there"
        fi
    fi

    for p in dkms make gcc; do
        command -v "$p" >/dev/null || tools+=" $p"
    done
    [ -e "/lib/modules/$KVER/build/Makefile" ] || tools+=" kernel-headers"
    [ "$need_extractor" = no ] || command -v cabextract >/dev/null || tools+=" cabextract"
    if [ -n "$tools" ]; then
        cat >&2 <<EOF

Missing:$tools

Install DKMS, a compiler, the headers of the running kernel ($KVER) and
cabextract, then run ./install.sh again. Package names (not tested by us):
  Debian/Ubuntu:  sudo apt install dkms build-essential linux-headers-surface mokutil cabextract
  Arch:           sudo pacman -S --needed dkms base-devel linux-surface-headers mokutil cabextract
EOF
        exit 1
    fi
}

root_firmware() {
    say "Firmware"
    if [ -f "$FW" ]; then
        if firmware_ok "$FW"; then
            echo "already installed"
        else
            echo "WARNING: $FW exists but is a different version; keeping it."
            echo "This driver was tested with the version from Microsoft's package 42.18362.3.16827"
            echo "only. To use that one, delete the file and run ./install.sh again."
        fi
        return
    fi
    local tmp src
    tmp="$(mktemp -d)"
    if [ -n "$FIRMWARE" ]; then
        src="$FIRMWARE"
    else
        src="$tmp/ipu4p_fw.bin"
        bash "$HERE/scripts/fetch-firmware.sh" "$src" || { rm -rf "$tmp"; exit 1; }
    fi
    firmware_ok "$src" || { rm -rf "$tmp"; die "firmware checksum mismatch"; }
    install -Dm644 -o root -g root "$src" "$FW"
    rm -rf "$tmp"
    echo "installed $FW"
}

install_conf() {
    local src="$1" dst="$2"
    if [ -e "$dst" ] && ! cmp -s "$src" "$dst" && [ "$OVERWRITE" = no ]; then
        echo "kept your $dst (it differs from this version; --overwrite-config replaces it)"
        return
    fi
    install -Dm644 -o root -g root "$src" "$dst"
    echo "installed $dst"
}

root_files() {
    say "Driver source and settings"
    local v
    # any earlier version of this package
    for v in $(dkms status -m "$NAME" 2>/dev/null | sed -n "s|^$NAME/\([^,:]*\)[,:].*|\1|p" | sort -u); do
        dkms remove -m "$NAME" -v "$v" --all
    done
    rm -rf "/usr/src/$NAME-$VER"
    mkdir -p "/usr/src/$NAME-$VER"
    cp -r --no-preserve=mode,ownership "$HERE/dkms/." "/usr/src/$NAME-$VER/"
    chown -R root:root "/usr/src/$NAME-$VER"
    echo "installed /usr/src/$NAME-$VER"

    install_conf "$HERE/etc/modprobe.d/sp7-camera.conf" /etc/modprobe.d/sp7-camera.conf
    for v in ov5693.yaml ov8865.yaml; do
        install_conf "$HERE/etc/libcamera/ipa/simple/$v" "/etc/libcamera/ipa/simple/$v"
    done
    # SELinux labels of the target folders
    restorecon -R "/usr/src/$NAME-$VER" "$FW" /etc/modprobe.d/sp7-camera.conf /etc/libcamera 2>/dev/null || true
}

root_dkms() {
    say "Building the modules for $KVER (takes a minute or two)"
    local m path
    dkms add -m "$NAME" -v "$VER"
    if ! dkms build -m "$NAME" -v "$VER" -k "$KVER"; then
        tail -n 40 "/var/lib/dkms/$NAME/$VER/build/make.log" 2>/dev/null || true
        die "the build failed (log: /var/lib/dkms/$NAME/$VER/build/make.log)."
    fi
    dkms install -m "$NAME" -v "$VER" -k "$KVER"
    for m in $MODULES; do
        path="$(modinfo -k "$KVER" -n "$m" 2>/dev/null || true)"
        echo "  $m -> ${path:-NOT FOUND}"
        case "$path" in
            */extra/*) ;;
            *) die "$m was not installed to /lib/modules/$KVER/extra; 'dkms status' may say why." ;;
        esac
    done
}

# The certificate DKMS signs modules with.
dkms_cert() {
    local cert=/var/lib/dkms/mok.pub f v
    for f in /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf; do
        [ -f "$f" ] || continue
        v="$(sed -n 's/^[[:space:]]*mok_certificate=//p' "$f" | tail -n 1 | tr -d "\"'")"
        [ -z "$v" ] || cert="$v"
    done
    if [ ! -f "$cert" ] && [ -f /var/lib/shim-signed/mok/MOK.der ]; then
        cert=/var/lib/shim-signed/mok/MOK.der
    fi
    echo "$cert"
}

root_secureboot() {
    say "Secure Boot"
    local cert out
    if ! command -v mokutil >/dev/null ||
       ! mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
        echo "Secure Boot is off (or mokutil is missing): nothing to do."
        echo off > "$STATE/mok"
        return
    fi
    cert="$(dkms_cert)"
    echo "$cert" > "$STATE/cert"
    if [ -z "$(modinfo -k "$KVER" -F signer intel-ipu6 2>/dev/null)" ] || [ ! -f "$cert" ]; then
        echo "Secure Boot is on but DKMS did not sign the modules."
        echo unsigned > "$STATE/mok"
        return
    fi
    out="$(mokutil --test-key "$cert" 2>&1 || true)"
    case "$out" in
        *"already enrolled"*)
            echo "The DKMS signing key is already enrolled."
            echo enrolled > "$STATE/mok"
            return ;;
        *"already in the enrollment request"*)
            echo "The DKMS signing key is already waiting to be enrolled at the next boot."
            echo queued > "$STATE/mok"
            return ;;
    esac
    if [ -t 0 ]; then
        echo "DKMS signed the modules with its own key ($cert)."
        echo "Secure Boot only loads them once that key is enrolled."
        echo "Choose a one-time password; you type it again once on the next boot."
        if mokutil --import "$cert"; then
            echo queued > "$STATE/mok"
            return
        fi
    fi
    echo manual > "$STATE/mok"
}

root_reload() {
    say "Swapping the running modules"
    if SP7_UID="$USER_ID" bash "$HERE/scripts/reload-modules.sh"; then
        echo ok > "$STATE/reload"
    else
        echo failed > "$STATE/reload"
    fi
}

root_main() {
    [ "$(id -u)" = 0 ] || die "--root-stage is for the script's own use."
    [ -n "$STATE" ] && [ -d "$STATE" ] || die "--root-stage is for the script's own use."
    root_deps
    root_firmware
    root_files
    root_dkms
    root_secureboot
    if [ "$RELOAD" = yes ]; then
        if [ "$(cat "$STATE/mok")" = enrolled ] || [ "$(cat "$STATE/mok")" = off ]; then
            root_reload
        else
            echo "Not swapping the modules: the signing key has to be enrolled first."
        fi
    fi
    chmod -R a+rX "$STATE"
}

if [ "$STAGE" = root ]; then
    root_main
else
    user_main
fi
