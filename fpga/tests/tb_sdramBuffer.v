/************************************************************************

    tb_sdramBuffer.v

    Testbench for the SDRAM capture buffer, end to end (T3)
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    The capture path from the sampling side to the GPIF databus, built as
    the top level wires it: sdramBuffer.v (both FIFOs, the controller, the
    flush and status logic) feeding upstream's buffer.v, read by upstream's
    fx3StateMachine.v, with sdramModel.v as the SDRAM. Only the PLL and the
    pins are missing, which is why the top level itself is not simulated.

    The producer is the sampling side at 40 MSPS - one word every second
    80 MHz cycle - carrying a counter. The consumer behaves like the FX3: it
    takes 8192-word packets through the state machine whenever
    data_available offers one, with a short random gap between packets, and
    it can be told to stall, which it does at a packet boundary. It checks
    every word it takes against the counter and records every discontinuity.

    The ring is 32 rows here instead of 32768, so the whole path holds about
    0.7 ms of samples instead of 0.42 s and a stall that overflows it is
    short enough to simulate. Everything else is as built, including the
    200 us SDRAM power-up and the 2048-word FIFOs.

      1. collect_data raised before the SDRAM is ready: the path stays
         bypassed until initialisation completes, then switches with no
         break in the stream
      2. steady state: no break, and buffer.v held at one packet, so that
         its instrument reads as healthy as it did before the SDRAM
      3. random stalls that fit: no break, and the status word's fill
         follows the backlog throughout
      4. a stall the path cannot hold: one contiguous run lost, buffer_error
         raised, the instrument's overflow and dropped counts agree with the
         run the consumer saw, the sticky status bit set, and the stream
         contiguous again afterwards; then the drain rate is measured
      5. collect_data falling with a backlog: back to bypass at once, the
         SDRAM path's contents discarded as one contiguous run, the path
         flushed
      6. collect_data rising: the sticky bit cleared, the switch made with no
         break
      7. collect_data falling and rising again within a microsecond, with a
         backlog, and again early in the recovery from a full ring, when the
         ingress FIFO is deep: the path is emptied completely before it is
         used again, so nothing stale comes out after the restart
      8. bypassed, a stall overflows buffer.v as it always has, and the
         sticky SDRAM bit is not set by it

************************************************************************/

`timescale 1ns / 1ps

module tb_sdramBuffer;

    localparam integer RING_ROWS = 32;
    localparam integer ROWS_PER_BANK = 8;
    localparam integer ROW_WORDS = 512;
    localparam integer FIFO_WORDS = 2048;
    localparam integer PACKET_WORDS = 8192;
    localparam integer BUFFER_LIMIT = 8194;

    localparam real SYSTEM_HALF = 6.25;
    localparam real SDRAM_HALF = 4.167;
    localparam real SDRAM_PERIOD = 2.0 * SDRAM_HALF;
    localparam real SDRAM_CLOCK_DELAY = SDRAM_PERIOD - 1.0;

    reg clock;
    reg sdram_clock;
    reg dram_clock;
    reg reset_source_n;
    reg reset_n;
    reg sdram_reset_n;

    initial begin
        clock       = 1'b0;
        sdram_clock = 1'b0;
        dram_clock  = 1'b0;
    end

    always begin
        #(SYSTEM_HALF) clock = ~clock;
    end

    // Started off the system clock's edges, and at a period that does not
    // divide it, so the two drift through every alignment
    initial begin
        #1.3;
        forever begin
            #(SDRAM_HALF) sdram_clock = ~sdram_clock;
        end
    end

    always @(sdram_clock) begin
        dram_clock <= #(SDRAM_CLOCK_DELAY) sdram_clock;
    end

    // One asynchronous reset, released by a synchroniser in each domain, as
    // the top level does it
    reg [1:0] reset_sync;
    reg [1:0] sdram_reset_sync;

    always @(posedge clock, negedge reset_source_n) begin
        if (!reset_source_n) begin
            reset_sync <= 2'b00;
        end else begin
            reset_sync <= {reset_sync[0], 1'b1};
        end
    end

    always @(posedge sdram_clock, negedge reset_source_n) begin
        if (!reset_source_n) begin
            sdram_reset_sync <= 2'b00;
        end else begin
            sdram_reset_sync <= {sdram_reset_sync[0], 1'b1};
        end
    end

    always @(*) begin
        reset_n       = reset_sync[1];
        sdram_reset_n = sdram_reset_sync[1];
    end

    // The sampling side: one word every second cycle, a counter -------------------

    reg         sample_phase;
    reg  [31:0] produced;
    wire        sample_strobe = sample_phase;
    wire [15:0] sample_data = produced[15:0];

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            sample_phase <= 1'b0;
            produced     <= 32'd0;
        end else begin
            sample_phase <= ~sample_phase;
            if (sample_strobe) begin
                produced <= produced + 32'd1;
            end
        end
    end

    // The path ----------------------------------------------------------------------

    reg         collect_data;

    wire        buffer_write;
    wire [15:0] buffer_data;
    wire [14:0] buffer_used_words;
    wire        sample_lost;
    wire [23:0] status;

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

    sdramBuffer #(
        .RingRows(RING_ROWS)
    ) dut (
        .reset_n          (reset_n),
        .clock            (clock),
        .collect_data     (collect_data),
        .sample_strobe    (sample_strobe),
        .sample_data      (sample_data),
        .buffer_used_words(buffer_used_words),
        .buffer_write     (buffer_write),
        .buffer_data      (buffer_data),
        .sample_lost      (sample_lost),
        .status           (status),
        .sdram_reset_n    (sdram_reset_n),
        .sdram_clock      (sdram_clock),
        .sdram_cke        (sdram_cke),
        .sdram_cs_n       (sdram_cs_n),
        .sdram_ras_n      (sdram_ras_n),
        .sdram_cas_n      (sdram_cas_n),
        .sdram_we_n       (sdram_we_n),
        .sdram_ba         (sdram_ba),
        .sdram_addr       (sdram_addr),
        .sdram_dqm        (sdram_dqm),
        .sdram_dq_out     (sdram_dq_out),
        .sdram_dq_oe      (sdram_dq_oe),
        .sdram_dq_in      (sdram_dq)
    );

    sdramModel #(
        .RowsPerBank(ROWS_PER_BANK)
    ) model (
        .clock(dram_clock),
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

    wire         fx3_is_reading;
    wire [ 15:0] fx3_databus;
    wire         data_available;
    wire         buffer_error;
    reg          telemetry_latch;
    wire [127:0] telemetry;
    wire [ 47:0] telemetry_geometry;

    buffer buffer_0 (
        .reset_n           (reset_n),
        .clock             (clock),
        .write_enable      (buffer_write),
        .data_in           (buffer_data),
        .sample_offered    (sample_strobe),
        .sample_lost       (sample_lost),
        .is_reading        (fx3_is_reading),
        .telemetry_latch   (telemetry_latch),
        .data_out          (fx3_databus),
        .data_available    (data_available),
        .buffer_error      (buffer_error),
        .used_words        (buffer_used_words),
        .telemetry         (telemetry),
        .telemetry_geometry(telemetry_geometry)
    );

    reg fx3_read_data;

    fx3StateMachine fx3_state_machine_0 (
        .reset_n       (reset_n),
        .fx3_clock     (clock),
        .read_data     (fx3_read_data),
        .fx3_is_reading(fx3_is_reading)
    );

    wire    [15:0] status_fill = status[15:0];
    wire           status_lost = status[17];
    wire           status_initialised = status[18];
    wire           status_active = status[19];
    wire    [ 3:0] status_version = status[23:20];

    wire    [15:0] telemetry_peak = telemetry[47:32];
    wire    [15:0] telemetry_overflows = telemetry[79:64];
    wire    [15:0] telemetry_dropped = telemetry[95:80];
    wire    [15:0] telemetry_near_full = telemetry[127:112];

    // The FX3 ------------------------------------------------------------------------
    //
    // Requests a packet when one is offered and it is not stalled, takes it,
    // waits a short random time and asks again. A stall takes effect at the
    // next packet boundary, as a real one does.

    integer        errors;
    integer        reported;
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
    reg            stalled;
    reg            requested;
    integer        packet_gap;

    // The consumer's view of the stream: the index of the next word it expects,
    // reconstructed to 32 bits from the 16-bit counter, and every break in it
    reg     [31:0] expected;
    reg     [31:0] consumed;
    integer        gaps;
    reg     [31:0] last_gap;
    reg     [31:0] gap_words;
    reg            first_word;
    reg     [15:0] delta;

    // Samples lost - at the SDRAM path's door or, bypassed, at buffer.v's -
    // that the consumer has not yet reached the gap of. Until it does they
    // are produced and not consumed, but they are not in the path either.
    reg     [31:0] lost_total;
    reg     [31:0] lost_seen;

    always @(posedge clock) begin
        if (reset_n && buffer_0.overflow) begin
            lost_total = lost_total + 32'd1;
        end
    end

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            fx3_read_data <= 1'b0;
            requested     <= 1'b0;
            packet_gap    <= 0;
        end else begin
            fx3_read_data <= 1'b0;

            if (fx3_is_reading) begin
                requested  <= 1'b0;
                packet_gap <= 16 + ((random_word(1'b0) & 32'h7FFF) % 200);
            end else if (packet_gap != 0) begin
                packet_gap <= packet_gap - 1;
            end else if (!requested && !stalled && data_available) begin
                fx3_read_data <= 1'b1;
                requested     <= 1'b1;
            end
        end
    end

    always @(posedge clock) begin
        if (reset_n && fx3_is_reading) begin
            if (first_word) begin
                expected   = {16'd0, fx3_databus};
                first_word = 1'b0;
            end

            delta = fx3_databus - expected[15:0];
            if (delta != 16'd0) begin
                // A break. It can only be forwards: anything that reads as a
                // jump of more than the whole path can hold is a word out of
                // order, repeated, or corrupt.
                gaps      = gaps + 1;
                last_gap  = {16'd0, delta};
                gap_words = gap_words + {16'd0, delta};
                if (delta > 16'd50000) begin
                    errors = errors + 1;
                    if (reported < 10) begin
                        $display("FAIL: word out of order: got %h, expected %h (t=%0t)",
                                 fx3_databus, expected[15:0], $time);
                        reported = reported + 1;
                    end
                end
                expected  = expected + {16'd0, delta};
                lost_seen = lost_total;
            end

            expected = expected + 32'd1;
            consumed = consumed + 32'd1;
        end

        // Never written while full: the SDRAM path waits for room
        if (reset_n && buffer_write && status_active && (buffer_used_words >= 15'd16384)) begin
            errors = errors + 1;
            $display("FAIL: the SDRAM path wrote into a full buffer.v (t=%0t)", $time);
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

    task wait_us;
        input real microseconds;
        begin
            #(microseconds * 1000.0);
            @(posedge clock);
            #1;
        end
    endtask

    // Sample the instrument, as the register bank does
    task take_reading;
        begin
            @(posedge clock);
            #1 telemetry_latch = 1'b1;
            @(posedge clock);
            #1 telemetry_latch = 1'b0;
            @(posedge clock);
            #1;
        end
    endtask

    // Words between the producer and the consumer, by the testbench's count:
    // produced, less the index of the next word the consumer expects, less
    // what has been lost and not yet skipped
    function [31:0] in_path;
        input dummy;
        begin
            in_path = produced - expected - (lost_total - lost_seen);
        end
    endfunction

    // The status fill against the truth. The fill counts rows in the SDRAM;
    // the rest of the backlog is in the two FIFOs and buffer.v. One row can be
    // counted in both places while it is being read out, one can be in
    // neither while it is being written, and the status word can be one row
    // behind the controller, so the bounds allow two rows either way. While
    // bypassed, buffer.v can hold its whole depth.
    task check_fill;
        reg [31:0] words;
        reg [31:0] rows_words;
        reg [31:0] buffer_words;
        begin
            words        = in_path(1'b0);
            rows_words   = {16'd0, status_fill} * ROW_WORDS;
            buffer_words = status_active ? BUFFER_LIMIT : 16384;
            if (rows_words > words + 2 * ROW_WORDS + 64) begin
                fail_fill("the status fill claims more than the backlog", words);
            end
            if (words > rows_words + (2 * FIFO_WORDS) + buffer_words + (2 * ROW_WORDS) + 64) begin
                fail_fill("the backlog is more than the status fill accounts for", words);
            end
            if ((status_fill > dut.sdram_controller_0.ring_fill + 16'd1)
                || (status_fill + 16'd1 < dut.sdram_controller_0.ring_fill)) begin
                fail_fill("the status fill is not the controller's ring fill", words);
            end
        end
    endtask

    integer fill_failures;

    task fail_fill;
        input [511:0] what;
        input [31:0] words;
        begin
            errors        = errors + 1;
            fill_failures = fill_failures + 1;
            if (fill_failures < 5) begin
                $display("FAIL: %0s: fill %0d rows, backlog %0d words (t=%0t)", what, status_fill,
                         words, $time);
            end
        end
    endtask

    // Run for a while, checking the fill every few microseconds
    reg [15:0] peak_fill;

    task run_checking_fill;
        input real microseconds;
        real finish_time;
        begin
            finish_time = $realtime + microseconds * 1000.0;
            while ($realtime < finish_time) begin
                #(2000.0);
                check_fill;
                if (status_fill > peak_fill) begin
                    peak_fill = status_fill;
                end
            end
            @(posedge clock);
            #1;
        end
    endtask

    integer        gaps_before;
    integer        errors_before;
    reg     [31:0] gap_before;
    reg     [31:0] produced_at;
    reg     [31:0] path_at;
    real           start_time;
    real           drain_time;
    real           rate_net;
    real           rate_out;
    integer        stall;
    integer        i;

    initial begin
        errors          = 0;
        reported        = 0;
        fill_failures   = 0;
        seed            = 32'h0D0D_5D5D;
        stalled         = 1'b0;
        collect_data    = 1'b0;
        telemetry_latch = 1'b0;
        expected        = 32'd0;
        consumed        = 32'd0;
        gaps            = 0;
        last_gap        = 32'd0;
        gap_words       = 32'd0;
        first_word      = 1'b1;
        lost_total      = 32'd0;
        lost_seen       = 32'd0;
        peak_fill       = 16'd0;
        reset_source_n  = 1'b0;

        #100;
        reset_source_n = 1'b1;

        // --- 1. collect_data before the SDRAM is ready ----------------------
        wait_us(50.0);
        check(status_version, 1, "status layout version");
        check(status_initialised, 0, "SDRAM not initialised 50 us after reset");
        check(status_active, 0, "bypassed before collect_data");
        collect_data = 1'b1;
        wait_us(100.0);
        check(status_active, 0, "still bypassed: the SDRAM is not ready");
        check(status_initialised, 0, "still not initialised at 150 us");
        check(gaps, 0, "an unbroken stream while bypassed");
        wait (status_initialised === 1'b1);
        $display("1. SDRAM initialised at %0.1f us", $realtime / 1000.0);
        wait_us(5.0);
        check(status_active, 1, "the path is in use once initialised");
        wait_us(200.0);
        check(gaps, 0, "no break across the switch into the SDRAM path");
        check(consumed > 0, 1, "the FX3 is receiving");
        check(status_lost, 0, "nothing lost");

        // --- 2. Steady state ------------------------------------------------
        take_reading;
        run_checking_fill(500.0);
        take_reading;
        $display("2. steady state: buffer.v peak %0d words, near-full %0d, fill peak %0d rows",
                 telemetry_peak, telemetry_near_full, peak_fill);
        check(gaps, 0, "no break in steady state");
        check(telemetry_peak <= BUFFER_LIMIT, 1, "buffer.v held at one packet");
        check(telemetry_near_full, 0, "buffer.v never near full");
        check(telemetry_overflows, 0, "no overflow in steady state");

        // --- 3. Stalls that fit ---------------------------------------------
        peak_fill = 16'd0;
        for (i = 0; i < 4; i = i + 1) begin
            peak_fill = 16'd0;
            stall     = 100 + ((random_word(1'b0) & 32'h7FFF) % 400);
            stalled   = 1'b1;
            run_checking_fill(stall * 1.0);
            // Two FIFOs and buffer.v's packet hold about 300 us between them; a
            // stall longer than that has to reach the ring
            if (stall >= 350) begin
                check(peak_fill > 0, 1, "a stall builds a backlog in the SDRAM");
            end
            stalled = 1'b0;
            wait (status_fill == 16'd0);
            run_checking_fill(100.0);
            $display("3. stall of %0d us: fill peak %0d rows, stream unbroken", stall, peak_fill);
        end
        check(gaps, 0, "no break through stalls that fit");
        check(status_lost, 0, "nothing lost through stalls that fit");
        check(buffer_error, 0, "no error through stalls that fit");

        // --- 4. A stall the path cannot hold --------------------------------
        take_reading;
        gaps_before = gaps;
        stalled     = 1'b1;
        run_checking_fill(1500.0);
        check(status_fill, RING_ROWS, "the ring is full");
        check(status_lost, 1, "the sticky loss bit is set");
        check(buffer_error, 1, "buffer_error is raised while samples are lost");

        // The drain: from a full ring back to empty, with samples still
        // arriving at 40 MSPS
        stalled = 1'b0;
        wait (status_fill < RING_ROWS);
        start_time  = $realtime;
        produced_at = produced;
        path_at     = in_path(1'b0);
        gap_before  = consumed;
        wait (status_fill == 16'd0);
        drain_time = $realtime - start_time;
        rate_net   = (path_at - in_path(1'b0)) / (drain_time / 1000.0);
        rate_out   = (consumed - gap_before) / (drain_time / 1000.0);
        run_checking_fill(200.0);
        take_reading;

        $display("4. overflow: %0d run(s) lost, %0d words; instrument %0d overflow(s), %0d dropped",
                 gaps - gaps_before, last_gap, telemetry_overflows, telemetry_dropped);
        $display("   drain of %0d rows in %0.1f us: net %0.1f Mwords/s, delivered %0.1f Mwords/s",
                 RING_ROWS, drain_time / 1000.0, rate_net, rate_out);
        check(gaps - gaps_before, 1, "an overflow loses one contiguous run");
        check(telemetry_overflows, 1, "the instrument counts one overflow");
        check({16'd0, telemetry_dropped}, last_gap, "the instrument's dropped count is the run");
        check(rate_net > 30.0, 1, "the backlog drains at more than 30 Mwords/s net");
        check(buffer_error, 0, "buffer_error falls once samples stop being lost");
        check(status_lost, 1, "the sticky bit stays set");

        gaps_before = gaps;
        run_checking_fill(300.0);
        check(gaps - gaps_before, 0, "the stream is contiguous after the overflow");

        // --- 5. collect_data falling with a backlog -------------------------
        stalled = 1'b1;
        run_checking_fill(300.0);
        check(status_fill > 4, 1, "a backlog before the stop");
        gaps_before  = gaps;
        collect_data = 1'b0;
        wait_us(1.0);
        check(status_active, 0, "bypassed at once when collect_data falls");
        stalled = 1'b0;
        wait_us(400.0);
        check(status_fill, 0, "the SDRAM is emptied when collect_data falls");
        check(gaps - gaps_before, 1, "the discarded contents are one contiguous run");
        $display("5. stop with a backlog: %0d words discarded, stream continues bypassed",
                 last_gap);

        // --- 6. collect_data rising -----------------------------------------
        gaps_before  = gaps;
        collect_data = 1'b1;
        wait_us(5.0);
        check(status_active, 1, "the path is in use again");
        check(status_lost, 0, "the sticky bit is cleared by a new capture");
        run_checking_fill(300.0);
        check(gaps - gaps_before, 0, "no break across the switch back into the path");

        // --- 7. Stop and start within a microsecond, with a backlog ---------
        stalled = 1'b1;
        run_checking_fill(300.0);
        check(status_fill > 4, 1, "a backlog before the restart");
        gaps_before  = gaps;
        collect_data = 1'b0;
        #(400.0);
        collect_data = 1'b1;
        stalled      = 1'b0;
        wait_us(600.0);
        check(status_active, 1, "the path is in use after the restart");
        check(gaps - gaps_before, 1,
              "one run discarded by the restart, and nothing stale after it");
        run_checking_fill(200.0);
        check(gaps - gaps_before, 1, "still one run");
        $display("7. restart within a microsecond: %0d words discarded, no stale data after it",
                 last_gap);

        // The same early in the recovery from a full ring, when the ingress
        // FIFO is still deep and the egress FIFO nearly empty. The controller
        // can then acknowledge the flush - it has finished its operation and
        // sees the egress FIFO empty - while it is still discarding the
        // ingress FIFO's contents, so a restart has to wait for the system
        // side's own view of the ingress FIFO to be empty as well. Anything
        // left behind would come out after the restart, out of order.
        stalled = 1'b1;
        wait ((status_fill == RING_ROWS) && dut.ingress_full);
        stalled = 1'b0;
        i       = 0;
        while (!((dut.egress_fifo.read_used <= 256) && (dut.ingress_write_used >= 512))
               && (i < 40000)) begin
            @(posedge clock);
            i = i + 1;
        end
        check(i < 40000, 1, "set-up: a deep ingress FIFO and a shallow egress FIFO");
        $display("7. restart early in a recovery: ingress %0d words, egress %0d words",
                 dut.ingress_write_used, dut.egress_fifo.read_used);
        errors_before = errors;
        collect_data  = 1'b0;
        #(400.0);
        collect_data = 1'b1;
        wait_us(800.0);
        check(status_active, 1, "the path is in use after the restart");
        check(errors - errors_before, 0, "nothing stale or out of order after the restart");

        // --- 8. Bypassed overflow -------------------------------------------
        // Stopping discards what the path holds, which the consumer meets
        // once buffer.v has delivered what it already had
        gaps_before  = gaps;
        collect_data = 1'b0;
        wait_us(500.0);
        check(status_active, 0, "bypassed");
        check(gaps - gaps_before, 1, "the stop discards the path's contents as one run");
        take_reading;
        gaps_before = gaps;
        stalled     = 1'b1;
        wait_us(400.0);
        check(buffer_error, 1, "a bypassed stall overflows buffer.v as before");
        check(status_lost, 0, "a bypassed overflow is not an SDRAM loss");
        stalled = 1'b0;
        wait_us(300.0);
        take_reading;
        check(gaps - gaps_before, 1, "a bypassed overflow loses one run");
        check(telemetry_overflows, 1, "the instrument counts it");
        check({16'd0, telemetry_dropped}, last_gap, "and counts what it cost");

        check(model.errors, 0, "protocol errors reported by the SDRAM model");
        $display("SDRAM model: %0d refreshes, refresh debt at most %0d, longest gap %0.2f us",
                 model.refresh_count, model.maximum_debt, model.maximum_refresh_gap / 1000.0);
        $display("%0d words delivered", consumed);

        if (errors != 0) begin
            $fatal(1, "tb_sdramBuffer: %0d check(s) failed", errors);
        end

        $display("tb_sdramBuffer: PASS");
        $finish;
    end

endmodule
