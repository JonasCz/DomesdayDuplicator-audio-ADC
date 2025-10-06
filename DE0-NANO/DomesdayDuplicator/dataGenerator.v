/************************************************************************
	
	dataGeneration.v
	Data generation module
	
	Domesday Duplicator - LaserDisc RF sampler
	Copyright (C) 2018 Simon Inns
	
	This file is part of Domesday Duplicator.
	
	Domesday Duplicator is free software: you can redistribute it and/or
	modify it under the terms of the GNU General Public License as
	published by the Free Software Foundation, either version 3 of the
	License, or (at your option) any later version.
	
	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.
	
	You should have received a copy of the GNU General Public License
	along with this program.  If not, see <http://www.gnu.org/licenses/>.
	Email: simon.inns@gmail.com
	
************************************************************************/

module dataGenerator (
	input nReset,
	input clock,
	input [9:0] adc_databus,
	input testModeFlag,
	
	// Audio inputs from SPI controller
	input [11:0] audio_left_in,
	input [11:0] audio_right_in,
	input audio_ready,
	
	// PCM1802 24-bit audio inputs
	input [23:0] pcm_left_in,
	input [23:0] pcm_right_in,
	input pcm_ready,
	
	// Outputs
	output [15:0] dataOut
);

// Register to store ADC data values
reg [9:0] adcData;

// Register to store test data values
reg [9:0] testData;

// Register to store the sequence number counter
reg [21:0] sequenceCount;

// Frame position counter (0-511)
reg [8:0] sample_in_frame;

// Latched audio data
reg [11:0] audio_left_latch;
reg [11:0] audio_right_latch;

// Latched PCM1802 audio data (24-bit)
reg [23:0] pcm_left_latch;
reg [23:0] pcm_right_latch;

// Top 6 bits: depends on position in frame
reg [5:0] top_6_bits;

// Sync pattern: 0xDEADBEEFCAFEDEADBEEFCAFE (96-bit)
localparam [95:0] SYNC_PATTERN = 96'hDEADBEEFCAFEDEADBEEFCAFE;

// Output assignments
assign dataOut[15:10] = top_6_bits;
assign dataOut[9:0] = testModeFlag ? testData : adcData;

// Read the ADC data and increment the counters on the
// positive edge of the clock
//
// Note: The test data is a repeating pattern of incrementing
// values from 0 to 1020.
//
// The sequence number counts from 0 to 62 repeatedly, with each
// number being attached to 65536 samples.
//
// Audio data is packed into the top 6 bits based on position
// within 512-sample frames.
always @ (posedge clock, negedge nReset) begin
	if (!nReset) begin
		adcData <= 10'd0;
		testData <= 10'd0;
		sequenceCount <= 22'd0;
		sample_in_frame <= 9'd0;
		audio_left_latch <= 12'd0;
		audio_right_latch <= 12'd0;
		top_6_bits <= 6'd0;
	end else begin
		// Read the ADC data
		adcData <= adc_databus;
		
		// Test mode data generation
		if (testData == 10'd1021 - 1)
			testData <= 10'd0;
		else
			testData <= testData + 10'd1;
		
		// Latch new audio sample when ready
		if (audio_ready) begin
			audio_left_latch <= audio_left_in;
			audio_right_latch <= audio_right_in;
		end
		// Latch new PCM1802 sample when ready
		if (pcm_ready) begin
			pcm_left_latch <= pcm_left_in;
			pcm_right_latch <= pcm_right_in;
		end
		
		// Determine top 6 bits based on position in frame
        // New layout: 0..15 = 96-bit sync (16 samples)
		// 16..19 = ADC128 12-bit L/R (4 samples)
		// 20..21 = CRC placeholders
		// 22..25 = PCM1802 Left 24-bit (4 samples)
		// 26..29 = PCM1802 Right 24-bit (4 samples)
		// 30..511 = Sequence number
        case (sample_in_frame)
            // Sync pattern (samples 0-15)
            9'd0:  top_6_bits <= SYNC_PATTERN[5:0];
            9'd1:  top_6_bits <= SYNC_PATTERN[11:6];
            9'd2:  top_6_bits <= SYNC_PATTERN[17:12];
            9'd3:  top_6_bits <= SYNC_PATTERN[23:18];
            9'd4:  top_6_bits <= SYNC_PATTERN[29:24];
            9'd5:  top_6_bits <= SYNC_PATTERN[35:30];
            9'd6:  top_6_bits <= SYNC_PATTERN[41:36];
            9'd7:  top_6_bits <= SYNC_PATTERN[47:42];
            9'd8:  top_6_bits <= SYNC_PATTERN[53:48];
            9'd9:  top_6_bits <= SYNC_PATTERN[59:54];
            9'd10: top_6_bits <= SYNC_PATTERN[65:60];
            9'd11: top_6_bits <= SYNC_PATTERN[71:66];
            9'd12: top_6_bits <= SYNC_PATTERN[77:72];
            9'd13: top_6_bits <= SYNC_PATTERN[83:78];
            9'd14: top_6_bits <= SYNC_PATTERN[89:84];
            9'd15: top_6_bits <= SYNC_PATTERN[95:90];

            // Temporarily keep existing ADC128 audio at samples 16..19 (left/right 12-bit)
            9'd16: top_6_bits <= audio_left_latch[11:6];
            9'd17: top_6_bits <= audio_left_latch[5:0];
            9'd18: top_6_bits <= audio_right_latch[11:6];
            9'd19: top_6_bits <= audio_right_latch[5:0];

            // CRC placeholders (20..21)
            9'd20: top_6_bits <= 6'd0;
            9'd21: top_6_bits <= 6'd0;

			// PCM1802 Left 24-bit (22..25)
			9'd22: top_6_bits <= pcm_left_latch[23:18];
			9'd23: top_6_bits <= pcm_left_latch[17:12];
			9'd24: top_6_bits <= pcm_left_latch[11:6];
			9'd25: top_6_bits <= pcm_left_latch[5:0];

			// PCM1802 Right 24-bit (26..29)
			9'd26: top_6_bits <= pcm_right_latch[23:18];
			9'd27: top_6_bits <= pcm_right_latch[17:12];
			9'd28: top_6_bits <= pcm_right_latch[11:6];
			9'd29: top_6_bits <= pcm_right_latch[5:0];

			// Sequence number for remaining samples
            default: top_6_bits <= sequenceCount[21:16];
        endcase
		
		// Increment frame position
		if (sample_in_frame == 9'd511) begin
			sample_in_frame <= 9'd0;
		end else begin
			sample_in_frame <= sample_in_frame + 9'd1;
		end
		
		// Sequence number generation
		if (sequenceCount == (6'd63 << 16) - 1)
			sequenceCount <= 22'd0;
		else
			sequenceCount <= sequenceCount + 22'd1;
	end
end

endmodule