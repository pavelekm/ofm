-- pcie_addr_gen.vhd: manages free space and addresses for PCIe transactions
-- Copyright (c) 2022 CESNET z.s.p.o.
-- Author(s): Radek Iša <isa@cesnet.cz>
--
-- SPDX-License-Identifier: BSD-3-CLause

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.math_pack.all;

-- This module generates pcie headers acording to packets size. The module generates
-- number of geneaders depending on INPUT_SIZE and BLOCK_SIZE. Number of generated headers
-- is round up INPUT_SIZE/BLOCK_SIZE
entity PCIE_ADDR_GEN is
    generic (
        -- number of managed channels
        CHANNELS      : integer;
        -- size of sent segments in bytes
        BLOCK_SIZE    : integer;
        -- RAM address width
        ADDR_WIDTH    : integer   := 64;
        -- width of a pointer to the ring buffer log2(NUMBER_OF_ITEMS)
        POINTER_WIDTH : integer   := 16;
        PKT_MTU       : integer   := 2**12;
        DEVICE        : string    := "ULTRASCALE"
        );

    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =====================================================================
        -- ADDRES REQUEST INTERFACE (To SW manager)
        -- =====================================================================
        -- Address requesting for channel
        ADDR_CHANNEL    : out std_logic_vector(log2(CHANNELS)-1 downto 0);
        -- Address base for channel
        ADDR_BASE       : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        -- righ buffer size. log2(NUMBER_OF_MAX_ITEMS)
        ADDR_MASK       : in  std_logic_vector(POINTER_WIDTH-1 downto 0);
        -- SW pointer to ring buffer
        ADDR_SW_POINTER : in  std_logic_vector(POINTER_WIDTH-1 downto 0);

        -- =====================================================================
        -- HW UPDATE ADDRESS INTERFACE (To SW manager)
        -- =====================================================================
        POINTER_UPDATE_CHAN : out std_logic_vector(log2(CHANNELS)-1 downto 0);
        POINTER_UPDATE_DATA : out std_logic_vector(POINTER_WIDTH-1 downto 0);
        POINTER_UPDATE_EN   : out std_logic;

        -- =====================================================================
        -- RESET ADDRESS MANAGER 
        -- =====================================================================
        -- if one bit of this signal is set, the coresponding channel's HW address is reset
        CHANNEL_RESET : in  std_logic_vector(CHANNELS-1 downto 0);

        -- =====================================================================
        -- REQUEST ADDRES FOR CHANNEL (Metadata instructions)
        -- =====================================================================
        -- Requested channel
        INPUT_DISC    : in std_logic;
        INPUT_CHANNEL : in std_logic_vector(log2(CHANNELS)-1 downto 0);
        INPUT_SIZE    : in std_logic_vector(log2(PKT_MTU+1) -1 downto 0);

        INPUT_SRC_RDY : in  std_logic;
        INPUT_DST_RDY : out std_logic;

        -- =====================================================================
        -- RESPONSE ADDRES (To be inserted to the PCIex header)
        -- =====================================================================
        -- Address to RAM
        OUT_ADDR      : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        OUT_OFFSET    : out std_logic_vector(POINTER_WIDTH-1 downto 0);
        OUT_ADDR_VLD  : out std_logic;
        OUT_DISC      : out std_logic;
        OUT_LAST      : out std_logic;
        OUT_FIRST     : out std_logic;
        -- this signal have two clock delay. If you want to stop receiving new 
        OUT_DST_RDY   : in std_logic
    );

end entity;

architecture FULL of PCIE_ADDR_GEN is

    -- FSM
    type fsm_t is (IDLE, PACKET_NEW, PACKET_DISCARD, PACKET_RECEIVE);
    signal state_next  : fsm_t;
    signal state_r0    : fsm_t := IDLE;
    signal state_r1    : fsm_t := IDLE;

    -- INPUT DATA
    signal channel      : std_logic_vector(log2(CHANNELS) -1 downto 0);
    signal channel_vld  : std_logic; -- request for addr manager
    signal pkt_size     : unsigned(log2(PKT_MTU+1) -1 downto 0);

    ----------------------
    -- Addr manager signals
    ----------------------
    -- addr manager can accept new segment or new packet
    signal segment_next : std_logic;
    signal packet_next  : std_logic;
    -- addr manager received transaction in previous clock tack
    signal output_vld   : std_logic;
    -- add manager output signals
    signal addr       : std_logic_vector(ADDR_WIDTH -1 downto 0);
    signal offset     : std_logic_vector(POINTER_WIDTH -1 downto 0);
    signal addr_vld   : std_logic;
    -- set if this addres is last for received packetd otherwhise zero.
    signal packet_end : std_logic;

    -- driving signals
    signal input_rdy      : std_logic;
    signal dst_rdy_reg    : std_logic;
begin

    input_rdy     <= INPUT_SRC_RDY and packet_next and dst_rdy_reg;
    INPUT_DST_RDY <= packet_next  and dst_rdy_reg;

    input_process : process (CLK)
    begin
        if (rising_edge(CLK)) then
            -- Set data if new packet is receive
            if (input_rdy = '1') then
                channel  <= INPUT_CHANNEL;
            end if;

            dst_rdy_reg <= OUT_DST_RDY;
        end if;
    end process;

    --=====================================================================
    -- FSM DATA
    --=====================================================================
    -- if this signal is set then pause pipeline. We need wait to empty fifo or receive new pointers.
    state_reg_process : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                state_r0 <= IDLE;
                state_r1 <= IDLE;
            else
                if (segment_next = '1') then
                    if (dst_rdy_reg = '1') then
                        state_r1 <= state_r0;
                    else
                        state_r1 <= IDLE;
                    end if;
                end if;
                if ((packet_next = '1' or segment_next = '1') and dst_rdy_reg = '1') then
                    state_r0 <= state_next;
                end if;
            end if;
        end if;
    end process;

    state_next_process : process(all)
        variable  fsm_new_status_next : fsm_t;
    begin
        state_next <= state_r0;

        -- choose if next packet are going to be discarded or received
        if (INPUT_DISC = '0') then
            fsm_new_status_next := PACKET_NEW;
        else
            fsm_new_status_next := PACKET_DISCARD;
        end if;


        case state_r0 is

            when IDLE        =>

                if (input_rdy = '1') then
                    state_next <= fsm_new_status_next;
                end if;

             when PACKET_RECEIVE | PACKET_NEW  =>
                state_next <= PACKET_RECEIVE;
                if (pkt_size <= BLOCK_SIZE) then
                    if (input_rdy = '1') then
                        state_next <= fsm_new_status_next;
                    else
                        state_next <= IDLE;
                    end if;
                end if;

             when PACKET_DISCARD  =>
                 if (input_rdy = '1') then
                     state_next <= fsm_new_status_next;
                 else
                     state_next <= IDLE;
                 end if;
        end case;
    end process;


    size_pprocess : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (input_rdy = '1') then
                pkt_size <= unsigned(INPUT_SIZE);
            elsif ((state_r0 = PACKET_RECEIVE  or state_r0 = PACKET_NEW) and segment_next = '1' and dst_rdy_reg = '1') then
                pkt_size <= pkt_size - BLOCK_SIZE;
            end if;
        end if;
    end process;

    process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                packet_end <= '0';
            elsif ((state_r0 = PACKET_RECEIVE or state_r0 = PACKET_NEW) and segment_next = '1' and dst_rdy_reg = '1') then
                if (pkt_size <= BLOCK_SIZE) then
                    packet_end <= '1';
                else
                    packet_end <= '0';
                end if;
            end if;
        end if;
    end process;


    output_vld   <= '1' when (state_r1 = PACKET_RECEIVE or state_r1 = PACKET_NEW)  else '0';
    segment_next <= '1' when (output_vld = '0' or (addr_vld = '1' and output_vld = '1')) else '0';
    packet_next  <= '1' when state_r0 = IDLE
                        or ((state_r0 = PACKET_DISCARD or ((state_r0 = PACKET_RECEIVE  or state_r0 = PACKET_NEW) and pkt_size <= BLOCK_SIZE)) and segment_next = '1') else '0';
    -- Request for next 128B memory space
    channel_vld  <= '1' when (state_r0 = PACKET_RECEIVE  or state_r0 = PACKET_NEW) and dst_rdy_reg = '1' else '0';

    addr_manager_i : entity work.addr_manager
        generic map(
            CHANNELS      => CHANNELS,
            BLOCK_SIZE    => BLOCK_SIZE,
            ADDR_WIDTH    => ADDR_WIDTH,
            POINTER_WIDTH => POINTER_WIDTH,

            DEVICE => DEVICE
            )
        port map(
            CLK   => CLK,
            RESET => RESET,

            ADDR_CHANNEL    => ADDR_CHANNEL,
            ADDR_BASE       => ADDR_BASE,
            ADDR_MASK       => ADDR_MASK,
            ADDR_SW_POINTER => ADDR_SW_POINTER,

            POINTER_UPDATE_CHAN => POINTER_UPDATE_CHAN,
            POINTER_UPDATE_DATA => POINTER_UPDATE_DATA,
            POINTER_UPDATE_EN   => POINTER_UPDATE_EN,

            CHANNEL       => channel,
            CHANNEL_VLD   => channel_vld,
            CHANNEL_RESET => CHANNEL_RESET,

            ADDR     => addr,
            OFFSET   => offset,
            ADDR_VLD => addr_vld
        );

    OUT_ADDR       <= addr;
    OUT_OFFSET     <= offset;
    OUT_ADDR_VLD   <= addr_vld;
    OUT_LAST       <= packet_end;
    OUT_FIRST      <= '1' when state_r1 = PACKET_DISCARD or (state_r1 = PACKET_NEW and addr_vld = '1') else '0';
    OUT_DISC       <= '1' when state_r1 = PACKET_DISCARD else '0';
    --OUT_DST_RDY

end architecture;
