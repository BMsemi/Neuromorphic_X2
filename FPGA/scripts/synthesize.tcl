set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build synthesis]
file mkdir $out
read_verilog [glob [file join $root rtl *.v]]
synth_design -top pe512_system -part xczu7ev-ffvc1156-2-e -mode out_of_context
create_clock -name pe_clk -period 10.000 [get_ports clk]
report_utilization -hierarchical -file [file join $out utilization.rpt]
report_timing_summary -file [file join $out timing_estimate.rpt]
write_checkpoint -force [file join $out pe512_system_synth.dcp]
puts "SHARED_PE_SYNTHESIS_PASSED"
