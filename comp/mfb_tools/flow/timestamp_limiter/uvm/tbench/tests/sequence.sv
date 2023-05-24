// sequence.sv: Virtual sequence
// Copyright (C) 2023 CESNET z. s. p. o.
// Author(s): Daniel Kříž <danielkriz@cesnet.cz>

// SPDX-License-Identifier: BSD-3-Clause


class virt_sequence #(MFB_REGIONS, MFB_REGION_SIZE, MFB_BLOCK_SIZE, MFB_ITEM_WIDTH, RX_MFB_META_WIDTH, TX_MFB_META_WIDTH, FRAME_SIZE_MIN, PKT_MTU, TIMESTAMP_MIN, TIMESTAMP_MAX, TIMESTAMP_WIDTH) extends uvm_sequence;
    `uvm_object_param_utils(test::virt_sequence #(MFB_REGIONS, MFB_REGION_SIZE, MFB_BLOCK_SIZE, MFB_ITEM_WIDTH, RX_MFB_META_WIDTH, TX_MFB_META_WIDTH, FRAME_SIZE_MIN, PKT_MTU, TIMESTAMP_MIN, TIMESTAMP_MAX, TIMESTAMP_WIDTH))
    `uvm_declare_p_sequencer(uvm_timestamp_limiter::virt_sequencer #(MFB_REGIONS, MFB_REGION_SIZE, MFB_BLOCK_SIZE, MFB_ITEM_WIDTH, RX_MFB_META_WIDTH, TX_MFB_META_WIDTH))

    function new (string name = "virt_sequence");
        super.new(name);
    endfunction

    uvm_reset::sequence_start                                                                                               m_reset;
    uvm_logic_vector_array::sequence_lib #(MFB_ITEM_WIDTH)                                                                  m_mfb_data_sq_lib;
    uvm_timestamp_limiter::sequence_meta#(RX_MFB_META_WIDTH, TIMESTAMP_WIDTH, TIMESTAMP_MIN, TIMESTAMP_MAX)     m_mfb_meta_sq;

    uvm_sequence#(uvm_mfb::sequence_item#(MFB_REGIONS, MFB_REGION_SIZE, MFB_BLOCK_SIZE, MFB_ITEM_WIDTH, TX_MFB_META_WIDTH)) m_mfb_rdy_seq;
    uvm_mfb::sequence_lib_tx#(MFB_REGIONS, MFB_REGION_SIZE, MFB_BLOCK_SIZE, MFB_ITEM_WIDTH, TX_MFB_META_WIDTH)              m_mfb_rdy_lib;
    uvm_phase phase;

    virtual function void init(uvm_phase phase);

        m_reset           = uvm_reset::sequence_start::type_id::create("m_reset_seq");
        m_mfb_data_sq_lib = uvm_logic_vector_array::sequence_lib #(MFB_ITEM_WIDTH)::type_id::create("m_mfb_data_sq_lib");
        m_mfb_meta_sq     = uvm_timestamp_limiter::sequence_meta#(RX_MFB_META_WIDTH, TIMESTAMP_WIDTH, TIMESTAMP_MIN, TIMESTAMP_MAX)::type_id::create("m_mfb_meta_sq");

        m_mfb_rdy_lib     = uvm_mfb::sequence_lib_tx#(MFB_REGIONS, MFB_REGION_SIZE, MFB_BLOCK_SIZE, MFB_ITEM_WIDTH, TX_MFB_META_WIDTH)::type_id::create("m_mfb_rdy_lib");

        m_mfb_data_sq_lib.init_sequence();
        m_mfb_data_sq_lib.cfg = new();
        m_mfb_data_sq_lib.cfg.array_size_set(FRAME_SIZE_MIN, PKT_MTU);
        m_mfb_data_sq_lib.min_random_count = 100;
        m_mfb_data_sq_lib.max_random_count = 300;
        m_mfb_data_sq_lib.randomize();

        m_mfb_rdy_lib.init_sequence();
        m_mfb_rdy_lib.min_random_count = 100;
        m_mfb_rdy_lib.max_random_count = 200;
        m_mfb_rdy_seq = m_mfb_rdy_lib;

        this.phase = phase;

    endfunction

    virtual task mfb_rdy_seq();
        //RUN TX Sequencer
        forever begin
            m_mfb_rdy_seq.randomize();
            m_mfb_rdy_seq.start(p_sequencer.m_mfb_rdy_sqr);
        end
    endtask

    virtual task run_reset();
        m_reset.randomize();
        m_reset.start(p_sequencer.m_reset_sqr);
    endtask

    task body();

        fork
            run_reset();
        join_none

        #(100ns);

        //RUN MFB TX SEQUENCE
        fork
            mfb_rdy_seq();
        join_none

        fork
            m_mfb_data_sq_lib.start(p_sequencer.m_mfb_data_sqr);
            begin
                m_mfb_meta_sq.randomize();
                m_mfb_meta_sq.start(p_sequencer.m_mfb_meta_sqr);
            end
        join_any

    endtask

endclass
