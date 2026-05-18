# Pre-hook for write_bitstream step — waive I/O DRC for unconstrained debug ports
# uart_txd_0 and cim_done_irq_0 are optional debug pins not wired on MZU15B.
# LOCs and IOSTANDARDs will be assigned when the production board is available.
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
