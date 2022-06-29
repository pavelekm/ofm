/*
 * file       : sequence_lib.sv
 * Copyright (C) 2022 CESNET z. s. p. o.
 * description: UVM Byte array to MII sequence library
 * date       : 2022
 * author     : Oliver Gurka <xgurka00@stud.fit.vutbr.cz>
 *
 * SPDX-License-Identifier: BSD-3-Clause
*/

class sequence_lib #(CHANNELS, CHANNEL_WIDTH) extends uvm_sequence_library #(uvm_mii::sequence_item #(CHANNELS, CHANNEL_WIDTH));
    `uvm_object_param_utils(uvm_byte_array_mii::sequence_lib #(CHANNELS, CHANNEL_WIDTH))
    `uvm_sequence_library_utils(uvm_byte_array_mii::sequence_lib #(CHANNELS, CHANNEL_WIDTH))

    function new(string name = "sequence_library");
        super.new(name);
        init_sequence_library();
    endfunction

    virtual function void load_sequences();
        this.add_sequence(uvm_byte_array_mii::sequence_simple #(CHANNELS, CHANNEL_WIDTH)::get_type());
    endfunction

endclass