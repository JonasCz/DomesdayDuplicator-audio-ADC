/************************************************************************

    tb_pcm1802Slave.v

    Testbench for the PCM1802 audio capture (T3)
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    The controller against a model of the converter that checks the
    datasheet's interface timing on every edge (pcm1802Model.v), with a
    10 ns pin-and-board delay each way so that the capture margin argued in
    pcm1802Slave.v is exercised rather than assumed. Three lanes run side
    by side, each with its own controller and converter:

      0  the full rate, 40 Msps
      1  decimating, 20 Msps
      2  switched from the first rate to the second and back mid-frame, as
         a change of DECIMATION during a capture would

    Each lane's enable comes from its own halfBandDecimator, as the capture
    enable does in the top level, so the change of rate in lane 2 produces
    the irregular intervals a real one does - one of them a single system
    clock.

    In each lane:

      - the converter's own checks all pass: SCKI, BCK and LRCK pulse
        widths, LRCK set-up and hold, exactly 256 SCKI and 64 BCK cycles per
        LRCK period, and a sampling rate inside 16 to 96 kHz
      - every frame publishes the left and right words the converter sent in
        that frame's LRCK period - the left one while LRCK was high - and
        publishes nothing anywhere but at its fixed slot
      - LRCK's period is one frame: 12.8 us, 78.125 kHz, at the full rate
        and 25.6 us, 39.0625 kHz, decimating

************************************************************************/

`timescale 1ns / 1ps

module tb_pcm1802Slave;

    localparam integer LANES = 3;
    localparam integer FRAMES = 12;

    // The slot whose sample publishes the pair, and the one after it, which
    // is the first on which the new pair can be seen
    localparam integer PUBLISH_SLOT = 444;
    localparam integer SEEN_SLOT = PUBLISH_SLOT + 1;

    // FPGA pin, board and converter pin, each way
    localparam real PIN_DELAY = 10.0;

    // One frame of samples at each rate, in nanoseconds
    localparam real FULL_RATE_FRAME = 12800.0;
    localparam real DECIMATED_FRAME = 25600.0;

    reg                 reset_n;
    reg                 clock;
    integer             errors;

    // Whether each lane's decimator is halving the rate
    reg     [LANES-1:0] decimate;

    // 80 MHz system clock
    initial begin
        clock = 1'b0;
    end
    always begin
        #6.25 clock = ~clock;
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
            reg      [ 8:0] frame_position;
            wire            sample_enable;
            wire     [ 9:0] unused_sample;

            wire            scki;
            wire            bck;
            wire            lrck;
            wire            dout;
            wire     [23:0] audio_left;
            wire     [23:0] audio_right;

            wire            scki_pin;
            wire            bck_pin;
            wire            lrck_pin;
            wire            dout_pin;

            integer         frames_checked;
            realtime        last_lrck_rise;

            // The capture enable, from the decimator the capture path has,
            // so that a change of rate produces the intervals a real one does
            halfBandDecimator decimator (
                .reset_n      (reset_n),
                .clock        (clock),
                .sample_enable(adc_sample_enable),
                .data_in      (10'd0),
                .decimate     (decimate[lane]),
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

            pcm1802Slave dut (
                .reset_n       (reset_n),
                .clock         (clock),
                .sample_enable (sample_enable),
                .frame_position(frame_position),
                .pcm_dout      (dout),
                .pcm_scki      (scki),
                .pcm_bck       (bck),
                .pcm_lrck      (lrck),
                .audio_left    (audio_left),
                .audio_right   (audio_right)
            );

            assign #(PIN_DELAY) scki_pin = scki;
            assign #(PIN_DELAY) bck_pin  = bck;
            assign #(PIN_DELAY) lrck_pin = lrck;
            assign #(PIN_DELAY) dout     = dout_pin;

            pcm1802Model converter (
                .scki(scki_pin),
                .bck (bck_pin),
                .lrck(lrck_pin),
                .dout(dout_pin)
            );

            initial begin
                frames_checked = 0;
                last_lrck_rise = -1.0;
            end

            // The pair, checked on the first sample it can be seen on. The
            // converter's newest LRCK period is the one this frame opened.
            always @(posedge clock) begin
                if (reset_n && sample_enable && (frame_position == SEEN_SLOT)) begin
                    if (converter.periods < 1) begin
                        fail(lane, "the converter has not sent a word");
                    end else if ((audio_left !== converter.log_left[converter.periods-1]) ||
                                 (audio_right !== converter.log_right[converter.periods-1])) begin
                        $display("lane %0d: got %h %h, sent %h %h", lane, audio_left, audio_right,
                                 converter.log_left[converter.periods-1],
                                 converter.log_right[converter.periods-1]);
                        fail(lane, "the published pair is not the pair the converter sent");
                    end
                    frames_checked = frames_checked + 1;
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

            // LRCK's period, which at a steady rate is exactly one frame
            always @(posedge lrck_pin) begin
                if ((last_lrck_rise > 0.0) && (lane != 2)) begin
                    if (($realtime - last_lrck_rise) !=
                        ((lane == 0) ? FULL_RATE_FRAME : DECIMATED_FRAME)) begin
                        fail(lane, "LRCK's period is not one frame");
                    end
                end
                last_lrck_rise = $realtime;
            end
        end
    endgenerate

    // Wait for a lane to reach a given slot of a given frame
    task wait_for_slot;
        input integer frame;
        input integer slot;
        begin
            while ((gen_lanes[2].converter.periods < frame) ||
                   (gen_lanes[2].frame_position != slot)) begin
                @(negedge clock);
            end
        end
    endtask

    initial begin
        errors   = 0;
        decimate = 3'b010;
        reset_n  = 1'b0;

        @(posedge clock);
        #1 reset_n = 1'b1;

        // Lane 2: to the decimated rate in the middle of a frame's right
        // half, and back in the middle of a left half
        wait_for_slot(3, 300);
        decimate[2] = 1'b1;
        wait_for_slot(6, 77);
        decimate[2] = 1'b0;

        // Run until the slowest lane has finished
        while (gen_lanes[1].frames_checked < FRAMES) begin
            @(negedge clock);
        end

        if (gen_lanes[0].frames_checked < FRAMES) begin
            fail(0, "too few frames checked");
        end
        if (gen_lanes[2].frames_checked < FRAMES) begin
            fail(2, "too few frames checked");
        end

        errors = errors + gen_lanes[0].converter.errors + gen_lanes[1].converter.errors +
            gen_lanes[2].converter.errors;

        if (errors == 0) begin
            $display("tb_pcm1802Slave: PASS");
        end else begin
            $display("tb_pcm1802Slave: FAIL (%0d errors)", errors);
        end

        if (errors != 0) begin
            $fatal(1, "tb_pcm1802Slave failed");
        end
        $finish;
    end

endmodule
