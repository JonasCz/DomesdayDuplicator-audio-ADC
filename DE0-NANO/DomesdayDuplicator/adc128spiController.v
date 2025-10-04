/************************************************************************
	
	adc128spiController.v
	SPI Controller for ADC128S022 audio ADC
	
	Domesday Duplicator - LaserDisc RF sampler
	Copyright (C) 2025 Jonas Czech
	
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
	
************************************************************************/

module adc128spiController (
	// System clock and reset
	input wire clk_40MHz,
	input wire nReset,
	
	// SPI interface to ADC128S022
	output reg spi_cs_n,        // Chip select (active low)
	output reg spi_sclk,        // Serial clock (2.5 MHz)
	output reg spi_din,         // Data to ADC (channel select)
	input wire spi_dout,        // Data from ADC (conversion result)
	
	// Audio output (to dataGenerator)
	output reg [11:0] audio_left,
	output reg [11:0] audio_right,
	output reg audio_ready       // Pulses every 512 RF clocks
);

// Clock divider: 40 MHz / 16 = 2.5 MHz
// This creates an enable pulse every 16 clocks
reg [3:0] clk_div;
wire sclk_enable = (clk_div == 4'd15);

always @(posedge clk_40MHz, negedge nReset) begin
	if (!nReset)
		clk_div <= 4'd0;
	else
		clk_div <= clk_div + 4'd1;  // Wraps at 16
end

// SPI state machine
reg [4:0] bit_count;           // 0-15 for 16 SCLK cycles
reg [11:0] shift_reg;          // Shift register for received data
reg channel_select;            // 0 = left (CH0), 1 = right (CH1)
reg [8:0] sample_counter;      // Counts to 256 (for 512 RF clocks total)
reg spi_active;                // Indicates SPI transaction in progress

always @(posedge clk_40MHz, negedge nReset) begin
	if (!nReset) begin
		spi_cs_n <= 1'b1;
		spi_sclk <= 1'b0;
		spi_din <= 1'b0;
		bit_count <= 5'd0;
		shift_reg <= 12'd0;
		audio_left <= 12'd0;
		audio_right <= 12'd0;
		audio_ready <= 1'b0;
		channel_select <= 1'b0;
		sample_counter <= 9'd0;
		spi_active <= 1'b0;
	end else begin
		audio_ready <= 1'b0;  // Default: clear ready flag
		
		// Sample counter increments every clock
		// We trigger new conversions every 256 clocks
		// Since we need 2 conversions (L+R), total is 512 RF clocks
		sample_counter <= sample_counter + 9'd1;
		
		// Start new conversion when counter reaches 255 and no active SPI
		if (sample_counter == 9'd255 && !spi_active) begin
			spi_cs_n <= 1'b0;     // Assert CS to start conversion
			spi_active <= 1'b1;
			bit_count <= 5'd0;
		end
		
		if (sclk_enable && spi_active) begin
			// Toggle SCLK
			spi_sclk <= ~spi_sclk;
			
			if (!spi_sclk) begin  
				// Rising edge of SCLK - setup data
				// Send channel select bits during first 3 clocks
				// ADC128S022 expects 3-bit address: 000 for CH0, 001 for CH1
				if (bit_count < 5'd3) begin
					if (bit_count == 5'd0)
						spi_din <= 1'b0;  // Bit 2 of address
					else if (bit_count == 5'd1)
						spi_din <= 1'b0;  // Bit 1 of address
					else  // bit_count == 5'd2
						spi_din <= channel_select;  // Bit 0: 0=CH0, 1=CH1
				end else begin
					spi_din <= 1'b0;  // Don't care bits
				end
				
			end else begin  
				// Falling edge of SCLK - sample data
				// Data valid after 4th clock, 12 bits total
				if (bit_count >= 5'd4 && bit_count <= 5'd15)
					shift_reg <= {shift_reg[10:0], spi_dout};
				
				// Increment bit counter
				bit_count <= bit_count + 5'd1;
				
				// After 16 clocks, conversion complete
				if (bit_count == 5'd15) begin
					if (channel_select == 1'b0) begin
						// Just finished left channel
						audio_left <= shift_reg;
						channel_select <= 1'b1;
						spi_cs_n <= 1'b1;      // De-assert CS
						spi_active <= 1'b0;
						bit_count <= 5'd0;
						shift_reg <= 12'd0;
						sample_counter <= 9'd0; // Reset for next channel
					end else begin
						// Just finished right channel
						audio_right <= shift_reg;
						channel_select <= 1'b0;
						spi_cs_n <= 1'b1;      // De-assert CS
						spi_active <= 1'b0;
						bit_count <= 5'd0;
						shift_reg <= 12'd0;
						sample_counter <= 9'd0;
						audio_ready <= 1'b1;   // Signal both channels ready
					end
				end
			end
		end
	end
end

endmodule

