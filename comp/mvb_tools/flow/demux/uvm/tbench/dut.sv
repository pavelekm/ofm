//-- dut.sv: Design under test 
//-- Copyright (C) 2022 CESNET z. s. p. o.
//-- Author:   Oliver Gurka <xgurka00@stud.fit.vutbr.cz>

//-- SPDX-License-Identifier: BSD-3-Clause

import test::*;

module DUT (
    input logic     CLK,
    input logic     RST,
    mvb_if.dut_rx   mvb_wr,
    mvb_if.dut_tx mvb_rd [RX_MVB_CNT - 1 : 0]
    );

    localparam int unsigned SEL_WIDTH = $clog2(RX_MVB_CNT);
    localparam int unsigned TOTAL_ITEM_WIDTH = ITEM_WIDTH + SEL_WIDTH;

    logic [ITEMS * ITEM_WIDTH - 1 : 0]                      RX_DATA;
    logic [ITEMS * $clog2(RX_MVB_CNT) - 1 : 0]              RX_SEL;

    logic [RX_MVB_CNT * ITEMS * ITEM_WIDTH - 1 : 0]         tx_mvb_data;
    logic [RX_MVB_CNT * ITEMS - 1 : 0]                      tx_mvb_vld;
    logic [RX_MVB_CNT - 1 : 0]                              tx_mvb_src_rdy;
    logic [RX_MVB_CNT - 1 : 0]                              tx_mvb_dst_rdy;

    for (genvar it = 0; it < ITEMS; it++) begin
        assign RX_DATA[(it+1) * ITEM_WIDTH - 1 -: ITEM_WIDTH] = mvb_wr.DATA[it * TOTAL_ITEM_WIDTH + ITEM_WIDTH - 1 -: ITEM_WIDTH];
        assign RX_SEL[(it+1) * SEL_WIDTH - 1 -: SEL_WIDTH] = mvb_wr.DATA[(it+1) * TOTAL_ITEM_WIDTH -1 -: SEL_WIDTH];
    end

    for (genvar it = 0; it < RX_MVB_CNT; it++) begin
        assign mvb_rd[it].DATA = tx_mvb_data[(it+1) * ITEMS * ITEM_WIDTH - 1 -: ITEMS * ITEM_WIDTH];
        assign mvb_rd[it].VLD = tx_mvb_vld[(it+1) * ITEMS - 1 -: ITEMS];
        assign mvb_rd[it].SRC_RDY = tx_mvb_src_rdy[it];
        assign tx_mvb_dst_rdy[it] = mvb_rd[it].DST_RDY;
    end

    GEN_MVB_DEMUX #(
        .MVB_ITEMS       (ITEMS),
        .DATA_WIDTH  (ITEM_WIDTH),
        .DEMUX_WIDTH (RX_MVB_CNT),
        .DATA_DEMUX  (DATA_DEMUX)
    ) VHDL_DUT_U (
        .CLK        (CLK),
        .RESET      (RST),

        .RX_DATA    (RX_DATA),
        .RX_SEL     (RX_SEL),
        .RX_VLD     (mvb_wr.VLD),
        .RX_SRC_RDY (mvb_wr.SRC_RDY),
        .RX_DST_RDY (mvb_wr.DST_RDY),

        .TX_DATA    (tx_mvb_data),
        .TX_VLD     (tx_mvb_vld),
        .TX_SRC_RDY (tx_mvb_src_rdy),
        .TX_DST_RDY (tx_mvb_dst_rdy)
    );


endmodule
