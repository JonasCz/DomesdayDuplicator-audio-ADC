/************************************************************************

    audio_sink.h

    Writing a framed stream's audio beside the RF capture
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "audio_metrics.h"
#include "framed_format.h"
#include "sample_sink.h"

namespace ddd::capture {

// Which of the board's two audio converters a capture records.
//
// The integrated converter is the ADC128S022 on the Duplicator board itself;
// the external one is a PCM1802 on a board of its own. Both reach the host in
// every frame of a framed stream whether or not anything records them, so this
// decides only which files are written.
enum class AudioSource {
  kNone,
  kIntegrated,
  kExternal,
  kBoth,
};

// The word a settings file and a command line use: "none", "integrated",
// "external" or "both".
const char* AudioSourceName(AudioSource source);
std::optional<AudioSource> AudioSourceFromName(std::string_view name);

inline constexpr bool RecordsIntegratedAudio(AudioSource source) {
  return source == AudioSource::kIntegrated || source == AudioSource::kBoth;
}
inline constexpr bool RecordsExternalAudio(AudioSource source) {
  return source == AudioSource::kExternal || source == AudioSource::kBoth;
}

// One of the two converters, as a file.
enum class AudioConverter {
  // Signed 16-bit little-endian, the 12-bit reading shifted up by four.
  kIntegrated,

  // Signed 24-bit little-endian, three bytes a sample, as the converter
  // delivered it.
  kExternal,
};

// What each file is called after the capture it sits beside: the capture's
// name, less its own suffix, with one of these on the end. The names the fork's
// capture application used, so that a tool written for its files finds these.
inline constexpr const char* kIntegratedAudioFileSuffix =
    "_audio_integrated_adc.s16";
inline constexpr const char* kExternalAudioFileSuffix =
    "_audio_external_adc.s24";

// Bytes per stereo frame in each file.
inline constexpr size_t kIntegratedAudioBytesPerFrame = 4;
inline constexpr size_t kExternalAudioBytesPerFrame = 6;

size_t AudioBytesPerFrame(AudioConverter converter);

// The file a converter's audio is written to, for a capture at
// `capture_path`.
std::filesystem::path AudioFilePath(const std::filesystem::path& capture_path,
                                    AudioConverter converter);

// The same path, or one with " (1)", " (2)", … before its suffix if something
// is already there. A capture's own name is made unique before it is opened,
// and an audio file left behind by an earlier capture under the same name must
// not be overwritten by a new one either.
std::filesystem::path MakeUniqueAudioPath(const std::filesystem::path& wanted);

// One converter's audio, written to a headerless file of interleaved stereo
// samples, left first.
//
// Headerless because that is what the fork wrote and what the tools built
// around it read — and like the uncompressed RF format, it means the rate is
// known only because somebody wrote it down. The capture's sidecar is where it
// is written down.
//
// Synchronous, on the processing thread, as RawSink's writes are. The rate is
// what makes that safe: a frame is 512 RF samples, so a 2 MB buffer carries
// 2,048 audio samples — 8 KiB for one file and 12 KiB for the other, through a
// buffered stream, beside the 2 MB the RF sink takes from the same buffer.
//
// Thread-safety: as ISampleSink — the processing thread writes; the tally is
// read only once the writer has been handed back.
class RawAudioWriter {
 public:
  explicit RawAudioWriter(AudioConverter converter);
  ~RawAudioWriter();

  RawAudioWriter(const RawAudioWriter&) = delete;
  RawAudioWriter& operator=(const RawAudioWriter&) = delete;
  RawAudioWriter(RawAudioWriter&&) = delete;
  RawAudioWriter& operator=(RawAudioWriter&&) = delete;

  // Create the file. Returns false with the reason in LastError().
  bool Open(const std::filesystem::path& file_path);

  bool Write(std::span<const AudioFrame> frames);

  // Flush and close. Safe to call twice; the destructor calls it.
  bool Finish();

  AudioConverter converter() const { return converter_; }
  const std::filesystem::path& file_path() const { return file_path_; }
  const AudioFileTally& tally() const { return tally_; }
  const std::string& LastError() const { return last_error_; }

 private:
  AudioConverter converter_;
  std::ofstream file_;
  std::filesystem::path file_path_;
  std::string last_error_;

  // The converted frames on their way to the file. Sized once at Open().
  std::vector<uint8_t> scratch_;

  AudioFileTally tally_;
  bool finished_ = false;
};

// An RF sink with audio files beside it.
//
// The RF sink does everything it did before — this forwards every call to it
// — and the audio the validator took out of each buffer reaches the writers
// through WriteAudio(). It is one sink rather than two because the pipeline
// changes sinks atomically at a buffer boundary: as one object, the RF file and
// its audio start and stop at the same buffer by construction, where two would
// need a second handover that could land one buffer apart.
class CaptureSinkWithAudio : public ISampleSink {
 public:
  // Either writer may be null, for a capture recording one converter.
  CaptureSinkWithAudio(std::unique_ptr<ISampleSink> rf,
                       std::unique_ptr<RawAudioWriter> integrated,
                       std::unique_ptr<RawAudioWriter> external);
  ~CaptureSinkWithAudio() override;

  const char* Name() const override { return name_.c_str(); }
  bool StoresData() const override { return rf_->StoresData(); }

  bool Write(const uint8_t* wire_data, size_t sample_count) override;
  bool WriteAudio(std::span<const AudioFrame> frames) override;
  bool Finish() override;

  // The RF file's figures. The audio files' are AudioWritten()'s: the panels
  // and the sidecar describe the two separately, and a byte count that summed
  // them would describe neither.
  uint64_t BytesWritten() const override { return rf_->BytesWritten(); }
  uint64_t SamplesWritten() const override { return rf_->SamplesWritten(); }
  uint64_t SamplesPending() const override { return rf_->SamplesPending(); }

  AudioWriteSummary AudioWritten() const override;

  const std::string& LastError() const override;

  ISampleSink& rf() { return *rf_; }

 private:
  std::unique_ptr<ISampleSink> rf_;
  std::unique_ptr<RawAudioWriter> integrated_;
  std::unique_ptr<RawAudioWriter> external_;
  std::string name_;
  std::string last_error_;
  bool finished_ = false;
};

}  // namespace ddd::capture
