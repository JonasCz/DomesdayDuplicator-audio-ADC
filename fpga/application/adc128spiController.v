/************************************************************************

    adc128spiController.v

    ADC128S022 audio capture, the DE0-Nano's own A/D converter
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    Reads two of the converter's eight inputs, IN0 as the left channel and
    IN1 as the right, twelve bits each, once per 512-sample frame of the
    framed sample format, and hands the pair to dataGenerator for the frame's
    header.

    Clocking. Everything here runs on the 80 MHz system clock and advances
    only on sample_enable - the capture path's enable, after the decimator -
    so the converter's whole timeline is counted in samples. SCLK, CS and DIN
    are registers toggled on those ticks; nothing is clocked by them.

    Phase lock. The timeline is not a counter of this module's own: it is
    frame_position, the slot dataGenerator is emitting, so every action below
    happens at a fixed slot of every frame and an audio pair can never drift
    into a different frame from the one it belongs to. Two conversions fill
    the frame, IN0 in slots 0 to 255 and IN1 in slots 256 to 511, sixteen
    slots to an SCLK cycle:

      step (slot mod 256)   what happens
      0, 16, ... 240        SCLK falls - falling edges 1 to 16. DIN changes
      8, 24, ... 248        SCLK rises - rising edges 1 to 16. DOUT is read
                            on edges 5 to 16, which carry DB11 to DB0
      48                    falling edge 4: the input is held and converted
      250                   CS rises, with SCLK high
      254                   CS falls, with SCLK high, opening the next frame

    so every frame has exactly the sixteen rising edges the datasheet
    requires and a 50% SCLK, and CS only moves while SCLK is high. Its fall
    is six slots after the rising edge before it and ten before the one
    after it, against the 10 ns of tCSH and tCSS the datasheet asks. The
    control word clocked in on each frame's first eight rising edges names
    the input for the next frame - the other channel - which is how the
    converter's one-frame address pipeline is kept.

    Rates. One pair per frame of 512 samples: at 40 Msps that is SCLK at
    2.5 MHz and 156.25 k conversions a second, 78.125 kHz per channel; at
    20 Msps, decimating, 1.25 MHz and 39.0625 kHz. Both are inside the
    ADC128S022's 0.8 to 3.2 MHz and 50 to 200 ksps.

    Reading DOUT. The converter changes DOUT at most 27 ns after a falling
    edge (tDACC) and holds it at least 4 ns after the next one (tDHLD).
    ADC_SDAT is registered on every system clock, and the shift register
    takes that registered value on the edge that drives SCLK high - so the
    pin was read one system clock, 12.5 ns, before the rising edge left the
    FPGA, and eight slots after the falling edge that launched the bit did:
    187.5 ns later at 40 Msps, 387.5 ns at 20 Msps. The round trip it has to
    cover is two FPGA pin delays, a few centimetres of board and tDACC -
    well under 60 ns - so at least 125 ns of setup margin remains, and the
    bit is not due to change until the next falling edge, more than 200 ns
    after it is read. DIN changes with the falling edge and is read on the
    rising edge eight slots later, against a 10 ns setup and hold
    requirement.

    The first conversion after reset converts whichever input the converter
    was last told to, which after a power cycle is IN0 and after a reset of
    this logic alone may be either. Every conversion after it is right, so
    at most the first right-channel sample is wrong.

    Ported from the fork's controller, which was clocked by the 40 MHz ADC
    clock, ran its own divider free of the frame, and ended each conversion
    on its fifteenth rising edge rather than its sixteenth.

************************************************************************/

module adc128spiController (
    input       reset_n,
    input       clock,
    input       sample_enable,   // 1 = a sample is taken on this edge
    input [8:0] frame_position,  // The frame slot of the sample taken on this edge
    input       adc_dout,        // ADC_SDAT, the converter's DOUT

    // Outputs
    output reg        adc_chip_select_n,  // ADC_CS_N
    output reg        adc_serial_clock,   // ADC_SCLK
    output reg        adc_din,            // ADC_SADDR, the converter's DIN
    output reg [11:0] audio_left,         // IN0, unsigned
    output reg [11:0] audio_right         // IN1, unsigned
);

    // Steps within each half of the frame, from the table above
    localparam [7:0] LastRisingEdge = 8'd248;
    localparam [7:0] ChipSelectRise = 8'd250;
    localparam [7:0] ChipSelectFall = 8'd254;

    // Where in an SCLK cycle of sixteen slots each edge falls, and the cycle
    // whose rising edge carries DB11: the fifth, after four leading zeros
    localparam [3:0] RisingPhase = 4'd8;
    localparam [3:0] FirstDataCycle = 4'd4;

    // Which conversion this is, and where in it
    wire        converting_right = frame_position[8];
    wire [ 7:0] step = frame_position[7:0];
    wire [ 3:0] sclk_cycle = step[7:4];
    wire [ 3:0] sclk_phase = step[3:0];

    // The control word, most significant bit first on rising edges 1 to 8:
    // two don't-care bits, the next conversion's input ADD2 to ADD0, and
    // three more don't-care bits. The next input is always the other one.
    wire [ 2:0] next_input = {2'b00, ~converting_right};
    wire [ 7:0] control_word = {2'b00, next_input, 3'b000};
    wire        control_bit = (sclk_cycle < 4'd8) ? control_word[3'd7-sclk_cycle[2:0]] : 1'b0;

    // DOUT, registered on every clock; the bits read so far; and IN0's
    // result, held until IN1's is complete so the two are published together
    reg         dout_sampled;
    reg  [10:0] shift;
    reg  [11:0] left_held;

    wire [11:0] word = {shift, dout_sampled};

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            adc_chip_select_n <= 1'b1;
            adc_serial_clock  <= 1'b1;
            adc_din           <= 1'b0;
            dout_sampled      <= 1'b0;
            shift             <= 11'd0;
            left_held         <= 12'd0;
            audio_left        <= 12'd0;
            audio_right       <= 12'd0;
        end else begin
            dout_sampled <= adc_dout;

            if (sample_enable) begin
                // Low for the first eight slots of each sixteen, high for the
                // rest, so it falls on phase 0 and rises on phase 8
                adc_serial_clock <= step[3];

                // Changes only where the cycle does, which is a falling edge
                adc_din          <= control_bit;

                // CS is moved rather than recomputed, so that after reset it
                // stays high until the first proper place for it to fall
                // instead of falling on the same edge as SCLK
                if (step == ChipSelectRise) begin
                    adc_chip_select_n <= 1'b1;
                end else if (step == ChipSelectFall) begin
                    adc_chip_select_n <= 1'b0;
                end

                if ((sclk_phase == RisingPhase) && (sclk_cycle >= FirstDataCycle)) begin
                    shift <= word[10:0];
                end

                if (step == LastRisingEdge) begin
                    if (!converting_right) begin
                        left_held <= word;
                    end else begin
                        audio_left  <= left_held;
                        audio_right <= word;
                    end
                end
            end
        end
    end

endmodule
