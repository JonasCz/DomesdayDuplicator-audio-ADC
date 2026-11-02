/************************************************************************

    usb_stall_injection.cpp

    Stopping the host from reading, on purpose, for a measured time
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#include "usb_stall_injection.h"

#include <algorithm>
#include <array>
#include <ctime>

#include "log_format.h"

namespace ddd::capture {
namespace {

// A whole number of milliseconds, or nothing.
std::optional<int64_t> ParseMilliseconds(std::string_view text) {
  if (text.empty() || text.size() > 9) {
    return std::nullopt;
  }
  int64_t value = 0;
  for (const char digit : text) {
    if (digit < '0' || digit > '9') {
      return std::nullopt;
    }
    value = (value * 10) + (digit - '0');
  }
  return value;
}

// A non-negative number of seconds with an optional fraction, as
// milliseconds, or nothing. Written out rather than handed to strtod, which
// reads the locale's decimal separator and would take "2,5" on one machine and
// refuse it on the next.
std::optional<int64_t> ParseSecondsAsMilliseconds(std::string_view text) {
  const size_t point = text.find('.');
  const std::string_view whole = text.substr(0, point);
  const std::string_view fraction = point == std::string_view::npos
                                        ? std::string_view()
                                        : text.substr(point + 1);

  if ((whole.empty() && fraction.empty()) || whole.size() > 6 ||
      fraction.size() > 3 ||
      (point != std::string_view::npos && fraction.empty())) {
    return std::nullopt;
  }

  int64_t milliseconds = 0;
  for (const char digit : whole) {
    if (digit < '0' || digit > '9') {
      return std::nullopt;
    }
    milliseconds = (milliseconds * 10) + (digit - '0');
  }
  milliseconds *= 1000;

  int64_t scale = 100;
  for (const char digit : fraction) {
    if (digit < '0' || digit > '9') {
      return std::nullopt;
    }
    milliseconds += (digit - '0') * scale;
    scale /= 10;
  }
  return milliseconds;
}

std::string Seconds(std::chrono::milliseconds value) {
  const auto count = value.count();
  return count % 1000 == 0
             ? std::to_string(count / 1000) + " s"
             : FormatDecimal(static_cast<double>(count) / 1000.0, 3) + " s";
}

}  // namespace

UsbStallPlanParse ParseUsbStallPlan(std::string_view text) {
  UsbStallPlanParse result;
  const std::string spelling =
      "Use <milliseconds>[@<period seconds>][+<delay seconds>], for example "
      "300@10+5";

  const size_t at = text.find('@');
  const size_t plus = text.find('+');
  if (at != std::string_view::npos && plus != std::string_view::npos &&
      plus < at) {
    result.error = "The period comes before the delay. " + spelling;
    return result;
  }

  const size_t stall_end = std::min(at, plus);
  const std::optional<int64_t> stall =
      ParseMilliseconds(text.substr(0, stall_end));
  if (!stall.has_value()) {
    result.error = "'" + std::string(text) +
                   "' does not start with a stall in whole milliseconds. " +
                   spelling;
    return result;
  }
  if (*stall < 1 || *stall > UsbStallPlan::kMaximumStall.count()) {
    result.error = "A stall of " + std::to_string(*stall) +
                   " ms is outside 1 to " +
                   std::to_string(UsbStallPlan::kMaximumStall.count()) +
                   " ms: anything longer is ended by the capture's own "
                   "five-second stall watchdog";
    return result;
  }

  UsbStallPlan plan;
  plan.stall = std::chrono::milliseconds(*stall);

  if (at != std::string_view::npos) {
    const size_t period_end = plus == std::string_view::npos
                                  ? std::string_view::npos
                                  : plus - (at + 1);
    const std::optional<int64_t> period =
        ParseSecondsAsMilliseconds(text.substr(at + 1, period_end));
    if (!period.has_value() || *period <= *stall) {
      result.error =
          "The period after '@' has to be a number of seconds longer than "
          "the stall itself. " +
          spelling;
      return result;
    }
    plan.period = std::chrono::milliseconds(*period);
  }

  if (plus != std::string_view::npos) {
    const std::optional<int64_t> delay =
        ParseSecondsAsMilliseconds(text.substr(plus + 1));
    if (!delay.has_value()) {
      result.error =
          "The delay after '+' has to be a number of seconds. " + spelling;
      return result;
    }
    plan.initial_delay = std::chrono::milliseconds(*delay);
  }

  result.plan = plan;
  return result;
}

std::string DescribeUsbStallPlan(const UsbStallPlan& plan) {
  if (!plan.enabled()) {
    return "off";
  }
  std::string text = std::to_string(plan.stall.count()) + " ms ";
  text += plan.period.count() > 0 ? "every " + Seconds(plan.period) : "once";
  text += ", the first " + Seconds(plan.initial_delay) + " in";
  return text;
}

void UsbStallScheduler::Start(Clock::time_point now) {
  completed_ = 0;
  last_ = Stall{};
  if (!plan_.enabled()) {
    phase_ = Phase::kIdle;
    return;
  }
  phase_ = Phase::kWaiting;
  due_ = now + plan_.initial_delay;
  wall_due_ = std::chrono::system_clock::now() +
              std::chrono::duration_cast<std::chrono::system_clock::duration>(
                  plan_.initial_delay);
}

void UsbStallScheduler::BeginDrain(Clock::time_point now) {
  phase_ = Phase::kDraining;
  drain_started_ = now;
  wall_due_ = std::chrono::system_clock::now();
}

bool UsbStallScheduler::HoldBack(Clock::time_point now,
                                 size_t in_flight_after) {
  if (phase_ == Phase::kWaiting && now >= due_) {
    BeginDrain(now);
  }

  if (phase_ == Phase::kDraining && in_flight_after == 0) {
    phase_ = Phase::kHolding;
    hold_started_ = now;
  }

  return holding_back();
}

UsbStallScheduler::Event UsbStallScheduler::Advance(Clock::time_point now,
                                                    size_t in_flight) {
  if (phase_ == Phase::kWaiting && now >= due_) {
    BeginDrain(now);
  }

  if (phase_ == Phase::kDraining) {
    if (in_flight != 0) {
      return Event::kNone;
    }
    phase_ = Phase::kHolding;
    hold_started_ = now;
    return Event::kHoldStarted;
  }

  if (phase_ != Phase::kHolding || now - hold_started_ < plan_.stall) {
    return Event::kNone;
  }

  ++completed_;
  last_.number = completed_;
  last_.requested = plan_.stall;
  last_.drain = hold_started_ - drain_started_;
  last_.zero_queued = now - hold_started_;
  last_.due = drain_started_;
  last_.wall = wall_due_;

  if (plan_.period.count() > 0) {
    // On a fixed cadence from when each was due, so a stall that ran long
    // does not push every later one back with it — unless it ran past the
    // next one altogether, which then starts a period from now.
    due_ = drain_started_ + plan_.period;
    if (due_ <= now) {
      due_ = now + plan_.period;
    }
    phase_ = Phase::kWaiting;
  } else {
    phase_ = Phase::kIdle;
  }
  return Event::kHoldEnded;
}

UsbStallScheduler::Clock::duration UsbStallScheduler::WaitBound(
    Clock::time_point now, Clock::duration idle) const {
  switch (phase_) {
    case Phase::kIdle:
    case Phase::kDraining:
      return idle;
    case Phase::kWaiting:
      return std::clamp<Clock::duration>(due_ - now, Clock::duration::zero(),
                                         idle);
    case Phase::kHolding:
      return std::clamp<Clock::duration>(hold_started_ + plan_.stall - now,
                                         Clock::duration::zero(), idle);
  }
  return idle;
}

std::string FormatUtcTimestamp(std::chrono::system_clock::time_point when) {
  const std::time_t seconds = std::chrono::system_clock::to_time_t(when);
  const auto milliseconds =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          when.time_since_epoch())
          .count() %
      1000;

  std::tm parts{};
#ifdef _WIN32
  if (gmtime_s(&parts, &seconds) != 0) {
    return "unknown time";
  }
#else
  if (gmtime_r(&seconds, &parts) == nullptr) {
    return "unknown time";
  }
#endif

  std::array<char, 32> text{};
  if (std::strftime(text.data(), text.size(), "%Y-%m-%dT%H:%M:%S", &parts) ==
      0) {
    return "unknown time";
  }
  const std::string fraction = std::to_string(1000 + milliseconds).substr(1);
  return std::string(text.data()) + "." + fraction + "Z";
}

}  // namespace ddd::capture
