#!/usr/bin/env python3
"""SnapDark Tunnel — brand asset generator (Violet Pulse rebrand).

Regenerates every raster brand asset from ONE source (the supplied avatar
`app_logo.jpg`): launcher icons (legacy + adaptive foreground), the native
launch-splash lockup, and the in-app logo marks.

Brand rules (keep in sync with lib/theme/snapdark_tokens.dart):
  bg      #0B0913   near-black violet (launcher_background / native splash)
  accent  #7C3AED   violet
  light   #C084FC   electric lavender (wordmark accent)

Usage:  python3 tool/rebrand_assets.py [--source /path/to/logo.jpg]
Idempotent: overwrites the tracked PNGs in-place with the same dimensions.
"""

from __future__ import annotations

import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFont

# --- paths (run from app/ or pass --root) ----------------------------------
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
ASSETS = os.path.join(ROOT, "assets", "images")
DEFAULT_SOURCE = "/sdcard/Download/Telegram/app_logo.jpg"

# --- palette ---------------------------------------------------------------
BG = (11, 9, 19, 255)  # #0B0913 — near-black violet
ACCENT = (124, 58, 237, 255)  # #7C3AED
LAVENDER = (192, 132, 252, 255)  # #C084FC
WHITE = (255, 255, 255, 255)
INK = (22, 18, 31, 255)  # dark text for light-background logos

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

# Hue band remapped from blue → violet (degrees → PIL 0..255 scale).
H_LO = round(180 / 360 * 255)  # 128
H_HI = round(262 / 360 * 255)  # 184
H_SHIFT = round((262 - 225) / 360 * 255)  # +26 (~+37°)

# Adaptive-icon layout (108dp canvas units): tile occupies this fraction so it
# stays inside every launcher mask's safe zone (center 66%).
FG_TILE_FRAC = 0.64
# Legacy (API 24/25) PNGs are not masked — slightly fuller.
LEGACY_TILE_FRAC = 0.74
TILE_RADIUS_FRAC = 0.16


def violet_shift(im: Image.Image) -> Image.Image:
    """Rotate the blue band (180–262°) to violet while keeping skin/naturals."""
    rgba = im.convert("RGBA")
    hsv = rgba.convert("HSV")
    h, s, v = hsv.split()
    lut = list(range(256))
    for i in range(H_LO, H_HI + 1):
        lut[i] = min(255, i + H_SHIFT)
    orig_h = list(h.getdata())
    h = h.point(lut)
    # Nudge saturation up a touch inside the shifted band for a richer violet.
    # (Decide from the ORIGINAL hue of each pixel, before the rotation.)
    s_data = list(s.getdata())
    s = Image.new("L", s.size)
    s.putdata([min(255, int(val * 1.12)) if H_LO <= hh <= H_HI else val
               for hh, val in zip(orig_h, s_data)])
    out = Image.merge("HSV", (h, s, v)).convert("RGBA")
    out.putalpha(rgba.getchannel("A"))
    return out


def avatar_tile(src: Image.Image, size: int, radius_frac: float = TILE_RADIUS_FRAC) -> Image.Image:
    """Center-crop the square avatar to `size`, round the corners."""
    src = src.convert("RGB")
    w, h = src.size
    side = min(w, h)
    src = src.crop(((w - side) // 2, (h - side) // 2, (w - side) // 2 + side,
                    (h - side) // 2 + side)).resize((size, size), Image.LANCZOS)
    src = violet_shift(src).convert("RGBA")
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=int(size * radius_frac), fill=255)
    src.putalpha(mask)
    return src


def _paste_center(canvas: Image.Image, tile: Image.Image) -> None:
    x = (canvas.width - tile.width) // 2
    y = (canvas.height - tile.height) // 2
    canvas.alpha_composite(tile, (x, y))


def launcher_icon(src: Image.Image, size: int, tile_frac: float) -> Image.Image:
    """Full-bleed violet field + avatar tile (legacy icon / generic badge)."""
    canvas = Image.new("RGBA", (size, size), BG)
    tile = avatar_tile(src, int(size * tile_frac))
    _paste_center(canvas, tile)
    return canvas


def adaptive_foreground(src: Image.Image, size: int) -> Image.Image:
    """Transparent 108dp-canvas foreground layer (adaptive icon)."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tile = avatar_tile(src, int(size * FG_TILE_FRAC))
    _paste_center(canvas, tile)
    return canvas


def _tracked_text(draw: ImageDraw.ImageDraw, text: str, font, fill, cx: int,
                  top: int, tracking: float) -> int:
    """Draw uppercase text with letter-spacing centred on cx. Returns bottom y."""
    widths = [draw.textlength(ch, font=font) for ch in text]
    total = sum(widths) + tracking * (len(text) - 1)
    x = cx - total / 2
    for ch, w in zip(text, widths):
        draw.text((x, top), ch, font=font, fill=fill)
        x += w + tracking
    return top + draw.textbbox((x, top), "Ag", font=font)[3]


def lockup(src: Image.Image, size: int, dark_text: bool = False) -> Image.Image:
    """Brand lockup: avatar tile + ARMAN / TUNNEL wordmark (transparent bg).

    Mirrors the original shield + SENSEI/TUNNEL composition so the native and
    Flutter splash screens keep their layout at 200dp.
    """
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)

    tile_px = int(size * 0.52)
    tile = avatar_tile(src, tile_px)
    canvas.alpha_composite(tile, ((size - tile_px) // 2, int(size * 0.06)))

    name_col = INK if dark_text else WHITE
    sub_col = ACCENT if dark_text else LAVENDER

    f_name = ImageFont.truetype(FONT_BOLD, int(size * 0.155))
    f_sub = ImageFont.truetype(FONT_BOLD, int(size * 0.072))

    y = int(size * 0.63)
    d.text(((size - d.textlength("ARMAN", font=f_name)) / 2, y), "ARMAN",
           font=f_name, fill=name_col)
    y += int(size * 0.175)
    sub = "T U N N E L"
    w = d.textlength(sub, font=f_sub)
    d.text(((size - w) / 2, y), sub, font=f_sub, fill=sub_col)
    return canvas


def save(im: Image.Image, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im.save(path, "PNG")
    print(f"  ✓ {os.path.relpath(path, ROOT)}  {im.width}x{im.height}")


def existing_size(path: str, fallback: int) -> int:
    if os.path.exists(path):
        with Image.open(path) as im:
            return im.width
    return fallback


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", default=DEFAULT_SOURCE,
                    help="avatar source image (default: supplied app_logo.jpg)")
    args = ap.parse_args()

    if not os.path.exists(args.source):
        print(f"ERROR: source image not found: {args.source}", file=sys.stderr)
        return 1
    src = Image.open(args.source)
    print(f"Source: {args.source} ({src.width}x{src.height})")

    # 1. Launcher icons — legacy PNGs (mdpi..xxxhdpi) + adaptive foregrounds.
    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for name, scale in densities.items():
        legacy = int(48 * scale)
        fg = int(108 * scale)
        save(launcher_icon(src, legacy, LEGACY_TILE_FRAC),
             os.path.join(RES, f"mipmap-{name}", "ic_launcher.png"))
        save(adaptive_foreground(src, fg),
             os.path.join(RES, f"mipmap-{name}", "ic_launcher_foreground.png"))

    # 2. Native launch-splash lockup (per-density, dimensions preserved).
    for name in densities:
        path = os.path.join(RES, f"drawable-{name}", "snapdark_splash.png")
        size = existing_size(path, int(300 * densities[name] / 1.5))
        save(lockup(src, size), path)

    # 3. In-app assets (pubspec assets:) — dimensions preserved.
    save(lockup(src, existing_size(os.path.join(ASSETS, "snapdark_splash.png"), 600)),
         os.path.join(ASSETS, "snapdark_splash.png"))
    save(lockup(src, existing_size(os.path.join(ASSETS, "snapdark_logo.png"), 512)),
         os.path.join(ASSETS, "snapdark_logo.png"))
    save(avatar_tile(src, existing_size(os.path.join(ASSETS, "snapdark_mark.png"), 512)),
         os.path.join(ASSETS, "snapdark_mark.png"))

    # 4. Android drawable copies (unused by XML but shipped in the APK).
    drawable = os.path.join(RES, "drawable")
    save(lockup(src, existing_size(os.path.join(drawable, "snapdark_logo.png"), 512)),
         os.path.join(drawable, "snapdark_logo.png"))
    save(lockup(src, existing_size(os.path.join(drawable, "snapdark_logo_dark.png"), 512),
                dark_text=True),
         os.path.join(drawable, "snapdark_logo_dark.png"))
    save(avatar_tile(src, existing_size(os.path.join(drawable, "snapdark_mark.png"), 512)),
         os.path.join(drawable, "snapdark_mark.png"))

    print("\nDone. Re-run after logo changes; keep launcher_background (#0B0913) "
          "in sync with lib/theme/snapdark_tokens.dart.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
