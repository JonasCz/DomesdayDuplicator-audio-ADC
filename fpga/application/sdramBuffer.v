/************************************************************************

    sdramBuffer.v

    SDRAM capture buffer
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    Puts the DE0-Nano's 32 MiB SDRAM between the sampling side and buffer.v,
    so that a USB stall is paid out of 0.42 s of storage at 40 MSPS rather
    than out of buffer.v's 205 us. The design is described in full in
    sdram-capture-buffer.md beside this file; what follows is what a reader
    of this module needs.

        sampling side (80 MHz)
          -> ingress FIFO  (80 -> 120 MHz)
          -> sdramController, a ring of 512-word rows in the SDRAM (120 MHz)
          -> egress FIFO   (120 -> 80 MHz)
          -> buffer.v -> FX3

    The path is only in use while the FX3 says a capture is running. The FX3
    drives collect_data high on the host's start request and low on its stop
    request; until this design it was wired to nothing. While it is low, and
    until the SDRAM has been initialised, every sample goes straight to
    buffer.v exactly as it did before the SDRAM existed - the same buffer,
    the same overflow behaviour - which is also what a host that never sends
    a start request gets.

    The reason for the switch is stale data. The host discards the first
    8 MB of a stream; 32 MiB of samples queued from before the start would be
    delivered after that, ending in a gap. So:

      - collect_data falling: samples go back to buffer.v on the next cycle,
        and whatever the SDRAM path still holds is discarded.
      - collect_data rising: once the path is empty, samples go into it. Every
        sample before the switch went to buffer.v directly and every sample
        after it comes out of the path later, so the switch cannot reorder.

    The path is emptied by draining it, not by resetting it. Resetting half of
    a dual-clock FIFO while the other half runs corrupts it, and resetting the
    controller in the middle of a burst would leave the SDRAM mid-command. So
    a flush is a four-phase handshake: this side raises flush_request, the
    controller finishes its current operation, empties the ring and discards
    the ingress FIFO's contents while this side discards the egress FIFO's,
    and the controller acknowledges once it sees the egress FIFO empty from
    its own side. This side then waits for its own view of the ingress FIFO
    to be empty too - the writer's view, which is the one that cannot be
    wrong about it - before calling the path clean.

    Starting is the second half of the same handshake: flush_request falls,
    and samples are sent into the path only once the acknowledgement has
    fallen as well, because until it has the controller may still be
    discarding what arrives.

    Samples are lost in one place only: the ingress FIFO, when it is full
    because the ring is full. That is reported as sample_lost, which buffer.v
    counts exactly as it counts its own overflows, so the register-based
    instrument and the error pin go on telling the truth. A loss is always a
    contiguous run of samples ending at the first one that finds room.

    Writes into buffer.v are held off once it holds BufferFillLimit words,
    which is one packet plus the two words the registered data_available
    takes to rise. That is where buffer.v's occupancy sits in a healthy
    capture without the SDRAM, so its instrument reads the same; a stall
    fills the SDRAM rather than buffer.v, and the stream's status word is
    what reports it.

    The status word, in the system clock domain:

        [23:20] layout version, 1
        [19]    the SDRAM path is carrying the samples
        [18]    the SDRAM has been initialised
        [17]    a sample was lost at the SDRAM since collect_data last rose
        [16]    zero
        [15:0]  rows of 512 words in the ring, 0 to 32768

    The ring fill and the initialisation flag cross from the controller's
    clock through a request-acknowledge handshake that runs continuously, so
    the word is refreshed every few hundred nanoseconds.

    Every register that samples a signal from the other clock domain is named
    *_meta, and DomesdayDuplicator.SDC constrains those paths by that name.

************************************************************************/

module sdramBuffer #(
    parameter integer RingRows              = 32768,
    parameter integer InitWaitCycles        = 25000,
    parameter integer RefreshIntervalCycles = 900,
    parameter integer IngressAddressBits    = 11,
    parameter integer EgressAddressBits     = 11,
    parameter integer BufferFillLimit       = 8194
) (
    // System clock side
    input reset_n,
    input clock,

    // The FX3's capture flag, straight from the pin
    input collect_data,

    // The sampling side: one word per strobe
    input        sample_strobe,
    input [15:0] sample_data,

    // buffer.v's write port and occupancy
    input  [14:0] buffer_used_words,
    output        buffer_write,
    output [15:0] buffer_data,

    // A sample was offered and the SDRAM path had no room for it
    output sample_lost,

    output [23:0] status,

    // Controller clock side
    input sdram_reset_n,
    input sdram_clock,

    output        sdram_cke,
    output        sdram_cs_n,
    output        sdram_ras_n,
    output        sdram_cas_n,
    output        sdram_we_n,
    output [ 1:0] sdram_ba,
    output [12:0] sdram_addr,
    output [ 1:0] sdram_dqm,
    output [15:0] sdram_dq_out,
    output        sdram_dq_oe,
    input  [15:0] sdram_dq_in
);

    localparam integer RowWords = 512;

    // The controller only starts a read when the egress FIFO has room for a
    // whole row plus the last few words of the previous one, which are still
    // in its capture pipeline when it decides
    localparam integer EgressInFlight = 8;

    localparam [31:0] RowValue = RowWords;
    localparam [31:0] EgressRoomValue = (1 << EgressAddressBits) - RowWords - EgressInFlight;
    localparam [31:0] BufferLimitValue = BufferFillLimit;

    localparam [IngressAddressBits:0] IngressRow = RowValue[IngressAddressBits:0];
    localparam [EgressAddressBits:0] EgressRoomUsed = EgressRoomValue[EgressAddressBits:0];
    localparam [14:0] BufferLimit = BufferLimitValue[14:0];

    localparam [3:0] StatusVersion = 4'd1;

    // =======================================================================
    // System clock side
    // =======================================================================

    // collect_data is an FX3 GPIO with no relationship to this clock
    reg  collect_data_meta;
    reg  collect_data_sync;
    reg  collect_data_last;

    // The flush handshake, this side's half
    reg  flush_request;
    reg  flush_ack_meta;
    reg  flush_ack_sync;

    wire flush_ack;

    // PathFlushing  flush requested; waiting for the path to be empty
    // PathClean     empty, and held empty; waiting for collect_data
    // PathStarting  flush released; waiting for the controller to see it
    // PathActive    samples go into the SDRAM path
    localparam [1:0] PathFlushing = 2'd0;
    localparam [1:0] PathClean = 2'd1;
    localparam [1:0] PathStarting = 2'd2;
    localparam [1:0] PathActive = 2'd3;

    reg  [                 1:0] path_state;

    wire                        path_active = (path_state == PathActive);

    wire                        ingress_full;
    wire [IngressAddressBits:0] ingress_write_used;

    wire [                15:0] egress_data;
    wire                        egress_empty;

    // Into the path, or lost at its door
    wire                        ingress_write = path_active && sample_strobe;
    assign sample_lost = path_active && sample_strobe && ingress_full;

    // Out of the path. While the path is not in use its output is discarded,
    // which is how the egress FIFO is emptied by a flush.
    wire egress_read = !egress_empty && (!path_active || (buffer_used_words < BufferLimit));

    assign buffer_write = path_active ? egress_read : sample_strobe;
    assign buffer_data  = path_active ? egress_data : sample_data;

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            collect_data_meta <= 1'b0;
            collect_data_sync <= 1'b0;
            collect_data_last <= 1'b0;
            flush_ack_meta    <= 1'b0;
            flush_ack_sync    <= 1'b0;
        end else begin
            collect_data_meta <= collect_data;
            collect_data_sync <= collect_data_meta;
            collect_data_last <= collect_data_sync;
            flush_ack_meta    <= flush_ack;
            flush_ack_sync    <= flush_ack_meta;
        end
    end

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            path_state    <= PathFlushing;
            flush_request <= 1'b1;
        end else begin
            case (path_state)
                PathFlushing: begin
                    if (flush_ack_sync && (ingress_write_used == {(IngressAddressBits + 1) {1'b0}})
                        && egress_empty) begin
                        path_state <= PathClean;
                    end
                end

                PathClean: begin
                    if (collect_data_sync) begin
                        path_state    <= PathStarting;
                        flush_request <= 1'b0;
                    end
                end

                PathStarting: begin
                    // The acknowledgement must fall before anything else
                    // happens, so that the next one seen is a new one
                    if (!flush_ack_sync) begin
                        if (collect_data_sync) begin
                            path_state <= PathActive;
                        end else begin
                            path_state    <= PathFlushing;
                            flush_request <= 1'b1;
                        end
                    end
                end

                default: begin
                    // PathActive
                    if (!collect_data_sync) begin
                        path_state    <= PathFlushing;
                        flush_request <= 1'b1;
                    end
                end
            endcase
        end
    end

    // Sticky loss, cleared when a capture starts. A loss needs the path to be
    // active and the path cannot be active on the edge collect_data rises, so
    // the two never coincide.
    reg lost_since_start;

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            lost_since_start <= 1'b0;
        end else if (sample_lost) begin
            lost_since_start <= 1'b1;
        end else if (collect_data_sync && !collect_data_last) begin
            lost_since_start <= 1'b0;
        end
    end

    // The status handshake, receiving half. The controller side changes
    // status_hold only after this side has taken the previous value, so it is
    // stable whenever status_request_sync says there is something new.
    reg         status_request_meta;
    reg         status_request_sync;
    reg         status_ack;
    reg  [15:0] status_fill;
    reg         status_initialised;

    wire        status_request;
    wire [16:0] status_hold;

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            status_request_meta <= 1'b0;
            status_request_sync <= 1'b0;
            status_ack          <= 1'b0;
            status_fill         <= 16'd0;
            status_initialised  <= 1'b0;
        end else begin
            status_request_meta <= status_request;
            status_request_sync <= status_request_meta;

            if (status_request_sync != status_ack) begin
                status_fill        <= status_hold[15:0];
                status_initialised <= status_hold[16];
                status_ack         <= status_request_sync;
            end
        end
    end

    assign status = {
        StatusVersion, path_active, status_initialised, lost_since_start, 1'b0, status_fill
    };

    // =======================================================================
    // The two FIFOs
    // =======================================================================

    wire                        ingress_read;
    wire [                15:0] ingress_data;
    wire                        ingress_empty_unused;
    wire [IngressAddressBits:0] ingress_read_used;

    wire                        egress_write;
    wire [                15:0] egress_write_data;
    wire                        egress_full_unused;
    wire [ EgressAddressBits:0] egress_write_used;
    wire [ EgressAddressBits:0] egress_read_used_unused;

    asyncFifo #(
        .DataWidth  (16),
        .AddressBits(IngressAddressBits)
    ) ingress_fifo (
        .write_reset_n(reset_n),
        .write_clock  (clock),
        .write_request(ingress_write),
        .write_data   (sample_data),
        .write_full   (ingress_full),
        .write_used   (ingress_write_used),
        .read_reset_n (sdram_reset_n),
        .read_clock   (sdram_clock),
        .read_request (ingress_read),
        .read_data    (ingress_data),
        .read_empty   (ingress_empty_unused),
        .read_used    (ingress_read_used)
    );

    asyncFifo #(
        .DataWidth  (16),
        .AddressBits(EgressAddressBits)
    ) egress_fifo (
        .write_reset_n(sdram_reset_n),
        .write_clock  (sdram_clock),
        .write_request(egress_write),
        .write_data   (egress_write_data),
        .write_full   (egress_full_unused),
        .write_used   (egress_write_used),
        .read_reset_n (reset_n),
        .read_clock   (clock),
        .read_request (egress_read),
        .read_data    (egress_data),
        .read_empty   (egress_empty),
        .read_used    (egress_read_used_unused)
    );

    // =======================================================================
    // Controller clock side
    // =======================================================================

    reg         flush_request_meta;
    reg         flush_request_sync;
    reg         status_ack_meta;
    reg         status_ack_sync;
    reg         status_request_toggle;
    reg  [16:0] status_hold_register;

    wire        controller_init_done;
    wire [15:0] controller_ring_fill;

    always @(posedge sdram_clock, negedge sdram_reset_n) begin
        if (!sdram_reset_n) begin
            // Held flushing until the system side says otherwise, which is
            // also what it asks for out of reset
            flush_request_meta    <= 1'b1;
            flush_request_sync    <= 1'b1;
            status_ack_meta       <= 1'b0;
            status_ack_sync       <= 1'b0;
            status_request_toggle <= 1'b0;
            status_hold_register  <= 17'd0;
        end else begin
            flush_request_meta <= flush_request;
            flush_request_sync <= flush_request_meta;
            status_ack_meta    <= status_ack;
            status_ack_sync    <= status_ack_meta;

            // The previous value has been taken: offer the next one
            if (status_ack_sync == status_request_toggle) begin
                status_hold_register  <= {controller_init_done, controller_ring_fill};
                status_request_toggle <= ~status_request_toggle;
            end
        end
    end

    assign status_request = status_request_toggle;
    assign status_hold    = status_hold_register;

    sdramController #(
        .RingRows             (RingRows),
        .InitWaitCycles       (InitWaitCycles),
        .RefreshIntervalCycles(RefreshIntervalCycles)
    ) sdram_controller_0 (
        .reset_n        (sdram_reset_n),
        .clock          (sdram_clock),
        .ingress_has_row(ingress_read_used >= IngressRow),
        .ingress_data   (ingress_data),
        .ingress_read   (ingress_read),
        .egress_has_room(egress_write_used <= EgressRoomUsed),
        .egress_drained (egress_write_used == {(EgressAddressBits + 1) {1'b0}}),
        .egress_write   (egress_write),
        .egress_data    (egress_write_data),
        .flush          (flush_request_sync),
        .flush_ack      (flush_ack),
        .init_done      (controller_init_done),
        .ring_fill      (controller_ring_fill),
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
        .sdram_dq_in    (sdram_dq_in)
    );

endmodule
