/************************************************************************

    test_usb_stall_injection.cpp

    T1 tests for the USB stall test facility's plan and its schedule
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

#include <gtest/gtest.h>

#include <chrono>
#include <string>

#include "usb_stall_injection.h"

namespace ddd::capture {
namespace {

using namespace std::chrono_literals;
using Clock = UsbStallScheduler::Clock;
using Event = UsbStallScheduler::Event;
using Phase = UsbStallScheduler::Phase;

UsbStallPlan Plan(std::string_view text) {
  const UsbStallPlanParse parsed = ParseUsbStallPlan(text);
  EXPECT_TRUE(parsed.plan.has_value()) << text << ": " << parsed.error;
  return parsed.plan.value_or(UsbStallPlan{});
}

// --- What can be asked for
// ----------------------------------------------------

TEST(UsbStallPlanTest, OffIsTheDefault) {
  EXPECT_FALSE(UsbStallPlan{}.enabled());
  EXPECT_EQ(DescribeUsbStallPlan(UsbStallPlan{}), "off");
}

TEST(UsbStallPlanTest, AStallAloneIsOneStallFiveSecondsIn) {
  const UsbStallPlan plan = Plan("300");
  EXPECT_EQ(plan.stall, 300ms);
  EXPECT_EQ(plan.period, 0ms);
  EXPECT_EQ(plan.initial_delay, 5000ms);
  EXPECT_EQ(DescribeUsbStallPlan(plan), "300 ms once, the first 5 s in");
}

TEST(UsbStallPlanTest, APeriodAndADelayCanBothBeGiven) {
  const UsbStallPlan plan = Plan("250@10+2.5");
  EXPECT_EQ(plan.stall, 250ms);
  EXPECT_EQ(plan.period, 10'000ms);
  EXPECT_EQ(plan.initial_delay, 2500ms);
  EXPECT_EQ(DescribeUsbStallPlan(plan),
            "250 ms every 10 s, the first 2.500 s in");

  EXPECT_EQ(Plan("40@0.5").period, 500ms);
  EXPECT_EQ(Plan("40+0").initial_delay, 0ms);
}

TEST(UsbStallPlanTest, WhatCannotBeReadIsRefusedWithTheSpelling) {
  for (const char* text : {"", "abc", "300ms", "-5", "300@", "300+", "300@x",
                           "300+1.2345", "300+5@10", "300@1,5", "0", "4001"}) {
    const UsbStallPlanParse parsed = ParseUsbStallPlan(text);
    EXPECT_FALSE(parsed.plan.has_value()) << text;
    EXPECT_FALSE(parsed.error.empty()) << text;
  }
  EXPECT_NE(ParseUsbStallPlan("abc").error.find("300@10+5"), std::string::npos);
}

TEST(UsbStallPlanTest, AStallTheWatchdogWouldEndIsRefused) {
  EXPECT_TRUE(ParseUsbStallPlan("4000").plan.has_value());
  const UsbStallPlanParse refused = ParseUsbStallPlan("5000");
  EXPECT_FALSE(refused.plan.has_value());
  EXPECT_NE(refused.error.find("watchdog"), std::string::npos);
}

TEST(UsbStallPlanTest, APeriodNoLongerThanTheStallIsRefused) {
  EXPECT_FALSE(ParseUsbStallPlan("500@0.5").plan.has_value());
  EXPECT_TRUE(ParseUsbStallPlan("500@0.6").plan.has_value());
}

// --- The schedule ----------------------------------------------------------

TEST(UsbStallSchedulerTest, NothingIsHeldBackWhenItIsOff) {
  UsbStallScheduler scheduler{UsbStallPlan{}};
  const Clock::time_point start;
  scheduler.Start(start);
  EXPECT_EQ(scheduler.phase(), Phase::kIdle);
  EXPECT_FALSE(scheduler.HoldBack(start + 1h, 0));
  EXPECT_EQ(scheduler.Advance(start + 1h, 0), Event::kNone);
}

TEST(UsbStallSchedulerTest, AStallDrainsThenHoldsThenReleases) {
  UsbStallScheduler scheduler(Plan("300@10+5"));
  const Clock::time_point start;
  scheduler.Start(start);
  EXPECT_EQ(scheduler.phase(), Phase::kWaiting);

  // Before it is due, every transfer goes straight back on the wire.
  EXPECT_FALSE(scheduler.HoldBack(start + 4999ms, 7));

  // Due: from here every completion is held back, and the transfers still in
  // flight are left to complete on their own.
  EXPECT_TRUE(scheduler.HoldBack(start + 5000ms, 7));
  EXPECT_EQ(scheduler.phase(), Phase::kDraining);
  EXPECT_EQ(scheduler.Advance(start + 5001ms, 3), Event::kNone);
  EXPECT_TRUE(scheduler.HoldBack(start + 5002ms, 1));

  // The last one in flight completes: nothing is queued from this moment.
  EXPECT_TRUE(scheduler.HoldBack(start + 5003ms, 0));
  EXPECT_EQ(scheduler.phase(), Phase::kHolding);

  // Held for exactly the time asked, not a moment less.
  EXPECT_EQ(scheduler.Advance(start + 5302ms, 0), Event::kNone);
  EXPECT_EQ(scheduler.Advance(start + 5303ms, 0), Event::kHoldEnded);

  const UsbStallScheduler::Stall& stall = scheduler.last();
  EXPECT_EQ(stall.number, 1U);
  EXPECT_EQ(stall.requested, 300ms);
  EXPECT_EQ(stall.drain, 3ms);
  EXPECT_EQ(stall.zero_queued, 300ms);
  EXPECT_EQ(scheduler.completed(), 1U);

  // And streaming resumes until the next one, on the cadence from when this
  // one was due.
  EXPECT_EQ(scheduler.phase(), Phase::kWaiting);
  EXPECT_FALSE(scheduler.HoldBack(start + 14'999ms, 7));
  EXPECT_TRUE(scheduler.HoldBack(start + 15'000ms, 7));
}

TEST(UsbStallSchedulerTest, AOneOffStallHappensOnce) {
  UsbStallScheduler scheduler(Plan("100+1"));
  const Clock::time_point start;
  scheduler.Start(start);

  EXPECT_TRUE(scheduler.HoldBack(start + 1000ms, 0));
  EXPECT_EQ(scheduler.Advance(start + 1100ms, 0), Event::kHoldEnded);
  EXPECT_EQ(scheduler.phase(), Phase::kIdle);
  EXPECT_FALSE(scheduler.HoldBack(start + 1h, 0));
}

TEST(UsbStallSchedulerTest, TheEventLoopStartsTheHoldWhenNoCompletionDoes) {
  // A device that has itself gone quiet: nothing completes to notice the
  // stall is due, so the event loop has to.
  UsbStallScheduler scheduler(Plan("50+1"));
  const Clock::time_point start;
  scheduler.Start(start);

  EXPECT_EQ(scheduler.Advance(start + 1000ms, 0), Event::kHoldStarted);
  EXPECT_EQ(scheduler.phase(), Phase::kHolding);
  EXPECT_EQ(scheduler.Advance(start + 1050ms, 0), Event::kHoldEnded);
  EXPECT_EQ(scheduler.last().zero_queued, 50ms);
  EXPECT_EQ(scheduler.last().drain, 0ms);
}

TEST(UsbStallSchedulerTest, AHoldOverrunningThePeriodStartsAFreshOne) {
  UsbStallScheduler scheduler(Plan("100@0.2+0"));
  const Clock::time_point start;
  scheduler.Start(start);

  ASSERT_TRUE(scheduler.HoldBack(start, 5));
  // The in-flight transfers take far longer to drain than the period.
  ASSERT_TRUE(scheduler.HoldBack(start + 400ms, 0));
  ASSERT_EQ(scheduler.Advance(start + 500ms, 0), Event::kHoldEnded);

  // Not immediately due again: a period from now.
  EXPECT_FALSE(scheduler.HoldBack(start + 699ms, 5));
  EXPECT_TRUE(scheduler.HoldBack(start + 700ms, 5));
}

TEST(UsbStallSchedulerTest, TheEventLoopIsWokenInTimeToEndTheHold) {
  UsbStallScheduler scheduler(Plan("300+1"));
  const Clock::time_point start;
  scheduler.Start(start);

  // Waiting: no later than the stall is due.
  EXPECT_EQ(scheduler.WaitBound(start, 100ms), 100ms);
  EXPECT_EQ(scheduler.WaitBound(start + 960ms, 100ms), 40ms);

  ASSERT_TRUE(scheduler.HoldBack(start + 1000ms, 0));
  EXPECT_EQ(scheduler.WaitBound(start + 1250ms, 100ms), 50ms);
  EXPECT_EQ(scheduler.WaitBound(start + 1400ms, 100ms), 0ms);
}

TEST(UsbStallSchedulerTest, StartingAgainForgetsTheLastRun) {
  UsbStallScheduler scheduler(Plan("10+0"));
  const Clock::time_point start;
  scheduler.Start(start);
  ASSERT_TRUE(scheduler.HoldBack(start, 0));
  ASSERT_EQ(scheduler.Advance(start + 10ms, 0), Event::kHoldEnded);

  scheduler.Start(start + 1h);
  EXPECT_EQ(scheduler.completed(), 0U);
  EXPECT_EQ(scheduler.phase(), Phase::kWaiting);
}

TEST(UsbStallSchedulerTest, AWallClockMomentIsWrittenAsUtcToTheMillisecond) {
  const std::chrono::system_clock::time_point when =
      std::chrono::system_clock::from_time_t(1'786'624'496) + 7ms;
  EXPECT_EQ(FormatUtcTimestamp(when), "2026-08-13T12:34:56.007Z");
}

}  // namespace
}  // namespace ddd::capture
