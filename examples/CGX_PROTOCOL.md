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

## Packet Format (mainDAQThread)

The device streams continuously once connected. Each packet:

```
┌─────────┬──────────────┬─────────────────────────┬──────────┬──────────┐
│ Header  │ Status Word  │ EEG Channels            │ EXT Data │ ACC Data │
│ 1 byte  │ 4 bytes      │ NumEEG × 3 bytes        │ NumEXT×3 │ NumACC×3 │
└─────────┴──────────────┴─────────────────────────┴──────────┴──────────┘
```

### Header Byte
- Top 7 bits: packet sequence counter (mask 0x7F)
- Bit 0: flag
- Validation: check against 0x81 pattern

### Status Word (4 bytes, big-endian)
- ADS1299 status + trigger information
- Stored in `TriggerAtIndex`

### EEG Channels
- Each channel: 3 bytes, big-endian, 24-bit signed
- `value = (byte0 << 24 | byte1 << 16 | byte2 << 8) >> 8`  (sign-extend)
- Floating inputs read near 0xFFFFxx (positive rail)
- Battery channel uses `BatteryGain` scaling

### Additional Constants in mainDAQThread
- 0xAD (173), 0x39 (57), 0xBF (191): packet validation/checksum bytes
- Shift values: 24, 16, 8 for 32-bit word assembly
- Lost packet detection via `LostPackets` counter

### Packet Size (HD-72)
- Header: 1 byte
- Status: 4 bytes
- EEG: 64 × 3 = 192 bytes
- EXT: variable × 3 bytes
- ACC: variable × 3 bytes
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

## Config Read Sequence

```
1. Set keepAliveOn = false          (stop read thread)
2. Sleep(250ms)
3. preFlush()                       (read & discard 65536 bytes)
4. WriteByte(0x14)                  (send READ_CONFIG_CMD_BYTE)
5. Read bytes → CONFIG_START[]      (until timeout or 262144 bytes)
6. downloadConfig()                 (parse at LOC_ offsets)
7. Look for magic 0x392802          (24-bit config sync word)
8. Look for 0x499602D2              (DEVICE_DL_FINISHED sentinel)
9. Retry up to 3 times on failure
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
