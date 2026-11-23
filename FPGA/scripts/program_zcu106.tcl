# Programs PL only. Do not run psu_init or reset/halt the Linux APU.
set root [file normalize [file join [file dirname [info script]] ..]]
set bit [file join $root build physical overlay shared_pe.bit]
if {![file exists $bit]} {set bit [file join $root reports physical overlay shared_pe.bit]}
if {[llength $argv]} {set bit [file normalize [lindex $argv 0]]}
if {![file exists $bit]} {error "Bitstream missing: $bit"}
open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets -quiet *]
if {[llength $targets]!=1} {error "Expected exactly one connected JTAG target: $targets"}
open_hw_target [lindex $targets 0]
set matching {}
foreach dev [get_hw_devices -quiet] {
 set part [get_property PART $dev]
 puts "JTAG_DEVICE: $dev PART=$part"
 # This ZCU106's JTAG IDCODE 14730093 is exposed as xczu7, without EV suffix.
 if {[string tolower $part] in {xczu7 xczu7ev}} {lappend matching $dev}
}
if {[llength $matching]!=1} {error "Expected one xczu7 JTAG device: $matching"}
set dev [lindex $matching 0]
current_hw_device $dev
refresh_hw_device $dev
puts "PROGRAM_TARGET: $dev"
puts "PROGRAM_FILE: $bit"
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev
# program_hw_devices reports startup status; this target has no BIT5_DONE property.
puts SHARED_PE_JTAG_PROGRAMMED
close_hw_manager
exit
