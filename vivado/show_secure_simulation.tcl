# Open the secure DDQ authentication design and leave its behavioral
# simulation visible in the Vivado GUI.

set script_dir  [file dirname [file normalize [info script]]]
set secure_root [file normalize [file join $script_dir ..]]
set xpr_file    [file join $script_dir secure_ddq_auth secure_ddq_auth.xpr]

if {[file exists $xpr_file]} {
    open_project $xpr_file
} else {
    source [file join $script_dir create_secure_project.tcl]
}

set_property top tb_secure_ddq_auth_top [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation -mode behavioral
add_wave -r /tb_secure_ddq_auth_top/*
run all

puts "SECURE_DDQ: behavioral simulation complete; waveform window is open."
