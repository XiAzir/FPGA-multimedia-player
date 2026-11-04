set task_root [file normalize [file join [file dirname [info script]] ..]]
set project_dir $task_root/src/td_project
set output_dir $task_root/build/manual
file mkdir $output_dir
cd $project_dir
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project AC201_tf_hdmi.al -single_run
    load_run_param -run syn_1
    set_param -run syn_1 gate eram_init off
    # TD bundled AreaOptimizeHigh; clocks and IO constraints unchanged.
    set_param gate add_map_lut_struct high
    set_param gate map_mode area_prior
    set_param gate multi_thread_mapping partition
    set_param rtl resource_sharing auto
    set_param rtl shifter_style shifter_reg
    # TD bundled AdderChainThresholdHigh, combined with AreaOptimizeHigh.
    set_param rtl min_ripple_len 18
    set_param gate mapper_lut_delay 1600
    set_param gate max_dsp 29
    set_param gate pack_effort high
    report_param -stage rtl -detail -all -file $output_dir/strategy_actual.rtl.log
    report_param -stage gate -detail -all -file $output_dir/strategy_actual.gate.log
    elaborate -top top
    read_adc ../user_source/constraints_source/pin.adc
    read_sdc ../user_source/constraints_source/timing.sdc
    read_sdc -ip rfifo_32_32_512 ../user_source/hdl_source/IP/afifo_16_32_256.tcl
    read_sdc -ip wfifo_32_32_512 ../user_source/hdl_source/IP/afifo_32_16_256.tcl
    export_db $output_dir/AC201_tf_hdmi_elaborate.db
    commit_param -step rtl
    optimize_rtl
    export_db $output_dir/AC201_tf_hdmi_rtl.db
    commit_param -step gate
    optimize_gate -packarea $output_dir/AC201_tf_hdmi_gate.area
    legalize_phy_inst
    update_timing
    report_timing_status -file $output_dir/AC201_tf_hdmi_gate.ts
    report_timing_summary -file $output_dir/AC201_tf_hdmi_gate.timing
    write_verilog $output_dir/AC201_tf_hdmi_gate.v
    export_db $output_dir/AC201_tf_hdmi_gate.db
} message]} {
    puts "BUILD_ERROR: $message"
    exit 1
}
puts "SYNTHESIS_COMPLETE_WITH_GATE_DATABASE"
close_project
exit





