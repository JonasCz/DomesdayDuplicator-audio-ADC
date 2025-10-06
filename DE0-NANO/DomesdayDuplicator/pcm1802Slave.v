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

// Data capture: I2S format, 24 MSBs valid after LRCK edge, sample on BCK falling edges
reg [4:0] bit_index;
reg [23:0] shift_reg;
reg        capture_active;
reg        lrck_d;
reg        current_left;

always @(negedge bck or negedge nReset) begin
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
            // Start a new channel capture after LRCK transition
            capture_active <= 1'b1;
            bit_index <= 5'd0;
            shift_reg <= 24'd0;
            // I2S standard: LRCK = 0 -> left channel
            current_left <= (lrck == 1'b0);
        end else if (capture_active) begin
            // bit_index 0: alignment bit (discard)
            if (bit_index == 5'd0) begin
                bit_index <= 5'd1;
            end else if (bit_index <= 5'd24) begin
                shift_reg <= {shift_reg[22:0], dout};
                bit_index <= bit_index + 5'd1;
                if (bit_index == 5'd24) begin
                    // Completed 24 data bits for this channel
                    if (current_left) begin
                        left_out <= shift_reg;
                    end else begin
                        right_out <= shift_reg;
                        sample_ready <= 1'b1; // Both channels now valid
                    end
                    capture_active <= 1'b0; // wait for next LRCK edge
                end
            end
        end
    end
end

endmodule
