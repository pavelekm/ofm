//-- pkg.sv
//-- Copyright (C) 2022 CESNET z. s. p. o.
//-- Author(s): Daniel Kříž <xkrizd01@vutbr.cz>

//-- SPDX-License-Identifier: BSD-3-Clause


`ifndef INFO_PKG
`define INFO_PKG

package uvm_ptc_info;

    `include "uvm_macros.svh"
    import uvm_pkg::*;

    `include "sync_tag.sv"
    `include "config.sv"
    `include "sequence_item.sv"
    `include "sequencer.sv"
    `include "sequence.sv"
    `include "monitor.sv"
    `include "agent.sv"

endpackage

`endif
