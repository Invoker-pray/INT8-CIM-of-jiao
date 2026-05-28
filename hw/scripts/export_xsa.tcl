# Export XSA with bitstream + sysdef.xml from existing Vivado project
# Usage: vivado -mode batch -source export_xsa.tcl vivado_proj/cim_soc.xpr output_dir/
open_project [lindex $argv 0]
set output_dir [lindex $argv 1]

# Open block design FIRST so write_hw_platform includes sysdef.xml
set bd_list [get_bd_designs]
if {[llength $bd_list] > 0} {
    open_bd_design [lindex $bd_list 0]
}

# Open the implemented design to make bitstream available
open_run impl_1
write_hw_platform -fixed -include_bit -force ${output_dir}/cim_soc.xsa

# Verify sysdef.xml is present in the XSA
set zip_ok [catch {exec unzip -l ${output_dir}/cim_soc.xsa | grep sysdef.xml} verify_out]
if {${zip_ok} != 0} {
    puts "WARN: sysdef.xml not found in XSA. PYNQ v3.0+ requires it."
    puts "WARN: Use .hwh directly as workaround: Overlay('cim_soc.hwh')"
    # Manual injection of sysdef.xml as fallback
    set hwh_dir [glob ${output_dir}/../cim_soc.gen/sources_1/bd/system/hw_handoff]
    set sysdef_src [glob ${hwh_dir}/sysdef.xml]
    if {[file exists ${sysdef_src}]} {
        set tmp_base ${output_dir}/xsa_tmp
        file mkdir ${tmp_base}
        exec unzip -o ${output_dir}/cim_soc.xsa -d ${tmp_base}
        file copy -force ${sysdef_src} ${tmp_base}/sysdef.xml
        exec bash -c "cd ${tmp_base} && zip -qr ${output_dir}/cim_soc.xsa ."
        file delete -force {*}[glob ${tmp_base}/*]
        puts "INFO: sysdef.xml injected into XSA."
    }
} else {
    puts "INFO: sysdef.xml present in XSA."
}

close_project
