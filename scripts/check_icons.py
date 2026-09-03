#!/usr/bin/env python3
"""Validate checked-in app icon resources offline, using only Python's stdlib."""

import json
import math
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ANDROID = ROOT / 'clipy_android/android/app/src/main/res'
IOS = ROOT / 'clipy_android/ios/Runner/Assets.xcassets/AppIcon.appiconset'
ATTR = '{http://schemas.android.com/apk/res/android}'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def png(path, size, alpha):
    """Read our 8-bit, non-interlaced RGB/RGBA exports, including actual alpha."""
    data = path.read_bytes()
    require(data[:8] == b'\x89PNG\r\n\x1a\n', f'{path.name}: not a PNG')
    offset, compressed = 8, bytearray()
    header = None
    while offset < len(data):
        length = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        checksum = struct.unpack_from('>I', data, offset + 8 + length)[0]
        require(zlib.crc32(kind + payload) == checksum, f'{path.name}: invalid PNG checksum')
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', payload)
        elif kind == b'IDAT':
            compressed.extend(payload)
        elif kind == b'tRNS':
            raise ValueError(f'{path.name}: unexpected indexed/color-key transparency')
        offset += length + 12
        if kind == b'IEND':
            break
    channels = 4 if alpha else 3
    require(header == (size, size, 8, 6 if alpha else 2, 0, 0, 0),
            f'{path.name}: expected {size}x{size} 8-bit {"RGBA" if alpha else "RGB"}, got {header}')
    raw = zlib.decompress(compressed)
    stride = size * channels
    require(len(raw) == (stride + 1) * size, f'{path.name}: invalid pixel count')
    if not alpha:
        return None
    rows, previous = [], bytearray(stride)
    for y in range(size):
        start = y * (stride + 1)
        mode = raw[start]
        require(mode in range(5), f'{path.name}: unsupported PNG filter')
        row = bytearray(raw[start + 1:start + 1 + stride])
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            up = previous[x]
            corner = previous[x - channels] if x >= channels else 0
            prediction = left + up - corner
            distances = [abs(prediction - value) for value in (left, up, corner)]
            paeth = (left, up, corner)[distances.index(min(distances))]
            row[x] = (row[x] + (0, left, up, (left + up) // 2, paeth)[mode]) & 255
        rows.append(row)
        previous = row
    return rows


def main():
    for relative, size in [('Clipy/Resources/AppIcon.png', 1024), ('Logo.png', 512),
                           ('assets/logo/logo_placeholder.png', 192)]:
        rows = png(ROOT / relative, size, True)
        require(rows[0][3] == rows[-1][-1] == 0, f'{relative}: corners must be transparent')
        require(rows[size // 2][(size // 2) * 4 + 3] == 255, f'{relative}: missing tile')
    for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
        png(ANDROID / f'mipmap-{density}/ic_launcher.png', size, True)

    foreground = png(ANDROID / 'drawable-xxxhdpi/ic_launcher_foreground.png', 432, True)
    mono = png(ANDROID / 'drawable-xxxhdpi/ic_launcher_monochrome.png', 432, True)
    visible = 0
    for y, row in enumerate(foreground):
        for x in range(432):
            i = x * 4
            alpha = row[i + 3]
            require(alpha == mono[y][i + 3], 'Android monochrome/foreground silhouettes differ')
            if alpha > 12:
                visible += 1
                require(math.hypot(x - 215.5, y - 215.5) <= 132,
                        'Android foreground exceeds the centered 66 dp safe circle')
                require(all(value == 255 for value in mono[y][i:i + 3]),
                        'Android themed icon must have a white silhouette')
    require(visible > 10000, 'Android foreground is empty or too small')

    for api in (26, 33):
        icon = ET.parse(ANDROID / f'mipmap-anydpi-v{api}/ic_launcher.xml').getroot()
        expected = {'background': '@drawable/ic_launcher_background',
                    'foreground': '@drawable/ic_launcher_foreground'}
        if api == 33:
            expected['monochrome'] = '@drawable/ic_launcher_monochrome'
        require(icon.tag == 'adaptive-icon', f'API {api}: missing adaptive icon')
        require({child.tag: child.get(ATTR + 'drawable') for child in icon} == expected,
                f'API {api}: wrong adaptive icon layers')
    background = ET.parse(ANDROID / 'drawable/ic_launcher_background.xml').getroot()
    for name in ('startColor', 'endColor'):
        require(re.fullmatch(r'#[0-9A-Fa-f]{6}', background.find('gradient').get(ATTR + name, '')),
                f'Invalid Android background {name}')
    application = ET.parse(ANDROID.parent / 'AndroidManifest.xml').getroot().find('application')
    require(application.get(ATTR + 'icon') == '@mipmap/ic_launcher', 'Launcher icon is not wired up')

    catalogue = json.loads((IOS / 'Contents.json').read_text())
    checked = set()
    for entry in catalogue['images']:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
        key = (entry['filename'], size)
        if key not in checked:
            png(IOS / entry['filename'], size, False)
            checked.add(key)
    require(len(checked) == 15, 'Unexpected iOS icon catalogue; review platform coverage')
    print('App icons passed: macOS/README, Android legacy/adaptive/themed, 15 opaque iOS sizes.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, struct.error, ET.ParseError, zlib.error) as error:
        print(f'Icon validation failed: {error}', file=sys.stderr)
        sys.exit(1)
