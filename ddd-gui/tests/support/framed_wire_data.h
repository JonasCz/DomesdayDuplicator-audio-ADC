/************************************************************************

    framed_wire_data.h

    Fabricating framed device data for tests
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>
#include <vector>

namespace ddd::capture::test {

// A framed stream, built the way the audio gateware builds one.
//
// A second implementation, deliberately sharing nothing with the engine: the
// sync pattern is read out of the gateware's own 192-bit hex literal a nibble
// at a time rather than taken from framed_format.h, and every field is placed
// by arithmetic written out here. A test that built its frames with the code it
// was testing would prove only that the code agreed with itself.
// What one frame carries besides its sync pattern and counter, as the
// converters deliver it: the integrated converter's 12-bit unsigned readings
// and the external converter's 24-bit two's complement ones, and the four
// reserved slots' six-bit values. At namespace scope because a nested struct
// with defaults cannot be the default argument of its own class's members.
struct FramedFrameContent {
  uint16_t integrated_left = 2048;
  uint16_t integrated_right = 2048;
  uint32_t external_left = 0;
  uint32_t external_right = 0;
  std::array<uint8_t, 4> reserved{};
};

class FramedStreamBuilder {
 public:
  using FrameContent = FramedFrameContent;

  // The gateware's literal, most significant nibble first.
  static constexpr std::string_view kSyncLiteral =
      "DDDF20251015DDDF20251015DDDF20251016FEDCBA987654";

  explicit FramedStreamBuilder(uint64_t first_counter = 0)
      : counter_(first_counter & kCounterMask) {}

  // Bits [6k+5:6k] of the 192-bit pattern.
  static uint8_t SyncChunk(size_t k) {
    uint8_t chunk = 0;
    for (size_t bit = 0; bit < 6; ++bit) {
      const size_t index = (6 * k) + bit;          // bit of the 192
      const size_t nibble_from_right = index / 4;  // 0 is the last character
      const char digit =
          kSyncLiteral[kSyncLiteral.size() - 1 - nibble_from_right];
      const unsigned nibble = digit <= '9'
                                  ? static_cast<unsigned>(digit - '0')
                                  : static_cast<unsigned>(digit - 'A' + 10);
      if (((nibble >> (index % 4)) & 1U) != 0) {
        chunk = static_cast<uint8_t>(chunk | (1U << bit));
      }
    }
    return chunk;
  }

  // Append whole frames with the given content. Each sample's RF is RfFor()
  // of its index in the stream, dropped samples included.
  void AppendFrames(size_t count, const FrameContent& content = {}) {
    for (size_t frame = 0; frame < count; ++frame) {
      AppendSamples(512, content);
    }
  }

  // Append `count` samples continuing wherever the framing has got to, so a
  // stream can be cut anywhere — mid-frame, mid-counter-value — the way a
  // buffer boundary cuts one.
  void AppendSamples(size_t count, const FrameContent& content = {}) {
    for (size_t index = 0; index < count; ++index) {
      Push(NextTopBits(content));
    }
  }

  // Advance the framing by `count` samples without writing them, as a lost
  // stretch of a transfer would.
  void DropSamples(size_t count, const FrameContent& content = {}) {
    for (size_t index = 0; index < count; ++index) {
      NextTopBits(content);
      ++rf_;
    }
  }

  // Overwrite the top bits of an already-written sample.
  void SetTopBits(size_t sample_index, uint8_t top) {
    uint8_t& high = bytes_[(sample_index * 2) + 1];
    high = static_cast<uint8_t>((high & 0x03U) | (top << 2));
  }

  // The RF value every sample carries: a ramp over the ten bits, so a test can
  // check the bottom bits survive the stripping untouched.
  static uint16_t RfFor(size_t sample_index) {
    return static_cast<uint16_t>((sample_index * 7) % 1024);
  }

  size_t position() const { return position_; }
  uint64_t counter() const { return counter_; }
  size_t sample_count() const { return bytes_.size() / 2; }

  std::vector<uint8_t>& bytes() { return bytes_; }
  const std::vector<uint8_t>& bytes() const { return bytes_; }

 private:
  static constexpr uint64_t kCounterMask = (uint64_t{1} << 48) - 1;

  void Push(uint8_t top) {
    const uint16_t word =
        static_cast<uint16_t>(RfFor(rf_) | (static_cast<uint16_t>(top) << 10));
    bytes_.push_back(static_cast<uint8_t>(word & 0xFF));
    bytes_.push_back(static_cast<uint8_t>(word >> 8));
    ++rf_;
  }

  uint8_t NextTopBits(const FrameContent& content) {
    const size_t p = position_;
    uint8_t top = 0;

    if (p < 32) {
      top = SyncChunk(p);
    } else if (p == 32) {
      top = static_cast<uint8_t>((content.integrated_left >> 6) & 0x3F);
    } else if (p == 33) {
      top = static_cast<uint8_t>(content.integrated_left & 0x3F);
    } else if (p == 34) {
      top = static_cast<uint8_t>((content.integrated_right >> 6) & 0x3F);
    } else if (p == 35) {
      top = static_cast<uint8_t>(content.integrated_right & 0x3F);
    } else if (p == 36 || p == 37) {
      top = content.reserved[p - 36];
    } else if (p >= 38 && p <= 41) {
      top = static_cast<uint8_t>((content.external_left >> (6 * (41 - p))) &
                                 0x3F);
    } else if (p >= 42 && p <= 45) {
      top = static_cast<uint8_t>((content.external_right >> (6 * (45 - p))) &
                                 0x3F);
    } else if (p == 46 || p == 47) {
      top = content.reserved[p - 44];
    } else {
      const size_t i = (p - 48) % 8;
      top = static_cast<uint8_t>((counter_ >> (6 * i)) & 0x3F);
      if (i == 7) {
        counter_ = (counter_ + 1) & kCounterMask;
      }
    }

    position_ = (p + 1) % 512;
    return top;
  }

  std::vector<uint8_t> bytes_;
  size_t position_ = 0;
  uint64_t counter_ = 0;
  size_t rf_ = 0;
};

}  // namespace ddd::capture::test
