-- rx_dma_hdr_insertor.vhd: inserts PCIex header to each transfer and sends DMA header afterwards
-- Copyright (c) 2022 CESNET z.s.p.o.
-- Author(s): Vladislav Valek  <xvalek14@vutbr.cz>
--
-- SPDX-License-Identifier: BSD-3-CLause

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Note:

use work.math_pack.all;
use work.type_pack.all;

-- This component accepts buffered PCIe transactions (currently set to 128 Bytes). And sends them
-- with appropriate PCIe header. When end of a packet is processed, the DMA header is sent after
-- that.
entity RX_DMA_HDR_INSERTOR is
    generic (
        -- =========================================================================================
        -- RX MFB configuration
        --
        -- Number of regions is always 1
        -- =========================================================================================
        RX_REGION_SIZE : natural := 1;
        RX_BLOCK_SIZE  : natural := 128;
        RX_ITEM_WIDTH  : natural := 8;

        -- =========================================================================================
        -- TX MFB configuration
        -- =========================================================================================
        TX_REGIONS     : natural := 2;
        TX_REGION_SIZE : natural := 1;
        TX_BLOCK_SIZE  : natural := 8;
        TX_ITEM_WIDTH  : natural := 32;

        CHANNELS     : natural := 8;
        PKT_SIZE_MAX : natural := 2**16 - 1
        );
    port (
        CLK : in std_logic;
        RST : in std_logic;

        -- =========================================================================================
        -- MFB input interface
        --
        -- EOF_POS is not used because. when the input word ends (signalized by EOF), whole word is
        -- valid. The SOF_POS is not used either because the input words are aligned to the
        -- beginning of the word.
        -- =========================================================================================
        RX_MFB_DATA    : in  std_logic_vector(RX_REGION_SIZE*RX_BLOCK_SIZE*RX_ITEM_WIDTH-1 downto 0);
        RX_MFB_SOF     : in  std_logic;
        RX_MFB_EOF     : in  std_logic;
        RX_MFB_SRC_RDY : in  std_logic;
        RX_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- MFB output interface
        -- =========================================================================================
        TX_MFB_DATA    : out std_logic_vector(TX_REGIONS*TX_REGION_SIZE*TX_BLOCK_SIZE*TX_ITEM_WIDTH-1 downto 0);
        TX_MFB_SOF     : out std_logic_vector(TX_REGIONS-1 downto 0);
        TX_MFB_EOF     : out std_logic_vector(TX_REGIONS-1 downto 0);
        TX_MFB_SOF_POS : out std_logic_vector(TX_REGIONS*max(1, log2(TX_REGION_SIZE))-1 downto 0);
        TX_MFB_EOF_POS : out std_logic_vector(TX_REGIONS*max(1, log2(TX_REGION_SIZE*TX_BLOCK_SIZE))-1 downto 0);
        TX_MFB_SRC_RDY : out std_logic;
        TX_MFB_DST_RDY : in  std_logic;

        -- =========================================================================================
        -- Header manager interface
        --
        -- Adheres to the MVB specification.
        -- =========================================================================================
        HDRM_PCIE_HDR_DATA : in std_logic_vector(127 downto 0);

        -- - log. 0 means header is 3 DW long
        -- - log. 1 means header is 4 DW long
        HDRM_PCIE_HDR_TYPE              : in  std_logic;
        HDRM_PCIE_HDR_SRC_RDY_DATA_TRAN : in  std_logic;
        HDRM_PCIE_HDR_SRC_RDY_DMA_HDR   : in  std_logic;
        HDRM_PCIE_HDR_DST_RDY           : out std_logic;

        HDRM_DMA_CHAN_NUM    : in  std_logic_vector((log2(CHANNELS)-1) downto 0);
        HDRM_PKT_DROP        : in  std_logic;
        HDRM_DMA_HDR_DATA    : in  std_logic_vector(63 downto 0);
        HDRM_DMA_HDR_SRC_RDY : in  std_logic;
        HDRM_DMA_HDR_DST_RDY : out std_logic;

        -- asserts for 1 clock period when the transmission of a packet has been completed
        HDRM_PKT_CNTR_CHAN : out std_logic_vector((log2(CHANNELS)-1) downto 0);
        HDRM_PKT_SENT_INC  : out std_logic;
        HDRM_PKT_DISC_INC  : out std_logic;
        HDRM_PKT_SIZE      : out std_logic_vector((log2(PKT_SIZE_MAX+1) - 1) downto 0)
        );
end entity;

architecture FULL of RX_DMA_HDR_INSERTOR is

    signal bshifter_data_out  : std_logic_vector(RX_MFB_DATA'range);
    signal low_shift_val      : std_logic_vector(2 downto 0);
    -- normally the lenght of these signals is set to address each group of 4 blocks on the bus but I made the
    -- signals one bit wider because I use them as a counter of output words in each transaction
    signal high_shift_val_pst : unsigned(log2(32)-4 downto 0);
    signal high_shift_val_nst : unsigned(log2(32)-4 downto 0);
    signal shift_sel_pst      : std_logic;
    signal shift_sel_nst      : std_logic;

    type tran_process_state_type is (IDLE, TRANSACTION_SEND, DMA_HDR_SEND);
    signal tprocess_pst : tran_process_state_type := IDLE;
    signal tprocess_nst : tran_process_state_type := IDLE;

    signal dma_hdr_last     : std_logic;
    signal dma_hdr_last_reg : std_logic;
    signal pkt_drop         : std_logic;
    signal pkt_drop_reg     : std_logic;

    -- varies its value according to the generic parameters
    signal SHIFT_INC  : unsigned(1 downto 0);
    signal INIT_SHIFT : unsigned(1 downto 0);

    -- attribute mark_debug                       : string;
    -- attribute mark_debug of tprocess_pst       : signal is "true";
    -- attribute mark_debug of high_shift_val_pst : signal is "true";
begin

    assert ((RX_REGION_SIZE = 1 and RX_BLOCK_SIZE = 128 and RX_ITEM_WIDTH = 8)
            or (RX_REGION_SIZE = 1 and RX_BLOCK_SIZE = 256 and RX_ITEM_WIDTH = 8))
        report "RX_DMA_HDR_INSERTOR: The design is not prepared for such RX MFB configuration, the valid are: MFB#(_,1,128,8), MFB#(_,1,256,8)."
        severity FAILURE;

    assert ((TX_REGIONS = 1 and TX_REGION_SIZE = 1 and TX_BLOCK_SIZE = 8 and TX_ITEM_WIDTH = 32)
            or (TX_REGIONS = 2 and TX_REGION_SIZE = 1 and TX_BLOCK_SIZE = 8 and TX_ITEM_WIDTH = 32))
        report "RX_DMA_HDR_INSERTOR: The design is not prepared for such TX MFB configuration, the valid are: MFB#(1,1,8,32), MFB#(2,1,8,32)."
        severity FAILURE;

    --=============================================================================================================
    -- FSM state register
    --=============================================================================================================
    tprocess_pst_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then

                tprocess_pst       <= IDLE;
                shift_sel_pst      <= '0';
                high_shift_val_pst <= "11";

            elsif (TX_MFB_DST_RDY = '1') then

                tprocess_pst       <= tprocess_nst;
                shift_sel_pst      <= shift_sel_nst;
                high_shift_val_pst <= high_shift_val_nst;

            end if;
        end if;
    end process;

    --=============================================================================================================
    -- FSM next state logic
    --=============================================================================================================
    tprocess_nst_logic_p : process (all) is
    begin

        tprocess_nst <= tprocess_pst;

        case tprocess_pst is
            when IDLE =>

                if (RX_MFB_SRC_RDY = '1'
                    and HDRM_PCIE_HDR_SRC_RDY_DATA_TRAN = '1'
                    and HDRM_PKT_DROP = '0'
                    and HDRM_DMA_HDR_SRC_RDY = '1'
                    and
                    (
                        TX_REGIONS = 1
                        or
                        (
                            TX_REGIONS = 2
                            and
                            HDRM_PCIE_HDR_SRC_RDY_DMA_HDR = '1'
                            and
                            RX_MFB_EOF = '1'
                        )
                        or
                        (
                            TX_REGIONS = 2 and RX_MFB_EOF = '0'
                        )
                    )
                ) then

                    tprocess_nst <= TRANSACTION_SEND;
                end if;

            when TRANSACTION_SEND =>

                if (high_shift_val_pst = "11") then

                    if (RX_MFB_EOF = '1' and TX_REGIONS = 1) then
                        tprocess_nst <= DMA_HDR_SEND;
                    elsif (
                        (RX_MFB_EOF = '1' and TX_REGIONS = 2)
                        or
                        RX_MFB_EOF = '0'
                        ) then

                        tprocess_nst <= IDLE;
                    end if;
                end if;

            when DMA_HDR_SEND =>

                if (HDRM_PCIE_HDR_SRC_RDY_DMA_HDR = '1') then
                    tprocess_nst <= IDLE;
                end if;
        end case;
    end process;

    --=============================================================================================================
    -- FSM process which contols the input RX MFB and Header Manager signals
    --=============================================================================================================
    tshift_logic_p : process (all) is
    begin

        RX_MFB_DST_RDY        <= TX_MFB_DST_RDY;
        HDRM_PCIE_HDR_DST_RDY <= TX_MFB_DST_RDY;
        HDRM_DMA_HDR_DST_RDY  <= TX_MFB_DST_RDY;

        shift_sel_nst <= shift_sel_pst;

        -- signals which are used to create pulses for the packet counters
        dma_hdr_last <= '0';
        pkt_drop     <= '0';

        case tprocess_pst is
            -- In this state, the component waits for the arrival of three crucial components, a valid packet, the
            -- PCIEX header and the DMA header
            when IDLE =>

                -- when valid word arrives deassert the RX_DST_RDY signal because the FSM awaits the arrival of
                -- the PCIE header, no need to wait for the MFB_SOF signal the RX_DST_RDY signal is sufficient
                if (RX_MFB_SRC_RDY = '1') then
                    RX_MFB_DST_RDY <= '0';
                end if;

                -- if PCIE header has been captured, then deassert the PCIE_HDR_DST_RDY singnal because we need to
                -- wait for a valid packet to arrive. This packet should also be the one which will not be
                -- dropped. (PCIE  headers on the input are always valid)
                if (HDRM_PCIE_HDR_SRC_RDY_DATA_TRAN = '1') then
                    shift_sel_nst         <= HDRM_PCIE_HDR_TYPE;
                    HDRM_PCIE_HDR_DST_RDY <= '0';
                end if;

                -- awaiting the arrival of valid DMA header with the information if packet should be dropped or not
                if (HDRM_DMA_HDR_SRC_RDY = '1') then

                    HDRM_DMA_HDR_DST_RDY <= '0';

                    -- when valid PKT_DROP signal is captured, then the next valid packet should be dropped
                    if (HDRM_PKT_DROP = '1') then

                        RX_MFB_DST_RDY        <= '1';
                        HDRM_PCIE_HDR_DST_RDY <= '0';

                        -- if valid SOF is captured, current DMA header is also dropped
                        if (RX_MFB_EOF = '1' and RX_MFB_SRC_RDY = '1') then
                            HDRM_DMA_HDR_DST_RDY <= '1';
                            pkt_drop             <= '1';
                        end if;
                    end if;
                end if;

            when TRANSACTION_SEND =>

                RX_MFB_DST_RDY        <= '0';
                HDRM_PCIE_HDR_DST_RDY <= '0';
                HDRM_DMA_HDR_DST_RDY  <= '0';

                if (TX_REGIONS = 1) then

                    if (high_shift_val_pst = "11") then
                        -- switch the PCIE header on the input to the next one
                        HDRM_PCIE_HDR_DST_RDY <= TX_MFB_DST_RDY;

                        -- switch also the word on the input but only if a current packet does not contain an EOF
                        -- because the transmission needs to be paused and the special transaction with a DMA
                        -- header is sent
                        -- NOTE: This is a possible bottleneck because the next word can be loaded
                        -- on the input in the next clock cycle.
                        if (RX_MFB_EOF = '0') then
                            RX_MFB_DST_RDY <= TX_MFB_DST_RDY;
                        end if;
                    end if;
                else

                    -- switch to the next header because it will be needed by the write of the last word of the
                    -- transaction when there is also a DMA header transaction to be written at once
                    if (high_shift_val_pst = "01" and RX_MFB_EOF = '1') then
                        HDRM_PCIE_HDR_DST_RDY <= TX_MFB_DST_RDY;
                    end if;

                    if (high_shift_val_pst = "11") then

                        RX_MFB_DST_RDY        <= TX_MFB_DST_RDY;
                        -- switch the PCIE header on the input to the next one (for the next transaction)
                        HDRM_PCIE_HDR_DST_RDY <= TX_MFB_DST_RDY;

                        if (RX_MFB_EOF = '1') then
                            HDRM_DMA_HDR_DST_RDY  <= TX_MFB_DST_RDY;
                            dma_hdr_last          <= '1';
                        end if;

                    end if;
                end if;

            when DMA_HDR_SEND =>

                -- release the headers on the input and allow next packet to arrive
                HDRM_PCIE_HDR_DST_RDY <= TX_MFB_DST_RDY;

                if (HDRM_PCIE_HDR_SRC_RDY_DMA_HDR = '1') then

                    RX_MFB_DST_RDY       <= TX_MFB_DST_RDY;
                    HDRM_DMA_HDR_DST_RDY <= TX_MFB_DST_RDY;
                    dma_hdr_last         <= '1';
                else
                    HDRM_DMA_HDR_DST_RDY <= '0';
                    RX_MFB_DST_RDY       <= '0';
                end if;
        end case;
    end process;
    --=============================================================================================================

    -- my attempt to make the set of constants which change according to the specified generic parameters
    shift_cntr_incr_g : if (TX_REGIONS = 1) generate
        INIT_SHIFT <= "00";
        SHIFT_INC  <= "01";
    else generate
        INIT_SHIFT <= "01";
        -- increment by two, the barrel shifter remains the same for both of the configurations so the
        -- shifting by two is needed
        SHIFT_INC  <= "10";
    end generate;

    --=============================================================================================================
    -- FSM process which controls the output MFB signals and their logic
    --=============================================================================================================
    tout_logic_p : process (all) is
    begin

        TX_MFB_DATA    <= bshifter_data_out(TX_MFB_DATA'high downto 0);
        TX_MFB_SOF     <= (others => '0');
        TX_MFB_EOF     <= (others => '0');
        TX_MFB_SOF_POS <= (others => '0');
        TX_MFB_EOF_POS <= (others => '0');
        TX_MFB_SRC_RDY <= '0';

        high_shift_val_nst <= high_shift_val_pst;

        case tprocess_pst is
            when IDLE =>

                if (RX_MFB_SRC_RDY = '1'
                    and HDRM_PCIE_HDR_SRC_RDY_DATA_TRAN = '1'
                    and HDRM_PKT_DROP = '0'
                    and HDRM_DMA_HDR_SRC_RDY = '1'
                    and (TX_REGIONS = 1
                         or
                         (TX_REGIONS = 2 and HDRM_PCIE_HDR_SRC_RDY_DMA_HDR = '1' and RX_MFB_EOF = '1')
                         or
                         (TX_REGIONS = 2 and RX_MFB_EOF = '0')
                         )
                    ) then

                    if (HDRM_PCIE_HDR_TYPE = '0') then
                        TX_MFB_DATA <= bshifter_data_out(TX_MFB_DATA'high downto 96) & HDRM_PCIE_HDR_DATA(95 downto 0);
                    else
                        TX_MFB_DATA <= bshifter_data_out(TX_MFB_DATA'high downto 128) & HDRM_PCIE_HDR_DATA(127 downto 0);
                    end if;

                    TX_MFB_SOF     <= std_logic_vector(to_unsigned(1, TX_MFB_SOF'length));
                    TX_MFB_SRC_RDY <= '1';

                    high_shift_val_nst <= INIT_SHIFT;
                end if;

            when TRANSACTION_SEND =>

                high_shift_val_nst <= high_shift_val_pst + SHIFT_INC;

                if (high_shift_val_pst = "11") then

                    -- because the design in this configuration contains two regions, the output word
                    -- is organized in the way that the first half is occupied by the rest of a current
                    -- transaction and the second half by the prepared DMA header with its PCIe header
                    if (TX_REGIONS = 2 and RX_MFB_EOF = '1') then
                        -- the value of "10"
                        TX_MFB_SOF <= std_logic_vector(to_unsigned(2, TX_MFB_SOF'length));
                        -- the value of "11"
                        TX_MFB_EOF <= std_logic_vector(to_unsigned(3, TX_MFB_EOF'length));
                    else
                        -- the value of "01"
                        TX_MFB_EOF <= std_logic_vector(to_unsigned(1, TX_MFB_EOF'length));
                    end if;

                    -- keep the shift to the next segment because the PCIex header needs to be inserted which means
                    -- that the initial shift is at its highest value (e.q. "011")
                    high_shift_val_nst <= high_shift_val_pst;

                    if (HDRM_PCIE_HDR_TYPE = '0') then

                        if (TX_REGIONS = 2 and RX_MFB_EOF = '1') then

                            TX_MFB_DATA <= (TX_MFB_DATA'high downto 96 + 64 + (TX_MFB_DATA'length / 2) => '0')
                                           & HDRM_DMA_HDR_DATA
                                           & HDRM_PCIE_HDR_DATA(95 downto 0)
                                           & ((TX_MFB_DATA'length / 2) - 1 downto 96 => '0')
                                           & bshifter_data_out(95 downto 0);

                            -- the value of "100" & "010"
                            TX_MFB_EOF_POS <= std_logic_vector(to_unsigned(34, TX_MFB_EOF_POS'length));
                        else
                            -- the value of "000" & "010"
                            TX_MFB_EOF_POS <= std_logic_vector(to_unsigned(2, TX_MFB_EOF_POS'length));
                        end if;
                    else

                        if (TX_REGIONS = 2 and RX_MFB_EOF = '1') then

                            TX_MFB_DATA <= (TX_MFB_DATA'high downto 128 + 64 + (TX_MFB_DATA'length / 2) => '0')
                                           & HDRM_DMA_HDR_DATA
                                           & HDRM_PCIE_HDR_DATA(127 downto 0)
                                           & ((TX_MFB_DATA'length / 2) - 1 downto 128 => '0')
                                           & bshifter_data_out(127 downto 0);

                            -- the value of "101" & "011"
                            TX_MFB_EOF_POS <= std_logic_vector(to_unsigned(43, TX_MFB_EOF_POS'length));
                        else
                            -- the value of "000" & "011"
                            TX_MFB_EOF_POS <= std_logic_vector(to_unsigned(3, TX_MFB_EOF_POS'length));
                        end if;
                    end if;
                end if;

                TX_MFB_SRC_RDY <= '1';

            when DMA_HDR_SEND =>

                if (HDRM_PCIE_HDR_SRC_RDY_DMA_HDR = '1') then

                    -- load the DMA header and some other non-important data
                    if (HDRM_PCIE_HDR_TYPE = '0') then
                        TX_MFB_DATA    <= (TX_MFB_DATA'high downto 96 + 64 => '0') & HDRM_DMA_HDR_DATA & HDRM_PCIE_HDR_DATA(95 downto 0);
                        TX_MFB_EOF_POS <= std_logic_vector(to_unsigned(4, TX_MFB_EOF_POS'length));
                    else
                        TX_MFB_DATA    <= (TX_MFB_DATA'high downto 128 + 64 => '0') & HDRM_DMA_HDR_DATA & HDRM_PCIE_HDR_DATA(127 downto 0);
                        TX_MFB_EOF_POS <= std_logic_vector(to_unsigned(5, TX_MFB_EOF_POS'length));
                    end if;

                    TX_MFB_SOF     <= std_logic_vector(to_unsigned(1, TX_MFB_SOF'length));
                    TX_MFB_EOF     <= std_logic_vector(to_unsigned(1, TX_MFB_EOF'length));
                    TX_MFB_SRC_RDY <= '1';
                end if;
        end case;
    end process;
    --=============================================================================================================

    --=============================================================================================================
    -- Shifter of the output data
    --=============================================================================================================
    input_data_shifter_i : entity work.BARREL_SHIFTER_GEN
        generic map (
            -- 32 DWs and each has 32b
            BLOCKS     => 32,
            BLOCK_SIZE => 32,
            SHIFT_LEFT => FALSE)
        port map (
            DATA_IN  => RX_MFB_DATA,
            DATA_OUT => bshifter_data_out,
            SEL      => std_logic_vector(high_shift_val_pst) & low_shift_val);

    with shift_sel_nst select
        low_shift_val <=
        "101" when '0',
        "100" when '1',
        "000" when others;

    --=============================================================================================================
    -- Edge detector for the information if the packet has already been sent
    --=============================================================================================================
    dma_hdr_last_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            dma_hdr_last_reg <= dma_hdr_last;
            pkt_drop_reg     <= pkt_drop;
        end if;
    end process;

    HDRM_PKT_SENT_INC  <= '1' when (dma_hdr_last = '1' and dma_hdr_last_reg = '0') else '0';
    HDRM_PKT_DISC_INC  <= '1' when (pkt_drop = '1' and pkt_drop_reg = '0')         else '0';
    -- choose only the valid bits from the DMA header for the packet counters
    HDRM_PKT_SIZE      <= HDRM_DMA_HDR_DATA(log2(PKT_SIZE_MAX + 1) - 1 downto 0);
    HDRM_PKT_CNTR_CHAN <= HDRM_DMA_CHAN_NUM;

end architecture;
