#!/usr/bin/env python3
"""Read-only NRF_EPD BLE connection probe using Bleak.

This is intentionally independent of the macOS app's CoreBluetooth adapter.
It scans, connects, enumerates GATT services, and disconnects without writing
commands or image data.
"""

from __future__ import annotations

import argparse
import asyncio
import sys

from bleak import BleakClient, BleakScanner


EPD_SERVICE_UUID = "62750001-d828-918d-fb46-b6c11c675aec"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default="NRF_EPD_8042")
    parser.add_argument("--scan-timeout", type=float, default=12.0)
    parser.add_argument("--connect-timeout", type=float, default=20.0)
    return parser.parse_args()


async def probe(args: argparse.Namespace) -> int:
    print(f"Scanning for {args.name}…", flush=True)
    discovered = await BleakScanner.discover(
        timeout=args.scan_timeout,
        return_adv=True,
    )
    candidates = []
    for device, advertisement in discovered.values():
        name = advertisement.local_name or device.name or "Unnamed BLE device"
        service_uuids = {value.lower() for value in advertisement.service_uuids}
        if args.name.casefold() in name.casefold() or EPD_SERVICE_UUID in service_uuids:
            candidates.append((device, advertisement, name))

    if not candidates:
        print("No compatible NRF_EPD device found", flush=True)
        return 2

    candidates.sort(key=lambda item: item[1].rssi, reverse=True)
    for _, advertisement, name in candidates:
        print(f"Found {name}: {advertisement.rssi} dBm", flush=True)

    device, _, name = candidates[0]
    print(f"Connecting to {name}…", flush=True)
    try:
        async with BleakClient(device, timeout=args.connect_timeout) as client:
            print(f"Connected: {client.is_connected}", flush=True)
            for service in client.services:
                print(f"Service {service.uuid}", flush=True)
                for characteristic in service.characteristics:
                    properties = ",".join(characteristic.properties)
                    print(
                        f"  Characteristic {characteristic.uuid} [{properties}]",
                        flush=True,
                    )
    except Exception as error:  # Diagnostic tool: preserve backend error type.
        print(f"Connection failed: {type(error).__name__}: {error}", flush=True)
        return 3
    return 0


def main() -> int:
    return asyncio.run(probe(parse_args()))


if __name__ == "__main__":
    sys.exit(main())
