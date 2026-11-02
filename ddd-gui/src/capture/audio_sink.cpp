/************************************************************************

    audio_sink.cpp

    Writing a framed stream's audio beside the RF capture
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#include "audio_sink.h"

#include <algorithm>
#include <system_error>

#include "capture_format.h"

namespace ddd::capture {
namespace {

// Frames converted per write to the file. Two buffers' worth at the full rate,
// so one write per buffer in the ordinary case.
constexpr size_t kWriteChunkFrames = 4096;

// The " (n)" attempts before giving up and taking the last one, the same bound
// the capture's own naming uses.
constexpr int kMaximumNameAttempts = 1000;

int32_t Magnitude(int32_t value) { return value < 0 ? -value : value; }

void PutSigned16(uint8_t* out, int16_t value) {
  const auto bits = static_cast<uint16_t>(value);
  out[0] = static_cast<uint8_t>(bits & 0xFF);
  out[1] = static_cast<uint8_t>(bits >> 8);
}

void PutSigned24(uint8_t* out, int32_t value) {
  const auto bits = static_cast<uint32_t>(value);
  out[0] = static_cast<uint8_t>(bits & 0xFF);
  out[1] = static_cast<uint8_t>((bits >> 8) & 0xFF);
  out[2] = static_cast<uint8_t>((bits >> 16) & 0xFF);
}

}  // namespace

const char* AudioSourceName(AudioSource source) {
  switch (source) {
    case AudioSource::kNone:
      return "none";
    case AudioSource::kIntegrated:
      return "integrated";
    case AudioSource::kExternal:
      return "external";
    case AudioSource::kBoth:
      return "both";
  }
  return "none";
}

std::optional<AudioSource> AudioSourceFromName(std::string_view name) {
  for (const AudioSource source :
       {AudioSource::kNone, AudioSource::kIntegrated, AudioSource::kExternal,
        AudioSource::kBoth}) {
    if (name == AudioSourceName(source)) {
      return source;
    }
  }
  return std::nullopt;
}

size_t AudioBytesPerFrame(AudioConverter converter) {
  return converter == AudioConverter::kIntegrated
             ? kIntegratedAudioBytesPerFrame
             : kExternalAudioBytesPerFrame;
}

std::filesystem::path AudioFilePath(const std::filesystem::path& capture_path,
                                    AudioConverter converter) {
  return std::filesystem::path(StripCaptureFileSuffix(capture_path.string()) +
                               (converter == AudioConverter::kIntegrated
                                    ? kIntegratedAudioFileSuffix
                                    : kExternalAudioFileSuffix));
}

std::filesystem::path MakeUniqueAudioPath(const std::filesystem::path& wanted) {
  std::error_code error;
  if (!std::filesystem::exists(wanted, error)) {
    return wanted;
  }

  // The number goes in front of the extension rather than in front of
  // "_audio_": "Casper (1)_audio_…" would read as the audio of a capture
  // called "Casper (1)", which may well exist.
  const std::string full = wanted.string();
  const std::string extension = wanted.extension().string();
  const std::string base = full.substr(0, full.size() - extension.size());

  std::filesystem::path candidate = wanted;
  for (int copy = 1; copy < kMaximumNameAttempts; ++copy) {
    candidate = std::filesystem::path(base + " (" + std::to_string(copy) + ")" +
                                      extension);
    if (!std::filesystem::exists(candidate, error)) {
      return candidate;
    }
  }
  return candidate;
}

RawAudioWriter::RawAudioWriter(AudioConverter converter)
    : converter_(converter) {}

RawAudioWriter::~RawAudioWriter() { Finish(); }

bool RawAudioWriter::Open(const std::filesystem::path& file_path) {
  file_path_ = file_path;

  file_.open(file_path, std::ios::out | std::ios::binary | std::ios::trunc);
  if (!file_.is_open()) {
    last_error_ = "RawAudioWriter::Open(): Failed to create the audio file " +
                  file_path.string();
    return false;
  }

  tally_ = AudioFileTally{};
  tally_.open = true;
  finished_ = false;
  scratch_.resize(kWriteChunkFrames * AudioBytesPerFrame(converter_));
  return true;
}

bool RawAudioWriter::Write(std::span<const AudioFrame> frames) {
  if (!file_.is_open()) {
    last_error_ = "RawAudioWriter::Write(): The audio file is not open";
    return false;
  }

  const size_t frame_bytes = AudioBytesPerFrame(converter_);
  const bool integrated = converter_ == AudioConverter::kIntegrated;
  const int32_t minimum_rail =
      integrated ? kIntegratedAudioMinimum : kExternalAudioMinimum;
  const int32_t maximum_rail =
      integrated ? kIntegratedAudioMaximum : kExternalAudioMaximum;

  size_t done = 0;
  while (done < frames.size()) {
    const size_t count = std::min(kWriteChunkFrames, frames.size() - done);

    for (size_t index = 0; index < count; ++index) {
      const AudioFrame& frame = frames[done + index];
      const int32_t left =
          integrated ? frame.integrated_left : frame.external_left;
      const int32_t right =
          integrated ? frame.integrated_right : frame.external_right;

      for (const int32_t value : {left, right}) {
        tally_.peak = std::max(tally_.peak, Magnitude(value));
        if (value == minimum_rail || value == maximum_rail) {
          ++tally_.clipped_samples;
        }
      }

      // Byte by byte, so the file is little-endian whatever wrote it.
      uint8_t* const out = scratch_.data() + (index * frame_bytes);
      if (integrated) {
        PutSigned16(out, IntegratedAudioToSigned16(left));
        PutSigned16(out + 2, IntegratedAudioToSigned16(right));
      } else {
        PutSigned24(out, left);
        PutSigned24(out + 3, right);
      }
    }

    const size_t bytes = count * frame_bytes;
    file_.write(reinterpret_cast<const char*>(scratch_.data()),
                static_cast<std::streamsize>(bytes));
    if (!file_.good()) {
      last_error_ =
          "RawAudioWriter::Write(): Failed to write to the audio "
          "file " +
          file_path_.string();
      return false;
    }

    tally_.frames += count;
    tally_.bytes += bytes;
    done += count;
  }

  return true;
}

bool RawAudioWriter::Finish() {
  if (finished_ || !file_.is_open()) {
    return true;
  }
  finished_ = true;

  file_.flush();
  const bool good = file_.good();
  file_.close();

  if (!good) {
    last_error_ = "RawAudioWriter::Finish(): Failed to flush the audio file " +
                  file_path_.string();
    return false;
  }
  return true;
}

CaptureSinkWithAudio::CaptureSinkWithAudio(
    std::unique_ptr<ISampleSink> rf, std::unique_ptr<RawAudioWriter> integrated,
    std::unique_ptr<RawAudioWriter> external)
    : rf_(std::move(rf)),
      integrated_(std::move(integrated)),
      external_(std::move(external)) {
  name_ = std::string(rf_->Name()) + " with audio";
}

CaptureSinkWithAudio::~CaptureSinkWithAudio() { Finish(); }

bool CaptureSinkWithAudio::Write(const uint8_t* wire_data,
                                 size_t sample_count) {
  return rf_->Write(wire_data, sample_count);
}

bool CaptureSinkWithAudio::WriteAudio(std::span<const AudioFrame> frames) {
  for (RawAudioWriter* writer : {integrated_.get(), external_.get()}) {
    if (writer != nullptr && !writer->Write(frames)) {
      last_error_ = writer->LastError();
      return false;
    }
  }
  return true;
}

bool CaptureSinkWithAudio::Finish() {
  if (finished_) {
    return last_error_.empty();
  }
  finished_ = true;

  // The RF file first, because it is the capture: an audio file that cannot be
  // flushed is worth reporting, and is not a reason to leave the recording
  // unfinished.
  bool good = rf_->Finish();
  if (!good) {
    last_error_ = rf_->LastError();
  }

  for (RawAudioWriter* writer : {integrated_.get(), external_.get()}) {
    if (writer != nullptr && !writer->Finish()) {
      if (good) {
        last_error_ = writer->LastError();
      }
      good = false;
    }
  }
  return good;
}

AudioWriteSummary CaptureSinkWithAudio::AudioWritten() const {
  AudioWriteSummary summary;
  if (integrated_ != nullptr) {
    summary.integrated = integrated_->tally();
  }
  if (external_ != nullptr) {
    summary.external = external_->tally();
  }
  return summary;
}

const std::string& CaptureSinkWithAudio::LastError() const {
  return last_error_.empty() ? rf_->LastError() : last_error_;
}

}  // namespace ddd::capture
