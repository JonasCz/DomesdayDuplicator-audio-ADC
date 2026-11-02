/************************************************************************

    applicationPll_bb.v

    Black-box declaration of the capture gateware's PLL
    Domesday Duplicator - LaserDisc RF sampler
    SPDX-FileCopyrightText: 2026 Jonas Czech
    SPDX-License-Identifier: GPL-3.0-or-later

    The ports of applicationPll.v and nothing else, so that the top level can
    be linted without Altera's altpll, which has no free model. Never
    compiled into a bitstream: the .qsf names applicationPll.v instead.

************************************************************************/

module applicationPll (
    input  inclk0,
    output c0,
    output c1,
    output c2,
    output locked
);

endmodule
