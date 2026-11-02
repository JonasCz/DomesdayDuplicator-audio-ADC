/************************************************************************

    tb_sdramFramed.v

    Testbench for the SDRAM status word in the framed stream (T3)
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    The application's capture path from the generator to the GPIF databus,
    as the top level wires it: dataGenerator in the framed format with test
    mode on, carrying sdramBuffer's status word in the header, then
    sdramBuffer, buffer.v and fx3StateMachine, with sdramModel.v as the
    SDRAM. The consumer behaves like the FX3 and decodes every frame it
    receives the way a host does, from the words alone.

    What it checks is that the status word a host reads is the truth:

      - every frame arrives whole and in order: the sync pattern at slots 0
        to 7 of each, and the test ramp in bits 9:0 unbroken throughout
      - the status word in slots 36, 37, 46 and 47 of each frame is, bit
        for bit, the word sdramBuffer was presenting when that frame was
        started - so it is end to end exact, through the SDRAM and back,
        whatever the word says
      - what it says is right: layout version 1 from the first frame after
        reset; initialisation complete before the path is in use, and
        neither until the SDRAM is ready; no loss; and a fill that rises
        through a stall in step with the backlog, then returns to the zero
        or one row of steady state

    The ring is 32 rows, as in tb_sdramBuffer.

************************************************************************/

`timescale 1ns / 1ps

module tb_sdramFramed;

    localparam integer RING_ROWS = 32;
    localparam integer ROWS_PER_BANK = 8;
    localparam integer FRAME = 512;
    localparam integer RAMP_LENGTH = 1021;
    localparam integer MAX_FRAMES = 1024;

    // The first eight slots of the sync pattern, least significant chunk
    // first, as a host's decoder holds them
    localparam [47:0] SYNC_0 = 48'hFEDCBA987654;

    localparam real SYSTEM_HALF = 6.25;
    localparam real SDRAM_HALF = 4.167;
    localparam real SDRAM_CLOCK_DELAY = 2.0 * SDRAM_HALF - 1.0;

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

    initial begin
        #1.3;
        forever begin
            #(SDRAM_HALF) sdram_clock = ~sdram_clock;
        end
    end

    always @(sdram_clock) begin
        dram_clock <= #(SDRAM_CLOCK_DELAY) sdram_clock;
    end

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

    // The sampling side, as the top level builds it ---------------------------------

    reg adc_clock_divider;

    initial begin
        adc_clock_divider = 1'b0;
    end
    always @(posedge clock) begin
        adc_clock_divider <= ~adc_clock_divider;
    end

    wire        sample_enable = ~adc_clock_divider;

    wire [23:0] status;
    wire [15:0] generator_out;
    wire [ 8:0] frame_position;

    dataGenerator #(
        .FramedFormat(1'b1)
    ) generator (
        .reset_n       (reset_n),
        .clock         (clock),
        .sample_enable (sample_enable),
        .adc_databus   (10'd0),
        .test_mode_flag(1'b1),
        .adc128_left   (12'd0),
        .adc128_right  (12'd0),
        .pcm1802_left  (24'd0),
        .pcm1802_right (24'd0),
        .status_word   (status),
        .data_out      (generator_out),
        .frame_position(frame_position)
    );

    // The path ------------------------------------------------------------------------

    reg         collect_data;
    wire        buffer_write;
    wire [15:0] buffer_data;
    wire [14:0] buffer_used_words;
    wire        sample_lost;

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
    ) path (
        .reset_n          (reset_n),
        .clock            (clock),
        .collect_data     (collect_data),
        .sample_strobe    (sample_enable),
        .sample_data      (generator_out),
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
    wire [127:0] telemetry_unused;
    wire [ 47:0] telemetry_geometry_unused;

    buffer buffer_0 (
        .reset_n           (reset_n),
        .clock             (clock),
        .write_enable      (buffer_write),
        .data_in           (buffer_data),
        .sample_offered    (sample_enable),
        .sample_lost       (sample_lost),
        .is_reading        (fx3_is_reading),
        .telemetry_latch   (1'b0),
        .data_out          (fx3_databus),
        .data_available    (data_available),
        .buffer_error      (buffer_error),
        .used_words        (buffer_used_words),
        .telemetry         (telemetry_unused),
        .telemetry_geometry(telemetry_geometry_unused)
    );

    reg fx3_read_data;

    fx3StateMachine fx3_state_machine_0 (
        .reset_n       (reset_n),
        .fx3_clock     (clock),
        .read_data     (fx3_read_data),
        .fx3_is_reading(fx3_is_reading)
    );

    // The status word each frame was started with, recorded at the producer
    // ---------------------------------------------------------------------------------
    //
    // The generator snapshots its header inputs on the edge that loads slot 0
    // of a frame, which is the enabled edge with slot 511 on its output. Frame
    // 0 is the one reset starts, which no snapshot fills, so frame f >= 1
    // carries snapshot f - 1.

    reg     [23:0] produced_status [0:MAX_FRAMES-1];
    integer        produced_frames;

    // The FX3 and the decoder ----------------------------------------------------------

    integer        errors;
    integer        reported;
    reg     [31:0] seed;
    reg            stalled;
    reg            requested;
    integer        packet_gap;

    reg     [31:0] received;
    integer        frames;
    reg     [47:0] sync;
    reg     [23:0] frame_status;
    reg     [ 5:0] chunk;
    reg     [ 8:0] slot;

    reg     [23:0] received_status [0:MAX_FRAMES-1];

    function [31:0] random_word;
        input dummy;
        begin
            seed        = seed ^ (seed << 13);
            seed        = seed ^ (seed >> 17);
            seed        = seed ^ (seed << 5);
            random_word = seed;
        end
    endfunction

    task fail;
        input [511:0] what;
        begin
            errors = errors + 1;
            if (reported < 10) begin
                $display("FAIL: %0s (frame %0d, t=%0t)", what, frames, $time);
                reported = reported + 1;
            end
        end
    endtask

    always @(posedge clock) begin
        if (reset_n && sample_enable && (frame_position == 9'd511)) begin
            if (produced_frames < MAX_FRAMES) begin
                produced_status[produced_frames] = status;
            end
            produced_frames = produced_frames + 1;
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
                packet_gap <= 16 + (random_word(1'b0) % 200);
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
            slot  = received % FRAME;
            chunk = fx3_databus[15:10];

            if (fx3_databus[9:0] !== (received % RAMP_LENGTH)) begin
                fail("the test ramp is broken: a word lost, repeated or reordered");
            end

            if (slot < 8) begin
                sync = {chunk, sync[47:6]};
                if ((slot == 7) && (sync !== SYNC_0)) begin
                    fail("a frame does not start with the sync pattern");
                end
            end

            case (slot)
                9'd36: frame_status[23:18] = chunk;
                9'd37: frame_status[17:12] = chunk;
                9'd46: frame_status[11:6] = chunk;
                9'd47: frame_status[5:0] = chunk;
                default: begin
                end
            endcase

            if (slot == 9'd47) begin
                if (frames < MAX_FRAMES) begin
                    received_status[frames] = frame_status;
                end
                if (frames == 0) begin
                    if (frame_status !== 24'd0) begin
                        fail("the frame reset starts does not carry a zero status word");
                    end
                end else if ((frames - 1 < MAX_FRAMES)
                             && (frame_status !== produced_status[frames-1])) begin
                    fail("a frame's status word is not the one it was started with");
                    $display("      got %h, the frame was started with %h", frame_status,
                             produced_status[frames-1]);
                end
            end

            if (slot == FRAME - 1) begin
                frames = frames + 1;
            end
            received = received + 32'd1;
        end
    end

    task wait_us;
        input real microseconds;
        begin
            #(microseconds * 1000.0);
            @(posedge clock);
            #1;
        end
    endtask

    integer        f;
    integer        stall_first;
    integer        stall_last;
    integer        first_initialised;
    integer        first_active;
    reg     [15:0] peak_fill;
    integer        peak_frame;

    initial begin
        errors          = 0;
        reported        = 0;
        seed            = 32'h00F2_A3ED;
        stalled         = 1'b0;
        collect_data    = 1'b0;
        received        = 32'd0;
        frames          = 0;
        sync            = 48'd0;
        frame_status    = 24'd0;
        produced_frames = 0;
        reset_source_n  = 1'b0;

        #100;
        reset_source_n = 1'b1;

        // The start request arrives before the SDRAM is ready
        wait_us(50.0);
        collect_data = 1'b1;
        wait (status[19] === 1'b1);
        wait_us(300.0);

        // A stall the path can hold
        stall_first = produced_frames;
        stalled     = 1'b1;
        wait_us(450.0);
        stalled    = 1'b0;
        stall_last = produced_frames;
        wait (path.sdram_controller_0.ring_fill == 16'd0);
        wait_us(400.0);

        // What the frames said -------------------------------------------------------

        first_initialised = -1;
        first_active      = -1;
        peak_fill         = 16'd0;
        peak_frame        = -1;

        for (f = 1; f < frames; f = f + 1) begin
            if (received_status[f][23:20] !== 4'd1) begin
                fail("a frame does not carry layout version 1");
            end
            if (received_status[f][16] !== 1'b0) begin
                fail("the reserved status bit is not zero");
            end
            if (received_status[f][17] !== 1'b0) begin
                fail("a frame reports a loss that did not happen");
            end
            if ((first_initialised < 0) && received_status[f][18]) begin
                first_initialised = f;
            end
            if ((first_active < 0) && received_status[f][19]) begin
                first_active = f;
            end
            if (received_status[f][19] && !received_status[f][18]) begin
                fail("a frame reports the path in use before the SDRAM is initialised");
            end
            if (received_status[f][15:0] > peak_fill) begin
                peak_fill  = received_status[f][15:0];
                peak_frame = f;
            end
        end

        $display("%0d frames received; initialised from frame %0d, path in use from frame %0d",
                 frames, first_initialised, first_active);
        $display("in-band fill peaked at %0d rows in frame %0d (stall over frames %0d to %0d)",
                 peak_fill, peak_frame, stall_first + 1, stall_last + 1);

        if (first_initialised < 5) begin
            fail("frames claim the SDRAM is initialised before it could be");
        end
        if ((first_active < first_initialised) || (first_active < 0)) begin
            fail("the path is reported in use before it is initialised, or never");
        end
        if (peak_fill < 16'd10) begin
            fail("the in-band fill does not show the stall's backlog");
        end
        if ((peak_frame < stall_first) || (peak_frame > stall_last + 2)) begin
            fail("the in-band fill does not peak in the frames the stall produced");
        end
        // In steady state each row is written and read straight back, so the
        // ring holds one row for about a third of the time
        if (received_status[frames-1][15:0] > 16'd1) begin
            fail("the in-band fill does not return to its steady state of 0 or 1 row");
        end

        // The fill rises monotonically through the frames produced in the stall,
        // as the backlog does, once the path's FIFOs and buffer.v have filled
        for (f = stall_first + 2; f <= stall_last; f = f + 1) begin
            if (received_status[f][15:0] + 16'd1 < received_status[f-1][15:0]) begin
                fail("the in-band fill falls during the stall");
            end
        end

        if (model.errors != 0) begin
            fail("protocol errors reported by the SDRAM model");
        end

        if (errors != 0) begin
            $fatal(1, "tb_sdramFramed: %0d check(s) failed", errors);
        end

        $display("tb_sdramFramed: PASS");
        $finish;
    end

endmodule
