/************************************************************************

    tb_audioCapture.v

    Testbench for the audio path end to end (T3)
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    The capture path from the decimator to the sample stream, wired as the
    top level wires it - halfBandDecimator, dataGenerator in the framed
    format, adc128spiController and pcm1802Slave - against models of the
    two converters that check their datasheets' timing on every edge, with
    a 10 ns pin-and-board delay each way. The stream is decoded the way a
    host decodes it.

    What this adds to the three testbenches below it is the phase lock.
    Both converters are timed from the generator's frame slot, so their
    samples cannot drift against the frames that carry them, and the
    relationship is checked as a fixed one rather than merely a working
    one:

      - every frame N carries in its header exactly what the converters
        produced during frame N - 1: the two conversions the ADC128S022
        made in it, IN0 then IN1, and the PCM1802 words sent in the LRCK
        period that began on its first slot
      - when frame N's header is loaded the ADC128S022 has made exactly
        2N + 1 conversions and the PCM1802 has sent exactly N + 1 LRCK
        periods - never one more or one fewer, at either rate

    Two lanes run side by side: one at the full rate and one decimating
    from reset, each a complete copy of the path.

    The first frames after reset carry what reset left: frame 0 carries
    zeros, and frame 1's ADC128S022 pair is the documented first conversion
    of whichever input the converter was last set to. Those are not
    compared.

************************************************************************/

`timescale 1ns / 1ps

module tb_audioCapture;

    localparam integer LANES = 2;
    localparam integer FRAMES = 10;
    localparam integer FRAME = 512;

    // FPGA pin, board and converter pin, each way
    localparam real PIN_DELAY = 10.0;

    reg            reset_n;
    reg            clock;
    integer        errors;

    // The ADC128S022's two inputs, moving at rates that share nothing with
    // the frame
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
        in0 = 12'h800;
        in1 = 12'h7FF;
    end
    always begin
        #271 in0 = in0 + 12'd53;
    end
    always begin
        #193 in1 = in1 - 12'd29;
    end

    // The sampling enable, built as the top level builds it
    reg adc_clock_divider;
    initial begin
        adc_clock_divider = 1'b0;
    end
    always @(posedge clock) begin
        adc_clock_divider <= ~adc_clock_divider;
    end

    wire sample_enable = ~adc_clock_divider;

    task fail;
        input integer lane;
        input integer frame;
        input [511:0] what;
        begin
            $display("FAIL: lane %0d frame %0d: %0s", lane, frame, what);
            errors = errors + 1;
        end
    endtask

    genvar lane;

    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : gen_lanes
            wire        capture_enable;
            wire [ 9:0] capture_sample;
            wire [15:0] data_out;
            wire [ 8:0] frame_position;

            wire [11:0] adc128_left;
            wire [11:0] adc128_right;
            wire [23:0] pcm1802_left;
            wire [23:0] pcm1802_right;

            wire        adc128_chip_select_n;
            wire        adc128_serial_clock;
            wire        adc128_din;
            wire        adc128_dout;
            wire        adc128_chip_select_n_pin;
            wire        adc128_serial_clock_pin;
            wire        adc128_din_pin;
            wire        adc128_dout_pin;

            wire        pcm1802_scki;
            wire        pcm1802_bck;
            wire        pcm1802_lrck;
            wire        pcm1802_dout;
            wire        pcm1802_scki_pin;
            wire        pcm1802_bck_pin;
            wire        pcm1802_lrck_pin;
            wire        pcm1802_dout_pin;

            halfBandDecimator decimator (
                .reset_n      (reset_n),
                .clock        (clock),
                .sample_enable(sample_enable),
                .data_in      (10'd0),
                .decimate     (lane == 1),
                .data_out     (capture_sample),
                .output_enable(capture_enable)
            );

            dataGenerator #(
                .FramedFormat(1'b1)
            ) generator (
                .reset_n       (reset_n),
                .clock         (clock),
                .sample_enable (capture_enable),
                .adc_databus   (capture_sample),
                .test_mode_flag(1'b1),
                .adc128_left   (adc128_left),
                .adc128_right  (adc128_right),
                .pcm1802_left  (pcm1802_left),
                .pcm1802_right (pcm1802_right),
                .data_out      (data_out),
                .frame_position(frame_position)
            );

            adc128spiController adc128 (
                .reset_n          (reset_n),
                .clock            (clock),
                .sample_enable    (capture_enable),
                .frame_position   (frame_position),
                .adc_dout         (adc128_dout),
                .adc_chip_select_n(adc128_chip_select_n),
                .adc_serial_clock (adc128_serial_clock),
                .adc_din          (adc128_din),
                .audio_left       (adc128_left),
                .audio_right      (adc128_right)
            );

            pcm1802Slave pcm1802 (
                .reset_n       (reset_n),
                .clock         (clock),
                .sample_enable (capture_enable),
                .frame_position(frame_position),
                .pcm_dout      (pcm1802_dout),
                .pcm_scki      (pcm1802_scki),
                .pcm_bck       (pcm1802_bck),
                .pcm_lrck      (pcm1802_lrck),
                .audio_left    (pcm1802_left),
                .audio_right   (pcm1802_right)
            );

            assign #(PIN_DELAY) adc128_chip_select_n_pin = adc128_chip_select_n;
            assign #(PIN_DELAY) adc128_serial_clock_pin  = adc128_serial_clock;
            assign #(PIN_DELAY) adc128_din_pin           = adc128_din;
            assign #(PIN_DELAY) adc128_dout              = adc128_dout_pin;

            assign #(PIN_DELAY) pcm1802_scki_pin         = pcm1802_scki;
            assign #(PIN_DELAY) pcm1802_bck_pin          = pcm1802_bck;
            assign #(PIN_DELAY) pcm1802_lrck_pin         = pcm1802_lrck;
            assign #(PIN_DELAY) pcm1802_dout             = pcm1802_dout_pin;

            adc128s022Model adc128_converter (
                .chip_select_n(adc128_chip_select_n_pin),
                .serial_clock (adc128_serial_clock_pin),
                .din          (adc128_din_pin),
                .in0          (in0),
                .in1          (in1),
                .dout         (adc128_dout_pin)
            );

            pcm1802Model pcm1802_converter (
                .scki(pcm1802_scki_pin),
                .bck (pcm1802_bck_pin),
                .lrck(pcm1802_lrck_pin),
                .dout(pcm1802_dout_pin)
            );

            // The host's view: a running word count, and the header chunks
            // of the frame in progress
            integer        words;
            integer        frame;
            integer        slot;
            integer        newest;
            reg     [47:0] header;
            reg     [11:0] expected_adc128_left;
            reg     [11:0] expected_adc128_right;
            reg     [23:0] expected_pcm1802_left;
            reg     [23:0] expected_pcm1802_right;

            initial begin
                words = 0;
                frame = 0;
            end

            always @(posedge clock) begin
                if (reset_n && capture_enable) begin
                    frame = words / FRAME;
                    slot  = words % FRAME;

                    if (frame_position !== slot) begin
                        fail(lane, frame, "frame_position does not match the word's slot");
                    end

                    // The header's audio, most significant chunk first. The
                    // last eight slots taken are what the register holds, so
                    // at slot 35 its low 24 bits are slots 32 to 35, and at
                    // slot 45 all 48 are slots 38 to 45.
                    if ((slot >= 32) && (slot <= 45)) begin
                        header = {header[41:0], data_out[15:10]};
                    end

                    if (slot == 45) begin
                        if ((frame >= 1) && ({header[47:24], header[23:0]} !==
                                             {expected_pcm1802_left, expected_pcm1802_right})) begin
                            fail(lane, frame, "the PCM1802 pair is not the one sent a frame ago");
                        end
                    end

                    if (slot == 35) begin
                        if ((frame >= 2) && ({header[23:12], header[11:0]} !==
                                             {expected_adc128_left, expected_adc128_right})) begin
                            fail(lane, frame,
                                 "the ADC128S022 pair is not the one held a frame ago");
                        end
                    end

                    // The edge that loads the next frame's slot 0, and so its
                    // audio. What the converters have done by now is fixed.
                    if (slot == (FRAME - 1)) begin
                        newest = adc128_converter.conversions - 1;
                        if (adc128_converter.conversions != (2 * frame) + 1) begin
                            fail(lane, frame, "the ADC128S022 is not 2N + 1 conversions in");
                        end else if (frame >= 1) begin
                            if ((adc128_converter.log_channel[newest-1] != 3'd0) ||
                                (adc128_converter.log_channel[newest] != 3'd1)) begin
                                fail(lane, frame,
                                     "the ADC128S022 did not convert IN0 and then IN1");
                            end
                            expected_adc128_left  = adc128_converter.log_value[newest-1];
                            expected_adc128_right = adc128_converter.log_value[newest];
                        end

                        if (pcm1802_converter.periods != frame + 1) begin
                            fail(lane, frame, "the PCM1802 is not N + 1 LRCK periods in");
                        end else begin
                            expected_pcm1802_left =
                                pcm1802_converter.log_left[pcm1802_converter.periods-1];
                            expected_pcm1802_right =
                                pcm1802_converter.log_right[pcm1802_converter.periods-1];
                        end
                    end

                    words = words + 1;
                end
            end
        end
    endgenerate

    initial begin
        errors  = 0;
        reset_n = 1'b0;

        @(posedge clock);
        #1 reset_n = 1'b1;

        // Run until the decimating lane has recorded enough frames
        while (gen_lanes[1].words < (FRAMES * FRAME)) begin
            @(negedge clock);
        end

        errors = errors + gen_lanes[0].adc128_converter.errors +
            gen_lanes[0].pcm1802_converter.errors + gen_lanes[1].adc128_converter.errors +
            gen_lanes[1].pcm1802_converter.errors;

        if (errors == 0) begin
            $display("tb_audioCapture: PASS");
        end else begin
            $display("tb_audioCapture: FAIL (%0d errors)", errors);
        end

        if (errors != 0) begin
            $fatal(1, "tb_audioCapture failed");
        end
        $finish;
    end

endmodule
