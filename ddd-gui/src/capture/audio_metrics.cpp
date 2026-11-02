/************************************************************************

    audio_metrics.cpp

    What the audio in a framed stream looked like, and what was written
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#include "audio_metrics.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace ddd::capture {
namespace {

int32_t Magnitude(int32_t value) { return value < 0 ? -value : value; }

// One channel's sample into one converter's figures.
void Fold(AudioLevel& level, int32_t value, int32_t minimum_rail,
          int32_t maximum_rail, int32_t& recent_peak) {
  level.minimum = std::min(level.minimum, value);
  level.maximum = std::max(level.maximum, value);
  recent_peak = std::max(recent_peak, Magnitude(value));
  if (value == minimum_rail || value == maximum_rail) {
    ++level.clipped;
    ++level.recent_clipped;
  }
}

void AccumulateConverter(AudioLevel& level, std::span<const AudioFrame> frames,
                         int32_t AudioFrame::* left,
                         int32_t AudioFrame::* right, int32_t minimum_rail,
                         int32_t maximum_rail) {
  if (!level.measured) {
    // Seeded from the first sample rather than from the rails, so that a
    // snapshot taken after one buffer says what that buffer held.
    level.minimum = std::numeric_limits<int32_t>::max();
    level.maximum = std::numeric_limits<int32_t>::min();
    level.measured = true;
  }

  level.recent_clipped = 0;
  int32_t peak_left = 0;
  int32_t peak_right = 0;

  for (const AudioFrame& frame : frames) {
    Fold(level, frame.*left, minimum_rail, maximum_rail, peak_left);
    Fold(level, frame.*right, minimum_rail, maximum_rail, peak_right);
  }

  level.frames += frames.size();
  level.recent_peak_left = peak_left;
  level.recent_peak_right = peak_right;
  level.peak = std::max({level.peak, peak_left, peak_right});
}

}  // namespace

void AudioMetrics::Accumulate(std::span<const AudioFrame> frames) {
  if (frames.empty()) {
    return;
  }

  AccumulateConverter(snapshot_.integrated, frames,
                      &AudioFrame::integrated_left,
                      &AudioFrame::integrated_right, kIntegratedAudioMinimum,
                      kIntegratedAudioMaximum);
  AccumulateConverter(snapshot_.external, frames, &AudioFrame::external_left,
                      &AudioFrame::external_right, kExternalAudioMinimum,
                      kExternalAudioMaximum);
}

double DecibelsFullScale(int32_t magnitude, int32_t full_scale) {
  if (magnitude <= 0 || full_scale <= 0) {
    return -std::numeric_limits<double>::infinity();
  }
  return 20.0 * std::log10(static_cast<double>(magnitude) /
                           static_cast<double>(full_scale));
}

}  // namespace ddd::capture
