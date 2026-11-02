/************************************************************************

    DomesdayDuplicator.v

    Top-level module
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2018-2026 Simon Inns
    SPDX-License-Identifier: GPL-3.0-or-later

************************************************************************/

`include "version.vh"

module DomesdayDuplicator (
    input         CLOCK_50,
    inout  [33:0] GPIO0,
    inout  [33:0] GPIO1,
    output [ 7:0] LED,

    // The DE0-Nano's ADC128S022, on its own dedicated pins
    output ADC_CS_N,
    output ADC_SADDR,
    output ADC_SCLK,
    input  ADC_SDAT,

    // The 2x13 header JP3, which carries the PCM1802
    inout [12:0] GPIO_2,
    input [ 2:0] GPIO_2_IN,

    // The on-board SDRAM, under the DE0-Nano's own names for its pins
    output [12:0] DRAM_ADDR,
    output [ 1:0] DRAM_BA,
    output        DRAM_CAS_N,
    output        DRAM_CKE,
    output        DRAM_CLK,
    output        DRAM_CS_N,
    inout  [15:0] DRAM_DQ,
    output [ 1:0] DRAM_DQM,
    output        DRAM_RAS_N,
    output        DRAM_WE_N
);

    // FX3 Hardware mapping begins ------------------------------------------------

    // Generic pin-mapping for FX3 (DomDupBoard revisions 2_0 to 3_0)
    wire [15:0] fx3_databus;  // 32-bit databus (only 16-bits used)
    wire [12:0] fx3_control;  // 13-bit control bus
    wire        fx3_clock;  // FX3 GPIF Clock

    // 32-bit data bus physical mapping (output only)
    // Note: board supports 32-bits; software is limited to 16-bits
    assign GPIO1[32]       = fx3_databus[00];
    assign GPIO1[30]       = fx3_databus[01];
    assign GPIO1[28]       = fx3_databus[02];
    assign GPIO1[26]       = fx3_databus[03];
    assign GPIO1[24]       = fx3_databus[04];
    assign GPIO1[22]       = fx3_databus[05];
    assign GPIO1[20]       = fx3_databus[06];
    assign GPIO1[18]       = fx3_databus[07];
    assign GPIO1[16]       = fx3_databus[08];
    assign GPIO1[14]       = fx3_databus[09];
    assign GPIO1[12]       = fx3_databus[10];
    assign GPIO1[10]       = fx3_databus[11];
    assign GPIO1[08]       = fx3_databus[12];
    assign GPIO1[06]       = fx3_databus[13];
    assign GPIO1[04]       = fx3_databus[14];
    assign GPIO1[02]       = fx3_databus[15];

    // High-Z the unused FX3 databus pins
    assign GPIO0[02]       = 1'bZ;
    assign GPIO0[03]       = 1'bZ;
    assign GPIO0[04]       = 1'bZ;
    assign GPIO0[05]       = 1'bZ;
    assign GPIO0[06]       = 1'bZ;
    assign GPIO0[07]       = 1'bZ;
    assign GPIO0[12]       = 1'bZ;
    assign GPIO0[13]       = 1'bZ;
    assign GPIO0[14]       = 1'bZ;
    assign GPIO0[15]       = 1'bZ;
    assign GPIO0[16]       = 1'bZ;
    assign GPIO0[17]       = 1'bZ;
    assign GPIO0[18]       = 1'bZ;
    assign GPIO0[19]       = 1'bZ;
    assign GPIO0[20]       = 1'bZ;
    assign GPIO0[21]       = 1'bZ;

    // Mappings for 32-bit databus
    //assign GPIO0[02] = fx3_databus[16];
    //assign GPIO0[03] = fx3_databus[17];
    //assign GPIO0[04] = fx3_databus[18];
    //assign GPIO0[05] = fx3_databus[19];
    //assign GPIO0[06] = fx3_databus[20];
    //assign GPIO0[07] = fx3_databus[21];
    //assign GPIO0[12] = fx3_databus[22];
    //assign GPIO0[13] = fx3_databus[23];
    //assign GPIO0[14] = fx3_databus[24];
    //assign GPIO0[15] = fx3_databus[25];
    //assign GPIO0[16] = fx3_databus[26];
    //assign GPIO0[17] = fx3_databus[27];
    //assign GPIO0[18] = fx3_databus[28];
    //assign GPIO0[19] = fx3_databus[29];
    //assign GPIO0[20] = fx3_databus[30];
    //assign GPIO0[21] = fx3_databus[31];

    // FX3 Clock physical mapping
    assign GPIO1[31]       = fx3_clock;  // FX3 GPIO_16

    // 13-bit control bus physical mapping (outputs)
    assign GPIO1[27]       = fx3_control[00];  // FX3 CTL_00 GPIO_17 (output)
    assign GPIO1[21]       = fx3_control[03];  // FX3 CTL_03 GPIO_20 (output)
    assign GPIO1[19]       = fx3_control[04];  // FX3 CTL_04 GPIO_21 (output)
    assign GPIO1[13]       = fx3_control[07];  // FX3 CTL_07 GPIO_24 (output)
    assign GPIO1[05]       = fx3_control[11];  // FX3 CTL_11 GPIO_28 (output)
    assign GPIO1[03]       = fx3_control[12];  // FX3 CTL_12 GPIO_29 (output)

    // 13-bit control bus physical mapping (inputs)
    assign fx3_control[01] = GPIO1[25];  // FX3 CTL_01 GPIO_18
    assign fx3_control[02] = GPIO1[23];  // FX3 CTL_02 GPIO_19
    assign fx3_control[05] = GPIO1[17];  // FX3 CTL_05 GPIO_22
    assign fx3_control[06] = GPIO1[15];  // FX3 CTL_06 GPIO_23
    assign fx3_control[08] = GPIO1[11];  // FX3 CTL_08 GPIO_25
    assign fx3_control[09] = GPIO1[09];  // FX3 CTL_09 GPIO_26
    assign fx3_control[10] = GPIO1[07];  // FX3 CTL_10 GPIO_27

    // High-Z the unused GPIO0 pins
    assign GPIO0[0]        = 1'bZ;
    assign GPIO0[1]        = 1'bZ;
    assign GPIO0[8]        = 1'bZ;
    assign GPIO0[9]        = 1'bZ;
    assign GPIO0[10]       = 1'bZ;
    assign GPIO0[11]       = 1'bZ;
    assign GPIO0[22]       = 1'bZ;
    assign GPIO0[23]       = 1'bZ;
    assign GPIO0[24]       = 1'bZ;
    assign GPIO0[25]       = 1'bZ;
    assign GPIO0[26]       = 1'bZ;
    assign GPIO0[27]       = 1'bZ;
    assign GPIO0[28]       = 1'bZ;
    assign GPIO0[29]       = 1'bZ;
    assign GPIO0[30]       = 1'bZ;
    assign GPIO0[31]       = 1'bZ;
    assign GPIO0[32]       = 1'bZ;

    // High-Z the unused GPIO1 pins
    assign GPIO1[0]        = 1'bZ;
    assign GPIO1[1]        = 1'bZ;
    assign GPIO1[7]        = 1'bZ;
    assign GPIO1[9]        = 1'bZ;
    assign GPIO1[11]       = 1'bZ;
    assign GPIO1[15]       = 1'bZ;
    assign GPIO1[17]       = 1'bZ;
    assign GPIO1[23]       = 1'bZ;
    assign GPIO1[25]       = 1'bZ;
    assign GPIO1[29]       = 1'bZ;
    assign GPIO1[33]       = 1'bZ;

    // FX3 Signal mapping:
    //
    // Signal            GPIO     CTL     Direction Description
    //
    // CLK               GPIO16   PCLK    Output    - Data clock
    // Databus           GPIO0:15         Output    - Databus
    // data_available    GPIO_17  CTL_00  Output    - FPGA signals if data is available for reading
    // reset_n           GPIO_27  CTL_10  Input     - FX3 signals (not) reset condition
    // collect_data      GPIO_19  CTL_02  Input     - FX3 signals a capture is running
    // read_data         GPIO_18  CTL_01  Input     - FX3 signals it is reading from the databus
    //
    // input0            GPIO_20  CTL_03  Output    - Buffer error flag from FPGA
    // input1            GPIO_21  CTL_04  Output    - Unused
    // input2            GPIO_28  CTL_11  Output    - Unused
    // input3            GPIO_29  CTL_12  Output    - Unused
    //
    // spi_clock         GPIO_22  CTL_05  Input     - SPI clock from the FX3
    // spi_mosi          GPIO_23  CTL_06  Input     - SPI data from the FX3
    // spi_miso          GPIO_24  CTL_07  Output    - SPI data to the FX3
    // spi_chip_select_n GPIO_25  CTL_08  Input     - SPI chip select from the FX3 (active low)
    // (reserved)        GPIO_26  CTL_09  Input     - Unused; wired and held for a future signal

    // The four SPI lines replace what were five one-bit configuration signals, of
    // which only test mode was ever used. They reach the register bank in
    // spiRegisters, which is where test mode and the status LEDs now live; the
    // contract is the "FPGA register interface" page of the documentation site.

    // Wire definitions for FX3 GPIO mapping
    wire       fx3_reset_n;
    wire       fx3_collect_data;
    wire       fx3_data_available;
    wire       fx3_read_data;
    wire       fx3_buffer_error;
    wire       fx3_spi_clock;
    wire       fx3_spi_mosi;
    wire       fx3_spi_miso;
    wire       fx3_spi_chip_select_n;
    wire       fx3_test_mode;
    wire [7:0] fx3_decimation;

    // Signal outputs to FX3
    assign fx3_control[00]       = fx3_data_available;
    assign fx3_control[03]       = fx3_buffer_error;
    assign fx3_control[07]       = fx3_spi_miso;

    // These are currently unused, but must have a defined value
    assign fx3_control[04]       = 1'b0;
    assign fx3_control[11]       = 1'b0;
    assign fx3_control[12]       = 1'b0;

    // Signal inputs from FX3
    assign fx3_reset_n           = fx3_control[10];
    assign fx3_collect_data      = fx3_control[02];
    assign fx3_read_data         = fx3_control[01];

    // Signal inputs from FX3 (SPI register interface)
    assign fx3_spi_clock         = fx3_control[05];
    assign fx3_spi_mosi          = fx3_control[06];
    assign fx3_spi_chip_select_n = fx3_control[08];

    // FX3 Hardware mapping ends --------------------------------------------------


    // ADC Hardware mapping begins ------------------------------------------------

    wire [9:0] adc_databus;

    // 10-bit databus from ADC
    assign adc_databus[0] = GPIO0[32];
    assign adc_databus[1] = GPIO0[31];
    assign adc_databus[2] = GPIO0[30];
    assign adc_databus[3] = GPIO0[29];
    assign adc_databus[4] = GPIO0[28];
    assign adc_databus[5] = GPIO0[27];
    assign adc_databus[6] = GPIO0[26];
    assign adc_databus[7] = GPIO0[25];
    assign adc_databus[8] = GPIO0[24];
    assign adc_databus[9] = GPIO0[23];

    // ADC clock output - a divide-by-two of the system clock, generated below
    wire adc_clock;
    assign GPIO0[33] = adc_clock;

    // ADC Hardware mapping ends --------------------------------------------------


    // Audio hardware mapping begins ----------------------------------------------

    // ADC128S022, the DE0-Nano's own converter. Its analogue inputs IN0 and
    // IN1 - left and right - are JP3 pins 24 and 25. ADC_SADDR is the
    // converter's DIN and ADC_SDAT its DOUT; the names are Terasic's.
    wire adc128_chip_select_n;
    wire adc128_serial_clock;
    wire adc128_din;
    wire adc128_dout;

    assign ADC_CS_N    = adc128_chip_select_n;  // PIN_A10
    assign ADC_SCLK    = adc128_serial_clock;  // PIN_B14
    assign ADC_SADDR   = adc128_din;  // PIN_B10
    assign adc128_dout = ADC_SDAT;  // PIN_A9

    // PCM1802 on JP3, wired as the fork wired it. The converter's FSYNC is
    // not on any pin here and must be tied high at the converter.
    wire pcm1802_scki;
    wire pcm1802_bck;
    wire pcm1802_lrck;
    wire pcm1802_dout;

    assign GPIO_2[0]    = pcm1802_scki;  // JP3 pin 5,  PIN_A14 - SCKI
    assign GPIO_2[3]    = pcm1802_bck;  // JP3 pin 8,  PIN_C16 - BCK
    assign GPIO_2[5]    = pcm1802_lrck;  // JP3 pin 10, PIN_D16 - LRCK
    assign pcm1802_dout = GPIO_2_IN[0];  // JP3 pin 2,  PIN_E15 - DOUT

    // High-Z the unused JP3 pins. GPIO_2_IN[2:1], JP3 pins 3 and 4, are
    // input-only and are not read.
    assign GPIO_2[1]    = 1'bZ;
    assign GPIO_2[2]    = 1'bZ;
    assign GPIO_2[4]    = 1'bZ;
    assign GPIO_2[6]    = 1'bZ;
    assign GPIO_2[7]    = 1'bZ;
    assign GPIO_2[8]    = 1'bZ;
    assign GPIO_2[9]    = 1'bZ;
    assign GPIO_2[10]   = 1'bZ;
    assign GPIO_2[11]   = 1'bZ;
    assign GPIO_2[12]   = 1'bZ;

    // Audio hardware mapping ends ------------------------------------------------


    // Application logic begins ---------------------------------------------------


    // PLL clock generation
    //
    // One 80 MHz system clock from the 50 MHz physical clock, and everything
    // but the SDRAM controller runs from it. The sampling rate is set by
    // decimating this clock rather than by a clock of its own, which is what
    // lets the FX3 drain faster than the ADC fills without the two sides
    // having to be synchronised to each other.
    //
    // 80 MHz because it is the lowest multiple of the 40 MSPS sampling rate
    // that leaves the FX3 room to catch up. The GPIF II interface is specified
    // to 100 MHz, so this is inside it; the ADC needs a uniform clock, so the
    // system clock has to be an exact multiple of the sampling rate, which
    // 60 MHz was not.
    //
    // The SDRAM capture buffer adds a second domain, at 120 MHz, for its
    // controller alone: at 80 MHz the SDRAM cannot carry a capture going in and
    // coming out at the same time. The two meet only through the dual-clock
    // FIFOs and synchronisers in sdramBuffer. The third output is the 120 MHz
    // clock shifted to lead, for the SDRAM's clock pin.
    //
    // This is applicationPll rather than the IPpllGenerator the factory image
    // uses, so that adding the clocks changed nothing the factory image is
    // built from - see the head of applicationPll.v.
    wire system_clock;
    wire sdram_clock;
    wire sdram_pin_clock;
    wire pll_locked;

    applicationPll pll_generator_0 (
        // Inputs
        .inclk0(CLOCK_50),

        // Outputs
        .c0    (system_clock),     // 80 MHz system clock
        .c1    (sdram_clock),      // 120 MHz SDRAM controller clock
        .c2    (sdram_pin_clock),  // 120 MHz, leading, for DRAM_CLK
        .locked(pll_locked)        // 1 = the three clocks are stable
    );

    // The FX3's GPIF II is a synchronous slave and this pin is the clock it
    // runs from, so it is simply the system clock.
    assign fx3_clock = system_clock;

    // ADC sampling clock and the sampling instant
    //
    // A divide-by-two of the system clock, free-running and with no reset:
    // the ADC is a pipelined converter whose analogue behaviour was
    // characterised with a clock that is always present, and stopping it
    // whenever the host closes the device would be a change to the front end
    // rather than to the logic. The initial value is the power-up state, and
    // which phase it powers up in does not matter.
    //
    // sample_enable is high on the system clock edge that takes adc_clock
    // high, so the design captures the ADC bus at the same instant it did when
    // this module was clocked by the ADC clock directly - one full 40 MHz
    // period after the sample was launched.
    reg adc_clock_divider;

    initial begin
        adc_clock_divider = 1'b0;
    end

    always @(posedge system_clock) begin
        adc_clock_divider <= ~adc_clock_divider;
    end

    assign adc_clock = adc_clock_divider;

    wire       sample_enable = ~adc_clock_divider;

    // Reset synchroniser
    //
    // fx3_reset_n is driven by the FX3 and is asynchronous to the system
    // clock. Asserting asynchronously is what the design has always done and
    // is what makes a reset work with no clock; releasing it synchronously is
    // new, and is what stops two registers coming out of reset on different
    // cycles because they resolved the same asynchronous edge differently.
    //
    // The PLL's lock holds it too, so nothing leaves reset on a clock that is
    // still settling. Both clock domains are reset from this one source, each
    // through a synchroniser of its own, because the dual-clock FIFOs between
    // them must have both halves reset together.
    wire       reset_source_n = fx3_reset_n && pll_locked;

    reg  [1:0] reset_n_sync;

    always @(posedge system_clock, negedge reset_source_n) begin
        if (!reset_source_n) begin
            reset_n_sync <= 2'b00;
        end else begin
            reset_n_sync <= {reset_n_sync[0], 1'b1};
        end
    end

    wire       reset_n = reset_n_sync[1];

    reg  [1:0] sdram_reset_n_sync;

    always @(posedge sdram_clock, negedge reset_source_n) begin
        if (!reset_source_n) begin
            sdram_reset_n_sync <= 2'b00;
        end else begin
            sdram_reset_n_sync <= {sdram_reset_n_sync[0], 1'b1};
        end
    end

    wire        sdram_reset_n = sdram_reset_n_sync[1];

    wire        fx3_is_reading;
    wire [15:0] data_generator_out;

    // Sample rate
    //
    // The register holds the decimation factor rather than a flag, so that a
    // host reading it back gets a positive statement of what the capture path
    // is doing rather than an echo of what it asked for. Two is the only
    // factor this gateware implements; the bank normalises anything else to
    // one, so this comparison is the whole of the decode.
    wire        fx3_decimate = (fx3_decimation == 8'h02);

    wire [ 9:0] capture_sample;
    wire        capture_enable;

    // Anti-aliased 2:1 decimation, for tape capture
    //
    // In front of the data generator rather than behind it, which is the
    // arrangement that keeps the sequence counter honest: the counter is
    // attached to the samples that survive, so a decimated capture carries an
    // unbroken count and the host's integrity check works on it unchanged. A
    // decimator placed after the generator would drop every second sequence
    // number and every capture would read as damaged.
    //
    // It filters the ADC and nothing else. The test pattern is generated
    // downstream at the rate the decimator sets, so a test capture is an
    // unbroken ramp at whichever rate is selected and the integrity oracle
    // covers the decimated path as well as the full-rate one.
    halfBandDecimator half_band_decimator_0 (
        // Inputs
        .reset_n      (reset_n),        // Not reset
        .clock        (system_clock),   // 80 MHz system clock
        .sample_enable(sample_enable),  // 1 = a sample arrives on this edge
        .data_in      (adc_databus),    // 10-bit ADC databus
        .decimate     (fx3_decimate),   // 1 = filter and halve the rate

        // Outputs
        .data_out     (capture_sample),  // 10-bit filtered sample
        .output_enable(capture_enable)   // 1 = a sample worth keeping
    );

    // The SDRAM capture buffer's status, for the stream: layout version,
    // whether the path is in use, whether the SDRAM is initialised, whether a
    // sample has been lost to it since the capture started, and its fill in
    // rows. The framed format carries it in the header's slots 36, 37, 46 and
    // 47; framed-sample-format.md defines the word.
    wire [23:0] sdram_status;

    // The audio converters' latest samples, and the frame slot they are
    // timed from
    wire [ 8:0] frame_position;
    wire [11:0] adc128_left;
    wire [11:0] adc128_right;
    wire [23:0] pcm1802_left;
    wire [23:0] pcm1802_right;

    // Generate 16-bit data either from the ADC or the test data generator
    //
    // In the framed sample format: bits 9:0 are the sample exactly as before,
    // and bits 15:10 carry 512-sample frames of sync pattern, audio and a
    // 48-bit counter in place of the six-bit sequence number. The counter,
    // like the sequence number it replaces, is attached to the samples that
    // survive the decimator, so a decimated capture is an unbroken run of
    // frames. fpga/application/framed-sample-format.md is the specification.
    dataGenerator #(
        .FramedFormat(1'b1)
    ) data_generator_0 (
        // Inputs
        .reset_n       (reset_n),         // Not reset
        .clock         (system_clock),    // 80 MHz system clock
        .sample_enable (capture_enable),  // 1 = take a sample on this edge
        .adc_databus   (capture_sample),  // 10-bit sample from the decimator
        .test_mode_flag(fx3_test_mode),   // 1 = Test mode on
        .adc128_left   (adc128_left),     // ADC128S022 IN0
        .adc128_right  (adc128_right),    // ADC128S022 IN1
        .pcm1802_left  (pcm1802_left),    // PCM1802 left
        .pcm1802_right (pcm1802_right),   // PCM1802 right
        .status_word   (sdram_status),    // SDRAM capture buffer status

        // Outputs
        .data_out      (data_generator_out),  // 16-bit data out
        .frame_position(frame_position)       // Frame slot of data_out
    );

    // Audio capture
    //
    // Both converters are timed from the frame slot rather than from counters
    // of their own, and ticked by the capture enable rather than the ADC's, so
    // one stereo sample from each lands in every frame at whichever rate is
    // selected: 78.125 kHz at 40 Msps and 39.0625 kHz decimating. Neither is
    // clocked by anything but the system clock; the converters' clocks are
    // register outputs.
    adc128spiController adc128_controller_0 (
        // Inputs
        .reset_n       (reset_n),         // Not reset
        .clock         (system_clock),    // 80 MHz system clock
        .sample_enable (capture_enable),  // 1 = a sample is taken on this edge
        .frame_position(frame_position),  // Frame slot of that sample
        .adc_dout      (adc128_dout),     // ADC_SDAT

        // Outputs
        .adc_chip_select_n(adc128_chip_select_n),  // ADC_CS_N
        .adc_serial_clock (adc128_serial_clock),   // ADC_SCLK
        .adc_din          (adc128_din),            // ADC_SADDR
        .audio_left       (adc128_left),           // IN0
        .audio_right      (adc128_right)           // IN1
    );

    pcm1802Slave pcm1802_slave_0 (
        // Inputs
        .reset_n       (reset_n),         // Not reset
        .clock         (system_clock),    // 80 MHz system clock
        .sample_enable (capture_enable),  // 1 = a sample is taken on this edge
        .frame_position(frame_position),  // Frame slot of that sample
        .pcm_dout      (pcm1802_dout),    // DOUT

        // Outputs
        .pcm_scki   (pcm1802_scki),  // SCKI, 256 fs
        .pcm_bck    (pcm1802_bck),   // BCK, 64 fs
        .pcm_lrck   (pcm1802_lrck),  // LRCK, fs
        .audio_left (pcm1802_left),  // VINL
        .audio_right(pcm1802_right)  // VINR
    );

    // The capture buffer's back-pressure instrument, on its way to the register
    // bank. The latch pulse comes back the other way and is the only thing the
    // host can do to the buffer at all.
    wire [127:0] buffer_telemetry;
    wire [ 47:0] buffer_telemetry_geometry;
    wire         buffer_telemetry_latch;

    // SDRAM capture buffer
    //
    // Between the sampling side and the FIFO buffer while the FX3 says a
    // capture is running, and bypassed otherwise, so that a host that never
    // asks for a capture gets exactly the buffering it always had. See
    // sdram-capture-buffer.md for the design.
    wire         buffer_write;
    wire [ 15:0] buffer_data;
    wire [ 14:0] buffer_used_words;
    wire         sdram_sample_lost;

    wire [ 15:0] sdram_dq_out;
    wire         sdram_dq_oe;
    wire [ 15:0] sdram_dq_in;


    sdramBuffer sdram_buffer_0 (
        // Inputs
        .reset_n          (reset_n),             // Not reset, system clock domain
        .clock            (system_clock),        // 80 MHz system clock
        .collect_data     (fx3_collect_data),    // 1 = the FX3 is capturing
        .sample_strobe    (capture_enable),      // 1 = a sample is offered this edge
        .sample_data      (data_generator_out),  // 16-bit sample
        .buffer_used_words(buffer_used_words),   // The FIFO buffer's occupancy
        .sdram_reset_n    (sdram_reset_n),       // Not reset, SDRAM clock domain
        .sdram_clock      (sdram_clock),         // 120 MHz SDRAM controller clock
        .sdram_dq_in      (sdram_dq_in),         // SDRAM data in

        // Outputs
        .buffer_write(buffer_write),       // 1 = a word is written to the FIFO buffer
        .buffer_data (buffer_data),        // and this is it
        .sample_lost (sdram_sample_lost),  // 1 = the offered sample was dropped
        .status      (sdram_status),       // For the stream
        .sdram_cke   (DRAM_CKE),
        .sdram_cs_n  (DRAM_CS_N),
        .sdram_ras_n (DRAM_RAS_N),
        .sdram_cas_n (DRAM_CAS_N),
        .sdram_we_n  (DRAM_WE_N),
        .sdram_ba    (DRAM_BA),
        .sdram_addr  (DRAM_ADDR),
        .sdram_dqm   (DRAM_DQM),
        .sdram_dq_out(sdram_dq_out),
        .sdram_dq_oe (sdram_dq_oe)
    );

    // The SDRAM data bus, driven only while the controller is writing. Both
    // registers behind this are in the pins' I/O cells (the .qsf), as is the
    // input register in the controller.
    assign DRAM_DQ     = sdram_dq_oe ? sdram_dq_out : {16{1'bZ}};
    assign sdram_dq_in = DRAM_DQ;

    // The SDRAM's clock is the PLL's leading 120 MHz output, driven onto the
    // pin directly
    assign DRAM_CLK    = sdram_pin_clock;

    // FIFO buffer
    buffer buffer_0 (
        // Inputs
        .reset_n        (reset_n),                // Not reset
        .clock          (system_clock),           // 80 MHz system clock
        .write_enable   (buffer_write),           // 1 = a word is written this edge
        .data_in        (buffer_data),            // 16-bit word
        .sample_offered (capture_enable),         // 1 = a sample left the sampling side
        .sample_lost    (sdram_sample_lost),      // 1 = and was lost before it got here
        .is_reading     (fx3_is_reading),         // 1 = FX3 is reading data
        .telemetry_latch(buffer_telemetry_latch), // 1 = sample the instrument

        // Outputs
        .data_out          (fx3_databus),               // 16-bit data output
        .data_available    (fx3_data_available),        // Set if a whole packet is queued
        .buffer_error      (fx3_buffer_error),          // Set if a sample had to be dropped
        .used_words        (buffer_used_words),         // Occupancy, for the SDRAM path
        .telemetry         (buffer_telemetry),          // The instrument's shadow bank
        .telemetry_geometry(buffer_telemetry_geometry)  // and the constants to read it by
    );

    // FX3 GPIF state-machine logic
    fx3StateMachine fx3_state_machine_0 (
        // Inputs
        .reset_n  (reset_n),       // Not reset
        .fx3_clock(system_clock),  // 80 MHz system clock
        .read_data(fx3_read_data), // FX3 is about to start sampling the databus

        // Output
        .fx3_is_reading(fx3_is_reading)  // Flag to indicate FX3 is sampling the databus
    );

    // SPI register bank
    //
    // The build stamp comes from version.vh, which fpga/generate-version.sh
    // writes into the build directory. The copy committed beside the sources
    // reports no commit, which is the honest answer for a lint or simulation run
    // and for anyone who compiles without running the generator first.
    wire        window_write;
    wire [ 1:0] window_address;
    wire [ 7:0] window_write_data;
    wire [31:0] window_read_data;
    wire        transaction_decoded;

    spiRegisters #(
        .CommitText(`GATEWARE_COMMIT_TEXT),
        .BuildFlags(`GATEWARE_BUILD_FLAGS),

        // This is the capture gateware, which is what a host reads out of
        // IMAGE_ROLE to know it is not looking at a unit in recovery
        .ImageRole(8'h01),

        // and the image that has a capture buffer to report on
        .TelemetryPresent(1'b1),

        // and the only image with a sample stream to decimate
        .DecimationPresent(1'b1)
    ) spi_registers_0 (
        // Inputs
        .reset_n           (reset_n),
        .clock             (system_clock),
        .spi_clock         (fx3_spi_clock),
        .spi_mosi          (fx3_spi_mosi),
        .spi_chip_select_n (fx3_spi_chip_select_n),
        .window_read_data  (window_read_data),
        .diagnostics       (remote_update_diagnostics),
        .telemetry         (buffer_telemetry),
        .telemetry_geometry(buffer_telemetry_geometry),

        // Outputs
        .spi_miso           (fx3_spi_miso),
        .test_mode          (fx3_test_mode),          // 1 = test data generator selected
        .decimation         (fx3_decimation),         // Samples kept out of every n
        .leds               (LED),                    // Driven by the FX3, for status
        .window_write       (window_write),
        .window_address     (window_address),
        .window_write_data  (window_write_data),
        .transaction_decoded(transaction_decoded),
        .telemetry_latch    (buffer_telemetry_latch)
    );

    // Flash bridge and reconfiguration control
    //
    // The capture gateware carries these so that a gateware update is done from
    // the running application image rather than from the recovery one: the
    // factory image is for when something has gone wrong, and an update is not
    // that. Everything here is inert until the FX3 unlocks it.
    wire [7:0] bridge_unlock_read;
    wire [7:0] bridge_control_read;
    wire [7:0] bridge_data_read;
    wire [7:0] reconfiguration_read;

    wire       flash_clock;
    wire       flash_chip_select_n;
    wire       flash_data_out;
    wire       flash_data_in;
    wire       flash_drive;

    assign window_read_data = {
        reconfiguration_read, bridge_data_read, bridge_control_read, bridge_unlock_read
    };

    flashBridge flash_bridge_0 (
        // Inputs
        .reset_n          (reset_n),
        .clock            (system_clock),
        .window_write     (window_write),
        .window_address   (window_address),
        .window_write_data(window_write_data),
        .flash_data_in    (flash_data_in),

        // Outputs
        .unlock_read        (bridge_unlock_read),
        .control_read       (bridge_control_read),
        .data_read          (bridge_data_read),
        .flash_clock        (flash_clock),
        .flash_chip_select_n(flash_chip_select_n),
        .flash_data_out     (flash_data_out),
        .flash_drive        (flash_drive)
    );

    asmiBlock asmi_block_0 (
        // Inputs
        .dclk           (flash_clock),
        .chip_select_n  (flash_chip_select_n),
        .serial_data_out(flash_data_out),
        .output_enable  (flash_drive),

        // Output
        .serial_data_in(flash_data_in)
    );

    // The watchdog the factory image armed before it handed over is tickled by
    // transaction_decoded, so this image proves its fabric is alive rather than
    // merely proving it configured - which the configuration CRC already did.
    // A host reconfiguration request through this block returns the device to
    // the factory image, which then makes the boot decision again.
    // BENCH DIAGNOSTIC. The remote update block's account of itself,
    // carried to the register bank and presented read-only at 0x30.
    wire [63:0] remote_update_diagnostics;

    remoteUpdate remote_update_0 (
        // Inputs
        .reset_n            (reset_n),
        .clock              (system_clock),
        .window_write       (window_write && (window_address == 2'd3)),
        .window_write_data  (window_write_data),
        .transaction_decoded(transaction_decoded),
        .arm_request        (1'b0),
        .boot_address       (24'd0),
        .reconfigure_request(1'b0),

        // Outputs
        .control_read(reconfiguration_read),
        .diagnostics (remote_update_diagnostics)
    );

endmodule
