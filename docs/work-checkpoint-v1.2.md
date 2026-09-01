# Codex Monitor work checkpoint — V1.2

Checkpoint date: 2026-08-28

## Completed and approved

- macOS V1.1.0 Build 18: menu bar status, expanded menu, medium and large
  widgets, one-minute refresh, seven-day token chart, and launch at login.
- E-paper UI V1.1: approved 400 × 300 black/white/red layout with weekly
  calendar, time, quota summary, and daily usage chart.
- iPhone V1.2.0 Build 2: independent small WidgetKit widget installed on a
  physical iPhone.
- iPhone account data: OpenAI device-code authorization, weekly quota fetch,
  shared Keychain credential storage, App Group snapshot fallback, widget
  timeline refresh, and interactive refresh button.
- Safari authorization round-trip: temporary network interruption is retried
  without discarding a completed login.
- Apps Connect split routing: `openai.com`, `chatgpt.com`, and
  `oaistatic.com` use the proxy policy so global routing is unnecessary.

No account token, authorization code, device identifier, Apple Account,
certificate identifier, node address, or subscription URL is recorded here or
in source control.

## Preserved extension boundary

The hardware-neutral boundary is in
`Sources/CodexUsageShared/EPDTransport.swift`. The approved display design and
reference render are documented in `docs/epd-v1-design.md` and
`docs/images/epd-v1-preview.png`.

The renderer currently targets:

- 400 × 300 pixels
- three colors: black, white, and red
- two validated 1-bit color planes
- 15,000 bytes per plane

## Bluetooth display arrival update — 2026-08-30

The seller manual was reviewed and the physical unit is labeled
`NRF_EPD_8042`. The manual references the public EPD-nRF5 browser controller,
which confirmed the GATT UUIDs, command sequence, packet headers, MTU/RLE
notification format, and supported 4.2-inch driver IDs.

The macOS app now contains a native CoreBluetooth adapter and a read-only probe
panel. Bluetooth is initialized only after the user presses Probe. The first
probe scans for `NRF_EPD` devices, prefers the `8042` suffix, connects, enables
notifications, sends only the initialization request needed to read the
configuration, and reports the firmware, driver, MTU, and RLE capability. It
does not upload an image or alter the pin/driver configuration.

## Original hardware checklist

Do not redesign the approved page before testing it on the physical panel.
First collect or inspect the open control-side source and determine:

1. BLE service UUID and write/notify characteristic UUIDs.
2. Required pairing or authentication handshake.
3. Negotiated MTU, packet size, sequence numbering, acknowledgements, retry,
   and timeout behavior.
4. Frame orientation, row/column order, bit order, color-plane order, and any
   compression.
5. Commands for upload, display refresh, sleep, battery status, and mode
   switching.
6. Whether a full refresh and partial refresh are both supported.

The concrete transport and packet tests are now implemented. The remaining
sequence is to complete the physical read-only probe, send the existing V1.1
frame, compare orientation and colors on-device, and only then tune typography
or spacing for the real panel.

## Current release records

- `docs/release-notes/v1.1.0.md`
- `docs/release-notes/v1.2.0.md`
- `Mobile/README.md`

This checkpoint intentionally leaves the working tree intact. No `git stash`,
reset, or history-rewriting operation has been performed.
