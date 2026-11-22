# Surface Pro 7 cameras on Linux (IPU4P, DKMS)

Makes the front and rear cameras of the Surface Pro 7 work in normal apps (Camera, Chrome, video calls) through libcamera and PipeWire, **without rebuilding the kernel**.

The Surface Pro 7's cameras sit behind an Intel IPU4P image processor (PCI `8086:8a19`). Neither mainline Linux nor the linux-surface kernel has a driver for it yet, so no camera shows up at all. This repository packages the driver work others have published, plus the fixes that were needed to get from "a camera shows up" to a usable picture, as a DKMS module with an installer.

> **Read this first**
>
> - Tested on **one** Surface Pro 7 (model 1866): Fedora 44, linux-surface kernel 7.3.4, libcamera 0.7.2, Secure Boot on.
> - Works on the **linux-surface 7.3.x kernel only**. DKMS skips every other kernel. See [Other kernels](#other-kernels).
> - It replaces five kernel modules with patched builds. The driver is an RFC patch series that is still under review upstream. Expect rough edges, and expect this repository to become unnecessary once the driver is merged.
> - The infrared camera (Windows Hello) does not work.

## What it fixes

| Problem | Fix |
|---|---|
| No driver for the IPU4P, no camera at all | Mainline `intel-ipu6` driver plus the 12-patch IPU4P RFC v2 series by Ruslan Bay, built out of tree with DKMS |
| Front camera gives empty frames at 720p and below | Patched `ov5693` sensor driver |
| Both pictures are mirrored left to right | `mirror=1` option added to both sensor drivers |
| Rear picture is out of focus | Patched `ov8865` and `dw9719`: the lens motor is powered and held at a fixed position |
| Rear picture is dark and grey | Auto-exposure fixes in `ov8865` |
| Washed-out colours | libcamera colour tuning files for both sensors |
| Pink lines, colours that depend on what is in the top left corner | Two fixes to libcamera's GPU processing, applied to a private copy that only WirePlumber loads |

## Install

You need a Surface Pro 7 running the [linux-surface](https://github.com/linux-surface/linux-surface) kernel, version 7.3.x.

```bash
git clone https://github.com/RWS-HeNa93/sp7-camera-dkms.git
cd sp7-camera-dkms
./install.sh
```

Run it as your normal user from a terminal. It asks for your password once. Then reboot.

What the installer does:

1. Checks the machine and the kernel.
2. On Fedora, installs the build tools that are missing (`dkms`, `kernel-surface-devel` for the running kernel, `gcc`, `make`, `openssl`, `mokutil`, and `cabextract` if nothing that can unpack the firmware package is there). On other distributions it tells you what is missing.
3. Downloads Intel's firmware from Microsoft's driver package (31 MB) and checks its SHA-256. The firmware is Intel's and not ours to redistribute, so it is not in this repository.
4. Builds and installs the modules with DKMS.
5. If Secure Boot is on, queues DKMS's signing key for enrolment and asks you for a one-time password.
6. Installs the camera settings, the colour tuning files and the libcamera fix.

**Secure Boot:** on the first reboot a blue "MOK management" screen appears once. Choose **Enroll MOK**, **Continue**, **Yes**, enter the password you chose, then **Reboot**. This key is DKMS's own (`/var/lib/dkms/mok.pub`), separate from the linux-surface kernel's key. Without this step the kernel refuses to load the modules.

On Fedora, DKMS rebuilds every boot image after it installs a module, so the build step can take a few minutes.

Options: `./install.sh --help`. The useful ones are `--firmware FILE` (use a firmware file you got yourself), `--no-libcamera-fix` and `--reload` (when updating an install that already works: swap the running modules instead of rebooting).

### Other distributions

Only Fedora has been tested. The driver itself is plain DKMS, so it should build on any distribution running a linux-surface 7.3 kernel. Install DKMS, a compiler, the headers of the running kernel, `mokutil` and `cabextract` first; the installer prints package names for Debian/Ubuntu and Arch if something is missing. The statistics part of the libcamera fix only applies to Fedora's build of libcamera, see [libcamera-fix/README.md](libcamera-fix/README.md).

## What gets installed

| File | What it is |
|---|---|
| `/usr/src/sp7-ipu4p-rfcv2/` | Driver source for DKMS: `intel-ipu6`, `intel-ipu6-isys`, `ov5693`, `ov8865`, `dw9719`. The built modules go to `/lib/modules/<kernel>/extra/` and take the place of the stock ones |
| `/usr/lib/firmware/intel/ipu/ipu4p_fw.bin` | Intel's firmware for the image processor |
| `/etc/modprobe.d/sp7-camera.conf` | Driver options: mirroring, lens motor, focus position |
| `/etc/libcamera/ipa/simple/ov5693.yaml`, `ov8865.yaml` | Colour tuning for the front and rear sensor |
| `~/.local/bin/sp7-libcamera-fix` | Writes the corrected copy of libcamera to `~/.local/lib/libcamera-sp7/` |
| `~/.local/share/sp7-libcamera/` | The stock and the corrected shader text that script uses |
| `~/.config/systemd/user/wireplumber.service.d/sp7-libcamera.conf` | Makes WirePlumber run that script and load the copy |

No system library is modified. The files in your home folder are installed for the user who runs `install.sh`.

## Check it works

```bash
dkms status                                  # sp7-ipu4p/rfcv2 ... installed
lsmod | grep -E 'ipu6|ov5693|ov8865|dw9719'  # all five modules loaded
cam -l                                       # lists both cameras (package libcamera-tools)
~/.local/bin/sp7-libcamera-fix --status      # which libcamera fixes apply here
journalctl --user -u wireplumber -b | grep 'tuning file'   # ov5693.yaml and ov8865.yaml from /etc
```

Then open a camera app and switch between the two cameras. Text should read the right way round, the rear picture should be sharp at room distance, and something white should look white.

If no camera shows up:

- `dkms status` should say `installed` for the running kernel.
- `sudo dmesg | grep -iE 'ipu|ov5693|ov8865|dw9719'`. A message like "Key was rejected by service" or "module verification failed" means the signing key is not enrolled; see Secure Boot above.
- `cat /sys/module/{ov5693,ov8865,dw9719}/parameters/*` should work. If the parameters are missing, the stock modules are loaded instead of the patched ones.

## Rear focus

libcamera has no autofocus for these cameras, so the rear lens is held at one position: `default_focus=220` in `/etc/modprobe.d/sp7-camera.conf`. That value was calibrated on one tablet, lying roughly level and looking at a room 2-3 m away. Yours may need a different one. Larger values focus closer.

To set a value: `sudo scripts/set-focus.sh 250`.

To calibrate, point the rear camera at something detailed at the distance you want sharp, keep the tablet still, and run:

```bash
sudo REPEATS=3 scripts/focus-calibrate.sh /tmp/focus top 150 200 220 250 300 350
rm -r /tmp/focus
```

`top` is the part of the picture to make sharp (`full`, `top`, `mid`, `bot` or `centre`), the numbers are the positions to try, and `REPEATS=3` tries each one three times and judges it by its worst frame. It needs `v4l-utils`, `python3` and ImageMagick, stops WirePlumber while it runs (no camera or sound for a minute or so), and saves the best position. The lens position for a given value shifts with the tablet's tilt, so calibrate in the position you use it in.

## Changing things

| To change | Do |
|---|---|
| A driver option | Edit `/etc/modprobe.d/sp7-camera.conf` and reboot. The options marked "(live)" in that file can also be written to `/sys/module/<driver>/parameters/` |
| Colour tuning | Edit the `.yaml` file, then `systemctl --user restart wireplumber` |
| Switch the libcamera fix off | Delete `~/.config/systemd/user/wireplumber.service.d/sp7-libcamera.conf`, then `systemctl --user daemon-reload` and restart WirePlumber |

Restarting WirePlumber cuts the camera in any open app and interrupts sound for a moment. `install.sh` keeps settings files you have changed; `--overwrite-config` replaces them.

## After updates

**Kernel updates within 7.3.x:** DKMS rebuilds and signs the modules for the new kernel by itself, provided the matching kernel headers are installed (on Fedora, `kernel-surface-devel` follows the kernel). We have not yet been through a real kernel update with this.

**libcamera updates:** the corrected copy is rebuilt from the installed library before every WirePlumber start, with whichever fixes still match. When none matches, WirePlumber simply uses the system library. `sp7-libcamera-fix --status` shows the state. libcamera 0.8.0 has a different shader text, so both fixes will drop out there until they are ported.

**This repository:** `git pull`, then `./install.sh` again.

### Other kernels

`dkms.conf` has `BUILD_EXCLUSIVE_KERNEL="^7\.3\..*surface"`, so on any other kernel DKMS skips the package and the cameras stop working until the source is ported. Your last 7.3 kernel stays in the boot menu. To port:

1. Run `source/regenerate.sh <scratch folder>` to rebuild the source tree from its parts and confirm that it matches `dkms/`.
2. The IPU part is written for 7.4 already: remove the "kernel 7.3 API" edit in that script.
3. Take `ov5693.c`, `ov8865.c` and `dw9719.c` from the new linux-surface kernel branch and apply `source/sensors/*.patch` to them. If linux-surface has merged these fixes itself, drop our copies of the sensor drivers, because they shadow the kernel's.
4. Change `BUILD_EXCLUSIVE_KERNEL`, copy the new tree into `dkms/`, and run `./install.sh`.

If the IPU4P driver has reached your kernel by then, uninstall this instead.

## Known limits

- No autofocus on the rear camera.
- The infrared camera (OV7251) doesn't work; the RFC series doesn't cover it. Its driver fails to start with error -110, which is harmless.
- White balance averages the whole scene to grey, so a picture that is mostly one colour drifts.
- The rear camera has no colour calibration of its own. It borrows the front camera's daylight matrix, which looks natural but is an approximation.
- At 1280x720 and below the rear camera uses a faster, lower-resolution readout that has faint green and magenta fringes on sharp horizontal edges.
- A 16:9 picture from a 4:3 readout keeps the full width and takes its rows from the top of the frame, not the middle.
- WirePlumber also lists 64 raw `ipu4p [v4l2]` devices that apps can't use.

## Uninstall

```bash
./uninstall.sh
```

Then reboot. The stock modules come back and the cameras disappear again. Installed packages and the DKMS signing key are left in place; the script prints how to remove the key.

## How the driver source is put together

`dkms/` is generated, not written by hand. `source/regenerate.sh` rebuilds it from:

| Part | From |
|---|---|
| `intel-ipu6` driver | linux-media `media-committers`, commit `27285b099fbc` |
| IPU4P support | `source/ipu4p-rfcv2/`: the RFC v2 series from [ruslanbay/ipu4-drivers](https://github.com/ruslanbay/ipu4-drivers), branch `upstream`, commit `f0b3dfa` |
| 7.3 compatibility | One edit: drop the `v4l2_subdev_client_info` argument that only 7.4 has |
| `ov5693.c`, `ov8865.c`, `dw9719.c` | linux-surface kernel, branch `v7.3-surface`, at commits `00a71904ce4a`, `f4cdf7ca9a1f` and `d6aaeeec414a`, plus `source/sensors/*.patch` |

Each sensor patch explains itself at the top. In short:

- **ov5693** (front): the 2x2-binned 1296x972 mode gave only "Frame sync error" with a flip on, and libcamera always sets both flips and uses that mode for 1280x720 and smaller. The fix is the ov5693 part of [linux-surface/kernel#181](https://github.com/linux-surface/kernel/pull/181). Adds `mirror`.
- **ov8865** (rear): adds `mirror` and `vcm` (keeps the lens motor powered while the camera streams). Auto-exposure: the gain control stepped in units of 128, which rounded every small step back to 1x, and the exposure limit announced for a mode was higher than the real one, so libcamera never raised the gain. It also starts at a sensible exposure and gain, because libcamera's auto-exposure only moves 15-25% per second.
- **dw9719** (rear lens): `default_focus` (position applied at every power-up), `focus_overshoot` (go past the position and come back, otherwise the lens stuck short of it in 3 of 8 starts), `devnode=0` (no device node, otherwise libcamera keeps the lens and sensor powered for as long as WirePlumber runs).

**Mirroring:** libcamera can't be told to mirror, so `mirror=1` makes the drivers invert the horizontal flip. Every app then gets the true picture, and video-call apps mirror your own preview themselves.

**Colour tuning:** without a tuning file libcamera uses no colour correction at all. The front camera's six colour matrices were converted from the Windows driver's tuning file by [ConsultingFuture4200/sp7-camera](https://github.com/ConsultingFuture4200/sp7-camera); the black levels of both sensors were measured on raw frames.

**libcamera:** see [libcamera-fix/README.md](libcamera-fix/README.md).

## How far this has been tested

On one Surface Pro 7, with Fedora 44, kernel 7.3.4-2.surface, libcamera 0.7.2-2.fc44 and Secure Boot on:

- Both cameras work in the Camera app and in Chrome, also after a reboot. That was with the same files installed by hand, before the installer existed.
- Both cameras streamed at 320x240 to 2560x1440, 32 of 32 starts, with no kernel errors.
- `source/regenerate.sh` rebuilt the driver source from a fresh download, identical to `dkms/`.
- `./uninstall.sh` removed everything, and `./install.sh --reload` put it back, including the firmware download and the build. Both cameras then streamed at 1280x720 and 1920x1080 through PipeWire with no kernel errors. The modules were swapped live in that run, not through a reboot.
- `scripts/fetch-firmware.sh` with `cabextract` and with `7z`; `scripts/focus-calibrate.sh` and `scripts/set-focus.sh`.

Not tested:

- any other distribution, or any other machine
- the installer on a system where the build tools were missing (they were all there) or where the signing key was not enrolled yet (it was)
- a kernel update
- the libcamera source patches as source

## Credits

This is mostly other people's work, put together:

- **Ruslan Bay** wrote the IPU4P RFC series ([ruslanbay/ipu4-drivers](https://github.com/ruslanbay/ipu4-drivers)), with the co-developers named in its patches, building on the mainline IPU6 driver and Antti Laakso's IPU7 series.
- **rylos** and **D. Manresa** wrote the ov5693 and ov8865 fixes ([linux-surface/kernel#181](https://github.com/linux-surface/kernel/pull/181), [linux-surface/linux-surface#2252](https://github.com/linux-surface/linux-surface/pull/2252)).
- **ConsultingFuture4200** decoded the Windows tuning file ([sp7-camera](https://github.com/ConsultingFuture4200/sp7-camera)).
- The **linux-surface** project maintains the kernel and the sensor drivers this builds on. The mirror and default-focus options follow ideas from surface-kit.
- Everyone in [linux-surface discussion #1353](https://github.com/linux-surface/linux-surface/discussions/1353), which is where to follow the upstream work.

## Licence

The driver source and the patches are Linux kernel code under GPL-2.0, as marked in each file. The scripts and documentation here are under GPL-2.0-only as well ([LICENSE](LICENSE)). Exceptions, as marked in the files: the libcamera tuning files (CC0-1.0) and libcamera's shader (BSD-2-Clause).

Intel's firmware is not part of this repository and stays under Intel's terms.

No warranty. This replaces kernel modules on your machine; use it at your own risk.
