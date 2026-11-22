#!/usr/bin/python3
"""Sharpness of the rear camera frames taken by focus-sweep.sh.

usage: focus-metric.py <sweep-dir> [region]

Reads <sweep-dir>/pos-NNNN-R.raw (3264x2448, 16-bit Bayer BGGR; R counts the
repeats of a position), takes one green plane, and measures the standard
deviation of its Laplacian (higher = sharper) for the whole frame and for
parts of it. Prints, per lens position, the worst repeat for every part, and
for <region> all repeats. The last line is "BEST <position>": the position
whose worst repeat is sharpest in <region>, one of full, top, mid, bot,
centre (default: top, where distant objects usually are).

Needs ImageMagick (magick). Exposure and gain are fixed during the sweep, so
the noise floor is the same in every frame and only the sharpness differs.
"""
import array
import glob
import os
import re
import subprocess
import sys

W, H = 3264, 2448
GW, GH = W // 2, H // 2
REGIONS = {
    'full': f'{GW}x{GH}+0+0',
    'top': f'{GW}x{GH // 3}+0+0',
    'mid': f'{GW}x{GH // 3}+0+{GH // 3}',
    'bot': f'{GW}x{GH // 3}+0+{2 * GH // 3}',
    'centre': f'{GW // 3}x{GH // 3}+{GW // 3}+{GH // 3}',
}


def measure(path, tmp):
    raw = array.array('H')
    with open(path, 'rb') as fh:
        raw.frombytes(fh.read())
    if len(raw) != W * H:
        return None
    green = array.array('H')
    for y in range(0, H, 2):
        green.extend(raw[y * W + 1:(y + 1) * W:2])
    # 10 significant bits -> 16-bit grey
    green = array.array('H', [min(65535, v * 64) for v in green])
    with open(tmp, 'wb') as fh:
        fh.write(green.tobytes())

    values = {}
    for name, geom in REGIONS.items():
        out = subprocess.run(
            ['magick', '-size', f'{GW}x{GH}', '-depth', '16', '-endian', 'LSB',
             f'gray:{tmp}', '-crop', geom, '+repage', '-scale', '50%',
             '-define', 'convolve:scale=!',
             '-morphology', 'Convolve', 'Laplacian:0',
             '-format', '%[fx:standard_deviation*1000]', 'info:'],
            capture_output=True, text=True, check=True).stdout
        values[name] = float(out)
    return values


def main():
    sweep = sys.argv[1]
    region = sys.argv[2] if len(sys.argv) > 2 else 'top'
    if region not in REGIONS:
        sys.exit(f"unknown region {region}; one of {', '.join(REGIONS)}")

    tmp = os.path.join(sweep, 'green.tmp')
    by_pos = {}
    for path in sorted(glob.glob(os.path.join(sweep, 'pos-*.raw'))):
        m = re.match(r'pos-(\d+)(?:-\d+)?\.raw$', os.path.basename(path))
        if not m:
            continue
        values = measure(path, tmp)
        if values:
            by_pos.setdefault(int(m.group(1)), []).append(values)
    if os.path.exists(tmp):
        os.remove(tmp)
    if not by_pos:
        sys.exit(f"no frames in {sweep}")

    print(f"{'pos':>5} " + ' '.join(f'{n:>8}' for n in REGIONS)
          + f"   {region}, every repeat")
    worst = {}
    for pos in sorted(by_pos):
        reps = by_pos[pos]
        low = {n: min(r[n] for r in reps) for n in REGIONS}
        worst[pos] = low[region]
        print(f"{pos:>5} " + ' '.join(f'{low[n]:>8.3f}' for n in REGIONS)
              + '   ' + ' '.join(f'{r[region]:.1f}' for r in reps))
    print(f"BEST {max(worst, key=worst.get)}")


if __name__ == '__main__':
    main()
