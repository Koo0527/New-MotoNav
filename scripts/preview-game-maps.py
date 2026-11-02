#!/usr/bin/env python3
"""Reproducible synthetic layout using the firmware's RGB565 theme helpers."""
from pathlib import Path
import subprocess
import tempfile
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[1]
font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 23)
small = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 17)
out = root / 'docs/verification/game-minimaps-build19.png'
sheet = Image.new('RGB', (3 * 486, 2 * 520 + 64), '#16171c')
draw = ImageDraw.Draw(sheet)
with tempfile.TemporaryDirectory(prefix='motonav-game-preview-') as folder:
    binary = Path(folder) / 'preview'
    subprocess.run(['clang++', '-std=c++17', '-O2', str(root / 'firmware/tests/game_map_preview.cpp'), '-o', str(binary)], check=True)
    for night in range(2):
        for theme, name in enumerate(['Vice City', 'GTA5', 'Cyberpunk'], 1):
            ppm = Path(folder) / f'{theme}-{night}.ppm'
            subprocess.run([str(binary), str(theme), str(night), str(ppm)], check=True)
            image = Image.open(ppm).convert('RGB')
            ink = ImageDraw.Draw(image)
            ink.text((233, 37), 'N', font=small, fill='white', anchor='mm')
            ink.rounded_rectangle((200, 52, 266, 91), radius=10, fill='#101014')
            ink.text((233, 71), '50', font=font, fill='white', anchor='mm')
            x, y = (theme - 1) * 486 + 10, night * 520 + 40
            sheet.paste(image, (x, y))
            draw.text((x + 233, y - 20), f'{name} / {"Night" if night else "Day"}', font=font, fill='white', anchor='mm')
    icon = Path(folder) / 'waypoint.ppm'
    subprocess.run([str(binary), '2', '0', str(icon), 'icon'], check=True)
    Image.open(icon).crop((215, 215, 251, 251)).resize((288, 288), Image.Resampling.NEAREST).save(root / 'docs/verification/gta5-waypoint-build19.png')
draw.text((20, 1068), 'Synthetic scene - production colors, player geometry, route phase and ring pixels. Not an SDK screenshot.', font=small, fill='#b8bbc5')
sheet.save(out)
print(out)
