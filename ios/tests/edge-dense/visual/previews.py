"""Display frozen-shader pixels; enlargement is nearest-neighbor only."""
from pathlib import Path
import json
from PIL import Image, ImageChops, ImageDraw

OUT = Path(__file__).resolve().parents[4] / 'output/map-edge-bridge/visual-fit-probe'


def main():
    variants = ('C-control', 'D20', 'D25')
    images = []
    for variant in variants:
        image = Image.open(OUT / f'{variant}-fresh03-preview/denseC-45.ppm').convert('RGB')
        image.save(OUT / f'{variant}-fresh03-45.png')
        images.append(image)
    previous = OUT.parent/'isolated-dense-preview/denseC-45.png'
    assert ImageChops.difference(images[0], Image.open(previous).convert('RGB')).getbbox() is None
    labels = ['C .14 (0.56m)', 'D .20 (0.8m) - 482546B REJECT', 'D .25 (1.0m) - 483736B REJECT']
    canvas = Image.new('RGB', (1304, 464), '#202124')
    draw = ImageDraw.Draw(canvas)
    for i, (image, label) in enumerate(zip(images, labels)):
        canvas.paste(image, (i*440, 40))
        draw.text((i*440+5, 12), label, fill='white')
    canvas.save(OUT/'fresh03-45-C-D20-D25.png')
    diff = ImageChops.difference(images[0], images[1])
    mask = diff.convert('L').point(lambda v: 255 if v else 0)
    best = (-1, None)
    for y in range(0, 321, 8):
        for x in range(0, 321, 8):
            count = sum(bool(a) for a in mask.crop((x, y, x+104, y+104)).get_flattened_data())
            if count > best[0]: best = (count, (x, y, x+104, y+104))
    box = best[1]
    canvas = Image.new('RGB', (968, 352), '#202124')
    draw = ImageDraw.Draw(canvas)
    for i, (image, label) in enumerate(zip(images, ['C .14', 'D .20 - over budget', 'D .25 - over budget'])):
        canvas.paste(image.crop(box).resize((312, 312), Image.Resampling.NEAREST), (i*328, 40))
        draw.text((i*328+5, 12), label, fill='white')
    canvas.save(OUT/'fresh03-45-crop-nearest3x.png')
    metrics = dict(cropBoxOriginal424Pixels=box,
                   cropSelection='104x104 area with most C-to-D20 changed pixels; no source/render change; display-only nearest3x',
                   cropChangedPixels=best[0], frozenCMatchesPreviousPreview=True)
    for variant, image in zip(variants, images):
        diff = ImageChops.difference(images[0], image)
        metrics[variant] = dict(changedRGBPixels=sum(a != (0, 0, 0) for a in diff.get_flattened_data()), totalPixels=424*424)
    (OUT/'visual-metrics.json').write_text(json.dumps(metrics, indent=2)+'\n')


if __name__ == '__main__': main()
