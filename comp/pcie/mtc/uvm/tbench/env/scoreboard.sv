//-- scoreboard.sv: Scoreboard for verification
//-- Copyright (C) 2023 CESNET z. s. p. o.
//-- Author(s): Daniel Kriz <danielkriz@cesnet.cz>

//-- SPDX-License-Identifier: BSD-3-Clause

class scoreboard #(MFB_ITEM_WIDTH, DEVICE, ENDPOINT_TYPE, MI_DATA_WIDTH, MI_ADDR_WIDTH) extends uvm_scoreboard;
    `uvm_component_param_utils(uvm_mtc::scoreboard #(MFB_ITEM_WIDTH, DEVICE, ENDPOINT_TYPE, MI_DATA_WIDTH, MI_ADDR_WIDTH))

    uvm_common::subscriber #(uvm_logic_vector_array::sequence_item#(MFB_ITEM_WIDTH))                  analysis_export_cq_data;
    uvm_common::subscriber #(uvm_logic_vector::sequence_item#(sv_pcie_meta_pack::PCIE_CQ_META_WIDTH)) analysis_export_cq_meta;
    //DUT OUTPUT
    uvm_analysis_export #(uvm_logic_vector_array::sequence_item#(MFB_ITEM_WIDTH))                  analysis_export_cc_data;
    uvm_analysis_export #(uvm_logic_vector::sequence_item#(sv_pcie_meta_pack::PCIE_CC_META_WIDTH)) analysis_export_cc_meta;
    uvm_common::subscriber #(uvm_mi::sequence_item_response #(MI_DATA_WIDTH))                      analysis_export_cc_mi;

    // COMPARERS
    uvm_mtc::mi_cmp_rq #(MI_DATA_WIDTH, uvm_mi::sequence_item_request #(MI_DATA_WIDTH, MI_ADDR_WIDTH, 0))   m_mi_cmp_rq;
    uvm_common::comparer_ordered #(uvm_logic_vector::sequence_item#(sv_pcie_meta_pack::PCIE_CC_META_WIDTH)) m_mi_cmp_meta_rs;
    uvm_mtc::mi_cmp_rs #(MFB_ITEM_WIDTH) m_mi_cmp_rs;
    uvm_mtc::mi_subscriber #(MI_DATA_WIDTH, MI_ADDR_WIDTH) mi_scrb;

    model #(MFB_ITEM_WIDTH, DEVICE, ENDPOINT_TYPE, MI_DATA_WIDTH, MI_ADDR_WIDTH) m_model;
    response_model #(MFB_ITEM_WIDTH, DEVICE, ENDPOINT_TYPE, MI_DATA_WIDTH, MI_ADDR_WIDTH) m_resp_model;


    local int unsigned read_compared;
    local int unsigned write_compared;
    local int unsigned compared;
    local int unsigned errors;

    // Contructor of scoreboard.
    function new(string name, uvm_component parent);
        super.new(name, parent);
        // DUT MODEL COMUNICATION 
        analysis_export_cc_data   = new("analysis_export_cc_data", this);
        analysis_export_cc_meta   = new("analysis_export_cc_meta", this);

        read_compared  = 0;
        write_compared = 0;
        compared       = 0;
        errors         = 0;
    endfunction

    function int unsigned success();
        int unsigned ret = 0;
        ret |= m_mi_cmp_rq.success();
        ret |= m_mi_cmp_meta_rs.success();
        ret |= m_mi_cmp_rs.success();
        return ret;
    endfunction

    function int unsigned used();
        int unsigned ret = 0;
        ret |= m_mi_cmp_rq.used();
        ret |= m_mi_cmp_meta_rs.used();
        ret |= m_mi_cmp_rs.used();
        return ret;
    endfunction


    //build phase
    function void build_phase(uvm_phase phase);
        m_model = model #(MFB_ITEM_WIDTH, DEVICE, ENDPOINT_TYPE, MI_DATA_WIDTH, MI_ADDR_WIDTH)::type_id::create("m_model", this);
        m_resp_model = response_model #(MFB_ITEM_WIDTH, DEVICE, ENDPOINT_TYPE, MI_DATA_WIDTH, MI_ADDR_WIDTH)::type_id::create("m_resp_model", this);

        analysis_export_cq_data = uvm_common::subscriber #(uvm_logic_vector_array::sequence_item#(MFB_ITEM_WIDTH))::type_id::create("analysis_export_cq_data", this);
        analysis_export_cq_meta = uvm_common::subscriber #(uvm_logic_vector::sequence_item#(sv_pcie_meta_pack::PCIE_CQ_META_WIDTH))::type_id::create("analysis_export_cq_meta", this);
        analysis_export_cc_mi = uvm_common::subscriber #(uvm_mi::sequence_item_response #(MI_DATA_WIDTH))::type_id::create("analysis_export_cc_mi", this);

        m_mi_cmp_rq      = uvm_mtc::mi_cmp_rq #(MI_DATA_WIDTH, uvm_mi::sequence_item_request #(MI_DATA_WIDTH, MI_ADDR_WIDTH, 0))::type_id::create("m_mi_cmp_rq", this);
        m_mi_cmp_meta_rs = uvm_common::comparer_ordered #(uvm_logic_vector::sequence_item#(sv_pcie_meta_pack::PCIE_CC_META_WIDTH))::type_id::create("m_mi_cmp_meta_rs", this);
        m_mi_cmp_rs      = uvm_mtc::mi_cmp_rs #(MFB_ITEM_WIDTH)::type_id::create("m_mi_cmp_rs", this);

        mi_scrb = uvm_mtc::mi_subscriber #(MI_DATA_WIDTH, MI_ADDR_WIDTH)::type_id::create("mi_scrb", this);

        m_mi_cmp_rq.model_tr_timeout_set(10000000ns);
        m_mi_cmp_rs.model_tr_timeout_set(10000000ns);
    endfunction

    function void connect_phase(uvm_phase phase);
        analysis_export_cq_data.port.connect(m_model.analysis_imp_cq_data.analysis_export);
        analysis_export_cq_meta.port.connect(m_model.analysis_imp_cq_meta.analysis_export);
        analysis_export_cq_data.port.connect(m_resp_model.analysis_imp_cq_data.analysis_export);
        analysis_export_cq_meta.port.connect(m_resp_model.analysis_imp_cq_meta.analysis_export);
        analysis_export_cc_mi.port.connect(m_resp_model.analysis_imp_cc_mi.analysis_export);

        m_model.analysis_port_mi_data.connect(m_mi_cmp_rq.analysis_imp_model);
        mi_scrb.port.connect(m_mi_cmp_rq.analysis_imp_dut);

        m_resp_model.analysis_port_cc_meta.connect(m_mi_cmp_meta_rs.analysis_imp_model);
        analysis_export_cc_meta.connect(m_mi_cmp_meta_rs.analysis_imp_dut);

        m_resp_model.analysis_port_cc.connect(m_mi_cmp_rs.analysis_imp_model);
        analysis_export_cc_data.connect(m_mi_cmp_rs.analysis_imp_dut);

    endfunction

    function void report_phase(uvm_phase phase);
        string msg = "";

        if (this.success() && this.used() == 0) begin
            `uvm_info(get_type_name(), {msg, "\n\n\t---------------------------------------\n\t----     VERIFICATION SUCCESS      ----\n\t---------------------------------------"}, UVM_NONE)
        end else begin
            `uvm_info(get_type_name(), {msg, "\n\n\t---------------------------------------\n\t----     VERIFICATION FAILED       ----\n\t---------------------------------------"}, UVM_NONE)
        end

    endfunction
endclass
