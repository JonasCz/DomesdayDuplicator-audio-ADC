/************************************************************************

    test_audio_sink.cpp

    T1 tests for the audio files, their names and the levels shown
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#include <gtest/gtest.h>

#include <cmath>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

#include "audio_metrics.h"
#include "audio_sink.h"
#include "framed_format.h"
#include "recording_sink.h"

namespace ddd::capture {
namespace {

std::vector<uint8_t> ReadBytes(const std::filesystem::path& path) {
  std::ifstream file(path, std::ios::binary);
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(file),
                              std::istreambuf_iterator<char>());
}

AudioFrame Frame(int32_t integrated_left, int32_t integrated_right,
                 int32_t external_left, int32_t external_right) {
  AudioFrame frame;
  frame.integrated_left = integrated_left;
  frame.integrated_right = integrated_right;
  frame.external_left = external_left;
  frame.external_right = external_right;
  return frame;
}

class AudioSinkTest : public ::testing::Test {
 protected:
  void SetUp() override {
    directory_ =
        std::filesystem::temp_directory_path() /
        (std::string("ddd-audio-sink-test-") +
         ::testing::UnitTest::GetInstance()->current_test_info()->name());
    std::filesystem::remove_all(directory_);
    std::filesystem::create_directories(directory_);
  }

  void TearDown() override { std::filesystem::remove_all(directory_); }

  std::filesystem::path directory_;
};

// --- Names -------------------------------------------------------------------

TEST(AudioSourceTest, EachSourceRoundTripsThroughItsName) {
  for (const AudioSource source :
       {AudioSource::kNone, AudioSource::kIntegrated, AudioSource::kExternal,
        AudioSource::kBoth}) {
    EXPECT_EQ(AudioSourceFromName(AudioSourceName(source)), source);
  }
  EXPECT_FALSE(AudioSourceFromName("pcm1802").has_value());
  EXPECT_FALSE(AudioSourceFromName("").has_value());
}

TEST(AudioSourceTest, BothRecordsBothAndNoneRecordsNeither) {
  EXPECT_FALSE(RecordsIntegratedAudio(AudioSource::kNone));
  EXPECT_FALSE(RecordsExternalAudio(AudioSource::kNone));
  EXPECT_TRUE(RecordsIntegratedAudio(AudioSource::kIntegrated));
  EXPECT_FALSE(RecordsExternalAudio(AudioSource::kIntegrated));
  EXPECT_FALSE(RecordsIntegratedAudio(AudioSource::kExternal));
  EXPECT_TRUE(RecordsExternalAudio(AudioSource::kExternal));
  EXPECT_TRUE(RecordsIntegratedAudio(AudioSource::kBoth));
  EXPECT_TRUE(RecordsExternalAudio(AudioSource::kBoth));
}

TEST(AudioFileNameTest, TheAudioIsNamedAfterTheCaptureLessItsSuffix) {
  // The fork's names, so a tool written for its files finds these.
  EXPECT_EQ(
      AudioFilePath("/c/Casper side 1.ddd.flac", AudioConverter::kIntegrated),
      std::filesystem::path("/c/Casper side 1_audio_integrated_adc.s16"));
  EXPECT_EQ(
      AudioFilePath("/c/Casper side 1.ddd.flac", AudioConverter::kExternal),
      std::filesystem::path("/c/Casper side 1_audio_external_adc.s24"));
  EXPECT_EQ(AudioFilePath("/c/RF-Sample.ddd.s16", AudioConverter::kExternal),
            std::filesystem::path("/c/RF-Sample_audio_external_adc.s24"));
}

TEST_F(AudioSinkTest, AnAudioFileAlreadyThereIsNeverOverwritten) {
  const std::filesystem::path wanted =
      directory_ / "Casper_audio_integrated_adc.s16";
  EXPECT_EQ(MakeUniqueAudioPath(wanted), wanted);

  std::ofstream(wanted) << "an earlier capture's audio";
  const std::filesystem::path first = MakeUniqueAudioPath(wanted);
  EXPECT_EQ(first, directory_ / "Casper_audio_integrated_adc (1).s16");

  std::ofstream(first) << "and another";
  EXPECT_EQ(MakeUniqueAudioPath(wanted),
            directory_ / "Casper_audio_integrated_adc (2).s16");
}

// --- The files ---------------------------------------------------------------

TEST_F(AudioSinkTest, TheIntegratedFileIsSigned16BitInterleavedLittleEndian) {
  const std::filesystem::path path = directory_ / "a.s16";
  RawAudioWriter writer(AudioConverter::kIntegrated);
  ASSERT_TRUE(writer.Open(path));

  const std::vector<AudioFrame> frames = {Frame(-2048, 2047, 0, 0),
                                          Frame(1, -1, 0, 0),
                                          Frame(0, 0x123 - 2048, 0, 0)};
  ASSERT_TRUE(writer.Write(frames));
  ASSERT_TRUE(writer.Finish());

  // Each value times sixteen, left then right, low byte first. Written out by
  // hand:
  //   -2048 * 16 = -32768 = 0x8000      2047 * 16 = 32752 = 0x7FF0
  //   1 * 16 = 0x0010                   -1 * 16 = -16 = 0xFFF0
  //   0                                 (0x123 - 2048) * 16 = -28112 = 0x9230
  const std::vector<uint8_t> expected = {0x00, 0x80, 0xF0, 0x7F, 0x10, 0x00,
                                         0xF0, 0xFF, 0x00, 0x00, 0x30, 0x92};
  EXPECT_EQ(ReadBytes(path), expected);

  EXPECT_EQ(writer.tally().frames, 3U);
  EXPECT_EQ(writer.tally().bytes, 12U);
  EXPECT_EQ(writer.tally().clipped_samples, 2U);
  EXPECT_EQ(writer.tally().peak, 2048);
}

TEST_F(AudioSinkTest, TheExternalFileIsSigned24BitInThreeBytes) {
  const std::filesystem::path path = directory_ / "a.s24";
  RawAudioWriter writer(AudioConverter::kExternal);
  ASSERT_TRUE(writer.Open(path));

  const std::vector<AudioFrame> frames = {Frame(0, 0, -8'388'608, 8'388'607),
                                          Frame(0, 0, -1, 0x123456),
                                          Frame(0, 0, 0, -0x123456)};
  ASSERT_TRUE(writer.Write(frames));
  ASSERT_TRUE(writer.Finish());

  //   -8388608 = 0x800000      8388607 = 0x7FFFFF
  //   -1 = 0xFFFFFF            0x123456
  //   0                        -0x123456 = 0xEDCBAA
  const std::vector<uint8_t> expected = {0x00, 0x00, 0x80, 0xFF, 0xFF, 0x7F,
                                         0xFF, 0xFF, 0xFF, 0x56, 0x34, 0x12,
                                         0x00, 0x00, 0x00, 0xAA, 0xCB, 0xED};
  EXPECT_EQ(ReadBytes(path), expected);

  EXPECT_EQ(writer.tally().frames, 3U);
  EXPECT_EQ(writer.tally().bytes, 18U);
  EXPECT_EQ(writer.tally().clipped_samples, 2U);
  EXPECT_EQ(writer.tally().peak, 8'388'608);
}

TEST_F(AudioSinkTest, AWriteLongerThanTheScratchBufferIsWrittenWhole) {
  const std::filesystem::path path = directory_ / "long.s24";
  RawAudioWriter writer(AudioConverter::kExternal);
  ASSERT_TRUE(writer.Open(path));

  std::vector<AudioFrame> frames;
  for (int32_t index = 0; index < 10'000; ++index) {
    frames.push_back(Frame(0, 0, index, -index));
  }
  ASSERT_TRUE(writer.Write(frames));
  ASSERT_TRUE(writer.Finish());

  const std::vector<uint8_t> bytes = ReadBytes(path);
  ASSERT_EQ(bytes.size(), 60'000U);

  // Frame 9,999's left channel, at its own offset.
  const size_t offset = size_t{9'999} * 6;
  EXPECT_EQ(bytes[offset], 9'999 & 0xFF);
  EXPECT_EQ(bytes[offset + 1], (9'999 >> 8) & 0xFF);
  EXPECT_EQ(bytes[offset + 2], 0);
}

TEST_F(AudioSinkTest, AFileThatCannotBeCreatedSaysSo) {
  RawAudioWriter writer(AudioConverter::kIntegrated);
  EXPECT_FALSE(writer.Open(directory_ / "no such folder" / "a.s16"));
  EXPECT_NE(writer.LastError().find("audio file"), std::string::npos);
  EXPECT_FALSE(writer.Write(std::vector<AudioFrame>{Frame(0, 0, 0, 0)}));
}

TEST_F(AudioSinkTest, TheCombinedSinkPassesTheRfThroughAndKeepsTheAudio) {
  auto rf = std::make_unique<test::RecordingSink>();
  test::RecordingSink* const rf_view = rf.get();

  auto integrated =
      std::make_unique<RawAudioWriter>(AudioConverter::kIntegrated);
  auto external = std::make_unique<RawAudioWriter>(AudioConverter::kExternal);
  ASSERT_TRUE(integrated->Open(directory_ / "i.s16"));
  ASSERT_TRUE(external->Open(directory_ / "e.s24"));

  CaptureSinkWithAudio sink(std::move(rf), std::move(integrated),
                            std::move(external));
  EXPECT_TRUE(sink.StoresData());

  const std::vector<uint8_t> wire = {0x10, 0x02, 0x20, 0x01};
  ASSERT_TRUE(sink.Write(wire.data(), 2));
  ASSERT_TRUE(sink.WriteAudio(
      std::vector<AudioFrame>{Frame(5, 6, 7, 8), Frame(-5, -6, -7, -8)}));

  // The RF figures are the RF sink's alone.
  EXPECT_EQ(sink.SamplesWritten(), 2U);
  EXPECT_EQ(sink.BytesWritten(), rf_view->BytesWritten());

  const AudioWriteSummary summary = sink.AudioWritten();
  EXPECT_TRUE(summary.integrated.open);
  EXPECT_TRUE(summary.external.open);
  EXPECT_EQ(summary.integrated.frames, 2U);
  EXPECT_EQ(summary.integrated.bytes, 8U);
  EXPECT_EQ(summary.external.bytes, 12U);

  ASSERT_TRUE(sink.Finish());
  EXPECT_TRUE(rf_view->finished());
  EXPECT_EQ(ReadBytes(directory_ / "i.s16").size(), 8U);
  EXPECT_EQ(ReadBytes(directory_ / "e.s24").size(), 12U);

  // Finishing twice is harmless, as every sink's is.
  EXPECT_TRUE(sink.Finish());
}

TEST_F(AudioSinkTest, OneConverterAloneIsOneFileAlone) {
  auto external = std::make_unique<RawAudioWriter>(AudioConverter::kExternal);
  ASSERT_TRUE(external->Open(directory_ / "e.s24"));
  CaptureSinkWithAudio sink(std::make_unique<test::RecordingSink>(), nullptr,
                            std::move(external));

  ASSERT_TRUE(sink.WriteAudio(std::vector<AudioFrame>{Frame(1, 2, 3, 4)}));
  const AudioWriteSummary summary = sink.AudioWritten();
  EXPECT_FALSE(summary.integrated.open);
  EXPECT_TRUE(summary.external.open);
  EXPECT_EQ(summary.external.frames, 1U);
}

TEST(NullSinkAudioTest, ASinkThatKeepsNoAudioAcceptsItAndKeepsNone) {
  NullSink sink;
  EXPECT_TRUE(sink.WriteAudio(std::vector<AudioFrame>{AudioFrame{}}));
  EXPECT_FALSE(sink.AudioWritten().integrated.open);
  EXPECT_FALSE(sink.AudioWritten().external.open);
}

// --- Levels ------------------------------------------------------------------

TEST(AudioMetricsTest, NothingIsMeasuredUntilAFrameArrives) {
  AudioMetrics metrics;
  metrics.Accumulate({});
  EXPECT_FALSE(metrics.Snapshot().integrated.measured);
  EXPECT_FALSE(metrics.Snapshot().external.measured);
}

TEST(AudioMetricsTest, EachConverterIsMeasuredOnItsOwnScale) {
  AudioMetrics metrics;
  metrics.Accumulate(std::vector<AudioFrame>{Frame(-100, 300, 1000, -2000),
                                             Frame(2047, -5, -8'388'608, 7)});

  const AudioMetricsSnapshot snapshot = metrics.Snapshot();
  EXPECT_TRUE(snapshot.integrated.measured);
  EXPECT_EQ(snapshot.integrated.frames, 2U);
  EXPECT_EQ(snapshot.integrated.minimum, -100);
  EXPECT_EQ(snapshot.integrated.maximum, 2047);
  EXPECT_EQ(snapshot.integrated.peak, 2047);
  EXPECT_EQ(snapshot.integrated.clipped, 1U);
  EXPECT_EQ(snapshot.integrated.recent_peak_left, 2047);
  EXPECT_EQ(snapshot.integrated.recent_peak_right, 300);

  EXPECT_EQ(snapshot.external.minimum, -8'388'608);
  EXPECT_EQ(snapshot.external.maximum, 1000);
  EXPECT_EQ(snapshot.external.peak, 8'388'608);
  EXPECT_EQ(snapshot.external.clipped, 1U);
  EXPECT_EQ(snapshot.external.recent_peak_left, 8'388'608);
  EXPECT_EQ(snapshot.external.recent_peak_right, 2000);
}

TEST(AudioMetricsTest, RecentFiguresCoverTheLastBufferAndTheRunKeepsTheWorst) {
  AudioMetrics metrics;
  metrics.Accumulate(std::vector<AudioFrame>{Frame(-2048, 0, 0, 0)});
  metrics.Accumulate(std::vector<AudioFrame>{Frame(10, -20, 0, 0)});

  const AudioLevel level = metrics.Snapshot().integrated;
  EXPECT_EQ(level.recent_peak_left, 10);
  EXPECT_EQ(level.recent_peak_right, 20);
  EXPECT_EQ(level.recent_clipped, 0U);
  EXPECT_EQ(level.clipped, 1U);
  EXPECT_EQ(level.peak, 2048);
  EXPECT_EQ(level.minimum, -2048);
}

TEST(AudioMetricsTest, FullScaleIsZeroDecibelsAndSilenceHasNoLevel) {
  EXPECT_DOUBLE_EQ(DecibelsFullScale(2048, kIntegratedAudioFullScale), 0.0);
  EXPECT_NEAR(DecibelsFullScale(1024, kIntegratedAudioFullScale), -6.0206,
              1e-3);
  EXPECT_NEAR(DecibelsFullScale(8'388'608 / 10, kExternalAudioFullScale), -20.0,
              1e-5);
  EXPECT_TRUE(std::isinf(DecibelsFullScale(0, kExternalAudioFullScale)));
}

}  // namespace
}  // namespace ddd::capture
