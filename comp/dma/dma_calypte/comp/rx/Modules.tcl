# Modules.tcl: Components include script
# Copyright (C) 2022 CESNET
# Author(s): Vladislav Valek <xvalek14@vutbr.cz>
#


lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"

set HDR_INSERTOR_BASE       "$ENTITY_BASE/comp/hdr_insertor"
set HDR_MANAGER_BASE        "$ENTITY_BASE/comp/hdr_manager"
set TRANS_BUFFER_BASE       "$ENTITY_BASE/comp/trans_buffer"
set INPUT_BUFFER_BASE       "$ENTITY_BASE/comp/input_buffer"
set SW_MANAGER_BASE         "$ENTITY_BASE/comp/software_manager"
set MFB_FIFOX_BASE          "$OFM_PATH/comp/mfb_tools/storage/fifox"

lappend COMPONENTS \
      [ list "RX_DMA_HDR_INSERTOR"    $HDR_INSERTOR_BASE         "FULL"] \
      [ list "RX_DMA_HDR_MANAGER"     $HDR_MANAGER_BASE          "FULL"] \
      [ list "RX_DMA_TRANS_BUFFER"    $TRANS_BUFFER_BASE         "FULL"] \
      [ list "RX_DMA_INPUT_BUFFER"    $INPUT_BUFFER_BASE         "FULL"] \
      [ list "RX_DMA_SW_MANAGER"      $SW_MANAGER_BASE           "FULL"] \
      [ list "MFB_FIFOX"              $MFB_FIFOX_BASE            "FULL"] \


lappend MOD "$ENTITY_BASE/rx_dma_calypte.vhd"
