#!/usr/bin/env python3
"""Icônes Apple TV d'Onyx, dessinées depuis la géométrie de onyx-mark.svg.

tvOS ne prend pas une image mais une pile de calques que le système décale
au survol (l'effet de parallaxe de l'écran d'accueil) : un fond, le faisceau
au milieu, la lentille et le triangle play devant. Plus les bannières « Top
Shelf » affichées quand l'app est dans la rangée du haut.

La marque est redessinée ici avec Pillow plutôt que rastérisée depuis le SVG :
elle n'est faite que d'un cercle, d'un triangle et d'un trapèze, et le script
tourne alors sur n'importe quelle machine — generate-icons.sh, lui, a besoin
des outils de macOS.

    python3 brand/generate-tvos-icons.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "app/tvos/Runner/Assets.xcassets/AppIcon.brandassets"

CHARCOAL = (0x12, 0x14, 0x14)
LENS = (0x0E, 0x10, 0x10)
INK = (0xE8, 0xE6, 0xE4)

# La géométrie de onyx-mark.svg (viewBox 512×512).
BEAM = [(202, 141), (477, 226), (477, 286), (202, 371)]
LENS_CENTER, LENS_RADIUS, LENS_STROKE = (162, 256), 130, 10
PLAY = [(122, 191), (122, 321), (227, 256)]
# La boîte qu'occupe la marque, contour de la lentille compris.
MARK_BOX = (27, 121, 477, 391)

SUPERSAMPLE = 4


def _placement(size, height_ratio):
    """Échelle et décalage qui centrent la marque, haute de [height_ratio]."""
    w, h = size
    x0, y0, x1, y1 = MARK_BOX
    scale = h * height_ratio / (y1 - y0)
    ox = (w - (x1 - x0) * scale) / 2 - x0 * scale
    oy = (h - (y1 - y0) * scale) / 2 - y0 * scale
    return scale, ox, oy


def _layer(size, height_ratio, draw_fn, background=None):
    big = (size[0] * SUPERSAMPLE, size[1] * SUPERSAMPLE)
    mode, fill = ("RGB", background) if background else ("RGBA", (0, 0, 0, 0))
    image = Image.new(mode, big, fill)
    scale, ox, oy = _placement(big, height_ratio)

    def pt(x, y):
        return (ox + x * scale, oy + y * scale)

    draw_fn(image, pt, scale)
    return image.resize(size, Image.LANCZOS)


def _draw_beam(image, pt, scale):
    # Le dégradé du SVG : opacité 0,9 à la lentille, 0 au bout, le tout à 35 %.
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).polygon([pt(*p) for p in BEAM], fill=255)
    x_start, x_end = pt(*BEAM[0])[0], pt(*BEAM[1])[0]
    ramp = Image.new("L", image.size, 0)
    ramp_px = ramp.load()
    width, height = image.size
    for x in range(width):
        t = min(max((x - x_start) / (x_end - x_start), 0.0), 1.0)
        alpha = round(255 * 0.9 * (1 - t) * 0.35)
        for y in range(height):
            ramp_px[x, y] = alpha
    alpha = Image.composite(ramp, Image.new("L", image.size, 0), mask)
    beam = Image.new("RGBA", image.size, INK + (0,))
    beam.putalpha(alpha)
    image.alpha_composite(beam) if image.mode == "RGBA" else image.paste(
        beam, (0, 0), beam
    )


def _draw_lens(image, pt, scale):
    draw = ImageDraw.Draw(image)
    cx, cy = pt(*LENS_CENTER)
    r = LENS_RADIUS * scale
    half = LENS_STROKE * scale / 2
    draw.ellipse(
        [cx - r - half, cy - r - half, cx + r + half, cy + r + half], fill=INK
    )
    draw.ellipse(
        [cx - r + half, cy - r + half, cx + r - half, cy + r - half], fill=LENS
    )
    draw.polygon([pt(*p) for p in PLAY], fill=INK)


def _draw_mark(image, pt, scale):
    _draw_beam(image, pt, scale)
    _draw_lens(image, pt, scale)


def _save(image, relative):
    path = ASSETS / relative
    image.save(path, optimize=True)
    print(f"{image.size[0]}x{image.size[1]}  {relative}")


def main():
    for stack, base, stem in (
        ("App Icon - Small.imagestack", (400, 240), "small"),
        ("App Icon - Large.imagestack", (1280, 768), "large"),
    ):
        for factor, suffix in ((1, ""), (2, "@2x")):
            size = (base[0] * factor, base[1] * factor)
            # La marque occupe un peu moins de la moitié de la hauteur : tvOS
            # agrandit et rogne l'icône au survol.
            ratio = 0.46
            layers = {
                "Back": _layer(size, ratio, lambda *_: None, background=CHARCOAL),
                "Middle": _layer(size, ratio, _draw_beam),
                "Front": _layer(size, ratio, _draw_lens),
            }
            for name, image in layers.items():
                _save(
                    image,
                    f"{stack}/{name}.imagestacklayer/Content.imageset/"
                    f"{stem}_{name.lower()}{suffix}.png",
                )

    for imageset, base, stem in (
        ("Top Shelf Image.imageset", (1920, 720), "top_shelf"),
        ("Top Shelf Image Wide.imageset", (2320, 720), "top_shelf_wide"),
    ):
        for factor, suffix in ((1, ""), (2, "@2x")):
            size = (base[0] * factor, base[1] * factor)
            _save(
                _layer(size, 0.42, _draw_mark, background=CHARCOAL),
                f"{imageset}/{stem}{suffix}.png",
            )


if __name__ == "__main__":
    main()
