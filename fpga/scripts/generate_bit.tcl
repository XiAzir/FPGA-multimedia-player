set task_root [file normalize [file join [file dirname [info script]] ..]]
set project_dir $task_root/src/td_project
set output_dir $task_root/build/manual
cd $project_dir
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    import_db $output_dir/AC201_tf_hdmi_pr.db
    commit_param -step bitgen
    bitgen -bit $output_dir/AC201_player_c41_museum_osd.bit
} message]} {
    puts "BITGEN_ERROR: $message"
    exit 1
}
puts "BITSTREAM_GENERATED"
exit




