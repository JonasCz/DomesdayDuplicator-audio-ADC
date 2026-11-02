/************************************************************************

    adc128s022Model.v

    Simulation model of the ADC128S022, with its interface timing checked
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    A test fixture, never compiled into a bitstream. It answers the serial
    interface as the datasheet (TI SNAS334F, sections 6.6 and 7.3.1)
    describes it, and it checks every edge it is given against the same
    section, so a controller that only works because the model is lenient
    cannot pass:

      - a frame opens on CS falling and closes on CS rising, and must hold
        exactly sixteen rising SCLK edges
      - the input is held on the fourth falling edge; falling edges 1 to 4
        clock out zeros and 5 to 16 the result, MSB first, each bit
        undefined from tDHLD after its falling edge until tDACC after it
      - the control word is read from DIN on the first eight rising edges
        and names the input the next frame converts; the first frame after
        power-up converts IN0
      - DIN set-up and hold around every rising edge, CS set-up and hold
        around the rising edges either side of its fall, SCLK at 0.8 to
        3.2 MHz with 40% to 60% duty, and 50 to 200 thousand conversions a
        second

    It implements the one way of opening a frame the controller uses -
    CS falling while SCLK is high - and reports anything else as an error
    rather than modelling it. Only IN0 and IN1 are modelled; a frame that
    converts any other input logs it and holds an undefined value.

    Each completed conversion is logged as the input it converted and the
    code it held, for the testbench to compare with what the controller
    reported.

************************************************************************/

`timescale 1ns / 1ps

module adc128s022Model (
    input        chip_select_n,
    input        serial_clock,
    input        din,
    input [11:0] in0,            // IN0, as the code it converts to
    input [11:0] in1,            // IN1, as the code it converts to

    output reg dout
);

    // Section 6.6, in nanoseconds
    localparam real T_CSH = 10.0;
    localparam real T_CSS = 10.0;
    localparam real T_EN = 30.0;
    localparam real T_DACC = 27.0;
    localparam real T_DHLD = 4.0;
    localparam real T_DS = 10.0;
    localparam real T_DH = 10.0;
    localparam real T_DIS = 20.0;

    // fSCLK 0.8 to 3.2 MHz, duty 40% to 60%, and 50 to 200 ksps
    localparam real MIN_SCLK_PERIOD = 312.5;
    localparam real MAX_SCLK_PERIOD = 1250.0;
    localparam real MIN_DUTY = 0.4;
    localparam real MIN_CONVERSION_PERIOD = 5000.0;
    localparam real MAX_CONVERSION_PERIOD = 20000.0;

    localparam integer LOG_LENGTH = 4096;

    integer         errors;
    integer         conversions;

    reg      [ 2:0] log_channel               [0:LOG_LENGTH-1];
    reg      [11:0] log_value                 [0:LOG_LENGTH-1];

    reg             in_frame;
    integer         rising_count;
    integer         falling_count;
    reg      [ 2:0] control_address;
    reg      [ 2:0] converting;
    reg      [ 7:0] control_shift;
    reg      [11:0] held;
    reg             next_bit;

    realtime        last_rise;
    realtime        last_fall;
    realtime        last_din_change;
    realtime        chip_select_fall;
    realtime        previous_chip_select_fall;
    realtime        sclk_period;
    realtime        conversion_period;

    initial begin
        dout                      = 1'bz;
        errors                    = 0;
        conversions               = 0;
        in_frame                  = 1'b0;
        rising_count              = 0;
        falling_count             = 0;
        control_address           = 3'd0;
        converting                = 3'd0;
        control_shift             = 8'd0;
        held                      = 12'd0;
        last_rise                 = -1.0e9;
        last_fall                 = -1.0e9;
        last_din_change           = -1.0e9;
        sclk_period               = 0.0;
        conversion_period         = 0.0;
        chip_select_fall          = -1.0e9;
        previous_chip_select_fall = -1.0e9;
    end

    task fail;
        input [511:0] what;
        begin
            $display("adc128s022Model: %0s (t=%0t)", what, $realtime);
            errors = errors + 1;
        end
    endtask

    always @(negedge chip_select_n) begin
        if (serial_clock !== 1'b1) begin
            fail("CS fell with SCLK not high");
        end
        if (($realtime - last_rise) < T_CSH) begin
            fail("CS fell inside tCSH of a rising SCLK edge");
        end

        previous_chip_select_fall = chip_select_fall;
        chip_select_fall          = $realtime;
        if (previous_chip_select_fall > 0.0) begin
            conversion_period = chip_select_fall - previous_chip_select_fall;
            if ((conversion_period < MIN_CONVERSION_PERIOD) ||
                (conversion_period > MAX_CONVERSION_PERIOD)) begin
                fail("conversion rate outside 50 to 200 ksps");
            end
        end

        in_frame      = 1'b1;
        rising_count  = 0;
        falling_count = 0;
        converting    = control_address;
        control_shift = 8'd0;

        // Enabled, but nothing has been clocked out yet
        dout <= #(T_EN) 1'bx;
    end

    always @(posedge chip_select_n) begin
        if (in_frame) begin
            if (rising_count != 16) begin
                fail("a frame did not hold exactly sixteen rising SCLK edges");
            end else if (conversions < LOG_LENGTH) begin
                log_channel[conversions] = converting;
                log_value[conversions]   = held;
                conversions              = conversions + 1;
            end
        end

        in_frame = 1'b0;
        dout <= #(T_DIS) 1'bz;
    end

    always @(posedge serial_clock) begin
        if (last_fall > 0.0) begin
            if (($realtime - last_fall) < (MIN_DUTY * sclk_period)) begin
                fail("SCLK low for less than 40% of its period");
            end
        end
        last_rise = $realtime;

        if (in_frame) begin
            if (($realtime - chip_select_fall) < T_CSS) begin
                fail("a rising SCLK edge inside tCSS of CS falling");
            end
            if (($realtime - last_din_change) < T_DS) begin
                fail("DIN changed inside tDS of a rising SCLK edge");
            end

            rising_count = rising_count + 1;
            if (rising_count <= 8) begin
                control_shift = {control_shift[6:0], din};
            end
            if (rising_count == 8) begin
                control_address = control_shift[5:3];
            end
        end
    end

    always @(din) begin
        if (in_frame && (($realtime - last_rise) < T_DH)) begin
            fail("DIN changed inside tDH of a rising SCLK edge");
        end
        last_din_change = $realtime;
    end

    always @(negedge serial_clock) begin
        if (last_fall > 0.0) begin
            sclk_period = $realtime - last_fall;
            if ((sclk_period < MIN_SCLK_PERIOD) || (sclk_period > MAX_SCLK_PERIOD)) begin
                fail("SCLK outside 0.8 to 3.2 MHz");
            end
            if (($realtime - last_rise) < (MIN_DUTY * sclk_period)) begin
                fail("SCLK high for less than 40% of its period");
            end
        end
        last_fall = $realtime;

        if (in_frame) begin
            falling_count = falling_count + 1;

            if (falling_count == 4) begin
                if (converting == 3'd0) begin
                    held = in0;
                end else if (converting == 3'd1) begin
                    held = in1;
                end else begin
                    held = 12'hxxx;
                end
            end

            if (falling_count > 16) begin
                fail("more than sixteen falling SCLK edges in a frame");
                next_bit = 1'bx;
            end else if (falling_count <= 4) begin
                next_bit = 1'b0;
            end else begin
                next_bit = held[16-falling_count];
            end

            dout <= #(T_DHLD) 1'bx;
            dout <= #(T_DACC) next_bit;
        end
    end

endmodule
