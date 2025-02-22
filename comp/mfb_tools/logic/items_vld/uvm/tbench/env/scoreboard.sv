// scoreboard.sv: Scoreboard for verification
// Copyright (C) 2023 CESNET z. s. p. o.
// Author(s): Daniel Kriz <danielkriz@cesnet.cz>

// SPDX-License-Identifier: BSD-3-Clause

class scoreboard #(META_WIDTH, MVB_DATA_WIDTH, MVB_ITEMS, MFB_ITEM_WIDTH, OFFSET_WIDTH, LENGTH_WIDTH, VERBOSITY) extends uvm_scoreboard;
    `uvm_component_param_utils(uvm_items_valid::scoreboard #(META_WIDTH, MVB_DATA_WIDTH, MVB_ITEMS, MFB_ITEM_WIDTH, OFFSET_WIDTH, LENGTH_WIDTH, VERBOSITY))

    int unsigned compared;
    int unsigned errors;

    uvm_analysis_export #(uvm_logic_vector_array::sequence_item #(MFB_ITEM_WIDTH)) input_mfb;
    uvm_analysis_export #(uvm_logic_vector::sequence_item #(META_WIDTH))           input_meta;
    uvm_analysis_export #(uvm_logic_vector::sequence_item #(MVB_DATA_WIDTH))       out_mvb;
    uvm_analysis_export #(uvm_logic_vector::sequence_item #(1))                    end_mvb;

    uvm_tlm_analysis_fifo #(uvm_logic_vector::sequence_item #(MVB_DATA_WIDTH))   dut_mvb;
    uvm_tlm_analysis_fifo #(uvm_logic_vector::sequence_item #(1))                dut_end_mvb;
    uvm_tlm_analysis_fifo #(uvm_logic_vector::sequence_item #(MVB_DATA_WIDTH))   model_mvb;
    uvm_tlm_analysis_fifo #(uvm_logic_vector::sequence_item #(1))                model_mvb_end;

    model #(META_WIDTH, MVB_DATA_WIDTH, MFB_ITEM_WIDTH, OFFSET_WIDTH, LENGTH_WIDTH, VERBOSITY) m_model;

    // Contructor of scoreboard.
    function new(string name, uvm_component parent);
        super.new(name, parent);

        input_mfb     = new("input_mfb"    , this);
        input_meta    = new("input_meta"   , this);
        out_mvb       = new("out_mvb"      , this);
        end_mvb       = new("end_mvb"      , this);

        dut_mvb       = new("dut_mvb"      , this);
        dut_end_mvb   = new("dut_end_mvb"  , this);
        model_mvb     = new("model_mvb"    , this);
        model_mvb_end = new("model_mvb_end", this);

        compared      = 0;
        errors        = 0;

    endfunction

    function int unsigned used();
        int unsigned ret = 0;
        ret |= (dut_mvb.used()         != 0);
        ret |= (model_mvb.used()       != 0);
        ret |= (model_mvb_end.used() != 0);
        ret |= (dut_end_mvb.used()     != 0);
        return ret;
    endfunction


    function void build_phase(uvm_phase phase);
        m_model    = model#(META_WIDTH, MVB_DATA_WIDTH, MFB_ITEM_WIDTH, OFFSET_WIDTH, LENGTH_WIDTH, VERBOSITY)::type_id::create("m_model", this);
    endfunction

    function void connect_phase(uvm_phase phase);

        // connects input data to the input of the model
        input_mfb.connect(m_model.input_mfb.analysis_export);
        input_meta.connect(m_model.input_meta.analysis_export);

        // processed data from the output of the model connected to the analysis fifo
        m_model.out_mvb.connect(model_mvb.analysis_export);
        m_model.out_mvb_end.connect(model_mvb_end.analysis_export);
        // connects the data from the DUT to the analysis fifo
        out_mvb.connect(dut_mvb.analysis_export);
        end_mvb.connect(dut_end_mvb.analysis_export);

    endfunction

    task run_phase(uvm_phase phase);

        uvm_logic_vector::sequence_item #(MVB_DATA_WIDTH) tr_dut_mvb;
        uvm_logic_vector::sequence_item #(1)              tr_dut_end_mvb;
        uvm_logic_vector::sequence_item #(MVB_DATA_WIDTH) tr_model_mvb;
        uvm_logic_vector::sequence_item #(1)              tr_model_mvb_end;
        string msg = "\n";

        forever begin

            model_mvb.get(tr_model_mvb);
            model_mvb_end.get(tr_model_mvb_end);
            dut_mvb.get(tr_dut_mvb);
            dut_end_mvb.get(tr_dut_end_mvb);

            msg = "\n";
            $swrite(msg, "%sMVB Model %s\n" , msg, tr_model_mvb.convert2string());
            $swrite(msg, "%sEND Model %d\n", msg, tr_model_mvb_end.data);
            $swrite(msg, "%sMVB DUT %s\n"   , msg, tr_dut_mvb.convert2string());
            $swrite(msg, "%sEND DUT %d\n"   , msg, tr_dut_end_mvb.data);
            `uvm_info(this.get_full_name(), msg, UVM_MEDIUM)

            compared++;

            if (tr_model_mvb.compare(tr_dut_mvb) == 0) begin
                string msg = "";
                errors++;

                `uvm_info(this.get_full_name(), msg ,UVM_NONE)
                $swrite(msg, "%s\n\tComparison failed at Item number %d! \n\tModel Item:\n%s\n\tDUT Item:\n%s", msg, compared, tr_model_mvb.convert2string(), tr_dut_mvb.convert2string());
                `uvm_error(this.get_full_name(), msg);
            end

            if (tr_model_mvb_end.compare(tr_dut_end_mvb) == 0) begin
                string msg = "";
                errors++;

                `uvm_info(this.get_full_name(), msg ,UVM_NONE)
                $swrite(msg, "%s\n\tComparison failed at Item number %d! \n\tModel Item:\n%s\n\tDUT Item:\n%s", msg, compared, tr_model_mvb_end.convert2string(), tr_dut_end_mvb.convert2string());
                `uvm_error(this.get_full_name(), msg);
            end

            if ((compared % 10000) == 0) begin
                string msg = "";
                $swrite(msg, "\n%s%d transactions were compared\n", msg, compared);
                `uvm_info(this.get_full_name(), msg ,UVM_NONE)
            end

        end

    endtask

    function void report_phase(uvm_phase phase);

        if (errors == 0 && this.used() == 0) begin 
            string msg = "";

            $swrite(msg, "%s\nCompared Items: %0d", msg, compared);
            `uvm_info(get_type_name(), {msg, "\n\n\t---------------------------------------\n\t----     VERIFICATION SUCCESS      ----\n\t---------------------------------------"}, UVM_NONE)
        end else begin
            string msg = "";

            $swrite(msg, "%s\nCompared Items: %0d and errors %0d", msg, compared, errors);
            `uvm_info(get_type_name(), {msg, "\n\n\t---------------------------------------\n\t----     VERIFICATION FAILED       ----\n\t---------------------------------------"}, UVM_NONE)
        end

    endfunction

endclass
