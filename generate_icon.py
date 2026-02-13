#!/usr/bin/env python3
"""Generate 计数工具 app icon."""
import os
import shutil
import subprocess
from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
CORNER = int(SIZE * 0.22)


def rounded_rect_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def make_gradient(size):
    """Teal-to-blue vertical gradient."""
    img = Image.new("RGB", (size, size))
    for y in range(size):
        t = y / size
        r = int(46 * (1 - t) + 59 * t)
        g = int(204 * (1 - t) + 130 * t)
        b = int(193 * (1 - t) + 246 * t)
        for x in range(size):
            img.putpixel((x, y), (r, g, b))
    return img


def find_font(bold=True):
    """Find a usable system font."""
    candidates = [
        "/System/Library/Fonts/SFNSRounded.ttf",
        "/System/Library/Fonts/SFNS.ttf",
        "/Library/Fonts/SF-Pro-Rounded-Bold.otf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/HelveticaNeue.ttc",
    ]
    for path in candidates:
        if os.path.exists(path):
            return path
    return None


def generate_icon():
    bg = make_gradient(SIZE)
    mask = rounded_rect_mask(SIZE, CORNER)
    result = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    result.paste(bg, mask=mask)

    draw = ImageDraw.Draw(result)
    white = (255, 255, 255)
    white_dim = (255, 255, 255, 140)
    cx, cy = SIZE // 2, SIZE // 2

    font_path = find_font()

    # Draw "+1" as the main icon element
    try:
        font_big = ImageFont.truetype(font_path, int(SIZE * 0.42)) if font_path else ImageFont.load_default()
    except Exception:
        font_big = ImageFont.load_default()

    # Draw the "+1" text centered
    text = "+1"
    bbox = draw.textbbox((0, 0), text, font=font_big)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    tx = cx - tw // 2 - bbox[0]
    ty = cy - th // 2 - bbox[1] - int(SIZE * 0.02)
    draw.text((tx, ty), text, fill=white, font=font_big)

    # Draw three small tally dots below for visual flair
    dot_r = int(SIZE * 0.022)
    dot_y = cy + int(SIZE * 0.26)
    dot_spacing = int(SIZE * 0.07)
    for i in range(3):
        dx = cx + (i - 1) * dot_spacing
        draw.ellipse(
            [dx - dot_r, dot_y - dot_r, dx + dot_r, dot_y + dot_r],
            fill=white_dim
        )

    # Subtle inner glow
    for i in range(8):
        alpha = int(25 * (1 - i / 8))
        overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        od = ImageDraw.Draw(overlay)
        od.rounded_rectangle(
            [i, i, SIZE - 1 - i, SIZE - 1 - i],
            radius=max(1, CORNER - i), outline=(255, 255, 255, alpha)
        )
        result = Image.alpha_composite(result, overlay)

    return result


def create_iconset(icon):
    iconset_dir = "AppIcon.iconset"
    os.makedirs(iconset_dir, exist_ok=True)

    for s in [16, 32, 128, 256, 512]:
        icon.resize((s, s), Image.LANCZOS).save(os.path.join(iconset_dir, f"icon_{s}x{s}.png"))
        icon.resize((s * 2, s * 2), Image.LANCZOS).save(os.path.join(iconset_dir, f"icon_{s}x{s}@2x.png"))

    subprocess.run(["iconutil", "-c", "icns", iconset_dir], check=True)
    print("Created AppIcon.icns")
    shutil.rmtree(iconset_dir)


if __name__ == "__main__":
    icon = generate_icon()
    icon.save("AppIcon_1024.png")
    print("Saved AppIcon_1024.png (preview)")
    create_iconset(icon)
