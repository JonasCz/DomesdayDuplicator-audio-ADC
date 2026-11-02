/************************************************************************

    test_sdram_status.cpp

    T1 tests for the SDRAM buffer's in-band status
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#include <gtest/gtest.h>

#include <vector>

#include "framed_format.h"
#include "framed_stream_validator.h"
#include "framed_wire_data.h"
#include "sdram_status.h"

namespace ddd::capture {
namespace {

using test::FramedStreamBuilder;

// A status word put together by hand: version, the three flags, the fill.
constexpr uint32_t Word(uint32_t version, bool active, bool initialised,
                        bool overflowed, uint32_t rows) {
  return (version << 20) | (active ? 0x80000U : 0U) |
         (initialised ? 0x40000U : 0U) | (overflowed ? 0x20000U : 0U) |
         (rows & 0xFFFFU);
}

AudioFrame Carrying(uint32_t word) {
  AudioFrame frame;
  frame.reserved_word = word;
  return frame;
}

// --- The word ----------------------------------------------------------------

TEST(SdramStatusTest, EveryFieldIsReadFromItsOwnBits) {
  const SdramStatus status =
      DecodeSdramStatus(Word(1, true, false, true, 1234));
  EXPECT_TRUE(status.present);
  EXPECT_TRUE(status.active);
  EXPECT_FALSE(status.initialised);
  EXPECT_TRUE(status.overflowed);
  EXPECT_EQ(status.fill_rows, 1234U);

  const SdramStatus other = DecodeSdramStatus(Word(1, false, true, false, 0));
  EXPECT_FALSE(other.active);
  EXPECT_TRUE(other.initialised);
  EXPECT_FALSE(other.overflowed);
}

TEST(SdramStatusTest, AudioOnlyGatewaresZeroesAreNoStatusAtAll) {
  EXPECT_FALSE(DecodeSdramStatus(0).present);
}

TEST(SdramStatusTest, ALayoutThisBuildDoesNotKnowIsIgnoredRatherThanMisread) {
  for (uint32_t version = 2; version < 16; ++version) {
    EXPECT_FALSE(
        DecodeSdramStatus(Word(version, true, true, true, 100)).present)
        << version;
  }
}

TEST(SdramStatusTest, TheReservedBitChangesNothing) {
  const uint32_t word = Word(1, true, true, false, 77);
  EXPECT_EQ(DecodeSdramStatus(word | 0x10000U).fill_rows, 77U);
  EXPECT_FALSE(DecodeSdramStatus(word | 0x10000U).overflowed);
}

TEST(SdramStatusTest, FullIsThirtyTwoThousandRowsAndNoMore) {
  EXPECT_EQ(DecodeSdramStatus(Word(1, true, true, false, 32'768)).fill_rows,
            32'768U);
  EXPECT_EQ(DecodeSdramStatus(Word(1, true, true, false, 0xFFFF)).fill_rows,
            kSdramCapacityRows);
}

TEST(SdramStatusTest, AFillIsAShareASizeAndALengthOfStream) {
  EXPECT_DOUBLE_EQ(SdramFillPercent(16'384), 50.0);
  EXPECT_DOUBLE_EQ(SdramFillPercent(32'768), 100.0);
  EXPECT_EQ(SdramFillBytes(1), 1024U);
  EXPECT_EQ(SdramFillBytes(32'768), uint64_t{32} << 20);

  // The whole buffer is 16 Mi samples: 419 ms at 40 Msps, twice that at 20.
  EXPECT_NEAR(SdramFillMilliseconds(32'768, 40'000'000), 419.43, 0.01);
  EXPECT_NEAR(SdramFillMilliseconds(32'768, 20'000'000), 838.86, 0.01);
  EXPECT_DOUBLE_EQ(SdramFillMilliseconds(100, 0), 0.0);
}

// --- In the stream -----------------------------------------------------------

TEST(SdramStatusTest, TheWordIsAssembledFromTheFourReservedSlots) {
  // 0x1C1234 as 36 = 0x07, 37 = 0x01, 46 = 0x08, 47 = 0x34 — written into the
  // frame by the independent builder and read back through the validator.
  const uint32_t word = Word(1, true, true, false, 0x1234);
  FramedStreamBuilder::FrameContent content;
  content.reserved = {static_cast<uint8_t>((word >> 18) & 0x3F),
                      static_cast<uint8_t>((word >> 12) & 0x3F),
                      static_cast<uint8_t>((word >> 6) & 0x3F),
                      static_cast<uint8_t>(word & 0x3F)};

  FramedStreamBuilder builder;
  builder.AppendFrames(3, content);

  FramedStreamValidator validator;
  std::vector<AudioFrame> audio;
  ASSERT_TRUE(
      validator.Process(builder.bytes().data(), builder.bytes().size(), audio)
          .ok);
  ASSERT_EQ(audio.size(), 3U);
  EXPECT_EQ(audio[0].reserved_word, word);
  EXPECT_EQ(DecodeSdramStatus(audio[2].reserved_word).fill_rows, 0x1234U);

  // And the audio beside it is untouched by it.
  EXPECT_EQ(audio[0].integrated_left, 0);
}

// --- Over a run ------------------------------------------------------------

TEST(SdramMonitorTest, NothingIsPresentUntilAReadingIs) {
  SdramMonitor monitor;
  monitor.Accumulate(std::vector<AudioFrame>{Carrying(0), Carrying(0)});
  EXPECT_FALSE(monitor.Snapshot().present);
  EXPECT_EQ(monitor.Snapshot().readings, 0U);
}

TEST(SdramMonitorTest, ThePeakOutlastsTheBufferDraining) {
  SdramMonitor monitor;
  monitor.Accumulate(
      std::vector<AudioFrame>{Carrying(Word(1, true, true, false, 10)),
                              Carrying(Word(1, true, true, false, 9000)),
                              Carrying(Word(1, true, true, false, 300))});

  const SdramSnapshot snapshot = monitor.Snapshot();
  EXPECT_TRUE(snapshot.present);
  EXPECT_EQ(snapshot.current.fill_rows, 300U);
  EXPECT_EQ(snapshot.peak_rows, 9000U);
  EXPECT_TRUE(snapshot.active_seen);
  EXPECT_FALSE(snapshot.overflow_seen);
  EXPECT_EQ(snapshot.readings, 3U);
}

TEST(SdramMonitorTest, AnOverflowIsRememberedForTheRun) {
  SdramMonitor monitor;
  monitor.Accumulate(
      std::vector<AudioFrame>{Carrying(Word(1, true, true, true, 32'768))});
  monitor.Accumulate(
      std::vector<AudioFrame>{Carrying(Word(1, true, true, false, 0))});

  EXPECT_TRUE(monitor.Snapshot().overflow_seen);
  EXPECT_FALSE(monitor.Snapshot().current.overflowed);
  EXPECT_EQ(monitor.Snapshot().peak_rows, 32'768U);
}

TEST(SdramMonitorTest, AReadingInAnUnknownLayoutIsSkippedAlone) {
  SdramMonitor monitor;
  monitor.Accumulate(
      std::vector<AudioFrame>{Carrying(Word(1, true, true, false, 5)),
                              Carrying(Word(3, true, true, true, 30'000))});
  EXPECT_EQ(monitor.Snapshot().peak_rows, 5U);
  EXPECT_FALSE(monitor.Snapshot().overflow_seen);
  EXPECT_EQ(monitor.Snapshot().readings, 1U);
}

TEST(SdramMonitorTest, ResetForgetsTheRun) {
  SdramMonitor monitor;
  monitor.Accumulate(
      std::vector<AudioFrame>{Carrying(Word(1, true, true, true, 100))});
  monitor.Reset();
  EXPECT_FALSE(monitor.Snapshot().present);
  EXPECT_EQ(monitor.Snapshot().peak_rows, 0U);
}

}  // namespace
}  // namespace ddd::capture
