#!/usr/bin/env python3
"""Generates the iOS/iPadOS and tvOS app icons from the Mac icon's artwork.

The Mac icon (Buffer/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png)
is a padded, shadowed rounded square, which iOS and tvOS must not receive:
they want full-bleed square art that the system masks. This script lifts the
TV glyph out of the Mac artwork and rebuilds:

- BufferMobile AppIcon: 1024 universal light, dark and tinted appearances;
- BufferTV "App Icon & Top Shelf Image": layered (Back/Middle/Front) Home
  Screen and App Store icons for parallax, plus Top Shelf and wide images.

    python3 scripts/make_app_icons.py
"""
import json
import pathlib

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Buffer/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"
TOP = (74, 225, 221)
BOTTOM = (43, 194, 190)
DARK_TOP = (16, 54, 58)
DARK_BOTTOM = (6, 24, 28)
# The glyph's extent inside the Mac squircle, which spans 100...924.
SQUIRCLE = (100, 100, 924, 924)
INFO = {"author": "xcode", "version": 1}


def gradient(size, top, bottom):
    width, height = size
    column = Image.new("RGB", (1, height))
    for y in range(height):
        t = y / max(1, height - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize(size)


def glyph():
    """The TV glyph with an alpha mask, cropped to the Mac squircle's box."""
    art = Image.open(SOURCE).convert("RGBA").crop(SQUIRCLE)
    red = art.getchannel("R")
    # Teal background has red <= ~80; the glyph and its glow are lighter.
    mask = red.point(lambda r: max(0, min(255, (r - 82) * 255 // 30)))
    # Keep the squircle's light rim out of the mask.
    inner = Image.new("L", art.size, 0)
    ImageDraw.Draw(inner).rounded_rectangle((40, 40, art.width - 40, art.height - 40), radius=150, fill=255)
    mask = ImageChops.multiply(mask, inner)
    art.putalpha(mask)
    return art


def place(canvas_size, layer, scale, offset=(0, 0)):
    canvas = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    size = (round(layer.width * scale), round(layer.height * scale))
    scaled = layer.resize(size, Image.LANCZOS)
    x = (canvas_size[0] - size[0]) // 2 + offset[0]
    y = (canvas_size[1] - size[1]) // 2 + offset[1]
    canvas.alpha_composite(scaled, (x, y))
    return canvas


def write_json(path, payload):
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps(payload, indent=2) + "\n")


def ios_icons(art):
    folder = ROOT / "BufferMobile/Assets.xcassets/AppIcon.appiconset"
    for stale in folder.glob("*.png"):
        stale.unlink()
    size = (1024, 1024)
    # The squircle maps to the full canvas, so the glyph keeps its proportion.
    scale = 1024 / art.width
    front = place(size, art, scale)
    light = gradient(size, TOP, BOTTOM).convert("RGBA")
    light.alpha_composite(front)
    light.convert("RGB").save(folder / "icon-light.png")
    # Dark: transparent background, so the system supplies its dark backdrop.
    front.save(folder / "icon-dark.png")
    # Tinted: grayscale luminance; the system applies the user's tint.
    gray = Image.new("RGBA", size, (0, 0, 0, 0))
    luminance = front.convert("L")
    gray.paste(Image.merge("RGBA", (luminance, luminance, luminance, front.getchannel("A"))))
    gray.save(folder / "icon-tinted.png")
    image = {"idiom": "universal", "platform": "ios", "size": "1024x1024"}
    write_json(folder, {"images": [
        {**image, "filename": "icon-light.png"},
        {**image, "filename": "icon-dark.png", "appearances": [{"appearance": "luminosity", "value": "dark"}]},
        {**image, "filename": "icon-tinted.png", "appearances": [{"appearance": "luminosity", "value": "tinted"}]},
    ], "info": INFO})


def tv_layers(size, art):
    """Back (gradient), Middle (soft glow) and Front (glyph) for one icon size."""
    width, height = size
    back = gradient(size, TOP, BOTTOM).convert("RGBA")
    # Leave tvOS's parallax safe margin: the glyph fits in ~60% of the height.
    scale = height * 0.62 / (art.height * 0.66)
    front = place(size, art, scale, (0, round(height * 0.02)))
    glow = front.getchannel("A").filter(ImageFilter.GaussianBlur(radius=max(2, height // 30)))
    middle = Image.new("RGBA", size, (255, 255, 255, 0))
    middle.putalpha(glow.point(lambda a: a * 90 // 255))
    return {"Back": back, "Middle": middle, "Front": front}


def image_stack(folder, sizes, art, idiom):
    layers = {}
    for scale, size in sizes:
        for name, image in tv_layers(size, art).items():
            layers.setdefault(name, []).append((scale, image))
    write_json(folder, {"info": INFO, "layers": [{"filename": f"{n}.imagestacklayer"} for n in ("Front", "Middle", "Back")]})
    for name, images in layers.items():
        layer = folder / f"{name}.imagestacklayer"
        write_json(layer, {"info": INFO})
        content = layer / "Content.imageset"
        entries = []
        for scale, image in images:
            filename = f"{name.lower()}@{scale}.png"
            content.mkdir(parents=True, exist_ok=True)
            (image.convert("RGB") if name == "Back" else image).save(content / filename)
            entries.append({"filename": filename, "idiom": idiom, "scale": scale})
        write_json(content, {"images": entries, "info": INFO})


def top_shelf(folder, sizes, art):
    entries = []
    for scale, (width, height) in sizes:
        canvas = gradient((width, height), DARK_TOP, DARK_BOTTOM).convert("RGBA")
        icon_height = round(height * 0.5)
        tile = Image.new("RGBA", (round(icon_height * 1.0), icon_height), (0, 0, 0, 0))
        tile_bg = gradient(tile.size, TOP, BOTTOM).convert("RGBA")
        rounded = Image.new("L", tile.size, 0)
        ImageDraw.Draw(rounded).rounded_rectangle((0, 0, *tile.size), radius=icon_height // 4, fill=255)
        tile.paste(tile_bg, (0, 0), rounded)
        tile.alpha_composite(place(tile.size, art, tile.height / art.height))
        x = round(width * 0.3) - tile.width // 2
        canvas.alpha_composite(tile, (x, (height - tile.height) // 2))
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", round(height * 0.2))
        draw = ImageDraw.Draw(canvas)
        draw.text((x + tile.width + round(height * 0.12), height // 2), "Buffer", font=font,
                  fill=(236, 252, 251), anchor="lm")
        filename = f"top-shelf@{scale}.png"
        folder.mkdir(parents=True, exist_ok=True)
        canvas.convert("RGB").save(folder / filename)
        entries.append({"filename": filename, "idiom": "tv", "scale": scale})
    write_json(folder, {"images": entries, "info": INFO})


def tv_icons(art):
    brand = ROOT / "BufferTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
    image_stack(brand / "App Icon.imagestack", [("1x", (400, 240)), ("2x", (800, 480))], art, "tv")
    image_stack(brand / "App Icon - App Store.imagestack", [("1x", (1280, 768))], art, "tv-marketing")
    top_shelf(brand / "Top Shelf Image.imageset", [("1x", (1920, 720)), ("2x", (3840, 1440))], art)
    top_shelf(brand / "Top Shelf Image Wide.imageset", [("1x", (2320, 720)), ("2x", (4640, 1440))], art)
    write_json(brand, {"assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ], "info": INFO})


if __name__ == "__main__":
    art = glyph()
    ios_icons(art)
    tv_icons(art)
    print("icons written")
