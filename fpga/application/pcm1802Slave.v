/************************************************************************

    pcm1802Slave.v

    PCM1802 audio capture, with the converter in slave mode on JP3
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2025-2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    Drives a PCM1802 strapped for slave mode and the 24-bit left-justified
    format (MODE1:0 = 00, FMT1:0 = 00), and reads one stereo sample from it
    per 512-sample frame of the framed sample format, for dataGenerator to
    carry in the frame's header. The FPGA is the clock master: it supplies
    SCKI at 256 fs, BCK at 64 fs and LRCK at fs, and the converter shifts
    its data out on DOUT against them.

    Clocking. Everything here runs on the 80 MHz system clock and advances
    only on sample_enable - the capture path's enable, after the decimator -
    so the converter's whole timeline is counted in samples. SCKI, BCK and
    LRCK are registers set on those ticks; nothing is clocked by them. The
    fork clocked its LRCK and its data capture from the BCK it generated and
    passed the result back to the sampling clock unsynchronised.

    Phase lock. The timeline is frame_position, the slot dataGenerator is
    emitting, and every output is a bit of it:

      SCKI   slot bit 0, toggling every sample               256 fs
      BCK    slot bit 2: falls on slot 8k, rises on 8k + 4    64 fs
      LRCK   high for slots 0 to 255, low for 256 to 511        fs

    so one LRCK period is exactly one frame, both channels of a sample land
    in the same frame every time, and SCKI, BCK and LRCK keep the one fixed
    relationship the converter needs to stay synchronised. LRCK and BCK
    change together on BCK's falling edge, as the left-justified format
    draws them.

    LRCK high is the left channel. That is the datasheet's Figure 23 for the
    left-justified format, where LRCK is high for the left word and low for
    the right; low-is-left is the I2S convention. The fork took LRCK low as
    left, so its left and right were the other way round from the
    converter's VINL and VINR.

    Data. In this format the MSB leaves on the LRCK edge and each later bit
    on a falling BCK edge, and each is read on the rising edge that follows,
    so the word for a channel is the 24 bits read on the first 24 rising
    edges of its half: slots 4, 12, ... 188 for the left, 260 ... 444 for the
    right. The two are published together at slot 444.

    Rates. One sample per frame of 512 samples: fs = 78.125 kHz at 40 Msps,
    with SCKI at 20 MHz and BCK at 5 MHz; 39.0625 kHz at 20 Msps, decimating,
    with SCKI at 10 MHz and BCK at 2.5 MHz. Both are inside the PCM1802's
    16 to 96 kHz at 256 fs, and its 10 us minimum LRCK period.

    Reading DOUT. The converter changes DOUT between 10 ns before and 20 ns
    after BCK falls (tCKDO), or after the LRCK edge for the MSB (tLRDO).
    DOUT is registered on every system clock, and the shift register takes
    that registered value on the edge that drives BCK high - so the pin was
    read one system clock, 12.5 ns, before that edge left the FPGA, and four
    slots after the falling edge did: 87.5 ns later at 40 Msps, 187.5 ns at
    20 Msps. Taking two FPGA pin delays, the board and the 20 ns out of
    that leaves more than 40 ns of setup margin at the faster rate, and the
    next change is not due until 10 ns before the next falling edge, which
    is more than 90 ns after the read. BCK's high and low times are 100 ns
    at 40 Msps against a 60 ns minimum, and LRCK changes 100 ns from a
    rising BCK edge on either side against 40 ns of setup and 20 ns of hold.

    FSYNC is not driven. In slave mode the PCM1802 shifts data out only
    while FSYNC is high, so it has to be tied high at the converter; the
    datasheet's slave-mode figure draws it high throughout. The fork did
    not drive it either.

    The converter holds DOUT at zero until 1024 SCKI cycles and then
    4480 / fs have passed since its supply came up (datasheet 7.3.2), and
    SCKI only starts when this logic leaves reset, so the first 60 ms or so
    of audio after the FX3 releases reset read as silence - 115 ms when
    decimating.

************************************************************************/

module pcm1802Slave (
    input       reset_n,
    input       clock,
    input       sample_enable,   // 1 = a sample is taken on this edge
    input [8:0] frame_position,  // The frame slot of the sample taken on this edge
    input       pcm_dout,        // The converter's DOUT

    // Outputs
    output reg        pcm_scki,    // System clock, 256 fs
    output reg        pcm_bck,     // Bit clock, 64 fs
    output reg        pcm_lrck,    // Word clock, fs; high for the left channel
    output reg [23:0] audio_left,  // VINL, two's complement
    output reg [23:0] audio_right  // VINR, two's complement
);

    // Where in a BCK cycle of eight slots its rising edge falls, and the
    // cycle within a channel's half whose rising edge reads the LSB
    localparam [2:0] RisingPhase = 3'd4;
    localparam [4:0] LastDataCycle = 5'd23;

    // Which channel's half of the frame this is, and where in it
    wire        right_half = frame_position[8];
    wire [ 7:0] step = frame_position[7:0];
    wire [ 4:0] bck_cycle = step[7:3];
    wire        bck_rising = (step[2:0] == RisingPhase);

    // DOUT, registered on every clock; the bits read so far; and the left
    // word, held until the right one is complete so the two are published
    // together
    reg         dout_sampled;
    reg  [22:0] shift;
    reg  [23:0] left_held;

    wire [23:0] word = {shift, dout_sampled};

    always @(posedge clock, negedge reset_n) begin
        if (!reset_n) begin
            pcm_scki     <= 1'b0;
            pcm_bck      <= 1'b0;
            pcm_lrck     <= 1'b0;
            dout_sampled <= 1'b0;
            shift        <= 23'd0;
            left_held    <= 24'd0;
            audio_left   <= 24'd0;
            audio_right  <= 24'd0;
        end else begin
            dout_sampled <= pcm_dout;

            if (sample_enable) begin
                pcm_scki <= frame_position[0];
                pcm_bck  <= step[2];
                pcm_lrck <= ~right_half;

                if (bck_rising && (bck_cycle <= LastDataCycle)) begin
                    shift <= word[22:0];
                end

                if (bck_rising && (bck_cycle == LastDataCycle)) begin
                    if (!right_half) begin
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
