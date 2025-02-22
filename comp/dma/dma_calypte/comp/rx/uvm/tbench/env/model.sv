//-- model.sv: Model of implementation
//-- Copyright (C) 2022 CESNET z. s. p. o.
//-- Author(s): Radek Iša <isa@cesnet.cz>

//-- SPDX-License-Identifier: BSD-3-Clause 

class model_packet extends uvm_logic_vector_array::sequence_item#(32);
    `uvm_object_utils(uvm_dma_ll::model_packet);
    time start_time;
    bit  data_packet;
    int unsigned packet_num;
    int unsigned channel;
    int unsigned part;
    int unsigned part_num;
    logic [32-1 :0] hdr[4];
    logic [35-1 :0] meta;

    function new(string name = "model_packet");
        super.new(name);
        data_packet  = 0;
    endfunction
endclass

class model_data;
    int unsigned data_ptr;
    int unsigned hdr_ptr;
endclass


class status_cbs extends uvm_reg_cbs;
    model_data data;

    function new(model_data data);
        this.data = data;
    endfunction

    virtual task pre_write(uvm_reg_item rw);
        if(rw.value[0][0] == 1'b1) begin
            data.data_ptr = 0;
            data.hdr_ptr = 0;
        end
    endtask
endclass

class model_accept#(CHANNELS) extends uvm_subscriber#(uvm_mvb::sequence_item#(1, $clog2(CHANNELS) + 1));
    `uvm_component_param_utils(uvm_dma_ll::model_accept #(CHANNELS))
    logic [$clog2(CHANNELS) + 1] fifo[$];

    function new(string name, uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void write(uvm_mvb::sequence_item#(1, $clog2(CHANNELS) + 1) t);
        if (t.src_rdy == 1'b1 && t.dst_rdy == 1'b1) begin
            for (int unsigned it = 0; it < 1; it++) begin
                if (t.vld[it] == 1'b1) begin
                    fifo.push_back(t.data[it]);
                end
            end
        end
    endfunction
endclass

//model
class model #(CHANNELS, PKT_SIZE_MAX, META_WIDTH, DEVICE) extends uvm_component;
    `uvm_component_param_utils(uvm_dma_ll::model #(CHANNELS, PKT_SIZE_MAX, META_WIDTH, DEVICE))

    localparam USER_META_WIDTH = 24 + $clog2(PKT_SIZE_MAX+1) + $clog2(CHANNELS);
    localparam IS_INTEL_DEV    = (DEVICE == "STRATIX10" || DEVICE == "AGILEX");

    uvm_tlm_analysis_fifo #(uvm_byte_array::sequence_item)                     analysis_imp_rx;
    uvm_tlm_analysis_fifo #(uvm_logic_vector::sequence_item#(USER_META_WIDTH)) analysis_imp_rx_meta;
    model_accept#(CHANNELS)                                                    analysis_dma;
    uvm_analysis_port     #(uvm_logic_vector_array::sequence_item#(32))        analysis_port_tx;
    uvm_analysis_port     #(uvm_logic_vector::sequence_item#(META_WIDTH))      analysis_port_tx_meta;

    typedef struct{
        logic [$clog2(PKT_SIZE_MAX+1)-1:0] packet_size;
        logic [$clog2(CHANNELS)-1:0]       channel;
        logic [24-1:0]                     meta;
        time                               input_time;
        logic [2-1:0]                      run; //[0] -> run, [1] -> soft compare
    } packet_info;
    local packet_info         input_meta[$];

    local regmodel#(CHANNELS) m_regmodel;
    local int unsigned        packets;
    local int unsigned        packets_processed;

    local model_data m_data[CHANNELS];
    local status_cbs m_status_cbs[CHANNELS];


    function new (string name, uvm_component parent = null);
        super.new(name, parent);
        analysis_imp_rx       = new("analysis_imp_rx", this);
        analysis_imp_rx_meta  = new("analysis_imp_rx_meta", this);
        analysis_port_tx      = new("analysis_port_tx", this);
        if (IS_INTEL_DEV)
            analysis_port_tx_meta = new("analysis_port_tx_meta", this);

        for (int unsigned it = 0; it < CHANNELS; it++) begin
            m_data[it]       = new();
            m_status_cbs[it] = new(m_data[it]);
        end

        packets = 0;
        packets_processed = 0;
    endfunction

    function void regmodel_set(regmodel#(CHANNELS) m_regmodel);
        this.m_regmodel = m_regmodel;

        for (int unsigned it = 0; it < CHANNELS; it++) begin
            uvm_reg_field_cb::add(this.m_regmodel.channel[it].control.dma_enable, m_status_cbs[it]);
        end
    endfunction

    function void get_pcie_header(int unsigned packet_size, logic [64-1:0] addr, output logic[32-1 : 0] header[], output logic[35-1 : 0] meta);
        logic [2-1:0]  at       = 0;
        logic [1-1:0]  ecrc     = 0;
        logic [3-1:0]  attr     = 0;
        logic [3-1:0]  tc       = 0;
        logic [1-1:0]  rq_id_enabled = 0;
        logic [16-1:0] cm_id    = 0; //compleater ID
        logic [8-1:0]  tag      = 0;
        logic [16-1:0] rq_id    = 0;
        logic [1-1:0]  poisoned = 0;
        logic [4-1:0]  rq_type  = 4'h1;
        // {TD, TH}
        logic [1-1:0] td  = 0;
        logic [1-1:0] th  = 0;
        logic [1-1:0] ln  = 0;
        // Tag8
        logic [1-1:0] tag_8  = 0;
        // Tag9
        logic [1-1:0] tag_9  = 0;
        // FBE
        logic [4-1 : 0] fbe = '1;
        // LBE
        logic [4-1 : 0] lbe = 4 - (packet_size % 4);
        // Address
        logic [64-1 : 0] global_id = '0;
        // BAR
        logic [3-1 : 0] bar = 3'b001;
        // TLP Prefix
        logic [3-1 : 0] tlp_pref = 6'd26;
        // Intel request type (MEM write)
        logic [8-1:0]   intel_rq_type  = 8'b01100000;
        logic [11-1:0]  dword_count = (packet_size + 3)/4; //size in dwords
        logic [128-1:0] out_hdr;

        if (IS_INTEL_DEV) begin
            // Intel HDR:
            // Address resolve
            if (|addr[64-1 : 32]) begin
                global_id = {addr[32-1 : 2], addr[2-1 : 0], addr[64-1 : 32]};
            end else
                global_id = {32'h0000, addr[2-1 : 0], addr[32-1 : 2]};
            // TLP PREFIX
            meta[32-1 : 0]  = tlp_pref;
            // // BAR
            meta[35-1 : 32] = bar;
            out_hdr = {global_id, cm_id, tag, lbe, fbe, intel_rq_type, rq_type, tag_9, tc, tag_8, attr[2], ln, th, td, poisoned, attr[1 : 0], at, dword_count};
        end else begin
            meta = '0;
            out_hdr = {ecrc, attr, tc, rq_id_enabled, cm_id, tag, rq_id, poisoned, rq_type, dword_count, addr[64-1:2], at};
        end
        header = {<<32{out_hdr}};
    endfunction

    function void get_dma_header(logic [16-1:0] frame_pointer, logic[16-1:0] frame_length, logic [24-1:0] meta, output logic[32-1 : 0] header[2]);
        logic [64-1:0] out_hdr;

        out_hdr = {meta, 7'b0, 1'b1, frame_pointer, frame_length};
        header = {<<32{out_hdr}};
    endfunction


    function void get_data(logic[32-1 : 0] packet[], int unsigned f_start, int unsigned f_end, output logic[32-1 : 0] out[]);
        out = new[f_end - f_start];
        for (int unsigned it = 0; it < f_end - f_start; it++) begin
            out[it] = packet[f_start + it];
        end
    endfunction

    task packet_send(byte unsigned packet[], time start_time, int unsigned channel, logic [24-1:0] meta);
        uvm_logic_vector::sequence_item#(META_WIDTH) packet_meta;

        model_packet               packet_output;
        logic[32-1 : 0]            pcie_hdr_tmp[4];
        logic[35-1 : 0]            pcie_meta_tmp;
        int unsigned               it;
        logic[32-1 : 0]            packet_end[];
        logic[32-1 : 0]            pcie_packet[];
        logic[32-1 : 0]            packet_hdr[2];
        int unsigned               packet_pointer_start;
        int unsigned               parts;
        logic [64-1:0]             addr;

        packet_pointer_start = m_data[channel].data_ptr;
        pcie_packet = new[packet.size()/4];
        for (it = 0; it < packet.size()/4; it++) begin
            pcie_packet[it] = {<<8{packet[it*4 +: 4]}};
        end
        parts = (packet.size() + 127)/128;
        //SEND PARTS OF PACKETS EXCEPT LAST PART
        for (it = 0; it < (parts-1); it++) begin
            packet_output = model_packet::type_id::create("packet_output");
            packet_output.packet_num   = packets;
            packet_output.data_packet  = 1;
            packet_output.channel      = channel;
            packet_output.part_num     = parts;
            packet_output.part         = it+1;
            packet_output.start_time   = start_time;

            addr = m_regmodel.channel[channel].data_base.get() + (m_data[channel].data_ptr*128);
            m_data[channel].data_ptr = (m_data[channel].data_ptr + 1) & m_regmodel.channel[channel].data_mask.get();
            get_pcie_header(128, addr, pcie_hdr_tmp, pcie_meta_tmp);
            if (IS_INTEL_DEV) begin
                packet_meta        = uvm_logic_vector::sequence_item#(META_WIDTH)::type_id::create("packet_meta");
                packet_output.data = pcie_packet[it*(128/4) +: 128/4];
                packet_output.hdr  = pcie_hdr_tmp;
                packet_output.meta = pcie_meta_tmp;
                packet_meta.data   = {pcie_meta_tmp, pcie_hdr_tmp};
                analysis_port_tx_meta.write(packet_meta);
            end else
                packet_output.data = {pcie_hdr_tmp, pcie_packet[it*(128/4) +: 128/4]};
            analysis_port_tx.write(packet_output);
        end

        //SEND LAST PART OF PACKET
        packet_output = model_packet::type_id::create("packet_output");
        packet_output.packet_num   = packets;
        packet_output.data_packet  = 1;
        packet_output.channel      = channel;
        packet_output.part_num     = parts;
        packet_output.part         = parts;
        packet_output.start_time   = start_time;

        get_data(pcie_packet, it*(128/4), packet.size()/4, packet_end);
        addr = m_regmodel.channel[channel].data_base.get() + (m_data[channel].data_ptr*128);
        m_data[channel].data_ptr = (m_data[channel].data_ptr + 1) & m_regmodel.channel[channel].data_mask.get();
        //get_pcie_header(packet_end.size(), addr, pcie_hdr_tmp);
        get_pcie_header(128, addr, pcie_hdr_tmp, pcie_meta_tmp);
        if (IS_INTEL_DEV) begin
            packet_meta        = uvm_logic_vector::sequence_item#(META_WIDTH)::type_id::create("packet_meta");
            packet_output.data = pcie_packet[it*(128/4) +: 128/4];
            packet_output.hdr  = pcie_hdr_tmp;
            packet_output.meta = pcie_meta_tmp;
            packet_meta.data   = {pcie_meta_tmp, pcie_hdr_tmp};
            analysis_port_tx_meta.write(packet_meta);
        end else
            packet_output.data = {pcie_hdr_tmp, packet_end};
        analysis_port_tx.write(packet_output);

        //SEND DMA HEADER
        packet_output = model_packet::type_id::create("packet_output");
        packet_output.packet_num   = packets;
        packet_output.data_packet  = 0;
        packet_output.channel      = channel;
        packet_output.part_num     = 1;
        packet_output.part         = 1;
        packet_output.start_time   = start_time;

        get_dma_header(packet_pointer_start, packet.size(), meta, packet_hdr);
        addr = m_regmodel.channel[channel].hdr_base.get() + (m_data[channel].hdr_ptr*8);
        m_data[channel].hdr_ptr = (m_data[channel].hdr_ptr + 1) & m_regmodel.channel[channel].hdr_mask.get();
        get_pcie_header(8, addr, pcie_hdr_tmp, pcie_meta_tmp);
        if (IS_INTEL_DEV) begin
            packet_meta        = uvm_logic_vector::sequence_item#(META_WIDTH)::type_id::create("packet_meta");
            packet_output.data = pcie_packet[it*(128/4) +: 128/4];
            packet_output.hdr  = pcie_hdr_tmp;
            packet_output.meta = pcie_meta_tmp;
            packet_meta.data   = {pcie_meta_tmp, pcie_hdr_tmp};
            analysis_port_tx_meta.write(packet_meta);
        end else
            packet_output.data = {pcie_hdr_tmp, packet_hdr};
        analysis_port_tx.write(packet_output);
    endtask

    task get_input();
        uvm_logic_vector::sequence_item#(USER_META_WIDTH)  tr_meta;
        packet_info info;
        forever begin
            analysis_imp_rx_meta.get(tr_meta);
            {info.packet_size, info.channel, info.meta} = tr_meta.data;
            info.input_time = $time();

            input_meta.push_back(info);
        end
    endtask

    function void build_phase(uvm_phase phase);
        analysis_dma = model_accept#(CHANNELS)::type_id::create("analysis_dma", this);;
    endfunction

    task run_phase(uvm_phase phase);
        uvm_byte_array::sequence_item tr;
        string                        msg;
        int unsigned                  compare;
        int unsigned                  soft_compare;
        logic                         dma_discard;
        logic [$clog2(CHANNELS)]      dma_channel;
        packet_info                   info;

        fork
            get_input();
        join_none

        forever begin
            //first get metadata. Because this is relevat for checking comparability of packet
            wait (input_meta.size() != 0);
            info = input_meta.pop_front();

            compare      = info.run[0];
            soft_compare = info.run[1];

            //get packet
            analysis_imp_rx.get(tr);
            packets++;
            if (tr.data.size() != info.packet_size) begin
                string msg;
                $swrite(msg, "\n\tVerification FAILED! Packet size in meta %0d isn't same as correct packet size %0d", info.packet_size, tr.data.size());
                `uvm_fatal(this.get_full_name(), msg);
            end

            //Check if packet have been discared of send when starting or stopping channel
            wait (analysis_dma.fifo.size() != 0);

            {dma_channel, dma_discard} = analysis_dma.fifo.pop_front();
            info.run[0]     = (m_regmodel.channel[info.channel].status.get() & 32'h1 ) | (m_regmodel.channel[info.channel].control.get() & 32'h1);
            info.run[1]     = (m_regmodel.channel[info.channel].status.get() & 32'h1 ) ^ (m_regmodel.channel[info.channel].control.get() & 32'h1);

            if (dma_channel != info.channel) begin
                `uvm_fatal(this.get_full_name(),  $sformatf("\n\tChannel send from DMA HDR MANAGER %0d isn't same as received packet channel %0d. Time %0dns", dma_channel, info.channel, info.input_time/1ns));
            end

            $swrite(msg, "%s\n\tINPUT TIME: %d\n", msg, info.input_time/1ns);
            $swrite(msg, "%s\tPACKET NUMBER: %d\n", msg, packets);
            $swrite(msg, "%s\tDISCARD: %h\n", msg, dma_discard);
            $swrite(msg, "%s\tDISCARD CHANNEL: %h\n", msg, dma_channel);
            $swrite(msg, "%s\tCHANNEL: %h\n", msg, info.channel);
            $swrite(msg, "%s\tPACKET: %s\n", msg, tr.convert2string());
            $swrite(msg, "%s\tCOMPARE: %d\n", msg, compare);
            $swrite(msg, "%s\tSOFT COMPARE: %d\n", msg, soft_compare);

            `uvm_info(this.get_full_name(), msg,  UVM_MEDIUM);

            //check if should be processed
            if (compare) begin
                if (soft_compare == 0 && dma_discard == 1) begin
                    string msg;
                    $swrite(msg, "\n\tReceive time %0dns\n\tPacket num %0d sended on channel %0d have been discarded but channel %0d is running:\n%s", info.input_time/1ns, packets,  info.channel, info.channel, tr.convert2string());
                    `uvm_error(this.get_full_name(), msg);
                end

                if (soft_compare == 0 || (soft_compare == 1 && dma_discard == 0)) begin
                    packets_processed++;
                    //channel run
                    $swrite(msg, "\n\tRX transaction channel %0d meta %h pakcet size %0d\n%s", info.channel, info.meta, info.packet_size, tr.convert2string());
                    `uvm_info(this.get_full_name(), msg,  UVM_MEDIUM);
                    packet_send(tr.data, info.input_time, info.channel, info.meta);
                end
            end
        end
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info(this.get_full_name(), $sformatf("\n\tModle received %0d packets. Model processed %0d packets and %0d packets have been discarded", packets, packets_processed, packets - packets_processed), UVM_NONE)
    endfunction

endclass
