/************************************************************************

    recording_sink.h

    A sink that remembers what it was given
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Simon Inns
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <vector>

#include "framed_format.h"
#include "sample_format.h"
#include "sample_sink.h"

namespace ddd::capture::test {

// Keeps every sample value it is handed, so a test can say exactly what reached
// storage rather than only how much did.
//
// That distinction is the point. "The sink received 4 MB" would pass even if
// the pipeline had written the same buffer twice and dropped another; only the
// values themselves can show that the stream was continuous across a sink
// change.
class RecordingSink : public ISampleSink {
 public:
  const char* Name() const override { return "recording"; }

  bool Write(const uint8_t* wire_data, size_t sample_count) override {
    ++write_calls_;
    samples_per_write_.push_back(sample_count);

    values_.reserve(values_.size() + sample_count);
    for (size_t index = 0; index < sample_count; ++index) {
      const uint16_t word = static_cast<uint16_t>(
          static_cast<uint16_t>(wire_data[index * kBytesPerSample]) |
          static_cast<uint16_t>(
              static_cast<uint16_t>(wire_data[(index * kBytesPerSample) + 1])
              << 8));
      values_.push_back(word);
    }

    samples_written_ += sample_count;
    return !fail_next_write_;
  }

  bool Finish() override {
    finished_ = true;
    return true;
  }

  uint64_t BytesWritten() const override {
    return samples_written_ * kBytesPerSample;
  }
  uint64_t SamplesWritten() const override { return samples_written_; }
  const std::string& LastError() const override { return last_error_; }

  // Kept like the samples, so a test can say which audio reached the sink and
  // in which buffer's call.
  bool WriteAudio(std::span<const AudioFrame> frames) override {
    audio_.insert(audio_.end(), frames.begin(), frames.end());
    audio_after_write_.push_back(write_calls_);
    return true;
  }

  // Make the next Write() fail, so the pipeline's file-error path can be
  // exercised without a full disk.
  void FailNextWrite(const std::string& message) {
    fail_next_write_ = true;
    last_error_ = message;
  }

  bool finished() const { return finished_; }
  uint64_t write_calls() const { return write_calls_; }
  const std::vector<uint16_t>& values() const { return values_; }
  const std::vector<size_t>& samples_per_write() const {
    return samples_per_write_;
  }
  const std::vector<AudioFrame>& audio() const { return audio_; }

  // For each WriteAudio() call, how many Write() calls had been made before it.
  const std::vector<uint64_t>& audio_after_write() const {
    return audio_after_write_;
  }

 private:
  std::vector<uint16_t> values_;
  std::vector<size_t> samples_per_write_;
  std::vector<AudioFrame> audio_;
  std::vector<uint64_t> audio_after_write_;
  uint64_t samples_written_ = 0;
  uint64_t write_calls_ = 0;
  bool finished_ = false;
  bool fail_next_write_ = false;
  std::string last_error_;
};

}  // namespace ddd::capture::test
