/************************************************************************

    sdram_status.h

    What the gateware's SDRAM capture buffer reports in every frame
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#pragma once

#include <cstdint>
#include <span>

#include "framed_format.h"

// The status word a framed stream's reserved slots carry, once the gateware
// has an SDRAM buffer in its capture path.
//
// Twenty-four bits, six in each of four slots the audio-only gateware leaves at
// zero: bits 23..18 in sample 36 of a frame, 17..12 in 37, 11..6 in 46 and 5..0
// in 47. Laid out as
//
//     23..20   layout version. 0 is no status at all — audio-only gateware,
//              all four slots zero — and 1 is this layout. Anything else is a
//              layout this build does not know, and is ignored rather than
//              misread.
//     19       the stream is passing through the SDRAM at the moment
//     18       the SDRAM has finished initialising
//     17       the buffer overflowed since collection started: sticky, and it
//              means samples were dropped because all 32 MiB were full
//     16       reserved
//     15..0    how full the buffer was when this frame's sample was taken, in
//              rows of 512 words — 1 KiB — from 0 to 32,768, which is full
//
// One reading a frame, so 78,125 a second: far finer than anything a display
// needs, and fine enough that a peak taken across them misses nothing.
//
// The gateware's definition is beside the framed format's own, in fpga/; this
// is the host's copy, kept separately on purpose (AGENTS.md §2).
namespace ddd::capture {

inline constexpr uint32_t kSdramStatusLayoutVersion = 1;

// The buffer's size, in the units the status reports and in bytes.
inline constexpr uint32_t kSdramCapacityRows = 32'768;
inline constexpr uint32_t kSdramRowWords = 512;
inline constexpr uint64_t kSdramRowBytes =
    uint64_t{kSdramRowWords} * kBytesPerSample;
inline constexpr uint64_t kSdramCapacityBytes =
    uint64_t{kSdramCapacityRows} * kSdramRowBytes;

static_assert(kSdramCapacityBytes == uint64_t{32} << 20,
              "the buffer is 32 MiB");

// Bits of the status word.
inline constexpr uint32_t kSdramVersionShift = 20;
inline constexpr uint32_t kSdramActiveBit = uint32_t{1} << 19;
inline constexpr uint32_t kSdramInitialisedBit = uint32_t{1} << 18;
inline constexpr uint32_t kSdramOverflowBit = uint32_t{1} << 17;
inline constexpr uint32_t kSdramFillMask = 0xFFFF;

// One reading, decoded.
struct SdramStatus {
  // The word carried a layout this build understands. False for audio-only
  // gateware, for a stream that is not framed at all, and for a layout from a
  // future nobody has described — all three of which are "nothing to show".
  bool present = false;

  bool active = false;
  bool initialised = false;
  bool overflowed = false;

  // 0 to kSdramCapacityRows. A reading above it is clamped: a fill the buffer
  // cannot hold is a fill that is full.
  uint32_t fill_rows = 0;
};

SdramStatus DecodeSdramStatus(uint32_t word);

// The fill as a share of the buffer, in percent, and as a quantity: bytes, and
// how long that much of the stream lasts at `sample_rate_hz`.
double SdramFillPercent(uint32_t rows);
uint64_t SdramFillBytes(uint32_t rows);
double SdramFillMilliseconds(uint32_t rows, uint32_t sample_rate_hz);

// What the buffer did over a run, as the display and the log want it.
struct SdramSnapshot {
  // At least one reading in a layout this build understands has arrived.
  bool present = false;

  // The most recent reading.
  SdramStatus current;

  // The fullest it got since the run started, which is the figure that says
  // how close a capture came to dropping samples: the current reading of a
  // buffer that is draining says nothing about the minute before.
  uint32_t peak_rows = 0;

  // Whether any reading in the run had the stream in the SDRAM, and whether
  // any said it had overflowed. The second is sticky in the gateware as well,
  // but the gateware's flag covers the collection and this covers the run.
  bool active_seen = false;
  bool overflow_seen = false;

  uint64_t readings = 0;
};

// Folds the frames' readings in as they go past.
//
// Thread-safety: none. Owned by the processing thread, like the audio levels.
class SdramMonitor {
 public:
  // Every frame's reading in this buffer. Words in an unknown layout are
  // skipped one by one, so a stream that changed layout partway — which no
  // gateware does — would be read where it could be and nowhere else.
  void Accumulate(std::span<const AudioFrame> frames);

  SdramSnapshot Snapshot() const { return snapshot_; }

  void Reset() { snapshot_ = SdramSnapshot{}; }

 private:
  SdramSnapshot snapshot_;
};

}  // namespace ddd::capture
