#!/usr/bin/env python3
"""Key, split and pad the nano-banana character sheet into role sprites.

Gemini returns no alpha and the "pure green" backdrop comes back as *some*
green with a tinted edge, so the backdrop is taken as the median of the image
border and removed by a flood fill from the border — green accents inside a
cog (the green operator's own plating) are enclosed by its dark outline and
therefore survive. The keyed row is then split on empty columns, each part is
padded to a square and resized to 128 px.

    python3 scripts/art/split_cog_sheet.py

Owns (nano-banana renders, regenerate with generate_cog_sheet.py):
    data/cog_manager.png
    data/cog_worker_red.png  cog_worker_blue.png
    data/cog_worker_green.png  cog_worker_yellow.png

Does NOT own the coworld-ctf assets the starter shipped (arena_floor.png,
font.ttf, soldier_red_front.png).
"""

import collections
import os

from PIL import Image

SHEET = "scripts/art/source/cogs_sheet.png"
OUT_DIR = "data"
SIZE = 128
TOLERANCE = 70
GAP = 6  # minimum columns between two cuts

ROLES = [
    "cog_manager",
    "cog_worker_red",
    "cog_worker_blue",
    "cog_worker_green",
    "cog_worker_yellow",
]


def border_color(image):
    width, height = image.size
    pixels = image.load()
    counter = collections.Counter()
    for x in range(width):
        counter[pixels[x, 0][:3]] += 1
        counter[pixels[x, height - 1][:3]] += 1
    for y in range(height):
        counter[pixels[0, y][:3]] += 1
        counter[pixels[width - 1, y][:3]] += 1
    return counter.most_common(1)[0][0]


def key_out(image, key):
    """Flood fill the backdrop from every border pixel; returns RGBA."""
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()

    def near(color):
        return (
            (color[0] - key[0]) ** 2
            + (color[1] - key[1]) ** 2
            + (color[2] - key[2]) ** 2
        ) <= TOLERANCE * TOLERANCE

    seen = bytearray(width * height)
    stack = []
    for x in range(width):
        stack.append((x, 0))
        stack.append((x, height - 1))
    for y in range(height):
        stack.append((0, y))
        stack.append((width - 1, y))
    while stack:
        x, y = stack.pop()
        if x < 0 or y < 0 or x >= width or y >= height:
            continue
        index = y * width + x
        if seen[index]:
            continue
        if not near(pixels[x, y]):
            continue
        seen[index] = 1
        pixels[x, y] = (0, 0, 0, 0)
        stack.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return image


def column_weights(image):
    """Opaque pixels per column."""
    width, height = image.size
    pixels = image.load()
    return [
        sum(1 for y in range(height) if pixels[x, y][3] > 24)
        for x in range(width)
    ]


def split_columns(image, parts):
    """Column ranges for `parts` evenly-spaced characters.

    The characters stand shoulder to shoulder — a raised wrench reaches into
    the next cog's column and the ground shadows run together — so there is
    no fully empty column to cut on. Cut instead at the emptiest column
    inside a window around each expected boundary, which is the gap between
    two bodies wherever the render put it.
    """
    weights = column_weights(image)
    width = len(weights)
    inked = [x for x, weight in enumerate(weights) if weight > 0]
    if not inked:
        raise SystemExit("the sheet is empty after keying")
    left, right = inked[0], inked[-1] + 1
    pitch = (right - left) / parts
    cuts = [left]
    for index in range(1, parts):
        expected = left + pitch * index
        window = max(GAP, int(pitch * 0.30))
        low = max(cuts[-1] + GAP, int(expected - window))
        high = min(width - 1, int(expected + window))
        cuts.append(min(range(low, high + 1), key=lambda x: (weights[x], abs(x - expected))))
    cuts.append(right)
    return [(cuts[i], cuts[i + 1]) for i in range(parts)]


def square(image):
    bbox = image.getbbox()
    cropped = image.crop(bbox) if bbox else image
    side = max(cropped.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(
        cropped,
        ((side - cropped.size[0]) // 2, (side - cropped.size[1]) // 2),
    )
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main() -> None:
    sheet = Image.open(SHEET).convert("RGBA")
    keyed = key_out(sheet, border_color(sheet))
    runs = split_columns(keyed, len(ROLES))
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, (left, right) in zip(ROLES, runs):
        part = square(keyed.crop((left, 0, right, keyed.size[1])))
        path = os.path.join(OUT_DIR, f"{name}.png")
        part.save(path)
        print(f"{path}: {right - left}px wide on the sheet -> {SIZE}px")


if __name__ == "__main__":
    main()
