/************************************************************************

    pcm1802Model.v

    Simulation model of the PCM1802 in slave mode, with its interface
    timing checked
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    A test fixture, never compiled into a bitstream. It is the converter
    strapped for slave mode (MODE1:0 = 00) and the 24-bit left-justified
    format (FMT1:0 = 00), with FSYNC tied high, and it answers and checks
    its interface as the datasheet (TI SLES023D) gives them:

      - Figure 23: LRCK high is the left word and low the right; each word's
        MSB leaves on the LRCK edge and every later bit on a falling BCK
        edge, for the receiver to read on the rising edge after it; after
        the 24th bit DOUT is zero until the next LRCK edge
      - Table 7: DOUT undefined from 10 ns before a falling BCK edge, or the
        LRCK edge, until 20 ns after it; BCK period at least 150 ns, high
        and low at least 60 ns each; LRCK set up 40 ns before and held 20 ns
        after a rising BCK edge; LRCK period at least 10 us
      - Table 2: SCKI high and low at least 7 ns each
      - 7.3.3 and 7.4.2.3: SCKI at 256 fs and BCK at 64 fs, which this model
        checks as exactly 256 and 64 rising edges in every LRCK period, and
        a sampling rate of 16 to 96 kHz

    The words it sends are a function of the LRCK period's index and the
    channel, chosen to exercise every bit and both signs and to differ
    between the channels, and each is logged as it starts so a testbench
    can compare what the controller reported with what was sent.

************************************************************************/

`timescale 1ns / 1ps

module pcm1802Model (
    input scki,
    input bck,
    input lrck,

    output reg dout
);

    // Table 7 and Table 2, in nanoseconds
    localparam real T_SCKH = 7.0;
    localparam real T_SCKL = 7.0;
    localparam real T_BCKP = 150.0;
    localparam real T_BCKH = 60.0;
    localparam real T_BCKL = 60.0;
    localparam real T_LRSU = 40.0;
    localparam real T_LRHD = 20.0;
    localparam real T_DOUT_EARLY = 10.0;
    localparam real T_DOUT_LATE = 20.0;

    // fs from 16 to 96 kHz, which also meets the 10 us minimum LRCK period
    localparam real MIN_LRCK_PERIOD = 10416.0;
    localparam real MAX_LRCK_PERIOD = 62500.0;

    localparam integer LOG_LENGTH = 4096;

    integer         errors;
    integer         periods;

    reg      [23:0] log_left       [0:LOG_LENGTH-1];
    reg      [23:0] log_right      [0:LOG_LENGTH-1];

    reg      [23:0] word;
    reg             lrck_previous;
    integer         bits_sent;
    integer         scki_rises;
    integer         bck_rises;
    reg             next_bit;

    realtime        last_scki_rise;
    realtime        last_scki_fall;
    realtime        last_bck_rise;
    realtime        last_bck_fall;
    realtime        last_lrck_edge;
    realtime        last_lrck_rise;
    realtime        bck_high;

    // The word sent for a channel in a given LRCK period. Twenty-four bits
    // that change in every byte from one period to the next, have both
    // signs, and are never equal between the two channels.
    function [23:0] sample_word;
        input integer index;
        input right_channel;
        reg [7:0] k;
        begin
            k = index[7:0];
            if (right_channel) begin
                sample_word = {~k, k ^ 8'hC3, k};
            end else begin
                sample_word = {k, ~k, k ^ 8'h5A};
            end
        end
    endfunction

    initial begin
        dout           = 1'b0;
        lrck_previous  = 1'bx;
        errors         = 0;
        periods        = 0;
        word           = 24'd0;
        bits_sent      = 24;
        scki_rises     = 0;
        bck_rises      = 0;
        last_scki_rise = -1.0e9;
        last_scki_fall = -1.0e9;
        last_bck_rise  = -1.0e9;
        last_bck_fall  = -1.0e9;
        last_lrck_edge = -1.0e9;
        last_lrck_rise = -1.0e9;
        bck_high       = 0.0;
    end

    task fail;
        input [511:0] what;
        begin
            $display("pcm1802Model: %0s (t=%0t)", what, $realtime);
            errors = errors + 1;
        end
    endtask

    // SCKI ---------------------------------------------------------------------

    always @(posedge scki) begin
        if (($realtime - last_scki_fall) < T_SCKL) begin
            fail("SCKI low for less than 7 ns");
        end
        last_scki_rise = $realtime;
        scki_rises     = scki_rises + 1;
    end

    always @(negedge scki) begin
        if (($realtime - last_scki_rise) < T_SCKH) begin
            fail("SCKI high for less than 7 ns");
        end
        last_scki_fall = $realtime;
    end

    // LRCK -----------------------------------------------------------------------

    // Only a change between 0 and 1 is an edge: the pin leaving x as the
    // controller comes out of reset is not the start of a word
    always @(lrck) begin
        if ((lrck_previous === 1'b0) || (lrck_previous === 1'b1)) begin
            lrck_edge(lrck);
        end
        lrck_previous = lrck;
    end

    task lrck_edge;
        input level;
        begin
            if (($realtime - last_bck_rise) < T_LRHD) begin
                fail("LRCK changed inside its hold time after a rising BCK edge");
            end
            last_lrck_edge = $realtime;

            // A new word, MSB first, starting on this edge
            word           = sample_word(periods, ~level);
            bits_sent      = 1;
            dout           = 1'bx;
            dout <= #(T_DOUT_LATE) word[23];

            if (level) begin
                // The start of a period, and so the end of the one before it,
                // if there was one
                if (last_lrck_rise > 0.0) begin
                    if ((($realtime - last_lrck_rise) < MIN_LRCK_PERIOD) ||
                    (($realtime - last_lrck_rise) > MAX_LRCK_PERIOD)) begin
                        fail("sampling rate outside 16 to 96 kHz");
                    end
                    if (scki_rises != 256) begin
                        fail("SCKI was not 256 fs");
                    end
                    if (bck_rises != 64) begin
                        fail("BCK was not 64 fs");
                    end
                end
                last_lrck_rise = $realtime;
                scki_rises     = 0;
                bck_rises      = 0;

                if (periods < LOG_LENGTH) begin
                    log_left[periods] = word;
                end
            end else begin
                if (periods < LOG_LENGTH) begin
                    log_right[periods] = word;
                end
                periods = periods + 1;
            end
        end
    endtask

    // BCK and DOUT -----------------------------------------------------------

    always @(posedge bck) begin
        if (($realtime - last_bck_fall) < T_BCKL) begin
            fail("BCK low for less than 60 ns");
        end
        if (($realtime - last_bck_rise) < T_BCKP) begin
            fail("BCK period shorter than 150 ns");
        end
        if (($realtime - last_lrck_edge) < T_LRSU) begin
            fail("LRCK changed inside its set-up time before a rising BCK edge");
        end
        last_bck_rise = $realtime;
        bck_rises     = bck_rises + 1;
    end

    // DOUT may start to change 10 ns before a falling BCK edge. The edge is
    // predicted from the last high time, and if it comes sooner than that -
    // the rate has just gone up - the prediction is dropped, because the
    // part's figure is relative to the edge it actually gets.
    always @(posedge bck) begin
        if (bck_high > T_DOUT_EARLY) begin
            #(bck_high - T_DOUT_EARLY);
            if (bck === 1'b1) begin
                dout = 1'bx;
            end
        end
    end

    always @(negedge bck) begin
        if (($realtime - last_bck_rise) < T_BCKH) begin
            fail("BCK high for less than 60 ns");
        end
        if (last_bck_rise > 0.0) begin
            bck_high = $realtime - last_bck_rise;
        end
        last_bck_fall = $realtime;

        // A falling edge on the same instant as an LRCK edge belongs to the
        // new word, whose MSB the LRCK edge has already sent
        if ($realtime != last_lrck_edge) begin
            if (bits_sent < 24) begin
                next_bit = word[23-bits_sent];
            end else begin
                next_bit = 1'b0;
            end
            bits_sent = bits_sent + 1;
            dout      = 1'bx;
            dout <= #(T_DOUT_LATE) next_bit;
        end
    end

endmodule
