/************************************************************************

    framed_format.h

    The framed sample layout the audio gateware emits
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "sample_format.h"

// The second of the two layouts bits 15..10 of a wire word can carry.
//
// Bits 9..0 are the RF sample in both. Where the original gateware puts a
// 6-bit sequence counter in the top bits (sample_format.h), the audio gateware
// cuts the stream into 512-sample frames and gives the top bits of each sample
// a job according to where it sits in its frame:
//
//     0..31     a 192-bit sync pattern, six bits a sample, least significant
//               chunk first
//     32..35    the on-board ADC128S022: left [11:6], left [5:0], right [11:6],
//               right [5:0], unsigned with 2048 as zero
//     36..37    reserved
//     38..45    the PCM1802: left [23:18] .. [5:0], then right the same way,
//               24-bit two's complement
//     46..47    reserved
//     48..511   58 values of a free-running 48-bit counter, eight samples each,
//               least significant chunk first. It advances once per eight-
//               sample block of this region and carries on across frames, so
//               the first value of a frame is one more than the last value of
//               the frame before it.
//
// One stereo audio sample per frame, so the audio rate is the stream's rate
// over 512: 78,125 Hz undecimated and 39,062.5 Hz when the gateware halves the
// rate, because the framing is applied after the decimator.
//
// The definitive description is the framed sample format specification that
// lives beside the gateware (fpga/application/framed-sample-format.md); the
// gateware's own definition is fpga/application/dataGenerator.v. This is the
// host's copy of the numbers, kept separately on purpose (AGENTS.md §2) — it
// is a wire protocol, and the definitions live on two different processors.
namespace ddd::capture {

// Samples in one frame, and therefore stream samples per audio sample.
inline constexpr size_t kFrameSamples = 512;

// Where each field starts within a frame.
inline constexpr size_t kFrameSyncSamples = 32;
inline constexpr size_t kFrameIntegratedAudioOffset = 32;
inline constexpr size_t kFrameExternalAudioOffset = 38;
inline constexpr size_t kFrameCounterOffset = 48;

// The 48-bit counter: eight samples a value, 58 values a frame.
inline constexpr size_t kCounterSamplesPerValue = 8;
inline constexpr size_t kCounterValuesPerFrame =
    (kFrameSamples - kFrameCounterOffset) / kCounterSamplesPerValue;
inline constexpr uint64_t kFrameCounterMask = (uint64_t{1} << 48) - 1;

static_assert(kCounterValuesPerFrame == 58,
              "the counter region is 464 samples of 8-sample values");

// The sync pattern, as the gateware writes it: one 192-bit constant, of which
// sample k of a frame carries bits [6k+5:6k]. Held here as its four 48-bit
// quarters, least significant first, because no C++ integer is 192 bits wide.
//
//     192'hDDDF20251015DDDF20251015DDDF20251016FEDCBA987654
inline constexpr std::array<uint64_t, 4> kSyncPatternQuarters = {
    0xFEDCBA987654ULL, 0xDDDF20251016ULL, 0xDDDF20251015ULL, 0xDDDF20251015ULL};

// The six bits each of the first 32 samples of a frame carries.
inline constexpr std::array<uint8_t, kFrameSyncSamples> kSyncChunks = [] {
  std::array<uint8_t, kFrameSyncSamples> chunks{};
  for (size_t index = 0; index < kFrameSyncSamples; ++index) {
    const uint64_t quarter = kSyncPatternQuarters[index / 8];
    chunks[index] = static_cast<uint8_t>((quarter >> (6 * (index % 8))) & 0x3F);
  }
  return chunks;
}();

// The property the incremental search for a sync pattern rests on: the first
// chunk appears nowhere else in the pattern. A partial match that fails can
// therefore only restart at the very sample that broke it, so the search needs
// one counter and no table — and a pattern split across two buffers is found
// as easily as one that is not.
inline constexpr bool SyncFirstChunkIsUnique() {
  for (size_t index = 1; index < kFrameSyncSamples; ++index) {
    if (kSyncChunks[index] == kSyncChunks[0]) {
      return false;
    }
  }
  return true;
}
static_assert(SyncFirstChunkIsUnique(),
              "the sync search restarts at the breaking sample, which is only "
              "right while the first chunk does not recur");

// The six bits a wire word carries above its sample, read from the word's high
// byte the way the hot loops read it.
inline constexpr uint8_t TopBitsOfHighByte(uint8_t high_byte) {
  return static_cast<uint8_t>(high_byte >> kSequenceCounterHighByteShift);
}

// The integrated converter's full scale either side of zero, and its rails.
inline constexpr int32_t kIntegratedAudioZero = 2048;
inline constexpr int32_t kIntegratedAudioMinimum = -2048;
inline constexpr int32_t kIntegratedAudioMaximum = 2047;

// The external converter's.
inline constexpr int32_t kExternalAudioMinimum = -8'388'608;
inline constexpr int32_t kExternalAudioMaximum = 8'388'607;

// One frame's audio: a stereo sample from each converter, in signed form.
//
// The integrated converter's 12-bit unsigned reading has 2048 taken off it, so
// it runs -2048..2047; the external one is sign-extended from 24 bits. Both are
// what the converter said and nothing else — the scaling a file is written with
// is the writer's business, not this struct's.
//
// The four reserved slots travel with it, put back together as one 24-bit
// word: samples 36 and 37 are its top twelve bits and 46 and 47 its bottom
// twelve. Zero from audio-only gateware; gateware with an SDRAM buffer reports
// that buffer's status in it (sdram_status.h).
struct AudioFrame {
  int32_t integrated_left = 0;
  int32_t integrated_right = 0;
  int32_t external_left = 0;
  int32_t external_right = 0;
  uint32_t reserved_word = 0;
};

// A 12-bit unsigned reading from the integrated converter, centred on zero.
inline constexpr int32_t CentreIntegratedAudio(uint32_t twelve_bit) {
  return static_cast<int32_t>(twelve_bit & 0x0FFFU) - kIntegratedAudioZero;
}

// A 24-bit two's complement reading from the external converter, widened.
inline constexpr int32_t SignExtendExternalAudio(uint32_t twenty_four_bit) {
  const uint32_t value = twenty_four_bit & 0x00FF'FFFFU;
  return (value & 0x0080'0000U) != 0
             ? static_cast<int32_t>(value) - static_cast<int32_t>(0x0100'0000)
             : static_cast<int32_t>(value);
}

// The integrated converter's sample as it goes into a signed 16-bit file.
//
// Shifted up by four, so that the converter's full scale is the file's: the
// same scaling the fork's writer used, which means a file written here and one
// written there hold the same numbers for the same signal.
inline constexpr int16_t IntegratedAudioToSigned16(int32_t centred) {
  return static_cast<int16_t>(centred * 16);
}

// Decode one frame's audio from the sixteen auxiliary chunks, positions 32..47
// of a frame, in order.
inline constexpr AudioFrame DecodeAudioFrame(
    const std::array<uint8_t, 16>& auxiliary) {
  const auto pair = [&auxiliary](size_t first) {
    return (static_cast<uint32_t>(auxiliary[first]) << 6) |
           static_cast<uint32_t>(auxiliary[first + 1]);
  };
  const auto quad = [&auxiliary](size_t first) {
    return (static_cast<uint32_t>(auxiliary[first]) << 18) |
           (static_cast<uint32_t>(auxiliary[first + 1]) << 12) |
           (static_cast<uint32_t>(auxiliary[first + 2]) << 6) |
           static_cast<uint32_t>(auxiliary[first + 3]);
  };

  constexpr size_t kIntegrated = 0;
  constexpr size_t kExternal =
      kFrameExternalAudioOffset - kFrameIntegratedAudioOffset;

  // Positions 36, 37, 46 and 47, most significant first.
  constexpr size_t kReservedHigh = 36 - kFrameIntegratedAudioOffset;
  constexpr size_t kReservedLow = 46 - kFrameIntegratedAudioOffset;

  AudioFrame frame;
  frame.integrated_left = CentreIntegratedAudio(pair(kIntegrated));
  frame.integrated_right = CentreIntegratedAudio(pair(kIntegrated + 2));
  frame.external_left = SignExtendExternalAudio(quad(kExternal));
  frame.external_right = SignExtendExternalAudio(quad(kExternal + 4));
  frame.reserved_word = (pair(kReservedHigh) << 12) | pair(kReservedLow);
  return frame;
}

// The audio rate a stream running at `stream_rate_hz` carries, in hertz.
//
// A double because it is not always whole: the decimated stream's is 39,062.5.
// Exact in both cases, since 512 is a power of two.
inline constexpr double FramedAudioSampleRateHz(uint32_t stream_rate_hz) {
  return static_cast<double>(stream_rate_hz) /
         static_cast<double>(kFrameSamples);
}

}  // namespace ddd::capture
