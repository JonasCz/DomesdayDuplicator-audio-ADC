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

// Register to store the 48-bit sequence counter
reg [47:0] sequenceCount;

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

// 192-bit sync pattern (32 samples). Firmware revision marker: 20251015
// Pattern: DDDF20251015 repeated with variation for uniqueness
localparam [191:0] SYNC_PATTERN = 192'hDDDF20251015DDDF20251015DDDF20251016FEDCBA987654;

// Output assignments
assign dataOut[15:10] = top_6_bits;
assign dataOut[9:0] = testModeFlag ? testData : adcData;

// Frame Structure (512 samples, 40 MHz sampling):
//   Samples   0-31:  Sync pattern (192 bits, firmware version 20251015)
//   Samples  32-35:  ADC128 audio L+R (12-bit per channel, 2 samples each)
//   Samples  36-37:  Reserved block 1 (zeros)
//   Samples  38-45:  PCM1802 audio L+R (24-bit per channel, 4 samples each)
//   Samples  46-47:  Reserved block 2 (zeros)
//   Samples  48-511: Sequence counter (58 complete 48-bit counter values)
//                    Each counter value spans 8 samples (6 bits per sample)
//                    Counter increments once per 8 samples
//                    Rollover after 719 days @ 40 MHz sampling
//
// Test mode generates valid sync pattern, audio, and incrementing counter.
// RF data (lower 10 bits) is either ADC data or test pattern (0-1020).
always @ (posedge clock, negedge nReset) begin
	if (!nReset) begin
		adcData <= 10'd0;
		testData <= 10'd0;
		sequenceCount <= 48'd0;
		sample_in_frame <= 9'd0;
		audio_left_latch <= 12'd0;
		audio_right_latch <= 12'd0;
		pcm_left_latch <= 24'd0;
		pcm_right_latch <= 24'd0;
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
        case (sample_in_frame)
            // Sync pattern (samples 0-31): 192-bit pattern
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
            9'd16: top_6_bits <= SYNC_PATTERN[101:96];
            9'd17: top_6_bits <= SYNC_PATTERN[107:102];
            9'd18: top_6_bits <= SYNC_PATTERN[113:108];
            9'd19: top_6_bits <= SYNC_PATTERN[119:114];
            9'd20: top_6_bits <= SYNC_PATTERN[125:120];
            9'd21: top_6_bits <= SYNC_PATTERN[131:126];
            9'd22: top_6_bits <= SYNC_PATTERN[137:132];
            9'd23: top_6_bits <= SYNC_PATTERN[143:138];
            9'd24: top_6_bits <= SYNC_PATTERN[149:144];
            9'd25: top_6_bits <= SYNC_PATTERN[155:150];
            9'd26: top_6_bits <= SYNC_PATTERN[161:156];
            9'd27: top_6_bits <= SYNC_PATTERN[167:162];
            9'd28: top_6_bits <= SYNC_PATTERN[173:168];
            9'd29: top_6_bits <= SYNC_PATTERN[179:174];
            9'd30: top_6_bits <= SYNC_PATTERN[185:180];
            9'd31: top_6_bits <= SYNC_PATTERN[191:186];

            // ADC128 audio (samples 32-35): 12-bit L/R
            9'd32: top_6_bits <= audio_left_latch[11:6];
            9'd33: top_6_bits <= audio_left_latch[5:0];
            9'd34: top_6_bits <= audio_right_latch[11:6];
            9'd35: top_6_bits <= audio_right_latch[5:0];

            // Reserved block 1 (samples 36-37)
            9'd36: top_6_bits <= 6'd0;
            9'd37: top_6_bits <= 6'd0;

            // PCM1802 audio (samples 38-45): 24-bit L/R
            9'd38: top_6_bits <= pcm_left_latch[23:18];
            9'd39: top_6_bits <= pcm_left_latch[17:12];
            9'd40: top_6_bits <= pcm_left_latch[11:6];
            9'd41: top_6_bits <= pcm_left_latch[5:0];
            9'd42: top_6_bits <= pcm_right_latch[23:18];
            9'd43: top_6_bits <= pcm_right_latch[17:12];
            9'd44: top_6_bits <= pcm_right_latch[11:6];
            9'd45: top_6_bits <= pcm_right_latch[5:0];

            // Reserved block 2 (samples 46-47)
            9'd46: top_6_bits <= 6'd0;
            9'd47: top_6_bits <= 6'd0;

            // Sequence counter (samples 48-511): 48-bit counter spread across 8 samples
            // Each 8-sample block contains same counter value
            // Bits [5:0] at offset 0, [11:6] at offset 1, ..., [47:42] at offset 7
            default: begin
                case ((sample_in_frame - 9'd48) % 9'd8)
                    9'd0: top_6_bits <= sequenceCount[5:0];
                    9'd1: top_6_bits <= sequenceCount[11:6];
                    9'd2: top_6_bits <= sequenceCount[17:12];
                    9'd3: top_6_bits <= sequenceCount[23:18];
                    9'd4: top_6_bits <= sequenceCount[29:24];
                    9'd5: top_6_bits <= sequenceCount[35:30];
                    9'd6: top_6_bits <= sequenceCount[41:36];
                    9'd7: top_6_bits <= sequenceCount[47:42];
                endcase
            end
        endcase
		
		// Increment frame position
		if (sample_in_frame == 9'd511) begin
			sample_in_frame <= 9'd0;
		end else begin
			sample_in_frame <= sample_in_frame + 9'd1;
		end
		
		// 48-bit sequence counter increment logic
		// Increment counter every 8 samples in the counter region (samples 48-511)
		// Counter wraps at 2^48 for ~719 day rollover
		if (sample_in_frame >= 9'd48 && ((sample_in_frame - 9'd48) % 9'd8 == 9'd7)) begin
			// Increment at the end of each 8-sample block
			sequenceCount <= sequenceCount + 48'd1;
		end
	end
end

endmodule