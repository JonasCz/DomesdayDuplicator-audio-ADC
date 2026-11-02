/************************************************************************

    dataGenerator.v

    Data generation module
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2018-2026 Simon Inns
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    Runs on the system clock and takes one sample per assertion of
    sample_enable, which the top level raises on the cycle that also takes the
    ADC clock high. That is the same instant this module used to capture on
    when it was clocked by the ADC clock directly: the sample it reads was
    launched by the previous ADC clock edge, a full 40 MHz period earlier, so
    it has the same time to settle as before.

    Everything downstream of the enable counts samples rather than cycles, so
    the ramp, the sequence number and the frame advance at the sampling rate
    and not at the system clock rate.

    Bits 9:0 of every word are the RF sample, or the test ramp in test mode,
    in either format. What bits 15:10 carry is chosen by FramedFormat:

      0  the six-bit sequence number, 0 to 62, 65535 samples each. This is
         the default, and the format the host's sequence validator reads.

      1  the framed format: 512-sample frames whose top six bits carry a
         192-bit sync pattern, the two audio converters' latest samples, a
         24-bit status word and a free-running 48-bit counter. The layout is
         specified, slot by slot, in framed-sample-format.md beside this
         file, which is the one place it is defined; the frame position, the
         header and the counter below implement that page and nothing else.

    Both formats are always built and the parameter picks one at the output,
    so that a lint of this module checks the logic of both. Synthesis keeps
    only the one that is selected.

************************************************************************/

module dataGenerator #(
    // 0 = sequence number in bits 15:10, 1 = the framed format
    parameter [0:0] FramedFormat = 1'b0
) (
    input       reset_n,
    input       clock,
    input       sample_enable,
    input [9:0] adc_databus,
    input       test_mode_flag,

    // The audio converters' latest samples, carried by the framed format's
    // header. The default format does not read them.
    input [11:0] adc128_left,   // ADC128S022 IN0, unsigned
    input [11:0] adc128_right,  // ADC128S022 IN1, unsigned
    input [23:0] pcm1802_left,  // PCM1802 left, two's complement
    input [23:0] pcm1802_right, // PCM1802 right, two's complement

    // The status word the framed format's header carries in slots 36, 37, 46
    // and 47 - the SDRAM capture buffer's, in the application image. Its
    // layout is framed-sample-format.md's; this module only carries it. The
    // default format does not read it either.
    input [23:0] status_word,

    // Outputs
    output [15:0] data_out,
    output [ 8:0] frame_position  // Framed format: the frame slot of data_out
);

    // Register to store ADC data values
    reg [9:0] adc_data;

    // Register to store test data values
    reg [9:0] test_data;

    // Samples carrying each sequence number, and how many sequence numbers
    // there are before the count wraps.
    //
    // 65535 and not 65536, and the odd number is the whole point. The host
    // detects loss by predicting the next sequence number and disagreeing with
    // what arrives, so the one gap it cannot see is a gap that is an exact
    // multiple of the whole period - all 63 blocks - because that leaves the
    // stream in the phase it would have been in anyway.
    //
    // USB 3 loses capture data a whole endpoint packet at a time: 1024 bytes,
    // which is 512 samples. With a block of 65536 the period is 63 * 65536
    // samples, and 8064 lost packets land exactly on it - so a hole of
    // 7.875 MiB, a tenth of a second of capture, would read as no hole at all.
    // An odd block length shares no factor of two with a packet, so the
    // smallest hole that is both a whole number of packets and a whole period
    // becomes 512 periods: just under 4 GiB, or 53 seconds of capture, which
    // every other thing the host counts would have noticed long before.
    //
    // The host tolerates both lengths - see sequence_validator.cpp - so a
    // board carrying the older gateware still captures.
    localparam [15:0] BlockSamples = 16'd65535;
    localparam [15:0] BlockLast = BlockSamples - 16'd1;
    localparam [15:0] BlockZero = 16'd0;
    localparam [15:0] BlockOne = 16'd1;

    localparam [5:0] SequenceLast = 6'd62;
    localparam [5:0] SequenceZero = 6'd0;
    localparam [5:0] SequenceOne = 6'd1;

    // Register to store the sequence number and the position within the block
    // of samples that number covers
    reg  [ 5:0] sequence_count;
    reg  [15:0] sequence_position;

    // The top 6 bits of the output are the sequence number or the frame's
    // metadata, whichever format this instance was built for
    wire [ 5:0] frame_metadata;

    assign data_out[15:10] = FramedFormat ? frame_metadata : sequence_count;

    // If we are in test-mode use test data,
    // otherwise use the actual ADC data
    assign data_out[9:0]   = test_mode_flag ? test_data : adc_data;

    // Read the ADC data and increment the counters, once per sample
    //
    // Note: The test data is a repeating pattern of incrementing
    // values from 0 to 1020.
    //
    // The sequence number counts from 0 to 62 repeatedly, with each
    // number being attached to 65535 samples.
    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            adc_data          <= 10'd0;
            test_data         <= 10'd0;
            sequence_count    <= SequenceZero;
            sequence_position <= BlockZero;
        end else if (sample_enable) begin
            // Read the ADC data
            adc_data <= adc_databus;

            // Test mode data generation
            if (test_data == 10'd1021 - 1) begin
                test_data <= 10'd0;
            end else begin
                test_data <= test_data + 10'd1;
            end

            // Sequence number generation. Two counters rather than the
            // single wide one this used to be: the top bits of a 22-bit
            // counter are only a sequence number when the block length is a
            // power of two, and it deliberately is not.
            if (sequence_position == BlockLast) begin
                sequence_position <= BlockZero;

                if (sequence_count == SequenceLast) begin
                    sequence_count <= SequenceZero;
                end else begin
                    sequence_count <= sequence_count + SequenceOne;
                end
            end else begin
                sequence_position <= sequence_position + BlockOne;
            end
        end
    end

    // The framed format --------------------------------------------------------
    //
    // A frame is 512 samples. Slots 0 to 31 carry the sync pattern, 32 to 47
    // the header, and 48 to 511 the counter, eight slots to a value. Six bits
    // per slot: least significant chunk first in the sync pattern and the
    // counter, most significant first in the header. That is the layout of the
    // fork this format comes from, kept bit for bit because captures and
    // decoders exist that read it.

    // The sync pattern. Slot k carries bits 6k+5 to 6k, so the low 48 bits
    // are the first eight slots.
    localparam [191:0] SyncPattern = 192'hDDDF20251015DDDF20251015DDDF20251016FEDCBA987654;

    localparam [8:0] HeaderFirst = 9'd32;
    localparam [8:0] CounterFirst = 9'd48;

    // The frame slot of the sample on data_out, and the slot whose metadata
    // is loaded with the next sample.
    reg  [ 8:0] position;
    wire [ 8:0] next_position = position + 9'd1;

    // The metadata on data_out. A register, so that bits 15:10 leave this
    // module from a flop in both formats rather than from a decoder in one.
    reg  [ 5:0] metadata;

    // The counter. It advances after the eighth slot of each value - the last
    // slot of the frame included, so each frame continues the count where the
    // one before it stopped - and nothing but reset_n ever clears it.
    reg  [47:0] counter;

    // The audio, snapshotted once per frame so that every frame carries one
    // coherent pair from each converter. The fork latched each converter
    // whenever it produced a sample, so a value spread across four slots could
    // change between the first of them and the last.
    reg  [11:0] adc128_left_frame;
    reg  [11:0] adc128_right_frame;
    reg  [23:0] pcm1802_left_frame;
    reg  [23:0] pcm1802_right_frame;

    // The status word, snapshotted with the audio for the same reason: its
    // four slots are spread across the header, and a word that changed
    // between slot 37 and slot 46 would be half one value and half another.
    reg  [23:0] status_word_frame;

    // Each region's metadata for the slot being loaded. The sync pattern and
    // the counter are indexed by slot; the header is a table.
    wire [ 7:0] sync_offset = {3'b000, next_position[4:0]} * 8'd6;
    wire [ 5:0] counter_offset = {3'b000, next_position[2:0]} * 6'd6;
    wire [ 5:0] sync_chunk = SyncPattern[sync_offset+:6];
    wire [ 5:0] counter_chunk = counter[counter_offset+:6];
    reg  [ 5:0] header_chunk;

    always @(*) begin
        case (next_position[3:0])
            4'd0:    header_chunk = adc128_left_frame[11:6];
            4'd1:    header_chunk = adc128_left_frame[5:0];
            4'd2:    header_chunk = adc128_right_frame[11:6];
            4'd3:    header_chunk = adc128_right_frame[5:0];
            4'd4:    header_chunk = status_word_frame[23:18];
            4'd5:    header_chunk = status_word_frame[17:12];
            4'd6:    header_chunk = pcm1802_left_frame[23:18];
            4'd7:    header_chunk = pcm1802_left_frame[17:12];
            4'd8:    header_chunk = pcm1802_left_frame[11:6];
            4'd9:    header_chunk = pcm1802_left_frame[5:0];
            4'd10:   header_chunk = pcm1802_right_frame[23:18];
            4'd11:   header_chunk = pcm1802_right_frame[17:12];
            4'd12:   header_chunk = pcm1802_right_frame[11:6];
            4'd13:   header_chunk = pcm1802_right_frame[5:0];
            4'd14:   header_chunk = status_word_frame[11:6];
            default: header_chunk = status_word_frame[5:0];
        endcase
    end

    wire [5:0] next_metadata = (next_position < HeaderFirst) ? sync_chunk :
        (next_position < CounterFirst) ? header_chunk : counter_chunk;

    assign frame_metadata = metadata;
    assign frame_position = position;

    // Reset leaves slot 0 on the output, so the first word after reset starts
    // a frame and the first counter value is zero.
    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            position            <= 9'd0;
            metadata            <= SyncPattern[5:0];
            counter             <= 48'd0;
            adc128_left_frame   <= 12'd0;
            adc128_right_frame  <= 12'd0;
            pcm1802_left_frame  <= 24'd0;
            pcm1802_right_frame <= 24'd0;
            status_word_frame   <= 24'd0;
        end else if (sample_enable) begin
            position <= next_position;
            metadata <= next_metadata;

            if ((next_position >= CounterFirst) && (next_position[2:0] == 3'd7)) begin
                counter <= counter + 48'd1;
            end

            // With the sample that loads slot 0: after both converters have
            // published the pair they finish in a frame, and long before the
            // header slots that carry it are reached.
            if (next_position == 9'd0) begin
                adc128_left_frame   <= adc128_left;
                adc128_right_frame  <= adc128_right;
                pcm1802_left_frame  <= pcm1802_left;
                pcm1802_right_frame <= pcm1802_right;
                status_word_frame   <= status_word;
            end
        end
    end

endmodule
