/************************************************************************

    tb_dataGeneratorFramed.v

    Testbench for the framed sample format (T3)
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    dataGenerator built as the application builds it, with FramedFormat set,
    behind the real decimator so that the enable it counts is the one the
    capture path has. Every word the buffer would take is recorded, and the
    whole record is then decoded the way a host decodes it - without
    reference to the generator's own constants - and checked against
    framed-sample-format.md:

      - the first word after reset is slot 0, every frame is 512 words, and
        frame_position agrees with the slot of every word
      - slots 0 to 31 carry the sync pattern bit for bit, read as the four
        48-bit values the fork's host decoder compares against
      - slots 32 to 35 the ADC128S022 pair and 38 to 45 the PCM1802 pair,
        most significant chunk first, and 36, 37, 46 and 47 the status word,
        S[23:18], S[17:12], S[11:6] and S[5:0], bit for bit
      - slots 48 to 511 carry 58 counter values per frame, least significant
        chunk first, each one more than the last, unbroken from one frame to
        the next and through a wrap of all 48 bits
      - bits 9:0 are the test ramp, unbroken across every frame and through
        both changes of rate

    Coherency. The audio inputs and the status word here are not the
    converters or the SDRAM path: they change every seven system clocks,
    several times while each frame's header is being emitted, and every
    value of them is one consistent set derived from a version number. A
    frame whose header mixed two versions - the fork's latch-on-arrival
    would - decodes to a set that no version produces, and a frame that
    carries a different version from the one present when slot 0 was loaded
    is reported too. The status word is derived through a multiplicative
    hash, so that every one of its 24 bits changes from version to version
    and a slot carrying the wrong six bits, or the right bits of the wrong
    version, cannot match by accident.

    Cadence. The rate starts at the full 40 Msps, is switched to decimating
    in the middle of a frame, and back again in the middle of another. The
    enable the decimator produces is measured: exactly every second system
    clock at the full rate and every fourth when decimating, with the few
    enables either side of a change excluded and listed. The frame stream
    is checked across both changes, because the frame counts samples.

************************************************************************/

`timescale 1ns / 1ps

module tb_dataGeneratorFramed;

    localparam integer FRAME = 512;
    localparam integer MAX_WORDS = 16384;
    localparam integer RAMP_LENGTH = 1021;
    localparam integer COUNTER_VALUES = 58;

    // The sync pattern as the fork's host decoder holds it: four values,
    // each assembled from eight consecutive slots, least significant first
    localparam [47:0] SYNC_0 = 48'hFEDCBA987654;
    localparam [47:0] SYNC_1 = 48'hDDDF20251016;
    localparam [47:0] SYNC_2 = 48'hDDDF20251015;
    localparam [47:0] SYNC_3 = 48'hDDDF20251015;

    // A value deposited into the counter, so that one frame wraps all 48 bits
    localparam [47:0] NEAR_WRAP = 48'hFFFF_FFFF_FFE2;

    // Enables either side of a change of rate that the cadence check
    // excludes. The decimator's pipeline is seven clocks deep.
    localparam integer SETTLE = 8;

    reg            reset_n;
    reg            clock;
    reg            decimate;
    reg     [ 9:0] adc_databus;
    reg     [11:0] adc128_left;
    reg     [11:0] adc128_right;
    reg     [23:0] pcm1802_left;
    reg     [23:0] pcm1802_right;
    reg     [23:0] status_word;

    wire           capture_enable;
    wire    [ 9:0] capture_sample;
    wire    [15:0] data_out;
    wire    [ 8:0] frame_position;

    integer        errors;
    integer        version;
    integer        words;
    integer        cycles;
    integer        i;
    integer        j;
    integer        k;
    integer        frame;
    integer        base;
    integer        deposit_frame;
    integer        switch_word      [          0:1];

    // The record: each word, the slot dataGenerator said it was, the audio
    // version present when it was taken, and the clock it was taken on
    reg     [15:0] word_data        [0:MAX_WORDS-1];
    reg     [ 8:0] word_position    [0:MAX_WORDS-1];
    integer        word_version     [0:MAX_WORDS-1];
    integer        word_cycle       [0:MAX_WORDS-1];

    reg     [47:0] value;
    reg     [47:0] expected_counter;
    reg     [11:0] got_adc_left;
    reg     [11:0] got_adc_right;
    reg     [23:0] got_pcm_left;
    reg     [23:0] got_pcm_right;
    reg     [23:0] got_status;
    integer        got_version;
    integer        interval;

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

    wire sample_enable = ~adc_clock_divider;

    halfBandDecimator decimator (
        .reset_n      (reset_n),
        .clock        (clock),
        .sample_enable(sample_enable),
        .data_in      (adc_databus),
        .decimate     (decimate),
        .data_out     (capture_sample),
        .output_enable(capture_enable)
    );

    dataGenerator #(
        .FramedFormat(1'b1)
    ) dut (
        .reset_n       (reset_n),
        .clock         (clock),
        .sample_enable (capture_enable),
        .adc_databus   (capture_sample),
        .test_mode_flag(1'b1),
        .adc128_left   (adc128_left),
        .adc128_right  (adc128_right),
        .pcm1802_left  (pcm1802_left),
        .pcm1802_right (pcm1802_right),
        .status_word   (status_word),
        .data_out      (data_out),
        .frame_position(frame_position)
    );

    // The status word for a version: every bit depends on it
    function [23:0] status_of;
        input [11:0] n;
        reg [35:0] product;
        begin
            product   = {24'd0, n} * 36'h0A3_C59;
            status_of = product[23:0] ^ {n, n};
        end
    endfunction

    // One consistent set of audio inputs and status per version, every field
    // derived from the same number so that a mixture of two is recognisable
    task set_audio;
        input integer v;
        reg [11:0] n;
        begin
            n             = v[11:0];
            adc128_left   = n;
            adc128_right  = n ^ 12'hA5A;
            pcm1802_left  = {n, ~n};
            pcm1802_right = {n ^ 12'h3C3, n};
            status_word   = status_of(n);
        end
    endtask

    task fail;
        input [511:0] what;
        begin
            $display("FAIL: frame %0d: %0s", frame, what);
            errors = errors + 1;
        end
    endtask

    // The six metadata bits of a recorded word
    function [5:0] top;
        input integer w;
        begin
            top = word_data[w][15:10];
        end
    endfunction

    // A value spread over n consecutive slots, least significant chunk first
    function [47:0] gather_lsb_first;
        input integer w;
        input integer n;
        integer s;
        begin
            gather_lsb_first = 48'd0;
            for (s = n - 1; s >= 0; s = s - 1) begin
                gather_lsb_first = {gather_lsb_first[41:0], top(w + s)};
            end
        end
    endfunction

    // A value spread over n consecutive slots, most significant chunk first
    function [47:0] gather_msb_first;
        input integer w;
        input integer n;
        integer s;
        begin
            gather_msb_first = 48'd0;
            for (s = 0; s < n; s = s + 1) begin
                gather_msb_first = {gather_msb_first[41:0], top(w + s)};
            end
        end
    endfunction

    // The recorder: what the buffer takes, on the edges it takes it
    initial begin
        words  = 0;
        cycles = 0;
    end
    always @(posedge clock) begin
        cycles = cycles + 1;
        if (reset_n && capture_enable && (words < MAX_WORDS)) begin
            word_data[words]     = data_out;
            word_position[words] = frame_position;
            word_version[words]  = version;
            word_cycle[words]    = cycles;
            words                = words + 1;
        end
    end

    // The audio inputs move every seven clocks, away from the clock edge
    initial begin
        version = 0;
        set_audio(0);
    end
    always begin
        #87.5 version = version + 1;
        set_audio(version);
    end

    task wait_for_slot;
        input integer target_frame;
        input integer slot;
        begin
            while ((words < (target_frame * FRAME)) || (frame_position != slot)) begin
                @(negedge clock);
            end
        end
    endtask

    initial begin
        errors        = 0;
        frame         = 0;
        decimate      = 1'b0;
        adc_databus   = 10'd0;
        deposit_frame = -1;
        reset_n       = 1'b0;

        @(posedge clock);
        #1 reset_n = 1'b1;

        // Four frames at the full rate, then into a fifth where the counter
        // is pushed to just short of its wrap - while the frame is still in
        // its header, so the first counter slot of that frame carries it
        wait_for_slot(4, 20);
        dut.counter   = NEAR_WRAP;
        deposit_frame = 4;

        // To the decimated rate in the middle of the next frame's counter
        wait_for_slot(5, 200);
        switch_word[0] = words;
        decimate       = 1'b1;

        // Five frames decimating, then back in the middle of a header
        wait_for_slot(11, 40);
        switch_word[1] = words;
        decimate       = 1'b0;

        // And three more at the full rate
        wait_for_slot(14, 0);
        @(negedge clock);

        // Cadence --------------------------------------------------------------
        //
        // The interval between consecutive enables, in system clocks, away
        // from the two changes of rate

        for (i = 1; i < words; i = i + 1) begin
            interval = word_cycle[i] - word_cycle[i-1];
            if (((i > switch_word[0] - SETTLE) && (i < switch_word[0] + SETTLE)) ||
                ((i > switch_word[1] - SETTLE) && (i < switch_word[1] + SETTLE))) begin
                if (interval != 2 && interval != 4) begin
                    $display("note: enable interval %0d clocks at word %0d, by a change of rate",
                             interval, i);
                end
            end else if ((i > switch_word[0]) && (i < switch_word[1])) begin
                if (interval != 4) begin
                    $display("FAIL: enable interval %0d at word %0d while decimating", interval, i);
                    errors = errors + 1;
                end
            end else if (interval != 2) begin
                $display("FAIL: enable interval %0d at word %0d at the full rate", interval, i);
                errors = errors + 1;
            end
        end

        // The ramp ------------------------------------------------------------

        for (i = 0; i < words; i = i + 1) begin
            if (word_data[i][9:0] !== (i % RAMP_LENGTH)) begin
                $display("FAIL: test ramp broken at word %0d", i);
                errors = errors + 1;
            end
        end

        // The frames ------------------------------------------------------------

        expected_counter = 48'd0;

        for (frame = 0; (frame + 1) * FRAME <= words; frame = frame + 1) begin
            base = frame * FRAME;

            for (i = 0; i < FRAME; i = i + 1) begin
                if (word_position[base+i] !== i) begin
                    fail("frame_position does not match the word's slot");
                end
            end

            // Sync
            if ((gather_lsb_first(
                    base + 0, 8
                ) !== SYNC_0) || (gather_lsb_first(
                    base + 8, 8
                ) !== SYNC_1) || (gather_lsb_first(
                    base + 16, 8
                ) !== SYNC_2) || (gather_lsb_first(
                    base + 24, 8
                ) !== SYNC_3)) begin
                fail("the sync pattern is not the fork's");
            end

            // Header
            value         = gather_msb_first(base + 32, 2);
            got_adc_left  = value[11:0];
            value         = gather_msb_first(base + 34, 2);
            got_adc_right = value[11:0];
            value         = gather_msb_first(base + 38, 4);
            got_pcm_left  = value[23:0];
            value         = gather_msb_first(base + 42, 4);
            got_pcm_right = value[23:0];

            got_status    = {top(base + 36), top(base + 37), top(base + 46), top(base + 47)};

            if (frame == 0) begin
                // Nothing has been snapshotted yet: reset's zeros
                if ((got_adc_left !== 12'd0) || (got_adc_right !== 12'd0) ||
                    (got_pcm_left !== 24'd0) || (got_pcm_right !== 24'd0)) begin
                    fail("the first frame after reset does not carry zero audio");
                end
                if (got_status !== 24'd0) begin
                    fail("the first frame after reset does not carry a zero status word");
                end
            end else begin
                got_version = got_adc_left;
                if ((got_adc_right !== (got_adc_left ^ 12'hA5A)) ||
                    (got_pcm_left !== {got_adc_left, ~got_adc_left}) ||
                    (got_pcm_right !== {got_adc_left ^ 12'h3C3, got_adc_left})) begin
                    fail("the header mixes two different sets of audio");
                end else if (got_status !== status_of(got_adc_left)) begin
                    fail("the status word is not the one snapshotted with the audio");
                end else if (got_version !== (word_version[base-1] % 4096)) begin
                    fail("the header is not the audio present when slot 0 was loaded");
                end
            end

            // Counter
            if (frame == deposit_frame) begin
                expected_counter = NEAR_WRAP;
            end
            for (j = 0; j < COUNTER_VALUES; j = j + 1) begin
                value = gather_lsb_first(base + 48 + (8 * j), 8);
                if (value !== expected_counter) begin
                    $display("frame %0d value %0d: got %h, expected %h", frame, j, value,
                             expected_counter);
                    fail("the counter is broken");
                end
                expected_counter = expected_counter + 48'd1;
            end
        end

        if (frame < 14) begin
            fail("too few frames recorded");
        end
        if (deposit_frame < 0) begin
            fail("the counter wrap was never exercised");
        end

        // The frame period at each rate, which is the audio sample period:
        // 12.8 us, 78.125 kHz, and 25.6 us, 39.0625 kHz
        k = word_cycle[2*FRAME] - word_cycle[1*FRAME];
        if (k != 1024) begin
            $display("FAIL: a full-rate frame took %0d clocks, not 1024", k);
            errors = errors + 1;
        end
        k = word_cycle[8*FRAME] - word_cycle[7*FRAME];
        if (k != 2048) begin
            $display("FAIL: a decimated frame took %0d clocks, not 2048", k);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("tb_dataGeneratorFramed: PASS");
        end else begin
            $display("tb_dataGeneratorFramed: FAIL (%0d errors)", errors);
        end

        if (errors != 0) begin
            $fatal(1, "tb_dataGeneratorFramed failed");
        end
        $finish;
    end

endmodule
