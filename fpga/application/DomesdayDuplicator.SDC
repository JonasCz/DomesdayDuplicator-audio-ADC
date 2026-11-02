#************************************************************************
#
#    DomesdayDuplicator.SDC
#
#    Timing constraints
#    Domesday Duplicator - LaserDisc RF sampler
#    SPDX-FileCopyrightText: 2018-2026 Simon Inns
#    SPDX-License-Identifier: GPL-3.0-or-later
#
#************************************************************************
#
# Until 2026 this file was three lines: the 50 MHz input clock and the two
# derive_* commands. That constrained the logic inside the FPGA and nothing at
# its pins, which was survivable while the design's own clocks were the only
# things it had to get right and the FX3 link ran at 60 MHz. Moving to one
# 80 MHz clock makes the pins the interesting part: the FX3 interface is the
# fastest thing on the board, and the ADC's sampling clock is now something
# this design generates in the fabric rather than something the PLL hands it.
#
# READ THIS BEFORE TRUSTING A TIMING REPORT
#
# The clock definitions below are facts about the design and are exact. The
# I/O delays are not: they are **deliberately pessimistic bounds**, not
# datasheet values, because the ADS825, 74LVTH541 and CYUSB3014 datasheets
# were not to hand when this file was written.
#
# They are chosen so that the error is in the safe direction. Every external
# delay is set larger than any plausible real value, and every setup and hold
# requirement is set tighter than the published one. So:
#
#   - if timing closes with these numbers, it closes with the real ones, and
#     the result can be believed;
#   - if it does not close, the numbers are the first thing to check, not the
#     design. Replace the values in the block below with the datasheet ones
#     and re-run before changing any logic.
#
# Each value says what it stands for and what to look up. Nothing else in the
# file needs editing to correct them.
#
# The SDRAM interface is the exception to all of the above: its delays are
# the IS42S16160B datasheet's own figures for the -7 grade, plus a stated
# estimate of the board traces, because an interface this fast cannot be
# closed against bounds pessimistic enough to be safe without the datasheet.
# What is estimated there is the board, and the phase shift chosen from it,
# and TimeQuest's report on those paths is what confirms the choice - see the
# SDRAM section below and fpga/application/sdram-capture-buffer.md.
#
#************************************************************************


# ---------------------------------------------------------------------------
# Values to confirm against the datasheets
# ---------------------------------------------------------------------------

# The altpll output pin that carries the 80 MHz system clock. This is the
# conventional Quartus path for an altpll instance named pll_generator_0; if a
# future Quartus renames it, every reference below comes from here.
set pll_clock_pin {pll_generator_0|altpll_component|auto_generated|pll1|clk[0]}

# The SDRAM controller's 120 MHz clock, and the same frequency shifted to lead
# it, which is driven onto DRAM_CLK. Both from the same altpll as the system
# clock - applicationPll.v, which keeps the instance name above.
set sdram_clock_pin {pll_generator_0|altpll_component|auto_generated|pll1|clk[1]}
set sdram_pin_clock_pin {pll_generator_0|altpll_component|auto_generated|pll1|clk[2]}

# FX3 GPIF II, 16-bit synchronous slave. The FPGA drives PCLK, so these are
# what the FX3 requires of data this design presents to it. CYUSB3014
# publishes about 2 ns setup and 0.5 ns hold; the values here are tighter, so
# meeting them means meeting the real ones.
set fx3_setup 2.5
set fx3_hold 1.0

# What the FX3 does with its own outputs, relative to the same PCLK edge -
# readData is the only one this design times. A clock-to-out window of 1 to
# 8 ns is wider than the part is specified for, which makes the constraint
# harder to meet rather than easier.
set fx3_ctl_max 8.0
set fx3_ctl_min 1.0

# The ADC data path: ADS825 clock-to-data, plus two 74LVTH541 buffers between
# the converter and the FPGA (see the hardware guide - they are there to keep
# the ADC's own switching noise off the analogue front end), plus the board
# and header traces. 15 ns is far more than that sum can plausibly be; the
# path has a 25 ns budget, so even this bound leaves room.
set adc_data_max 15.0
set adc_data_min 2.0

# The IS42S16160B, -7 speed grade, at CAS latency 3: input setup and hold
# (tDS/tDH; tAS/tAH, tCKS/tCKH and tCS/tCH carry the same figures), and the
# access time and output hold of read data (tAC, tOH)
set sdram_tds 1.5
set sdram_tdh 0.8
set sdram_tac 5.4
set sdram_toh 2.7

# The DE0-Nano's traces between the FPGA and the SDRAM, each way, as an
# estimate: the part sits beside the FPGA, a few centimetres of trace at
# roughly 6 ps/mm. Not measured. The range is wide on purpose; the clock trace
# is taken from the same range independently, so a skew between the clock and
# the signals of up to its full width is allowed for.
set sdram_trace_min 0.1
set sdram_trace_max 0.5

# The longest a signal crossing between the 80 and 120 MHz domains may take
# from the register that launches it to the synchroniser that first samples
# it - shorter than either clock's period, which is what keeps every bit of a
# Gray-coded pointer within one source clock of the others.
set cdc_max_delay 8.000


# ---------------------------------------------------------------------------
# Clocks
# ---------------------------------------------------------------------------

# The DE0-Nano's 50 MHz oscillator, the only clock that enters the FPGA
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]

# The PLL's three outputs: the 80 MHz system clock, which everything but the
# SDRAM controller runs from, the controller's 120 MHz, and its leading copy
# for DRAM_CLK. This one command defines all three, so it covers every
# internal path.
derive_pll_clocks

# PCLK to the FX3 is the system clock driven straight onto a pin, so the clock
# at the pin is a one-to-one copy of it. Without this the FX3 databus has no
# clock to be constrained against and the whole interface goes unanalysed.
create_generated_clock -name fx3_pclk \
    -source [get_pins $pll_clock_pin] \
    [get_ports {GPIO1[31]}]

# The ADC's 40 MHz sampling clock: the divide-by-two register's output, driven
# onto a pin.
#
# Sourced from the PLL rather than from the divider's own clock pin, which is
# what this said first and which Quartus rejected outright: "Argument -source
# is a collection with more than one object". The FAST_OUTPUT_REGISTER
# assignment on this pin makes the fitter duplicate the divider, one copy in
# the I/O cell and one in the fabric driving sample_enable, so the register
# name matches two pins and is not a usable source. The .qsf predicted the
# duplication; this file did not account for it.
#
# It failed loudly, but everything downstream of it failed quietly: with no
# adc_clock defined, the two set_input_delay commands and both multicycle
# exceptions below were dropped as well, and the ADC databus went unanalysed.
create_generated_clock -name adc_clock \
    -source [get_pins $pll_clock_pin] \
    -divide_by 2 \
    [get_ports {GPIO0[33]}]

# The remote update block's clock, a divide-by-four of the system clock made in
# the fabric by remoteUpdate. It is divided because the block is specified for a
# 25 ns minimum period and 10.1 ns minimum high and low times on this device, so
# the 80 MHz system clock violates it by a factor of two; Quartus checks this,
# and without the constraint below it would check the divided clock against the
# system clock's pulse widths and report a violation that is not there.
create_generated_clock -name update_clock \
    -source [get_pins $pll_clock_pin] \
    -divide_by 4 \
    [get_registers {*update_clock}]

# The SDRAM's clock: the PLL's leading 120 MHz output, driven straight onto
# the pin. Defined at the pin so that the SDRAM interface below is timed
# against the clock the part actually receives, including the delay out of
# the FPGA to get there.
create_generated_clock -name sdram_clk \
    -source [get_pins $sdram_pin_clock_pin] \
    [get_ports {DRAM_CLK}]

derive_clock_uncertainty


# ---------------------------------------------------------------------------
# Port groups
# ---------------------------------------------------------------------------

# Everything the FX3 samples on a PCLK edge: the 16-bit databus, and the two
# flags it reads alongside it.
set fx3_synchronous_outputs [get_ports { \
    GPIO1[2]  GPIO1[4]  GPIO1[6]  GPIO1[8]  GPIO1[10] GPIO1[12] GPIO1[14] \
    GPIO1[16] GPIO1[18] GPIO1[20] GPIO1[22] GPIO1[24] GPIO1[26] GPIO1[28] \
    GPIO1[30] GPIO1[32] \
    GPIO1[27] \
    GPIO1[21] }]

# readData, the one FX3 output this design captures on a clock edge
set fx3_synchronous_inputs [get_ports {GPIO1[25]}]

# The 10-bit ADC databus
set adc_data_inputs [get_ports { \
    GPIO0[23] GPIO0[24] GPIO0[25] GPIO0[26] GPIO0[27] \
    GPIO0[28] GPIO0[29] GPIO0[30] GPIO0[31] GPIO0[32] }]

# Everything the SDRAM samples on its clock: commands, addresses, masks, clock
# enable and write data
set sdram_outputs [get_ports { \
    DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_CKE DRAM_CS_N DRAM_DQM[*] \
    DRAM_RAS_N DRAM_WE_N DRAM_DQ[*] }]

# Read data
set sdram_inputs [get_ports {DRAM_DQ[*]}]


# ---------------------------------------------------------------------------
# The FX3 interface
# ---------------------------------------------------------------------------
#
# Source-synchronous, with this design as the source: it drives PCLK and the
# data together, and the FX3 samples both. The setup requirement becomes the
# maximum output delay and the hold requirement the minimum, negated.
#
# This is the fastest interface on the board and the one the move to 80 MHz
# puts most pressure on, so it is the report to read first.

set_output_delay -clock fx3_pclk -max $fx3_setup $fx3_synchronous_outputs
set_output_delay -clock fx3_pclk -min [expr {0 - $fx3_hold}] $fx3_synchronous_outputs

set_input_delay -clock fx3_pclk -max $fx3_ctl_max $fx3_synchronous_inputs
set_input_delay -clock fx3_pclk -min $fx3_ctl_min $fx3_synchronous_inputs


# ---------------------------------------------------------------------------
# The ADC interface
# ---------------------------------------------------------------------------
#
# The FPGA drives the ADC's clock and reads the result back, so this is
# source-synchronous with the FPGA as the source of the clock and the ADC as
# the source of the data.

set_input_delay -clock adc_clock -max $adc_data_max $adc_data_inputs
set_input_delay -clock adc_clock -min $adc_data_min $adc_data_inputs

# The sample the ADC launches on one of its clock edges is captured a whole
# ADC period later, not on the next system clock edge - dataGenerator only
# takes a sample when sample_enable is high, which is every second system
# clock edge, and those are exactly the edges the ADC clock rises on.
#
# Without this the analysis would allow 12.5 ns for a path the design gives
# 25 ns, and would report a failure that does not exist. The hold multicycle
# is one less than the setup multicycle, which is what keeps the hold check
# against the same edge it was against before the exception.
set_multicycle_path -setup 2 -from [get_clocks adc_clock] -to [get_clocks $pll_clock_pin]
set_multicycle_path -hold 1 -from [get_clocks adc_clock] -to [get_clocks $pll_clock_pin]


# ---------------------------------------------------------------------------
# The audio converters
# ---------------------------------------------------------------------------
#
# The ADC128S022 on the DE0-Nano's own pins, and the PCM1802 on JP3. Both are
# driven entirely by system-clock registers that the capture enable steps at
# fixed slots of the sample frame (adc128spiController.v, pcm1802Slave.v), so
# neither has a clock of its own for an I/O delay to be referred to: SCLK,
# SCKI, BCK and LRCK are outputs this design sets, not clocks anything in it
# runs on.
#
# What times them is the protocol. Each output changes at least two capture
# slots - 25 ns each at 40 Msps, 50 ns decimating - from any edge the
# converter samples it against, and usually four or eight. Each input is read
# at least 40 ns (PCM1802) or 125 ns (ADC128S022) after the converter has
# finished changing it and at least 90 ns before it can change again. Routing
# to and from a pin on this device is a few nanoseconds either way, which
# those margins cover many times over; the arithmetic is in each module's
# header and the datasheet figures it uses are cited there.
#
# So they are false paths, as the SPI register link below is. Analysing them
# against the 80 MHz clock would demand a single-cycle relationship the design
# never relies on, and would report failures on paths that have hundreds of
# nanoseconds to spare.
set audio_outputs [get_ports { \
    ADC_CS_N ADC_SADDR ADC_SCLK \
    GPIO_2[0] GPIO_2[3] GPIO_2[5] }]

set audio_inputs [get_ports { \
    ADC_SDAT \
    GPIO_2_IN[0] }]

set_false_path -to $audio_outputs
set_false_path -from $audio_inputs


# ---------------------------------------------------------------------------
# The SDRAM interface
# ---------------------------------------------------------------------------
#
# Source-synchronous in both directions with this design driving the clock.
# The controller's registers are all in the pins' I/O cells (the .qsf), so
# what is timed here is the I/O cells, the pin buffers and the board.
#
# Outputs: a command registered on a controller edge is taken by the SDRAM on
# the next DRAM_CLK edge, which - DRAM_CLK leading by 3.5 ns - comes about
# 4.8 ns later. That is the default single-cycle relationship, so no exception
# is needed. The external delay is the part's setup or hold plus the
# difference between the signal's trace and the clock's.
set_output_delay -clock sdram_clk \
    -max [expr {$sdram_tds + $sdram_trace_max - $sdram_trace_min}] $sdram_outputs
set_output_delay -clock sdram_clk \
    -min [expr {0 - $sdram_tdh + $sdram_trace_min - $sdram_trace_max}] $sdram_outputs

# Inputs: read data is launched by a DRAM_CLK edge, reaches the pin tAC (at
# worst) after it plus the clock's trace out and the data's trace back, and is
# captured by the input register in the I/O cell on the second controller
# edge after the launching DRAM_CLK edge - the first comes only 3.5 ns after
# it, before the data. sdramController.v's capture pipeline is built on the
# same statement.
set_input_delay -clock sdram_clk \
    -max [expr {$sdram_tac + 2 * $sdram_trace_max}] $sdram_inputs
set_input_delay -clock sdram_clk \
    -min [expr {$sdram_toh + 2 * $sdram_trace_min}] $sdram_inputs

# So the setup check moves to that second edge. The hold check is left where
# a setup multicycle of 2 puts it by default, one controller edge earlier -
# the edge just after the launch - and that is the right one here: it is the
# edge still capturing the previous word, which the newly launched word must
# not reach before tOH has passed. Adding the customary "-hold 1" would move
# the hold check a whole cycle earlier still and stop checking anything real.
set_multicycle_path -setup 2 -from [get_clocks sdram_clk] -to [get_clocks $sdram_clock_pin]


# ---------------------------------------------------------------------------
# The 80 <-> 120 MHz crossings
# ---------------------------------------------------------------------------
#
# The two clocks come from one PLL, so TimeQuest would by default time paths
# between them as synchronous, against the closest their edges ever come -
# about 4 ns. The design does not rely on that relationship: everything that
# crosses goes through sdramBuffer.v's dual-clock FIFOs or a two-register
# synchroniser, and every register that first samples the other domain is
# named *_meta. So those paths are given a bound instead of a relationship,
# and their hold check, which has nothing to protect at a synchroniser, is
# cut. set_clock_groups is deliberately not used: it would cut the bound too.
#
# The status word's held value is the one multi-bit crossing that is not a
# Gray code. It is stable from before its request toggles until after the
# acknowledgement returns, so the same bound is ample.
#
# Any other path between the two domains is a mistake, and leaving it to be
# timed synchronously is what makes it show up.
set_max_delay -to [get_registers {sdram_buffer_0|*_meta*}] $cdc_max_delay
set_false_path -hold -to [get_registers {sdram_buffer_0|*_meta*}]

set_max_delay -from [get_registers {sdram_buffer_0|status_hold_register[*]}] $cdc_max_delay
set_false_path -hold -from [get_registers {sdram_buffer_0|status_hold_register[*]}]


# ---------------------------------------------------------------------------
# Paths that are not timed, and why
# ---------------------------------------------------------------------------

# The SPI register link. Mode 0, and the master is the FX3 bit-banging GPIO
# through register writes, so the fastest it can go is two orders of magnitude
# below the 2 MHz the slave is specified for. All three inputs go through
# two-flop synchronisers and glitch filters in spiRegisters, which is what
# makes them safe to be asynchronous; timing them against the system clock
# would be constraining a relationship that does not exist.
set_false_path -from [get_ports {GPIO1[17]}]
set_false_path -from [get_ports {GPIO1[15]}]
set_false_path -from [get_ports {GPIO1[11]}]
set_false_path -to [get_ports {GPIO1[13]}]

# nReset from the FX3. It asserts asynchronously by design - a reset that
# needed a clock edge would not work when there is no clock - and the top
# level synchronises its release before any logic sees it, so recovery and
# removal analysis on the pin itself has nothing to say.
set_false_path -from [get_ports {GPIO1[7]}]

# The PLL's lock joins nReset in clearing the two reset synchronisers, one per
# clock domain. It has no clock relationship to either, for the same reason,
# and the synchronisers are what make its release safe. Cut at the
# synchronisers rather than at the PLL's lock output, whose name in the
# netlist is the megafunction's and not this project's.
set_false_path -to [get_registers {*reset_n_sync[*]}]

# collectData from the FX3, GPIO19. A level the host's start and stop requests
# set, with no relationship to any clock here; sdramBuffer.v synchronises it.
set_false_path -from [get_ports {GPIO1[23]}]

# The status LEDs. Driven from the register bank for a human to look at.
set_false_path -to [get_ports {LED[*]}]

# FX3 control lines the board wires up and this design does not use. They are
# tied off or ignored; the pin assignments are fixed by the PCB.
set_false_path -from [get_ports {GPIO1[9]}]
set_false_path -to [get_ports {GPIO1[19]}]
set_false_path -to [get_ports {GPIO1[5]}]
set_false_path -to [get_ports {GPIO1[3]}]
