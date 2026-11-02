/************************************************************************

    tb_asyncFifo.v

    Testbench for the dual-clock FIFO (T3)
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    The FIFO the capture stream crosses between the 80 MHz system clock and
    the SDRAM controller's 120 MHz clock, twice. What a capture depends on is
    that no word is lost, repeated or reordered at any ratio of the two
    clocks, and that the flags and counts only ever err on the safe side:

      - every word written comes out, once, in order
      - a write is refused only when the FIFO really is full: the writer
        never sees write_full with room to spare beyond the synchroniser's
        lag, and never writes into a full FIFO
      - read_used never claims a word that has not been written, and
        write_used never claims room that has not been freed, which is what
        lets the controller start a 512-word burst on read_used alone
      - write_used reaching zero means the reader really has taken every
        word, which the flush in sdramBuffer.v depends on
      - full is reached at exactly the depth, from the writer's side, once
        the reader has stopped

    Each scenario runs the two clocks at a different ratio, from a fresh
    reset, with the writer and reader each acting on a random fraction of
    their edges - including the 80 and 120 MHz the design uses, both ways
    round, and ratios that do not divide.

    The depth is 16 words so that full and empty are reached constantly;
    the design's FIFOs are 2048, which differs only in the pointer width.

************************************************************************/

`timescale 1ns / 1ps

module tb_asyncFifo;

    localparam integer ADDRESS_BITS = 4;
    localparam integer DEPTH = 1 << ADDRESS_BITS;

    // Words moved per scenario
    localparam integer TRANSFERS = 40000;

    reg                   write_reset_n;
    reg                   read_reset_n;
    reg                   write_clock;
    reg                   read_clock;

    reg                   write_request;
    reg  [          15:0] write_data;
    wire                  write_full;
    wire [ADDRESS_BITS:0] write_used;

    reg                   read_request;
    wire [          15:0] read_data;
    wire                  read_empty;
    wire [ADDRESS_BITS:0] read_used;

    asyncFifo #(
        .DataWidth  (16),
        .AddressBits(ADDRESS_BITS)
    ) dut (
        .write_reset_n(write_reset_n),
        .write_clock  (write_clock),
        .write_request(write_request),
        .write_data   (write_data),
        .write_full   (write_full),
        .write_used   (write_used),
        .read_reset_n (read_reset_n),
        .read_clock   (read_clock),
        .read_request (read_request),
        .read_data    (read_data),
        .read_empty   (read_empty),
        .read_used    (read_used)
    );

    // Clocks, each with its own half period, which a scenario sets
    real write_half;
    real read_half;
    reg  clocks_running;

    initial begin
        write_clock = 1'b0;
        read_clock  = 1'b0;
    end

    always begin
        #(write_half) write_clock = ~write_clock;
    end

    always begin
        #(read_half) read_clock = ~read_clock;
    end

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

    // The truth, kept by the testbench: how many words have gone in and come
    // out, counted on the edges at which they did
    integer        written;
    integer        read_count;
    integer        write_percent;
    integer        read_percent;

    // How many words the reader can take in the time the writer's view of it
    // lags: three write clocks, at the reader's rate, plus one either side
    integer        full_slack;
    reg            running;
    reg            draining;
    reg     [15:0] next_write;
    reg     [15:0] next_read;

    task fail;
        input [511:0] message;
        begin
            errors = errors + 1;
            if (reported < 20) begin
                $display("FAIL: %0s (t=%0t)", message, $time);
                reported = reported + 1;
            end
        end
    endtask

    // Writer. Requests on a random fraction of edges, and only when it
    // believes there is room - which is how the design's writer behaves - and
    // also, on some edges, regardless, to show a write into a full FIFO is
    // discarded rather than corrupting it.
    reg write_regardless;

    always @(posedge write_clock) begin
        // The FIFO's view as it stood before this edge, against the truth
        // before this edge's write. write_used counts words written and not
        // yet seen to have been read, so it can never be less than the true
        // occupancy, and it can only exceed it by what the reader took during
        // the synchroniser's lag.
        if (write_reset_n && (write_used < (written - read_count))) begin
            fail("write_used claims room that has not been freed");
        end
        if (write_reset_n && (write_used > DEPTH)) begin
            fail("write_used beyond the depth");
        end
        if (write_reset_n && write_full && ((written - read_count) < DEPTH - full_slack)) begin
            fail("write_full with more room than the synchroniser lag accounts for");
        end
        if (write_reset_n && (write_used == 0) && (written != read_count)) begin
            fail("write_used reads zero with words still in the FIFO");
        end

        if (write_request && !write_full) begin
            written    = written + 1;
            next_write = next_write + 16'd1;
        end

        #0.1;
        write_data = next_write;
        write_regardless = ((random_word(1'b0) & 32'h7) == 0);
        write_request = running && (written < TRANSFERS) &&
            (((random_word(1'b0) & 32'h7F) % 100) < write_percent) &&
            (!write_full || write_regardless);
    end

    // Reader. Checks the head word whenever it takes one.
    always @(posedge read_clock) begin
        // As for the writer: the view before this edge, against the truth
        // before this edge's read
        if (read_reset_n && (read_used > (written - read_count))) begin
            fail("read_used claims a word that has not been written");
        end
        if (read_reset_n && !read_empty && (written == read_count)) begin
            fail("read_empty is low with nothing written");
        end

        if (read_request && !read_empty) begin
            if (read_data !== next_read) begin
                fail("word out of order, lost or repeated");
                $display("      got %h expected %h", read_data, next_read);
                next_read = read_data;
            end
            next_read  = next_read + 16'd1;
            read_count = read_count + 1;
        end

        #0.1;
        read_request = (running || draining) &&
            (((random_word(1'b0) & 32'h7F) % 100) < read_percent);
    end

    task scenario;
        input real write_mhz;
        input real read_mhz;
        input integer write_busy;
        input integer read_busy;
        begin
            running       = 1'b0;
            draining      = 1'b0;
            write_request = 1'b0;
            read_request  = 1'b0;
            write_half    = 500.0 / write_mhz;
            read_half     = 500.0 / read_mhz;
            write_percent = write_busy;
            read_percent  = read_busy;
            full_slack    = $rtoi(3.0 * read_mhz / write_mhz) + 2;

            // Both halves reset together, as the design does it
            write_reset_n = 1'b0;
            read_reset_n  = 1'b0;
            #100;
            written    = 0;
            read_count = 0;
            next_write = 16'h0000;
            next_read  = 16'h0000;
            write_data = 16'h0000;
            #100;
            write_reset_n = 1'b1;
            #(write_half * 3.3);
            read_reset_n = 1'b1;
            #100;

            running = 1'b1;
            wait (written >= TRANSFERS);
            running      = 1'b0;
            draining     = 1'b1;
            read_percent = 100;
            wait (read_count == written);
            #1000;
            draining = 1'b0;

            if (read_count != TRANSFERS) begin
                fail("not every word came out");
            end
            if (!read_empty) begin
                fail("read_empty is not set once everything has been read");
            end
            if (write_used != 0) begin
                fail("write_used is not zero once everything has been read");
            end

            $display("  write %0.1f MHz at %0d%%, read %0.1f MHz at %0d%%: %0d words in order",
                     write_mhz, write_busy, read_mhz, read_busy, read_count);
        end
    endtask

    integer i;

    initial begin
        errors        = 0;
        reported      = 0;
        full_slack    = 6;
        seed          = 32'h0A51_F1F0;
        write_half    = 6.25;
        read_half     = 4.167;
        running       = 1'b0;
        draining      = 1'b0;
        write_request = 1'b0;
        read_request  = 1'b0;
        write_data    = 16'h0000;
        written       = 0;
        read_count    = 0;
        next_write    = 16'h0000;
        next_read     = 16'h0000;
        write_reset_n = 1'b0;
        read_reset_n  = 1'b0;

        // The design's two crossings, at their real clocks
        scenario(80.0, 120.0, 50, 60);
        scenario(120.0, 80.0, 60, 70);

        // Writer faster than the reader can take, and the reverse, so the FIFO
        // lives at full and at empty respectively
        scenario(80.0, 120.0, 100, 30);
        scenario(120.0, 80.0, 20, 100);

        // Ratios that do not divide, both ways round, and equal frequencies
        // whose edges drift past each other
        scenario(100.0, 33.0, 30, 95);
        scenario(33.0, 100.0, 95, 30);
        scenario(50.0, 50.3, 70, 70);
        scenario(13.0, 97.0, 100, 15);

        // --- Full at exactly the depth --------------------------------------
        // The reader stops; the writer writes until refused. Once the
        // pointers have settled the FIFO holds exactly DEPTH words, and
        // reports so, from both sides.
        running       = 1'b0;
        write_half    = 6.25;
        read_half     = 4.167;
        full_slack    = 6;
        write_reset_n = 1'b0;
        read_reset_n  = 1'b0;
        #100;
        written       = 0;
        read_count    = 0;
        next_write    = 16'h0000;
        next_read     = 16'h0000;
        write_reset_n = 1'b1;
        read_reset_n  = 1'b1;
        #100;
        write_percent = 100;
        read_percent  = 0;
        running       = 1'b1;
        #2000;
        running = 1'b0;
        #200;
        if (written != DEPTH) begin
            fail("a stopped reader does not hold the FIFO at exactly its depth");
        end
        if (!write_full || (write_used != DEPTH)) begin
            fail("the writer does not see a full FIFO as full");
        end
        if (read_used != DEPTH) begin
            fail("the reader does not count a full FIFO as full");
        end
        draining     = 1'b1;
        read_percent = 100;
        wait (read_count == written);
        #200;
        draining = 1'b0;
        if (!read_empty || (write_used != 0) || write_full) begin
            fail("drained FIFO does not read as empty from both sides");
        end
        $display("  full at exactly %0d words, and empty again after", DEPTH);

        if (errors != 0) begin
            $fatal(1, "tb_asyncFifo: %0d check(s) failed", errors);
        end

        $display("tb_asyncFifo: PASS");
        $finish;
    end

endmodule
