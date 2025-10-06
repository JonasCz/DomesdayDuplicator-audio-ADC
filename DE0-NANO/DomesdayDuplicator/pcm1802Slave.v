module pcm1802Slave (
// System
input  wire        clk_40MHz,
input  wire        nReset,

// Serial audio interface (master signals out)
output reg         bck,
output reg         lrck,
output reg         scki,
input  wire        dout,

// Captured outputs
output reg  [23:0] left_out,
output reg  [23:0] right_out,
output reg         sample_ready
);

// Generate clocks from 40 MHz base
// SCKI = 20 MHz (toggle every cycle)
always @(posedge clk_40MHz or negedge nReset) begin
    if (!nReset)
        scki <= 1'b0;
    else
        scki <= ~scki;
end

// LRCK target = 78.125 kHz, BCK = 64 * LRCK = 5.0 MHz
// Derive BCK = 40 MHz / 8 = 5 MHz, LRCK = toggle every 32 BCK cycles
reg [2:0] bck_div;
wire bck_tick = (bck_div == 3'd3); // toggle at 4 ticks -> 5 MHz
always @(posedge clk_40MHz or negedge nReset) begin
    if (!nReset) begin
        bck_div <= 3'd0;
        bck <= 1'b0;
    end else begin
        bck_div <= bck_div + 3'd1;
        if (bck_tick) begin
            bck_div <= 3'd0;
            bck <= ~bck;
        end
    end
end

// LRCK generation: 32 BCK pulses per half-frame (I2S 32-bit per channel)
reg [5:0] bck_count;
always @(posedge bck or negedge nReset) begin
    if (!nReset) begin
        bck_count <= 6'd0;
        lrck <= 1'b0;
    end else begin
        if (bck_count == 6'd31) begin
            bck_count <= 6'd0;
            lrck <= ~lrck;
        end else begin
            bck_count <= bck_count + 6'd1;
        end
    end
end

// Data capture: Left-justified, 24-bit MSB-first; per datasheet DOUT valid
// after BCK falling edge, so sample on BCK rising edges
reg [4:0] bit_index;
reg [23:0] shift_reg;
reg        capture_active;
reg        lrck_d;
reg        current_left;

always @(posedge bck or negedge nReset) begin
    if (!nReset) begin
        bit_index <= 5'd0;
        shift_reg <= 24'd0;
        left_out <= 24'd0;
        right_out <= 24'd0;
        sample_ready <= 1'b0;
        capture_active <= 1'b0;
        lrck_d <= 1'b0;
        current_left <= 1'b1;
    end else begin
        sample_ready <= 1'b0;
        // Detect LRCK edge
        lrck_d <= lrck;
        if (lrck_d != lrck) begin
            // Start a new channel capture at LRCK transition and latch MSB now (left-justified)
            capture_active <= 1'b1;
            // First bit (MSB) is valid immediately after LRCK transition
            shift_reg <= {shift_reg[22:0], dout};
            bit_index <= 5'd1; // already captured 1 bit
            // PCM1802: LRCK = 0 -> left channel
            current_left <= (lrck == 1'b0);
        end else if (capture_active) begin
            if (bit_index < 5'd24) begin
                // Shift in the next bit
                shift_reg <= {shift_reg[22:0], dout};
                // If this was the 24th bit, commit using the just-shifted value
                if (bit_index == 5'd23) begin
                    if (current_left) begin
                        left_out <= {shift_reg[22:0], dout};
                    end else begin
                        right_out <= {shift_reg[22:0], dout};
                        sample_ready <= 1'b1; // Both channels now valid
                    end
                    capture_active <= 1'b0; // wait for next LRCK edge
                end
                bit_index <= bit_index + 5'd1;
            end
        end
    end
end

endmodule
