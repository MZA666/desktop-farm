extends SceneTree

## This launches the real graphical app with an isolated full-scale fixture.
## It is not a player-facing fast-forward mode or a 30-minute performance pass.
const PHASE_SECONDS := 22.0
var app: Node
var phases: Array = []
var started_usec := 0
var output_directory := ""
var status_path := ""
var result_path := ""

func _init() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--benchmark-output="):
			output_directory = argument.trim_prefix("--benchmark-output=")
	if output_directory.is_empty():
		# Source-only fallback. Exported runs must supply an absolute directory.
		output_directory = ProjectSettings.globalize_path("res://.review")
	if not output_directory.is_absolute_path():
		printerr("Benchmark output directory must be absolute.")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output_directory)
	status_path = output_directory.path_join("benchmark-stage.json")
	result_path = output_directory.path_join("benchmark-runtime.json")
	_run.call_deferred()

func _write_json(path: String, content: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(content))
		file.flush()
		file.close()

func _status(phase: String, measuring: bool) -> void:
	_write_json(status_path, {"phase": phase, "measuring": measuring,
		"process_id": OS.get_process_id(), "tick_msec": Time.get_ticks_msec()})

func _run() -> void:
	if not OS.get_cmdline_user_args().has("--benchmark-fixture"):
		printerr("Benchmark requires --benchmark-fixture; refusing to use player save.")
		quit(2)
		return
	if DisplayServer.get_name() == "headless":
		printerr("Runtime benchmark needs a graphics display.")
		quit(2)
		return
	_status("initializing", false)
	app = load("res://scenes/main.tscn").instantiate()
	root.add_child(app)
	await create_timer(3.0).timeout
	if not app.host.ready_for_desktop:
		printerr("Desktop native module/instance startup failed.")
		_status("failed", false)
		quit(2)
		return
	started_usec = Time.get_ticks_usec()
	for phase in [
		{"id": "farm_30", "scene": "farm", "power": false, "collapsed": false},
		{"id": "ranch_30", "scene": "ranch", "power": false, "collapsed": false},
		{"id": "pond_30", "scene": "pond", "power": false, "collapsed": false},
		{"id": "farm_15", "scene": "farm", "power": true, "collapsed": false},
		{"id": "collapsed_30", "scene": "farm", "power": false, "collapsed": true},
	]:
		await _measure(phase)
	var result := {
		"engine": Engine.get_version_info(), "phases": phases, "process_id": OS.get_process_id(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"video_vendor": RenderingServer.get_video_adapter_vendor(),
		"api_version": RenderingServer.get_video_adapter_api_version(),
		"dpi_scale": app.host.dpi_scale, "screen_pixels": [DisplayServer.screen_get_size().x, DisplayServer.screen_get_size().y],
		"window_pixels": [root.size.x, root.size.y], "logic_seconds": app.model.state.elapsed,
		"population": {"plots": app.model.state.plots.filter(func(p): return p.open).size(),
			"grass": app.model.state.grass.filter(func(g): return g.open).size(),
			"animals": app.model.state.animals.size(), "farmers": app.model.state.farmers.size(), "fish": app.model.state.fish.size()},
		"total_phase_wall_seconds": float(Time.get_ticks_usec() - started_usec) / 1000000.0,
		"save_path": app.saves.path, "headless": false,
		"executable_path": OS.get_executable_path(),
		"resource_root": ProjectSettings.globalize_path("res://"),
		"main_scene_resource": app.scene_file_path,
		"main_scene_physical_file_exists": FileAccess.file_exists(ProjectSettings.globalize_path("res://scenes/main.tscn")),
		"editor_feature": OS.has_feature("editor"), "debug_feature": OS.has_feature("debug"),
		"benchmark_script_path": get_script().resource_path,
	}
	app._save_now()
	_write_json(result_path, result)
	_status("complete", false)
	print("GRAPHICAL_BENCHMARK_COMPLETE ", JSON.stringify(result))
	app.host.shutdown()
	quit(0)

func _measure(phase: Dictionary) -> void:
	_status(str(phase.id), false)
	app._set_scene(str(phase.scene))
	app.model.command("settings", {"values": {"interactive": false,
		"power_saving": phase.power, "collapsed": phase.collapsed}})
	app._apply_settings()
	await create_timer(2.0).timeout
	var native_visible := bool(app.host.native.call("is_visible"))
	var toolbar_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, app.toolbar.get_window_id())
	var toolbar_visible := bool(app.host.native.call("window_is_visible", toolbar_handle))
	if native_visible == bool(phase.collapsed) or not toolbar_visible:
		printerr("Benchmark visibility precondition failed: ", phase.id)
		_status("failed", false)
		quit(2)
		return
	_status(str(phase.id), true)
	var start := Time.get_ticks_usec()
	var start_logic := float(app.model.state.elapsed)
	var frame_count := 0
	var process_peak := 0.0
	var static_memory_peak := 0.0
	var draw_calls_sum := 0.0
	var scene_draw_calls_sum := 0.0
	var toolbar_draw_calls_sum := 0.0
	var popup_draw_calls_sum := 0.0
	while float(Time.get_ticks_usec() - start) / 1000000.0 < PHASE_SECONDS:
		await process_frame
		frame_count += 1
		process_peak = maxf(process_peak, Performance.get_monitor(Performance.TIME_PROCESS))
		static_memory_peak = maxf(static_memory_peak, Performance.get_monitor(Performance.MEMORY_STATIC))
		draw_calls_sum += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		# Verified against the actual 4.7.2 extension API metadata:
		# get_render_info(RenderInfoType type, RenderInfo info).
		scene_draw_calls_sum += root.get_render_info(Viewport.RENDER_INFO_TYPE_CANVAS, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
		toolbar_draw_calls_sum += app.toolbar.get_render_info(Viewport.RENDER_INFO_TYPE_CANVAS, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
		popup_draw_calls_sum += app.popup.get_render_info(Viewport.RENDER_INFO_TYPE_CANVAS, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var wall := float(Time.get_ticks_usec() - start) / 1000000.0
	var logic_delta := float(app.model.state.elapsed) - start_logic
	var row := {"phase": phase.id, "scene": phase.scene, "collapsed": phase.collapsed,
		"fps_cap": Engine.max_fps, "wall_seconds": wall, "logic_seconds": logic_delta,
		"process_frames": frame_count, "process_fps": float(frame_count) / wall,
		"logic_drift_seconds": logic_delta - wall,
		"max_process_frame_seconds": process_peak, "static_memory_peak_bytes": static_memory_peak,
		"scene_hwnd_visible": native_visible, "toolbar_hwnd_visible": toolbar_visible,
		"scene_animation_processing": app.view.is_processing(), "average_total_draw_calls": draw_calls_sum / maxf(1, frame_count),
		"average_scene_canvas_draw_calls": scene_draw_calls_sum / maxf(1, frame_count),
		"average_toolbar_canvas_draw_calls": toolbar_draw_calls_sum / maxf(1, frame_count),
		"average_popup_canvas_draw_calls": popup_draw_calls_sum / maxf(1, frame_count)}
	phases.append(row)
	_status(str(phase.id), false)
	print("BENCHMARK_PHASE ", JSON.stringify(row))
