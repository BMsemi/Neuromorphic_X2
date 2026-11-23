set root [file normalize [file join [file dirname [info script]] ..]]
set build D:/fpga_build/shared_pe512_v2
if {[info exists ::env(SHARED_PE_BUILD)]} {set build $::env(SHARED_PE_BUILD)}
if {[file exists [file join $build shared_pe.xpr]]} {error "Build exists; use a fresh SHARED_PE_BUILD directory"}
file mkdir $build
create_project shared_pe $build -part xczu7ev-ffvc1156-2-e
set_property board_part xilinx.com:zcu106:part0:2.6 [current_project]
set_property target_language Verilog [current_project]
file mkdir [file join $build src]
foreach source [glob [file join $root rtl *.v]] {
 file copy -force $source [file join $build src]
}
add_files -norecurse [glob [file join $build src *.v]]
update_compile_order -fileset sources_1
create_bd_design shared_pe
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* psu
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} [get_bd_cells psu]
set_property -dict [list CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100}] [get_bd_cells psu]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst_pl
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* ctrl
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells ctrl]
create_bd_cell -type module -reference pe512_axi pe
foreach pin {psu/maxihpm0_fpd_aclk rst_pl/slowest_sync_clk ctrl/aclk pe/aclk} {
 connect_bd_net [get_bd_pins psu/pl_clk0] [get_bd_pins $pin]
}
connect_bd_net [get_bd_pins psu/pl_resetn0] [get_bd_pins rst_pl/ext_reset_in]
connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] [get_bd_pins ctrl/aresetn] [get_bd_pins pe/aresetn]
connect_bd_intf_net [get_bd_intf_pins psu/M_AXI_HPM0_FPD] [get_bd_intf_pins ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl/M00_AXI] [get_bd_intf_pins pe/S_AXI]
assign_bd_address -offset 0xA0000000 -range 64K -target_address_space [get_bd_addr_spaces psu/Data] [get_bd_addr_segs pe/S_AXI/reg0] -force
validate_bd_design
save_bd_design
set bd [get_files -all */shared_pe.bd]
set_property synth_checkpoint_mode None $bd
generate_target all $bd
add_files -norecurse [make_wrapper -files $bd -top]
set_property top shared_pe_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1
set_param general.maxThreads 2
launch_runs synth_1 -jobs 2
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
set synth_log [open [file join $build shared_pe.runs synth_1 runme.log] r]
set synth_text [read $synth_log]
close $synth_log
if {[string first "CRITICAL WARNING" $synth_text]>=0} {error "Synthesis critical warning; fix before implementation"}
launch_runs impl_1 -to_step write_bitstream -jobs 2
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
open_run impl_1
report_utilization -file [file join $build utilization.rpt]
report_timing_summary -file [file join $build timing.rpt]
report_drc -file [file join $build drc.rpt]
foreach kind {max min} {
 set paths [get_timing_paths -delay_type $kind -max_paths 1]
 if {[llength $paths]==0 || [get_property SLACK $paths]<0} {error "Timing failed: $kind"}
}
set deploy [file join $root build physical overlay]
file mkdir $deploy
file copy -force [file join $build shared_pe.runs impl_1 shared_pe_wrapper.bit] [file join $deploy shared_pe.bit]
file copy -force [file join $build shared_pe.gen sources_1 bd shared_pe hw_handoff shared_pe.hwh] [file join $deploy shared_pe.hwh]
foreach name {utilization.rpt timing.rpt drc.rpt} {file copy -force [file join $build $name] [file join $deploy $name]}
puts SHARED_PE_BITSTREAM_PASSED
exit
