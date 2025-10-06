module adc128spiController (
// System clock and reset
input  wire        clk_40MHz,
input  wire        nReset,

// SPI interface to ADC128S022
output reg         spi_cs_n,     // Chip select (active low)
output reg         spi_sclk,     // Serial clock (2.5 MHz)
output reg         spi_din,      // Data to ADC (channel select)
input  wire        spi_dout,     // Data from ADC (conversion result)

// Audio output (to dataGenerator)
output reg  [11:0] audio_left,
output reg  [11:0] audio_right,
output reg         audio_ready   // Pulses once per L+R pair

);

// 40 MHz -> 2.5 MHz SCLK
// Tick every 8 clocks, drive SCLK edges on ticks
reg [2:0] clk_div;
wire sclk_tick = (clk_div == 3'd7);

always @(posedge clk_40MHz or negedge nReset) begin
	if (!nReset)
		clk_div <= 3'd0;
	else
		clk_div <= clk_div + 3'd1; // wraps at 8
end

// FSM
localparam ST_IDLE  = 2'd0;
localparam ST_PREP  = 2'd1; // CS low, SCLK low, DIN preloaded, wait one tick
localparam ST_SHIFT = 2'd2; // 16 SCLK rising edges

reg [1:0]  state;

// Control word (MSB-first): [7:6]=00, [5:3]=ADD2:ADD0, [2:0]=000
reg [7:0] ctrl;

// Rising-edge counter (0..15 where 1..16 are rising edges in a frame)
reg [4:0] rise_count;

// Shift register and final latched sample
reg [11:0] shift_reg;
reg [11:0] sample_word;

// Channel pipeline: sample you get now belongs to prev_channel;
// we set up next_channel for the next frame.
reg [2:0] prev_channel;
reg [2:0] next_channel;

always @(posedge clk_40MHz or negedge nReset) begin
	if (!nReset) begin
		spi_cs_n     <= 1'b1;
		spi_sclk     <= 1'b0;
		spi_din      <= 1'b0;

		audio_left   <= 12'd0;
		audio_right  <= 12'd0;
		audio_ready  <= 1'b0;

		state        <= ST_IDLE;
		rise_count   <= 5'd0;
		shift_reg    <= 12'd0;
		sample_word  <= 12'd0;

		ctrl         <= 8'h00;
		prev_channel <= 3'd0; // ADC defaults to CH0 after reset
		next_channel <= 3'd0; // Start by requesting CH0
	end else begin
		audio_ready <= 1'b0; // default

		case (state)
			ST_IDLE: begin
				// Compose control word for upcoming frame
				ctrl       <= {2'b00, next_channel, 3'b000};

				// Assert CS, hold SCLK low, preset DIN to first (MSB) bit
				spi_cs_n   <= 1'b0;
				spi_sclk   <= 1'b0;
				spi_din    <= ctrl[7];
				rise_count <= 5'd0;
				shift_reg  <= 12'd0;

				// Hold DIN for at least one tick before first rising edge
				state <= ST_PREP;
			end

			ST_PREP: begin
				// Wait exactly one sclk_tick so DIN is stable before 1st rising edge
				if (sclk_tick) begin
					state <= ST_SHIFT;
				end
			end

			ST_SHIFT: begin
				if (sclk_tick) begin
					if (spi_sclk == 1'b0) begin
						// Rising edge is about to be generated (we set spi_sclk=1 below)
						// ADC latches DIN on this rising edge; we sample DOUT here.
						// Count rising edges 1..16
						// We use the old value of rise_count for decisions and then increment.
						// Bits from DOUT are valid to sample on rising edges 5..16,
						// which corresponds to rise_count values 4..15 before increment.
						if (rise_count >= 5'd4 && rise_count <= 5'd15) begin
							shift_reg <= {shift_reg[10:0], spi_dout};
							if (rise_count == 5'd15) begin
								sample_word <= {shift_reg[10:0], spi_dout};
							end
						end

						// Shift the control word AFTER the ADC latched current bit
						ctrl <= {ctrl[6:0], 1'b0};

						// Advance rising edge count
						rise_count <= rise_count + 5'd1;

						// If that was the 16th rising edge (rise_count was 15), frame is done
						if (rise_count == 5'd15) begin
							// Store the sample according to the previous channel
							case (prev_channel)
								3'd0: audio_left  <= sample_word; // CH0
								3'd1: audio_right <= sample_word; // CH1
								default: ; // ignore other channels
							endcase

							// Pulse 'audio_ready' after CH1 completes (once per L+R pair)
							if (prev_channel == 3'd1) begin
								audio_ready <= 1'b1;
							end

							// Pipeline channel selection
							prev_channel <= next_channel;
							next_channel <= (next_channel == 3'd0) ? 3'd1 : 3'd0;

							// End frame: deassert CS, force SCLK low, go idle
							spi_cs_n <= 1'b1;
							spi_sclk <= 1'b0;
							state    <= ST_IDLE;
						end else begin
							// Normal rising edge: drive SCLK high
							spi_sclk <= 1'b1;
						end
					end else begin
						// Falling edge: ADC changes DOUT shortly after this,
						// so we set up DIN here (stable for next rising edge)
						spi_din  <= ctrl[7];
						spi_sclk <= 1'b0;
					end
				end
			end

			default: state <= ST_IDLE;
		endcase
	end
end

endmodule