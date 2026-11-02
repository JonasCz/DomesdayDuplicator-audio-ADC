# Handoff: audio capture and the SDRAM capture buffer

This branch is upstream's `main` (Domesday86/DomesdayDuplicator at `0f015fa`) with this
fork's audio work ported onto it, plus a new 32 MiB SDRAM capture buffer. None of it has been
through Quartus or run on a Duplicator yet. This document says what to build, what to check
and how to test it. Parts A–C go into detail, one per component.

## What is on `master`

| # | Commit | Subject | Meant for |
| --- | --- | --- | --- |
| 1 | `14486a4` | fpga: add PCM1802 and ADC128S022 audio capture and the framed sample format | audio PR |
| 2 | `d056fd3` | ddd-gui: capture the audio gateware's framed stream and its audio | audio PR |
| 3 | `413dd52` | Add the PCM1802 audio add-on board | audio PR |
| 4 | `eb3def8` | fpga: buffer the capture stream in the DE0-Nano SDRAM | SDRAM PR (needs the audio PR) |
| 5 | `5a4a84f` | ddd-gui: show the gateware's SDRAM buffer fill level | SDRAM PR |
| 6 | `e6818f6` | ddd-gui: add a host-side USB stall injector for testing the device's buffering | SDRAM PR |
| 7 | — | this handoff document | this fork only |

The fork's previous history (the old `DE0-NANO/` gateware and the old `Linux-Application/`
GUI) is kept under the tag `legacy-audio-fork`. Upstream deleted the old GUI on 2026-08-18,
so the audio features were ported to the new application, `ddd-gui/`, rather than rebased.
Commits 1–3 and 4–6 are each a self-contained series. To split them into branches later:
`git branch audio-adc 413dd52` and `git branch sdram-buffer e6818f6`.

All commits are authored as `derheilendelotus <derheilendelotus@gmail.com>` and carry no
tool-attribution trailers, because upstream's `AGENTS.md` (Rule 2) forbids them. To use another
identity, set `user.name`/`user.email` and run
`git rebase -r 0f015fa --exec 'git commit --amend --no-edit --reset-author'`.

## What has been verified, and what has not

| Check | Result |
| --- | --- |
| Gateware lint (`fpga/tests/run-lint.sh`, Verilator `-Wall`) | 19 modules clean |
| Gateware style (`run-style.sh`, Verible) | 43 files clean |
| Gateware constraints (`run-sdc.sh`) | both images parse and cover every pin, including the 20 audio and 39 SDRAM pins |
| Gateware simulation (`run-sim.sh`, Icarus) | all 18 testbenches pass: 10 upstream (two extended), 4 audio, 4 SDRAM |
| Licence headers (`tools/check-licence-headers.sh`) | OK |
| Capture application build (clang-format and clang-tidy gates) and `ctest -LE hil` | builds; **2026 of 2026 tests pass** (two upstream tests skip by design). The only compiler warning, `-Wfree-nonheap-object`, is a GCC false positive in upstream's unchanged `test_headless_capture_runner.cpp` |
| `fpga/common/`, `fpga/factory/`, `fx3/` | unchanged, so the factory image and the FX3 firmware stay upstream's |
| **Quartus fit and TimeQuest timing** | **not done** (see below) |
| **Anything on hardware** | **not done** |

### Quartus could not be run here, and upstream's Nix route is currently broken

The work was done in a cloud container. Altera's download servers refuse that network, and
Altera's official Docker images of Quartus only contain Cyclone V and MAX 10, not Cyclone IV E.
So nothing here has been fitted or timed.

Note that `nix develop .#fpga-quartus` / `nix build .#bitstream` currently **fail for
everyone**. The installer URL that nixpkgs pins (`downloads.intel.com/akdlm/...`) now
redirects to Intel's 404 page, so the fetch gets HTML and fails its hash check. Two
workarounds:

- **Seed the Nix store by hand.** Download the two files in a browser from Altera's
  *Quartus Prime Lite Edition 25.1 for Linux* page, check their SHA-256, then add them to
  the store. Nix accepts them because they match the pinned hashes, and the Nix route then
  works unchanged:

  ```bash
  sha256sum QuartusLiteSetup-25.1std.0.1129-linux.run cyclone-25.1std.0.1129.qdz
  # 518433ec7dcd61725560af653353f7a5c320cce9e528b22747b8a8df3674c4eb  QuartusLiteSetup-25.1std.0.1129-linux.run
  # 94a398cbad411f16383b2a27c400e0e9dec81b0724197f33bb4c7a769181e4ba  cyclone-25.1std.0.1129.qdz
  nix-store --add-fixed sha256 QuartusLiteSetup-25.1std.0.1129-linux.run cyclone-25.1std.0.1129.qdz
  nix develop .#fpga-quartus -c ./fpga/build-local.sh
  ```

  (`cyclone-…` is the Cyclone IV/10 LP package; `cyclonev-…` is a different file.)
- **Or use a hand-installed Quartus Prime Lite** (Linux or Windows), as Part A §1 (b)
  describes.

**The first thing to do is build master's application image and read the reports**, before
going near a board. What to look for is in Part A §1 and Part B §1. The two riskiest items
are the new 120 MHz SDRAM domain and the SDRAM I/O timing, whose `DRAM_CLK` phase shift
(−3.5 ns) is a calculated estimate. Part B §1 says how to adjust it.

## Recommended test order

1. **Build** master's bitstream and check fit and timing (Parts A §1 and B §1).
2. **Backwards compatibility.** Run the new capture application against the standard upstream
   gateware. RF capture must be unchanged, and audio and SDRAM must be reported as unavailable
   (Part C §3.1).
3. **Load master's gateware volatilely over JTAG**, without touching the factory image
   (Part A §2), and run the capture-integrity check in test mode (TESTING.md §5) at 40 and
   20 Msps with no stalls (Part A §3, test 1; Part B, test B2).
4. **Audio:** check the clocks with a scope, then a known tone on each channel for channel
   order, then levels and noise (Part A §3, tests 2–7; Part C §3.2–3.5). The PCM1802's L/R
   polarity was deliberately changed (below), so check it first.
5. **SDRAM:** check the status display, then injected stalls below and above capacity, the
   drain rate, start/stop behaviour, and finally the hour-long soak with periodic stalls
   (Part B §3, B1–B6; Part C §3.6–3.7).

If something breaks and you need to tell the two features apart, check out commit 3
(`413dd52`) and build its gateware. That is the audio-only image, without the SDRAM path.

## Design choices in brief

- **One gateware image carries both features.** `dataGenerator.v` has a `FramedFormat`
  parameter (default off, upstream's 6-bit sequence counter), and the application image
  turns it on. The framed format is bit-for-bit the fork's: 512-sample frames with sync,
  ADC128S022 and PCM1802 audio, a 48-bit counter, and now an SDRAM status word in the slots
  that were reserved. The single specification is `fpga/application/framed-sample-format.md`.
- **The host tells the formats apart from the data**, by looking for the sync pattern, as
  upstream already does for gateware without a counter. No register, FX3 firmware or USB
  protocol change was needed. With standard gateware the application captures exactly as
  upstream does and says audio is unavailable.
- **Audio follows the capture rate.** The converters are clocked from the post-decimator
  sample enable, so there is one stereo sample per frame. That is 78125 Hz at 40 Msps and
  39062.5 Hz when decimating to 20 Msps. Every frame's audio is captured at the same instant,
  which fixes the fork's possible tearing between slots. Frame N carries the audio sampled
  during frame N−1.
- **Two behaviour changes versus the fork, both from the datasheets:**
  - **PCM1802 left is now LRCK high.** The fork used low, so fork captures probably have
    L and R swapped. Part A §3 test 3 checks this with a tone and gives the one-line change
    if the board turns out to need the old polarity.
  - The ADC128S022 now gets the 16 SCLK rising edges per conversion that the part requires;
    the fork gave it 15.
- **The SDRAM runs in its own 120 MHz domain.** At upstream's single 80 MHz clock the SDRAM
  cannot carry 40 Mwords/s in and 40+ out. It uses an application-only PLL (the shared one
  in `fpga/common/` is untouched), hand-written dual-clock FIFOs, and a FIFO-only controller
  that moves whole 512-word rows. Simulated figures: 117 Mwords/s through the part, and a
  backlog draining at 37.5 Mwords/s net. It holds about 0.42 s of capture at 40 Msps,
  against about 2 ms before.
- **Stale data is handled with the FX3's existing `collectData` line.** The FX3 already
  drives it on the start/stop request (`0xB5`), which the capture application sends. While it
  is low the SDRAM is bypassed, which is exactly upstream's behaviour, so a host that never
  sends start still works. On start the path is flushed and used.
- **Samples are only ever dropped at the SDRAM's input,** as one contiguous run, when the
  32 MiB is full. The drop raises the FX3's error line and is counted by upstream's register
  telemetry. The in-band status word reports the fill, a sticky overflow bit and whether the
  path is in use, and the capture application shows them as a "Device SDRAM" bar.
- **Continue after dropped samples** (off by default, which is upstream's behaviour) ports
  the fork's resynchronise-and-continue. It works for framed streams only.
- **The USB stall injector** (`--inject-usb-stall <ms>[@<period-s>][+<delay-s>]` or
  `DDD_INJECT_USB_STALL`) is test-only and off unless asked for. Every capture made with it
  is labelled in the UI, the log and the metadata. It works with libusb only (Linux, macOS);
  the Windows/WinUSB build logs that it is unavailable.
- **The FX3's DMA buffer count was left at 4.** For a two-socket channel the SDK allocates
  twice the count, so 4 already uses 128 KiB of the 224 KiB DMA heap; the source comment
  saying 64 KiB is wrong. At most 5–6 would fit, for about 0.8 ms more tolerance, and a
  failed allocation would stop capture until a reflash. The SDRAM makes it unnecessary.

## Not ported from the fork

- Stopping a capture when the RF amplitude drops. It is a separate capture-control feature
  and would make a better PR of its own.
- The WinUSB/libusb toggle. Upstream picks the backend at build time.
- The connection-retry and "fix lag" changes. Neither problem exists in the new application.
- The Windows `.bat` build scripts and `.vscode/` settings. Upstream forbids IDE files and
  second build environments.

## Open questions for you

1. **PCM1802 channel order:** confirm LRCK-high = left with a tone (Part A §3, test 3).
2. **Audio file format:** keep the fork's headerless `.s16`/`.s24` files, or write WAV/FLAC?
3. **Stall injection on Windows:** wanted? It needs a change to the WinUSB loop's underflow
   check.
4. **If this ever goes upstream:** the SDRAM change gives the FX3's `collectData` line a
   meaning for the first time (no firmware change needed). Upstream's `AGENTS.md` asks for
   discussion of protocol and capture-path changes. Its test counts and TESTING.md §4.6 are
   also out of date (they already were).

---

## Part A: Audio gateware

What this covers: building, loading and bench-testing the audio gateware, which reads a
PCM1802 and the DE0-Nano's ADC128S022 and carries their samples in the framed sample format.

- Commit `14486a4` on `master`.
- The format specification is `fpga/application/framed-sample-format.md` in that commit. Read
  its *Wiring* and *Audio timing* sections before going to the bench.
- So far it is verified by lint and simulation only. It has never been through Quartus or
  onto a board.

**Before you start: the host must be updated too.** This gateware puts frame metadata in bits
15:10 where the six-bit sequence number used to be. The current ddd-gui checks that sequence
number and strips those bits before writing, so with this gateware it stops every capture with
*"Sequence counter mismatch"*. That message proves the gateware is emitting frames, and nothing
more. Tests 1, 3, 4 and 5 below need the capture engine's framed-format decoder in
`ddd-gui/src/capture/`, which is being written separately. Tests 0, 2, 6 and 7 need only a
scope or a logic analyser.

---

### 1. Building the bitstream

Quartus cannot be obtained in the container this was written in, so the build is yours. Build
the factory image too, as `build-local.sh` does. It does not change, but the scripts expect it.

#### (a) Nix, on x86_64 Linux

```bash
cd DomesdayDuplicator-audio-ADC   # the repository root, at master
nix develop .#fpga-quartus -c ./fpga/build-local.sh        # first run downloads several GB
```

The output goes to `fpga/build/`. `nix build .#bitstream` is the hermetic route (`result/`,
with the reports in `result/reports/application/`), but use `build-local.sh` while iterating.

#### (b) Quartus Prime Lite installed by hand

The canonical version is 25.1std. 18.x and later also compile the project.

- **Linux:** put Quartus's `bin` on `PATH`, for example
  `export PATH=$HOME/intelFPGA_lite/25.1std/quartus/bin:$PATH`, then run
  `./fpga/build-local.sh`. It checks for `quartus_sh` and `quartus_cpf` and does everything
  route (a) does. For JTAG access, install the udev rule
  `fx3/programmer/configs/70-domesday-duplicator.rules`.
- **Windows:** `build-local.sh` is bash, so do its essential steps by hand.
  1. Copy `fpga/common`, `fpga/application` and `fpga/factory` to a scratch folder, keeping
     the layout. Never compile in the checkout: Quartus rewrites the `.qsf`.
  2. In the Quartus command shell:
     `cd <scratch>\application` then `quartus_sh --flow compile DomesdayDuplicator`.
     Or open `DomesdayDuplicator.qpf` in the GUI and press Compile.

  This gives you `DomesdayDuplicator.sof`, which is all the JTAG test in §2 needs. The copied
  `common/version.vh` reports "no commit", so the identity shows *commit invalid*; that is
  expected for a bench build.

  A device update needs the `.rpd` and a bundle. Making those is bash (`quartus_cpf`,
  `make-boot-block.py`, `tools/dev-bundle.sh`), so do it on Linux or in a VM.

#### What to check in the reports

With `build-local.sh` the reports are `fpga/build/application/DomesdayDuplicator.*.rpt` and
`*.summary`.

| Check | Where | Pass |
| --- | --- | --- |
| Flow succeeded | `flow.rpt` | *Flow Status: Successful*; 0 errors |
| Resources | `fit.summary` | Upstream baseline: **2,999 / 22,320 LEs**, 0 embedded multipliers. Expect a few hundred more LEs: a 48-bit counter, 72 snapshot bits, two small controllers and a 192-bit sync ROM. Over about 1,000 more is worth a look; multipliers should still be 0; memory bits unchanged |
| Pins | `fit.rpt`, pin-out section | `ADC_CS_N` A10, `ADC_SADDR` B10, `ADC_SCLK` B14, `ADC_SDAT` A9, `GPIO_2[0]` A14, `GPIO_2[3]` C16, `GPIO_2[5]` D16, `GPIO_2_IN[0]` E15, all 3.3-V LVTTL. **No "no exact pin location" warning** |
| Setup and hold | `sta.summary`, `sta.rpt` | The system clock is `pll_generator_0\|altpll_component\|auto_generated\|pll1\|clk[0]`. Its worst setup and hold slack must be ≥ 0 in all three corners (Slow 85C, Slow 0C, Fast 0C). Upstream's worst setup was **+0.89 ns**; note the new figure |
| Exceptions | Timing Analyzer → SDC assignments | Exactly two new false paths, `-to $audio_outputs` and `-from $audio_inputs`. The **Ignored Constraints** report must be empty; an entry there means a port name did not match |
| Unconstrained | Timing Analyzer → Unconstrained Paths | The 8 audio ports may be listed beside the existing false-pathed ones (SPI link, LEDs). Nothing else new |

**Paths most at risk from this change.** All are single-cycle at 80 MHz.

1. `dataGenerator`: `position`, then `+1`, then `×6`, then the variable part-select of the
   192-bit `SyncPattern` (a 32-to-1 mux, 6 bits wide), then the region mux, into `metadata`.
   This is the most likely worst path. Also confirm Quartus accepted the part-select of a
   `localparam`: any synthesis error or warning on `SyncPattern[sync_offset+:6]` matters.
2. `dataGenerator`: the 48-bit `counter + 1` carry chain, and the 8-to-1 chunk select of
   `counter`, into `metadata`.
3. The `frame_position` fan-out into the two audio controllers. These are only compares, so
   they are short.

To see them, run this in `fpga/build/application` as `quartus_sta -t audio-timing.tcl`:

```tcl
project_open DomesdayDuplicator
create_timing_netlist; read_sdc; update_timing_netlist
report_timing -setup -npaths 20 -detail path_only -file worst_setup.txt
report_timing -hold  -npaths 20 -detail path_only -file worst_hold.txt
report_timing -setup -npaths 10 -to [get_registers {*data_generator_0*metadata*}] -file metadata_setup.txt
report_exceptions -file exceptions.txt
report_ucp -file unconstrained.txt
delete_timing_netlist; project_close
```

If slack is negative on paths 1 or 2, do **not** add a multicycle exception. Decimation
changes can put two enables one clock apart, so the paths really are single-cycle. The fix is
a lookahead: register `next_position`, or compute the metadata one slot further ahead. That
is a small change to `dataGenerator.v`, and `tb_dataGeneratorFramed` will check it.

**Warnings worth stopping for:**
- Timing requirements not met.
- An ignored or unmatched SDC constraint.
- No location assignment for any pin.
- Any audio output reported as stuck at VCC or GND.
- An inferred latch.
- Any audio signal (`pcm_bck`, `pcm_lrck`, `pcm_scki`, `adc_serial_clock`) treated as a
  clock. Nothing is clocked by them.

**Expected and harmless:** `GPIO_2_IN[2:1]` and the high-Z `GPIO_2` pins drive no logic, and
A9, E15, E16 and M16 are clock-capable pins used as plain inputs.

For a clean comparison, build upstream `0f015fa` the same way into another directory and diff
the summaries.

---

### 2. Loading it without touching the factory image

**First choice: volatile JTAG.** This writes nothing to flash, and a power cycle brings back
whatever was there.

With the case open, connect the DE0-Nano's mini-USB (its on-board USB-Blaster).

```bash
cd fpga/build/application && quartus_pgm DomesdayDuplicator_write_sof.cdf
```

On Windows, use the Programmer GUI: JTAG mode, add `DomesdayDuplicator.sof`, Start. The FX3
keeps running, and the new image leaves reset two clocks after configuration. Restart the
capture application, or reconnect, so it re-reads the identity, and check that `IMAGE_ROLE`
is `0x01`.

Without Quartus on the bench machine, convert to vectors and play them with `ddd-jtag`, which
is also volatile:
`quartus_cpf -c -q 4.5MHz -g 3.3 -n p DomesdayDuplicator_write_sof.cdf app.svf`, then
`ddd-jtag app.svf`.

**Once it works: a device update.** This writes only the application image, and the factory
image stays as a fallback.

1. Run `./tools/dev-bundle.sh` to get `build/domesday-duplicator-update-0.0.0-dev.dddfw`.
2. Install it with `ddd-update` or with **Tools → Firmware → Update firmware…**. The procedure
   is TESTING.md §6, U1/U2 and G1. G1's pass condition: the gateware row shows the new commit,
   `IMAGE_ROLE` reads `0x01`, a capture runs, and a power cycle comes back in the application
   image.
3. Keep a known-good bundle to hand for going back.

**Never** program a provisioning `.jic` just to test this. It rewrites the factory image as
well.

---

### 3. Bench tests, in this order

At **40 Msps**, one audio sample per 512 RF samples gives 78.125 kHz:

| Signal | Frequency | High / low |
| --- | --- | --- |
| SCKI | 20 MHz | 25 / 25 ns |
| BCK | 5 MHz | 100 / 100 ns |
| LRCK | 78.125 kHz | 6.4 / 6.4 µs |
| ADC SCLK | 2.5 MHz | 200 / 200 ns |
| ADC CS | one 100 ns high pulse every 6.4 µs | — |

At **20 Msps** (*20 MSPS for VHS*), every figure halves, so periods double: 39.0625 kHz,
SCKI 10 MHz, BCK 2.5 MHz, SCLK 1.25 MHz, and a 200 ns CS pulse every 12.8 µs.

#### 0. Smoke test (no host decoder needed)
- **Connect:** the device as normal; load per §2.
- **Do:** open the capture application.
- **Expect:** the device enumerates and the gateware identity reads with `IMAGE_ROLE 0x01`.
  A capture with the *current* ddd-gui stops with *"Sequence counter mismatch"*, which is
  expected here.
- **Failure:** "the FPGA is not answering" means the image did not load. Repeat §2 and power
  cycle.

#### 1. Capture integrity, TESTING.md §5 (needs the framed decoder)
- **Do:** test mode on, a capture of at least 60 s at 40 Msps; then the same at 20 Msps.
  Analyse each with `ddd-gui --analyse-test-data <file>`.
- **Expect:** zero ramp breaks. The decoder reports zero sync losses and zero counter
  breaks, every frame has its sync, and the counter is continuous. The device's own *samples
  dropped* reads 0.
- **Failure:**
  - The counter jumping by a multiple of 58 means whole USB packets were lost: one packet is
    one frame.
  - Sync lost at a non-multiple of 512 means a partial loss.
  - Sync never found at all means the wrong gateware, or a decoder that does not match the
    spec.
  - Test mode only changes bits 9:0, so audio is present in test-mode captures too.

#### 2. Clocks, scope or logic analyser (no host needed)
- **Connect:** PCM1802 signals at JP3: SCKI pin 5, BCK pin 8, LRCK pin 10, DOUT pin 2, ground
  pin 26. ADC128S022 signals at the chip (TSSOP-16): CS pin 1, DIN pin 14, DOUT pin 15, SCLK
  pin 16. You need at least 100 MS/s to see SCKI properly. A 24 MS/s analyser can only check
  BCK, LRCK and SCLK, best in 20 Msps mode.
- **Expect:**
  - The frequencies in the table above, at 50% duty, at each rate.
  - Per LRCK period, exactly 64 BCK and 256 SCKI. LRCK edges coincide with BCK *falling*
    edges.
  - DOUT changes within about 20 ns after BCK falls. The MSB appears at the LRCK edge,
    followed by 23 bits and then zeros.
  - ADC: exactly 16 SCLK rising edges per CS-low window. CS only moves while SCLK is high. DIN
    is high only during the 5th SCLK cycle of every *other* conversion; that is the IN0
    conversion addressing IN1 next.
- **Failure:**
  - All signals static: still in reset (FX3 nReset), the wrong pins, or the old gateware.
  - Frequencies off by 2×: the rate is not what the application says.
  - LRCK changing on a BCK *rising* edge: that is the fork's timing, so you are running fork
    gateware.

#### 3. Channel order, using a known tone (needs the decoder)
- **PCM1802:** feed a 1 kHz tone into the *left* input only (VINL: the module's LIN, or the
  custom board's IN1) and short or silence the right. Expect the tone in slots 38–41 (left)
  and near-silence in 42–45. Then swap.
- **ADC128S022:** feed IN0 (JP3 pin 24) only and expect slots 32–33 (left). Then IN1 (JP3
  pin 25), expecting slots 34–35. The ADC input range is 0–3.3 V, so bias it to about 1.65 V,
  for example with the fork's resistor-and-capacitor wiring.
- **LRCK polarity has changed from the fork.** Here LRCK **high = left**, per PCM1802
  datasheet Figure 23 for 24-bit left-justified. The fork used LRCK low as left, so a fork
  capture's PCM1802 "left" was VINR, assuming the converter was strapped FMT=00.
- **If the tone lands in the wrong channel:**
  1. First check FMT0/FMT1 are both low. FMT0 high means I2S, which flips the polarity *and*
     shifts the data by one bit, so levels would also be wrong (about half or garbled).
  2. If the straps are right, the board's input labelling is swapped relative to VINL/VINR.
     Prefer fixing the labels or the host's channel naming.
  3. To flip it in the gateware instead, change `pcm_lrck <= ~right_half;` to
     `pcm_lrck <= right_half;` in `fpga/application/pcm1802Slave.v`. Then
     `tb_pcm1802Slave` and `tb_audioCapture` will fail by design: they assert the datasheet
     order. Swap their expected left and right, and update the spec's *Changes from the fork*
     note. Timing is unaffected, because LRCK still changes at the same instants.

#### 4. Level and noise (needs the decoder)
- **PCM1802** (full scale about 3 Vp-p single-ended, 24-bit two's complement):
  - A 1 kHz tone at −20 dBFS (about 0.3 Vp-p) should peak near ±838,000 counts.
  - Inputs shorted: the noise floor should be far below −90 dBFS. The datasheet gives 105 dB
    dynamic range typical. The mean should be about 0 with BYPAS low (HPF on).
- **ADC128S022** (12-bit unsigned, mid-scale 2048):
  - 1 Vp-p should give about ±620 counts.
  - Expect a noisy floor; the fork reported about −40 dB.
  - There is no anti-alias filter. When decimating, its Nyquist is 19.5 kHz.
  - Its left and right are sampled 256 slots apart: 6.4 µs at 40 Msps, 12.8 µs decimating.
    That is an inter-channel delay (about 23° at 10 kHz at 40 Msps).
- **Look for:**
  - Single-sample spikes: tearing, which the per-frame snapshot should prevent.
  - Tones at SCLK/BCK aliases.
  - DC on the PCM.
  - Clipping at less than the expected input level.

#### 5. A decimation-rate change
- **Do:** ideally change rate mid-capture. If the application does not allow that, make two
  captures at different rates without a power cycle between them.
- **Expect:**
  - The frame stream and counter unbroken across the change; the decoder reports no break.
  - The audio rate halves or doubles.
  - Possibly a click, or a few frames of bad audio, right at the switch. Simulation shows one
    ADC128S022 SCLK cycle outside its 40–60% duty specification, and the PCM1802 datasheet
    recommends a power-down when fs changes.
  - The PCM1802 recovers by itself within a few tens of ms.
- **Failure:** a counter or sync break at the switch is a gateware bug. PCM1802 audio that
  stays zero after the change means it never resynchronised; report it, because PDWN is tied
  high on both boards so the gateware cannot cycle it.

#### 6. PCM1802 straps: module vs custom board
- **Required:** MODE1 = MODE0 = 0 (slave), FMT1 = FMT0 = 0 (24-bit left-justified),
  **FSYNC high**, **PDWN high**, OSR low. The gateware does not drive FSYNC; in slave mode the
  part only shifts data while FSYNC is high, and the pin has no internal pull-down.
- **Common module:** per the fork's README, wire 3.3 V to the **PDW and FSY** pins and leave
  the FMT, MODE, OSR and BYPAS pads open. Their internal 50 kΩ pull-downs make them low.
- **Fork custom board:** solder jumper `JFSYNC1` (bridged by default) ties FSYNC to 3.3 V, and
  PDWN is tied to 3.3 V on the PCB. Leave the FMT, MODE, OSR and BYPAS jumpers open. Its
  header J2 is JP3 numbered from the other end; the connections match this gateware's pins.
- **Failure:** FSYNC low or floating gives DOUT stuck low (all-zero PCM audio) or noise. PDWN
  low gives no DOUT at all.

#### 7. Start-up silence
- **Expect:**
  - After power-up (the FX3 releasing the FPGA's reset), the PCM1802 outputs zeros for about
    60 ms at 78.125 kHz, or 115 ms decimating: 1024 SCKI cycles plus 4480/fs.
  - The very first frame's audio is zero.
  - In the second frame, the ADC128S022 left is zero and right is the first conversion, which
    may be of the wrong input.
  - A capture started later than that sees none of this.
- **Failure:** PCM audio that stays zero well past about 0.2 s points at test 6 (straps), or
  at SCKI not reaching the converter.

---

### 4. Design choices, and open questions

**Choices made:**
- **The converters are timed from the generator's frame slot**, not from counters of their
  own. They cannot drift, and frame N always carries what was converted in frame N−1.
- **They are ticked by the post-decimator capture enable**, so the audio rate follows the RF
  rate and there is one stereo sample per frame at both rates.
- **One 80 MHz clock.** The converter clocks are register outputs, and inputs are registered
  every clock and read at fixed slots. That is why the SDC false-paths the audio pins, with
  the margins argued in the SDC and module headers.
- **One snapshot of all audio per frame**, so a value's slots can never come from two
  different samples.
- **LRCK high = left**, per the datasheet. This deviates from the fork and from the original
  brief.
- **ADC128S022:** 16 rising edges per conversion; CS high for 4 slots between conversions
  while SCLK keeps running; IN0 and IN1 alternate using the part's one-frame address pipeline.
- **`FramedFormat` parameter.** Both formats are always built and a mux at the output picks
  one, so one lint run covers both with no waivers. Upstream `tb_dataGenerator` is unchanged;
  it passes, with four iverilog dangling-port warnings.
- **The first word after reset is slot 0.** The fork had one extra word before it.
- **Four reserved slots**, held as one 24-bit word, ready for a status input.

**Open questions for you:**
1. **PCM1802 channel order:** keep the datasheet order (VINL in the left slots), or
   replicate the fork? And should the host flag fork-era captures as channel-swapped? Decide
   after test 3.
2. **Format identification:** no register says the gateware is framed, so the host detects
   the sync pattern. Do you want a `BUILD_FLAGS` bit or a register for it? That is a protocol
   change touching the host and the gateware, and possibly the FX3 relay.
3. **FSYNC:** keep relying on the board strap, or drive it from a spare JP3 pin as well? The
   latter would need a wiring change.
4. **ADC128S022 inter-channel delay** (6.4 or 12.8 µs): correct it in the host, or document
   it?
5. **Rate changes:** accept the transient, or mute or flag audio for a frame or two around a
   `DECIMATION` change?
6. **If timing slack is negative:** approve the lookahead pipelining described in §1.
7. **Documentation:** TESTING.md (§4.6 counts, and §5 should add frame and counter
   continuity for framed captures) and AGENTS.md §5.3 ("four port names") need updating; they
   were out of scope here.
8. **Authorship:** the commit author is `derheilendelotus <derheilendelotus@gmail.com>`,
   because the session's configured identity was a tool name. The new modules credit
   *2025-2026 Jonas Czech* and the tests *2026 Jonas Czech*. Amend either if wrong.

## Part B: SDRAM capture buffer gateware

Commit `eb3def8` on `master`, on top of the audio gateware (`14486a4`). The design is written up in `fpga/application/sdram-capture-buffer.md`. The status
word the stream carries is defined in `fpga/application/framed-sample-format.md`, section
"Status word". **Nothing here has been compiled by Quartus or run on hardware.** Everything
below is what has to happen before it can be trusted.

The application image now sends the **framed** sample format. Bits 9:0 are unchanged, so
`--analyse-test-data` works as before. A host without the framed-format decoder, though,
reports every capture as broken, so the bench tests below need the `ddd-gui` build that has
that decoder (commit `d056fd3`).

### 1. Build and read the reports

```bash
nix develop .#fpga-quartus      # x86_64-linux only, multi-GB first fetch
./fpga/build-local.sh           # copies to build/, compiles both images
```

Or, with Quartus Prime Lite 25.1 installed by hand and on `PATH`, run the same
`./fpga/build-local.sh`. Never compile inside `fpga/application/`, because it rewrites the
`.qsf`. Reports are under `build/application/` (`DomesdayDuplicator.fit.rpt`,
`.sta.rpt`, `.map.rpt`).

| Where | What to check | Expect |
| --- | --- | --- |
| Fit summary | fits; M9K | about 40 of 66 (32 `buffer.v` + 4 + 4 for the two FIFOs; more if Quartus put the decimator's delay line in RAM) |
| Fit summary | logic elements | upstream plus about 600 to 900 |
| Fit summary | PLLs, global clocks | 1 PLL; 2 more global clocks than before |
| Map report, RAM summary | `ingress_fifo` and `egress_fifo` inferred as M9K, simple dual port, dual clock | if they landed in logic elements instead, timing breaks and the CDC constraints are wrong; stop |
| Fitter, Resource Section, *Input/Output/Output Enable Registers* (I/O cell placement) | every `DRAM_ADDR/BA/CAS_N/CKE/CS_N/DQM/RAS_N/WE_N/DQ` output register, every `DRAM_DQ` OE register and input register is in its I/O cell | any one not packed: look for "fast register ignored" warnings and report it; its timing is then routing-dependent |
| Fitter, PLL Usage | `pll_generator_0`: clk[0] 80.000 MHz phase 0; clk[1] 120.000 MHz; clk[2] 120.000 MHz with a phase of about −3.5 ns (Quartus rounds to its step, about 0.13 ns; it may print it as a positive angle, about 209°) | anything else: check `applicationPll.v` |
| Warnings | PLL output driving the `DRAM_CLK` pin through a non-dedicated route | expected, as on Terasic's own designs |

**TimeQuest** (`.sta.rpt`, or `quartus_sta DomesdayDuplicator` then the GUI):

| Check | Expect |
| --- | --- |
| Setup and hold for `pll1\|clk[0]` (80 MHz) and `pll1\|clk[1]` (120 MHz), all corners | all slacks positive. The 120 MHz domain is the new risk; the controller's decode and the FIFO count compares are the long paths |
| SDRAM outputs: `report_timing -to [get_ports {DRAM_*}] -setup` and `-hold` | estimate: setup about +1 to +3 ns, hold about +0.5 to +1.5 ns |
| SDRAM inputs: `report_timing -from [get_ports {DRAM_DQ[*]}] -setup` and `-hold` | estimate: setup about +0.5 to +2 ns (setup relationship about 11.8 ns because of the multicycle), hold about +2 to +3 ns (relationship about +3.5 ns) |
| CDC: `report_timing -to [get_registers {sdram_buffer_0\|*_meta*}]` and `-from [get_registers {sdram_buffer_0\|status_hold_register[*]}]` | each path analysed against the 8.000 ns max delay with several ns of slack; hold not analysed |
| `report_sdc -ignored` (Ignored Constraints) | none of the SDRAM or CDC constraints listed. A pattern that matched nothing is a renamed register and must be fixed |
| `check_timing` and `report_ucp` (Unconstrained Paths) | nothing new compared with upstream. In particular, no other path between clk[0] and clk[1]: any such path is a bug |
| Metastability / Synchronizer report | the `*_meta`→`*_sync` chains recognised as synchronizers |

The input and output delays in the SDC are the datasheet's −7 figures plus a guessed
0.1–0.5 ns of board trace each way (`sdram_trace_min/max` in the SDC). If you know the real
trace lengths, put them there.

#### Adjusting the `DRAM_CLK` phase

Edit `altpll_component.clk2_phase_shift = "-3500"` in `fpga/application/applicationPll.v`
(ps; negative means `DRAM_CLK` leads) and rebuild. Change nothing else.

| Symptom | Direction |
| --- | --- |
| SDRAM **input setup** or **output hold** slack negative | more negative (for example −3750, −4000) |
| SDRAM **output setup** or **input hold** slack negative | less negative (for example −3250, −3000) |

The estimated valid window is −4.9 to −2.6 ns. If both directions fail, the window is
narrower than estimated; report the four slacks.

If timing passes but the board misbehaves (B1/B2 below fail with corrupted data rather than
gaps), sweep −2750 … −4250 in 250 ps steps. Run B2 and a 200 ms stall (B3) at each step,
and pick the middle of the passing range. Record the PLL Usage report's achieved phase for
each step.

### 2. Load it without touching the flash

```bash
cd build/application && quartus_pgm DomesdayDuplicator_write_sof.cdf
```

This is volatile JTAG configuration over the DE0-Nano's on-board USB-Blaster. Flash, factory
image and boot block are untouched, and a power cycle restores whatever was there. Restart
the capture application afterwards (the FPGA reconfigured under it). `jtagd` needs the
repository's udev rule (`fx3/programmer/configs/70-domesday-duplicator.rules`).

### 3. Bench tests, in order

Use test mode throughout unless stated (Settings in the GUI; TESTING.md §5). The pass
condition for every run is `--analyse-test-data` exit code 0. Note that the capture
application stops a capture at the first sequence break, so a loss ends the run, and that
is the expected failure signature.

**B1, SDRAM comes up.** Each frame of the stream carries the status word in slots 36, 37,
46 and 47 (S[23:18], S[17:12], S[11:6], S[5:0]):

| Field | Expected in a capture |
| --- | --- |
| S[23:20] version | 1 in every frame (0 would mean gateware without the SDRAM buffer) |
| S[18] initialised | 1. The SDRAM is ready about 210 µs after the FPGA leaves reset, long before any capture |
| S[19] path in use | 1 in every frame the application keeps. The first few dozen frames after a start come out of `buffer.v`'s bypass contents with S[19] = 0, but they fall inside the application's start-of-stream discard |
| S[17] lost | 0 unless a stall exceeded capacity (B3) |
| S[15:0] fill | 0 or 1 in steady state; rises during a stall, about 78 rows per ms at 40 MSPS |

- With the GUI's SDRAM display (the Device SDRAM bar in the Statistics panel, commit
  `5a4a84f`): it should show the buffer in use, no loss, and a fill near zero.
- Failure: S[18] = 0 means the SDRAM never initialised (check the PLL lock, the pins and the
  power-up sequence in SignalTap). S[19] = 0 throughout a capture means `collect_data` is not
  reaching `GPIO1[23]` or the flush never completes. Either way the capture is running
  bypassed, with upstream's 2 ms stall tolerance.

*Without the GUI display*, read the raw 16-bit words off the wire. The capture files keep only
bits 9:0, so they cannot be used. Capture a few seconds of the bulk IN endpoint (0x81) while a
capture runs, and decode it:

```bash
sudo modprobe usbmon
lsusb -d 1209:2347                     # note the bus number, e.g. 002
sudo tshark -i usbmon2 -s 0 -a duration:3 -w /tmp/ddd.pcapng     # during a capture
tshark -r /tmp/ddd.pcapng -Y 'usb.endpoint_address == 0x81 && usb.urb_type == "C"' \
    -T fields -e usb.capdata > /tmp/ddd.hex
python3 -I decode_status.py /tmp/ddd.hex
```

where `decode_status.py` is:

```python
import sys
data = bytearray()
for line in open(sys.argv[1]):
    data += bytes.fromhex(line.strip().replace(":", ""))
meta = [data[2 * i + 1] >> 2 for i in range(len(data) // 2)]   # bits 15:10 of each word
def lsb_first(i, n):
    v = 0
    for s in reversed(range(n)):
        v = (v << 6) | meta[i + s]
    return v
start = next(i for i in range(min(1024, len(meta) - 8)) if lsb_first(i, 8) == 0xFEDCBA987654)
for f in range(start, len(meta) - 511, 512):
    if lsb_first(f, 8) != 0xFEDCBA987654:
        print("frame at word", f, "has no sync: a capture gap or a truncated URB"); break
    s = (meta[f+36] << 18) | (meta[f+37] << 12) | (meta[f+46] << 6) | meta[f+47]
    print(f"word {f}: version {s >> 20} active {s >> 19 & 1} init {s >> 18 & 1} "
          f"lost {s >> 17 & 1} fill {s & 0xFFFF} rows")
```

usbmon may truncate large URBs. If frames lose sync partway through a transfer, compare
`usb.urb_len` with `usb.data_len` in Wireshark. SignalTap on `sdram_buffer_0|status_fill`,
`status_initialised` and `path_state` is the in-FPGA alternative.

**B2, clean integrity run.** 60 s, then 30 min, 40 MSPS, no induced stalls.
- Pass: zero breaks.
- End-of-run log line: `peak back pressure 0%, peak 8194 words, 0 overflows, 0 samples
  dropped`. A peak of 8194 is expected in SDRAM mode, because the path holds `buffer.v` at
  one packet.
- Failure: any break, or overflows above 0, in a run the host kept up with. That means the
  SDRAM path is corrupting or losing data: check the phase (above) and refresh (B6).

**B3, induced host stalls.** The primary method is the test-only stall injection (commit
`e6818f6`; libusb backend only, so Linux or macOS, not the Windows/WinUSB build). After all
in-flight transfers complete, it keeps zero transfers queued for the requested time,
periodically, and logs the zero-queue interval it actually measured. See Part C §3.7 for its
full syntax:

```bash
ddd-gui --headless --start-capture --duration-limit 120 --inject-usb-stall 100@10
# or: DDD_INJECT_USB_STALL=100@10 ddd-gui --headless --start-capture --duration-limit 120
```

That is 100 ms with nothing queued, every 10 s. Use the logged measured interval, not the
requested one, as *T* below. Go up one capture per length: 10, 50, 100, 200, 300, 380 ms,
then 500 ms and 1 s. Expected with *T* in ms at 40 MSPS (capacity about 420 ms, plus the FX3's
own few ms of buffering, here *t_FX3*):

| *T* | Stream | In-band fill peak (S[15:0]) | S[17] | Telemetry |
| --- | --- | --- | --- | --- |
| ≤ 2 ms | no break | 0 | 0 | 0 overflows. Upstream gateware also survives this, so it proves nothing about the SDRAM |
| 10 – 380 ms | no break | about (*T* − *t_FX3* − 0.3) × 78 rows: about 7,500 for 100 ms, 23,000 for 300 ms, 29,500 for 380 ms | 0 | 0 overflows, peak 8194 words, near-full 0 |
| 500 ms | one gap; the live check stops the capture there | 32768 (full) | 1 from the loss onwards | 1 overflow; dropped ≈ (*T* − 420 − *t_FX3*) × 40,000 samples (≈ 3 M) and equal to the gap `--analyse-test-data` finds |
| 1 s | as for 500 ms | 32768 | 1 | 1 overflow; ≈ 23 M samples dropped |

- During a loss, `bufferError` raises the LED pattern `0x55`.
- Failure: a break below about 400 ms; a fill that does not rise with *T*; more than one
  overflow event for one stall; dropped ≠ analysed gap; S[17] set without a loss; or S[17]
  surviving into the next capture (a new start must clear it).
- Fallback without the injection option: freeze the whole application with
  `kill -STOP $pid; sleep 0.1; kill -CONT $pid`. That stalls the host for at least the sleep
  plus scheduling jitter, so the expected numbers are only approximate.

**B4, drain rate.** With `--inject-usb-stall 300@10`:
- After each stall the in-band fill should fall at about 72 rows per ms (37 Mwords/s net),
  from about 23,000 rows to 0 in about 320 ms.
- The host should see about 155 MB/s (77 Mwords/s) from the device during that drain, then
  80 MB/s again (application rate display, or usbmon byte counts).
- Simulation measured 77.4 Mwords/s delivered and 37.5 Mwords/s net.
- Failure: a drain much slower than that. Either the host cannot take 155 MB/s (check the
  same host with a synthetic load) or the controller is idling; report the fill-versus-time
  curve.

**B5, `collect_data` behaviour.**
- Stop and start a capture 20 times in a row. Before some of the stops, freeze the app for
  200 ms. Expect every new capture to be clean after the app's start-of-stream discard: no
  stale data, no break.
- Old-host compatibility: any host path that reads the stream **without** sending vendor
  request `0xB5` must behave exactly like upstream gateware. In that case `collect_data`
  stays low and the SDRAM is bypassed, so a 50 ms stall must lose samples exactly as before.
  The current `ddd-gui` always sends `0xB5` (`kCollectionRequest`), so this needs a host
  tool that skips it, or a firmware build that never raises GPIO19. If neither is to hand,
  record it as not tested.

**B6, refresh soak.** In steady state a sample sits in the SDRAM for only about 13 µs, so a
plain soak hardly exercises refresh or retention.
- Run test mode for **1 hour with `--inject-usb-stall 300@10`**, so that rows sit in the SDRAM
  for hundreds of milliseconds about 360 times. Fallback: a `kill -STOP/-CONT` loop of 300 ms
  every 10 s.
- Pass: zero breaks; 0 overflows; S[17] = 0 throughout; the fill peaking near 23,000 rows on
  every stall and back to 0–1 between them.
- Repeat once at 20 MSPS (`--sample-rate 20`), where capacity doubles to about 0.84 s and the
  same stall peaks near 11,500 rows.
- A refresh or retention fault shows as ramp breaks or corrupted words inside data that had
  been sitting in the SDRAM, which `--analyse-test-data` reports by offset; the fill at that
  point says how long it had been there.

### 4. Design choices, and open questions

Choices (details in the design page):
- **120 MHz controller clock.** At 80 MHz the SDRAM carries about 78 Mwords/s, less than
  the 80 needed in steady state. One PLL (`applicationPll.v`, application image only;
  `fpga/common/IPpllGenerator.v` untouched, so no re-provisioning), with all 80↔120
  crossings through Gray FIFOs and synchronisers, constrained by `set_max_delay`.
- **Whole 512-word rows,** full-page bursts, one bank open at a time, refresh every 7.5 µs
  at operation boundaries. Simple sequences at fixed steps, checked by a protocol-checking
  model.
- **Flush by draining, with a four-phase handshake,** never by resetting the path. Bypass
  while `collect_data` is low, so a host without `0xB5` gets upstream behaviour.
- **`buffer.v` held at 8194 words.** Its register telemetry then reads as healthy as
  upstream's. The stall depth is reported by the stream status word's ring fill, not by
  `TELEM_USED_PEAK`. Losses are still counted in `TELEM_OVERFLOWS`/`TELEM_DROPPED` and
  raise `bufferError`.

Open questions:
1. `collect_data` (GPIO19) is now functional. The FX3 already drives it per its documented
   meaning, so no firmware or host change is needed, but this is a use of the FX3 ↔ FPGA
   control protocol and AGENTS.md §13 asks for it to be acknowledged.
2. The phase shift and every FPGA I/O delay in the budget are estimates (section 1).
3. The SDRAM speed grade on these boards is unconfirmed. The design assumes −7
   (the slowest), so a faster part only adds margin.
4. A reset from the FX3 in the middle of an SDRAM burst (it only drives nReset at its own
   boot) re-runs the 200 µs power-up with a row left open, which breaks tRAS max for that
   one row. That only loses data that is about to be discarded anyway; noted, not handled.
5. With the SDRAM in use, the register instrument's peak no longer shows how close a stall
   came to a loss. The stream's status word does, and the GUI's Device SDRAM bar shows it.
6. Simulation time: the four new benches add about 2.5 minutes to `run-sim.sh` (the
   controller's 8 ms soak and the end-to-end bench dominate).
7. The status word's fill is sampled when a frame enters the path, not when it leaves.
   Across frames it shows the backlog each sample queued behind, which is what "how close did
   this come" needs. It is not the backlog at the instant the host receives the frame.

## Part C: Capture application (ddd-gui): audio, SDRAM status and USB stall injection

Three commits on `master`:

| Commit | Subject | Meant as |
| --- | --- | --- |
| `d056fd3` | ddd-gui: capture the audio gateware's framed stream and its audio | PR 1 |
| `5a4a84f` | ddd-gui: show the gateware's SDRAM buffer fill level | PR 2 |
| `e6818f6` | ddd-gui: add a host-side USB stall injector for testing the device's buffering | PR 2 (or its own) |

All three build with the clang-format and clang-tidy gates and pass `ctest -LE hil`
(1980, 1999 and 2026 tests). **Nothing has run against a real device.** Every bench step
below is unverified until somebody does it.

The commits are authored as `derheilendelotus <derheilendelotus@gmail.com>`, because the
session's own git identity named a tool, which AGENTS.md Rule 2 rules out. Change it with
`git rebase -r 0f015fa --exec 'git commit --amend --no-edit --reset-author'` (after setting
your own `user.name`/`user.email`) before opening a PR.

---

### 1. Build and run

```bash
export NIX_CONFIG="experimental-features = nix-command flakes"
cd DomesdayDuplicator-audio-ADC   # the repository root
nix develop .#ddd-gui --command bash -c \
  'cmake -B ddd-gui/build -S ddd-gui && cmake --build ddd-gui/build -j4'

# Tests (about 6 minutes, most of it the three soak tests). Run serially: two timing
# tests, upstream's and the new framed one, exceed their bound when oversubscribed (-j8).
nix develop .#ddd-gui --command ctest --test-dir ddd-gui/build -LE hil --output-on-failure

# The GUI, with the debug log in a file (the capture's own account is at debug level)
nix develop .#ddd-gui --command ./ddd-gui/build/bin/ddd-gui -d --log-file /tmp/ddd.log

# Headless
nix develop .#ddd-gui --command ./ddd-gui/build/bin/ddd-gui --headless --start-capture \
  --capture-directory /tmp/caps --capture-name bench1 --duration-limit 60 \
  --audio-source both --log-level debug --log-file /tmp/ddd.log
```

Device permissions: `fx3/programmer/configs/70-domesday-duplicator.rules` (or the NixOS
module). A first build takes about 25 minutes on 4 cores because clang-tidy runs on every
file.

### 2. What was added, defaults and where

| Setting | Default | Where | Persisted |
| --- | --- | --- | --- |
| **Audio**: None / Integrated converter (ADC128S022, 12-bit) / External converter (PCM1802, 24-bit) / Both converters | None | File → Settings… → Capture; `--audio-source none\|integrated\|external\|both`; settings key `capture/audio_source` | yes |
| **Continue after dropped samples** | off | File → Settings… → Capture; `--on-dropped-samples stop\|continue`; key `capture/continue_after_dropped_samples` | yes |
| **USB stall injection** (test only) | off | `--inject-usb-stall <ms>[@<period-s>][+<delay-s>]` or `DDD_INJECT_USB_STALL=…` | never |

- Audio applies to the next capture; Continue applies the next time monitoring starts (it is
  a pipeline option). Continue only affects framed streams: a sequence-counter stream still
  fails on its first mismatch.
- Stall plan: `300` = one 300 ms stall 5 s after streaming starts; `300@10` = the first
  5 s in, then every 10 s from when each was due; `300@10+2` = the same, the first 2 s in. Stall 1–4000 ms (the pipeline's 5 s stall watchdog would end longer ones);
  the period must exceed the stall. A malformed value refuses to start (exit 1) rather than
  running without stalls.

Statistics panel, new rows: **Device SDRAM** (bar), **Stream format**, **Sync losses**,
**Integrated audio**, **External audio**, **Audio files**, **USB stall test**. The
**Integrity** row gains "Resynchronised — samples have been lost and the capture carried on".

Files written beside a capture `<stem>.ddd.flac` (or `.ddd.s16`):

- `<stem>_audio_integrated_adc.s16` — headerless, signed 16-bit little-endian, interleaved
  stereo L/R. Value = (12-bit reading − 2048) × 16, as the fork wrote it. 4 bytes per frame.
- `<stem>_audio_external_adc.s24` — headerless, signed 24-bit little-endian (3 bytes),
  interleaved stereo L/R, as the converter delivered it. 6 bytes per frame.
- Rate = stream rate / 512: **78125 Hz** at 40 Msps, **39062.5 Hz** at 20 Msps (exact).
- The `.ddd.yaml` sidecar gains `capture.stream_format`, `capture.sync_losses` (framed only),
  an `audio:` section (requested, per file: name, converter, encoding, channels,
  bits_per_sample, sample_rate_hz, samples per channel, bytes, clipped_samples, peak_dbfs, or
  `not_recorded` with the reason), and — only for a stall-injection run — a `TEST CAPTURE`
  comment at the top plus `capture.usb_stall_injection` and `capture.injected_usb_stalls`.
- An existing audio file is never overwritten (`… (1).s16`); audio files follow the capture
  when the duration is appended to its name.

### 3. Bench tests

Keep the debug log for every step (`-d --log-file …`). Lines to look for are quoted.

#### 3.1 Standard upstream gateware (no audio): nothing may change

1. Settings: Audio = Both, Continue = off. Start monitoring.
2. Expect: Stream format "Sequence counter — no audio"; Integrity "Verified — no samples
   lost"; Integrated/External audio "—"; Audio files "Asked for, but this gateware sends no
   audio"; Device SDRAM "Not reported by this gateware". Log: "The stream carries the
   sequence counter, so it has no audio in it".
3. Capture 60 s. Expect the status bar notice "Audio was asked for, but this device's
   gateware does not send any…", no `_audio_` files, sidecar `"stream_format": "sequence
   counter"`, `"not_recorded": "This gateware does not send audio…"`, no `sync_losses`.
4. Repeat starting the capture straight from idle (no monitoring first): the audio files are
   created and then removed at the end ("Removed …, which the stream had no audio for").
5. Test mode capture + `ddd-gui --analyse-test-data <file>` → exit 0, as before.
6. Failure looks like: the capture failing or refusing to start, any `_audio_` file left
   behind, Stream format "Framed", or a different RF file size/duration from before.

#### 3.2 Framed audio gateware, 40 Msps

1. Audio = Both. Feed a 1 kHz tone into the PCM1802 **left** input only, and a different
   level/tone into ADC128S022 IN0 (left) only, biased to ~1.65 V.
2. Monitor. Expect: Stream format "Framed — audio at 78125 Hz"; Integrity "Verified";
   Sync losses "None"; External audio "L −x dBFS, R silent-or-low (…)"; Integrated audio
   similarly. Levels must follow the input (turn it up until "clipped" counts rise). Log: "The
   stream is framed: validating its sync patterns and counter, with audio at 78125.0 Hz".
3. Capture exactly 60 s (`--duration-limit 60`). Expect both files with sizes
   ≈ 60 × 78125 × 4 = 18,750,000 bytes (s16) and × 6 = 28,125,000 bytes (s24), within a frame
   or two of RF samples / 512 × bytes-per-frame; the sidecar's `audio.*.samples` equal
   bytes / 4 and bytes / 6, `sample_rate_hz: 78125`, `sync_losses: 0`.
4. Listen/inspect (section 4). The tone must be on the left channel of both files.
5. Failure looks like: Stream format staying "—" or "Sequence counter" (detection failed —
   the log's mismatch message then says whether a sync pattern was seen); a sequence-counter
   mismatch immediately on start; audio on the wrong channel; pitch wrong (rate wrong); hum or
   a constant (wrong slot positions); files of very different length from the RF.

L/R note from the gateware port: PCM1802 **left is now LRCK high** (datasheet left-justified
convention). The fork used LRCK low = left, so fork captures probably had the PCM1802 channels
swapped; a mismatch against old fork files is expected, a mismatch against the physical input
is a bug. Frame N carries audio produced during frame N−1 (a fixed one-frame, 12.8 µs at
40 Msps, audio-to-RF offset nothing here corrects), and the first frame after an FPGA reset
carries zero audio — a single zero sample at the very start of a session is expected.

#### 3.3 Framed audio gateware, 20 Msps

Sample rate 20 Msps in the Capture panel (or `--sample-rate 20`). Expect "Framed — audio at
39062.5 Hz", file sizes halved for the same duration, `sample_rate_hz: 39062.5` in the
sidecar, and the tone at the right pitch when converted at 39062.5 Hz. The PCM1802 has no
anti-alias filter at this rate (Nyquist 19.5 kHz).

#### 3.4 Induced data loss, Continue off and on

Without SDRAM gateware a host stall of more than ~2 ms loses samples. Easiest repeatable
method: `--inject-usb-stall 50@10` (section 3.7). Alternatives: `kill -STOP <pid>; sleep 0.1;
kill -CONT <pid>`, or heavy load (`stress-ng --cpu 0 --io 4`) with a small buffer queue.

1. Continue **off**: the capture stops with "Capture stopped: sequence mismatch" and a detail
   starting "Framed stream sync pattern missing … / counter discontinuity …", ending "To keep
   capturing past a loss like this, turn on continuing after dropped samples". The partial
   files (RF and audio) are finalised and readable.
2. Continue **on**: the capture carries on. Sync losses counts one per loss; Integrity reads
   "Resynchronised…"; the log has "The stream lost samples and was resynchronised (…)"
   (first loss at once, then at most one line per 5 s) and at the end "Framed stream: N sync
   losses, each a place where samples are missing". Sidecar: `sync_losses: N`,
   `sequence_check: "resynchronised"`. Audio files are short by the lost frames (no padding
   is inserted).
3. With the **original** gateware the same stall fails the capture with "Sequence counter
   mismatch" whatever Continue says — expected.
4. Failure looks like: Continue on but the capture stopping; more than one loss counted per
   stall; a loss not counted; garbled audio around a loss (audio is only kept once the first
   counter value after it checks out).

#### 3.5 Test mode and the test-data analysis

Framed gateware, test mode on, 60 s capture: Integrity "Verified", sidecar
`test_pattern_passed: true`, `ddd-gui --analyse-test-data <file>` exits 0. Repeat at 20 Msps.
With an injected loss and Continue on, the live ramp check still stops a test-mode capture
("The device's test ramp broke…", kVerificationError): Continue does not make a broken ramp
pass, by design. Failure: any ramp break without an induced loss.

#### 3.6 SDRAM status display (SDRAM gateware)

1. Monitor at 40 Msps with no stall. Expect Device SDRAM "now 0.0% (0.0 MiB, 0 ms), peak
   ~0.0% …" (fill 0–1 rows), tooltip "Stream passing through it: yes. Initialised: yes.
   Overflowed since collection started: no." Log once: "The gateware reports an SDRAM capture
   buffer of 32.0 MiB, 419 ms of stream at this rate; the stream is passing through it".
2. `--inject-usb-stall 200@10`: the peak rises to roughly (200 − drain/FX3 slack) × 78
   rows ≈ 40–48 % (13–15 MiB, ~170–200 ms) and "now" drains back to ~0 within a few hundred
   ms of each stall; zero sync losses. Repeat 380 ms: ~90 % peak, still no loss.
3. `--inject-usb-stall 600@10`: Device SDRAM reads "Overflowed, samples dropped — …", peak
   100 %; log warning "The device's SDRAM buffer overflowed…" once; with Continue off the
   capture stops at the first stall; with Continue on, exactly one sync loss per stall.
4. 20 Msps: thresholds double (~0.8 s); the ms figures for a given fill double too.
5. Audio-only framed gateware and the original gateware: "Not reported by this gateware",
   bar at 0, no SDRAM lines in the log.
6. End of run, log: "Device SDRAM: peak X% (… MiB, … ms of stream), no overflow" (info) and a
   debug line with the fill history.
7. Failure: fill not rising during a stall, not draining after, overflow flagged below ~0.4 s,
   no overflow flag above it, the row present for gateware without the buffer.

#### 3.7 USB stall injection itself (libusb only)

`ddd-gui --headless --start-capture --duration-limit 120 --inject-usb-stall 100@10`
(or `DDD_INJECT_USB_STALL=100@10 ddd-gui` for the window).

- Start: warnings "TEST: USB stall injection is on for this run (100 ms every 10 s, the
  first 5 s in)…" and "USB STALL INJECTION IS ON: …". Status bar: "Monitoring — TEST: USB
  stall injection on (…)". Statistics "USB stall test": "TEST — ON: …; N injected so far".
- Every stall: "Injected USB stall N at <UTC ms>: asked for 100 ms; the K transfers in
  flight took D ms to complete, then nothing was queued for Z ms". **Z must be the requested
  time to within ~1 ms**; D is how long the transfers already queued took to fill, up to
  ~150 ms with the default 12 MB transfer queue at 80 MB/s — the device-side stall starts
  only when D ends, by design.
- Stop during a stall (press Stop capture / `--stop-capture` mid-stall): the run ends within
  ~100 ms with "The capture was stopped during an injected USB stall; nothing held back was
  resubmitted"; no hang.
- Sidecar: top comment "TEST CAPTURE…", `usb_stall_injection: "100 ms every 10 s, the first
  5 s in"`, `injected_usb_stalls: <count while the file was open>`.
- Expected outcomes: SDRAM gateware with stalls below ~0.4 s at 40 Msps (~0.8 s at 20 Msps):
  zero sequence breaks, in-band fill rises then drains; above that, exactly one contiguous
  drop per stall. Upstream gateware (no SDRAM): any stall above roughly 2 ms drops samples.
- On Windows (WinUSB) nothing is injected: the log says "USB stall injection was asked for
  … but is not available with the WinUSB backend", the panel and sidecar say it was asked for
  and not applied. Reason: the WinUSB loop's underflow probe fails a capture the moment a
  request completes before its successor is queued, which is exactly what a stall arranges.
- The FPGA telemetry poll (a control transfer on EP0) keeps running during a stall; only the
  bulk IN endpoint is idle.

### 4. Inspecting the audio files

```bash
R=78125   # 39062.5 at 20 Msps
sox -t raw -r $R -e signed-integer -b 16 -c 2 -L X_audio_integrated_adc.s16 integrated.wav
sox -t raw -r $R -e signed-integer -b 24 -c 2 -L X_audio_external_adc.s24 external.wav
sox integrated.wav -n stat          # levels, DC; sox --i integrated.wav for duration
sox external.wav -n remix 1 stat    # left only; remix 2 for right

ffmpeg -f s16le -ar 78125 -ac 2 -i X_audio_integrated_adc.s16 integrated.wav
ffmpeg -f s24le -ar 78125 -ac 2 -i X_audio_external_adc.s24 external.wav
# ffmpeg's -ar is an integer: use 39062 at 20 Msps (0.001 % slow), or sox, which takes 39062.5.
```

Quick sanity: duration = bytes / (4 or 6) / rate ≈ RF duration in the sidecar. The
integrated file's samples are multiples of 16 (the 12-bit value × 16), so its full scale is
−32768…32752.

### 5. Fork features

Ported: framed-stream sync and counter validation; resync and continue past a loss (the
fork's "stop on dropped samples", inverted, default changed to stop); sync-loss count; audio
source choice; `.s16`/`.s24` writers with the fork's file names and scaling; audio level
statistics (now per converter, in dBFS, both shown, instead of the fork's one combined set
preferring the PCM1802 and a normalised "mean amplitude").

Differences from the fork worth knowing: a counter discontinuity counts as a loss and
resynchronises (the fork silently adopted the new counter value); a frame's audio is only
kept once its first counter value checks out; detection is automatic (the fork assumed the
framed format whenever audio was selected).

Not ported:

- **Stop capture when RF amplitude drops for N seconds** (fork `mainwindow` auto-stop). It is
  missing upstream, but it is a capture-control policy unrelated to audio, needs its own
  threshold semantics against upstream's RMS/level figures and its own UI, and would sit
  beside upstream's existing "stop the capture when the player stops" coupling. Better as a
  separate PR.
- **WinUSB/libusb toggle** (fork configuration dialog, which also forced stop-on-dropped
  with WinUSB). Upstream chooses the backend at build time; there is nothing to toggle.
- **Connection retry hack** — only a VS Code task change in the fork.
- **"Fix lag"** — removed the logo from the old window's layout; no equivalent upstream.
- The fork's audio amplitude graph (a synthetic buffer fed to a second amplitude widget).

### 6. Design choices

- Detection happens once, on the first buffer after the opening discard, read-only and
  within its first 3,072 samples: a sync pattern followed by two whole frames that agree.
  Anything else goes to upstream's `SequenceValidator` untouched. A sequence-counter stream
  cannot match (its top bits are constant for 65,535 samples). A first buffer under ~3 KiB
  cannot be called framed; no real ring has slots that small.
- `StreamValidator` dispatches; `FramedStreamValidator` is single-pass like upstream's and
  measured at ~4 ms per 2 MB buffer (upstream's 8 ms in the same run; budget 26 ms).
- Audio rides the RF sink (`CaptureSinkWithAudio`) so both start and stop on the same buffer;
  files are opened on the GUI thread at capture start, written synchronously on the
  processing thread (8–12 KiB per 2 MB buffer), removed again if the stream proves to have no
  audio.
- `kResynchronised` is a new, sticky sequence state; a file opened after a loss records
  `running` with `sync_losses: 0`.
- SDRAM fill is logged and displayed but not written to the sidecar, following upstream's
  rule that buffer depths are about the session, not the recording.
- Stall injection: scheduling is pure engine code (`usb_stall_injection.*`, unit tested); the
  libusb hook holds back completed transfers in completion order and resubmits them in that
  order.

### 7. Only hardware can confirm

Everything in section 3, in particular: detection on real framed gateware; the slot
positions and bit order of both converters; L/R; the audio rate and continuity over a long
capture; that the validator's view of a real loss matches `--analyse-test-data`; the SDRAM
word's bit layout and fill numbers; that an injected stall's zero-queued interval is what the
device sees; stop-during-stall on real libusb; and nothing at all on Windows/macOS (the
WinUSB change is a log line and was not compiled here).
