set task_root [file normalize [file join [file dirname [info script]] ..]]
set project_dir $task_root/src/td_project
set output_dir $task_root/build/manual
cd $project_dir
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project AC201_tf_hdmi.al -single_run -noanalyze
    load_run_param -run phy_1
    import_db $output_dir/AC201_tf_hdmi_gate.db
    set_param flow enable_seed on
    set_param place seed 2
    set_param place effort high
    set_param place opt_timing high
    set_param place crit_path_opt on
    set_param place post_place_opt high
    set_param place hfn_opt_effort high
    set_param route effort routability
    set_param gate pack_effort high
    report_param -stage place -detail -all -file $output_dir/strategy_actual.place.log
    report_param -stage route -detail -all -file $output_dir/strategy_actual.route.log
    commit_param -step place
    place
    update_timing -mode manhattan
    report_timing_status -file $output_dir/AC201_tf_hdmi_place.ts
    export_db $output_dir/AC201_tf_hdmi_place.db
    commit_param -step route
    route
    update_timing -mode final
    report_timing_status -file $output_dir/AC201_tf_hdmi_phy.ts
    report_timing_summary -file $output_dir/AC201_tf_hdmi_pr.timing
    check_timing -verbose -file $output_dir/AC201_tf_hdmi_chk.timing
    report_timing_exception -file $output_dir/AC201_tf_hdmi_exception.timing
    report_area -io_info -file $output_dir/AC201_tf_hdmi_phy.area
    write_verilog $output_dir/AC201_tf_hdmi_routed.v
    export_db $output_dir/AC201_tf_hdmi_pr.db
} message]} {
    puts "BUILD_ERROR: $message"
    exit 1
}
puts "PLACE_ROUTE_COMPLETE_WITH_REPORTS"
close_project
exit





