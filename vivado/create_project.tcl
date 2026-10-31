#=======================================================================
#  create_project.tcl  -  Vivado project for the DDQ-APUF sources
#
#  GUI : Tools > Run Tcl Script...  and pick this file
#        (or in the Tcl Console:  cd <package>/vivado ;  source create_project.tcl)
#        then Flow Navigator > Run Simulation > Run Behavioral Simulation.
#        Switch testbench: Sources window > Simulation Sources > right-click
#        sim_sar or sim_temp > "Make Active".
#
#  Batch (creates the project AND runs all three simulations, copying each
#  transcript to ../logs/ so plot_ddq.py can read it):
#        vivado -mode batch -source create_project.tcl -tclargs run
#
#  After sourcing in the GUI you can also type   ddq_run_all   in the Tcl
#  Console to run all three and collect the logs.
#=======================================================================

# Any 7-series part is fine for simulation. Change this to your board's
# part only if you plan to build hardware (see README, "Taking it to an FPGA").
set ddq_part "xc7a35tcpg236-1"
set ddq_proj "ddq_apuf"

#---------------------------------------------------------------- locate the package
# Normally the package root is the parent of this script's directory. But
# [info script] is EMPTY when the file's contents are PASTED into the Tcl
# Console instead of sourced, and Tcl would then resolve "." to Vivado's own
# working directory and look for rtl/ and tb/ under AppData. So: resolve it,
# then verify, and stop with a readable message rather than a file-not-found.
if {[info exists ddq_root]} {
    # user set it by hand:  set ddq_root D:/HST_Project/ddq-apuf
    set ddq_root [file normalize $ddq_root]
} elseif {[info exists ::env(DDQ_ROOT)]} {
    set ddq_root [file normalize $::env(DDQ_ROOT)]
} elseif {[info script] ne ""} {
    set ddq_root [file normalize [file join [file dirname [info script]] ..]]
} else {
    error "create_project.tcl: cannot tell where the package is.\n\
      This happens when the script is PASTED into the Tcl Console - Tcl has\n\
      no filename to work from. Either use Tools > Run Tcl Script... and pick\n\
      the file, or set the path first and source it:\n\
      \n\
          set ddq_root D:/HST_Project/ddq-apuf\n\
          source D:/HST_Project/ddq-apuf/vivado/create_project.tcl\n"
}
set ddq_here [file join $ddq_root vivado]

foreach ddq_f {rtl/ddq_apuf.v rtl/ddq_sar.v tb/tb_ddq_apuf.v tb/tb_ddq_sar.v tb/tb_ddq_temp.v} {
    if {![file exists [file join $ddq_root $ddq_f]]} {
        error "create_project.tcl: expected to find $ddq_f under\n\
      $ddq_root\n\
      but it is not there. Keep the unzipped folder intact (rtl/, tb/, vivado/),\n\
      or set ddq_root to the package folder before sourcing."
    }
}
puts "DDQ: package root = $ddq_root"

create_project $ddq_proj [file join $ddq_here $ddq_proj] -part $ddq_part -force
set_property target_language    Verilog [current_project]
set_property simulator_language Verilog [current_project]
set_property target_simulator   XSim    [current_project]

#---------------------------------------------------------------- design
add_files -fileset sources_1 -norecurse [list \
    [file join $ddq_root rtl ddq_apuf.v] \
    [file join $ddq_root rtl ddq_sar.v] ]
set_property top ddq_apuf_top [get_filesets sources_1]
update_compile_order -fileset sources_1

# Synthesis uses the structural view (Xilinx LUT6 delay lines). Out-of-context
# because ddq_apuf_top is a core, not a board-level top with pin constraints.
# (Vivado also predefines SYNTHESIS, which selects the same view.)
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
             -value {-mode out_of_context -verilog_define DDQ_SYNTH} \
             -objects [get_runs synth_1]

#---------------------------------------------------------------- simulation
# One simulation set per testbench. Run time is "-all": each testbench ends
# itself with $finish (the default of 1000 ns would stop them almost at once).
proc ddq_add_simset {name tb} {
    global ddq_root
    if {[llength [get_filesets -quiet $name]] == 0} {
        create_fileset -simset $name
    }
    set fs [get_filesets $name]
    set_property SOURCE_SET sources_1 $fs
    # [list ...] keeps a path containing spaces as ONE argument;
    # a bare string would be word-split by Tcl ("D:/HST Project/..." -> "D:/HST")
    add_files -fileset $name -norecurse [list [file join $ddq_root tb "$tb.v"]]
    set_property top     $tb            $fs
    set_property top_lib xil_defaultlib $fs
    set_property -name {xsim.simulate.runtime} -value {-all} -objects $fs
    set_property -name {xsim.simulate.log_all_signals} -value {false} -objects $fs
    update_compile_order -fileset $name
}

ddq_add_simset sim_1    tb_ddq_apuf
ddq_add_simset sim_sar  tb_ddq_sar
ddq_add_simset sim_temp tb_ddq_temp
current_fileset -simset [get_filesets sim_1]

#---------------------------------------------------------------- helpers
# Run one simulation set and copy its transcript into ../logs/
proc ddq_run_sim {simset logname} {
    global ddq_root
    set pdir  [get_property DIRECTORY [current_project]]
    set pname [get_property NAME      [current_project]]
    puts "DDQ: running $simset ..."
    launch_simulation -simset $simset -mode behavioral
    close_sim -force
    set src [file join $pdir "$pname.sim" $simset behav xsim simulate.log]
    if {[file exists $src]} {
        file mkdir [file join $ddq_root logs]
        file copy -force $src [file join $ddq_root logs $logname]
        puts "DDQ: $simset transcript -> logs/$logname"
    } else {
        puts "DDQ: WARNING - transcript not found at $src"
    }
}

proc ddq_run_all {} {
    ddq_run_sim sim_1    run.log
    ddq_run_sim sim_sar  run_sar.log
    ddq_run_sim sim_temp run_temp.log
    current_fileset -simset [get_filesets sim_1]
    puts "DDQ: done. Plot with:  python plot_ddq.py logs/run.log logs/run_sar.log logs/run_temp.log"
}

if {[info exists argv] && [lsearch -exact $argv run] >= 0} {
    ddq_run_all
} else {
    puts "DDQ: project created. Run Behavioral Simulation, or type  ddq_run_all  to run all three."
}
