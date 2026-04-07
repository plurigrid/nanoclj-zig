# CGX / Cognionics HD-72 Serial Protocol

Reverse-engineered from `CGX Acquisition v66` (.NET WinForms app).

## Hardware

| Property | Value |
|----------|-------|
| Product | Cognionics HD-72 64CH 1702HDG |
| USB bridge | FTDI FT232R (VID=0x0403, PID=0x6001) |
| Serial | AI1B2OSR |
| Baud | 3,000,000 (config default) |
| ADC | TI ADS1299 (24-bit, up to 8 chips daisy-chained) |
| Transport | Proprietary 2.4GHz wireless via FTDI dongle |

## Software Architecture

```
CGX Acquisition.exe    (.NET 4.6.2, Cognionics_Data_Acqusition namespace)
├── CogByteInterface   (FTDI serial wrapper via ftd2xx.dll)
├── CogDeviceConfig    (config model with LOC_ constants)
├── CogDAQ             (data acquisition controller)
├── CogFileWriter      (EDF/BDF/BrainVision/Persyst/TDT export)
├── CogRDA             (Remote Data Access streaming)
├── InTheHand.Net      (Bluetooth client, alternative transport)
└── liblsl32.dll       (Lab Streaming Layer output)
```

## State Machine

```
stateSearching → stateInitDevice → stateInitGUI → stateConnected
                       │
                       ├─ ReadConfigSequenceInitDAQ
                       │    └─ enterConfigMode(0x14)
                       │         ├─ stop keepAlive
                       │         ├─ sleep 250ms
                       │         ├─ preFlush (discard 65536 bytes)
                       │         ├─ send READ_CONFIG_CMD_BYTE (0x14)
                       │         └─ read config into CONFIG_START[]
                       │
                       └─ CogInit
                            ├─ configure DSP filters
                            ├─ start mainDAQThread
                            └─ start keepAlive thread
```

## Protocol Constants

| Constant | Value | Description |
|----------|-------|-------------|
| READ_CONFIG_CMD_BYTE | 0x14 (20) | Enter config read mode |
| WRITE_CONFIG_CMD_BYTE | 0x13 (19) | Enter config write mode |
| HEADER_BITS | 7 | Bits in packet header |
| CRC_DUMMY | 0 | No CRC |
| DEVICE_DL_FINISHED | 0x499602D2 | Config download terminator |
| Config magic word | 0x392802 (3,745,794) | Config response sync marker |
| MAX_BYTES_FLUSH | 262,144 | Max flush before config read |
| MAX_BYTES_PREFLUSH | 65,536 | Pre-flush discard size |
| DEFAULT_READ_BUFFER | 4,096 | Read buffer size |
| DEFAULT_READ_CHUNK | 1 | Bytes per read call |
| REWRITE_HEADER_INTERVAL | 512 | File header rewrite interval |

## Config Layout

Config is a byte array (`CONFIG_START[]`) indexed by `LOC_*` offsets:

| Offset | Field | Description |
|--------|-------|-------------|
| 4 | LOC_MAX_CONIFG_CHS | Max configurable channels |
| 6 | LOC_CH_COUNT_LIMIT | Channel count limit |
| 7 | LOC_CONFIG_FORMAT | Config format version |
| 10 | LOC_NUM_ADS | Number of ADS1299 chips |
| 11 | LOC_NUM_ADSCH | Channels per ADS chip |
| 12 | LOC_EXT_CHS | External (ExG) channels |
| 13 | LOC_ACC_CHS | Accelerometer channels |
| 14 | LOC_INPUT_MODE | Input mode |
| 15 | LOC_GAIN | ADS gain setting |
| 16 | LOC_HIRES_MODE | High-resolution mode |
| 17 | LOC_SAMPLE_RATE | Sample rate index |
| 18 | LOC_IMP_MODE | Impedance mode |
| 20 | LOC_DATA_MODE | Data mode |
| 21 | LOC_NRF_EN | nRF wireless enable |
| 40 | LOC_CUR_CHS | Current channel count |
| 160 | LOC_CH_MASK_START | Channel mask array |
| 240 | LOC_CH_NAME_START | Channel name array |

### Config Array Index Map

| Index | Count | Field |
|-------|-------|-------|
| ARRAY_INDEX_DATA_MODE (0) | ARRAY_NUM_DATA_MODE (2) | Data mode |
| ARRAY_INDEX_NRFEN (1) | ARRAY_NUM_NRFEN (2) | nRF enable |
| ARRAY_INDEX_EXT (2) | ARRAY_NUM_EXT (1) | External |
| ARRAY_INDEX_ACC (3) | ARRAY_NUM_ACC (1) | Accelerometer |
| ARRAY_INDEX_ADS_MODE (4) | ARRAY_NUM_ADS_MODE (1) | ADS mode |
| ARRAY_INDEX_ADS_GAIN (5) | ARRAY_NUM_ADS_GAIN (1) | ADS gain |
| ARRAY_INDEX_ADS_HIRES (6) | ARRAY_NUM_ADS_HIRES (1) | Hi-res |
| ARRAY_INDEX_ADS_SR (7) | ARRAY_NUM_ADS_SR (1) | Sample rate |
| ARRAY_INDEX_ADS_IMP (8) | ARRAY_NUM_ADS_IMP (1) | Impedance |
| ARRAY_INDEX_IMPDEFAULT (2) | ARRAY_NUM_IMPDEFAULT (2) | Imp default |
| — | ARRAY_NUM_CH_MASK (11) | Channel masks |
| — | ARRAY_NUM_REMAP (10) | Remap table |
| — | ARRAY_NUM_POS (12) | Position table |

## Packet Formats

Two formats exist, selected by `legacyFormat` flag (derived from `CONFIG_START[LOC_DATA_MODE]`).

### Legacy Format

Sync: single `0xFF` byte, then:

```
┌──────────┬──────────────────────────┬───────────┬─────────┬─────────┐
│ Counter  │ EEG + EXT + ACC Channels │ Impedance │ Battery │ Trigger │
│ 1 byte   │ N × 3 bytes              │ 1 byte    │ 1 byte  │ 2 bytes │
└──────────┴──────────────────────────┴───────────┴─────────┴─────────┘
```

- **Counter**: 7-bit sequence (& 0x7F), lost packet detection via diff > 0x81
- **Channels**: 3 bytes each. If `Encrypted`, XOR with `{0xAD, 0x39, 0xBF}`.
  Assembly: `value = (b0<<24 | b1<<17 | b2<<10) >> 8` (unusual bit shifts!)
- **Impedance**: 1 byte, compared to 0x11
- **Battery**: 1 byte × `BatteryGain` → voltage
- **Trigger**: 2 bytes big-endian → `(b<<8 | b)`
- **Total**: 1 + N×3 + 1 + 1 + 2 bytes (HD-72: N=67 → 206 bytes)

### Modern (Non-Legacy) Format

Sync: three consecutive `0xFF` bytes, then:

```
┌──────────┬───────┬──────────────────┬──────────┬──────────┬────────┬──────────────────┬─────────┐
│ Sequence │ Reset │ Delta EEG Data   │ EXT Data │ ACC Data │ Status │ Trigger (opt)    │ Batt    │
│ 2 bytes  │ 1 B   │ variable         │ N×3 B    │ N×3 B    │ 1 byte │ 4 bytes if bit2  │ 2B bit5 │
└──────────┴───────┴──────────────────┴──────────┴──────────┴────────┴──────────────────┴─────────┘
```

- **Sequence**: 16-bit big-endian counter
- **Reset flag**: if `== 1`, clear all `prevSampleBuffer` entries to zero
- **Delta EEG** (per channel, variable length — see below)
- **EXT**: 3 bytes each, standard 24-bit BE signed
- **ACC**: 3 bytes each, standard 24-bit BE signed
- **Status byte** flags: bit0=impedance, bit1=trigger-linked, bit2=trigger, bit5=battery
- **Trigger**: 4 bytes BE (only if status bit 2 set)
- **Battery**: 2 bytes (only if status bit 5 set)

#### ReadDeltaData Encoding (verified from CIL disassembly)

Each EEG channel is encoded as 1, 2, or 3 bytes, keyed on the low 2 bits:

| bits[1:0] | Bytes | Type     | Decoding |
|-----------|-------|----------|----------|
| `x1`      | 1     | Delta    | `delta = ((b>>1) << 25) >> 25` (7-bit sign-ext), `delta <<= 3`, `value = prev + delta` |
| `10`      | 2     | Delta    | `combined = (b & 0xFC) \| (b2 << 8)`, `combined = (combined << 16) >> 15` (sign-ext+scale), `value = prev + combined` |
| `00`      | 3     | Absolute | `value = ((b3<<24) \| (b2<<16) \| ((b & 0xF8)<<8)) >> 8` (24-bit sign-ext) |

Previous values stored in circular `prevSampleBuffer[pastSampleIndex][]`, advancing `pastSampleIndex` mod `numPrevSamples` after each sample.

### Legacy Packet Size (HD-72)
- Counter: 1 byte
- EEG: 64 × 3 = 192 bytes
- EXT: variable × 3 bytes
- ACC: variable × 3 bytes
- Impedance + Battery + Trigger: 4 bytes
- **Minimum total: ~197 bytes**
- At 500 Hz: ~98,500 bytes/sec

## Device Config Files

Two device profiles found in MSI:

### Mobile-72 Cap
- 64 EEG channels
- Electrode-to-ADS remap table (specific pin ordering)

### HD-72 Dry Headset
- 64 EEG channels
- Different remap table (8 groups of 8 channels)

## keepAlive Thread (verified from CIL)

```csharp
void keepAlive() {
    byte[] buf = new byte[128];
    do {
        byteInterface.ReadBytes(buf);   // drain bytes to maintain wireless link
    } while (keepAliveOn);
}
```

The keepAlive thread must be stopped before entering config mode. Without continuous
reads, the wireless link may drop.

## Config Read Sequence (verified from CIL)

```
1. if (keepAliveOn):
     keepAliveOn = false
     Thread.Sleep(250ms)
     aliveThread.Abort()
2. preFlush()                       (read & discard up to MAX_BYTES_PREFLUSH bytes)
3. DAQWriteByte(0x14)               (send READ_CONFIG_CMD_BYTE)
4. remaining = 262144               (MAX_BYTES_FLUSH)
5. Loop: read byte-by-byte into configBuf[writeIdx++ % len]:
     - decrement remaining
     - compare configBuf against CONFIG_START (magic word check)
     - break on match or remaining == 0
6. downloadConfig()                 (parse at LOC_ offsets)
7. Look for magic 0x392802          (24-bit config sync word)
8. Look for 0x499602D2              (DEVICE_DL_FINISHED sentinel)
9. Retry up to 3 times on failure
10. Return true if remaining > 0, false otherwise
```

## Config Write Sequence

```
1. Send WRITE_CONFIG_CMD_BYTE (0x13)
2. Send config bytes
```

## Firmware Version

`stateInitDevice` checks firmware version constant `0x06051314`:
- Bytes: 06, 05, 13, 14 (possibly major.minor.patch.build)

## Output Formats

| Format | Method | Description |
|--------|--------|-------------|
| EDF | writeDataHeaderEDF | European Data Format |
| BDF | writeDataHeaderBDF | BioSemi Data Format (24-bit) |
| BrainVision | writeDataHeaderBV + writeMarkerHeaderBV | .vhdr/.vmrk/.eeg |
| Persyst | writeDataHeaderPersyst | Persyst .lay format |
| TDT | writeDataHeaderTDT | Tucker-Davis Technologies |
| LSL | StartLSL/StopLSL | Lab Streaming Layer (real-time) |
| RDA | StartRDA/StopRDA | Remote Data Access (BrainVision) |

## LSL Configuration

- Library: `liblsl32.dll`
- Channel format types: float32(1), double64(2), string(3), int32(4), int16(5), int8(6), int64(7)

## Notes

- The FTDI dongle bridges USB to the proprietary wireless protocol
- BLE throughput limits effective data rate (~200 B/s idle, up to ~40 KB/s active)
- Headset must be powered on for full-rate streaming
- Config reads only work when streaming thread is stopped
- The `keepAlive` thread continuously reads bytes to maintain connection
