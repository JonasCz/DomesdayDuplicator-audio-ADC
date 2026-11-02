/************************************************************************

    sdram_status.cpp

    What the gateware's SDRAM capture buffer reports in every frame
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#include "sdram_status.h"

#include <algorithm>

namespace ddd::capture {

SdramStatus DecodeSdramStatus(uint32_t word) {
  SdramStatus status;
  if ((word >> kSdramVersionShift) != kSdramStatusLayoutVersion) {
    return status;
  }

  status.present = true;
  status.active = (word & kSdramActiveBit) != 0;
  status.initialised = (word & kSdramInitialisedBit) != 0;
  status.overflowed = (word & kSdramOverflowBit) != 0;
  status.fill_rows = std::min(word & kSdramFillMask, kSdramCapacityRows);
  return status;
}

double SdramFillPercent(uint32_t rows) {
  return 100.0 * static_cast<double>(std::min(rows, kSdramCapacityRows)) /
         static_cast<double>(kSdramCapacityRows);
}

uint64_t SdramFillBytes(uint32_t rows) {
  return uint64_t{std::min(rows, kSdramCapacityRows)} * kSdramRowBytes;
}

double SdramFillMilliseconds(uint32_t rows, uint32_t sample_rate_hz) {
  if (sample_rate_hz == 0) {
    return 0.0;
  }
  // A row is 512 samples of the stream, whatever rate the stream runs at.
  return 1000.0 *
         static_cast<double>(uint64_t{std::min(rows, kSdramCapacityRows)} *
                             kSdramRowWords) /
         static_cast<double>(sample_rate_hz);
}

void SdramMonitor::Accumulate(std::span<const AudioFrame> frames) {
  for (const AudioFrame& frame : frames) {
    const SdramStatus status = DecodeSdramStatus(frame.reserved_word);
    if (!status.present) {
      continue;
    }

    snapshot_.present = true;
    snapshot_.current = status;
    snapshot_.peak_rows = std::max(snapshot_.peak_rows, status.fill_rows);
    snapshot_.active_seen = snapshot_.active_seen || status.active;
    snapshot_.overflow_seen = snapshot_.overflow_seen || status.overflowed;
    ++snapshot_.readings;
  }
}

}  // namespace ddd::capture
