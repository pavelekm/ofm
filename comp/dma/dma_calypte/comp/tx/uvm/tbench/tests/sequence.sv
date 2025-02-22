//-- sequence.sv:  virtual sequence
//-- Copyright (C) 2022 CESNET z. s. p. o.
//-- Author(s): Daniel Kriz <danielkriz@cesnet.cz>

//-- SPDX-License-Identifier: BSD-3-Clause 

class virt_seq#(USR_REGIONS, USR_REGION_SIZE, USR_BLOCK_SIZE, USR_ITEM_WIDTH, CQ_ITEM_WIDTH, CHANNELS, PKT_SIZE_MAX, PCIE_LEN_MIN, PCIE_LEN_MAX) extends uvm_sequence;
    `uvm_object_param_utils(test::virt_seq#(USR_REGIONS, USR_REGION_SIZE, USR_BLOCK_SIZE, USR_ITEM_WIDTH, CQ_ITEM_WIDTH, CHANNELS, PKT_SIZE_MAX, PCIE_LEN_MIN, PCIE_LEN_MAX))
    `uvm_declare_p_sequencer(uvm_dma_ll::sequencer#(USR_REGIONS, USR_REGION_SIZE, USR_BLOCK_SIZE, USR_ITEM_WIDTH, CQ_ITEM_WIDTH, CHANNELS, PKT_SIZE_MAX))

    function new (string name = "virt_seq");
        super.new(name);
    endfunction

    localparam USER_META_WIDTH = 24 + $clog2(PKT_SIZE_MAX+1) + $clog2(CHANNELS);

    uvm_reset::sequence_start                            m_reset;

    reg_sequence#(CQ_ITEM_WIDTH, PKT_SIZE_MAX, PCIE_LEN_MIN)                                                               m_reg;
    uvm_sequence#(uvm_mfb::sequence_item #(USR_REGIONS, USR_REGION_SIZE, USR_BLOCK_SIZE, USR_ITEM_WIDTH, USER_META_WIDTH)) m_pcie;
    uvm_mfb::sequence_lib_tx#(USR_REGIONS, USR_REGION_SIZE, USR_BLOCK_SIZE, USR_ITEM_WIDTH, USER_META_WIDTH)               m_pcie_lib;
    uvm_phase phase;
    logic done = 0;

    virtual function void init(uvm_dma_regs::regmodel#(CHANNELS) m_regmodel, uvm_dma_ll_info::watchdog #(CHANNELS) m_watch_dog, uvm_phase phase);

        m_reset = uvm_reset::sequence_start::type_id::create("rst_seq");

        m_reg             = reg_sequence#(CQ_ITEM_WIDTH, PKT_SIZE_MAX, PCIE_LEN_MIN)::type_id::create("m_reg");
        m_reg.m_regmodel  = m_regmodel;
        m_reg.m_watch_dog = m_watch_dog;

        m_pcie_lib = uvm_mfb::sequence_lib_tx#(USR_REGIONS, USR_REGION_SIZE, USR_BLOCK_SIZE, USR_ITEM_WIDTH, USER_META_WIDTH)::type_id::create("m_pcie_lib");
        m_pcie_lib.init_sequence();
        m_pcie = m_pcie_lib;

        this.phase = phase;
    endfunction

    virtual task run_mfb();
        forever begin
            assert(m_pcie.randomize());
            m_pcie.start(p_sequencer.m_pcie);
        end
    endtask

    virtual task run_reset();
        m_reset.randomize();
        m_reset.start(p_sequencer.m_reset);
    endtask

    function void pre_randomize();
         m_reg.randomize();
    endfunction

    task body();
        fork
            run_reset();
            begin
                #(200ns)
                m_reg.start(p_sequencer.m_packet);
                done = 1'b1;
            end
        join_none

        #(200ns);

        fork
            run_mfb();
        join_none

        wait(done);

    endtask
endclass
