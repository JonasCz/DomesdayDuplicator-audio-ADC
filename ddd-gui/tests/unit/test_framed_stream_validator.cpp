/************************************************************************

    test_framed_stream_validator.cpp

    T1 tests for the framed format: detection, validation and audio
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#include <gtest/gtest.h>

#include <array>
#include <chrono>
#include <cstring>
#include <iostream>
#include <vector>

#include "framed_format.h"
#include "framed_stream_validator.h"
#include "framed_wire_data.h"
#include "sample_format.h"
#include "sequence_validator.h"
#include "stream_validator.h"
#include "wire_data.h"

namespace ddd::capture {
namespace {

using test::FramedStreamBuilder;

constexpr uint64_t kCounterMask = (uint64_t{1} << 48) - 1;

FramedStreamValidator::Options Continuing() {
  return FramedStreamValidator::Options{.continue_after_sync_loss = true};
}

// The top six bits of a sample, read straight off the bytes.
uint8_t TopBits(const std::vector<uint8_t>& bytes, size_t index) {
  return static_cast<uint8_t>(bytes[(index * 2) + 1] >> 2);
}

// --- The format's constants ------------------------------------------------

TEST(FramedFormatTest, TheSyncChunksAreTheGatewaresLiteralSixBitsAtATime) {
  // The engine holds the pattern as four 48-bit quarters; the builder reads it
  // out of the gateware's own 192-bit literal. They must agree chunk for chunk.
  for (size_t k = 0; k < kFrameSyncSamples; ++k) {
    EXPECT_EQ(kSyncChunks[k], FramedStreamBuilder::SyncChunk(k))
        << "chunk " << k;
  }

  // And a spot check worked by hand: the literal ends ...987654, and the low
  // six bits of 0x654 are 0b010100.
  EXPECT_EQ(kSyncChunks[0], 0x14);
  EXPECT_EQ(kSyncChunks[1], 0x19);  // 0x654 >> 6 = 0x19
}

TEST(FramedFormatTest, TheAudioRateIsTheStreamRateOverAFrame) {
  EXPECT_DOUBLE_EQ(FramedAudioSampleRateHz(40'000'000), 78'125.0);
  EXPECT_DOUBLE_EQ(FramedAudioSampleRateHz(20'000'000), 39'062.5);
}

TEST(FramedFormatTest, TheConvertersReadingsAreDecodedBitForBit) {
  // Sixteen chunks for positions 32..47, written out by hand.
  //
  //   integrated left  0x123 -> chunks 0x04, 0x23 -> 0x123 - 2048 = -1757
  //   integrated right 0xFFF -> chunks 0x3F, 0x3F -> 2047
  //   reserved          0x2A, 0x15 (ignored by the audio)
  //   external left    0x123456 -> 0x04, 0x23, 0x11, 0x16 -> 1193046
  //   external right   0x800001 -> 0x20, 0x00, 0x00, 0x01 -> -8388607
  //   reserved          0x3F, 0x3F
  const std::array<uint8_t, 16> chunks = {0x04, 0x23, 0x3F, 0x3F, 0x2A, 0x15,
                                          0x04, 0x23, 0x11, 0x16, 0x20, 0x00,
                                          0x00, 0x01, 0x3F, 0x3F};
  const AudioFrame frame = DecodeAudioFrame(chunks);
  EXPECT_EQ(frame.integrated_left, 0x123 - 2048);
  EXPECT_EQ(frame.integrated_right, 2047);
  EXPECT_EQ(frame.external_left, 0x123456);
  EXPECT_EQ(frame.external_right, -8'388'607);
}

TEST(FramedFormatTest, TheConvertersRailsAndZeroLandWhereTheyShould) {
  EXPECT_EQ(CentreIntegratedAudio(0x000), -2048);
  EXPECT_EQ(CentreIntegratedAudio(0x800), 0);
  EXPECT_EQ(CentreIntegratedAudio(0xFFF), 2047);

  EXPECT_EQ(SignExtendExternalAudio(0x800000), -8'388'608);
  EXPECT_EQ(SignExtendExternalAudio(0x7FFFFF), 8'388'607);
  EXPECT_EQ(SignExtendExternalAudio(0xFFFFFF), -1);
  EXPECT_EQ(SignExtendExternalAudio(0x000000), 0);

  // Scaled by sixteen into a 16-bit file, so full scale is full scale.
  EXPECT_EQ(IntegratedAudioToSigned16(-2048), -32768);
  EXPECT_EQ(IntegratedAudioToSigned16(2047), 32752);
  EXPECT_EQ(IntegratedAudioToSigned16(1), 16);
}

// --- Detection ---------------------------------------------------------------

TEST(FramedDetectionTest, AFramedStreamIsFoundWhereverTheBufferOpens) {
  // The buffer may open anywhere in a frame. Every phase of one is tried.
  for (size_t phase = 0; phase < kFrameSamples; ++phase) {
    FramedStreamBuilder builder(1234);
    builder.DropSamples(phase);
    builder.AppendSamples(4 * kFrameSamples);

    const FramedDetection detection =
        DetectFramedStream(builder.bytes().data(), builder.sample_count());
    ASSERT_TRUE(detection.framed) << "phase " << phase;
    EXPECT_EQ(detection.frame_start, (kFrameSamples - phase) % kFrameSamples)
        << "phase " << phase;
  }
}

TEST(FramedDetectionTest, ASequenceCounterStreamIsNeverMistakenForFramed) {
  // Every counter value, including 20 — the value of the pattern's first
  // chunk — and a counter change inside the search window.
  for (uint8_t counter = 0; counter < kSequenceCounterValues; ++counter) {
    for (const uint32_t until : {1U, 100U, 2000U, kSamplesPerSequenceCounter}) {
      test::WireStreamBuilder builder(counter, until);
      builder.AppendRamp(kFramedDetectionMaximumSamples + 4096);
      const std::vector<uint8_t>& bytes = builder.bytes();

      const FramedDetection detection =
          DetectFramedStream(bytes.data(), bytes.size() / kBytesPerSample);
      EXPECT_FALSE(detection.framed);
      EXPECT_FALSE(detection.sync_seen);
    }
  }
}

TEST(FramedDetectionTest, AStreamWithNoMarkersIsNotFramed) {
  std::vector<uint8_t> bytes(8192 * kBytesPerSample, 0);
  for (size_t index = 0; index < bytes.size(); index += 2) {
    bytes[index] = 0x55;
    bytes[index + 1] = 0x01;
  }
  EXPECT_FALSE(DetectFramedStream(bytes.data(), 8192).framed);
}

TEST(FramedDetectionTest, OneFrameIsNotEnoughToCallItFramed) {
  // Two whole frames, both agreeing, or it is not framed.
  FramedStreamBuilder builder;
  builder.AppendSamples(kFrameSamples + 200);

  const FramedDetection detection =
      DetectFramedStream(builder.bytes().data(), builder.sample_count());
  EXPECT_FALSE(detection.framed);
  EXPECT_TRUE(detection.sync_seen);
}

TEST(FramedDetectionTest, ADamagedOpeningFrameIsPassedOverForTheNextOne) {
  FramedStreamBuilder builder;
  builder.AppendFrames(5);

  // The first frame's counter is corrupted, so the first pair of frames does
  // not confirm. The second pair does.
  builder.SetTopBits(100, 0x3F);

  const FramedDetection detection =
      DetectFramedStream(builder.bytes().data(), builder.sample_count());
  ASSERT_TRUE(detection.framed);
  EXPECT_EQ(detection.frame_start, kFrameSamples);
}

TEST(FramedDetectionTest, ASyncThatNeverRepeatsIsSeenButNotTrusted) {
  // One frame's worth of framing, then a stream whose top bits are something
  // else entirely — what a damaged opening looks like if nothing confirms.
  FramedStreamBuilder builder;
  builder.AppendFrames(4);
  for (size_t index = 300; index < builder.sample_count(); ++index) {
    builder.SetTopBits(index, 7);
  }

  const FramedDetection detection =
      DetectFramedStream(builder.bytes().data(), builder.sample_count());
  EXPECT_FALSE(detection.framed);
  EXPECT_TRUE(detection.sync_seen);
}

TEST(FramedDetectionTest, NothingIsFoundBeyondTheSearchWindow) {
  // The search is bounded: a stream whose first frame starts past the window
  // is not looked for there.
  std::vector<uint8_t> bytes(kFramedDetectionSearchSamples * 2, 0);
  FramedStreamBuilder builder;
  builder.AppendFrames(4);
  bytes.insert(bytes.end(), builder.bytes().begin(), builder.bytes().end());

  EXPECT_FALSE(
      DetectFramedStream(bytes.data(), bytes.size() / kBytesPerSample).framed);
}

TEST(FramedDetectionTest, DetectionLeavesTheBufferAsItFoundIt) {
  FramedStreamBuilder builder;
  builder.AppendFrames(6);
  const std::vector<uint8_t> before = builder.bytes();

  DetectFramedStream(builder.bytes().data(), builder.sample_count());
  EXPECT_EQ(builder.bytes(), before);
}

// --- Validation of a good stream
// ----------------------------------------------

TEST(FramedStreamValidatorTest, AGoodStreamLocksOnAndStaysLocked) {
  FramedStreamBuilder builder(42);
  builder.AppendFrames(64);

  FramedStreamValidator validator;
  std::vector<AudioFrame> audio;
  const FramedStreamValidator::Outcome outcome =
      validator.Process(builder.bytes().data(), builder.bytes().size(), audio);

  EXPECT_TRUE(outcome.ok);
  EXPECT_EQ(validator.state(), SequenceState::kRunning);
  EXPECT_TRUE(validator.locked());
  EXPECT_EQ(outcome.frames_checked, 64U);
  EXPECT_EQ(audio.size(), 64U);
  EXPECT_EQ(outcome.sync_losses, 0U);
  EXPECT_EQ(outcome.tally.sample_count, 64U * kFrameSamples);
}

TEST(FramedStreamValidatorTest, TheFramingIsStrippedAndTheRfLeftAlone) {
  FramedStreamBuilder builder;
  builder.AppendFrames(8);

  FramedStreamValidator validator;
  std::vector<AudioFrame> audio;
  ASSERT_TRUE(
      validator.Process(builder.bytes().data(), builder.bytes().size(), audio)
          .ok);

  for (size_t index = 0; index < builder.sample_count(); ++index) {
    ASSERT_EQ(TopBits(builder.bytes(), index), 0) << index;
    ASSERT_EQ(test::SampleAt(builder.bytes(), index),
              FramedStreamBuilder::RfFor(index))
        << index;
  }
}

TEST(FramedStreamValidatorTest, EachFramesAudioComesOutAsTheConvertersSentIt) {
  FramedStreamBuilder builder;

  const std::array<FramedStreamBuilder::FrameContent, 4> contents = {{
      {.integrated_left = 0x000,
       .integrated_right = 0xFFF,
       .external_left = 0x800000,
       .external_right = 0x7FFFFF},
      {.integrated_left = 0x800,
       .integrated_right = 0x7FF,
       .external_left = 0xFFFFFF,
       .external_right = 0x000001},
      {.integrated_left = 0x123,
       .integrated_right = 0xABC,
       .external_left = 0x123456,
       .external_right = 0xFEDCBA},
      {.integrated_left = 0x001,
       .integrated_right = 0x801,
       .external_left = 0x400000,
       .external_right = 0xC00000},
  }};
  for (const FramedStreamBuilder::FrameContent& content : contents) {
    builder.AppendFrames(1, content);
  }

  FramedStreamValidator validator;
  std::vector<AudioFrame> audio;
  ASSERT_TRUE(
      validator.Process(builder.bytes().data(), builder.bytes().size(), audio)
          .ok);
  ASSERT_EQ(audio.size(), 4U);

  // Worked by hand rather than by calling the decoder.
  EXPECT_EQ(audio[0].integrated_left, -2048);
  EXPECT_EQ(audio[0].integrated_right, 2047);
  EXPECT_EQ(audio[0].external_left, -8'388'608);
  EXPECT_EQ(audio[0].external_right, 8'388'607);

  EXPECT_EQ(audio[1].integrated_left, 0);
  EXPECT_EQ(audio[1].integrated_right, -1);
  EXPECT_EQ(audio[1].external_left, -1);
  EXPECT_EQ(audio[1].external_right, 1);

  EXPECT_EQ(audio[2].integrated_left, 291 - 2048);
  EXPECT_EQ(audio[2].integrated_right, 2748 - 2048);
  EXPECT_EQ(audio[2].external_left, 1'193'046);
  EXPECT_EQ(audio[2].external_right, 16'702'650 - 16'777'216);

  EXPECT_EQ(audio[3].integrated_left, -2047);
  EXPECT_EQ(audio[3].integrated_right, 1);
  EXPECT_EQ(audio[3].external_left, 4'194'304);
  EXPECT_EQ(audio[3].external_right, -4'194'304);
}

TEST(FramedStreamValidatorTest, TheCounterIsFollowedAcrossItsWrap) {
  // Starting a frame and a half short of the wrap, so it falls mid-frame.
  FramedStreamBuilder builder(kCounterMask - 80);
  builder.AppendFrames(6);

  FramedStreamValidator validator;
  std::vector<AudioFrame> audio;
  EXPECT_TRUE(
      validator.Process(builder.bytes().data(), builder.bytes().size(), audio)
          .ok);
  EXPECT_EQ(validator.state(), SequenceState::kRunning);
  EXPECT_LT(builder.counter(), kCounterMask - 80);  // it did wrap
}

TEST(FramedStreamValidatorTest, ABufferBoundaryAnywhereInAFrameChangesNothing) {
  // The device does not know where the host's buffers end, so a frame — and a
  // counter value inside it, and the sync pattern itself — can be cut at any
  // sample. Every cut in two whole frames is tried, against one validator
  // carrying its state from the first piece to the second.
  FramedStreamBuilder reference(7);
  reference.AppendFrames(6);

  std::vector<uint8_t> whole = reference.bytes();
  FramedStreamValidator one_piece;
  std::vector<AudioFrame> expected_audio;
  ASSERT_TRUE(one_piece.Process(whole.data(), whole.size(), expected_audio).ok);

  for (size_t cut = 1; cut < 2 * kFrameSamples; ++cut) {
    std::vector<uint8_t> bytes = reference.bytes();
    FramedStreamValidator validator;
    std::vector<AudioFrame> audio;

    const size_t split = (kFrameSamples + cut) * kBytesPerSample;
    ASSERT_TRUE(validator.Process(bytes.data(), split, audio).ok) << cut;
    ASSERT_TRUE(
        validator.Process(bytes.data() + split, bytes.size() - split, audio).ok)
        << cut;

    ASSERT_EQ(audio.size(), expected_audio.size()) << cut;
    for (size_t index = 0; index < audio.size(); ++index) {
      ASSERT_EQ(audio[index].integrated_left,
                expected_audio[index].integrated_left);
      ASSERT_EQ(audio[index].external_right,
                expected_audio[index].external_right);
    }
    ASSERT_EQ(bytes, whole) << cut;
  }
}

TEST(FramedStreamValidatorTest, ASyncPatternSplitAcrossBuffersIsStillFound) {
  // The first sync pattern begins at sample 20, and the first buffer ends
  // sixteen samples into it.
  FramedStreamBuilder builder;
  builder.DropSamples(kFrameSamples - 20);
  builder.AppendSamples(5 * kFrameSamples);
  constexpr size_t kCut = (20 + 16) * kBytesPerSample;

  FramedStreamValidator validator;
  std::vector<AudioFrame> audio;
  ASSERT_TRUE(validator.Process(builder.bytes().data(), kCut, audio).ok);
  EXPECT_EQ(validator.state(), SequenceState::kSynchronising);

  ASSERT_TRUE(validator
                  .Process(builder.bytes().data() + kCut,
                           builder.bytes().size() - kCut, audio)
                  .ok);
  EXPECT_EQ(validator.state(), SequenceState::kRunning);

  // Four whole frames from sample 20, and a fifth cut short but with its
  // audio and first counter value in.
  EXPECT_EQ(audio.size(), 5U);
}

// --- Validation of a stream that lost samples
// ---------------------------------

TEST(FramedStreamValidatorTest, SamplesLostInsideAFrameFailItByDefault) {
  FramedStreamBuilder builder;
  builder.AppendFrames(3);
  builder.AppendSamples(200);
  builder.DropSamples(100);
  builder.AppendFrames(3);

  FramedStreamValidator validator;
  std::vector<AudioFrame> audio;
  const FramedStreamValidator::Outcome outcome =
      validator.Process(builder.bytes().data(), builder.bytes().size(), audio);

  EXPECT_FALSE(outcome.ok);
  EXPECT_EQ(validator.state(), SequenceState::kFailed);

  // Position 200 began a counter value; after the drop its eight samples come
  // from mid-way through a different one, which the eighth of them shows.
  EXPECT_EQ(outcome.first_fault.kind, FramedFault::kCounter);
  EXPECT_EQ(outcome.first_fault.sample_index, (3 * kFrameSamples) + 207);
  EXPECT_EQ(outcome.first_fault.frame_position, 207U);

  // As the sequence validator does: nothing past the break is measured, and a
  // failed validator stays failed.
  EXPECT_EQ(outcome.tally.sample_count, (3 * kFrameSamples) + 207);
  std::vector<uint8_t> more = builder.bytes();
  EXPECT_FALSE(validator.Process(more.data(), more.size(), audio).ok);
}

TEST(FramedStreamValidatorTest, ALossInsideTheSyncPatternIsCaughtThere) {
  FramedStreamBuilder builder;
  builder.AppendFrames(2);
  builder.AppendSamples(10);
  builder.DropSamples(5);
  builder.AppendFrames(2);

  FramedStreamValidator validator;
  std::vector<AudioFrame> audio;
  const FramedStreamValidator::Outcome outcome =
      validator.Process(builder.bytes().data(), builder.bytes().size(), audio);

  ASSERT_FALSE(outcome.ok);
  EXPECT_EQ(outcome.first_fault.kind, FramedFault::kSyncPattern);
  EXPECT_EQ(outcome.first_fault.sample_index, (2 * kFrameSamples) + 10);
  EXPECT_EQ(outcome.first_fault.expected, kSyncChunks[10]);
  EXPECT_EQ(outcome.first_fault.actual, kSyncChunks[15]);
}

TEST(FramedStreamValidatorTest, AWholeFrameLostIsCaughtByTheCounter) {
  // The framing survives a loss of exactly one frame, so only the counter can
  // see it — and it jumps by exactly the 58 values a frame carries.
  FramedStreamBuilder builder;
  builder.AppendFrames(3);
  const uint64_t expected = builder.counter();
  builder.DropSamples(kFrameSamples);
  builder.AppendFrames(2);

  FramedStreamValidator validator;
  std::vector<AudioFrame> audio;
  const FramedStreamValidator::Outcome outcome =
      validator.Process(builder.bytes().data(), builder.bytes().size(), audio);

  ASSERT_FALSE(outcome.ok);
  EXPECT_EQ(outcome.first_fault.kind, FramedFault::kCounter);
  EXPECT_EQ(outcome.first_fault.expected, expected);
  EXPECT_EQ(outcome.first_fault.actual, expected + kCounterValuesPerFrame);

  // The broken frame's audio never came out: it was held until the counter
  // after it checked, and that is the check that failed.
  EXPECT_EQ(audio.size(), 3U);
}

TEST(FramedStreamValidatorTest, ALossAtABufferBoundaryIsCaughtInTheNextBuffer) {
  FramedStreamBuilder builder;
  builder.AppendFrames(2);
  builder.AppendSamples(300);
  const size_t first = builder.bytes().size();
  builder.DropSamples(64);
  builder.AppendFrames(2);

  FramedStreamValidator validator;
  std::vector<AudioFrame> audio;
  ASSERT_TRUE(validator.Process(builder.bytes().data(), first, audio).ok);

  const FramedStreamValidator::Outcome second = validator.Process(
      builder.bytes().data() + first, builder.bytes().size() - first, audio);
  EXPECT_FALSE(second.ok);
  EXPECT_EQ(second.first_fault.kind, FramedFault::kCounter);
}

TEST(FramedStreamValidatorTest, ContinuingCountsTheLossAndPicksUpAgain) {
  FramedStreamBuilder builder;
  builder.AppendFrames(3);
  builder.AppendSamples(200);
  builder.DropSamples(100);
  builder.AppendFrames(10);

  FramedStreamValidator validator(Continuing());
  std::vector<AudioFrame> audio;
  const FramedStreamValidator::Outcome outcome =
      validator.Process(builder.bytes().data(), builder.bytes().size(), audio);

  EXPECT_TRUE(outcome.ok);
  EXPECT_EQ(outcome.sync_losses, 1U);
  EXPECT_EQ(validator.sync_losses(), 1U);
  EXPECT_EQ(validator.state(), SequenceState::kResynchronised);
  EXPECT_TRUE(validator.locked());
  EXPECT_EQ(outcome.first_fault.kind, FramedFault::kCounter);

  // Every sample is still stripped and measured, the ones around the hole
  // included: the capture carries on with all of them.
  EXPECT_EQ(outcome.tally.sample_count, builder.sample_count());
  for (size_t index = 0; index < builder.sample_count(); ++index) {
    ASSERT_EQ(TopBits(builder.bytes(), index), 0) << index;
  }

  // Three frames before; the broken one's, which was already out because its
  // first counter value checked before the loss; and the ten after the
  // resync, the last of them cut short but with its audio and first counter
  // value inside the buffer.
  EXPECT_EQ(audio.size(), 3U + 1U + 10U);
}

TEST(FramedStreamValidatorTest, ContinuingResynchronisesAcrossABufferBoundary) {
  FramedStreamBuilder builder(1000);
  builder.AppendFrames(2);
  builder.AppendSamples(10);
  builder.DropSamples(7);
  builder.AppendSamples(kFrameSamples - 17);  // the end of that frame
  builder.AppendFrames(4);

  // Cut in the middle of the next frame's sync pattern.
  const size_t cut = ((3 * kFrameSamples) - 7 + 16) * kBytesPerSample;

  FramedStreamValidator validator(Continuing());
  std::vector<AudioFrame> audio;
  ASSERT_TRUE(validator.Process(builder.bytes().data(), cut, audio).ok);
  EXPECT_FALSE(validator.locked());
  EXPECT_EQ(validator.sync_losses(), 1U);

  ASSERT_TRUE(validator
                  .Process(builder.bytes().data() + cut,
                           builder.bytes().size() - cut, audio)
                  .ok);
  EXPECT_TRUE(validator.locked());
  EXPECT_EQ(validator.sync_losses(), 1U);
  EXPECT_EQ(validator.state(), SequenceState::kResynchronised);

  // Two before the loss, none for the frame it happened in, four after.
  EXPECT_EQ(audio.size(), 6U);
}

TEST(FramedStreamValidatorTest, EachSeparateLossIsCountedOnce) {
  FramedStreamBuilder builder;
  for (int loss = 0; loss < 5; ++loss) {
    builder.AppendFrames(3);
    builder.AppendSamples(77);
    builder.DropSamples(33);
    builder.AppendSamples(kFrameSamples - 110);
  }
  builder.AppendFrames(3);

  FramedStreamValidator validator(Continuing());
  std::vector<AudioFrame> audio;
  ASSERT_TRUE(
      validator.Process(builder.bytes().data(), builder.bytes().size(), audio)
          .ok);
  EXPECT_EQ(validator.sync_losses(), 5U);
}

TEST(FramedStreamValidatorTest, AudioIsHeldBackUntilTheCounterAfterItChecks) {
  // A loss between the audio and the first counter value. The audio slots are
  // filled by samples the validator cannot know are wrong until the counter
  // that follows them fails to agree — and then that frame's audio must not
  // reach a file.
  FramedStreamBuilder builder;
  builder.AppendFrames(2);
  builder.AppendSamples(40);
  builder.DropSamples(3);
  builder.AppendSamples(kFrameSamples - 43);
  builder.AppendFrames(3);

  FramedStreamValidator validator(Continuing());
  std::vector<AudioFrame> audio;
  ASSERT_TRUE(
      validator.Process(builder.bytes().data(), builder.bytes().size(), audio)
          .ok);
  EXPECT_EQ(validator.sync_losses(), 1U);
  EXPECT_EQ(audio.size(), 2U + 3U);
}

// --- Choosing between the two formats --------------------------------------

TEST(StreamValidatorTest, ASequenceCounterStreamIsValidatedExactlyAsBefore) {
  // The same bytes through the dispatcher and through SequenceValidator alone
  // must come out the same, buffer for buffer, mismatch for mismatch.
  test::WireStreamBuilder builder(5, 1234);
  builder.AppendRamp(size_t{3} * kSamplesPerSequenceCounter);
  builder.SkipCounter();
  builder.AppendRamp(kSamplesPerSequenceCounter);

  std::vector<uint8_t> through_dispatcher = builder.bytes();
  std::vector<uint8_t> through_validator = builder.bytes();

  StreamValidator dispatcher;
  dispatcher.Reset({});
  SequenceValidator direct;

  const size_t half = (through_validator.size() / 4) * 2;
  for (const auto& [offset, length] :
       {std::pair<size_t, size_t>{0, half},
        std::pair<size_t, size_t>{half, through_validator.size() - half}}) {
    const StreamValidator::Outcome via =
        dispatcher.Process(through_dispatcher.data() + offset, length);
    const SequenceValidator::Outcome alone =
        direct.Process(through_validator.data() + offset, length);

    EXPECT_EQ(via.format, StreamFormat::kSequenceCounter);
    EXPECT_EQ(via.ok, alone.ok);
    EXPECT_EQ(via.sequence.mismatch_sample_index, alone.mismatch_sample_index);
    EXPECT_EQ(via.tally.sample_count, alone.tally.sample_count);
    EXPECT_EQ(dispatcher.state(), direct.state());
    EXPECT_TRUE(dispatcher.audio().empty());
  }

  EXPECT_EQ(direct.state(), SequenceState::kFailed);
  EXPECT_EQ(through_dispatcher, through_validator);
}

TEST(StreamValidatorTest, AStreamWithNoMarkersIsStillDisabledRatherThanFailed) {
  std::vector<uint8_t> bytes((kSamplesPerSequenceCounter + 4) * kBytesPerSample,
                             0);
  for (size_t index = 0; index < bytes.size(); index += kBytesPerSample) {
    bytes[index] = 0x55;
    bytes[index + 1] = 0x01;
  }

  StreamValidator validator;
  validator.Reset({});
  const StreamValidator::Outcome outcome =
      validator.Process(bytes.data(), bytes.size());

  EXPECT_TRUE(outcome.ok);
  EXPECT_EQ(outcome.format, StreamFormat::kSequenceCounter);
  EXPECT_EQ(validator.state(), SequenceState::kDisabled);
}

TEST(StreamValidatorTest, AFramedStreamIsRecognisedAndItsAudioCollected) {
  FramedStreamBuilder builder;
  builder.DropSamples(123);
  builder.AppendSamples(40 * kFrameSamples);

  StreamValidator validator;
  validator.Reset({});
  const StreamValidator::Outcome outcome =
      validator.Process(builder.bytes().data(), builder.bytes().size());

  EXPECT_TRUE(outcome.ok);
  EXPECT_TRUE(outcome.format_decided_here);
  EXPECT_TRUE(outcome.detection.framed);
  EXPECT_EQ(outcome.detection.frame_start, kFrameSamples - 123);
  EXPECT_EQ(validator.format(), StreamFormat::kFramed);
  EXPECT_EQ(validator.state(), SequenceState::kRunning);

  // The partial frame the buffer opened on has no audio: its sync pattern was
  // before the buffer began. The partial one it closes on has, because its
  // first counter value is inside the buffer.
  EXPECT_EQ(validator.audio().size(), 40U);
}

TEST(StreamValidatorTest, TheFormatIsDecidedOnceAndHeldTo) {
  FramedStreamBuilder framed;
  framed.AppendFrames(8);

  StreamValidator validator;
  validator.Reset({});
  ASSERT_TRUE(
      validator.Process(framed.bytes().data(), framed.bytes().size()).ok);
  ASSERT_EQ(validator.format(), StreamFormat::kFramed);

  // A buffer of sequence-counter data after that is a framed stream that has
  // gone wrong, not a stream that has changed its mind.
  test::WireStreamBuilder legacy(3, 100);
  legacy.AppendRamp(4 * kFrameSamples);
  const StreamValidator::Outcome outcome =
      validator.Process(legacy.bytes().data(), legacy.bytes().size());
  EXPECT_FALSE(outcome.ok);
  EXPECT_EQ(outcome.format, StreamFormat::kFramed);
  EXPECT_FALSE(outcome.format_decided_here);
}

TEST(StreamValidatorTest, ContinuingIsPassedToTheFramedValidator) {
  FramedStreamBuilder builder;
  builder.AppendFrames(4);
  builder.DropSamples(50);
  builder.AppendFrames(4);

  StreamValidator validator;
  validator.Reset(StreamValidator::Options{.continue_after_sync_loss = true});
  const StreamValidator::Outcome outcome =
      validator.Process(builder.bytes().data(), builder.bytes().size());

  EXPECT_TRUE(outcome.ok);
  EXPECT_EQ(validator.sync_losses(), 1U);
  EXPECT_EQ(validator.state(), SequenceState::kResynchronised);
}

TEST(StreamValidatorTest, ResetForgetsTheFormat) {
  FramedStreamBuilder builder;
  builder.AppendFrames(4);

  StreamValidator validator;
  validator.Reset({});
  validator.Process(builder.bytes().data(), builder.bytes().size());
  ASSERT_EQ(validator.format(), StreamFormat::kFramed);

  validator.Reset({});
  EXPECT_EQ(validator.format(), StreamFormat::kUndetermined);
  EXPECT_EQ(validator.state(), SequenceState::kSynchronising);
  EXPECT_TRUE(validator.audio().empty());
}

// The real-time budget, as SequenceValidator's own test states it: half of the
// 26 ms a 2 MB buffer takes to arrive, loose on purpose for slow CI runners.
TEST(StreamValidatorTest, AFullSizeFramedBufferIsValidatedInsideTheBudget) {
  constexpr size_t kSlotBytes = size_t{2} << 20;

  FramedStreamBuilder builder;
  builder.AppendSamples(kSlotBytes / kBytesPerSample);
  const std::vector<uint8_t> pristine = builder.bytes();
  ASSERT_EQ(pristine.size(), kSlotBytes);

  std::vector<uint8_t> working(pristine.size());

  const auto time_one_pass = [&]() {
    std::memcpy(working.data(), pristine.data(), pristine.size());
    StreamValidator validator;
    validator.Reset({});

    const auto started = std::chrono::steady_clock::now();
    const StreamValidator::Outcome outcome =
        validator.Process(working.data(), working.size());
    const auto elapsed = std::chrono::steady_clock::now() - started;

    EXPECT_TRUE(outcome.ok);
    EXPECT_EQ(validator.audio().size(), 2048U);
    return std::chrono::duration<double, std::milli>(elapsed).count();
  };

  time_one_pass();

  constexpr int kPasses = 8;
  double total_milliseconds = 0.0;
  for (int pass = 0; pass < kPasses; ++pass) {
    total_milliseconds += time_one_pass();
  }
  const double milliseconds_per_buffer = total_milliseconds / kPasses;

  std::cout << "[          ] framed detection + validation + audio + metrics: "
            << milliseconds_per_buffer
            << " ms per 2 MB buffer (budget 26 ms)\n";

  EXPECT_LT(milliseconds_per_buffer, 13.0);
}

}  // namespace
}  // namespace ddd::capture
