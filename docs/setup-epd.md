# NRF_EPD_8042 dashboard / 蓝牙墨水屏复现

## Validated hardware / 已验证硬件

- advertised name: `NRF_EPD_8042`
- panel: 4.2-inch, 400 × 300 pixels
- colors: black, white, red
- detected controller: SSD1619-compatible three-color driver (`0x02`)
- transport: Bluetooth Low Energy

Other `NRF_EPD` boards may be discovered, but Codex Monitor refuses to transmit
unless the reported driver is one of the supported 4.2-inch three-color modes.

## Physical setup / 硬件准备

1. Power the assembled display according to its vendor documentation.
2. No GPIO or USB data cable is required by Codex Monitor; image data travels
   over BLE.
3. Keep the board awake and within normal Bluetooth range of the Mac.
4. Install and launch the macOS app, then grant Bluetooth permission.

The e-paper panel retains its last image without continuous refresh. The custom
bitmap does not run a clock on the display itself: date, weekday, and update time
are rendered by the Mac and remain unchanged until the next successful send.

## First verification / 首次验证

Open the macOS menu and find **E-paper display / 墨水屏**:

1. Click **Probe / 检测** for a read-only scan, connection, and driver query.
2. Confirm the name is `NRF_EPD_8042` and the driver description is a supported
   4.2-inch black/white/red mode.
3. Click **Sync now / 立即同步** if an immediate update is desired.

Probe and send connections are temporary. The menu may say that the device is
remembered while Bluetooth is disconnected; that is the expected low-power
idle state.

## Automatic policy / 自动同步策略

- Mac usage data refresh: every minute.
- EPD content check: once per hour.
- Date change: forces a check immediately after local midnight or Mac wake.
- Deduplication: SHA-256 of the rendered black/red frame after normalizing the
  volatile footer time.
- If unchanged: no BLE scan or connection.
- If changed: connect, upload both 15,000-byte planes, refresh, disconnect.
- Failure: disconnect and retry the entire BLE operation once.

With the legacy 20-byte BLE write size, a full non-RLE upload can take roughly
one to three minutes. Do not power-cycle the board during transfer.

## Confirmed protocol boundary / 已确认协议

- service UUID: `62750001-D828-918D-FB46-B6C11C675AEC`
- write/notify characteristic: `62750002-D828-918D-FB46-B6C11C675AEC`
- version characteristic: `62750003-D828-918D-FB46-B6C11C675AEC`
- initialize command: `0x01`
- refresh command: `0x05`
- image command: `0x30`
- frame planes: 400 × 300 ÷ 8 = 15,000 bytes each, MSB first

The adapter supports the legacy plane-control headers used by the tested board
and the newer header when the device explicitly reports RLE support. Packet
construction and orientation have deterministic verifier coverage.

## Renderer preview / 生成预览

Generate the exact one-bit frame reconstructed from transport planes:

```sh
./Scripts/render-epd-live-snapshot.sh
```

The output is `docs/images/epd-live-preview.png`. A Python reference renderer
is also available:

```sh
python3 -m venv .venv-epd
.venv-epd/bin/pip install -r Tools/EPD/requirements.txt
.venv-epd/bin/python Tools/EPD/render_preview.py
```

## Troubleshooting / 故障排查

- **No device found:** check power, distance, macOS Bluetooth permission, and
  that the advertising name contains `NRF_EPD`.
- **Device disconnected:** leave it powered, retry once, and avoid simultaneous
  connections from a browser controller.
- **Snow/noise:** verify the driver ID and plane protocol; do not send a frame
  intended for another panel type.
- **Mirrored/upside-down image:** use the checked-in orientation logic; changing
  byte order or adding a second flip will break the tested physical orientation.
- **Stale date:** the board has no autonomous clock for this bitmap. Keep Codex
  Monitor running so the cross-day/hourly policy can send a new frame.

