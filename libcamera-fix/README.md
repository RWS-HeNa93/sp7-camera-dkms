# libcamera fixes

libcamera 0.7.2 processes the camera picture on the GPU ("software ISP"), and
that code has two faults that show on the Surface Pro 7 as soon as a colour
tuning file is loaded. Both were still in libcamera 0.8.0 and master on
2026-11-20.

1. **Shader** (`bayer_unpacked.frag`). When the picture is scaled, some output
   pixels are read from the neighbour of the pixel their Bayer colour is
   computed for, and the outermost pixels are read from past the edge. Result:
   one-pixel pink lines (for example at x=1226 in a 1280x720 picture from the
   front camera) and a tinted first row and column.
2. **Statistics window** (`DebayerEGL::configure`). White balance, exposure
   and black level are worked out from a window of the *output* size at the
   top left of the *sensor* frame: 35% of the frame for a 1920x1080 picture
   from the rear camera's 3264x1836 mode. Whatever is in that corner gets
   averaged to grey. Measured on one scene: libcamera chose gains 1.87/1.50,
   the whole frame needed 2.07/1.40, and with the fix it chooses 2.09/1.40.

libcamera's CPU mode has neither fault, but it cannot scale: it cuts the
picture out of the middle of the sensor frame, which looks zoomed in.

## What install.sh sets up

`sp7-libcamera-fix` makes a corrected **copy** of the installed libcamera in
`~/.local/lib/libcamera-sp7/`, and a WirePlumber drop-in makes WirePlumber
(which runs the cameras for apps) load that copy. The system library is never
changed. The script runs before every WirePlumber start:

- It applies each fix only if the bytes it replaces are found exactly once.
- The shader fix replaces the shader text, so it applies to any build of
  libcamera whose shader is unchanged (0.7.2).
- The statistics fix replaces 43 bytes of machine code and applies only to
  Fedora's `libcamera-0.7.2-2.fc44.x86_64`.
- If neither applies, it removes the copy and WirePlumber uses the system
  library as usual.

`sp7-libcamera-fix --status` shows which fixes apply on your system.

To see the same picture with the `cam` tool, run it with
`LD_LIBRARY_PATH=~/.local/lib/libcamera-sp7`.

## Building libcamera yourself

`patches/` has the same two changes as source patches against libcamera
v0.7.2:

```bash
git clone --branch v0.7.2 https://github.com/libcamera-org/libcamera.git
cd libcamera
patch -p1 < /path/to/libcamera-fix/patches/libcamera-0.7.2-shader.patch
patch -p1 < /path/to/libcamera-fix/patches/libcamera-0.7.2-stats-window.patch
```

What was tested is the corrected copy described above. The shader patch is
the same shader text with the original comments kept. The statistics patch is
the source equivalent of the machine code change and has **not** been compiled
by us.

With a libcamera built this way, install with `./install.sh --no-libcamera-fix`.
