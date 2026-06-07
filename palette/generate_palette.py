"""Generate a palette image from all images in a folder.

Example:
    python generate_palette.py ./images --output palette.png --colors 128
"""

from __future__ import annotations

import argparse
import math
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable, Iterator, Tuple

from PIL import Image, ImageDraw #pillow

RGB = Tuple[int, int, int]
SUPPORTED_EXTENSIONS = {".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp", ".tif", ".tiff"}


def find_images(folder: Path) -> Iterator[Path]:
    for path in folder.rglob("*"):
        if path.is_file() and path.suffix.lower() in SUPPORTED_EXTENSIONS:
            yield path


def extract_colors_from_image(
    image_path: Path,
    per_image_colors: int,
    sample_size: int,
) -> Counter[RGB]:
    with Image.open(image_path) as img:
        rgb = img.convert("RGB")

        # Resize for faster processing while preserving aspect ratio.
        rgb.thumbnail((sample_size, sample_size), Image.Resampling.LANCZOS)

        # Quantize to a limited set of representative colors.
        quantized = rgb.quantize(colors=per_image_colors, method=Image.Quantize.MEDIANCUT)
        reduced = quantized.convert("RGB")

        colors = reduced.getdata()
        return Counter(colors)


def aggregate_colors(
    image_paths: Iterable[Path],
    per_image_colors: int,
    sample_size: int,
) -> Counter[RGB]:
    total = Counter()
    for image_path in image_paths:
        try:
            total.update(extract_colors_from_image(image_path, per_image_colors, sample_size))
        except OSError:
            # Skip unreadable/corrupted files.
            continue
    return total


def merge_similar_colors(colors: Counter[RGB], threshold: int) -> Counter[RGB]:
    if threshold <= 1:
        return colors

    merged = Counter()
    buckets: dict[RGB, list[tuple[RGB, int]]] = defaultdict(list)

    for color, count in colors.items():
        bucket = tuple((channel // threshold) * threshold for channel in color)
        buckets[bucket].append((color, count))

    for bucket, entries in buckets.items():
        if len(entries) == 1:
            color, count = entries[0]
            merged[color] += count
            continue

        total_count = sum(count for _color, count in entries)
        red = sum(color[0] * count for color, count in entries) // total_count
        green = sum(color[1] * count for color, count in entries) // total_count
        blue = sum(color[2] * count for color, count in entries) // total_count
        merged[(red, green, blue)] += total_count

    return merged


def build_palette_image(
    colors: list[RGB],
    output_path: Path,
    swatch_size: int,
    columns: int,
) -> None:
    if not colors:
        raise ValueError("No colors were collected to build the palette image.")

    columns = max(1, columns)
    rows = math.ceil(len(colors) / columns)

    width = columns * swatch_size
    height = rows * swatch_size

    palette = Image.new("RGB", (width, height), (255, 255, 255))
    draw = ImageDraw.Draw(palette)

    for idx, color in enumerate(colors):
        col = idx % columns
        row = idx // columns
        x0 = col * swatch_size
        y0 = row * swatch_size
        x1 = x0 + swatch_size
        y1 = y0 + swatch_size
        draw.rectangle((x0, y0, x1, y1), fill=color)

    palette.save(output_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a palette image from a folder of images.")
    parser.add_argument("input_folder", type=Path, help="Folder containing images.")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("palette.png"),
        help="Output palette image path (default: palette.png).",
    )
    parser.add_argument(
        "--colors",
        type=int,
        default=256,
        help="How many colors to keep in final palette (default: 128).",
    )
    parser.add_argument(
        "--merge-similar-colors",
        action="store_true",
        help="Merge nearby colors before building the final palette.",
    )
    parser.add_argument(
        "--merge-threshold",
        type=int,
        default=16,
        help="Color bucket size used when merging similar colors (default: 16).",
    )
    parser.add_argument(
        "--per-image-colors",
        type=int,
        default=32,
        help="Max representative colors extracted per image (default: 32).",
    )
    parser.add_argument(
        "--sample-size",
        type=int,
        default=256,
        help="Max width/height used when sampling each image (default: 256).",
    )
    parser.add_argument(
        "--swatch-size",
        type=int,
        default=40,
        help="Pixel size of each color swatch (default: 40).",
    )
    parser.add_argument(
        "--columns",
        type=int,
        default=16,
        help="Number of columns in output palette (default: 16).",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    input_folder: Path = args.input_folder
    output: Path = args.output

    if not input_folder.exists() or not input_folder.is_dir():
        print(f"Error: input folder not found: {input_folder}")
        return 1

    image_paths = list(find_images(input_folder))
    if not image_paths:
        print("Error: no supported image files found in folder.")
        return 1

    color_counts = aggregate_colors(
        image_paths,
        per_image_colors=max(1, args.per_image_colors),
        sample_size=max(8, args.sample_size),
    )

    if args.merge_similar_colors:
        color_counts = merge_similar_colors(color_counts, max(2, args.merge_threshold))

    top_colors = [
        color
        for color, _count in color_counts.most_common(max(1, args.colors))
    ]

    if not top_colors:
        print("Error: unable to extract colors from provided images.")
        return 1

    build_palette_image(
        colors=top_colors,
        output_path=output,
        swatch_size=max(4, args.swatch_size),
        columns=max(1, args.columns),
    )

    print(f"Saved palette with {len(top_colors)} colors to: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
