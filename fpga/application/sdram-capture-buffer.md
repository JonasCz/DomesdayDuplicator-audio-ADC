# The SDRAM capture buffer

The capture gateware puts the DE0-Nano's 32 MiB SDRAM between the sampling side and the FIFO
buffer the FX3 reads from, so that a stall on the USB host side is paid out of 0.42 s of
storage instead of 205 µs.

| | Without the SDRAM | With it |
| --- | --- | --- |
| Stall absorbed at 40 MSPS (80 MB/s) | ~2 ms: 205 µs in `buffer.v` plus the FX3's DMA buffers | ~0.42 s more: 32768 rows of 512 words |
| Where samples are lost | `buffer.v`, when full | the SDRAM path's ingress FIFO, when the ring is full |
| What reports a loss | `bufferError` (CTL_03) and the register telemetry | the same two, unchanged, plus a sticky bit in the stream's status word |

Sources: `sdramBuffer.v` (the path), `sdramController.v` (the SDRAM), `asyncFifo.v` (the
clock-crossing FIFO), `applicationPll.v` (the clocks). Tests: `tests/tb_asyncFifo.v`,
`tests/tb_sdramController.v`, `tests/tb_sdramBuffer.v`, against this project's own model of
the part, `tests/sdramModel.v`.

## Architecture

```
 halfBandDecimator -> dataGenerator             80 MHz system clock
                          |
                          | one word per sample (40 MSPS, or 20 decimated)
                          v
      +---------------- sdramBuffer -------------------------------------+
      |  bypass mux <---------------------------------------------+      |
      |     |  collect_data low, or path not ready                |      |
      |     |                                                     |      |
      |     +--> ingress asyncFifo (2048)  80 -> 120 MHz          |      |
      |                 |                                         |      |
      |          sdramController  ring of 32768 x 512-word rows   |      |
      |                 |         (120 MHz, IS42S16160B)          |      |
      |          egress asyncFifo (2048)  120 -> 80 MHz ----------+      |
      +-------------------------------------------------------------------+
                          |  held off at 8194 words
                          v
                 buffer.v (16384-word FIFO, data_available, bufferMonitor)
                          |
                 fx3StateMachine -> GPIF II -> FX3
```

`buffer.v` is upstream's, with three ports added (below). Its packet logic, its error flag
and its instrument are unchanged.

## Clocking, and why 120 MHz

Every sample goes through the SDRAM twice, once in and once out. In steady state that is
40 Mwords/s each way; after a stall the outbound side has to run as fast as it can to catch
up while the inbound side keeps going.

At the 80 MHz system clock one 512-word row costs about 520 cycles (ACT, 3 cycles to the
burst, 512 words, stop, precharge, 3 cycles of tRP), so the part carries
80 × 512 / 520 ≈ 79 Mwords/s before refresh, ≈ 78 after: less than the 80 Mwords/s the
steady state alone needs. At 120 MHz it carries ≈ 117 Mwords/s with refresh paid, which
leaves ≈ 77 Mwords/s for reading while 40 go in, so a backlog drains at ≈ 37 Mwords/s net.
The simulation measures 117.3, 77.4 and 37.5.

120 MHz at CAS latency 3 is inside the slowest IS42S16160B grade (-7: 143 MHz at CL3). The
grade fitted to a given DE0-Nano is not something this design depends on: every timing
figure is the -7's.

The clocks come from one PLL, `applicationPll.v`:

| Output | Frequency | Phase | Use |
| --- | --- | --- | --- |
| c0 | 80 MHz (50 × 8 / 5) | 0 | system clock, exactly what `IPpllGenerator` makes |
| c1 | 120 MHz (50 × 12 / 5) | 0 | SDRAM controller and its I/O registers |
| c2 | 120 MHz | −3.5 ns | driven onto `DRAM_CLK` |

`locked` holds both clock domains in reset with the FX3's `nReset`.

**Why there are two PLL files.** `fpga/common/IPpllGenerator.v` is compiled into the factory
image, which is frozen after provisioning (`fpga/factory/README.md`). Adding outputs to it
would change the factory image for a feature it does not have. The application image
therefore has its own PLL file, and the factory image keeps `IPpllGenerator` unchanged.
The instance is still called `pll_generator_0`, so the SDC's PLL paths keep their names.

**One PLL, still treated as asynchronous.** The 80 and 120 MHz clocks share a VCO, so their
edges have a fixed relationship. The design does not use it. Everything that crosses goes
through a Gray-pointer FIFO or a two-register synchroniser, and the SDC constrains those
paths by a bound rather than a relationship.

## The ring

The controller treats the part as a ring of 32768 rows of 512 words and moves whole rows,
oldest first. Ring row *r* is bank *r*[1:0], row *r*[14:2], so even the 32-row ring the
testbench uses reaches all four banks. There is no random access and no bank interleaving.

Every command is decoded from (state, step) and registered at the pins. All gaps are fixed
step numbers, rounded up from the −7 figures at 8.33 ns:

| | Datasheet (−7) | Cycles used |
| --- | --- | --- |
| tRCD | 20 ns | 3 |
| tRP | 20 ns | 3 |
| tRC | 67.5 ns | 9 (REF to next) |
| tRAS | 45 ns min, 120 µs max | 516 per row |
| tDPL | 14 ns | 2 |
| tMRD | 15 ns | 2 or more |

- **Row write:** ACT; WRITE at column 0 three cycles later as a full-page burst carrying the
  first word, then one word per cycle; BURST STOP on the cycle after the 512th word (the part
  ignores that cycle's data); PRECHARGE two cycles after the last word. DQM is high on the
  stop and the precharge, so the burst's wrap back to column 0 cannot write anything.
  519 cycles from one ACT to the next, the idle cycle between operations included.
- **Row read:** ACT; READ at column 0, full page; PRECHARGE 512 cycles after the READ. That
  is CL − 1 cycles before the last word is valid, which is the datasheet's rule for
  truncating a full-page read, so exactly 512 words come out. 518 cycles.
- **Capture:** the READ registered on controller edge *n* reaches the SDRAM just before edge
  *n*+1. The first word is valid at the pin late in the cycle before edge *n*+4, and the
  input register in the I/O cell captures it on that edge. A 4-stage delay of the 512-cycle
  read window therefore marks the captured words exactly. The SDC's input multicycle states
  the same timing.
- **Power-up:** CKE high and 25000 cycles (208 µs) of NOP with DQM high, then PRECHARGE ALL,
  eight AUTO REFRESH, then LOAD MODE REGISTER (`0x037`: full page, sequential, CL3, burst
  writes).

### Arbitration and refresh

Arbitration happens only between operations, never inside one, in this order:

1. refresh, if a credit is due
2. a flush in progress (see below): start nothing else
3. a row write, if the ingress FIFO holds at least 512 words and the ring is not full
4. a row read, if the ring holds a row and the egress FIFO has room for 512 words plus the
   last few still in the capture pipeline

Writes come before reads because a write that waits is a FIFO filling, while a read that
waits only delays the host.

A refresh credit is issued every 900 cycles (7.5 µs; the datasheet requires 8192 per 64 ms,
an average of 7.8125 µs). It is served at the next operation boundary. The longest
operation is 519 cycles, so a credit waits at most 4.3 µs and at most one is ever
outstanding. The model measured a longest gap between refreshes of 11.8 µs and a maximum
debt of one refresh, against an allowance of eight.

### FIFO sizing

- **Ingress, 2048 words.** It must cover the longest time a full row can wait for the
  controller. That worst case is a read row just started (518 cycles), then a refresh (9),
  then the write's own ACT-to-burst (4): about 4.45 µs, during which another 178 samples
  arrive. So the peak is about 700 words. 2048 leaves about 33 µs of further margin.
- **Egress, 2048 words** (four rows). The controller reads while it has room for a row, so
  this is what keeps it busy while the FX3 is between packets.

Both are `asyncFifo.v`: binary pointers one bit wider than the address, published as Gray
codes from registers and taken through two flip-flops (`*_meta`, then `*_sync`), with
registered counts computed from the pointer as it will be after the edge. Every flag and
count is therefore pessimistic by the synchroniser delay and nothing else. Each one is an
M9K-inferred simple dual-port memory with a clock per port: 4 M9K each.

## What `buffer.v` sees

`buffer.v` gains three ports. With the path bypassed they reduce exactly to upstream:

| Port | Bypassed | SDRAM path active |
| --- | --- | --- |
| `write_enable`, `data_in` | the sample strobe and sample | words from the egress FIFO, up to one per cycle |
| `sample_offered` (new) | = `write_enable` | the sample strobe |
| `sample_lost` (new) | 0 | a sample dropped at the ingress FIFO |
| `used_words` (new) | unused | the occupancy, for back-pressure |

`sample_lost` is ORed into `buffer.v`'s own overflow, so it raises `bufferError` for the
same 25 µs hold and the instrument counts it in `TELEM_OVERFLOWS` and `TELEM_DROPPED`.
`sample_offered` is what the instrument counts samples by. A run of losses therefore ends
at the first sample that finds room, as upstream defines it, even though words now reach
`buffer.v` in bursts.

**Back-pressure at 8194 words.** The egress side writes into `buffer.v` only while it holds
fewer than 8194 words: one packet plus the two words that the registered `data_available`
takes to rise. That is where a healthy capture leaves `buffer.v`'s occupancy without the
SDRAM (fpga-register-interface.md: "8194 of 16384 words, on every interval"), so the
register instrument reads exactly as it did. A stall now fills the SDRAM instead of
`buffer.v`, so `TELEM_USED_PEAK` stays at 8194 and `TELEM_NEARFULL` stays at zero. The
instrument no longer shows how close a stall came to losing data; the status word's fill
does. Losses are still counted in the registers.

Two alternatives were rejected. A cap just below near-full (12287) would report 49 % back
pressure on every stall the SDRAM absorbs without trouble: the instrument would warn when
nothing is wrong. No cap at all would let `buffer.v` overflow. Holding it at one packet
costs no throughput: the SDRAM read rate (77 Mwords/s) is below what the FX3 drains, so
the cap only stops writes while a full packet is waiting for the FX3 to start on it, and
the egress FIFO absorbs that wait.

## `collect_data`: bypass, flush and switch

The FX3 drives `collect_data` (GPIO19 → CTL_02 → `GPIO1[23]`) high on vendor request
`0xB5` start and low on stop. Upstream gateware ignored it. It is synchronised here.

- **Low, or the SDRAM not yet initialised:** bypassed. Every sample goes straight to
  `buffer.v` exactly as upstream, including upstream's overflow behaviour. This is also what
  a host that never sends `0xB5` gets.
- **Rising:** once the path is empty, samples go into it. Everything before the switch went
  to `buffer.v` directly, and everything after it comes out of the path later, so the switch
  cannot reorder samples. The sticky loss bit is cleared.
- **Falling:** bypassed again on the next cycle, and the path's contents (ingress, ring and
  egress) are discarded. The consumer sees one contiguous gap at the switch.

The reason for the switch is stale data. The capture application discards the first ~8 MB
of a stream; 32 MiB queued from before a start would come out after that, ending in a gap.
With the switch, at most `buffer.v`'s 16384 words and the FX3's own buffers are stale, as
before.

**The path is emptied by draining it, never by resetting it.** Resetting half of a
dual-clock FIFO corrupts it, and resetting the controller mid-burst leaves the SDRAM
mid-command. A flush is a four-phase handshake:

1. The system side raises `flush_request`, stops writing to the ingress FIFO, and discards
   whatever the egress FIFO offers.
2. The controller finishes its current operation, empties the ring, discards everything
   the ingress FIFO offers, starts nothing but refreshes, and raises `flush_ack` once its
   own view of the egress FIFO is empty and its capture pipeline is idle.
3. The system side also waits for its own view of the ingress FIFO to be empty. That is the
   writer's view, the only one that cannot be wrong about emptiness. The path is then clean.
4. To start, the system side drops `flush_request`, and sends samples into the path only
   after `flush_ack` has fallen too. Until it falls, the controller may still be discarding.

Step 3 is not redundant. Late in the recovery from a full ring, the controller can
acknowledge while still discarding a deep ingress FIFO. `tb_sdramBuffer` sets up exactly
that case, and with the step removed it delivers stale words after a restart. The
system-side egress-empty check and the controller's capture-pipeline check back each other
up, so the bench cannot show either one alone to be necessary.

## Drops

Samples are lost in one place only: at the ingress FIFO, when it is full because the ring
is full. A loss is always a contiguous run, ending at the first sample that finds room
again, and nothing is reordered. `tb_sdramBuffer` measured a stall of 1.5 ms against a
32-row ring: one run of 39792 samples lost, with `TELEM_OVERFLOWS` = 1 and
`TELEM_DROPPED` = 39792.

## The status word

24 bits in the system clock domain, for the stream's reserved frame slots:

| Bits | Meaning |
| --- | --- |
| 23:20 | layout version, 1 |
| 19 | the SDRAM path is carrying the samples |
| 18 | the SDRAM has been initialised |
| 17 | a sample was lost at the SDRAM since `collect_data` last rose (sticky) |
| 16 | 0 |
| 15:0 | rows of 512 words in the ring, 0 to 32768 |

It travels in-band: the framed sample format carries it in the header's slots 36, 37, 46 and
47 — S[23:18], S[17:12], S[11:6] and S[5:0] — snapshotted with the audio when each frame
starts, so a frame's four slots are always one word. **The host-facing definition, including
what the fill means and when it was sampled, is in
[framed-sample-format.md](framed-sample-format.md#status-word-slots-36-37-46-and-47)**; the
table above is the producer's view of the same word.

The fill and the initialisation flag cross from 120 MHz through a request/acknowledge
handshake. It runs continuously, so the word is refreshed every few hundred nanoseconds,
well inside the 12.8 µs one row of samples (and one frame) takes. The held value is stable
from before its request toggles until after the acknowledgement returns.

## I/O timing and the `DRAM_CLK` phase shift

All command, address, DQM, CKE and DQ output registers, the DQ output enable and the DQ
input register are placed in the I/O cells (`FAST_OUTPUT_REGISTER`,
`FAST_OUTPUT_ENABLE_REGISTER`, `FAST_INPUT_REGISTER` in the `.qsf`). `DRAM_CLK` is c2
driven straight to the pin.

Let φ be c2's phase relative to c1 (negative means `DRAM_CLK` leads). The budget below uses
datasheet figures for the part and **estimates** for the FPGA and the board:

| Quantity | Value | Source |
| --- | --- | --- |
| tDS / tDH (also tAS/tAH, tCS/tCH, tCKS/tCKH) | 1.5 / 0.8 ns | datasheet, −7 |
| tAC / tOH at CL3 | 5.4 / 2.7 ns | datasheet, −7 |
| PLL to `DRAM_CLK` pin | 2.0 – 3.0 ns | estimate |
| PLL to a registered output pin | 2.2 – 3.5 ns | estimate |
| pin to input register, setup included | 1.0 – 1.5 ns | estimate |
| board trace, each way | 0.1 – 0.5 ns | estimate: a few cm at ~6 ps/mm |

| Check | Requirement on φ |
| --- | --- |
| output setup: 2.1 + φ + 8.33 − 4.0 ≥ 1.5 | φ ≥ −4.9 ns |
| output hold: 2.3 − (3.5 + φ) ≥ 0.8 | φ ≤ −2.0 ns |
| input setup: 3.5 + φ + 5.4 + 0.5 + 1.5 ≤ 8.33 | φ ≤ −2.6 ns |
| input hold: 2.1 + φ + 2.7 + 0.1 + 1.0 ≥ 0 | φ ≥ −5.9 ns |

The window is about −4.9 to −2.6 ns, centred near −3.75. **−3.5 ns is chosen.** It sits
just on the conventional side of the centre, in line with the 2–3 ns leads DE-series
reference designs use at 100 MHz, scaled up for the shorter period.

**This must be confirmed in TimeQuest.** The FPGA delays above are guesses, and TimeQuest
knows the real ones. The SDC carries the datasheet figures and the board estimate, so the
slack on the SDRAM paths tells you directly which way to move φ:

| Failing check | Move φ (`clk2_phase_shift` in `applicationPll.v`) |
| --- | --- |
| input setup, or output hold | more negative |
| output setup, or input hold | less negative |

## Constraints

- `sdram_clk`: a generated clock on `DRAM_CLK`, sourced from `pll1|clk[2]`.
- **Outputs:** `-max` = tDS + trace_max − trace_min = 1.9 ns, `-min` = −tDH + trace_min −
  trace_max = −1.2 ns. The default single-cycle relationship is correct (capture is on the
  next `DRAM_CLK` edge, about 4.8 ns after launch).
- **Inputs:** `-max` = tAC + 2 × trace_max = 6.4 ns, `-min` = tOH + 2 × trace_min = 2.9 ns,
  plus `set_multicycle_path -setup 2` from `sdram_clk` to c1. The hold check is
  deliberately left at its default, one controller edge after the launch, which is the edge
  still capturing the previous word. A customary `-hold 1` would stop checking anything
  real.
- **Crossings:** `set_max_delay 8.0` to every `sdram_buffer_0|*_meta*` register and from the
  status hold register, with their hold checks cut. `set_clock_groups` is deliberately not
  used, because it would cut the bound too. Any other 80↔120 path stays timed as
  synchronous, so a mistake shows up as a failing path.
- **Asynchronous inputs:** a false path to both reset synchronisers (PLL lock and `nReset`)
  and from `GPIO1[23]` (`collect_data`).

`tests/check-sdc.py` now also requires every `DRAM_*` port to be in the right group and
`DRAM_CLK` to carry a clock.

## Resource estimate (not fitted)

| | Estimate | Device |
| --- | --- | --- |
| M9K | +8 (two 2048 × 16 FIFOs), ~40 total with `buffer.v`'s 32 | 66 |
| Logic elements | +600 to +900 | 22,320 |
| PLLs | still 1 (applicationPll replaces IPpllGenerator in this image) | 4 |
| Global clocks | +2 (c1, c2) | 20 |
| I/O | +39 (the board's dedicated SDRAM pins) | |

## Test coverage

| Bench | Covers | Result |
| --- | --- | --- |
| `tb_asyncFifo` | random push and pop at 80/120, 120/80, both saturated, 100/33, 33/100, 50/50.3, 13/97 MHz; order, no loss, pessimistic flags and counts, writes into a full FIFO discarded, full at exactly the depth | pass |
| `tb_sdramController` | power-up; one row; ring full at exactly 64 rows with nothing but refresh while stalled; drain at 40 MSPS (37.2 Mwords/s net); 8 ms of random reader stalls (1308 refreshes, debt ≤ 1, longest gap 11.8 µs); flush mid-backlog; saturated throughput (117.3 Mwords/s) | pass, model silent |
| `tb_sdramBuffer` | the path, `buffer.v` and `fx3StateMachine` end to end with an FX3-like reader; see its header for the eight scenarios | pass, model silent |
| `tb_sdramFramed` | the status word in-band: the framed generator in test mode feeding the path, every frame decoded by the consumer; each frame's status word bit-exactly the one presented when it started, version 1, init before active, no loss, fill peaking at 23 rows during a 450 µs stall and back to steady state | pass, model silent |
| `tb_dataGeneratorFramed`, `tb_dataGenerator` | the status word's four slots bit-exact and coherent with the audio snapshot; the unframed format unaffected by it | pass |

`tests/sdramModel.v` checks power-up, tRCD, tRP, tRC, tRAS min and max, tRRD, tDPL, tMRD,
bank state, burst termination and wrap, undriven write data, bus contention and the refresh
rate (more than eight postponed fails). Mutations of the controller (each timing constant,
the capture delay, the stop, the read precharge, the refresh interval, the power-up wait
and refresh count, both DQM settings) and of the flush logic were each caught.

**Not covered by simulation:**

- The top level, the PLL and the pins, as with the rest of the gateware.
- Real I/O timing. The model's 1 ns clock lead and its tAC/tOH output delays show that the
  capture edge is the right one. Whether the board meets the budget is TimeQuest's job and
  the bench's.
- Metastability. A zero-delay simulation cannot show it. The synchroniser structure is
  checked by reading, and the paths by the SDC.
- The full 32768-row ring. The benches use 64 and 32 rows; the wrap logic is the same
  comparison either way.

## What only Quartus, TimeQuest and hardware can confirm

- The design fits and the memories infer as M9K (4 per FIFO).
- Every SDRAM register is packed into its I/O cell, including the per-pin output-enable
  registers the Fitter must duplicate from one.
- The PLL achieves 80, 120 and 120 MHz at −3.5 ns, and no output-pin warnings matter.
- TimeQuest closes the 80 and 120 MHz domains, the SDRAM input and output paths, and the
  crossings, and shows no unconstrained paths.
- The SDRAM initialises and holds data at 120 MHz on the board, through a long soak with
  zero sequence breaks, and the ramp analysis and the register telemetry agree about every
  deliberate loss.
