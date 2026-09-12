"""Rebuild the macOS iconset from the approved transparent design raster.

The original SVG and its lossless 1024px raster are authored/exported separately;
this script only scales and packages them, using macOS system tools.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / 'Sources/VelaApp/Resources/Design/app-icon.png'
destination = root / 'Sources/VelaApp/Resources/Vela.icns'
with tempfile.TemporaryDirectory(prefix='vela-icon-') as temporary:
    iconset = Path(temporary) / 'Vela.iconset'
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for factor, suffix in ((1, ''), (2, '@2x')):
            pixels = str(size * factor)
            subprocess.run(['sips', '-z', pixels, pixels, str(source), '--out',
                            str(iconset / f'icon_{size}x{size}{suffix}.png')],
                           check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(destination)], check=True)
print('Built Vela.icns at 16–1024 px; temporary iconset removed.')
