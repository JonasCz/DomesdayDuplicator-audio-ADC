/************************************************************************

    framed_stream_validator.h

    Proving a framed capture is bit-perfect, and taking its audio out
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "framed_format.h"
#include "sample_metrics.h"
#include "sequence_validator.h"

namespace ddd::capture {

// --- Telling the two formats apart -----------------------------------------

// How far into the first buffer a frame may begin and still be found, in
// samples. Four frames' worth: the opening slots a source discards already
// absorb whatever was in flight when the device was opened, so a frame start
// is expected within the first 512, and the other three are margin for a
// buffer head that is still untidy after the discard.
inline constexpr size_t kFramedDetectionSearchSamples = 4 * kFrameSamples;

// What the detection insists on before it calls a stream framed: two whole
// consecutive frames, both sync patterns in place and all 116 counter values in
// sequence across them.
inline constexpr size_t kFramedDetectionConfirmSamples = 2 * kFrameSamples;

// The most of a buffer detection can read. Bounded, and small: about 6 KiB of a
// 2 MiB buffer, read once, at the start of a run.
inline constexpr size_t kFramedDetectionMaximumSamples =
    kFramedDetectionSearchSamples + kFramedDetectionConfirmSamples;

struct FramedDetection {
  // Two whole frames were found and agreed with each other.
  bool framed = false;

  // A sync pattern was seen somewhere in the search, whether or not it was
  // confirmed. Only interesting when `framed` is false: it is the difference
  // between a stream that is plainly not framed and a framed stream whose
  // opening was damaged, and a log that says which saves somebody a long
  // afternoon.
  bool sync_seen = false;

  // The sample the confirmed frame starts at. Meaningless unless `framed`.
  size_t frame_start = 0;
};

// Is this buffer the opening of a framed stream?
//
// Read-only and bounded by kFramedDetectionMaximumSamples, so a stream in the
// sequence-counter format reaches its own validator exactly as it would have
// without this. It cannot be mistaken for framed: its top bits stay constant
// for 65,535 samples at a time, and a sync pattern is 32 samples of which no
// two neighbours are equal. A stream with no markers at all — every top bit
// zero — cannot match either.
FramedDetection DetectFramedStream(const uint8_t* buffer, size_t sample_count);

// --- Validating one ----------------------------------------------------------

// What broke, when a framed stream stopped agreeing with its framing.
enum class FramedFault {
  kNone,

  // A frame's opening 32 samples were not the sync pattern.
  kSyncPattern,

  // A counter value was not one more than the value before it.
  kCounter,
};

const char* FramedFaultName(FramedFault fault);

// Validates the framing of the audio gateware's stream, strips it, takes the
// audio out of it and measures the signal — the framed format's counterpart to
// SequenceValidator, and on the same contract.
//
// What "validates" means: every frame must open with the sync pattern, and
// every one of the counter values in it must be one more than the value before,
// across frame boundaries and buffer boundaries alike. A sync pattern in the
// wrong place says samples went missing inside a frame; a counter that jumped
// with the sync still in place says a whole number of frames did.
//
// What happens then is a choice, and the default is upstream's: the stream is
// declared failed, exactly as a sequence-counter mismatch fails one, because a
// capture that has lost samples is not the capture it claims to be. With
// continue_after_sync_loss set the loss is counted instead, the validator looks
// for the next sync pattern, and carries on from there — the behaviour the
// fork's capture application had, for anyone who would rather have a capture
// with a hole in it than no capture at all.
//
// One pass, for the reason SequenceValidator gives: a 2 MB buffer does not fit
// in cache, so validation, stripping, audio extraction and measurement share a
// loop. The top bits are cleared in place, so what reaches the sink is the RF
// sample and nothing else.
//
// A frame's audio is handed over only once the first counter value after it
// has checked out. The audio sits between the sync pattern and the counter, so
// a loss anywhere inside it shifts the counter that follows, and holding the
// audio back until then is what keeps a sample assembled from two different
// frames out of the file.
//
// Thread-safety: none. One instance belongs to the processing thread for the
// life of a capture.
class FramedStreamValidator {
 public:
  struct Options {
    bool continue_after_sync_loss = false;
  };

  // Where a fault was found and what was there.
  struct Fault {
    FramedFault kind = FramedFault::kNone;

    // A sample index into the buffer the fault was found in.
    uint64_t sample_index = 0;

    // Where in its frame the validator thought that sample was.
    uint32_t frame_position = 0;

    // A 6-bit sync chunk for kSyncPattern, a 48-bit counter value for
    // kCounter.
    uint64_t expected = 0;
    uint64_t actual = 0;
  };

  struct Outcome {
    // False only for a fault the validator was not allowed to recover from.
    bool ok = true;

    // Always populated, as SequenceValidator's is: the samples up to a break
    // were real.
    BufferTally tally;

    // The first fault in this buffer — the one that failed it, or the first of
    // the losses it recovered from.
    Fault first_fault;

    // Losses recovered from in this buffer.
    uint64_t sync_losses = 0;

    // Frames whose sync pattern and first counter value both checked out.
    uint64_t frames_checked = 0;
  };

  FramedStreamValidator() = default;
  explicit FramedStreamValidator(const Options& options) : options_(options) {}

  // Validate, strip, extract and measure one buffer. Frames whose audio became
  // complete in this buffer are appended to `audio`, which is not cleared
  // first. byte_count must be even; a trailing odd byte is left alone.
  Outcome Process(uint8_t* buffer, size_t byte_count,
                  std::vector<AudioFrame>& audio);

  // The shared vocabulary: kSynchronising until the first sync pattern,
  // kRunning while nothing has been lost, kResynchronised once something has
  // and the validator carried on, kFailed when it was not allowed to.
  SequenceState state() const;

  // Whether it is currently in step with the framing, rather than looking for
  // the next sync pattern.
  bool locked() const { return phase_ == Phase::kLocked; }

  uint64_t sync_losses() const { return sync_losses_; }
  uint64_t frames_checked() const { return frames_checked_; }

  void Reset(const Options& options);

 private:
  enum class Phase {
    // Looking for a sync pattern, at the start or after a loss.
    kSearching,
    kLocked,
    kFailed,
  };

  Options options_;
  Phase phase_ = Phase::kSearching;
  bool ever_locked_ = false;

  // Searching: how many chunks of the sync pattern the most recent samples
  // have matched. Carried across buffers, so a pattern split by a buffer
  // boundary is found like any other.
  size_t sync_matched_ = 0;

  // Locked: where the next sample sits in its frame.
  size_t position_ = 0;

  // The counter value being assembled from the current eight-sample block, and
  // the value the next complete one must have.
  uint64_t counter_accumulator_ = 0;
  uint64_t expected_counter_ = 0;
  bool counter_known_ = false;

  // The current frame's sixteen chunks from positions 32 to 47: the audio and
  // the reserved slots, held until the counter after them has checked out.
  std::array<uint8_t, 16> auxiliary_{};

  uint64_t sync_losses_ = 0;
  uint64_t frames_checked_ = 0;
};

}  // namespace ddd::capture
