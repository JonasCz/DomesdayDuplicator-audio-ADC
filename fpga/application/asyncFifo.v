/************************************************************************

    asyncFifo.v

    Dual-clock FIFO
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    The SDRAM capture buffer runs its controller from a 120 MHz clock and
    everything else from the 80 MHz system clock, so the samples have to
    cross between the two twice. This is the FIFO they cross in. It is
    written here rather than taken from Altera's dcfifo for the same reason
    fifo.v replaced that IP: dcfifo has no free simulation model, and a FIFO
    that cannot be simulated is a capture path that cannot be tested.

    The design is the textbook one, kept textbook on purpose:

      - Each side keeps a binary pointer one bit wider than the address, so
        that full and empty can be told apart, and publishes it as a Gray
        code from a register. A Gray count changes one bit per increment, so
        a pointer sampled by the other clock in the middle of a change reads
        as either its old or its new value and never as anything else.
      - Each side takes the other's Gray pointer through two flip-flops before
        using it. The first stage is the only one that can go metastable; the
        registers are named *_meta so the constraints can find them.
      - Every flag and count is computed from the far pointer as it was some
        cycles ago, which can only make it pessimistic: the write side may
        report full when a word has just been taken, and the read side may
        report empty when a word has just been written, but neither can ever
        report room or data that is not there.

    Both counts are registered and are computed from the pointer as it will be
    after this edge, so they are pessimistic by the synchroniser delay and by
    nothing else. In particular write_used reaching zero is a proof that the
    reader has taken every word that was written, because it can only be zero
    once the reader's own pointer has crossed back and caught up. The flush in
    sdramBuffer.v depends on exactly that.

    Show-ahead, like fifo.v: read_data already presents the word at the head
    of the queue while read_empty is low, and read_request acknowledges it.

    There is no write-to-read bypass, which fifo.v needs and this does not. A
    word only becomes visible to the reader two read clocks after it was
    written, by which time the registered memory read of its address has
    been repeated at least once with the write long finished.

    Depth is a power of two, 2^AddressBits, because Gray pointers only wrap
    correctly at one.

    The two resets must be asserted together. Asserting one side alone would
    leave the other side's pointer describing words that are no longer there.
    In this design both come from the same asynchronous source, released by a
    synchroniser in each clock domain.

************************************************************************/

module asyncFifo #(
    parameter integer DataWidth   = 16,
    parameter integer AddressBits = 11
) (
    // Write side. A write while write_full is discarded.
    input                      write_reset_n,
    input                      write_clock,
    input                      write_request,
    input      [DataWidth-1:0] write_data,
    output reg                 write_full,
    output reg [AddressBits:0] write_used,

    // Read side. read_data is already valid while read_empty is low;
    // read_request advances past it.
    input                      read_reset_n,
    input                      read_clock,
    input                      read_request,
    output     [DataWidth-1:0] read_data,
    output reg                 read_empty,
    output reg [AddressBits:0] read_used
);

    localparam integer Depth = 1 << AddressBits;

    // Sized constants, made by part-selecting a 32-bit value for the reason
    // given at the head of fifo.v
    localparam [31:0] DepthValue = Depth;
    localparam [AddressBits:0] DepthWords = DepthValue[AddressBits:0];
    localparam [AddressBits:0] PointerZero = {(AddressBits + 1) {1'b0}};

    function [AddressBits:0] binary_to_gray;
        input [AddressBits:0] binary;
        begin
            binary_to_gray = binary ^ (binary >> 1);
        end
    endfunction

    function [AddressBits:0] gray_to_binary;
        input [AddressBits:0] gray;
        integer bit_index;
        begin
            gray_to_binary[AddressBits] = gray[AddressBits];
            for (bit_index = AddressBits - 1; bit_index >= 0; bit_index = bit_index - 1) begin
                gray_to_binary[bit_index] = gray_to_binary[bit_index+1] ^ gray[bit_index];
            end
        end
    endfunction

    // Storage ---------------------------------------------------------------
    //
    // A simple dual-port memory with one clock per port, which is the form
    // Quartus infers as an M9K in dual-clock mode. No reset and no initial
    // contents, for the reasons given in fifo.v.

    reg  [DataWidth-1:0] memory                                                       [0:Depth-1];
    reg  [DataWidth-1:0] memory_data_out;

    // Pointers ----------------------------------------------------------------
    //
    // Each side's binary pointer and the Gray copy it publishes, and the two
    // stages that bring the other side's Gray copy in.

    reg  [AddressBits:0] write_binary;
    reg  [AddressBits:0] write_gray;
    reg  [AddressBits:0] read_gray_meta;
    reg  [AddressBits:0] read_gray_sync;

    reg  [AddressBits:0] read_binary;
    reg  [AddressBits:0] read_gray;
    reg  [AddressBits:0] write_gray_meta;
    reg  [AddressBits:0] write_gray_sync;

    // Write side --------------------------------------------------------------

    wire                 write_enable = write_request && !write_full;

    wire [AddressBits:0] write_increment = {PointerZero[AddressBits:1], write_enable};
    wire [AddressBits:0] write_binary_next = write_binary + write_increment;
    wire [AddressBits:0] read_binary_seen = gray_to_binary(read_gray_sync);
    wire [AddressBits:0] write_used_next = write_binary_next - read_binary_seen;

    always @(posedge write_clock) begin
        if (write_enable) begin
            memory[write_binary[AddressBits-1:0]] <= write_data;
        end
    end

    always @(posedge write_clock, negedge write_reset_n) begin
        if (!write_reset_n) begin
            write_binary   <= PointerZero;
            write_gray     <= PointerZero;
            read_gray_meta <= PointerZero;
            read_gray_sync <= PointerZero;
            write_used     <= PointerZero;
            write_full     <= 1'b0;
        end else begin
            write_binary   <= write_binary_next;
            write_gray     <= binary_to_gray(write_binary_next);
            read_gray_meta <= read_gray;
            read_gray_sync <= read_gray_meta;
            write_used     <= write_used_next;
            write_full     <= (write_used_next == DepthWords);
        end
    end

    // Read side ---------------------------------------------------------------

    wire                 read_enable = read_request && !read_empty;

    wire [AddressBits:0] read_increment = {PointerZero[AddressBits:1], read_enable};
    wire [AddressBits:0] read_binary_next = read_binary + read_increment;
    wire [AddressBits:0] write_binary_seen = gray_to_binary(write_gray_sync);
    wire [AddressBits:0] read_used_next = write_binary_seen - read_binary_next;

    // The address the head will be at after this edge, read ahead so that the
    // head word is already on read_data when the next cycle starts
    always @(posedge read_clock) begin
        memory_data_out <= memory[read_binary_next[AddressBits-1:0]];
    end

    assign read_data = memory_data_out;

    always @(posedge read_clock, negedge read_reset_n) begin
        if (!read_reset_n) begin
            read_binary     <= PointerZero;
            read_gray       <= PointerZero;
            write_gray_meta <= PointerZero;
            write_gray_sync <= PointerZero;
            read_used       <= PointerZero;
            read_empty      <= 1'b1;
        end else begin
            read_binary     <= read_binary_next;
            read_gray       <= binary_to_gray(read_binary_next);
            write_gray_meta <= write_gray;
            write_gray_sync <= write_gray_meta;
            read_used       <= read_used_next;
            read_empty      <= (read_used_next == PointerZero);
        end
    end

endmodule
