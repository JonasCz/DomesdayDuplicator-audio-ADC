/************************************************************************

    tb_sdramController.v

    Testbench for the SDRAM ring controller (T3)
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    The controller on its own, against sdramModel.v. Its two FIFOs are
    upstream's single-clock fifo.v at the controller's clock, so that what is
    tested here is the SDRAM side and nothing about crossing clocks; the
    dual-clock path is tb_sdramBuffer's.

    The model checks the protocol on every edge - power-up, every command's
    timing, bank state, burst termination, refresh rate - and this bench
    checks the data: a counter goes in, the same counter has to come out, in
    order and complete. The ring is 64 rows, sixteen per bank, so it wraps
    many times and every bank is used.

      1. power-up: nothing but NOP for 200 us, then the sequence
      2. one row in and out
      3. the ring filled to capacity with the reader stopped: it holds exactly
         RingRows rows, the controller stops writing and stops touching the
         SDRAM except to refresh, and nothing is lost
      4. the backlog drained with the writer running at 40 MSPS, and the net
         drain rate measured
      5. a long run with the reader stalling at random, for refresh compliance
         over thousands of refresh intervals and for many wraps of the ring
      6. a flush in the middle of a backlog: acknowledged, the ring empty,
         both FIFOs empty, and the stream after it fresh
      7. both directions saturated, to measure what the part carries

    The SDRAM's clock leads the controller's by 1 ns here, standing for the
    phase shift and the pin delays on the board: commands registered on one
    controller edge are taken by the SDRAM just before the next, and read data
    launched by the SDRAM is captured on the controller edge after it.

************************************************************************/

`timescale 1ns / 1ps

module tb_sdramController;

    localparam integer RING_ROWS = 64;
    localparam integer ROWS_PER_BANK = 16;
    localparam integer ROW_WORDS = 512;
    localparam integer FIFO_DEPTH = 2048;

    // Room for a row, plus the words still in the capture pipeline
    localparam integer EGRESS_ROOM = FIFO_DEPTH - ROW_WORDS - 8;

    // 120 MHz, to the picosecond
    localparam real HALF_PERIOD = 4.167;
    localparam real PERIOD = 2.0 * HALF_PERIOD;
    localparam real SDRAM_CLOCK_DELAY = PERIOD - 1.0;

    reg reset_n;
    reg clock;
    reg sdram_clock;

    initial begin
        clock       = 1'b0;
        sdram_clock = 1'b0;
    end
    always begin
        #(HALF_PERIOD) clock = ~clock;
    end

    // A transport delay: an inertial one longer than the half period would
    // swallow every edge
    always @(clock) begin
        sdram_clock <= #(SDRAM_CLOCK_DELAY) clock;
    end

    // FIFOs -------------------------------------------------------------------

    reg         ingress_write;
    reg  [15:0] ingress_write_data;
    wire        ingress_read;
    wire [15:0] ingress_data;
    wire        ingress_full;
    wire [11:0] ingress_used;

    fifo #(
        .DataWidth(16),
        .Depth    (FIFO_DEPTH)
    ) ingress (
        .reset_n      (reset_n),
        .clock        (clock),
        .write_request(ingress_write),
        .data_in      (ingress_write_data),
        .read_request (ingress_read),
        .data_out     (ingress_data),
        .full         (ingress_full),
        .used_words   (ingress_used)
    );

    wire        egress_write;
    wire [15:0] egress_write_data;
    wire        egress_read;
    wire [15:0] egress_data;
    wire        egress_full;
    wire [11:0] egress_used;

    fifo #(
        .DataWidth(16),
        .Depth    (FIFO_DEPTH)
    ) egress (
        .reset_n      (reset_n),
        .clock        (clock),
        .write_request(egress_write),
        .data_in      (egress_write_data),
        .read_request (egress_read),
        .data_out     (egress_data),
        .full         (egress_full),
        .used_words   (egress_used)
    );

    // The controller and the part -----------------------------------------------

    reg         flush;
    wire        flush_ack;
    wire        init_done;
    wire [15:0] ring_fill;

    wire        sdram_cke;
    wire        sdram_cs_n;
    wire        sdram_ras_n;
    wire        sdram_cas_n;
    wire        sdram_we_n;
    wire [ 1:0] sdram_ba;
    wire [12:0] sdram_addr;
    wire [ 1:0] sdram_dqm;
    wire [15:0] sdram_dq_out;
    wire        sdram_dq_oe;
    wire [15:0] sdram_dq;

    assign sdram_dq = sdram_dq_oe ? sdram_dq_out : {16{1'bz}};

    sdramController #(
        .RingRows(RING_ROWS)
    ) dut (
        .reset_n        (reset_n),
        .clock          (clock),
        .ingress_has_row(ingress_used >= ROW_WORDS),
        .ingress_data   (ingress_data),
        .ingress_read   (ingress_read),
        .egress_has_room(egress_used <= EGRESS_ROOM),
        .egress_drained (egress_used == 12'd0),
        .egress_write   (egress_write),
        .egress_data    (egress_write_data),
        .flush          (flush),
        .flush_ack      (flush_ack),
        .init_done      (init_done),
        .ring_fill      (ring_fill),
        .sdram_cke      (sdram_cke),
        .sdram_cs_n     (sdram_cs_n),
        .sdram_ras_n    (sdram_ras_n),
        .sdram_cas_n    (sdram_cas_n),
        .sdram_we_n     (sdram_we_n),
        .sdram_ba       (sdram_ba),
        .sdram_addr     (sdram_addr),
        .sdram_dqm      (sdram_dqm),
        .sdram_dq_out   (sdram_dq_out),
        .sdram_dq_oe    (sdram_dq_oe),
        .sdram_dq_in    (sdram_dq)
    );

    sdramModel #(
        .RowsPerBank(ROWS_PER_BANK)
    ) model (
        .clock(sdram_clock),
        .cke  (sdram_cke),
        .cs_n (sdram_cs_n),
        .ras_n(sdram_ras_n),
        .cas_n(sdram_cas_n),
        .we_n (sdram_we_n),
        .ba   (sdram_ba),
        .addr (sdram_addr),
        .dqm  (sdram_dqm),
        .dq   (sdram_dq)
    );

    // Producer and consumer -----------------------------------------------------
    //
    // The producer offers one word every produce_period cycles while
    // producing is set; 1 is as fast as the FIFO takes them, 3 is 40 MSPS.
    // The consumer takes a word whenever there is one and consuming is set,
    // and checks it against the next expected value unless discarding is set.

    integer        errors;
    reg            producing;
    integer        produce_period;
    integer        produce_phase;
    reg     [15:0] produce_value;
    integer        produced;

    reg            consuming;
    reg            discarding;
    reg     [15:0] expected;
    integer        consumed;
    integer        reported;

    assign egress_read = consuming && (egress_used != 12'd0);

    always @(*) begin
        ingress_write      = producing && (produce_phase == 0) && !ingress_full;
        ingress_write_data = produce_value;
    end

    always @(posedge clock) begin
        if (producing) begin
            produce_phase <= (produce_phase + 1 >= produce_period) ? 0 : produce_phase + 1;
        end else begin
            produce_phase <= 0;
        end

        if (ingress_write) begin
            produce_value <= produce_value + 16'd1;
            produced      <= produced + 1;
        end

        if (egress_read) begin
            consumed <= consumed + 1;
            if (!discarding) begin
                if (egress_data !== expected) begin
                    errors = errors + 1;
                    if (reported < 10) begin
                        $display("FAIL: word %0d: got %h, expected %h (t=%0t)", consumed,
                                 egress_data, expected, $time);
                        reported = reported + 1;
                    end
                end
                expected <= egress_data + 16'd1;
            end
        end

        if (egress_write && egress_full) begin
            errors = errors + 1;
            $display("FAIL: the controller wrote to a full egress FIFO (t=%0t)", $time);
        end
    end

    task check;
        input [31:0] got;
        input [31:0] want;
        input [511:0] what;
        begin
            if (got !== want) begin
                $display("FAIL: %0s: got %0d, expected %0d (t=%0t)", what, got, want, $time);
                errors = errors + 1;
            end
        end
    endtask

    task wait_cycles;
        input integer count;
        integer n;
        begin
            for (n = 0; n < count; n = n + 1) begin
                @(posedge clock);
            end
            #1;
        end
    endtask

    // Microseconds of simulated time, in cycles
    function integer us;
        input real microseconds;
        begin
            us = $rtoi(microseconds * 1000.0 / PERIOD);
        end
    endfunction

    real           start_time;
    real           phase_time;
    integer        start_words;
    integer        start_rows;
    integer        activates_before;
    integer        i;
    reg     [31:0] seed;

    // A xorshift generator, so that a run is the same on every simulator and
    // every time. seed is its state.
    function [31:0] random_word;
        input dummy;
        begin
            seed        = seed ^ (seed << 13);
            seed        = seed ^ (seed >> 17);
            seed        = seed ^ (seed << 5);
            random_word = seed;
        end
    endfunction
    real rate;

    initial begin
        errors         = 0;
        reported       = 0;
        seed           = 32'h5d_5d_0001;
        reset_n        = 1'b0;
        flush          = 1'b0;
        producing      = 1'b0;
        produce_period = 1;
        produce_phase  = 0;
        produce_value  = 16'd0;
        produced       = 0;
        consuming      = 1'b0;
        discarding     = 1'b0;
        expected       = 16'd0;
        consumed       = 0;

        wait_cycles(4);
        reset_n    = 1'b1;
        start_time = $realtime;

        // --- 1. Power-up ----------------------------------------------------
        wait (init_done === 1'b1);
        #1;
        $display("Power-up complete after %0.1f us", ($realtime - start_time) / 1000.0);
        check(($realtime - start_time) >= 200000.0, 1, "power-up takes at least 200 us");
        check(model.mode_set, 1, "the mode register is set");
        check(model.refresh_count >= 8, 1, "at least eight power-up refreshes");
        check(model.errors, 0, "protocol errors during power-up");

        // --- 2. One row --------------------------------------------------------
        consuming = 1'b1;
        producing = 1'b1;
        wait (produced == ROW_WORDS);
        producing = 1'b0;
        wait (consumed == ROW_WORDS);
        wait_cycles(16);
        check(consumed, ROW_WORDS, "one row comes back whole");
        check(ring_fill, 0, "the ring is empty again");

        // --- 3. Fill to capacity -----------------------------------------------
        consuming = 1'b0;
        producing = 1'b1;
        wait ((ring_fill == RING_ROWS) && ingress_full);
        wait_cycles(us(20.0));
        check(ring_fill, RING_ROWS, "the ring holds exactly RingRows rows when full");
        check(ingress_full, 1, "the ingress FIFO backs up behind a full ring");
        activates_before = model.activates;
        wait_cycles(us(60.0));
        check(model.activates - activates_before, 0, "nothing but refresh while full and stalled");
        check(ring_fill, RING_ROWS, "still full");
        $display("Held while stalled: %0d words (%0d rows in the ring, %0d + %0d in the FIFOs)",
                 produced - consumed, ring_fill, ingress_used, egress_used);

        // --- 4. Drain at 40 MSPS ----------------------------------------------
        produce_period = 3;
        consuming      = 1'b1;
        wait_cycles(us(10.0));
        start_time  = $realtime;
        start_rows  = ring_fill;
        start_words = produced - consumed;
        wait (ring_fill == 0);
        #1;
        rate = (start_words - (produced - consumed)) / (($realtime - start_time) / 1000.0);
        $display("Backlog drain with 40 MSPS arriving: %0d rows in %0.1f us, net %0.1f Mwords/s",
                 start_rows, ($realtime - start_time) / 1000.0, rate);
        check(rate > 30.0, 1, "the backlog drains at more than 30 Mwords/s net");

        // --- 5. Long run, random reader stalls ---------------------------------
        phase_time = $realtime;
        while (($realtime - phase_time) < 8000000.0) begin
            consuming = 1'b0;
            wait_cycles(us((random_word(1'b0) & 32'hFF) * 1.0));
            consuming = 1'b1;
            wait_cycles(us((random_word(1'b0) & 32'hFF) * 2.0));
        end
        consuming = 1'b1;
        wait (ring_fill == 0);
        $display("Long run: %0d words, %0d refreshes, debt at most %0d, longest gap %0.2f us",
                 consumed, model.refresh_count, model.maximum_debt,
                 model.maximum_refresh_gap / 1000.0);
        check(model.maximum_debt <= 1, 1, "no more than one refresh ever owed");

        // --- 6. Flush in the middle of a backlog -------------------------------
        consuming = 1'b0;
        wait_cycles(us(300.0));
        check(ring_fill > 10, 1, "a backlog to flush");
        producing  = 1'b0;
        discarding = 1'b1;
        consuming  = 1'b1;
        flush      = 1'b1;
        wait (flush_ack === 1'b1);
        wait_cycles(4);
        check(ring_fill, 0, "a flush empties the ring");
        check(ingress_used, 0, "a flush empties the ingress FIFO");
        check(egress_used, 0, "a flush leaves the egress FIFO empty");
        activates_before = model.activates;
        wait_cycles(us(20.0));
        check(model.activates - activates_before, 0, "nothing but refresh while flushed");
        check(flush_ack, 1, "the acknowledgement holds while the flush does");

        flush = 1'b0;
        wait (flush_ack === 1'b0);
        wait_cycles(4);
        discarding     = 1'b0;
        produce_value  = 16'hC000;
        expected       = 16'hC000;
        produce_period = 3;
        producing      = 1'b1;
        wait_cycles(us(500.0));
        check(consumed > 0, 1, "data flows after a flush");

        // --- 7. Both directions saturated --------------------------------------
        produce_period = 1;
        wait_cycles(us(50.0));
        start_time  = $realtime;
        start_words = model.words_written + model.words_read;
        wait_cycles(us(1000.0));
        rate = (model.words_written + model.words_read - start_words)
            / (($realtime - start_time) / 1000.0);
        $display("Saturated: %0.1f Mwords/s through the part, written and read together", rate);
        check(rate > 110.0, 1, "the part carries more than 110 Mwords/s");

        producing = 1'b0;
        wait (ring_fill == 0);
        wait_cycles(us(20.0));

        check(model.errors, 0, "protocol errors reported by the SDRAM model");

        if (errors != 0) begin
            $fatal(1, "tb_sdramController: %0d check(s) failed", errors);
        end

        $display("tb_sdramController: PASS");
        $finish;
    end

endmodule
