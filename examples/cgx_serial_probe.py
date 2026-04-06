#!/usr/bin/env python3
"""CGX Quick-20r serial stream probe.

Empirically determine packet framing from the BLE dongle serial output.
CGX doesn't publish their protocol, so we reverse-engineer it:

1. Record raw bytes
2. Find repeating structure via autocorrelation
3. Identify sync patterns
4. Parse channels given known specs:
   - 20 EEG + 2 ExG = 22 channels
   - 24-bit ADC (3 bytes/channel)
   - 500 Hz sample rate
   - Expected packet: 22ch × 3B = 66B payload + header/footer
   - At 500 Hz × ~70B = 35,000 B/s theoretical
   - But observed 1,384 B/s → either BLE throttled or different mode

Usage:
    uv run --no-project --with pyserial --with numpy python3 cgx_serial_probe.py /dev/tty.usbserial-AI1B2OSR
"""

import argparse
import struct
import sys
import time

import numpy as np


def record_raw(port, baud=115200, duration=10):
    """Record raw bytes from serial port."""
    import serial
    ser = serial.Serial(port, baud, timeout=1)
    print(f"Recording from {port} @ {baud} for {duration}s...", file=sys.stderr)
    time.sleep(0.5)  # let buffer fill

    start = time.time()
    data = bytearray()
    while time.time() - start < duration:
        chunk = ser.read(4096)
        if chunk:
            data.extend(chunk)
    ser.close()

    rate = len(data) / duration
    print(f"Captured {len(data)} bytes ({rate:.0f} B/s)", file=sys.stderr)
    return bytes(data), rate


def byte_histogram(data):
    """Show byte value distribution."""
    counts = np.zeros(256, dtype=int)
    for b in data:
        counts[b] += 1

    # Find most common bytes (potential sync)
    top = np.argsort(counts)[::-1][:10]
    print("\nTop 10 byte values:", file=sys.stderr)
    for i, b in enumerate(top):
        pct = counts[b] / len(data) * 100
        print(f"  0x{b:02X} ({b:3d}): {counts[b]:5d} ({pct:.1f}%)", file=sys.stderr)

    # Check entropy
    probs = counts[counts > 0] / len(data)
    entropy = -np.sum(probs * np.log2(probs))
    print(f"\nEntropy: {entropy:.2f} bits (max 8.0, uniform ≈ 7.8+)", file=sys.stderr)

    return counts


def find_repeating_pattern(data, max_period=200):
    """Use autocorrelation to find packet length."""
    arr = np.frombuffer(data[:min(len(data), 10000)], dtype=np.uint8).astype(float)
    arr -= arr.mean()

    print("\nAutocorrelation peaks (potential packet sizes):", file=sys.stderr)
    correlations = []
    for lag in range(2, max_period):
        n = len(arr) - lag
        if n < 100:
            break
        corr = np.sum(arr[:n] * arr[lag:lag+n]) / (n * max(np.std(arr[:n]) * np.std(arr[lag:lag+n]), 1e-10))
        correlations.append((lag, corr))

    # Sort by correlation strength
    correlations.sort(key=lambda x: -x[1])
    for lag, corr in correlations[:15]:
        # Check if it divides the byte rate cleanly
        print(f"  period={lag:3d}B  corr={corr:.4f}", file=sys.stderr)

    return correlations


def try_sync_bytes(data, candidates=None):
    """Try to find sync byte patterns."""
    if candidates is None:
        candidates = [0xFF, 0xA0, 0xAA, 0x55, 0xFE, 0x00, 0xC0, 0x80]

    print("\nSync byte analysis:", file=sys.stderr)
    for sync in candidates:
        positions = [i for i in range(len(data)) if data[i] == sync]
        if len(positions) < 3:
            continue
        gaps = np.diff(positions)
        if len(gaps) < 2:
            continue

        # Look for consistent gaps (= packet size)
        mode_gap = int(np.median(gaps))
        consistent = np.sum(np.abs(gaps - mode_gap) <= 1) / len(gaps)

        if consistent > 0.3:  # at least 30% consistent
            print(f"  0x{sync:02X}: median_gap={mode_gap}B, consistency={consistent:.0%}, "
                  f"count={len(positions)}", file=sys.stderr)


def try_packet_parse(data, packet_size, sync_byte=None):
    """Try parsing with a given packet size."""
    print(f"\nTrying packet_size={packet_size}:", file=sys.stderr)

    # Find start
    start = 0
    if sync_byte is not None:
        for i in range(len(data)):
            if data[i] == sync_byte:
                start = i
                break

    n_packets = (len(data) - start) // packet_size
    if n_packets < 3:
        print("  Too few packets", file=sys.stderr)
        return

    # For possible channel counts given packet_size
    # header could be 1-4 bytes, footer 0-2 bytes
    for header in range(0, min(5, packet_size)):
        for footer in range(0, min(3, packet_size - header)):
            payload = packet_size - header - footer
            if payload <= 0:
                continue

            # Try 24-bit (3B) channels
            if payload % 3 == 0:
                n_ch = payload // 3
                if n_ch in [8, 16, 20, 22, 24, 32]:
                    # Parse a few packets and check if values look like EEG
                    samples = []
                    for pkt in range(min(n_packets, 20)):
                        offset = start + pkt * packet_size + header
                        channels = []
                        for ch in range(n_ch):
                            hi = data[offset + ch*3]
                            mid = data[offset + ch*3 + 1]
                            lo = data[offset + ch*3 + 2]
                            # Try both signed interpretations
                            val = (hi << 16) | (mid << 8) | lo
                            if val & 0x800000:
                                val -= 0x1000000
                            channels.append(val)
                        samples.append(channels)

                    arr = np.array(samples, dtype=float)
                    mean_range = np.mean(np.ptp(arr, axis=0))
                    mean_std = np.mean(np.std(arr, axis=0))

                    # EEG-like: values should have some variance but not be random
                    print(f"  header={header} footer={footer} → {n_ch}ch×24bit: "
                          f"range={mean_range:.0f} std={mean_std:.0f}", file=sys.stderr)

            # Try 16-bit (2B) channels
            if payload % 2 == 0:
                n_ch = payload // 2
                if n_ch in [8, 16, 20, 22, 24, 32]:
                    samples = []
                    for pkt in range(min(n_packets, 20)):
                        offset = start + pkt * packet_size + header
                        channels = []
                        for ch in range(n_ch):
                            val = struct.unpack(">h", data[offset + ch*2:offset + ch*2 + 2])[0]
                            channels.append(val)
                        samples.append(channels)

                    arr = np.array(samples, dtype=float)
                    mean_range = np.mean(np.ptp(arr, axis=0))
                    mean_std = np.mean(np.std(arr, axis=0))

                    print(f"  header={header} footer={footer} → {n_ch}ch×16bit: "
                          f"range={mean_range:.0f} std={mean_std:.0f}", file=sys.stderr)


def try_ble_commands(port, baud=115200):
    """Try sending known BLE/serial init commands to wake the device."""
    import serial

    # Common EEG device init sequences
    commands = [
        (b'\x90\x01', "start acquisition (KT88-style)"),
        (b'\x01', "simple start"),
        (b'b', "OpenBCI start stream"),
        (b's', "OpenBCI stop stream"),
        (b'v', "OpenBCI version"),
        (b'\x02', "STX"),
        (b'\x06', "ACK"),
    ]

    print("\nTrying init commands:", file=sys.stderr)
    for cmd, desc in commands:
        try:
            ser = serial.Serial(port, baud, timeout=2)
            ser.reset_input_buffer()
            ser.write(cmd)
            ser.flush()
            time.sleep(1)
            response = ser.read(256)
            ser.close()
            if response:
                print(f"  {desc}: got {len(response)}B → {response[:32].hex()}", file=sys.stderr)
            else:
                print(f"  {desc}: no response", file=sys.stderr)
        except Exception as e:
            print(f"  {desc}: error: {e}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="CGX Quick-20r serial stream probe")
    parser.add_argument("port", help="Serial port (e.g. /dev/tty.usbserial-AI1B2OSR)")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--duration", type=int, default=10, help="Recording duration in seconds")
    parser.add_argument("--try-commands", action="store_true", help="Try sending init commands")
    parser.add_argument("--save-raw", help="Save raw bytes to file")
    args = parser.parse_args()

    if args.try_commands:
        try_ble_commands(args.port, args.baud)
        print("\n" + "="*60, file=sys.stderr)

    # Record
    data, rate = record_raw(args.port, args.baud, args.duration)

    if not data:
        print("No data received!", file=sys.stderr)
        sys.exit(1)

    if args.save_raw:
        with open(args.save_raw, "wb") as f:
            f.write(data)
        print(f"Saved raw to {args.save_raw}", file=sys.stderr)

    # Analyze
    byte_histogram(data)
    correlations = find_repeating_pattern(data)
    try_sync_bytes(data)

    # Try top autocorrelation periods as packet sizes
    if correlations:
        for lag, corr in correlations[:5]:
            if corr > 0.05:
                try_packet_parse(data, lag)

    # Also try known CGX-plausible packet sizes
    # 22ch × 3B = 66B payload + possible 2-4B header/footer
    for ps in [68, 69, 70, 71, 72, 66, 67, 73, 74, 48, 96]:
        if not any(c[0] == ps for c in correlations[:10]):
            try_packet_parse(data, ps)

    # Print summary
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Summary:", file=sys.stderr)
    print(f"  Byte rate: {rate:.0f} B/s", file=sys.stderr)
    print(f"  Total bytes: {len(data)}", file=sys.stderr)

    # Given rate, what sample rates are possible?
    print(f"\n  Possible configurations at {rate:.0f} B/s:", file=sys.stderr)
    for n_ch in [8, 16, 20, 22]:
        for bpc in [2, 3]:  # bytes per channel
            for overhead in [0, 2, 4]:
                pkt = n_ch * bpc + overhead
                sr = rate / pkt
                if 1 < sr < 600:
                    print(f"    {n_ch}ch × {bpc*8}bit + {overhead}B overhead = {pkt}B/pkt → {sr:.1f} Hz",
                          file=sys.stderr)


if __name__ == "__main__":
    main()
