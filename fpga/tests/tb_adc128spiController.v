/************************************************************************

    tb_adc128spiController.v

    Testbench for the ADC128S022 audio capture (T3)
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    The controller against a model of the converter that checks the
    datasheet's interface timing on every edge (adc128s022Model.v), with a
    10 ns pin-and-board delay each way so that the capture margin argued in
    adc128spiController.v is exercised rather than assumed. Two lanes run
    side by side, each with its own controller and converter:

      0  the full rate, 40 Msps
      1  decimating, 20 Msps

    Each lane's enable comes from its own halfBandDecimator, as the capture
    enable does in the top level.

    In each lane:

      - the converter's own checks all pass: sixteen rising edges in every
        frame, CS set-up and hold, DIN set-up and hold, SCLK frequency and
        duty, and the conversion rate
      - every frame converts IN0 and then IN1, the order that the control
        word each conversion sends sets up for the next
      - every frame publishes the two codes the converter held in that
        frame, IN0 as left and IN1 as right, and publishes nothing anywhere
        but at its fixed slot
      - SCLK is 2.5 MHz at the full rate and 1.25 MHz decimating, and a
        conversion starts every 6.4 us and 12.8 us respectively

    The inputs move continuously, at rates unrelated to the frame, so that
    a code taken from the wrong conversion, or a pair split across two
    frames, cannot match by accident.

    The first frame after reset is not checked. Its IN0 slot has no
    conversion - CS stays high until the first proper place for it to fall
    - and its IN1 slot converts whichever input the converter was last set
    to, which is the documented behaviour, not a fault.

************************************************************************/

`timescale 1ns / 1ps

module tb_adc128spiController;

    localparam integer LANES = 2;
    localparam integer FRAMES = 12;

    // The first slot on which a newly published pair can be seen - it is
    // published with the sample in slot 504 - and the slot it is checked on,
    // by which time the converter has closed the frame that converted IN1 and
    // logged what it held
    localparam integer SEEN_SLOT = 505;
    localparam integer CHECK_SLOT = 511;

    // FPGA pin, board and converter pin, each way
    localparam real PIN_DELAY = 10.0;

    reg            reset_n;
    reg            clock;
    integer        errors;

    // The two inputs, as the codes they would convert to, moving at rates
    // that share nothing with the frame
    reg     [11:0] in0;
    reg     [11:0] in1;

    // 80 MHz system clock
    initial begin
        clock = 1'b0;
    end
    always begin
        #6.25 clock = ~clock;
    end

    initial begin
        in0 = 12'h000;
        in1 = 12'hFFF;
    end
    always begin
        #317 in0 = in0 + 12'd37;
    end
    always begin
        #229 in1 = in1 - 12'd91;
    end

    // The sampling enable, built as the top level builds it
    reg adc_clock_divider;
    initial begin
        adc_clock_divider = 1'b0;
    end
    always @(posedge clock) begin
        adc_clock_divider <= ~adc_clock_divider;
    end

    wire adc_sample_enable = ~adc_clock_divider;

    task fail;
        input integer lane;
        input [511:0] what;
        begin
            $display("FAIL: lane %0d: %0s (t=%0t)", lane, what, $realtime);
            errors = errors + 1;
        end
    endtask

    genvar lane;

    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : gen_lanes
            // The SCLK period, and the time from one conversion to the next,
            // that each rate should give
            localparam real SCLK_PERIOD = (lane == 0) ? 400.0 : 800.0;
            localparam real CONVERSION_PERIOD = (lane == 0) ? 6400.0 : 12800.0;

            reg      [ 8:0] frame_position;
            wire            sample_enable;
            wire     [ 9:0] unused_sample;

            wire            chip_select_n;
            wire            serial_clock;
            wire            din;
            wire            dout;
            wire     [11:0] audio_left;
            wire     [11:0] audio_right;

            wire            chip_select_n_pin;
            wire            serial_clock_pin;
            wire            din_pin;
            wire            dout_pin;

            integer         frames_seen;
            integer         frames_checked;
            integer         conversions_before;
            integer         newest;
            realtime        last_sclk_fall;
            realtime        last_chip_select_fall;

            // The capture enable, from the decimator the capture path has
            halfBandDecimator decimator (
                .reset_n      (reset_n),
                .clock        (clock),
                .sample_enable(adc_sample_enable),
                .data_in      (10'd0),
                .decimate     (lane == 1),
                .data_out     (unused_sample),
                .output_enable(sample_enable)
            );

            // The frame slot of the sample taken on each enable, as
            // dataGenerator reports it
            always @(posedge clock, negedge reset_n) begin
                if (!reset_n) begin
                    frame_position <= 9'd0;
                end else if (sample_enable) begin
                    frame_position <= frame_position + 9'd1;
                end
            end

            adc128spiController dut (
                .reset_n          (reset_n),
                .clock            (clock),
                .sample_enable    (sample_enable),
                .frame_position   (frame_position),
                .adc_dout         (dout),
                .adc_chip_select_n(chip_select_n),
                .adc_serial_clock (serial_clock),
                .adc_din          (din),
                .audio_left       (audio_left),
                .audio_right      (audio_right)
            );

            assign #(PIN_DELAY) chip_select_n_pin = chip_select_n;
            assign #(PIN_DELAY) serial_clock_pin  = serial_clock;
            assign #(PIN_DELAY) din_pin           = din;
            assign #(PIN_DELAY) dout              = dout_pin;

            adc128s022Model converter (
                .chip_select_n(chip_select_n_pin),
                .serial_clock (serial_clock_pin),
                .din          (din_pin),
                .in0          (in0),
                .in1          (in1),
                .dout         (dout_pin)
            );

            initial begin
                frames_seen           = 0;
                frames_checked        = 0;
                conversions_before    = 0;
                last_sclk_fall        = -1.0;
                last_chip_select_fall = -1.0;
            end

            // The pair, checked once the converter has logged both of this
            // frame's conversions; the frame before it left the count where
            // it was.
            always @(posedge clock) begin
                if (reset_n && sample_enable && (frame_position == CHECK_SLOT)) begin
                    newest = converter.conversions - 1;
                    if (frames_seen > 0) begin
                        if (converter.conversions != conversions_before + 2) begin
                            fail(lane, "a frame did not hold exactly two conversions");
                        end else if ((converter.log_channel[newest-1] != 3'd0) ||
                                     (converter.log_channel[newest] != 3'd1)) begin
                            fail(lane, "a frame did not convert IN0 and then IN1");
                        end else if ((audio_left !== converter.log_value[newest-1]) ||
                                     (audio_right !== converter.log_value[newest])) begin
                            $display("lane %0d: got %h %h, held %h %h", lane, audio_left,
                                     audio_right, converter.log_value[newest-1],
                                     converter.log_value[newest]);
                            fail(lane, "the published pair is not the pair the converter held");
                        end
                        frames_checked = frames_checked + 1;
                    end
                    conversions_before = converter.conversions;
                    frames_seen        = frames_seen + 1;
                end
            end

            // Nothing is published but at the publishing slot, which is seen
            // as the slot after it. Looked at a nanosecond later, so that the
            // slot counter's update on the same edge has certainly landed.
            always @(audio_left or audio_right) begin
                #1;
                if (reset_n && (frame_position != SEEN_SLOT)) begin
                    fail(lane, "the outputs changed away from the publishing slot");
                end
            end

            // SCLK's period, and the time from one conversion to the next
            always @(negedge serial_clock_pin) begin
                if (last_sclk_fall > 0.0) begin
                    if (($realtime - last_sclk_fall) != SCLK_PERIOD) begin
                        fail(lane, "SCLK is not 2.5 MHz at the full rate, 1.25 MHz decimating");
                    end
                end
                last_sclk_fall = $realtime;
            end

            always @(negedge chip_select_n_pin) begin
                if (last_chip_select_fall > 0.0) begin
                    if (($realtime - last_chip_select_fall) != CONVERSION_PERIOD) begin
                        fail(lane, "conversions are not two to a frame");
                    end
                end
                last_chip_select_fall = $realtime;
            end
        end
    endgenerate

    initial begin
        errors  = 0;
        reset_n = 1'b0;

        @(posedge clock);
        #1 reset_n = 1'b1;

        // Run until the slower lane has finished
        while (gen_lanes[1].frames_checked < FRAMES) begin
            @(negedge clock);
        end

        if (gen_lanes[0].frames_checked < FRAMES) begin
            fail(0, "too few frames checked");
        end

        errors = errors + gen_lanes[0].converter.errors + gen_lanes[1].converter.errors;

        if (errors == 0) begin
            $display("tb_adc128spiController: PASS");
        end else begin
            $display("tb_adc128spiController: FAIL (%0d errors)", errors);
        end

        if (errors != 0) begin
            $fatal(1, "tb_adc128spiController failed");
        end
        $finish;
    end

endmodule
