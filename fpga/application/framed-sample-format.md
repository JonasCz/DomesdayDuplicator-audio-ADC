# The framed sample format

The application gateware's sample stream, as `dataGenerator.v` builds it with `FramedFormat`
set — which `DomesdayDuplicator.v` does. Every 16-bit word still carries one RF sample in its
low ten bits; the top six bits, which carried a six-bit sequence number, instead carry
512-sample **frames** of a sync pattern, the latest audio from two audio converters, a status
word describing the SDRAM capture buffer, and a free-running 48-bit counter.

**This page is the specification.** The format is a wire protocol with definitions in two
components, kept apart deliberately (AGENTS.md §2), and both implement this page:

| Where | What it defines |
| --- | --- |
| `fpga/application/dataGenerator.v` | The format: frame position, sync pattern, header, counter, the once-a-frame audio snapshot |
| `fpga/application/adc128spiController.v`, `pcm1802Slave.v` | The audio the header carries, and its timing against the frame |
| `fpga/application/sdramBuffer.v` | The status word the header carries — see [Status word](#status-word-slots-36-37-46-and-47) |
| The capture engine's framed-format decoder in `ddd-gui/src/capture/` | The host's reading of it |

Change the format here first, and then in both places, in one pull request.

The format comes from Jonas Czech's audio fork of the Duplicator, and it is kept bit for bit:
captures and decoders exist that read it. What the port changed is around the format rather
than in it — see [Changes from the fork](#changes-from-the-fork).

## Words

A word is 16 bits, little-endian on the wire, as it always has been.

| Bits | Contents |
| --- | --- |
| 9:0 | The RF sample, unsigned — or, in test mode, the 0…1020 test ramp. Exactly as in the unframed format |
| 15:10 | The frame's metadata for this word's slot |

A host reading a byte buffer finds a word's metadata as `(byte[2n + 1] >> 2) & 0x3F`.

Bits 9:0 are untouched, so the test-ramp analysis of TESTING.md §5 applies to a framed capture
unchanged. The six-bit sequence number does not exist in this format; a host must not run its
sequence-number check on a framed capture, and should check the frame instead.

## Frames

A frame is 512 consecutive words. A slot is a word's position in its frame, 0 to 511.

| Slots | Contents | Order across slots |
| --- | --- | --- |
| 0–31 | Sync pattern, 192 bits | least significant chunk first |
| 32–35 | ADC128S022: left, then right; 12 bits each | most significant chunk first |
| 36–37 | Status word, bits 23:12 | most significant chunk first |
| 38–45 | PCM1802: left, then right; 24 bits each | most significant chunk first |
| 46–47 | Status word, bits 11:0 | most significant chunk first |
| 48–511 | Counter: 58 values of 48 bits | least significant chunk first |

Every slot carries six bits. Note that the two orders differ: the sync pattern and the counter
are least significant first, the header most significant first. That is the fork's layout.

### Sync pattern, slots 0–31

```
SYNC = 192'hDDDF20251015DDDF20251015DDDF20251016FEDCBA987654
```

Slot *k* carries `SYNC[6k+5 : 6k]`. Read as four 48-bit values of eight slots each, least
significant chunk first — which is how the fork's decoder compares them — they are:

| Slots | Value |
| --- | --- |
| 0–7 | `0xFEDCBA987654` |
| 8–15 | `0xDDDF20251016` |
| 16–23 | `0xDDDF20251015` |
| 24–31 | `0xDDDF20251015` |

and slot by slot, 0 to 31, the six-bit values are:

```
14 19 07 26 3A 32 2D 3F 16 00 11 09 20 3C 1D 37
15 00 11 09 20 3C 1D 37 15 00 11 09 20 3C 1D 37
```

### Header, slots 32–47

| Slot | Bits 15:10 |
| --- | --- |
| 32 | ADC128S022 left `[11:6]` |
| 33 | ADC128S022 left `[5:0]` |
| 34 | ADC128S022 right `[11:6]` |
| 35 | ADC128S022 right `[5:0]` |
| 36 | status word `[23:18]` |
| 37 | status word `[17:12]` |
| 38 | PCM1802 left `[23:18]` |
| 39 | PCM1802 left `[17:12]` |
| 40 | PCM1802 left `[11:6]` |
| 41 | PCM1802 left `[5:0]` |
| 42 | PCM1802 right `[23:18]` |
| 43 | PCM1802 right `[17:12]` |
| 44 | PCM1802 right `[11:6]` |
| 45 | PCM1802 right `[5:0]` |
| 46 | status word `[11:6]` |
| 47 | status word `[5:0]` |

The ADC128S022 values are unsigned straight binary, 0 to 4095 across 0 V to the converter's
3.3 V reference; silence is mid-scale, so a host subtracts 2048. The PCM1802 values are 24-bit
two's complement, so a host sign-extends bit 23.

**Every frame's header is one coherent snapshot.** The gateware copies all four audio values and
the status word in one clock edge, on the sample that loads slot 0, and holds them for the whole
frame, so a value's four slots — or two — can never come from two different samples, left and
right are always a pair, and the status word's four slots are always one word. The fork latched
each converter's output whenever it changed, which could split a value across two samples.

### Status word, slots 36, 37, 46 and 47

One 24-bit word, most significant six bits in slot 36 and least significant in slot 47:

```
S = (slot36 << 18) | (slot37 << 12) | (slot46 << 6) | slot47
```

| Bits | Meaning |
| --- | --- |
| 23:20 | **Layout version.** 0: no status word — what gateware without the SDRAM capture buffer sends, and what the fork sent, both of which carry zero here; a host must ignore bits 19:0. 1: the layout below. Anything else is a layout this page does not define yet; a host must ignore bits 19:0 |
| 19 | The SDRAM capture buffer is carrying the samples. Low while the FX3's `collect_data` is low, until the SDRAM is initialised, and until the path has been emptied after a stop — the samples then go straight to the on-chip buffer, as they did before the SDRAM was used |
| 18 | The SDRAM has been initialised. It stays set until the FPGA is reset |
| 17 | A sample has been lost at the SDRAM since `collect_data` last rose: the SDRAM was full. Sticky; cleared only by the next rise of `collect_data`, the FX3's start of a capture. A loss is also counted by the capture buffer telemetry and raises `bufferError`, exactly as an overflow of the on-chip buffer does |
| 16 | Reserved, zero |
| 15:0 | **Fill**: rows of 512 samples held in the SDRAM, 0 to 32768. 32768 is full: 0.42 s of samples at 40 Msps, 0.84 s decimating |

What the fill describes, and when:

- It is sampled when the frame **enters** the capture path — at the generator, before the
  SDRAM — so it is the backlog the frame queued behind, not the backlog when it reached the
  host. It is delivered after that backlog. Read across frames, it shows how far behind the
  host was falling, sample by sample, which is what a host wants for "how close did this come".
- It counts the SDRAM only. Up to about 12,300 more samples sit in the path's two FIFOs and the
  on-chip buffer, about 0.3 ms at 40 Msps; a fill of zero means less than that is queued.
- In steady state it reads 0 or 1: each row is written and then read straight back.
- While bit 19 is low the fill is zero or falling to zero: the path is not in use, and its
  contents are being discarded after a stop.

The word is produced by `sdramBuffer.v`, in the system clock domain, from values crossed from
the SDRAM controller's clock at least every few hundred nanoseconds — far more often than the
12.8 µs a frame lasts, so each frame's snapshot is current. The design is in
[sdram-capture-buffer.md](sdram-capture-buffer.md).

The first frame after reset carries zero here, as it does in the audio slots: nothing has been
snapshotted yet.

### Counter, slots 48–511

Value *j* of a frame, *j* = 0 to 57, is in slots `48 + 8j` to `48 + 8j + 7`, and slot
`48 + 8j + i` carries `value[6i+5 : 6i]`.

- Each value is one more than the value before it, modulo 2^48.
- The count runs on across frames: a frame's first value is one more than the last value of
  the frame before it.
- Nothing resets it but the FPGA's reset, which the FX3 releases when its firmware starts, and
  the FPGA being configured. The first value after reset is zero. It wraps after about 719 days at 40 Msps, twice that
  decimating.

## Alignment and checking

**The first word after reset is slot 0**, and the first counter value is zero. A capture rarely
starts there, though — the FX3 starts and stops streaming independently of the frame — so a host
finds the frame by searching for the sync pattern and then expects it every 512 words.

What a host can check, and what each check catches:

- **Sync at slot 0 of every frame.** Any loss that is not a whole number of frames moves it.
- **The counter's continuity.** A loss of a whole number of frames leaves sync where it was
  expected. USB loses data a 1024-byte endpoint packet at a time, which is 512 words — exactly
  one frame — so this is the case that matters most, and it shows as the counter jumping by 58
  for each frame lost.
- **The test ramp in bits 9:0**, in test mode, as before.

No register says which format a gateware emits; the sync pattern is how a host knows.

## Rates and decimation

Everything in a frame counts **samples**: the frame advances once per sample the capture path
keeps, after the decimator, and so do the counter and the audio converters' timing. So:

- A decimated capture is an unbroken run of frames, exactly as a full-rate one is. Changing the
  rate mid-capture does not break the frame or the count.
- **One stereo sample from each converter per frame, at both rates.** The audio sampling rate is
  the RF rate divided by 512:

| `DECIMATION` | RF rate | Audio rate | PCM1802 SCKI / BCK | ADC128S022 SCLK |
| --- | --- | --- | --- | --- |
| `0x01` | 40 Msps | 78.125 kHz | 20 MHz / 5 MHz | 2.5 MHz |
| `0x02` | 20 Msps | 39.0625 kHz | 10 MHz / 2.5 MHz | 1.25 MHz |

Both rates are inside both converters' ratings: the PCM1802 runs at 256 fs between 16 and 96 kHz,
and the ADC128S022 wants SCLK between 0.8 and 3.2 MHz and 50 to 200 thousand conversions a
second (it makes two per frame).

The decimator's enable is periodic at both rates — every second 80 MHz clock at the full rate,
every fourth decimating, with an irregular interval or two only where the rate changes — and
`tests/tb_dataGeneratorFramed.v` measures that. Across a change of rate the PCM1802's clocks
stay within its specification. The ADC128S022's SCLK can have one cycle outside its 40% to 60%
duty cycle, and the PCM1802 datasheet recommends a power-down cycle when the sampling rate
changes, so audio in the frames around a change of rate is not guaranteed. The application sets
the rate before a capture starts.

## Audio timing

Both converters are timed from the frame itself: their clocks and every action they take happen
at fixed slots, so their samples cannot drift against the frames that carry them.

- **Frame N carries the audio both converters produced during frame N − 1.** Every frame, with no
  exceptions after the first two: frame 0 after reset carries zeros, and in frame 1 the
  ADC128S022 left value is still zero — frame 0 has no left conversion, because CS waits for its
  first proper place to fall — and the right value is the first conversion after reset, which is
  of whichever input the converter was last set to.
- The ADC128S022 converts the left input with its hold instant at slot 48 and the right at slot
  304 of frame N − 1.
- The PCM1802's LRCK period is exactly one frame, starting at slot 0 — left word while LRCK is
  high, right while it is low. The PCM1802's own digital filter adds its group delay on top, as it
  does for any use of the part.
- The PCM1802 outputs zero until 1024 SCKI cycles and then 4480 sample periods have passed
  since its supply came up, and its clocks only start when the FPGA leaves reset: roughly the
  first 60 ms of audio is silence, 115 ms decimating.

`tests/tb_audioCapture.v` checks the one-frame relationship, as a fixed count, at both rates.

## Wiring

The ADC128S022 is the DE0-Nano's own converter, on dedicated FPGA pins. The PCM1802 is a
separate board on the DE0-Nano's 2x13 header JP3, wired as the fork wired it.

| Signal | Direction | FPGA port | FPGA pin | Board |
| --- | --- | --- | --- | --- |
| ADC128S022 CS | out | `ADC_CS_N` | `PIN_A10` | on board |
| ADC128S022 DIN | out | `ADC_SADDR` | `PIN_B10` | on board |
| ADC128S022 SCLK | out | `ADC_SCLK` | `PIN_B14` | on board |
| ADC128S022 DOUT | in | `ADC_SDAT` | `PIN_A9` | on board |
| ADC128S022 IN0, left | analogue | — | — | JP3 pin 24 |
| ADC128S022 IN1, right | analogue | — | — | JP3 pin 25 |
| PCM1802 SCKI | out | `GPIO_2[0]` | `PIN_A14` | JP3 pin 5 |
| PCM1802 BCK | out | `GPIO_2[3]` | `PIN_C16` | JP3 pin 8 |
| PCM1802 LRCK | out | `GPIO_2[5]` | `PIN_D16` | JP3 pin 10 |
| PCM1802 DOUT | in | `GPIO_2_IN[0]` | `PIN_E15` | JP3 pin 2 |
| 3.3 V | — | — | — | JP3 pin 1 |
| Ground | — | — | — | JP3 pin 26 |

Pin names and locations are Terasic's: their reference `.qsf` and Tables 3-8 and 3-9 of the
DE0-Nano user manual. Header pin numbers are from the DE0-Nano schematic. Every other JP3 pin is
left high-Z.

The PCM1802 has to be strapped, on its board, for:

| Pin | Level | Why |
| --- | --- | --- |
| MODE1, MODE0 | low, low | Slave mode: the FPGA supplies SCKI, BCK and LRCK |
| FMT1, FMT0 | low, low | 24-bit, MSB first, left-justified |
| FSYNC | **high** | In slave mode the PCM1802 only shifts data out while FSYNC is high, and no FPGA pin drives it |
| PDWN | high | Not powered down |
| OSR | low | ×64 oversampling; ×128 is only for sampling rates below 50 kHz |

Its digital supply is 3.3 V, which matches the FPGA's 3.3-V LVTTL pins; its analogue supply is
5 V.

## Changes from the fork

The layout is unchanged; the four slots the fork sent as zero now carry the status word, and a
zero there reads as layout version 0, "no status word", so a fork capture and a capture from
gateware without the SDRAM buffer both say so in the same way. These are the differences in
how the format is produced, each of which a capture from the fork could show:

- **PCM1802 left and right.** In the left-justified format LRCK is high for the left channel
  (PCM1802 datasheet, Figure 23); low is left in I2S. The fork took LRCK low as left, so a fork
  capture's PCM1802 "left" is the converter's VINR. Here slots 38–41 carry VINL.
- **One coherent snapshot per frame** rather than a latch on every new sample, as above.
- **Phase-locked audio.** The fork's converters ran free from reset on their own counters and
  relied on equal periods to stay in step with the frame. Here they are timed from the frame
  slot and cannot drift.
- **The audio rate follows the RF rate.** The fork had no decimator. Here the audio is ticked by
  the samples the capture keeps, so a decimated capture has half the audio rate and one stereo
  sample per frame still.
- **The ADC128S022 frame has sixteen rising SCLK edges**, as the datasheet requires. The fork's
  ended on the fifteenth.
- **One clock domain.** The fork clocked its audio logic from the 40 MHz ADC clock and from the
  BCK it generated, with an unsynchronised crossing back. Here every register is on the 80 MHz
  system clock and the converters' clocks are register outputs.
- **The first word after reset is slot 0.** In the fork the first word carried zero metadata and
  slot 0 followed it.

## How this is verified

In simulation only, so far. The testbenches are under `fpga/tests/`:

| Testbench | Checks |
| --- | --- |
| `tb_dataGeneratorFramed.v` | Every slot of every frame, decoded independently of the gateware's own constants; the counter across frames and through a 48-bit wrap; snapshot coherency of the audio and the status word against inputs that change during the header, with every status bit changing between snapshots; the decimator's enable cadence and the frame across two changes of rate |
| `tb_adc128spiController.v` | The ADC128S022 interface against a model that checks the datasheet's timing on every edge, at both rates |
| `tb_pcm1802Slave.v` | The PCM1802 interface against a model that checks the datasheet's timing on every edge, at both rates and across changes of rate |
| `tb_audioCapture.v` | The whole path, decimator to stream, at both rates: that frame N carries what the converters produced in frame N − 1, as a fixed count |
| `tb_sdramFramed.v` | The status word end to end: the generator in this format feeding the SDRAM capture buffer, read back by a consumer that decodes every frame from the words alone. Each frame's status word is, bit for bit, the one the buffer presented when the frame was started; the version is 1, initialisation precedes the path being in use, nothing is reported lost, and the fill rises through a stall and returns to steady state |
| `tb_dataGenerator.v` | That the unframed format is unchanged, with the status word input moving on every clock |

The converter models are `tests/adc128s022Model.v` and `tests/pcm1802Model.v`.

What has **not** been done: a Quartus build, so neither fit nor timing closure is confirmed, and
any run on hardware. Before this is relied on, the gateware needs the TESTING.md §5 procedure at
both rates, and the audio needs checking against a known signal on each converter, which is
also the first check of the pin wiring and the PCM1802's channel order.
