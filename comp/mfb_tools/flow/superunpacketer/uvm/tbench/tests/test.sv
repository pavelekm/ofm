// test.sv: Verification test
// Copyright (C) 2022 CESNET z. s. p. o.
// Author(s): Daniel Kříž <xkrizd01@vutbr.cz>

// SPDX-License-Identifier: BSD-3-Clause

class ex_test extends uvm_test;
    `uvm_component_utils(test::ex_test);

    // declare the Environment reference variable
    uvm_superunpacketer::env #(MFB_REGIONS, MFB_REGION_SIZE, MFB_BLOCK_SIZE, MFB_ITEM_WIDTH, OUT_META_WIDTH, HEADER_SIZE, VERBOSITY, PKT_MTU, MIN_SIZE, OUT_META_MODE) m_env;
    int unsigned timeout;

    // ------------------------------------------------------------------------
    // Functions
    // Constrctor of the test object
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // Build phase function, e.g. the creation of test's internal objects
    function void build_phase(uvm_phase phase);
        // Initializing the reference to the environment
        m_env = uvm_superunpacketer::env #(MFB_REGIONS, MFB_REGION_SIZE, MFB_BLOCK_SIZE, MFB_ITEM_WIDTH, OUT_META_WIDTH, HEADER_SIZE, VERBOSITY, PKT_MTU, MIN_SIZE, OUT_META_MODE)::type_id::create("m_env", this);
    endfunction

    virtual task tx_seq(uvm_phase phase);

        // Declaring the sequence library reference and initializing it
        uvm_mfb::sequence_lib_tx#(MFB_REGIONS, MFB_REGION_SIZE, MFB_BLOCK_SIZE, MFB_ITEM_WIDTH, OUT_META_WIDTH) mfb_seq;
        mfb_seq = uvm_mfb::sequence_lib_tx#(MFB_REGIONS, MFB_REGION_SIZE, MFB_BLOCK_SIZE, MFB_ITEM_WIDTH, OUT_META_WIDTH)::type_id::create("mfb_tx_seq", this);

        mfb_seq.init_sequence();
        mfb_seq.min_random_count = 100;
        mfb_seq.max_random_count = 200;

        //RUN TX Sequencer
        forever begin
            mfb_seq.randomize();
            mfb_seq.start(m_env.m_env_tx.m_sequencer);
        end

    endtask

    virtual task tx_mvb_seq(uvm_phase phase);
        uvm_mvb::sequence_lib_tx#(MFB_REGIONS, OUT_META_WIDTH) mvb_seq;
        mvb_seq = uvm_mvb::sequence_lib_tx#(MFB_REGIONS, OUT_META_WIDTH)::type_id::create("mvb_seq", this);
        mvb_seq.init_sequence();
        mvb_seq.min_random_count = 100;
        mvb_seq.max_random_count = 200;

        forever begin
            mvb_seq.randomize();
            mvb_seq.start(m_env.m_env_tx_mvb.m_sequencer);
        end
    endtask

    // ------------------------------------------------------------------------
    // Create environment and Run sequences on their sequencers
    virtual task run_phase(uvm_phase phase);
        virt_sequence #(MIN_SIZE, PKT_MTU) m_vseq;

        phase.raise_objection(this);

        //RUN MFB and MVB TX SEQUENCE
        fork
            tx_seq(phase);
            tx_mvb_seq(phase);
        join_none

        //RUN MFB RX SEQUENCE
        m_vseq = virt_sequence#(MIN_SIZE, PKT_MTU)::type_id::create("m_vseq");
        m_vseq.randomize();
        m_vseq.start(m_env.vscr);

        timeout = 1;
        fork
            test_wait_timeout(1000);
            test_wait_result();
        join_any;

        phase.drop_objection(this);

    endtask

    task test_wait_timeout(int unsigned time_length);
        #(time_length*1us);
    endtask

    task test_wait_result();
        do begin
            #(600ns);
        end while (m_env.sc.used(1'b0) != 0);
        timeout = 0;
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info(this.get_full_name(), {"\n\tTEST : ", this.get_type_name(), " END\n"}, UVM_NONE);
        if (timeout) begin
            `uvm_error(this.get_full_name(), "\n\t===================================================\n\tTIMEOUT SOME PACKET STUCK IN DESIGN\n\t===================================================\n\n");
        end
    endfunction
endclass
