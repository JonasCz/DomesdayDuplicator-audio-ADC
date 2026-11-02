/************************************************************************

    usb_stall_injection.h

    Stopping the host from reading, on purpose, for a measured time
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

// A test facility, and only that: a way to make the host stop taking data
// from the device for a known length of time, on a schedule, so that what the
// device does with the samples it cannot send — its FIFO, and the SDRAM buffer
// some gateware has behind it — can be measured repeatably instead of by
// waiting for a machine to misbehave.
//
// Off unless asked for, by --inject-usb-stall on the command line or the
// DDD_INJECT_USB_STALL environment variable. A run with it on says so loudly,
// at the start and at every stall, and a capture made with it records it in
// its sidecar, because a capture made this way has had samples put at risk on
// purpose and must never be mistaken for an ordinary one.
//
// What a stall is, precisely, because the device-side measurement depends on
// it: when one is due the host stops resubmitting transfers as they complete,
// waits until every transfer in flight has completed — at which point the
// host controller is issuing no IN requests at all — then holds zero
// transfers queued for exactly the time asked for, and then resubmits as
// normal. The interval with nothing queued is measured and logged beside the
// one requested.
//
// The arithmetic is here, Qt-free and free of libusb, so it can be tested; the
// source's part is a few lines of hook around it.
namespace ddd::capture {

// What was asked for.
struct UsbStallPlan {
  // How long to hold nothing queued. Zero is off.
  std::chrono::milliseconds stall{0};

  // Time from one stall's start to the next. Zero is once.
  std::chrono::milliseconds period{0};

  // Time from the start of streaming to the first stall: long enough for the
  // opening discard, the format detection and a capture to be started.
  std::chrono::milliseconds initial_delay{kDefaultInitialDelay};

  bool enabled() const { return stall.count() > 0; }

  bool operator==(const UsbStallPlan& other) const = default;

  static constexpr std::chrono::milliseconds kDefaultInitialDelay{5000};

  // The longest stall this will inject. The pipeline declares a source that
  // delivers nothing for five seconds stalled and ends the run, so a stall
  // near that would test the watchdog rather than the buffering.
  static constexpr std::chrono::milliseconds kMaximumStall{4000};
};

// The environment variable that turns it on where there is no command line —
// a windowed run started from a desktop shortcut.
inline constexpr const char* kUsbStallEnvironmentVariable =
    "DDD_INJECT_USB_STALL";

// Read "<ms>[@<period-seconds>][+<initial-delay-seconds>]", as the command
// line and the environment variable spell it: "300" is one 300 ms stall five
// seconds in, "300@10" one every ten seconds, "300@10+2" the same starting two
// seconds in. Seconds may be fractional.
struct UsbStallPlanParse {
  std::optional<UsbStallPlan> plan;

  // Empty when the text was understood.
  std::string error;
};

UsbStallPlanParse ParseUsbStallPlan(std::string_view text);

// The plan in words, for the log, the panel and the sidecar: "300 ms every
// 10 s, the first 5 s in".
std::string DescribeUsbStallPlan(const UsbStallPlan& plan);

// When to stall, and what each stall turned out to be.
//
// Driven from the transfer thread by two calls: HoldBack() for each transfer
// that completes, which says whether it may go back on the wire, and Advance()
// from the event loop, which moves the stall along when nothing is in flight.
// Time is passed in rather than read, so the tests can drive it.
//
// Thread-safety: none. Belongs to the source's transfer thread.
class UsbStallScheduler {
 public:
  using Clock = std::chrono::steady_clock;

  enum class Phase {
    // Not injecting: off, or a one-off stall that has happened.
    kIdle,

    // Streaming normally until the next stall is due.
    kWaiting,

    // Due: completed transfers are being held back, and the ones still in
    // flight are completing.
    kDraining,

    // Nothing in flight, and nothing will be submitted until the hold is up.
    kHolding,
  };

  enum class Event {
    kNone,

    // The last transfer in flight has completed; the hold has begun.
    kHoldStarted,

    // The hold is over: resubmit what was held back, in the order it was held.
    kHoldEnded,
  };

  // One stall, as it happened.
  struct Stall {
    uint64_t number = 0;
    std::chrono::milliseconds requested{0};

    // From the moment it was due to the moment the last transfer completed.
    Clock::duration drain{0};

    // With nothing queued at all. The figure the device saw.
    Clock::duration zero_queued{0};

    // When it was due, on the steady clock and on the wall clock.
    Clock::time_point due;
    std::chrono::system_clock::time_point wall;
  };

  explicit UsbStallScheduler(const UsbStallPlan& plan) : plan_(plan) {}

  // The run has begun; the first stall is due initial_delay from now.
  void Start(Clock::time_point now);

  // A transfer has completed. True if it must not be resubmitted, which is
  // every transfer from the moment a stall is due until it is over.
  // in_flight_after is what is still on the wire without it: the completion
  // that leaves nothing in flight is the moment the hold begins.
  bool HoldBack(Clock::time_point now, size_t in_flight_after);

  // The event loop's turn.
  Event Advance(Clock::time_point now, size_t in_flight);

  // How long the event loop may sleep before Advance() next has something to
  // do, capped at `idle` — which is what it waits otherwise.
  Clock::duration WaitBound(Clock::time_point now, Clock::duration idle) const;

  Phase phase() const { return phase_; }
  bool holding_back() const {
    return phase_ == Phase::kDraining || phase_ == Phase::kHolding;
  }

  // The most recent stall to have finished, and how many have.
  const Stall& last() const { return last_; }
  uint64_t completed() const { return completed_; }

  const UsbStallPlan& plan() const { return plan_; }

 private:
  void BeginDrain(Clock::time_point now);

  UsbStallPlan plan_;
  Phase phase_ = Phase::kIdle;
  Clock::time_point due_;
  Clock::time_point drain_started_;
  Clock::time_point hold_started_;
  std::chrono::system_clock::time_point wall_due_;
  Stall last_;
  uint64_t completed_ = 0;
};

// A wall-clock moment as UTC ISO 8601 with milliseconds, for the stall log.
std::string FormatUtcTimestamp(std::chrono::system_clock::time_point when);

}  // namespace ddd::capture
