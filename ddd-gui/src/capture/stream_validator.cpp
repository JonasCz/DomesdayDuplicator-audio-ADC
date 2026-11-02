/************************************************************************

    stream_validator.cpp

    Which of the two formats a stream is in, and validating it as that
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#include "stream_validator.h"

#include "sample_format.h"

namespace ddd::capture {

const char* StreamFormatName(StreamFormat format) {
  switch (format) {
    case StreamFormat::kUndetermined:
      return "undetermined";
    case StreamFormat::kSequenceCounter:
      return "sequence counter";
    case StreamFormat::kFramed:
      return "framed";
  }
  return "unknown";
}

void StreamValidator::Reset(const Options& options) {
  options_ = options;
  format_ = StreamFormat::kUndetermined;
  sequence_.Reset();
  framed_.Reset(FramedStreamValidator::Options{
      .continue_after_sync_loss = options.continue_after_sync_loss});
  audio_.clear();
}

SequenceState StreamValidator::state() const {
  switch (format_) {
    case StreamFormat::kUndetermined:
      return SequenceState::kSynchronising;
    case StreamFormat::kSequenceCounter:
      return sequence_.state();
    case StreamFormat::kFramed:
      return framed_.state();
  }
  return SequenceState::kSynchronising;
}

StreamValidator::Outcome StreamValidator::Process(uint8_t* buffer,
                                                  size_t byte_count) {
  Outcome outcome;
  audio_.clear();

  const size_t sample_count = byte_count / kBytesPerSample;

  if (format_ == StreamFormat::kUndetermined && sample_count > 0) {
    outcome.detection = DetectFramedStream(buffer, sample_count);
    outcome.format_decided_here = true;
    format_ = outcome.detection.framed ? StreamFormat::kFramed
                                       : StreamFormat::kSequenceCounter;

    if (format_ == StreamFormat::kFramed) {
      // The most frames a buffer of this size can complete, plus one for a
      // frame begun in the buffer before. Slots are all one size, so this is
      // the only allocation the audio ever needs.
      audio_.reserve((sample_count / kFrameSamples) + 2);
    }
  }

  outcome.format = format_;

  switch (format_) {
    case StreamFormat::kUndetermined:
      break;
    case StreamFormat::kSequenceCounter:
      outcome.sequence = sequence_.Process(buffer, byte_count);
      outcome.ok = outcome.sequence.ok;
      outcome.tally = outcome.sequence.tally;
      break;
    case StreamFormat::kFramed:
      outcome.framed = framed_.Process(buffer, byte_count, audio_);
      outcome.ok = outcome.framed.ok;
      outcome.tally = outcome.framed.tally;
      break;
  }

  return outcome;
}

}  // namespace ddd::capture
