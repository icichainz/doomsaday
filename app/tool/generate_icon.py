#!/usr/bin/env python3
"""Generate the Doomsaday app icons, one set per edition.

Original artwork: a "D" with angular bone-like spikes breaking out of its
silhouette. The geometry is the same in both editions; only the two colours
change — Free is the mint mark on the app's dark ground, Pro is an ivory mark
on deep red. No third-party packages are required, so this runs on a plain
`python3 tool/generate_icon.py` from the `app/` directory.

Outputs, for `<edition>` in free and pro
  assets/icon/<edition>/app_icon.png             1024x1024, opaque, iOS and
                                                 legacy Android
  assets/icon/<edition>/app_icon_foreground.png  1024x1024, transparent,
                                                 the Android adaptive layer
  macos/Runner/Assets.xcassets/AppIcon-<edition>.appiconset/
                                                 the ten macOS sizes, rendered
                                                 rather than downscaled

The Android and iOS icons are cut from the two 1024 px sources by
`dart run flutter_launcher_icons`, which reads flutter_launcher_icons-free.yaml
and flutter_launcher_icons-pro.yaml. Its macOS generator has no flavor support
— it would write both editions over one AppIcon.appiconset — so the macOS sets
are written here instead.

Replace the two app_icon.png files with your own licensed 1024x1024 artwork and
rerun `dart run flutter_launcher_icons` if you do not want this placeholder.
"""

import json
import math
import os
import struct
import zlib

SIZE = 1024
SUBSAMPLES = 8

GROUND = (0x0E, 0x14, 0x17)
MINT = (0x5B, 0xE3, 0xB0)
PRO_RED = (0x9E, 0x1B, 0x1B)
IVORY = (0xFA, 0xF3, 0xE8)

# design/README.md, "Editions": same mark, two colourways.
EDITIONS = {
    'free': {'background': GROUND, 'mark': MINT},
    'pro': {'background': PRO_RED, 'mark': IVORY},
}

# The ten entries of a macOS AppIcon set, as Xcode writes them.
MACOS_IMAGES = [
    ('16x16', '1x', 16), ('16x16', '2x', 32),
    ('32x32', '1x', 32), ('32x32', '2x', 64),
    ('128x128', '1x', 128), ('128x128', '2x', 256),
    ('256x256', '1x', 256), ('256x256', '2x', 512),
    ('512x512', '1x', 512), ('512x512', '2x', 1024),
]


class Raster:
    """Scanline polygon rasteriser (even-odd, anti-aliased) writing an RGBA PNG.

    Shapes accumulate into one coverage mask so that overlapping spikes and the
    letter stay a single flat silhouette with no seams.
    """

    def __init__(self, size=SIZE):
        self.size = size
        self.mask = [0.0] * (size * size)

    def fill(self, contours):
        """Add one shape. Several contours in one call cut holes (even-odd)."""
        edges = []
        for contour in contours:
            for i in range(len(contour)):
                x0, y0 = contour[i]
                x1, y1 = contour[(i + 1) % len(contour)]
                if y0 != y1:
                    edges.append((x0, y0, x1, y1))
        if not edges:
            return
        top = max(0, int(math.floor(min(min(e[1], e[3]) for e in edges))))
        bottom = min(self.size, int(math.ceil(max(max(e[1], e[3]) for e in edges))))
        step = 1.0 / SUBSAMPLES
        for y in range(top, bottom):
            coverage = [0.0] * self.size
            touched = False
            for s in range(SUBSAMPLES):
                sy = y + (s + 0.5) * step
                crossings = []
                for x0, y0, x1, y1 in edges:
                    if (y0 <= sy < y1) or (y1 <= sy < y0):
                        crossings.append(x0 + (sy - y0) * (x1 - x0) / (y1 - y0))
                if not crossings:
                    continue
                crossings.sort()
                for i in range(0, len(crossings) - 1, 2):
                    if self._span(coverage, crossings[i], crossings[i + 1], step):
                        touched = True
            if touched:
                base = y * self.size
                for x, value in enumerate(coverage):
                    if value > self.mask[base + x]:
                        self.mask[base + x] = 1.0 if value > 1.0 else value

    def _span(self, coverage, xa, xb, weight):
        xa = max(0.0, xa)
        xb = min(float(self.size), xb)
        if xb <= xa:
            return False
        first, last = int(xa), int(math.ceil(xb)) - 1
        if first == last:
            coverage[first] += (xb - xa) * weight
            return True
        coverage[first] += (first + 1 - xa) * weight
        for x in range(first + 1, last):
            coverage[x] += weight
        coverage[last] += (xb - last) * weight
        return True

    def write_png(self, path, color, background=None):
        pixels = bytearray(self.size * self.size * 4)
        fr, fg, fb = color
        for i, a in enumerate(self.mask):
            if background is None:
                pixels[i * 4:i * 4 + 4] = bytes((fr, fg, fb, int(round(a * 255))))
            else:
                pixels[i * 4:i * 4 + 4] = bytes(
                    tuple(int(round(f * a + b * (1 - a))) for f, b in zip(color, background))
                    + (255,))

        raw = bytearray()
        stride = self.size * 4
        for y in range(self.size):
            raw.append(0)
            raw += pixels[y * stride:(y + 1) * stride]

        def chunk(tag, data):
            body = tag + data
            return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body))

        header = struct.pack('>IIBBBBB', self.size, self.size, 8, 6, 0, 0, 0)
        png = (b'\x89PNG\r\n\x1a\n'
               + chunk(b'IHDR', header)
               + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
               + chunk(b'IEND', b''))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as handle:
            handle.write(png)


def arc(cx, cy, rx, ry, start_deg, end_deg, steps=48):
    points = []
    for i in range(steps + 1):
        angle = math.radians(start_deg + (end_deg - start_deg) * i / steps)
        points.append((cx + rx * math.cos(angle), cy + ry * math.sin(angle)))
    return points


def letter_d():
    """Outer silhouette plus the counter, in design-space coordinates."""
    top, bottom, cy = 232.0, 792.0, 512.0
    stem_left, stem_right, shoulder = 300.0, 420.0, 520.0
    outer_right, bar = 736.0, 116.0

    outer = [(stem_left, top), (shoulder, top)]
    outer += arc(shoulder, cy, outer_right - shoulder, cy - top, -90, 90)
    outer += [(shoulder, bottom), (stem_left, bottom)]

    inner_top, inner_bottom = top + bar, bottom - bar
    inner = [(stem_right, inner_top), (shoulder, inner_top)]
    inner += arc(shoulder, cy, outer_right - bar - shoulder, cy - inner_top, -90, 90)
    inner += [(shoulder, inner_bottom), (stem_right, inner_bottom)]
    return [outer, inner]


SPIKES = [
    [(300, 262), (300, 372), (138, 296)],
    [(300, 450), (300, 556), (116, 508)],
    [(300, 640), (300, 744), (152, 718)],
    [(668, 330), (692, 432), (884, 300)],
    [(668, 694), (692, 592), (884, 724)],
    [(462, 232), (566, 232), (516, 96)],
    [(470, 792), (560, 792), (512, 906)],
]


def transform(shapes, fraction, size=SIZE):
    """Centre every shape in the canvas and scale it to `fraction` of the side."""
    points = [p for shape in shapes for contour in shape for p in contour]
    min_x = min(p[0] for p in points)
    max_x = max(p[0] for p in points)
    min_y = min(p[1] for p in points)
    max_y = max(p[1] for p in points)
    scale = size * fraction / max(max_x - min_x, max_y - min_y)
    dx = size / 2 - (min_x + max_x) / 2 * scale
    dy = size / 2 - (min_y + max_y) / 2 * scale
    return [[[(x * scale + dx, y * scale + dy) for x, y in contour] for contour in shape]
            for shape in shapes]


def render(path, mark, background, fraction, size=SIZE):
    """One PNG: the mark in `mark`, on `background`, or transparent when None."""
    canvas = Raster(size)
    for shape in transform([letter_d()] + [[s] for s in SPIKES], fraction, size):
        canvas.fill(shape)
    canvas.write_png(path, mark, background)
    print('wrote', path)


def macos_appiconset(directory, mark, background):
    """The ten sizes plus the Contents.json Xcode expects beside them."""
    for _, _, pixels in MACOS_IMAGES:
        render(os.path.join(directory, 'app_icon_%d.png' % pixels),
               mark, background, 0.74, pixels)
    images = [{'size': size, 'idiom': 'mac', 'filename': 'app_icon_%d.png' % pixels,
               'scale': scale} for size, scale, pixels in MACOS_IMAGES]
    contents = {'info': {'version': 1, 'author': 'xcode'}, 'images': images}
    with open(os.path.join(directory, 'Contents.json'), 'w') as handle:
        json.dump(contents, handle, indent=4)
        handle.write('\n')


if __name__ == '__main__':
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for edition, colours in EDITIONS.items():
        mark, background = colours['mark'], colours['background']
        out = os.path.join(here, 'assets', 'icon', edition)
        render(os.path.join(out, 'app_icon.png'), mark, background, 0.74)
        # The adaptive foreground is the mark alone, inside the 66% safe zone.
        render(os.path.join(out, 'app_icon_foreground.png'), mark, None, 0.52)
        macos_appiconset(
            os.path.join(here, 'macos', 'Runner', 'Assets.xcassets',
                         'AppIcon-%s.appiconset' % edition),
            mark, background)
