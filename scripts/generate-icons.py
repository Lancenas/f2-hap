#!/usr/bin/env python3
"""Generate F2H app icons for HarmonyOS HAP."""
import os
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError as e:
    raise SystemExit("Pillow is required: pip install Pillow") from e

BASE_DIR = Path(__file__).resolve().parent.parent
ASSETS_DIR = BASE_DIR / "assets"
RES_DIR = BASE_DIR / "entry" / "src" / "main" / "resources" / "base" / "media"

# Brand colors (consistent with macOS F2Downloader icon)
START_COLOR = (0x22, 0x6B, 0xF0)  # bright blue
END_COLOR = (0x4C, 0x4A, 0xF0)    # indigo

FONT_CANDIDATES = [
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/Avenir.ttc",
    "/System/Library/Fonts/ArialHB.ttc",
]


def find_font():
    """Find a usable bold system font."""
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return path
    return None


def make_gradient(size, radius_ratio=180 / 1024):
    """Create a rounded-rectangle gradient background."""
    width, height = size, size
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Gradient
    for y in range(height):
        ratio = y / height
        r = int(START_COLOR[0] + (END_COLOR[0] - START_COLOR[0]) * ratio)
        g = int(START_COLOR[1] + (END_COLOR[1] - START_COLOR[1]) * ratio)
        b = int(START_COLOR[2] + (END_COLOR[2] - START_COLOR[2]) * ratio)
        draw.line([(0, y), (width, y)], fill=(r, g, b, 255))

    # Mask to rounded rectangle
    radius = int(width * radius_ratio)
    mask = Image.new("L", (width, height), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle([0, 0, width, height], radius=radius, fill=255)
    img.putalpha(mask)
    return img


def draw_text_centered(img, text, font_path, font_size_ratio, y_ratio, font_index=1):
    """Draw bold text centered on image."""
    draw = ImageDraw.Draw(img)
    font_size = int(img.width * font_size_ratio)
    try:
        font = ImageFont.truetype(font_path, font_size, index=font_index)
    except (OSError, ValueError) as e:
        raise RuntimeError(f"Cannot load font {font_path} index={font_index}: {e}")

    bbox = draw.textbbox((0, 0), text, font=font)
    text_width = bbox[2] - bbox[0]
    text_height = bbox[3] - bbox[1]
    x = (img.width - text_width) / 2 - bbox[0]
    y = img.height * y_ratio - text_height / 2 - bbox[1]
    draw.text((x, y), text, font=font, fill=(255, 255, 255, 255))
    return img


def generate_full_icon(size, font_path, output_path):
    """App icon / startIcon: gradient background + F2H text."""
    img = make_gradient(size, radius_ratio=180 / 1024)
    draw_text_centered(img, "F2H", font_path, font_size_ratio=0.42, y_ratio=0.5, font_index=1)
    img.save(output_path, "PNG")
    print(f"Generated: {output_path}")


def generate_layered_background(size, output_path):
    """Layered icon background: just the gradient rounded rect."""
    img = make_gradient(size, radius_ratio=180 / 1024)
    img.save(output_path, "PNG")
    print(f"Generated: {output_path}")


def generate_layered_foreground(size, font_path, output_path):
    """Layered icon foreground: transparent bg + F2H text."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw_text_centered(img, "F2H", font_path, font_size_ratio=0.42, y_ratio=0.5, font_index=1)
    img.save(output_path, "PNG")
    print(f"Generated: {output_path}")


def generate_svg(output_path):
    """Save a source SVG for future edits."""
    svg = '''<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#226BF0"/>
      <stop offset="100%" style="stop-color:#4C4AF0"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="180" fill="url(#bg)"/>
  <text x="512" y="540" font-family="Helvetica, Arial, sans-serif"
        font-size="430" font-weight="bold" fill="white" text-anchor="middle">F2H</text>
</svg>
'''
    output_path.write_text(svg, encoding="utf-8")
    print(f"Generated: {output_path}")


def main():
    font_path = find_font()
    if not font_path:
        raise SystemExit("No suitable system font found for F2H icon.")
    print(f"Using font: {font_path}")

    ASSETS_DIR.mkdir(exist_ok=True)
    RES_DIR.mkdir(parents=True, exist_ok=True)

    generate_svg(ASSETS_DIR / "app-icon.svg")
    generate_full_icon(216, font_path, RES_DIR / "app_icon.png")
    generate_full_icon(216, font_path, RES_DIR / "startIcon.png")
    generate_layered_background(288, RES_DIR / "background.png")
    generate_layered_foreground(288, font_path, RES_DIR / "foreground.png")


if __name__ == "__main__":
    main()
