#!/usr/bin/env python3
"""Render the approved 400x300 black/white/red Codex Monitor EPD page."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


WIDTH = 400
HEIGHT = 300
WHITE = (255, 255, 255)
BLACK = (18, 18, 18)
RED = (190, 38, 35)
CHINESE_FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
NUMBER_FONT = "/System/Library/Fonts/HelveticaNeue.ttc"


def font(size: int, *, numbers: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(NUMBER_FONT if numbers else CHINESE_FONT, size=size)


def text_center(
    draw: ImageDraw.ImageDraw,
    center_x: float,
    y: float,
    value: str,
    value_font: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int] = BLACK,
) -> None:
    box = draw.textbbox((0, 0), value, font=value_font)
    draw.text((center_x - (box[2] - box[0]) / 2, y), value, font=value_font, fill=fill)


def text_right(
    draw: ImageDraw.ImageDraw,
    right_x: float,
    y: float,
    value: str,
    value_font: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int] = BLACK,
) -> None:
    box = draw.textbbox((0, 0), value, font=value_font)
    draw.text((right_x - (box[2] - box[0]), y), value, font=value_font, fill=fill)


def compact_tokens(tokens: int) -> str:
    if tokens >= 1_000_000:
        return f"{tokens / 1_000_000:.1f}M"
    if tokens >= 1_000:
        return f"{tokens / 1_000:.0f}K"
    return str(tokens)


def nearest_palette_color(pixel: tuple[int, int, int]) -> tuple[int, int, int]:
    red, green, blue = pixel
    # Preserve only pixels that originated from red artwork. A generic nearest
    # color match can otherwise turn neutral gray text antialiasing into red.
    if red - green > 18 and red - blue > 18:
        return RED
    luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
    return BLACK if luminance < 180 else WHITE


def enforce_three_colors(image: Image.Image) -> Image.Image:
    quantized = Image.new("RGB", image.size, WHITE)
    source = image.load()
    quantized.putdata(
        [
            nearest_palette_color(source[x, y])
            for y in range(image.height)
            for x in range(image.width)
        ]
    )
    return quantized


def pack_plane(image: Image.Image, active_color: tuple[int, int, int]) -> bytes:
    pixels = image.load()
    payload = bytearray()
    for y in range(HEIGHT):
        for start_x in range(0, WIDTH, 8):
            value = 0
            for bit in range(8):
                # The reference firmware expects white=1 and active color=0.
                if pixels[start_x + bit, y] != active_color:
                    value |= 1 << (7 - bit)
            payload.append(value)
    return bytes(payload)


def render(now: datetime) -> Image.Image:
    image = Image.new("RGB", (WIDTH, HEIGHT), WHITE)
    draw = ImageDraw.Draw(image)

    # Header: keep static identity on the left and date metadata on the right.
    # A large clock would become stale unless the full custom bitmap were sent
    # every minute, so it is intentionally omitted.
    draw.text((12, 8), "CODEX MONITOR", font=font(18, numbers=True), fill=RED)
    weekday_name = ("MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY")[
        now.weekday()
    ]
    text_right(draw, 389, 3, now.strftime("%Y.%m.%d"), font(13, numbers=True), BLACK)
    text_right(draw, 389, 20, weekday_name, font(14, numbers=True), RED)
    draw.line((11, 44, 389, 44), fill=BLACK, width=2)

    # Monday-to-Sunday strip. Keep today's text on white: thin reversed text
    # loses too much detail on the physical three-color panel.
    week_start = now - timedelta(days=now.weekday())
    labels = ("MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN")
    left = 11
    right = 389
    top = 51
    bottom = 88
    cell_width = (right - left + 1) / 7
    for index, label in enumerate(labels):
        day = week_start + timedelta(days=index)
        x1 = round(left + index * cell_width)
        x2 = round(left + (index + 1) * cell_width) - 1
        is_today = day.date() == now.date()
        is_weekend = index >= 5
        draw.rectangle(
            (x1, top, x2, bottom),
            outline=RED if is_today else BLACK,
            width=3 if is_today else 1,
        )
        label_color = RED if is_today or is_weekend else BLACK
        number_color = BLACK if is_today else (RED if is_weekend else BLACK)
        text_center(draw, (x1 + x2) / 2, top + 4, label, font(9), label_color)
        text_center(
            draw,
            (x1 + x2) / 2,
            top + 13,
            str(day.day),
            font(20, numbers=True),
            number_color,
        )

    # Lower left: the large-widget quota block.
    divider_x = 202
    draw.line((divider_x, 106, divider_x, 266), fill=BLACK, width=1)
    draw.text((12, 108), "本周额度", font=font(14), fill=RED)
    draw.text((12, 124), "90", font=font(56, numbers=True), fill=BLACK)
    draw.text((84, 157), "%", font=font(18, numbers=True), fill=BLACK)

    bar_left = 12
    bar_right = 189
    bar_top = 185
    draw.rectangle((bar_left, bar_top, bar_right, bar_top + 10), outline=BLACK, width=1)
    fill_width = round((bar_right - bar_left - 3) * 0.90)
    draw.rectangle(
        (bar_left + 2, bar_top + 2, bar_left + 2 + fill_width, bar_top + 8),
        fill=RED,
    )
    draw.text((12, 203), "本周已用", font=font(10), fill=BLACK)
    text_right(draw, 189, 201, "10%", font(13, numbers=True), BLACK)
    draw.text((12, 224), "下次重置", font=font(10), fill=BLACK)
    text_right(draw, 189, 222, "09-01 08:00", font(12, numbers=True), BLACK)
    draw.line((12, 246, 189, 246), fill=BLACK, width=1)
    draw.text((12, 252), "累计 Token", font=font(10), fill=BLACK)
    text_right(draw, 189, 248, "32.8M", font(17, numbers=True), RED)

    # Lower right: seven independent daily token values, never cumulative.
    chart_left = 231
    chart_right = 381
    chart_top = 139
    chart_bottom = 228
    token_values = [420_000, 760_000, 510_000, 1_240_000, 900_000, 1_520_000, 680_000]
    draw.text((214, 108), "近 7 日 TOKEN", font=font(14), fill=RED)
    text_right(draw, chart_right, 112, "今日 680K", font(10), BLACK)

    maximum = ((max(token_values) + 199_999) // 200_000) * 200_000
    for fraction in (0.0, 0.5, 1.0):
        y = round(chart_bottom - fraction * (chart_bottom - chart_top))
        draw.line((chart_left, y, chart_right, y), fill=BLACK, width=1)
        label = compact_tokens(round(maximum * fraction))
        text_right(draw, chart_left - 5, y - 5, label, font(8, numbers=True), BLACK)
    points: list[tuple[int, int]] = []
    for index, tokens in enumerate(token_values):
        x = round(chart_left + index * (chart_right - chart_left) / 6)
        y = round(chart_bottom - tokens / maximum * (chart_bottom - chart_top))
        points.append((x, y))
    draw.line(points, fill=RED, width=3, joint="curve")
    for x, y in points:
        draw.ellipse((x - 3, y - 3, x + 3, y + 3), fill=RED)

    for index, _ in enumerate(token_values):
        x = round(chart_left + index * (chart_right - chart_left) / 6)
        text_center(draw, x, 234, labels[index], font(10), RED if index >= 5 else BLACK)

    # Footer doubles as the future sync/transport status area.
    draw.line((11, 270, 389, 270), fill=BLACK, width=2)
    draw.text((12, 276), "更新 10:32 · 按需同步", font=font(10), fill=BLACK)
    text_right(draw, 389, 276, "本地预览 · BLE 待接入", font(10), RED)

    return enforce_three_colors(image)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("docs/images/epd-v1-preview.png"),
    )
    parser.add_argument(
        "--planes-dir",
        type=Path,
        default=Path(".build/epd-preview"),
    )
    args = parser.parse_args()

    preview = render(datetime(2026, 8, 28, 10, 32))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    preview.save(args.output)

    args.planes_dir.mkdir(parents=True, exist_ok=True)
    black_payload = pack_plane(preview, BLACK)
    red_payload = pack_plane(preview, RED)
    (args.planes_dir / "epd-v1-black.bin").write_bytes(black_payload)
    (args.planes_dir / "epd-v1-red.bin").write_bytes(red_payload)
    if len(black_payload) != 15_000 or len(red_payload) != 15_000:
        raise RuntimeError("A 400x300 1-bit plane must contain exactly 15,000 bytes")

    print(f"Rendered {args.output} ({WIDTH}x{HEIGHT}, black/white/red only)")
    print(f"Packed planes: {len(black_payload)} bytes x 2")


if __name__ == "__main__":
    main()
