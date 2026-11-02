/************************************************************************

    audio_metrics.h

    What the audio in a framed stream looked like, and what was written
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#pragma once

#include <cstdint>
#include <span>

#include "framed_format.h"

namespace ddd::capture {

// One converter's levels, both channels together except where a channel is
// named.
//
// The same shape as the RF figures in SampleMetricsSnapshot and for the same
// reason: a whole-run extreme records the worst moment since monitoring began
// and never comes back down, so it cannot show that turning a level down has
// helped. The recent figures cover the most recent buffer only — about 26 ms of
// signal, two thousand audio samples — which is what a level readout wants.
struct AudioLevel {
  // False until a framed stream has delivered at least one frame. A stream in
  // the sequence-counter format never sets it, and that has to stay distinct
  // from a converter reading silence.
  bool measured = false;

  // Stereo samples seen, which is one per frame.
  uint64_t frames = 0;

  // Over the whole run, in the converter's own signed units.
  int32_t minimum = 0;
  int32_t maximum = 0;

  // The largest magnitude seen over the run. The negative rail's magnitude is
  // the converter's full scale, so a signal sitting there reads 0 dBFS.
  int32_t peak = 0;

  // Samples at either rail, over the run and over the most recent buffer.
  uint64_t clipped = 0;
  uint64_t recent_clipped = 0;

  // The largest magnitude in the most recent buffer, per channel.
  int32_t recent_peak_left = 0;
  int32_t recent_peak_right = 0;
};

struct AudioMetricsSnapshot {
  AudioLevel integrated;
  AudioLevel external;
};

// Accumulates audio levels as the frames go past.
//
// Thread-safety: none. Owned by the processing thread, like SampleMetrics; the
// display gets a copy through the statistics block.
class AudioMetrics {
 public:
  // Fold in one buffer's frames. An empty span is a buffer with no audio in it,
  // which leaves the recent figures where they were rather than reading as
  // silence: a sequence-counter stream never has any, and a framed buffer
  // always does.
  void Accumulate(std::span<const AudioFrame> frames);

  AudioMetricsSnapshot Snapshot() const { return snapshot_; }

  void Reset() { snapshot_ = AudioMetricsSnapshot{}; }

 private:
  AudioMetricsSnapshot snapshot_;
};

// The level a magnitude stands for, in decibels relative to full scale. Minus
// infinity for silence; the caller decides how to say that.
double DecibelsFullScale(int32_t magnitude, int32_t full_scale);

// Full scale for each converter: the magnitude of its negative rail.
inline constexpr int32_t kIntegratedAudioFullScale = -kIntegratedAudioMinimum;
inline constexpr int32_t kExternalAudioFullScale = -kExternalAudioMinimum;

// What reached one audio file.
//
// Counted by the writer itself, so the figures cover exactly the frames that
// file holds — the same reasoning that has the RF sink report its own bytes
// rather than the pipeline deriving them.
struct AudioFileTally {
  bool open = false;
  uint64_t frames = 0;
  uint64_t bytes = 0;
  uint64_t clipped_samples = 0;
  int32_t peak = 0;
};

// Both converters' files. A tally that is not open is a converter that was not
// being recorded.
struct AudioWriteSummary {
  AudioFileTally integrated;
  AudioFileTally external;
};

}  // namespace ddd::capture
