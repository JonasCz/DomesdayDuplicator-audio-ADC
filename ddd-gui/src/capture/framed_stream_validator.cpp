/************************************************************************

    framed_stream_validator.cpp

    Proving a framed capture is bit-perfect, and taking its audio out
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#include "framed_stream_validator.h"

#include <algorithm>

#include "sample_format.h"

namespace ddd::capture {
namespace {

uint8_t TopBitsAt(const uint8_t* buffer, size_t sample_index) {
  return TopBitsOfHighByte(buffer[(sample_index * kBytesPerSample) + 1]);
}

// The 48-bit counter value held in the eight samples starting at `first`.
uint64_t CounterValueAt(const uint8_t* buffer, size_t first) {
  uint64_t value = 0;
  for (size_t chunk = 0; chunk < kCounterSamplesPerValue; ++chunk) {
    value |= static_cast<uint64_t>(TopBitsAt(buffer, first + chunk))
             << (6 * chunk);
  }
  return value;
}

// Two whole frames from `start`, read and not written.
bool ConfirmFrames(const uint8_t* buffer, size_t sample_count, size_t start) {
  if (start + kFramedDetectionConfirmSamples > sample_count) {
    return false;
  }

  bool have_previous = false;
  uint64_t previous = 0;

  for (size_t frame = 0; frame < 2; ++frame) {
    const size_t base = start + (frame * kFrameSamples);

    for (size_t chunk = 0; chunk < kFrameSyncSamples; ++chunk) {
      if (TopBitsAt(buffer, base + chunk) != kSyncChunks[chunk]) {
        return false;
      }
    }

    for (size_t value_index = 0; value_index < kCounterValuesPerFrame;
         ++value_index) {
      const uint64_t value =
          CounterValueAt(buffer, base + kFrameCounterOffset +
                                     (value_index * kCounterSamplesPerValue));
      if (have_previous && value != ((previous + 1) & kFrameCounterMask)) {
        return false;
      }
      previous = value;
      have_previous = true;
    }
  }

  return true;
}

}  // namespace

FramedDetection DetectFramedStream(const uint8_t* buffer, size_t sample_count) {
  FramedDetection detection;

  // The last place a frame may start and still be found, plus the rest of its
  // sync pattern.
  const size_t limit = std::min(
      sample_count, kFramedDetectionSearchSamples + kFrameSyncSamples - 1);

  size_t matched = 0;
  for (size_t index = 0; index < limit; ++index) {
    const uint8_t top = TopBitsAt(buffer, index);

    if (top == kSyncChunks[matched]) {
      ++matched;
    } else {
      // The first chunk occurs nowhere else in the pattern (framed_format.h),
      // so a failed match can only start again at this very sample.
      matched = (top == kSyncChunks[0]) ? 1 : 0;
    }

    if (matched == kFrameSyncSamples) {
      const size_t start = index + 1 - kFrameSyncSamples;
      detection.sync_seen = true;
      if (ConfirmFrames(buffer, sample_count, start)) {
        detection.framed = true;
        detection.frame_start = start;
        return detection;
      }

      // A pattern that did not repeat. Keep looking: the next frame may
      // confirm where this one did not, and if none does the stream is handed
      // to the sequence-counter validator, which is what would have happened
      // without any of this.
      matched = 0;
    }
  }

  return detection;
}

const char* FramedFaultName(FramedFault fault) {
  switch (fault) {
    case FramedFault::kNone:
      return "none";
    case FramedFault::kSyncPattern:
      return "sync pattern";
    case FramedFault::kCounter:
      return "counter";
  }
  return "unknown";
}

void FramedStreamValidator::Reset(const Options& options) {
  *this = FramedStreamValidator(options);
}

SequenceState FramedStreamValidator::state() const {
  if (phase_ == Phase::kFailed) {
    return SequenceState::kFailed;
  }
  if (sync_losses_ > 0) {
    return SequenceState::kResynchronised;
  }
  return ever_locked_ ? SequenceState::kRunning : SequenceState::kSynchronising;
}

FramedStreamValidator::Outcome FramedStreamValidator::Process(
    uint8_t* buffer, size_t byte_count, std::vector<AudioFrame>& audio) {
  Outcome outcome;

  const size_t sample_count = byte_count / kBytesPerSample;
  if (sample_count == 0) {
    return outcome;
  }

  if (phase_ == Phase::kFailed) {
    outcome.ok = false;
    return outcome;
  }

  // The state the loop changes, held in locals for its duration. The loop calls
  // out to push_back, which the compiler cannot see through, and members would
  // otherwise be reloaded from memory after every frame.
  Phase phase = phase_;
  size_t sync_matched = sync_matched_;
  size_t position = position_;
  uint64_t accumulator = counter_accumulator_;
  uint64_t expected = expected_counter_;
  bool counter_known = counter_known_;
  bool ever_locked = ever_locked_;

  uint16_t minimum_value = UINT16_MAX;
  uint16_t maximum_value = 0;
  uint64_t clipped_low = 0;
  uint64_t clipped_high = 0;
  uint64_t sum_of_squares = 0;
  uint64_t measured = 0;

  // Raw pointers rather than the arrays' operator[], and the shift written out
  // rather than called: an unoptimised build calls every one of those, and
  // this loop runs a million times a buffer.
  const uint8_t* const sync = kSyncChunks.data();
  uint8_t* const auxiliary = auxiliary_.data();

  for (size_t index = 0; index < sample_count; ++index) {
    uint8_t* word = buffer + (index * kBytesPerSample);
    const uint8_t high_byte = word[1];
    const auto top =
        static_cast<uint8_t>(high_byte >> kSequenceCounterHighByteShift);

    if (phase == Phase::kLocked) {
      FramedFault fault = FramedFault::kNone;
      uint64_t fault_expected = 0;

      // Most of a frame is counter, so that is asked about first.
      if (position >= kFrameCounterOffset) {
        // The counter region starts on a multiple of eight, so the chunk is
        // the position's low three bits.
        const size_t chunk = position & (kCounterSamplesPerValue - 1);
        accumulator |= static_cast<uint64_t>(top) << (6 * chunk);

        if (chunk == kCounterSamplesPerValue - 1) {
          if (counter_known && accumulator != expected) {
            fault = FramedFault::kCounter;
            fault_expected = expected;
          } else {
            expected = (accumulator + 1) & kFrameCounterMask;
            counter_known = true;

            // The first value after the audio has checked out, so the audio
            // between it and the sync pattern is all from this frame.
            if (position == kFrameCounterOffset + kCounterSamplesPerValue - 1) {
              audio.push_back(DecodeAudioFrame(auxiliary_));
              ++outcome.frames_checked;
            }
            accumulator = 0;
          }
        }
      } else if (position < kFrameSyncSamples) {
        if (top != sync[position]) {
          fault = FramedFault::kSyncPattern;
          fault_expected = sync[position];
        }
      } else {
        auxiliary[position - kFrameIntegratedAudioOffset] = top;
      }

      if (fault != FramedFault::kNone) {
        if (outcome.first_fault.kind == FramedFault::kNone) {
          outcome.first_fault.kind = fault;
          outcome.first_fault.sample_index = index;
          outcome.first_fault.frame_position = static_cast<uint32_t>(position);
          outcome.first_fault.expected = fault_expected;
          outcome.first_fault.actual =
              fault == FramedFault::kCounter ? accumulator : top;
        }

        if (!options_.continue_after_sync_loss) {
          // As SequenceValidator does: the capture is over, so the rest of the
          // buffer is neither stripped nor measured.
          phase = Phase::kFailed;
          outcome.ok = false;
          break;
        }

        // Counted, and then the search for the next sync pattern begins with
        // this very sample, which may be the first chunk of it.
        ++outcome.sync_losses;
        phase = Phase::kSearching;
        sync_matched = (top == sync[0]) ? 1 : 0;
        accumulator = 0;
        counter_known = false;
      } else {
        position = (position + 1) & (kFrameSamples - 1);
      }
    } else {
      if (top == sync[sync_matched]) {
        ++sync_matched;
        if (sync_matched == kFrameSyncSamples) {
          // The next sample is the first after the pattern. The counter is
          // learned afresh from the first value that follows: after a loss
          // there is no knowing how many values went with it.
          phase = Phase::kLocked;
          position = kFrameSyncSamples;
          sync_matched = 0;
          accumulator = 0;
          counter_known = false;
          ever_locked = true;
        }
      } else {
        sync_matched = (top == sync[0]) ? 1 : 0;
      }
    }

    // Strip the framing in place, so what reaches the sink is the RF sample.
    word[1] = static_cast<uint8_t>(high_byte & kSampleValueHighByteMask);

    const uint16_t value = static_cast<uint16_t>(
        static_cast<uint16_t>(word[0]) |
        static_cast<uint16_t>(static_cast<uint16_t>(word[1]) << 8));

    minimum_value = std::min(minimum_value, value);
    maximum_value = std::max(maximum_value, value);

    if (value == kMinimumSampleValue) {
      ++clipped_low;
    } else if (value == kMaximumSampleValue) {
      ++clipped_high;
    }

    const int32_t centred = static_cast<int32_t>(value) - kSampleZeroOffset;
    sum_of_squares += static_cast<uint64_t>(centred * centred);
    ++measured;
  }

  phase_ = phase;
  sync_matched_ = sync_matched;
  position_ = position;
  counter_accumulator_ = accumulator;
  expected_counter_ = expected;
  counter_known_ = counter_known;
  ever_locked_ = ever_locked;
  sync_losses_ += outcome.sync_losses;
  frames_checked_ += outcome.frames_checked;

  outcome.tally.sample_count = measured;
  outcome.tally.minimum_value = minimum_value;
  outcome.tally.maximum_value = maximum_value;
  outcome.tally.clipped_low_count = clipped_low;
  outcome.tally.clipped_high_count = clipped_high;
  outcome.tally.sum_of_squares = sum_of_squares;
  return outcome;
}

}  // namespace ddd::capture
