extends SceneTree

## Minimal external-script capability probe; never touches player saves.
func _init() -> void:
	var output_directory := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--benchmark-output="):
			output_directory = argument.trim_prefix("--benchmark-output=")
	if output_directory.is_empty() or not output_directory.is_absolute_path():
		printerr("PROBE requires an absolute --benchmark-output directory")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output_directory)
	var file := FileAccess.open(output_directory.path_join("external-script-probe.json"), FileAccess.WRITE)
	if file == null:
		printerr("PROBE output is not writable")
		quit(2)
		return
	file.store_string(JSON.stringify({"external_script_ran": true,
		"script_path": get_script().resource_path, "executable_path": OS.get_executable_path(),
		"resource_root": ProjectSettings.globalize_path("res://"),
		"editor_feature": OS.has_feature("editor"), "debug_feature": OS.has_feature("debug"),
		"packed_main_scene_exists": FileAccess.file_exists("res://scenes/main.tscn"),
		"process_id": OS.get_process_id()}))
	file.flush()
	file.close()
	print("RELEASE_EXTERNAL_SCRIPT_PROBE_PASS")
	quit(0)
