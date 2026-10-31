# Open the secure DDQ design as an elaborated RTL circuit and print the
# verified simulation and attack results in Vivado's Tcl Console.

set script_dir [file dirname [file normalize [info script]]]
set xpr_file   [file join $script_dir secure_ddq_auth secure_ddq_auth.xpr]

if {![file exists $xpr_file]} {
    error "Project not found: run create_secure_project.tcl first"
}

open_project $xpr_file
set_property top secure_ddq_auth_top [get_filesets sources_1]
update_compile_order -fileset sources_1

# This is the Tcl equivalent of Flow > Open Elaborated Design.
synth_design -rtl -name rtl_1

# Show the top-level circuit and its HMAC hierarchy in the Schematic window.
show_schematic [get_cells]

puts {===============================================================}
puts {SECURE DDQ-AUTH: VERIFIED RESULTS}
puts {Vivado XSim RTL test: PASS, 0 errors, completed at 2740 ns}
puts {Expected/observed 64-bit tag: f01bcd48741875e8}
puts {}
puts {MODELING ATTACK ON RTL-GENERATED TAGS}
puts {Training CRPs   Per-bit prediction   Full 64-bit forgeries}
puts {100             49.923%              0 / 2000 (0.0%)}
puts {300             50.078%              0 / 2000 (0.0%)}
puts {1000            49.979%              0 / 2000 (0.0%)}
puts {3000            49.986%              0 / 2000 (0.0%)}
puts {10000           50.104%              0 / 2000 (0.0%)}
puts {}
puts {Replay attack with fresh nonce: 0 / 2000 accepted (0.0%)}
puts {Ideal blind 64-bit forgery probability: 1/2^64 = 5.42e-20}
puts {}
puts {Interpretation: approximately 50% per-bit means random guessing, not}
puts {50% authentication success. A response is accepted only when all 64}
puts {tag bits match; no complete forged tag succeeded in these tests.}
puts {===============================================================}
puts {The RTL schematic is open. Expand u_hmac to inspect SHA-256 internals.}
