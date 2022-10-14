-- dma_calypte.vhd: encapsulates RX and TX of the Calypte DMA controller
-- Copyright (c) 2022 CESNET z.s.p.o.
-- Author(s): Vladislav Valek  <xvalek14@vutbr.cz>
--
-- SPDX-License-Identifier: BSD-3-CLause

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;

-- This core provides simple DMA functionality for both RX and TX directions.
-- The design was primary focused on the lowest latency possible for the
-- transaction from the input of the DMA core to reach its output. The block scheme
-- as well as its connection to the NDK design is provided in the following figure:
--
-- .. figure:: img/tx_calypte_block-dma_whole_block.svg
--     :align: center
--     :scale: 100%
entity DMA_CALYPTE is
    generic(
        -- ==========================================================================================
        -- Global settings
        --
        -- Settings affecting both RX and TX or the top level entity itself
        -- ==========================================================================================
        -- Name of target device, the supported are:
        -- "ULTRASCALE"
        DEVICE : string := "ULTRASCALE";

        -- USER MFB data bus configuration
        -- Defines the total width of User data stream.
        USR_MFB_REGIONS     : natural := 1;
        USR_MFB_REGION_SIZE : natural := 8;
        USR_MFB_BLOCK_SIZE  : natural := 8;
        USR_MFB_ITEM_WIDTH  : natural := 8;

        -- ==========================================================================================
        -- PCIe-side bus settings
        -- ==========================================================================================
        -- Requester Request MFB interface configration, allowed configurations are:
        -- (1,1,8,32)
        PCIE_RQ_MFB_REGIONS     : natural := 2;
        PCIE_RQ_MFB_REGION_SIZE : natural := 1;
        PCIE_RQ_MFB_BLOCK_SIZE  : natural := 8;
        PCIE_RQ_MFB_ITEM_WIDTH  : natural := 32;

        -- Completer Request MFB interface configration, allowed configurations are:
        -- (1,1,8,32)
        PCIE_CQ_MFB_REGIONS     : natural := 2;
        PCIE_CQ_MFB_REGION_SIZE : natural := 1;
        PCIE_CQ_MFB_BLOCK_SIZE  : natural := 8;
        PCIE_CQ_MFB_ITEM_WIDTH  : natural := 32;

        -- Completer Completion MFB interface configration, allowed configurations are:
        -- (1,1,8,32)
        PCIE_CC_MFB_REGIONS     : natural := 2;
        PCIE_CC_MFB_REGION_SIZE : natural := 1;
        PCIE_CC_MFB_BLOCK_SIZE  : natural := 8;
        PCIE_CC_MFB_ITEM_WIDTH  : natural := 32;

        -- Width of User Header Metadata information
        -- on RX: added to header sent to header Buffer in RAM
        -- on TX: extracted from descriptor and propagated to output
        HDR_META_WIDTH : natural := 24;

        -- ==========================================================================================
        -- RX DMA settings
        --
        -- Settings for RX direction of DMA Module
        -- ==========================================================================================
        -- Total number of RX DMA Channels (multiples of 2 at best)
        -- Minimum: 4
        RX_CHANNELS         : natural := 8;
        -- Width of Software and Hardware Descriptor Pointer
        -- Defines width of signals used for these values in DMA Module
        -- Affects logic complexity
        -- Maximum value: 32 (restricted by size of SDP and HDP MI register)
        RX_PTR_WIDTH        : natural := 16;
        -- Maximum size of a User packet (in bytes)
        -- Defines width of Packet length signals.
        -- the maximum is 2**16 - 1
        USR_RX_PKT_SIZE_MAX : natural := 2**12;

        -- =====================================================================
        -- TX DMA settings
        --
        -- Settings for TX direction of DMA Module
        -- =====================================================================
        -- Total number of TX DMA Channels
        -- Minimum value: TX_SEL_CHANNELS*DMA_ENDPOINTS
        TX_CHANNELS         : natural := 8;
        -- Width of Software and Hardware Descriptor Pointer
        -- Defines width of signals used for these values in DMA Module
        -- Affects logic complexity
        -- Maximum value: 32 (restricted by size of SDP and HDP MI register)
        TX_FIFO_DEPTH       : natural := 16;
        -- Maximum size of a User packet (in bytes)
        -- Defines width of Packet length signals.
        -- the maximum is 2**16 - 1
        USR_TX_PKT_SIZE_MAX : natural := 2**12;
        -- Enables the component which merges the outputs of all channel cores to
        -- one output interface (interface number 0)
        CHANNEL_ARBITER_EN : boolean := TRUE;

        -- =====================================================================
        -- Optional settings
        --
        -- Settings for testing and debugging, settings usually left unchanged
        -- at entity-area constants.
        -- =====================================================================
        -- Width of DSP packet and byte statistics counters
        DSP_CNT_WIDTH : natural := 64;
        -- Enable generation of RX/TX side of DMA Module
        RX_GEN_EN     : boolean := TRUE;
        TX_GEN_EN     : boolean := TRUE;
        -- Width of MI bus
        MI_WIDTH      : natural := 32
        );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =====================================================================
        -- RX DMA User-side MFB
        -- =====================================================================
        USR_RX_MFB_META_PKT_SIZE : in std_logic_vector(log2(USR_RX_PKT_SIZE_MAX + 1) -1 downto 0);
        USR_RX_MFB_META_CHAN     : in std_logic_vector(log2(RX_CHANNELS) -1 downto 0);
        USR_RX_MFB_META_HDR_META : in std_logic_vector(HDR_META_WIDTH -1 downto 0);

        USR_RX_MFB_DATA    : in  std_logic_vector(USR_MFB_REGIONS*USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH-1 downto 0);
        USR_RX_MFB_SOF     : in  std_logic_vector(USR_MFB_REGIONS -1 downto 0);
        USR_RX_MFB_EOF     : in  std_logic_vector(USR_MFB_REGIONS -1 downto 0);
        USR_RX_MFB_SOF_POS : in  std_logic_vector(USR_MFB_REGIONS*max(1, log2(USR_MFB_REGION_SIZE)) -1 downto 0);
        USR_RX_MFB_EOF_POS : in  std_logic_vector(USR_MFB_REGIONS*max(1, log2(USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE)) -1 downto 0);
        USR_RX_MFB_SRC_RDY : in  std_logic;
        USR_RX_MFB_DST_RDY : out std_logic := '1';

        -- =====================================================================
        -- TX DMA User-side MFB
        -- =====================================================================
        USR_TX_MFB_META_PKT_SIZE : out std_logic_vector(log2(USR_TX_PKT_SIZE_MAX + 1) -1 downto 0) := (others => '0');
        USR_TX_MFB_META_CHAN     : out std_logic_vector(log2(TX_CHANNELS) -1 downto 0)             := (others => '0');
        USR_TX_MFB_META_HDR_META : out std_logic_vector(HDR_META_WIDTH -1 downto 0)                := (others => '0');

        USR_TX_MFB_DATA    : out std_logic_vector(USR_MFB_REGIONS*USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH-1 downto 0) := (others => '0');
        USR_TX_MFB_SOF     : out std_logic_vector(USR_MFB_REGIONS -1 downto 0)                                                          := (others => '0');
        USR_TX_MFB_EOF     : out std_logic_vector(USR_MFB_REGIONS -1 downto 0)                                                          := (others => '0');
        USR_TX_MFB_SOF_POS : out std_logic_vector(USR_MFB_REGIONS*max(1, log2(USR_MFB_REGION_SIZE)) -1 downto 0)                        := (others => '0');
        USR_TX_MFB_EOF_POS : out std_logic_vector(USR_MFB_REGIONS*max(1, log2(USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE)) -1 downto 0)     := (others => '0');
        USR_TX_MFB_SRC_RDY : out std_logic                                                                                              := '0';
        USR_TX_MFB_DST_RDY : in  std_logic;

        -- =====================================================================
        -- PCIe-side interfaces
        -- =====================================================================
        -- Upstream MFB interface (for sending data to PCIe Endpoints)
        PCIE_RQ_MFB_DATA    : out std_logic_vector(PCIE_RQ_MFB_REGIONS*PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE*PCIE_RQ_MFB_ITEM_WIDTH-1 downto 0);
        PCIE_RQ_MFB_META    : out std_logic_vector(PCIE_RQ_META_WIDTH -1 downto 0);
        PCIE_RQ_MFB_SOF     : out std_logic_vector(PCIE_RQ_MFB_REGIONS -1 downto 0);
        PCIE_RQ_MFB_EOF     : out std_logic_vector(PCIE_RQ_MFB_REGIONS -1 downto 0);
        PCIE_RQ_MFB_SOF_POS : out std_logic_vector(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE)) -1 downto 0);
        PCIE_RQ_MFB_EOF_POS : out std_logic_vector(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE)) -1 downto 0);
        PCIE_RQ_MFB_SRC_RDY : out std_logic;
        PCIE_RQ_MFB_DST_RDY : in  std_logic;

        -- Downstream MFB interface (for sending data from PCIe Endpoints)
        PCIE_CQ_MFB_DATA    : in  std_logic_vector(PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH-1 downto 0);
        PCIE_CQ_MFB_META    : in  std_logic_vector(PCIE_CQ_META_WIDTH -1 downto 0);
        PCIE_CQ_MFB_SOF     : in  std_logic_vector(PCIE_CQ_MFB_REGIONS -1 downto 0);
        PCIE_CQ_MFB_EOF     : in  std_logic_vector(PCIE_CQ_MFB_REGIONS -1 downto 0);
        PCIE_CQ_MFB_SOF_POS : in  std_logic_vector(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE)) -1 downto 0);
        PCIE_CQ_MFB_EOF_POS : in  std_logic_vector(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE)) -1 downto 0);
        PCIE_CQ_MFB_SRC_RDY : in  std_logic;
        PCIE_CQ_MFB_DST_RDY : out std_logic := '1';

        -- Response interface for PCIe CQ requests
        PCIE_CC_MFB_DATA    : out std_logic_vector(PCIE_CC_MFB_REGIONS*PCIE_CC_MFB_REGION_SIZE*PCIE_CC_MFB_BLOCK_SIZE*PCIE_CC_MFB_ITEM_WIDTH-1 downto 0);
        PCIE_CC_MFB_META    : out std_logic_vector(PCIE_CC_META_WIDTH -1 downto 0);
        PCIE_CC_MFB_SOF     : out std_logic_vector(PCIE_CC_MFB_REGIONS -1 downto 0);
        PCIE_CC_MFB_EOF     : out std_logic_vector(PCIE_CC_MFB_REGIONS -1 downto 0);
        PCIE_CC_MFB_SOF_POS : out std_logic_vector(PCIE_CC_MFB_REGIONS*max(1, log2(PCIE_CC_MFB_REGION_SIZE)) -1 downto 0);
        PCIE_CC_MFB_EOF_POS : out std_logic_vector(PCIE_CC_MFB_REGIONS*max(1, log2(PCIE_CC_MFB_REGION_SIZE*PCIE_CC_MFB_BLOCK_SIZE)) -1 downto 0);
        PCIE_CC_MFB_SRC_RDY : out std_logic;
        PCIE_CC_MFB_DST_RDY : in  std_logic;

        -- ==========================================================================================
        -- MI interface for SW access
        -- ==========================================================================================
        MI_ADDR : in  std_logic_vector (MI_WIDTH -1 downto 0);
        MI_DWR  : in  std_logic_vector (MI_WIDTH -1 downto 0);
        MI_BE   : in  std_logic_vector (MI_WIDTH/8-1 downto 0);
        MI_RD   : in  std_logic;
        MI_WR   : in  std_logic;
        MI_DRD  : out std_logic_vector (MI_WIDTH -1 downto 0);
        MI_ARDY : out std_logic;
        MI_DRDY : out std_logic
        );

end entity;

architecture FULL of DMA_CALYPTE is

    constant MI_SPLIT_BASES : slv_array_t(2 -1 downto 0)(MI_WIDTH-1 downto 0) := (
        -- RX DMA
        0 => X"00000000",
        -- TX DMA
        1 => X"00200000");

    signal mi_split_dwr  : slv_array_t(2 -1 downto 0)(MI_WIDTH -1 downto 0);
    signal mi_split_addr : slv_array_t(2 -1 downto 0)(MI_WIDTH -1 downto 0);
    signal mi_split_be   : slv_array_t(2 -1 downto 0)(MI_WIDTH/8 -1 downto 0);
    signal mi_split_rd   : std_logic_vector(2 -1 downto 0);
    signal mi_split_wr   : std_logic_vector(2 -1 downto 0);
    signal mi_split_drd  : slv_array_t(2 -1 downto 0)(MI_WIDTH -1 downto 0);
    signal mi_split_ardy : std_logic_vector(2 -1 downto 0);
    signal mi_split_drdy : std_logic_vector(2 -1 downto 0);
begin

    PCIE_RQ_MFB_META(PCIE_RQ_META_HEADER) <= (others => '0');
    PCIE_RQ_MFB_META(PCIE_RQ_META_PREFIX) <= (others => '0');
    PCIE_RQ_MFB_META(PCIE_RQ_META_FBE)    <= (others => '1');
    PCIE_RQ_MFB_META(PCIE_RQ_META_LBE)    <= (others => '1');

    rx_dma_calypte_g : if (RX_GEN_EN) generate
        rx_dma_calypte_i : entity work.RX_DMA_CALYPTE
            generic map (
                DEVICE   => DEVICE,
                MI_WIDTH => MI_WIDTH,

                USER_RX_MFB_REGIONS     => USR_MFB_REGIONS,
                USER_RX_MFB_REGION_SIZE => USR_MFB_REGION_SIZE,
                USER_RX_MFB_BLOCK_SIZE  => USR_MFB_BLOCK_SIZE,
                USER_RX_MFB_ITEM_WIDTH  => USR_MFB_ITEM_WIDTH,

                PCIE_UP_MFB_REGIONS     => PCIE_RQ_MFB_REGIONS,
                PCIE_UP_MFB_REGION_SIZE => PCIE_RQ_MFB_REGION_SIZE,
                PCIE_UP_MFB_BLOCK_SIZE  => PCIE_RQ_MFB_BLOCK_SIZE,
                PCIE_UP_MFB_ITEM_WIDTH  => PCIE_RQ_MFB_ITEM_WIDTH,

                CHANNELS       => RX_CHANNELS,
                POINTER_WIDTH  => RX_PTR_WIDTH,
                SW_ADDR_WIDTH  => 64,
                CNTRS_WIDTH    => DSP_CNT_WIDTH,
                HDR_META_WIDTH => HDR_META_WIDTH,
                PKT_SIZE_MAX   => USR_RX_PKT_SIZE_MAX,
                TRBUF_FIFO_EN  => FALSE)

            port map (
                CLK   => CLK,
                RESET => RESET,

                MI_ADDR => mi_split_addr(0),
                MI_DWR  => mi_split_dwr(0),
                MI_BE   => mi_split_be(0),
                MI_RD   => mi_split_rd(0),
                MI_WR   => mi_split_wr(0),
                MI_DRD  => mi_split_drd(0),
                MI_ARDY => mi_split_ardy(0),
                MI_DRDY => mi_split_drdy(0),

                USER_RX_MFB_META_HDR_META => USR_RX_MFB_META_HDR_META,
                USER_RX_MFB_META_CHAN     => USR_RX_MFB_META_CHAN,
                USER_RX_MFB_META_PKT_SIZE => USR_RX_MFB_META_PKT_SIZE,

                USER_RX_MFB_DATA    => USR_RX_MFB_DATA,
                USER_RX_MFB_SOF     => USR_RX_MFB_SOF,
                USER_RX_MFB_EOF     => USR_RX_MFB_EOF,
                USER_RX_MFB_SOF_POS => USR_RX_MFB_SOF_POS,
                USER_RX_MFB_EOF_POS => USR_RX_MFB_EOF_POS,
                USER_RX_MFB_SRC_RDY => USR_RX_MFB_SRC_RDY,
                USER_RX_MFB_DST_RDY => USR_RX_MFB_DST_RDY,

                PCIE_UP_MFB_DATA    => PCIE_RQ_MFB_DATA,
                PCIE_UP_MFB_SOF     => PCIE_RQ_MFB_SOF,
                PCIE_UP_MFB_EOF     => PCIE_RQ_MFB_EOF,
                PCIE_UP_MFB_SOF_POS => PCIE_RQ_MFB_SOF_POS,
                PCIE_UP_MFB_EOF_POS => PCIE_RQ_MFB_EOF_POS,
                PCIE_UP_MFB_SRC_RDY => PCIE_RQ_MFB_SRC_RDY,
                PCIE_UP_MFB_DST_RDY => PCIE_RQ_MFB_DST_RDY);
    end generate;

    tx_dma_calypte_g : if (TX_GEN_EN) generate
        signal s_usr_tx_mfb_meta_pkt_size : slv_array_t(TX_CHANNELS -1 downto 0)(log2(USR_TX_PKT_SIZE_MAX+1) -1 downto 0);
        signal s_usr_tx_mfb_meta_chan     : slv_array_t(TX_CHANNELS -1 downto 0)(log2(TX_CHANNELS) -1 downto 0);
        signal s_usr_tx_mfb_meta_hdr_meta : slv_array_t(TX_CHANNELS -1 downto 0)(HDR_META_WIDTH -1 downto 0);
        signal s_usr_tx_mfb_data          : slv_array_t(TX_CHANNELS -1 downto 0)(USR_MFB_REGIONS*USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH -1 downto 0);
        signal s_usr_tx_mfb_sof           : slv_array_t(TX_CHANNELS -1 downto 0)(USR_MFB_REGIONS -1 downto 0);
        signal s_usr_tx_mfb_eof           : slv_array_t(TX_CHANNELS -1 downto 0)(USR_MFB_REGIONS -1 downto 0);
        signal s_usr_tx_mfb_sof_pos       : slv_array_t(TX_CHANNELS -1 downto 0)(max(1, log2(USR_MFB_REGION_SIZE)) -1 downto 0);
        signal s_usr_tx_mfb_eof_pos       : slv_array_t(TX_CHANNELS -1 downto 0)(max(1, log2(USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE)) -1 downto 0);
        signal s_usr_tx_mfb_src_rdy       : std_logic_vector(TX_CHANNELS -1 downto 0);
        signal s_usr_tx_mfb_dst_rdy       : std_logic_vector(TX_CHANNELS -1 downto 0);
    begin

        tx_dma_calypte_i : entity work.TX_DMA_CALYPTE
            generic map (
                DEVICE   => DEVICE,
                MI_WIDTH => MI_WIDTH,

                USR_TX_MFB_REGIONS     => USR_MFB_REGIONS,
                USR_TX_MFB_REGION_SIZE => USR_MFB_REGION_SIZE,
                USR_TX_MFB_BLOCK_SIZE  => USR_MFB_BLOCK_SIZE,
                USR_TX_MFB_ITEM_WIDTH  => USR_MFB_ITEM_WIDTH,

                PCIE_CQ_MFB_REGIONS     => PCIE_CQ_MFB_REGIONS,
                PCIE_CQ_MFB_REGION_SIZE => PCIE_CQ_MFB_REGION_SIZE,
                PCIE_CQ_MFB_BLOCK_SIZE  => PCIE_CQ_MFB_BLOCK_SIZE,
                PCIE_CQ_MFB_ITEM_WIDTH  => PCIE_CQ_MFB_ITEM_WIDTH,

                PCIE_CC_MFB_REGIONS     => PCIE_CC_MFB_REGIONS,
                PCIE_CC_MFB_REGION_SIZE => PCIE_CC_MFB_REGION_SIZE,
                PCIE_CC_MFB_BLOCK_SIZE  => PCIE_CC_MFB_BLOCK_SIZE,
                PCIE_CC_MFB_ITEM_WIDTH  => PCIE_CC_MFB_ITEM_WIDTH,

                FIFO_DEPTH         => TX_FIFO_DEPTH,
                CHANNELS           => TX_CHANNELS,
                CNTRS_WIDTH        => DSP_CNT_WIDTH,
                HDR_META_WIDTH     => HDR_META_WIDTH,
                PKT_SIZE_MAX       => USR_TX_PKT_SIZE_MAX,
                CHANNEL_ARBITER_EN => CHANNEL_ARBITER_EN)

            port map (
                CLK   => CLK,
                RESET => RESET,

                USR_TX_MFB_META_PKT_SIZE => s_usr_tx_mfb_meta_pkt_size,
                USR_TX_MFB_META_CHAN     => s_usr_tx_mfb_meta_chan,
                USR_TX_MFB_META_HDR_META => s_usr_tx_mfb_meta_hdr_meta,

                USR_TX_MFB_DATA    => s_usr_tx_mfb_data,
                USR_TX_MFB_SOF     => s_usr_tx_mfb_sof,
                USR_TX_MFB_EOF     => s_usr_tx_mfb_eof,
                USR_TX_MFB_SOF_POS => s_usr_tx_mfb_sof_pos,
                USR_TX_MFB_EOF_POS => s_usr_tx_mfb_eof_pos,
                USR_TX_MFB_SRC_RDY => s_usr_tx_mfb_src_rdy,
                USR_TX_MFB_DST_RDY => s_usr_tx_mfb_dst_rdy,

                PCIE_CQ_MFB_DATA    => PCIE_CQ_MFB_DATA,
                PCIE_CQ_MFB_META    => PCIE_CQ_MFB_META,
                PCIE_CQ_MFB_SOF     => PCIE_CQ_MFB_SOF,
                PCIE_CQ_MFB_EOF     => PCIE_CQ_MFB_EOF,
                PCIE_CQ_MFB_SOF_POS => PCIE_CQ_MFB_SOF_POS,
                PCIE_CQ_MFB_EOF_POS => PCIE_CQ_MFB_EOF_POS,
                PCIE_CQ_MFB_SRC_RDY => PCIE_CQ_MFB_SRC_RDY,
                PCIE_CQ_MFB_DST_RDY => PCIE_CQ_MFB_DST_RDY,

                PCIE_CC_MFB_DATA    => PCIE_CC_MFB_DATA,
                PCIE_CC_MFB_META    => PCIE_CC_MFB_META,
                PCIE_CC_MFB_SOF     => PCIE_CC_MFB_SOF,
                PCIE_CC_MFB_EOF     => PCIE_CC_MFB_EOF,
                PCIE_CC_MFB_SOF_POS => PCIE_CC_MFB_SOF_POS,
                PCIE_CC_MFB_EOF_POS => PCIE_CC_MFB_EOF_POS,
                PCIE_CC_MFB_SRC_RDY => PCIE_CC_MFB_SRC_RDY,
                PCIE_CC_MFB_DST_RDY => PCIE_CC_MFB_DST_RDY,

                MI_ADDR => mi_split_addr(1),
                MI_DWR  => mi_split_dwr(1),
                MI_BE   => mi_split_be(1),
                MI_RD   => mi_split_rd(1),
                MI_WR   => mi_split_wr(1),
                MI_DRD  => mi_split_drd(1),
                MI_ARDY => mi_split_ardy(1),
                MI_DRDY => mi_split_drdy(1));

        USR_TX_MFB_META_PKT_SIZE <= s_usr_tx_mfb_meta_pkt_size(0);
        USR_TX_MFB_META_CHAN     <= s_usr_tx_mfb_meta_chan(0);
        USR_TX_MFB_META_HDR_META <= s_usr_tx_mfb_meta_hdr_meta(0);

        USR_TX_MFB_DATA      <= s_usr_tx_mfb_data(0);
        USR_TX_MFB_SOF       <= s_usr_tx_mfb_sof(0);
        USR_TX_MFB_EOF       <= s_usr_tx_mfb_eof(0);
        USR_TX_MFB_SOF_POS   <= s_usr_tx_mfb_sof_pos(0);
        USR_TX_MFB_EOF_POS   <= s_usr_tx_mfb_eof_pos(0);
        USR_TX_MFB_SRC_RDY   <= s_usr_tx_mfb_src_rdy(0);
        s_usr_tx_mfb_dst_rdy <= (0 => USR_TX_MFB_DST_RDY, others => '0');
    end generate;

    mi_splitter_rx_tx_channel_i : entity work.MI_SPLITTER_PLUS_GEN
        generic map (
            ADDR_WIDTH => MI_WIDTH,
            DATA_WIDTH => MI_WIDTH,
            META_WIDTH => 0,
            PORTS      => 2,
            PIPE_OUT   => (others => FALSE),

            ADDR_BASES => 2,
            ADDR_BASE  => MI_SPLIT_BASES,
            ADDR_MASK  => x"00200000",

            DEVICE => DEVICE)
        port map (
            CLK   => CLK,
            RESET => RESET,

            RX_DWR  => MI_DWR,
            RX_MWR  => (others => '0'),
            RX_ADDR => MI_ADDR,
            RX_BE   => MI_BE,
            RX_RD   => MI_RD,
            RX_WR   => MI_WR,
            RX_ARDY => MI_ARDY,
            RX_DRD  => MI_DRD,
            RX_DRDY => MI_DRDY,

            TX_DWR  => mi_split_dwr,
            TX_MWR  => open,
            TX_ADDR => mi_split_addr,
            TX_BE   => mi_split_be,
            TX_RD   => mi_split_rd,
            TX_WR   => mi_split_wr,
            TX_ARDY => mi_split_ardy,
            TX_DRD  => mi_split_drd,
            TX_DRDY => mi_split_drdy);
end architecture;
