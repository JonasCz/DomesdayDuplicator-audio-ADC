/************************************************************************

    sdramModel.v

    Behavioural model of the IS42S16160B SDRAM, with a protocol checker
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    A test fixture, never compiled into a bitstream. It stands in for the
    DE0-Nano's 256 Mb SDRAM in the testbenches of sdramController.v and
    sdramBuffer.v, and it is this project's own: it implements what the
    capture buffer uses of the part and checks the controller against the
    datasheet while it does.

    What it implements:

      - storage, four banks of RowsPerBank rows of 512 sixteen-bit words, so
        a testbench can use a small ring and still reach every bank. Never
        written words read back as X, which a testbench comparing data sees.
      - the mode register this design programs - full-page bursts,
        sequential, CAS latency 3, burst writes - and refusal of any other.
      - full-page WRITE and READ bursts, terminated by BURST STOP or
        PRECHARGE as the datasheet describes: data on the edge of a BURST STOP
        or PRECHARGE terminating a write is not written, and a read terminated
        on edge p delivers its last word at edge p + 2.
      - read data driven with the part's output timing: the previous word held
        for tOH after an edge, then X until tAC, then the new word. A
        controller that captured on the wrong edge reads X.
      - DQM: write masking with no latency, read output disable two edges on.

    What it checks, each failure counted in `errors` and printed:

      - power-up: 200 us of NOP or deselect with CKE and DQM high, then
        PRECHARGE ALL, at least eight AUTO REFRESH and the mode register
        before any ACTIVE
      - tRCD, tRP, tRC (ACT to ACT and REF to anything), tRAS minimum and
        maximum, tRRD, tDPL and tMRD, all against the -7 grade's figures in
        nanoseconds, so the check does not depend on the clock the
        testbench happens to run
      - commands to a bank in the wrong state: ACTIVE to an open bank, READ or
        WRITE to a closed one, REFRESH or the mode register with a bank open
      - a full-page burst running past column 511, and a READ or WRITE issued
        while another burst is still running, neither of which this design
        ever means to do
      - write data that is X or Z on a byte DQM does not mask
      - the bus driven by both sides at once
      - the refresh rate: from the end of power-up the controller owes one
        refresh every 64 ms / 8192 = 7.8125 us, and owing more than eight -
        the most the part allows to be postponed - is a failure. maximum_debt
        and maximum_refresh_gap record how close it came.

    Self refresh, power-down, clock suspend, auto precharge and burst lengths
    other than full page are not implemented, because the design does not use
    them; using one is reported as an error.

    Clocked by the SDRAM's own clock, which the testbench makes lead the
    controller's clock as the board does. Blocking assignments in a clocked
    process, as models of external devices are written: each edge is handled
    completely, in order, before the next.

************************************************************************/

`timescale 1ns / 1ps

module sdramModel #(
    parameter integer RowsPerBank = 8192
) (
    input        clock,
    input        cke,
    input        cs_n,
    input        ras_n,
    input        cas_n,
    input        we_n,
    input [ 1:0] ba,
    input [12:0] addr,
    input [ 1:0] dqm,
    inout [15:0] dq
);

    // -7 speed grade, nanoseconds
    localparam real T_RCD = 20.0;
    localparam real T_RP = 20.0;
    localparam real T_RC = 67.5;
    localparam real T_RAS_MIN = 45.0;
    localparam real T_RAS_MAX = 120000.0;
    localparam real T_RRD = 14.0;
    localparam real T_DPL = 14.0;
    localparam real T_MRD = 15.0;
    localparam real T_AC = 5.4;
    localparam real T_OH = 2.7;
    localparam real T_POWER_UP = 200000.0;
    localparam real T_REFI = 7812.5;

    localparam integer MAX_POSTPONED = 8;
    localparam integer INIT_REFRESHES = 8;
    localparam integer ROW_WORDS = 512;
    localparam integer CAS_LATENCY = 3;

    // The one mode this model implements, and this design programs
    localparam [12:0] MODE_VALUE = 13'h037;

    localparam real LONG_AGO = -1.0e9;

    // A read burst not yet told to stop. Far enough off never to arrive, and
    // small enough that adding the CAS latency to it cannot overflow.
    localparam integer NEVER = 32'h3FFF_FFFF;

    reg     [15:0] memory               [0:4*RowsPerBank*ROW_WORDS-1];

    // Bank state
    reg            bank_open            [                        0:3];
    integer        bank_row             [                        0:3];
    real           act_time             [                        0:3];
    real           pre_time             [                        0:3];
    real           last_write_time      [                        0:3];
    reg            ras_max_reported     [                        0:3];

    real           last_act_time;
    integer        last_act_bank;
    real           last_ref_time;
    real           last_mrs_time;

    // Power-up
    reg            powered;
    real           power_time;
    reg            init_precharged;
    integer        init_refreshes;
    reg            mode_set;
    reg            initialised;

    // The burst in progress, if any
    reg            read_active;
    integer        read_bank;
    integer        read_row;
    integer        read_column;
    integer        read_command_cycle;
    integer        read_stop_cycle;

    reg            write_active;
    integer        write_bank;
    integer        write_row;
    integer        write_column;
    integer        write_command_cycle;

    // Refresh accounting
    real           refresh_origin;
    integer        refreshes_done;
    integer        maximum_debt;
    real           maximum_refresh_gap;
    real           last_counted_refresh;
    integer        refresh_count;

    // Activity, for a testbench to report
    integer        activates;
    integer        words_written;
    integer        words_read;

    integer        errors;
    integer        cycle;

    // The output drivers
    reg            drive_enable;
    reg     [15:0] drive_value;
    reg     [ 1:0] dqm_previous;

    assign dq = drive_enable ? drive_value : {16{1'bz}};

    integer b;

    initial begin
        for (b = 0; b < 4; b = b + 1) begin
            bank_open[b]        = 1'b0;
            bank_row[b]         = 0;
            act_time[b]         = LONG_AGO;
            pre_time[b]         = LONG_AGO;
            last_write_time[b]  = LONG_AGO;
            ras_max_reported[b] = 1'b0;
        end

        last_act_time        = LONG_AGO;
        last_act_bank        = -1;
        last_ref_time        = LONG_AGO;
        last_mrs_time        = LONG_AGO;
        powered              = 1'b0;
        power_time           = 0.0;
        init_precharged      = 1'b0;
        init_refreshes       = 0;
        mode_set             = 1'b0;
        initialised          = 1'b0;
        read_active          = 1'b0;
        write_active         = 1'b0;
        read_stop_cycle      = 0;
        refresh_origin       = 0.0;
        refreshes_done       = 0;
        maximum_debt         = 0;
        maximum_refresh_gap  = 0.0;
        last_counted_refresh = 0.0;
        refresh_count        = 0;
        activates            = 0;
        words_written        = 0;
        words_read           = 0;
        errors               = 0;
        cycle                = 0;
        drive_enable         = 1'b0;
        drive_value          = 16'd0;
        dqm_previous         = 2'b11;
    end

    task fail;
        input [1023:0] message;
        begin
            errors = errors + 1;
            if (errors <= 20) begin
                $display("sdramModel: ERROR at %0t ns: %0s", $realtime, message);
            end
        end
    endtask

    task check_since;
        input real since;
        input real minimum;
        input [1023:0] message;
        begin
            if (($realtime - since) < minimum - 0.001) begin
                errors = errors + 1;
                if (errors <= 20) begin
                    $display("sdramModel: ERROR at %0t ns: %0s (%0.3f ns, minimum %0.3f)",
                             $realtime, message, $realtime - since, minimum);
                end
            end
        end
    endtask

    function integer address_of;
        input integer bank;
        input integer row;
        input integer column;
        begin
            address_of = ((bank * RowsPerBank) + row) * ROW_WORDS + column;
        end
    endfunction

    // Close a bank on a PRECHARGE, checking what closing it requires
    task precharge_bank;
        input integer bank;
        begin
            if (bank_open[bank]) begin
                check_since(act_time[bank], T_RAS_MIN, "tRAS: PRECHARGE too soon after ACTIVE");
                check_since(last_write_time[bank], T_DPL,
                            "tDPL: PRECHARGE too soon after the last written word");
                bank_open[bank] = 1'b0;
                pre_time[bank]  = $realtime;
            end

            if (read_active && (read_bank == bank) && (read_stop_cycle > cycle + 1)) begin
                read_stop_cycle = cycle + 1;
            end

            if (write_active && (write_bank == bank)) begin
                write_active = 1'b0;
            end
        end
    endtask

    reg     [ 3:0] command;
    reg            is_nop;
    reg            terminating_write;
    integer        bank_index;
    integer        element;
    integer        debt;
    integer        required;
    reg     [15:0] word;
    reg     [15:0] stored;

    always @(posedge clock) begin
        cycle             = cycle + 1;
        terminating_write = 1'b0;

        // Contention: on the edge, the bus has to hold what this model drove
        if (drive_enable && (dq !== drive_value)) begin
            fail("data bus driven by the controller while the SDRAM is driving it");
        end

        // Row open too long
        for (b = 0; b < 4; b = b + 1) begin
            if (bank_open[b] && !ras_max_reported[b]
                && (($realtime - act_time[b]) > T_RAS_MAX)) begin
                fail("tRAS maximum: a row has been open for more than 120 us");
                ras_max_reported[b] = 1'b1;
            end
        end

        // Refresh owed
        if (initialised) begin
            required = $rtoi(($realtime - refresh_origin) / T_REFI);
            debt     = required - refreshes_done;
            if (debt > maximum_debt) begin
                maximum_debt = debt;
            end
            if (debt > MAX_POSTPONED) begin
                fail("refresh starved: more than eight refreshes postponed");
                // Reported once per shortfall rather than on every edge
                refreshes_done = required;
            end
        end

        if (!cke) begin
            if (powered) begin
                fail("CKE low after power-up: power-down and suspend are not used");
            end
        end else begin
            if (!powered) begin
                powered    = 1'b1;
                power_time = $realtime;
            end

            if (!mode_set && (dqm !== 2'b11)) begin
                fail("DQM must be high until the mode register is set");
            end

            if ((^{cs_n, ras_n, cas_n, we_n}) === 1'bx) begin
                fail("command inputs are X or Z with CKE high");
                command = 4'b1111;
            end else begin
                command = {cs_n, ras_n, cas_n, we_n};
            end

            is_nop = command[3] || (command[2:0] == 3'b111);

            if (!is_nop && (($realtime - power_time) < T_POWER_UP)) begin
                fail("command before the 200 us power-up wait is over");
            end

            if (!is_nop && !init_precharged && !((command[2:0] == 3'b010) && addr[10])) begin
                fail("the first command after power-up must be PRECHARGE ALL");
            end

            if (!is_nop) begin
                check_since(last_mrs_time, T_MRD, "tMRD: command too soon after the mode register");
                bank_index = ba;

                case (command[2:0])
                    // ACTIVE
                    3'b011: begin
                        if (!initialised) begin
                            fail("ACTIVE before power-up is complete");
                        end
                        if (bank_open[bank_index]) begin
                            fail("ACTIVE to a bank that is already open");
                        end
                        if (addr >= RowsPerBank) begin
                            fail("ACTIVE to a row this model does not have");
                        end
                        check_since(pre_time[bank_index], T_RP,
                                    "tRP: ACTIVE too soon after PRECHARGE");
                        check_since(act_time[bank_index], T_RC,
                                    "tRC: ACTIVE too soon after ACTIVE");
                        check_since(last_ref_time, T_RC, "tRC: ACTIVE too soon after REFRESH");
                        if (last_act_bank != bank_index) begin
                            check_since(last_act_time, T_RRD,
                                        "tRRD: ACTIVE too soon after another bank's");
                        end

                        bank_open[bank_index]        = 1'b1;
                        bank_row[bank_index]         = addr;
                        act_time[bank_index]         = $realtime;
                        ras_max_reported[bank_index] = 1'b0;
                        last_act_time                = $realtime;
                        last_act_bank                = bank_index;
                        activates                    = activates + 1;
                    end

                    // READ
                    3'b101: begin
                        if (!bank_open[bank_index]) begin
                            fail("READ to a bank that is not open");
                        end
                        if (addr[10]) begin
                            fail("READ with auto precharge, which this design does not use");
                        end
                        if ((read_active && (read_stop_cycle >= cycle)) || write_active) begin
                            fail("READ while another burst is still running");
                        end
                        check_since(act_time[bank_index], T_RCD,
                                    "tRCD: READ too soon after ACTIVE");

                        read_active        = 1'b1;
                        read_bank          = bank_index;
                        read_row           = bank_row[bank_index];
                        read_column        = addr[8:0];
                        read_command_cycle = cycle;
                        read_stop_cycle    = NEVER;
                    end

                    // WRITE
                    3'b100: begin
                        if (!bank_open[bank_index]) begin
                            fail("WRITE to a bank that is not open");
                        end
                        if (addr[10]) begin
                            fail("WRITE with auto precharge, which this design does not use");
                        end
                        if ((read_active && (read_stop_cycle + CAS_LATENCY > cycle))
                            || write_active) begin
                            fail("WRITE while another burst is still running");
                        end
                        check_since(act_time[bank_index], T_RCD,
                                    "tRCD: WRITE too soon after ACTIVE");

                        write_active        = 1'b1;
                        write_bank          = bank_index;
                        write_row           = bank_row[bank_index];
                        write_column        = addr[8:0];
                        write_command_cycle = cycle;
                    end

                    // BURST STOP: the data on this edge is not written
                    3'b110: begin
                        if (write_active) begin
                            write_active      = 1'b0;
                            terminating_write = 1'b1;
                        end
                        if (read_active && (read_stop_cycle > cycle + 1)) begin
                            read_stop_cycle = cycle + 1;
                        end
                    end

                    // PRECHARGE, one bank or all
                    3'b010: begin
                        if (write_active && (addr[10] || (write_bank == bank_index))) begin
                            terminating_write = 1'b1;
                        end

                        if (addr[10]) begin
                            for (b = 0; b < 4; b = b + 1) begin
                                precharge_bank(b);
                            end
                            init_precharged = 1'b1;
                        end else begin
                            precharge_bank(bank_index);
                        end
                    end

                    // AUTO REFRESH
                    3'b001: begin
                        for (b = 0; b < 4; b = b + 1) begin
                            if (bank_open[b]) begin
                                fail("REFRESH with a bank open");
                            end
                            check_since(pre_time[b], T_RP, "tRP: REFRESH too soon after PRECHARGE");
                        end
                        check_since(last_ref_time, T_RC, "tRC: REFRESH too soon after REFRESH");
                        if (read_active && (read_stop_cycle + CAS_LATENCY > cycle)) begin
                            fail("REFRESH while a read burst is still running");
                        end

                        last_ref_time = $realtime;
                        refresh_count = refresh_count + 1;

                        if (initialised) begin
                            if (($realtime - last_counted_refresh) > maximum_refresh_gap) begin
                                maximum_refresh_gap = $realtime - last_counted_refresh;
                            end
                            last_counted_refresh = $realtime;

                            // Up to eight may be pulled in early; any beyond
                            // that earn nothing
                            required             = $rtoi(($realtime - refresh_origin) / T_REFI);
                            if (refreshes_done < required + MAX_POSTPONED) begin
                                refreshes_done = refreshes_done + 1;
                            end
                        end else begin
                            init_refreshes = init_refreshes + 1;
                        end
                    end

                    // LOAD MODE REGISTER
                    default: begin
                        for (b = 0; b < 4; b = b + 1) begin
                            if (bank_open[b]) begin
                                fail("mode register set with a bank open");
                            end
                            check_since(pre_time[b], T_RP,
                                        "tRP: mode register too soon after PRECHARGE");
                        end
                        check_since(last_ref_time, T_RC,
                                    "tRC: mode register too soon after REFRESH");
                        if ((addr !== MODE_VALUE) || (ba !== 2'b00)) begin
                            fail("mode register is not full page, sequential, CL3, burst write");
                        end

                        last_mrs_time = $realtime;
                        mode_set      = 1'b1;
                    end
                endcase

                if (!initialised && mode_set && (init_refreshes >= INIT_REFRESHES)) begin
                    initialised          = 1'b1;
                    refresh_origin       = $realtime;
                    last_counted_refresh = $realtime;
                end
            end
        end

        // Write data. The WRITE command's own edge carries the first word, and
        // a terminating command's edge carries nothing.
        if (write_active && !terminating_write) begin
            element = cycle - write_command_cycle;

            if ((write_column + element) >= ROW_WORDS) begin
                fail("full-page write burst ran past the end of the row");
                write_active = 1'b0;
            end else begin
                stored = memory[address_of(write_bank, write_row, write_column+element)];
                word   = dq;

                if (!dqm[0]) begin
                    if ((^word[7:0]) === 1'bx) begin
                        fail("write data low byte is X or Z");
                    end
                    stored[7:0] = word[7:0];
                end
                if (!dqm[1]) begin
                    if ((^word[15:8]) === 1'bx) begin
                        fail("write data high byte is X or Z");
                    end
                    stored[15:8] = word[15:8];
                end

                if (!dqm[0] || !dqm[1]) begin
                    memory[address_of(write_bank, write_row, write_column+element)] = stored;
                    last_write_time[write_bank] = $realtime;
                    words_written = words_written + 1;
                end
            end
        end

        // Read data. Element k of a READ registered on edge n is valid on edge
        // n + CL + k, so it is launched from edge n + CL - 1 + k, which is this
        // one if element below comes out non-negative.
        if (read_active && (cycle <= read_stop_cycle)) begin
            element = cycle - read_command_cycle - (CAS_LATENCY - 1);

            if (element >= 0) begin
                if ((read_column + element) >= ROW_WORDS) begin
                    fail("full-page read burst ran past the end of the row");
                    read_active = 1'b0;
                    drive_enable <= #(T_OH) 1'b0;
                end else if (dqm_previous !== 2'b00) begin
                    // DQM two edges before the word is valid masks it
                    drive_enable <= #(T_OH) 1'b0;
                end else begin
                    word = memory[address_of(read_bank, read_row, read_column+element)];
                    drive_enable <= #(T_OH) 1'b1;
                    drive_value  <= #(T_OH) {16{1'bx}};
                    drive_value  <= #(T_AC) word;
                    words_read = words_read + 1;
                end
            end else begin
                drive_enable <= #(T_OH) 1'b0;
            end
        end else begin
            if (read_active && (cycle > read_stop_cycle)) begin
                read_active = 1'b0;
            end
            drive_enable <= #(T_OH) 1'b0;
        end

        dqm_previous = dqm;
    end

endmodule
