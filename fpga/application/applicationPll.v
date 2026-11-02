/************************************************************************

    applicationPll.v

    The capture gateware's PLL
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    Why there are two PLL files. fpga/common/IPpllGenerator.v makes the one
    80 MHz clock, and it is compiled into the factory image, which reaches a
    unit by JTAG once and is never updated in the field (fpga/factory/README.md).
    The SDRAM capture buffer needs two more clocks from the same PLL, and
    adding them to the shared file would be a change to the factory image for
    the sake of a feature the factory image does not have. So the application
    image has its own PLL here, and the factory image keeps IPpllGenerator
    exactly as it is.

    One PLL rather than a second one beside the original, so that the three
    clocks come from one VCO. The design still treats the 80 and 120 MHz
    domains as unrelated - every crossing is a dual-clock FIFO or a
    synchroniser - but a shared VCO keeps their behaviour predictable.

      c0  80 MHz  the system clock, everything but the SDRAM controller.
                  Exactly the 50 x 8 / 5 output IPpllGenerator makes, with the
                  same zero phase and the same compensation, so nothing that
                  ran from the old clock sees a different one.
      c1  120 MHz the SDRAM controller and the I/O registers on its pins
      c2  120 MHz the same frequency shifted -3.5 ns, driven onto DRAM_CLK, so
                  that the SDRAM's clock edge arrives ahead of the controller's.
                  The budget behind -3.5 ns is in sdram-capture-buffer.md; it
                  is an estimate from datasheet figures and a guess at the
                  board, and TimeQuest is what confirms it.

    locked holds the design in reset until the clocks are stable.

    The parameter block is altpll's own, written out in the same form the
    MegaWizard writes it in IPpllGenerator.v, so the two files can be read
    side by side and the PLL changed by editing these values. Like
    IPpllGenerator.v this has no free simulation model and is not linted;
    applicationPll_bb.v is the declaration that stands in for it.

************************************************************************/

`timescale 1 ps / 1 ps

module applicationPll (
    input  inclk0,
    output c0,
    output c1,
    output c2,
    output locked
);

    wire [4:0] pll_clocks;

    assign c0 = pll_clocks[0];
    assign c1 = pll_clocks[1];
    assign c2 = pll_clocks[2];

    altpll altpll_component (
        .inclk             ({1'b0, inclk0}),
        .clk               (pll_clocks),
        .activeclock       (),
        .areset            (1'b0),
        .clkbad            (),
        .clkena            ({6{1'b1}}),
        .clkloss           (),
        .clkswitch         (1'b0),
        .configupdate      (1'b0),
        .enable0           (),
        .enable1           (),
        .extclk            (),
        .extclkena         ({4{1'b1}}),
        .fbin              (1'b1),
        .fbmimicbidir      (),
        .fbout             (),
        .fref              (),
        .icdrclk           (),
        .locked            (locked),
        .pfdena            (1'b1),
        .phasecounterselect({4{1'b1}}),
        .phasedone         (),
        .phasestep         (1'b1),
        .phaseupdown       (1'b1),
        .pllena            (1'b1),
        .scanaclr          (1'b0),
        .scanclk           (1'b0),
        .scanclkena        (1'b1),
        .scandata          (1'b0),
        .scandataout       (),
        .scandone          (),
        .scanread          (1'b0),
        .scanwrite         (1'b0),
        .sclkout0          (),
        .sclkout1          (),
        .vcooverrange      (),
        .vcounderrange     ()
    );

    defparam altpll_component.bandwidth_type = "AUTO",
        altpll_component.clk0_divide_by = 5, altpll_component.clk0_duty_cycle = 50,
        altpll_component.clk0_multiply_by = 8, altpll_component.clk0_phase_shift = "0",
        altpll_component.clk1_divide_by = 5, altpll_component.clk1_duty_cycle = 50,
        altpll_component.clk1_multiply_by = 12, altpll_component.clk1_phase_shift = "0",
        altpll_component.clk2_divide_by = 5, altpll_component.clk2_duty_cycle = 50,
        altpll_component.clk2_multiply_by = 12, altpll_component.clk2_phase_shift = "-3500",
        altpll_component.compensate_clock = "CLK0",
        altpll_component.inclk0_input_frequency = 20000,
        altpll_component.intended_device_family = "Cyclone IV E",
        altpll_component.lpm_hint = "CBX_MODULE_PREFIX=applicationPll",
        altpll_component.lpm_type = "altpll", altpll_component.operation_mode = "NORMAL",
        altpll_component.pll_type = "AUTO", altpll_component.port_activeclock = "PORT_UNUSED",
        altpll_component.port_areset = "PORT_UNUSED",
        altpll_component.port_clkbad0 = "PORT_UNUSED",
        altpll_component.port_clkbad1 = "PORT_UNUSED",
        altpll_component.port_clkloss = "PORT_UNUSED",
        altpll_component.port_clkswitch = "PORT_UNUSED",
        altpll_component.port_configupdate = "PORT_UNUSED",
        altpll_component.port_fbin = "PORT_UNUSED", altpll_component.port_inclk0 = "PORT_USED",
        altpll_component.port_inclk1 = "PORT_UNUSED",
        altpll_component.port_locked = "PORT_USED", altpll_component.port_pfdena = "PORT_UNUSED",
        altpll_component.port_phasecounterselect = "PORT_UNUSED",
        altpll_component.port_phasedone = "PORT_UNUSED",
        altpll_component.port_phasestep = "PORT_UNUSED",
        altpll_component.port_phaseupdown = "PORT_UNUSED",
        altpll_component.port_pllena = "PORT_UNUSED",
        altpll_component.port_scanaclr = "PORT_UNUSED",
        altpll_component.port_scanclk = "PORT_UNUSED",
        altpll_component.port_scanclkena = "PORT_UNUSED",
        altpll_component.port_scandata = "PORT_UNUSED",
        altpll_component.port_scandataout = "PORT_UNUSED",
        altpll_component.port_scandone = "PORT_UNUSED",
        altpll_component.port_scanread = "PORT_UNUSED",
        altpll_component.port_scanwrite = "PORT_UNUSED", altpll_component.port_clk0 = "PORT_USED",
        altpll_component.port_clk1 = "PORT_USED", altpll_component.port_clk2 = "PORT_USED",
        altpll_component.port_clk3 = "PORT_UNUSED", altpll_component.port_clk4 = "PORT_UNUSED",
        altpll_component.port_clk5 = "PORT_UNUSED",
        altpll_component.port_clkena0 = "PORT_UNUSED",
        altpll_component.port_clkena1 = "PORT_UNUSED",
        altpll_component.port_clkena2 = "PORT_UNUSED",
        altpll_component.port_clkena3 = "PORT_UNUSED",
        altpll_component.port_clkena4 = "PORT_UNUSED",
        altpll_component.port_clkena5 = "PORT_UNUSED",
        altpll_component.port_extclk0 = "PORT_UNUSED",
        altpll_component.port_extclk1 = "PORT_UNUSED",
        altpll_component.port_extclk2 = "PORT_UNUSED",
        altpll_component.port_extclk3 = "PORT_UNUSED",
        altpll_component.self_reset_on_loss_lock = "OFF", altpll_component.width_clock = 5;

endmodule
