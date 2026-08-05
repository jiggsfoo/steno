# HiDock P1 — device reference

Ground truth measured against Angelo's own P1. Every claim here was observed, not
inferred from documentation or from the community reverse-engineering repos.

**Why this file exists separately from the specs.** Six assumptions taken from
`sgeraldes/hidock-next` and `ghecko/OpenHiNotes` turned out wrong on this device, and two
more of my own were wrong on top. Specs plan against this file; when something here
conflicts with a spec, this file wins.

**Device under test:** firmware 1.4.5, serial `HDP1254506027`, on macOS 27 (26A5388g).

---

## Identity

| | Value |
|---|---|
| Data device | VID `0x10d6` (Actions Semiconductor), PID `0xb00e`. Also seen: `0xaf0e`, `0x2040`. 480 Mb/s. |
| USB serial | `ACTIONS-BOS-002` (the *USB* serial; the Jensen protocol reports `HDP1254506027`) |
| Jensen interface | configuration 1, **interface 0**, alt 0. Vendor-specific. Bulk OUT `0x01`, IN `0x82`. |

**Interface matching.** `IOUSBHostInterface.__createMatchingDictionary` with an
`interfaceNumber` predicate matches **nothing** on macOS 27, even though the device's
registered `bInterfaceNumber` genuinely is 0 — IOKit compares CFNumber types strictly,
not numeric values. Use a bare `IOServiceMatching("IOUSBHostInterface")` class match and
filter in Swift. Consequence: those callbacks fire for *every* USB interface on the
machine, so the VID/PID filter is the only thing making an event meaningful.

**Interface 0 is Apple's iAP interface** (class 255, subclass 240, `SupportsIAP = Yes`),
and `accessoryd` holds a user client on it. That does **not** block an independent claim.

---

## Wire protocol

12-byte header, big-endian: `0x12 0x34` sync, command (u16), sequence (u32), then a
length word whose **top byte is padding length and low 24 bits are body length**.

**The device echoes the request sequence.** Verified with `0x00000000`, `0x00000007`,
`0x00003039` and `0xDEADBEEF` — all returned byte-identical. Match responses on
**(command, sequence)**, which is what stops a late reply to an abandoned command from
satisfying its own retry.

**A single bulk read coalesces multiple packets.** A 53,568-byte recording arrived as 7
Jensen packets in **one** 53,652-byte read (payload + 7 × 12 framing). The decode loop
must drain several packets per buffer.

### Verified response bodies

**`GET_DEVICE_INFO` (1) — 17 bytes, not 20.**
```
00 01 04 05 | 48 44 50 31 32 35 34 35 30 36 30 32 37
 firmware   | "HDP1254506027"  (13 chars, NO padding)
 = 1.4.5    |
```
The reference implementations assume a padded 16-byte serial field. A `>= 20` guard
throws on every connect against this device.

**`GET_DEVICE_TIME` (2) — 7 bytes, BCD.**
```
20 26 08 04 14 04 27   read at local wall clock 14:04:28
YY YY MM DD HH MM SS   each byte is two BCD digits — 0x14 is 14, not 20
```
Two independent captures, each one second off from wall clock (read latency). Reading
these as binary gives year 8230, hour 20, second 39 — which is what a guessed parser
produced before this was measured.

**`SET_DEVICE_TIME` (3) is never sent.** That the write accepts the same layout is an
inference, not a measurement, and a wrong write corrupts the clock that names every
recording.

**`GET_FILE_LIST` (4)** — optional 6-byte header (`0xFF 0xFF` + u32 count), then entries:
u8 version, u24 name length, name (ASCII, skip NULs), u32 byte length, 6 padding, 16-byte
signature. Parses with zero bytes left over.

**`TRANSFER_FILE` (5)** payloads are ordinary framed Jensen packets echoing the request
sequence — **not** a raw byte stream.

**`GET_CARD_INFO` (16)** — u32 free MiB, u32 capacity MiB, u32 status. Observed capacity
59,648 MiB.

**`DELETE_FILE` (7) response is never parsed.** Format unverified, so deletion is
confirmed by **re-listing the device** instead. Format-independent, and it fails safe.

**`GET_BATTERY_STATUS` (4100) — 6 bytes, NOT yet decoded.**
```
00 62 00 3d b8 c8      one sample only
```
`0x62` = 98 is a plausible battery percentage and `0x3d` = 61 might be the earphones', but
this is **one reading at one charge level**. Needs a second sample at a materially
different level before anything is built on it. The menubar already has the line and
hides it while `battery` is nil.

---

## Recordings

**`.hda` files are plain MP3.** Payload begins `ff fb` (MPEG-1 Layer III). `afinfo`
reports 1 channel, 48 kHz, 96 kbps; `file(1)` agrees. **Nothing is transcoded and no
header is wrapped** — only the extension is corrected on write, and the original device
filename is preserved in the sidecar.

Filenames are timestamped: `2026Aug04-135302-Wip02.hda`. A second numeric form
(`20260804143022REC001.wav`) exists in the reference implementations; the pattern for it
must be anchored to the start of the name, or it will take the first 12-digit run
anywhere and silently misfile the recording.

Firmware 1.4.3 added a WAV 768 kbps mode. At that rate a 30-minute recording is ~170 MB,
which is why transfers stream to disk rather than buffering.

---

## BlueCatch — how the P1 records calls

Verified 2026-08-05. This is the mechanism behind wishlist item 5.

```
Mac ──USB-C──▶ P1 ──Bluetooth──▶ your earphones
                │
                └─ records both directions
```

The P1 is a Bluetooth **host**: it pairs directly to earphones itself, rather than being a
peripheral of the Mac. When BlueCatch is engaged the P1 presents a **second, separate USB
device** alongside the data device:

| | Data | Audio |
|---|---|---|
| VID:PID | `0x10d6:0xb00e` | `0x1395:0x005d` |
| Speed | 480 Mb/s | 12 Mb/s |
| Chipset | Actions Semiconductor | Solid State System Co.,Ltd. |
| Core Audio | — | 2ch output / 1ch input, 48 kHz |

**Both operate simultaneously.** The Jensen protocol keeps working while the P1 serves as
the call's audio device, so syncing during a call is fine.

**The data path goes briefly deaf while BlueCatch attaches earphones.** The first
`GET_DEVICE_INFO` after connecting timed out; subsequent ones succeeded. The app's
existing timeout → "P1 busy" → backoff handling covers this correctly.

**Wired headphones cannot participate.** The P1 has to be the Mac's audio device and it
hands audio off over Bluetooth. There is no path to insert a wired headset, and the
1-channel input means a wired mic is equally out.

### To record a Google Meet call

1. P1 connected by USB-C, earphones BlueCatch'd to it.
2. In Meet, set **both** microphone and speaker to **HiDock P1**.
3. Audio plays through the earphones; the P1 records both directions.

### Verified Bluetooth payloads

Both read-only, both confirmed against a live BlueCatch session.

**`BLUETOOTH_STATUS` (4099) — 35 bytes**
```
00 00 | 16 | "Angelo's AirPods Pro" | 82 9b c3 8e 3f 74 | 01 01 00 00
       len   UTF-8, curly apostrophe   MAC address        state flags
```

**`BT_GET_PAIRED_DEV_LIST` (4103) — 33 bytes**
```
00 | 01 | 00 16 | "Angelo's AirPods Pro" | 82 9b c3 8e 3f 74 | 01
     count  len(u16)                        MAC               connected
```

Name lengths are byte counts, not character counts — the curly apostrophe is 3 UTF-8
bytes, so "Angelo's AirPods Pro" is 22 bytes for 20 characters.

**Not yet exercised:** `BLUETOOTH_SCAN(4097)`, `BLUETOOTH_CMD(4098)`, `BT_SCAN(4101)`,
`BT_DEV_LIST(4102)`. These mutate device state and were deliberately not fired against a
working setup. `BT_REMOVE_PAIRED_DEV(4104)` is destructive — do not send it casually.

---

## Vibe Mic

A separate mode (double-click power). Pairs to the Mac as **`HiDock P1-Vibe Mic`**,
Bluetooth minor type **Keyboard** — a HID keyboard whose wheel fires a configurable
shortcut, plus a microphone. It is not an audio sink and plays no part in BlueCatch.

---

## Corrections log

Things believed true and later disproved. Kept so they are not re-adopted.

| Believed | Actually |
|---|---|
| Firmware 1.4.3 (from release notes) | **1.4.5** |
| `GET_DEVICE_INFO` body is 20 bytes | **17** — 13-char unpadded serial |
| Recordings are `.mp3`/`.wav`; `.hda` is legacy needing a WAV wrapper | **`.hda` IS MP3.** Only the extension is wrong |
| Device clock is binary | **BCD** |
| `interfaceNumber` predicate matches interface 0 | Matches **nothing** on macOS 27 |
| Responses match on command id alone | Device **echoes the sequence** — match on both |
| The P1 is not a USB audio device | It is, as a **separate USB device**, while BlueCatch is engaged |
| Spec 3 would need a CoreAudio HAL plugin fed by `REALTIME_TRANSFER` | BlueCatch does the routing in hardware; the app only orchestrates |
| A Swift `actor` enforces one-command-at-a-time | Actors are **reentrant**; needs an explicit FIFO gate |
