// sequence.sv Sequence generating frames
// Copyright (C) 2023 CESNET z. s. p. o.
// Author(s): Daniel Kriz <danielkriz@cesnet.cz>

// SPDX-License-Identifier: BSD-3-Clause

// This low level sequence define bus functionality
class byte_array_sequence#(PKT_MTU, OFFSET_WIDTH, LENGTH_WIDTH, MFB_ITEM_WIDTH) extends uvm_sequence#(uvm_logic_vector_array::sequence_item #(8));
    `uvm_object_param_utils(uvm_items_valid::byte_array_sequence#(PKT_MTU, OFFSET_WIDTH, LENGTH_WIDTH, MFB_ITEM_WIDTH))

    mailbox#(uvm_header_type::sequence_item#(PKT_MTU, OFFSET_WIDTH, LENGTH_WIDTH)) tr_export;
    uvm_header_type::sequence_item#(PKT_MTU, OFFSET_WIDTH, LENGTH_WIDTH) info_req;
    uvm_logic_vector_array::sequence_item #(MFB_ITEM_WIDTH)              req;

    function new(string name = "items_valid_sequence");
        super.new(name);
    endfunction

    task body;
        forever begin
            info_req  = uvm_header_type::sequence_item#(PKT_MTU, OFFSET_WIDTH, LENGTH_WIDTH)::type_id::create("info_req");
            req  = uvm_logic_vector_array::sequence_item #(MFB_ITEM_WIDTH)::type_id::create("req");

            tr_export.get(info_req);
            start_item(req);
            void'(req.randomize() with {data.size == (info_req.payload_size); });
            finish_item(req);
        end
    endtask
endclass

class logic_vector_sequence#(META_WIDTH) extends uvm_sequence #(uvm_logic_vector::sequence_item#(META_WIDTH));
    `uvm_object_param_utils(uvm_items_valid::logic_vector_sequence#(META_WIDTH))

    mailbox#(uvm_logic_vector::sequence_item#(META_WIDTH)) tr_export;

    function new(string name = "sequence_simple_lv_rx");
        super.new(name);
    endfunction

    task body;
        forever begin
            tr_export.get(req);
            start_item(req);
            finish_item(req);
        end
    endtask
endclass
