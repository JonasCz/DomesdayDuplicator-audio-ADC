/************************************************************************

    stream_validator.h

    Which of the two formats a stream is in, and validating it as that
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "framed_format.h"
#include "framed_stream_validator.h"
#include "sample_metrics.h"
#include "sequence_validator.h"

namespace ddd::capture {

// What the top six bits of every sample are carrying.
enum class StreamFormat {
  // Nothing has been processed yet.
  kUndetermined,

  // The original gateware's 6-bit sequence counter, or no markers at all from
  // gateware older still. SequenceValidator's to check.
  kSequenceCounter,

  // The audio gateware's 512-sample frames. FramedStreamValidator's.
  kFramed,
};

// "undetermined", "sequence counter" or "framed": what a log and a sidecar
// say.
const char* StreamFormatName(StreamFormat format);

// Decides a stream's format from its first buffer, and from then on hands every
// buffer to the validator for that format.
//
// The data decides, as it already does between the two sequence-counter block
// lengths: asking the device which gateware it runs would make the one part of
// the engine that must not be wrong depend on a register read that can fail,
// to decide something the stream states plainly. The first buffer after the
// source's opening discard is searched for a framed sync pattern — a bounded,
// read-only look at its first few thousand samples (DetectFramedStream) — and
// a stream that does not confirm as framed goes to SequenceValidator untouched,
// so a board on the original gateware is validated exactly as it was before
// the framed format existed.
//
// Decided once, on the first buffer, and never revisited: a stream does not
// change format partway through, and a validator that kept looking would be
// one that could be talked out of a failure.
//
// A first buffer too short to hold the detection's two frames (about 3 KiB)
// cannot be called framed. No ring this application builds has slots that
// small.
//
// Thread-safety: none. Owned by the processing thread.
class StreamValidator {
 public:
  struct Options {
    // Framed streams only. A sequence-counter stream fails on its first
    // mismatch whatever this says, exactly as it always has.
    bool continue_after_sync_loss = false;
  };

  struct Outcome {
    StreamFormat format = StreamFormat::kUndetermined;

    // False for a fault the capture cannot continue past, in either format.
    bool ok = true;

    // Whichever validator ran, it measured this.
    BufferTally tally;

    // The format was decided by this call, and what detection saw.
    bool format_decided_here = false;
    FramedDetection detection;

    // The details of the validator that ran. Only the one for `format` means
    // anything.
    SequenceValidator::Outcome sequence;
    FramedStreamValidator::Outcome framed;
  };

  // Validate, strip and measure one buffer, deciding the format first if this
  // is the first one.
  Outcome Process(uint8_t* buffer, size_t byte_count);

  StreamFormat format() const { return format_; }

  // The state of whichever validator is running, in their shared vocabulary.
  SequenceState state() const;

  // Losses a framed stream recovered from. Always zero for a sequence-counter
  // stream, which recovers from none.
  uint64_t sync_losses() const { return framed_.sync_losses(); }

  // The audio the most recent buffer completed, one stereo pair per frame.
  // Empty for any stream that is not framed. Valid until the next Process().
  const std::vector<AudioFrame>& audio() const { return audio_; }

  void Reset(const Options& options);

 private:
  Options options_;
  StreamFormat format_ = StreamFormat::kUndetermined;
  SequenceValidator sequence_;
  FramedStreamValidator framed_;

  // Reused from buffer to buffer. Sized on the first framed buffer to the most
  // frames one can complete, so nothing is allocated once a capture is
  // running.
  std::vector<AudioFrame> audio_;
};

}  // namespace ddd::capture
