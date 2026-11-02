/************************************************************************

    sdramController.v

    SDRAM ring controller for the capture buffer
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    Drives the DE0-Nano's IS42S16160B (256 Mb, x16, four banks of 8192 rows
    of 512 columns) as one thing only: a ring of whole rows, filled from the
    ingress FIFO and emptied into the egress FIFO, oldest row first. There is
    no address bus, no random access and no bank interleaving, because the
    capture stream needs none of them, and every one of them would be a way
    for this module to be wrong.

    Runs on its own 120 MHz clock. One row moved costs about 520 cycles, so
    the part carries about 117 Mwords/s once refresh is paid for - enough for
    the 40 Mwords/s coming in and 77 Mwords/s going out. At the 80 MHz system
    clock it would carry 78 Mwords/s, which is less than the 80 a capture
    needs in steady state. The arithmetic is in sdram-capture-buffer.md.

    Every timing figure below is the -7 speed grade's, rounded up to whole
    8.33 ns cycles. The -7 is the slowest grade the IS42S16160B is sold in;
    which grade a given DE0-Nano carries is not something this design asks.

        tRCD 20 ns -> 3    tRP 20 ns -> 3     tRC 67.5 ns -> 9
        tRAS 45 ns -> 6    tDPL 14 ns -> 2    tMRD 15 ns -> 2
        CAS latency 3, which -7 supports to 143 MHz

    The sequence for each kind of operation is a fixed list of commands at
    fixed step numbers, decoded from (state, step) and registered on the way
    out, so that every command, address, mask and data bit leaves the FPGA
    from a register that can sit in the pin's I/O cell. Nothing about the
    timing is computed at run time.

    A row write: ACT; WRITE at column 0 three cycles later, as a full-page
    burst carrying the first word, then one word per cycle; BURST STOP on the
    cycle after the 512th word, which the part ignores the data of; PRECHARGE
    two cycles after the last word (tDPL). DQM is high on the stop and the
    precharge, so neither the wrap to column 0 nor anything on the bus in
    those cycles can reach the array.

    A row read: ACT; READ at column 0 three cycles later, full page;
    PRECHARGE 512 cycles after the READ, which is CAS latency minus one
    cycles before the last word is valid - the datasheet's rule for
    truncating a full-page read - so exactly 512 words come out.

    Arbitration happens only between operations, never inside one, in this
    order: refresh, then a flush in progress, then a row write if the ingress
    FIFO holds a whole row and the ring has room, then a row read if the ring
    holds a row and the egress FIFO has room for it. Writes before reads,
    because a write that waits is a FIFO filling and a read that waits is
    only a host waiting.

    Refresh: one credit every RefreshIntervalCycles (7.5 us, against the
    datasheet's 7.8 us average for 8192 per 64 ms), served at the next
    operation boundary. The longest operation is a row write at 519 cycles,
    so a credit waits at most 4.3 us and never more than one is outstanding.

************************************************************************/

module sdramController #(
    // Rows in the ring. 32768 is the whole part; testbenches use a few dozen
    parameter integer RingRows              = 32768,
    // Cycles of NOP before the first command: at least 200 us
    parameter integer InitWaitCycles        = 25000,
    // Cycles between refresh credits
    parameter integer RefreshIntervalCycles = 900
) (
    input reset_n,
    input clock,

    // Ingress FIFO, read side. ingress_has_row is a pessimistic count, so
    // a row write never starts without all 512 words already queued.
    input         ingress_has_row,
    input  [15:0] ingress_data,
    output        ingress_read,

    // Egress FIFO, write side. egress_has_room must allow for the words still
    // in the capture pipeline from the previous read as well as a whole row.
    // egress_drained is the write side's own view of an empty FIFO, which is
    // the only view that proves the reader has taken everything.
    input         egress_has_room,
    input         egress_drained,
    output        egress_write,
    output [15:0] egress_data,

    // Flush: while flush is high the controller finishes the operation it is
    // in, empties the ring, discards everything the ingress FIFO offers and
    // starts nothing but refreshes. flush_ack says all of that is true and
    // that the egress FIFO is empty, and it stays high until flush falls.
    input      flush,
    output reg flush_ack,

    output reg        init_done,
    output     [15:0] ring_fill,

    // The SDRAM. All of these are registers; the top level maps them to pins
    // and the .qsf puts them in the I/O cells.
    output reg        sdram_cke,
    output reg        sdram_cs_n,
    output reg        sdram_ras_n,
    output reg        sdram_cas_n,
    output reg        sdram_we_n,
    output reg [ 1:0] sdram_ba,
    output reg [12:0] sdram_addr,
    output reg [ 1:0] sdram_dqm,
    output reg [15:0] sdram_dq_out,
    output reg        sdram_dq_oe,
    input      [15:0] sdram_dq_in
);

    // Commands, as {CS#, RAS#, CAS#, WE#} ------------------------------------

    localparam [3:0] CommandDeselect = 4'b1111;
    localparam [3:0] CommandNop = 4'b0111;
    localparam [3:0] CommandActive = 4'b0011;
    localparam [3:0] CommandRead = 4'b0101;
    localparam [3:0] CommandWrite = 4'b0100;
    localparam [3:0] CommandBurstStop = 4'b0110;
    localparam [3:0] CommandPrecharge = 4'b0010;
    localparam [3:0] CommandRefresh = 4'b0001;
    localparam [3:0] CommandModeRegister = 4'b0000;

    // Burst length full page (A2:A0 = 111), sequential (A3 = 0), CAS latency
    // 3 (A6:A4 = 011), standard operation (A8:A7 = 00), burst writes (A9 = 0),
    // and A12:A10 zero as the datasheet asks
    localparam [12:0] ModeRegister = 13'b000_0_00_011_0_111;

    // A10 high on a PRECHARGE closes every bank
    localparam [12:0] PrechargeAll = 13'b0_0100_0000_0000;

    // Timing, in 8.33 ns cycles ------------------------------------------------

    localparam [15:0] TRcdCycles = 16'd3;
    localparam [15:0] TRpCycles = 16'd3;
    localparam [15:0] TRcCycles = 16'd9;
    localparam [15:0] TMrdCycles = 16'd2;
    localparam [15:0] TDplCycles = 16'd2;
    localparam [15:0] RowWords = 16'd512;

    // Eight refreshes before the mode register, as the datasheet's power-up
    // sequence requires
    localparam [3:0] InitRefreshLast = 4'd7;

    // Step numbers. The command for (state, step) is on the bus in the cycle
    // after that step, so these are also the cycle offsets between commands.
    //
    // An operation ends by returning to StateIdle, which spends one cycle
    // there before the next operation's step 0. So a gap of G cycles after the
    // last command at step L is met by ending at step L + G - 2. The power-up
    // states go straight from one to the next and end at step G - 1.

    localparam [15:0] WriteCommandStep = TRcdCycles;
    localparam [15:0] WriteLastDataStep = WriteCommandStep + RowWords - 16'd1;
    localparam [15:0] WriteStopStep = WriteLastDataStep + 16'd1;
    localparam [15:0] WritePrechargeStep = WriteLastDataStep + TDplCycles;
    localparam [15:0] WriteLastStep = WritePrechargeStep + TRpCycles - 16'd2;

    localparam [15:0] ReadCommandStep = TRcdCycles;
    localparam [15:0] ReadLastWindowStep = ReadCommandStep + RowWords - 16'd1;
    localparam [15:0] ReadPrechargeStep = ReadCommandStep + RowWords;
    localparam [15:0] ReadLastStep = ReadPrechargeStep + TRpCycles - 16'd2;

    localparam [15:0] RefreshLastStep = TRcCycles - 16'd2;

    localparam [31:0] InitWaitValue = InitWaitCycles - 1;
    localparam [15:0] InitWaitLastStep = InitWaitValue[15:0];
    localparam [15:0] InitPrechargeLastStep = TRpCycles - 16'd1;
    localparam [15:0] InitRefreshLastStep = TRcCycles - 16'd1;
    localparam [15:0] InitModeLastStep = TMrdCycles - 16'd1;

    localparam [15:0] StepZero = 16'd0;
    localparam [15:0] StepOne = 16'd1;

    // The ring --------------------------------------------------------------

    localparam [31:0] RingRowsValue = RingRows;
    localparam [31:0] RingLastValue = RingRows - 1;
    localparam [15:0] RingFull = RingRowsValue[15:0];
    localparam [14:0] RingLastRow = RingLastValue[14:0];

    localparam [31:0] RefreshValue = RefreshIntervalCycles - 1;
    localparam [10:0] RefreshTimerLast = RefreshValue[10:0];

    // The capture pipeline. A READ registered on edge n is sampled by the
    // SDRAM on its next clock edge, which with DRAM_CLK leading the
    // controller clock falls just before edge n + 1. The first word comes out
    // CAS latency edges after that and is valid at the pin late in the cycle
    // before edge n + 4, which is the edge the input register in the pin's I/O
    // cell captures it on (the multicycle in DomesdayDuplicator.SDC is this
    // same statement). So the window that is high from the READ for 512
    // cycles, delayed by CAS latency plus one stages, is high in exactly the
    // cycles the captured words are valid.
    localparam integer CaptureStages = 4;

    // States ------------------------------------------------------------------

    localparam [3:0] StateInitWait = 4'd0;
    localparam [3:0] StateInitPrecharge = 4'd1;
    localparam [3:0] StateInitRefresh = 4'd2;
    localparam [3:0] StateInitMode = 4'd3;
    localparam [3:0] StateIdle = 4'd4;
    localparam [3:0] StateRefresh = 4'd5;
    localparam [3:0] StateWrite = 4'd6;
    localparam [3:0] StateRead = 4'd7;

    reg  [ 3:0] state;
    reg  [15:0] step;
    reg  [ 3:0] init_refresh_count;

    // The ring's two ends and how many rows lie between them. The row
    // number maps to the part as bank = low two bits, row = the rest, so that
    // even a test ring of a few dozen rows reaches all four banks.
    reg  [14:0] write_row;
    reg  [14:0] read_row;
    reg  [15:0] fill;
    reg  [14:0] operation_row;

    wire        ring_full = (fill == RingFull);
    wire        ring_empty = (fill == 16'd0);

    assign ring_fill = fill;

    reg flush_held;

    reg [10:0] refresh_timer;
    reg [3:0] refresh_pending;

    wire refresh_start = (state == StateIdle) && (refresh_pending != 4'd0);
    wire refresh_tick = init_done && (refresh_timer == RefreshTimerLast);

    // Decode ------------------------------------------------------------------

    wire write_data_step = (state == StateWrite)
        && (step >= WriteCommandStep) && (step <= WriteLastDataStep);

    // The ingress FIFO is show-ahead, so the word on ingress_data is the one
    // loaded into the data register on this edge, and the read takes it
    assign ingress_read = write_data_step || flush_held;

    reg [ 3:0] next_command;
    reg [ 1:0] next_bank;
    reg [12:0] next_address;
    reg [ 1:0] next_dqm;
    reg        next_dq_oe;
    reg        next_read_window;

    always @(*) begin
        next_command     = CommandNop;
        next_bank        = 2'd0;
        next_address     = 13'd0;
        next_dqm         = 2'b11;
        next_dq_oe       = 1'b0;
        next_read_window = 1'b0;

        case (state)
            StateInitPrecharge: begin
                if (step == StepZero) begin
                    next_command = CommandPrecharge;
                    next_address = PrechargeAll;
                end
            end

            StateInitRefresh: begin
                if (step == StepZero) begin
                    next_command = CommandRefresh;
                end
            end

            StateInitMode: begin
                if (step == StepZero) begin
                    next_command = CommandModeRegister;
                    next_address = ModeRegister;
                end
            end

            StateRefresh: begin
                if (step == StepZero) begin
                    next_command = CommandRefresh;
                end
            end

            StateWrite: begin
                next_bank = operation_row[1:0];

                if (step == StepZero) begin
                    next_command = CommandActive;
                    next_address = operation_row[14:2];
                end else if (step == WriteCommandStep) begin
                    next_command = CommandWrite;
                end else if (step == WriteStopStep) begin
                    next_command = CommandBurstStop;
                end else if (step == WritePrechargeStep) begin
                    next_command = CommandPrecharge;
                end

                if (write_data_step) begin
                    next_dqm   = 2'b00;
                    next_dq_oe = 1'b1;
                end
            end

            StateRead: begin
                next_bank = operation_row[1:0];
                next_dqm  = 2'b00;

                if (step == StepZero) begin
                    next_command = CommandActive;
                    next_address = operation_row[14:2];
                end else if (step == ReadCommandStep) begin
                    next_command = CommandRead;
                end else if (step == ReadPrechargeStep) begin
                    next_command = CommandPrecharge;
                end

                if ((step >= ReadCommandStep) && (step <= ReadLastWindowStep)) begin
                    next_read_window = 1'b1;
                end
            end

            default: begin
                // StateInitWait and StateIdle: NOP with DQM high
            end
        endcase
    end

    // The pins ------------------------------------------------------------------

    reg                     read_window;
    reg [CaptureStages-1:0] capture_pipe;

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            // Deselected, masked, not driving, and clock disabled until the
            // reset is released; the 200 us count starts with CKE high
            sdram_cke   <= 1'b0;
            sdram_cs_n  <= CommandDeselect[3];
            sdram_ras_n <= CommandDeselect[2];
            sdram_cas_n <= CommandDeselect[1];
            sdram_we_n  <= CommandDeselect[0];
            sdram_ba    <= 2'd0;
            sdram_addr  <= 13'd0;
            sdram_dqm   <= 2'b11;
            sdram_dq_oe <= 1'b0;
            read_window <= 1'b0;
        end else begin
            sdram_cke   <= 1'b1;
            sdram_cs_n  <= next_command[3];
            sdram_ras_n <= next_command[2];
            sdram_cas_n <= next_command[1];
            sdram_we_n  <= next_command[0];
            sdram_ba    <= next_bank;
            sdram_addr  <= next_address;
            sdram_dqm   <= next_dqm;
            sdram_dq_oe <= next_dq_oe;
            read_window <= next_read_window;
        end
    end

    // The data registers have no reset: what they hold while nothing is
    // driving or capturing is never looked at, and a reset would be one more
    // thing standing between them and the I/O cell
    reg [15:0] sdram_dq_capture;

    always @(posedge clock) begin
        if (write_data_step) begin
            sdram_dq_out <= ingress_data;
        end

        sdram_dq_capture <= sdram_dq_in;
    end

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            capture_pipe <= {CaptureStages{1'b0}};
        end else begin
            capture_pipe <= {capture_pipe[CaptureStages-2:0], read_window};
        end
    end

    assign egress_write = capture_pipe[CaptureStages-1];
    assign egress_data  = sdram_dq_capture;

    // Sequencing ----------------------------------------------------------------

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            state              <= StateInitWait;
            step               <= StepZero;
            init_refresh_count <= 4'd0;
            init_done          <= 1'b0;
            write_row          <= 15'd0;
            read_row           <= 15'd0;
            fill               <= 16'd0;
            operation_row      <= 15'd0;
        end else begin
            step <= step + StepOne;

            case (state)
                StateInitWait: begin
                    if (step == InitWaitLastStep) begin
                        state <= StateInitPrecharge;
                        step  <= StepZero;
                    end
                end

                StateInitPrecharge: begin
                    if (step == InitPrechargeLastStep) begin
                        state <= StateInitRefresh;
                        step  <= StepZero;
                    end
                end

                StateInitRefresh: begin
                    if (step == InitRefreshLastStep) begin
                        step               <= StepZero;
                        init_refresh_count <= init_refresh_count + 4'd1;

                        if (init_refresh_count == InitRefreshLast) begin
                            state <= StateInitMode;
                        end
                    end
                end

                StateInitMode: begin
                    if (step == InitModeLastStep) begin
                        state     <= StateIdle;
                        step      <= StepZero;
                        init_done <= 1'b1;
                    end
                end

                StateIdle: begin
                    step <= StepZero;

                    // A flush empties the ring here, between operations, so
                    // that no operation is ever cut short
                    if (flush) begin
                        write_row <= 15'd0;
                        read_row  <= 15'd0;
                        fill      <= 16'd0;
                    end

                    if (refresh_start) begin
                        state <= StateRefresh;
                    end else if (flush || flush_held) begin
                        state <= StateIdle;
                    end else if (ingress_has_row && !ring_full) begin
                        state         <= StateWrite;
                        operation_row <= write_row;
                    end else if (!ring_empty && egress_has_room) begin
                        state         <= StateRead;
                        operation_row <= read_row;
                    end
                end

                StateRefresh: begin
                    if (step == RefreshLastStep) begin
                        state <= StateIdle;
                        step  <= StepZero;
                    end
                end

                StateWrite: begin
                    if (step == WriteLastStep) begin
                        state <= StateIdle;
                        step  <= StepZero;
                        fill  <= fill + 16'd1;

                        if (write_row == RingLastRow) begin
                            write_row <= 15'd0;
                        end else begin
                            write_row <= write_row + 15'd1;
                        end
                    end
                end

                StateRead: begin
                    if (step == ReadLastStep) begin
                        state <= StateIdle;
                        step  <= StepZero;
                        fill  <= fill - 16'd1;

                        if (read_row == RingLastRow) begin
                            read_row <= 15'd0;
                        end else begin
                            read_row <= read_row + 15'd1;
                        end
                    end
                end

                default: begin
                    state <= StateIdle;
                    step  <= StepZero;
                end
            endcase
        end
    end

    // Refresh credits -----------------------------------------------------------
    //
    // Counted from the end of power-up, which ends with eight refreshes of its
    // own. A credit and a refresh starting in the same cycle cancel.

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            refresh_timer   <= 11'd0;
            refresh_pending <= 4'd0;
        end else if (!init_done) begin
            refresh_timer   <= 11'd0;
            refresh_pending <= 4'd0;
        end else begin
            if (refresh_tick) begin
                refresh_timer <= 11'd0;
            end else begin
                refresh_timer <= refresh_timer + 11'd1;
            end

            if (refresh_tick && !refresh_start) begin
                if (refresh_pending != 4'hF) begin
                    refresh_pending <= refresh_pending + 4'd1;
                end
            end else if (refresh_start && !refresh_tick) begin
                refresh_pending <= refresh_pending - 4'd1;
            end
        end
    end

    // Flush handshake -----------------------------------------------------------
    //
    // flush_held is set only between operations, so once it is high nothing
    // is being written to the SDRAM or read from it, and it is cleared the
    // cycle flush falls, so the ingress discard stops before the system side
    // can see the acknowledgement fall and start writing again. The capture
    // pipeline is included because a read that finished just before the flush
    // can still have words on their way to the egress FIFO.

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            flush_held <= 1'b0;
            flush_ack  <= 1'b0;
        end else begin
            if (!flush) begin
                flush_held <= 1'b0;
            end else if (state == StateIdle) begin
                flush_held <= 1'b1;
            end

            flush_ack <= flush && flush_held && egress_drained && !read_window
                && (capture_pipe == {CaptureStages{1'b0}});
        end
    end

endmodule
