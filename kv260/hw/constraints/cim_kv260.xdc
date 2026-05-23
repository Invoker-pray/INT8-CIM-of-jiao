# ============================================================================
# cim_kv260.xdc — KV260 CIM SoC constraints
# ============================================================================
# Pure AXI internal design — no external PL pins to constrain.
# PS pl_clk0 is auto-constrained by the ZynqMP board preset.
#
# KV260 has no board-level PL LEDs or PMOD constraints needed for CIM.
# If PMOD debug pins are added later, append pin constraints here.
# ============================================================================

# Bitstream compression (matches Xilinx KV260 platform convention)
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
