#!/usr/bin/env python3
"""Build Shir's app icon from the source render in ``docs/logo/``.

The source (``docs/logo/shir-icon-source.png``) is a *presentation* render: the
disc-stack mark and the word "Shir" sitting on a white rounded card, on a light
page, with a drop shadow. None of that belongs in an iOS app icon —

  * iOS masks its own superellipse and draws its own shadow, so baked-in
    corners and a shadow show up as a second, wrong-shaped tile inside the real
    one;
  * a wordmark is illegible at 60pt and costs ~40% of the canvas that the mark
    could be using instead;
  * the card's margins leave the mark small inside an already-small tile.

So this script throws the packaging away and keeps the mark. It cuts the mark
out of the card by alpha (an unmix against the measured card colour, which
keeps the anti-aliased edge instead of leaving a white fringe), then recomposes
it full-bleed at 1024 in the three appearances iOS asks for:

  light    opaque white field, mark centred            (no alpha — a primary
                                                        icon with alpha trips
                                                        asset-catalog
                                                        validation)
  dark     transparent, mark's near-black disc         (transparent so the
           inverted to near-white                       system's dark backdrop
                                                        shows through)
  tinted   transparent, greyscale                      (iOS multiplies the
                                                        user's tint by
                                                        luminance)

The dark and tinted variants cannot just reuse the light artwork: the front
disc is #1b1b21, which on a dark backdrop is a hole where the play button
should be. The neutral pixels get their luminance inverted (§ ``_invert_neutrals``)
while the saturated fan is left exactly as drawn.

Run after replacing the source render:

    ./scripts/make-app-icon.py            # writes the .appiconset
    ./scripts/make-app-icon.py --preview  # also writes home-screen previews

Needs Pillow and numpy (``pip install pillow numpy``).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import numpy as np
    from PIL import Image, ImageDraw
except ImportError as exc:  # pragma: no cover - operator feedback
    sys.exit(f"needs Pillow and numpy: {exc}")

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs" / "logo" / "shir-icon-source.png"
ICONSET = ROOT / "Shir" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
PREVIEW_DIR = ROOT / "docs" / "logo"

CANVAS = 1024

# How much of the tile's width the mark spans. The mask's corner radius is
# ~0.224 * 1024 = 229pt, and the mark is a wide, short shape whose extremes are
# at mid-edge rather than in the corners, so 0.82 clears the mask comfortably
# while still filling the tile.
MARK_WIDTH_FRACTION = 0.82

# The card the mark is printed on, sampled rather than assumed white — the
# render is #FEFEFE, and unmixing against pure white leaves a grey rim.
CARD = np.array([254.0, 254.0, 254.0])

# Alpha ramp, in units of distance-from-card. Below the floor is the discs' own
# soft shadow on the card, which would carry over as a grey haze on the
# transparent variants; above the ceiling is solid ink. Between them is the
# 1-2px anti-aliased edge that has to survive.
ALPHA_FLOOR, ALPHA_CEIL = 6.0, 30.0

# Distance-from-card at which a pixel is unambiguously ink rather than a soft
# shadow, used only to *locate* the mark. The alpha ramp above is far too
# permissive for that job: the card's own drop shadow on the page clears it, so
# a ramp-based bounding box grabs the whole card (measured: 977x489 from x=138,
# where the mark is 744 wide from x=261). Ink is 150+ from the card; the
# darkest page shadow measures well under 80.
INK_FLOOR = 80.0

# Rows/columns of anti-aliased edge to keep around the located mark, since the
# ink threshold above deliberately cuts inside it.
INK_PAD = 8

# Saturation band separating the black disc / white play triangle from the
# colour fan. Two points, not one: the disc renders at #14181F — a saturation
# of 11, not 0 — so a single ramp from 0 weighted it only 0.76 neutral and
# left the inverted disc a dull #BEBEC2 instead of near-white. Everything below
# FULL is treated as pure neutral; the fan sits an order of magnitude above
# NONE (verified by the saturation histogram this script prints).
NEUTRAL_SAT_FULL, NEUTRAL_SAT_NONE = 22.0, 50.0

# Where inverted neutrals land. Not #FFFFFF / #000000: the disc keeps a hair of
# warmth off pure white so it does not glare, and the play triangle matches the
# app's true-black body.
INK_LIGHT = np.array([245.0, 245.0, 247.0])
INK_DARK = np.array([11.0, 11.0, 13.0])

# Luminance range the inversion ramps across. Deliberately wider than the
# neutrals actually occupy (the disc is L≈24, the triangle L≈255) so both ends
# clip flat: the render carries ±3 levels of noise in the disc, and mapping it
# through an unclipped ramp turned that noise into visible grain once the disc
# was inverted to near-white.
L_LO, L_HI = 40.0, 215.0

LUMA = np.array([0.2126, 0.7152, 0.0722])


def _load_source() -> np.ndarray:
    if not SOURCE.exists():
        sys.exit(f"missing source render: {SOURCE}")
    img = Image.open(SOURCE).convert("RGB")
    if img.width != img.height:
        print(f"note: source is {img.width}x{img.height}, not square", file=sys.stderr)
    return np.asarray(img).astype(np.float64)


def _matte(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Cut the ink off the card.

    Returns straight (un-premultiplied) colour and alpha. Alpha comes from
    distance to the card colour rather than from luminance, because a
    luminance key would make the saturated fan translucent — #FF7A2E is a long
    way from white but its blue channel is dark.
    """
    distance = np.abs(rgb - CARD).max(axis=2)
    alpha = np.clip((distance - ALPHA_FLOOR) / (ALPHA_CEIL - ALPHA_FLOOR), 0.0, 1.0)

    # C = F*a + card*(1-a)  ->  F = (C - card*(1-a)) / a
    a3 = alpha[..., None]
    safe = np.maximum(a3, 1e-4)
    straight = np.clip((rgb - CARD * (1.0 - a3)) / safe, 0.0, 255.0)
    straight = np.where(a3 > 1e-4, straight, CARD)
    return straight, alpha


def _mark_bounds(rgb: np.ndarray) -> tuple[int, int, int, int]:
    """Find the disc stack, ignoring the wordmark below it.

    The card holds two separate blocks of ink separated by a band of blank
    rows. The mark is the taller of them — picked by height rather than by
    being first, so a re-export that moves the wordmark above the mark still
    resolves correctly.
    """
    inked = np.abs(rgb - CARD).max(axis=2) > INK_FLOOR
    rows = inked.any(axis=1)

    runs: list[tuple[int, int]] = []
    start: int | None = None
    for y, filled in enumerate(rows):
        if filled and start is None:
            start = y
        elif not filled and start is not None:
            runs.append((start, y))
            start = None
    if start is not None:
        runs.append((start, len(rows)))
    if not runs:
        sys.exit("found no ink in the source render")

    y0, y1 = max(runs, key=lambda r: r[1] - r[0])
    cols = np.nonzero(inked[y0:y1].any(axis=0))[0]
    x0, x1 = int(cols[0]), int(cols[-1]) + 1
    print(f"  ink blocks (rows): {runs}  ->  mark is {y0}-{y1}")

    height, width = inked.shape
    return (
        max(0, x0 - INK_PAD),
        max(0, y0 - INK_PAD),
        min(width, x1 + INK_PAD),
        min(height, y1 + INK_PAD),
    )


def _invert_neutrals(rgb: np.ndarray) -> np.ndarray:
    """Flip the black disc to near-white and the play triangle to near-black.

    Applied by how neutral a pixel is rather than by a threshold, so the
    anti-aliased boundary between the disc and the triangle stays smooth and
    the colour fan — which is saturated everywhere — comes through untouched.
    """
    saturation = rgb.max(axis=2) - rgb.min(axis=2)
    neutrality = np.clip(
        (NEUTRAL_SAT_NONE - saturation) / (NEUTRAL_SAT_NONE - NEUTRAL_SAT_FULL), 0.0, 1.0
    )[..., None]

    luma = rgb @ LUMA
    t = np.clip((luma - L_LO) / (L_HI - L_LO), 0.0, 1.0)[..., None]
    inverted = INK_LIGHT + (INK_DARK - INK_LIGHT) * t

    return rgb * (1.0 - neutrality) + inverted * neutrality


def _fill_knockouts(rgb: np.ndarray, alpha: np.ndarray):
    """Back the play triangle with opaque ink instead of leaving it a hole.

    The triangle is drawn in the same white as the card, so the matte reads it
    as background and punches it clean through the disc. On the light variant
    that is invisible — it flattens back onto white. On the transparent
    variants it is a real hazard: the triangle would show whatever is behind
    the icon, and the disc it sits in is near-white, so anywhere iOS draws the
    dark artwork without its dark backdrop the play button disappears
    completely.

    Interior holes are found by flooding the background in from the border:
    transparent pixels the flood cannot reach are enclosed by ink.
    """
    solid = alpha > 0.5
    if solid[0, 0]:
        sys.exit("mark touches the crop corner — flood fill has nowhere to start")

    # .copy() is load bearing. Image.fromarray wraps the numpy buffer read-only,
    # and floodfill writes through image.load(), so without it the fill silently
    # does nothing, every background pixel looks enclosed, and the mark gets a
    # black box painted behind it.
    flood = Image.fromarray(np.where(solid, 0, 255).astype(np.uint8), "L").copy()
    ImageDraw.floodfill(flood, (0, 0), 128)
    flooded = np.asarray(flood)
    if flooded[0, 0] != 128:
        sys.exit("flood fill did not run — cannot tell knockouts from background")

    enclosed = (flooded == 255) & ~solid
    if not enclosed.any():
        print("  no enclosed knockouts found")
        return rgb, alpha

    print(f"  backed {int(enclosed.sum())} knockout px with ink")
    out_rgb = np.where(enclosed[..., None], INK_DARK, rgb)
    out_alpha = np.where(enclosed, 1.0, alpha)
    return out_rgb, out_alpha


def _report_saturation(rgb: np.ndarray, alpha: np.ndarray) -> None:
    """Print the neutral/colour split the inversion thresholds depend on."""
    sat = (rgb.max(axis=2) - rgb.min(axis=2))[alpha > 0.9]
    if sat.size == 0:
        return
    counts, edges = np.histogram(sat, bins=[0, 22, 50, 100, 150, 256])
    bands = " ".join(
        f"{int(edges[i])}-{int(edges[i + 1])}:{c}" for i, c in enumerate(counts)
    )
    print(f"  saturation of opaque px  {bands}")
    if counts[1] > counts[0] * 0.05:
        print(
            f"  WARNING: {counts[1]} px sit between the neutral thresholds "
            f"({NEUTRAL_SAT_FULL:.0f}-{NEUTRAL_SAT_NONE:.0f}) — inversion will be muddy"
        )


def _resize_matte(rgb: np.ndarray, alpha: np.ndarray, width: int, height: int):
    """Resample in premultiplied space.

    Resizing straight-alpha RGBA blends the colour of fully transparent pixels
    into the edge, which here is the card's white — a white fringe around every
    disc, invisible on the light variant and obvious on the dark one.
    """
    premul = np.clip(rgb * alpha[..., None], 0, 255).astype(np.uint8)
    packed = np.dstack([premul, np.clip(alpha * 255.0, 0, 255).astype(np.uint8)])

    resized = np.asarray(
        Image.fromarray(packed, "RGBA").resize((width, height), Image.LANCZOS)
    ).astype(np.float64)

    out_alpha = np.clip(resized[..., 3] / 255.0, 0.0, 1.0)
    a3 = np.maximum(out_alpha[..., None], 1e-4)
    out_rgb = np.clip(resized[..., :3] / a3, 0.0, 255.0)
    return out_rgb, out_alpha


def _place(rgb: np.ndarray, alpha: np.ndarray, announce: bool = False):
    """Scale the mark to the tile and centre it on a transparent canvas."""
    src_h, src_w = alpha.shape
    width = round(CANVAS * MARK_WIDTH_FRACTION)
    height = round(width * src_h / src_w)
    if height > CANVAS * MARK_WIDTH_FRACTION:  # a taller-than-wide mark
        height = round(CANVAS * MARK_WIDTH_FRACTION)
        width = round(height * src_w / src_h)

    small_rgb, small_alpha = _resize_matte(rgb, alpha, width, height)

    canvas_rgb = np.zeros((CANVAS, CANVAS, 3))
    canvas_alpha = np.zeros((CANVAS, CANVAS))
    x = (CANVAS - width) // 2
    y = (CANVAS - height) // 2
    canvas_rgb[y : y + height, x : x + width] = small_rgb
    canvas_alpha[y : y + height, x : x + width] = small_alpha
    if announce:
        print(f"  mark placed at {width}x{height}, inset {x}px / {y}px")
    return canvas_rgb, canvas_alpha


def _flatten(rgb: np.ndarray, alpha: np.ndarray, background) -> Image.Image:
    a3 = alpha[..., None]
    out = rgb * a3 + np.asarray(background, dtype=np.float64) * (1.0 - a3)
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGB")


def _rgba(rgb: np.ndarray, alpha: np.ndarray) -> Image.Image:
    packed = np.dstack(
        [
            np.clip(rgb, 0, 255).astype(np.uint8),
            np.clip(alpha * 255.0, 0, 255).astype(np.uint8),
        ]
    )
    return Image.fromarray(packed, "RGBA")


def _write_contents() -> None:
    contents = {
        "images": [
            {
                "filename": "AppIcon-light.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            },
            {
                "appearances": [{"appearance": "luminosity", "value": "dark"}],
                "filename": "AppIcon-dark.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            },
            {
                "appearances": [{"appearance": "luminosity", "value": "tinted"}],
                "filename": "AppIcon-tinted.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            },
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (ICONSET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def _write_previews(light: Image.Image, dark: Image.Image, tinted: Image.Image) -> None:
    """Render the icons under the iOS mask, at tile size, for eyeballing.

    An unmasked 1024 square hides exactly the mistakes that matter — corner
    crowding and how small the mark reads on a home screen.
    """
    tile = 180
    radius = round(tile * 0.2237)
    mask = Image.new("L", (tile * 4, tile * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, tile * 4 - 1, tile * 4 - 1), radius=radius * 4, fill=255
    )
    mask = mask.resize((tile, tile), Image.LANCZOS)

    backdrops = {
        "light": (232, 232, 236),
        "dark": (28, 28, 32),
        "tinted": (28, 28, 32),
    }
    sheet = Image.new("RGB", (tile * 3 + 80, tile + 40), (120, 120, 128))
    for i, (name, icon) in enumerate([("light", light), ("dark", dark), ("tinted", tinted)]):
        scaled = icon.convert("RGBA").resize((tile, tile), Image.LANCZOS)
        plate = Image.new("RGB", (tile, tile), backdrops[name])
        plate.paste(scaled, (0, 0), scaled.split()[3])
        rounded = Image.new("RGBA", (tile, tile), (0, 0, 0, 0))
        rounded.paste(plate, (0, 0), mask)
        sheet.paste(rounded, (20 + i * (tile + 20), 20), rounded)

    sheet.save(PREVIEW_DIR / "app-icon-preview.png")
    print(f"  wrote {PREVIEW_DIR / 'app-icon-preview.png'}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--preview",
        action="store_true",
        help="also write docs/logo/app-icon-preview.png, masked at tile size",
    )
    args = parser.parse_args()

    print(f"source: {SOURCE.relative_to(ROOT)}")
    source = _load_source()
    straight, alpha = _matte(source)

    x0, y0, x1, y1 = _mark_bounds(source)
    mark_rgb = straight[y0:y1, x0:x1]
    mark_alpha = alpha[y0:y1, x0:x1]
    print(f"  mark cropped to {x1 - x0}x{y1 - y0} from ({x0}, {y0})")

    _report_saturation(mark_rgb, mark_alpha)

    # Light: the mark as drawn, flattened onto white. No alpha channel at all —
    # a primary app icon carrying alpha trips asset-catalog validation.
    light = _flatten(*_place(mark_rgb, mark_alpha, announce=True), (255, 255, 255))

    # Dark and tinted share one recoloured master. The order here is load
    # bearing: invert first, back the knockouts second. Backing them first
    # would paint the triangle in INK_DARK, and the inversion — which reads
    # that as an unsaturated dark neutral, exactly like the disc — would
    # promptly flip it back to near-white.
    inverted = _invert_neutrals(mark_rgb)
    inverted, inverted_alpha = _fill_knockouts(inverted, mark_alpha)

    dark = _rgba(*_place(inverted, inverted_alpha))

    # Tinted: the dark master's luminance. Built from the *inverted* artwork so
    # the disc is the bright, tint-carrying part and the play triangle punches
    # through it dark, rather than the other way round.
    grey = (inverted @ LUMA)[..., None].repeat(3, axis=2)
    tinted = _rgba(*_place(grey, inverted_alpha))

    ICONSET.mkdir(parents=True, exist_ok=True)
    for name, image in [("light", light), ("dark", dark), ("tinted", tinted)]:
        path = ICONSET / f"AppIcon-{name}.png"
        image.save(path, "PNG")
        print(f"  wrote {path.relative_to(ROOT)}  ({image.mode})")

    _write_contents()
    print(f"  wrote {(ICONSET / 'Contents.json').relative_to(ROOT)}")

    if args.preview:
        _write_previews(light, dark, tinted)


if __name__ == "__main__":
    main()
