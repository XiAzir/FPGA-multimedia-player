set task_root [file normalize [file join [file dirname [info script]] ..]]
set project_dir $task_root/src/td_project
set output_dir $task_root/build/manual
cd $project_dir
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project AC201_tf_hdmi.al -single_run -noanalyze
    load_run_param -run phy_1
    import_db $output_dir/AC201_tf_hdmi_pr.db
    fix_hold
    update_timing -mode final
    report_timing_status -file $output_dir/AC201_tf_hdmi_phy.ts
    report_timing_summary -file $output_dir/AC201_tf_hdmi_pr.timing
    check_timing -verbose -file $output_dir/AC201_tf_hdmi_chk.timing
    report_timing_exception -file $output_dir/AC201_tf_hdmi_exception.timing
    report_area -io_info -file $output_dir/AC201_tf_hdmi_phy.area
    write_verilog $output_dir/AC201_tf_hdmi_routed.v
    export_db $output_dir/AC201_tf_hdmi_pr.db
} message]} {
    puts "HOLD_FIX_ERROR: $message"
    exit 1
}
puts "POST_ROUTE_HOLD_FIX_COMPLETE"
close_project
exit




