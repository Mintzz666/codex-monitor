# Codex Monitor · 4.2-inch EPD page V1

This page targets a landscape 400 × 300 black/white/red electronic-paper
display. It is intentionally independent from any particular Bluetooth service
or firmware so the visual layout can be approved before the physical device is
available.

## Information hierarchy

1. Header: a compact Codex Monitor identity on the left, with the date and a
   larger full English weekday right-aligned. No live clock is shown because
   this custom bitmap is updated on demand rather than every minute.
2. Compact week strip: Monday through Sunday; today uses a three-pixel red
   outline, red weekday text, and a black date on white. Weekends use red type.
3. Quota panel: one concise weekly-quota heading, a separated large remaining
   percentage, horizontal progress bar, weekly
   used percentage, reset time, and lifetime tokens.
4. Token panel: seven independent daily token values as a red line chart. The
   points are daily values and are never cumulative. A compact K/M axis and
   weekday labels replace a row of tiny per-point numbers. The plot is inset
   from both the center divider and outer border with balanced margins.
5. Footer: slightly enlarged last-update time and low-power Bluetooth
   synchronization state. A live frame says `自动同步 · BLE 低功耗`.

## Live-data behavior

The app no longer transmits the bundled approval image after the panel has
been validated. Menu data continues to refresh once per minute, independently
from the display. The EPD performs a low-power check once per hour and once
immediately after the local date changes. It normalizes the volatile footer
time before hashing the rendered frame, skips BLE entirely when the visible
content is unchanged, and otherwise scans/connects, sends, then disconnects.
Manual `立即同步` uses the same short-lived connection path. A failed connect
or write is retried once.

## Typography

Small Latin text and numerals use a fixed 5×7 pixel grid with integer scaling,
following the established monochrome-display approach used by U8g2,
Adafruit GFX, GxEPD2, and Waveshare examples. This keeps every `0`, weekday,
date, and chart label on an identical pixel baseline. Calendar weekdays render
at 2× and dates at 3×. Chinese copy and the large quota value still use macOS
fonts, but they are grayscale-antialiased first and then thresholded into the
final one-bit black or red plane. The percent sign uses this latter path because
it is too cramped and ambiguous in a 5×7 cell.

The generated documentation preview is reconstructed from the final transport
planes, so it shows the exact binary glyphs rather than the pre-threshold vector
canvas.

Small Chinese labels use Hiragino Sans GB, which survived the one-bit threshold
more cleanly on the physical panel than PingFang at the same size. The chart
weekday row is offset three pixels below the baseline to keep it clear of the
zero-axis line.

## E-paper constraints

- Canvas: exactly 400 × 300 pixels.
- Palette: pure white, near-black, and one red accent only.
- Output: one 1-bit black plane and one 1-bit red plane.
- Plane size: `400 × 300 ÷ 8 = 15,000` bytes each, MSB first.
- Red is reserved for hierarchy and state; it is not used as a large
  background, which avoids slow, visually heavy full-area red refreshes.
- The page does not require partial refresh. Stable rendered-content hashing
  skips a write when only the update timestamp or no visible data has changed.

## Confirmed NRF_EPD Bluetooth boundary

The purchased device is labeled `NRF_EPD_8042`, and the seller's manual points
to the public EPD-nRF5 Web Bluetooth controller. The renderer still produces
two firmware-neutral byte planes, while
`Sources/CodexUsageShared/NRFEPDBluetoothTransport.swift` now adapts them to the
confirmed protocol:

- Service: `62750001-D828-918D-FB46-B6C11C675AEC`
- Image write and notification characteristic:
  `62750002-D828-918D-FB46-B6C11C675AEC`
- Firmware version characteristic:
  `62750003-D828-918D-FB46-B6C11C675AEC`
- Upload order: init (`0x01`), black plane (`0x30`), red plane (`0x30`),
  refresh (`0x05`).
- The `NRF_EPD_8042` vendor controller linked by its manual uses legacy image
  headers (`0x0F/0xFF` for black and `0x00/0xF0` for red), a 20-byte fallback,
  a 50 ms delay after every write, and one acknowledged packet after every 50
  unacknowledged packets. Modern headers are enabled only when the device
  explicitly reports `rle=1`.
- The installed panel scans vertically opposite to the approved preview, so
  the adapter flips rows while preserving the left-to-right pixel order.

The `8042` suffix identifies the unit, not its panel driver. The adapter reads
the actual driver ID after connecting; the expected three-color IDs are
`0x02` (SSD1619) or `0x03` (UC8176).

## Rebuild the preview

```zsh
python3 -m venv .venv-epd
.venv-epd/bin/pip install -r Tools/EPD/requirements.txt
.venv-epd/bin/python Tools/EPD/render_preview.py
```

The preview is written to `docs/images/epd-v1-preview.png`; packed test planes
are written under `.build/epd-preview/`.
