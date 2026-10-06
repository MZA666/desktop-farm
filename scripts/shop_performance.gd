extends RefCounted

## Shared source/release benchmark for the real graphical main scene. The
## normal application entry passes its existing isolated main node to run().
## Measures the same isolated SAVE6 fixture
## for every phase. Opening/probing time is recorded separately from frame
## intervals. No formal save is loaded, read, modified, or written.
const PHASE_SECONDS := 8.0
const PROBE_COUNT := 3
var app: Node
var tree: SceneTree
var fixture: Dictionary = {}
var output_path := ""
var baseline_path := ""
var verify := false
var limits: Dictionary = {}
var phases: Array = []
var checks := 0
var failures: Array[String] = []

func _read_options() -> bool:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--shop-performance-output="): output_path = argument.trim_prefix("--shop-performance-output=")
		elif argument.begins_with("--shop-performance-baseline="): baseline_path = argument.trim_prefix("--shop-performance-baseline=")
		elif argument == "--shop-performance-verify": verify = true
		else:
			for key in ["max-open-ms", "max-refresh-ms", "max-quote-ms", "max-p95-ms", "max-over100", "max-open-ratio", "max-refresh-ratio"]:
				var prefix: String = "--shop-performance-" + str(key) + "="
				if argument.begins_with(prefix):
					var number: String = argument.trim_prefix(prefix)
					if not number.is_valid_float() or not is_finite(float(number)) or float(number) < 0:
						printerr("Invalid shop-performance limit: ", argument)
						return false
					limits[key] = float(number)
	if not OS.get_cmdline_user_args().has("--benchmark-fixture") or OS.get_name() != "Windows" or DisplayServer.get_name() == "headless":
		printerr("Shop-performance test requires Windows GUI and --benchmark-fixture; player data is never used.")
		return false
	if not output_path.is_absolute_path() or not output_path.replace("\\", "/").contains("/.review/") or not output_path.ends_with(".json"):
		printerr("Supply an absolute workspace .review JSON path with --shop-performance-output.")
		return false
	if not baseline_path.is_empty() and not baseline_path.is_absolute_path():
		printerr("Shop-performance baseline path must be absolute.")
		return false
	return true

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		printerr("SHOP_PERFORMANCE_FAIL: ", message)

func _write_json(path: String, content: Dictionary) -> bool:
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK: return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(content, "\t"))
	file.flush()
	var ok := file.get_error() == OK
	file.close()
	return ok

func _status(phase: String, measuring: bool) -> void:
	_write_json(output_path.get_basename() + "-stage.json", {"phase": phase, "measuring": measuring, "process_id": OS.get_process_id(), "tick_msec": Time.get_ticks_msec()})

func run(controller: Node, active_tree: SceneTree) -> int:
	app = controller
	tree = active_tree
	if not _read_options(): return 2
	_status("initializing", false)
	app.set_process(false)
	if not bool(app.get("benchmark_fixture")) or app.host == null or not app.host.ready_for_desktop or not app.host.test_instance:
		printerr("Shop benchmark did not start its independent native fixture.")
		return 2
	app.host.set_clock_paused(true)
	# This optional test-save path is also inside .review, even though normal
	# automatic saves are suppressed and this benchmark does not save at exit.
	app.saves.path = output_path.get_basename() + "-fixture-save.json"
	app.auto_save_elapsed = -3600.0
	app.model.command("settings", {"values": {"interactive": false, "power_saving": false, "collapsed": false, "display_mode": "expanded"}})
	fixture = app.model.snapshot()
	_check(int(fixture.version) == 6 and int(fixture.layout_version) == 6, "Fixture is SAVE6/Layout6")
	_check(app.model._validate(fixture).ok, "Fixture is a valid full-scale model")
	_check(app.config.crops.size() == 53, "Seed shop has all 53 configured crops")
	_check(Engine.max_fps == 30, "Actual main scene caps processing at 30 FPS")
	for scene_name in ["ranch", "pond"]:
		await _measure(str(scene_name), false)
		await _measure(str(scene_name), true)
	var comparisons := _compare_baseline()
	if verify: _verify_metrics()
	var result := {
		"schema": 1, "app_version": str(ProjectSettings.get_setting("application/config/version", "")),
		"phase_seconds": PHASE_SECONDS, "probe_count": PROBE_COUNT, "fps_cap": Engine.max_fps,
		"process_id": OS.get_process_id(), "executable_path": OS.get_executable_path(),
		"engine": Engine.get_version_info(), "editor_feature": OS.has_feature("editor"), "debug_feature": OS.has_feature("debug"),
		"main_scene_resource": app.scene_file_path, "resource_root": ProjectSettings.globalize_path("res://"), "runner_script_path": get_script().resource_path,
		"main_scene_physical_file_exists": FileAccess.file_exists(ProjectSettings.globalize_path("res://scenes/main.tscn")),
		"video_adapter": RenderingServer.get_video_adapter_name(), "api_version": RenderingServer.get_video_adapter_api_version(),
		"benchmark_fixture": true, "test_instance_namespace": "Local\\DesktopFarm.v07.test.%d" % OS.get_process_id(),
		"save_version": int(fixture.version), "layout_version": int(fixture.layout_version),
		"save_path": app.saves.path, "player_save_accessed": false, "save_written": false,
		"population": {"plots": fixture.plots.size(), "animals": fixture.animals.size(), "fish": fixture.fish.size(), "farmers": fixture.farmers.size(), "crop_definitions": app.config.crops.size()},
		"window_ownership": _windows(), "phases": phases, "comparisons": comparisons,
		"baseline_path": baseline_path, "verify": verify, "limits": limits,
		"checks": checks, "failures": failures, "passed": failures.is_empty(),
		"measurement_scope": "Natural 8s process-frame wall intervals; initial open and three explicit dirty/quote probes excluded from natural samples; identical restored isolated fixture per phase; no long-run CPU/memory acceptance claim."
	}
	var written := _write_json(output_path, result)
	_status("complete" if written and failures.is_empty() else "failed", false)
	print("SHOP_PERFORMANCE_COMPLETE ", JSON.stringify({"output": output_path, "checks": checks, "passed": failures.is_empty() and written, "phases": phases.map(func(row): return {"phase": row.phase, "p95_ms": row.frames.p95_ms, "max_ms": row.frames.max_ms, "over100": row.frames.over100, "open_ms": row.open_panel_ms, "dirty_refresh_ms": row.dirty_refresh_ms})}))
	app.set_process(false)
	app.host.set_clock_paused(true)
	app.host.shutdown()
	return 0 if written and failures.is_empty() else 1

func _windows() -> Dictionary:
	var result := {"process_id": OS.get_process_id(), "test_instance": bool(app.host.test_instance), "native_ready": bool(app.host.ready_for_desktop)}
	for pair in [["toolbar", app.toolbar], ["scenery", app.scene_window], ["popup", app.popup]]:
		var window: Window = pair[1]
		var window_id := window.get_window_id()
		# A hidden popup has no native window until its first show(). Main/root
		# window ID 0 is valid; only negative IDs must skip native queries.
		var handle: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window_id) if window_id >= 0 else 0
		result[str(pair[0])] = {"window_id": window_id, "hwnd": handle, "native_created": handle != 0, "hwnd_visible": bool(app.host.native.call("window_is_visible", handle)) if handle != 0 else false, "logical_visible": window.visible, "parent_is_owned_main": window == tree.root or window.get_parent() == app}
	return result

func _measure(scene_name: String, shop_open: bool) -> void:
	var phase_id := scene_name + ("_shop" if shop_open else "_closed")
	_status(phase_id, false)
	app.set_process(false)
	app.host.set_clock_paused(true)
	app._close_panel()
	var restored: Dictionary = app.model.restore(fixture)
	_check(restored.ok, phase_id + ": exact full-scale fixture restores")
	app.crop_search = ""
	app.crop_season = "全部"
	app.crop_mechanism = "全部"
	app.crop_unlocked_only = false
	app.selected_plot_ids = []
	app.auto_save_elapsed = -3600.0
	app.view._animal_tracks.clear()
	app.view._fish_tracks.clear()
	app.view._farmer_tracks.clear()
	app.view._gait_tracks.clear()
	app.view.set_model(app.model.state, true)
	app._set_scene(scene_name)
	app._apply_settings()
	# set_scene() clears fish interpolation tracks. Re-sample the frozen
	# fixture after the scene change so measurement starts with real actors.
	app.view.set_model(app.model.state, true)
	var open_panel_ms := 0.0
	if shop_open:
		var open_start := Time.get_ticks_usec()
		app._open_panel("crops")
		open_panel_ms = float(Time.get_ticks_usec() - open_start) / 1000.0
		_check(app._crop_quote_controls.size() == 53, phase_id + ": unfiltered seed shop renders 53 real cards")
	await tree.create_timer(0.8).timeout
	app._shop_refresh_elapsed = 0.0
	app.ui_elapsed = 0.0
	app.host.set_clock_paused(false)
	app.set_process(true)
	_check(app.view.is_processing() and not bool(app.view._desktop_suspended), phase_id + ": scenery animation is active")
	var windows_start := _windows()
	_check(bool(windows_start.scenery.hwnd_visible) and bool(windows_start.toolbar.hwnd_visible), phase_id + ": fixture scenery and toolbar are native-visible")
	var logic_start := float(app.model.state.elapsed)
	var animation_start := float(app.view._animation_seconds)
	var model_start := _model_positions(scene_name)
	var visual_start := _visual_positions(scene_name)
	_check(not visual_start.is_empty(), phase_id + ": initial interpolation tracks are populated")
	var intervals: Array[float] = []
	var samples: Array = []
	var started := Time.get_ticks_usec()
	var previous := started
	_status(phase_id, true)
	while float(Time.get_ticks_usec() - started) / 1000000.0 < PHASE_SECONDS:
		await tree.process_frame
		var now := Time.get_ticks_usec()
		var frame_ms := float(now - previous) / 1000.0
		intervals.append(frame_ms)
		samples.append([float(now - started) / 1000000.0, frame_ms])
		previous = now
	var wall := float(Time.get_ticks_usec() - started) / 1000000.0
	var logic_delta := float(app.model.state.elapsed) - logic_start
	var animation_delta := float(app.view._animation_seconds) - animation_start
	var model_moved := _changed_position_count(model_start, _model_positions(scene_name))
	var visual_moved := _changed_position_count(visual_start, _visual_positions(scene_name))
	var frame_stats := _frame_stats(intervals)
	_check(logic_delta > 0.0 and animation_delta > 0.0, phase_id + ": simulation and animation clocks both advance")
	_check(model_moved > 0 and visual_moved > 0, phase_id + ": actual actor model and interpolated visual positions both move")
	app.set_process(false)
	app.host.set_clock_paused(true)
	var dirty_refresh_ms: Array[float] = []
	var crop_quotes_ms: Array[float] = []
	var before_probes: Dictionary = app.model.snapshot()
	if shop_open:
		_status(phase_id + "_explicit_probes", false)
		for index in range(PROBE_COUNT):
			app._shop_revision = "__shop_performance_dirty_%d" % index
			var probe_start := Time.get_ticks_usec()
			app._refresh_open_shop()
			dirty_refresh_ms.append(float(Time.get_ticks_usec() - probe_start) / 1000.0)
			await tree.process_frame
		for unused in range(PROBE_COUNT):
			app._prepare_preview()
			var quote_start := Time.get_ticks_usec()
			app._refresh_crop_quotes()
			crop_quotes_ms.append(float(Time.get_ticks_usec() - quote_start) / 1000.0)
			await tree.process_frame
	_check(app.model.snapshot() == before_probes, phase_id + ": quote probes never mutate the live model")
	var row := {"phase": phase_id, "scene": scene_name, "shop_open": shop_open, "crop_cards": app._crop_quote_controls.size() if shop_open else 0,
		"wall_seconds": wall, "logic_seconds": logic_delta, "logic_drift_seconds": logic_delta - wall, "animation_seconds": animation_delta,
		"model_actors_moved": model_moved, "visual_actors_moved": visual_moved,
		"frames": frame_stats, "frame_samples_seconds_ms": samples, "open_panel_ms": open_panel_ms,
		"dirty_refresh_ms": dirty_refresh_ms, "crop_quotes_ms": crop_quotes_ms,
		"windows_start": windows_start, "windows_end": _windows()}
	phases.append(row)
	_status(phase_id, false)
	print("SHOP_PERFORMANCE_PHASE ", JSON.stringify({"phase": phase_id, "frames": frame_stats, "open_ms": open_panel_ms, "dirty_ms": dirty_refresh_ms, "quotes_ms": crop_quotes_ms, "model_moved": model_moved, "visual_moved": visual_moved}))

func _model_positions(scene_name: String) -> Dictionary:
	var result := {}
	var actors: Array = app.model.state.animals if scene_name == "ranch" else app.model.state.fish
	for actor in actors: result[str(actor.id)] = [float(actor.x), float(actor.y)]
	return result

func _visual_positions(scene_name: String) -> Dictionary:
	var result := {}
	var tracks: Dictionary = app.view._animal_tracks if scene_name == "ranch" else app.view._fish_tracks
	for id in tracks:
		var point: Vector2 = app.view._actor_position(tracks[id]) if scene_name == "ranch" else app.view._fish_position(tracks[id])
		result[str(id)] = [point.x, point.y]
	return result

func _changed_position_count(before: Dictionary, after: Dictionary) -> int:
	var result := 0
	for id in before:
		if after.has(id) and Vector2(float(before[id][0]), float(before[id][1])).distance_squared_to(Vector2(float(after[id][0]), float(after[id][1]))) > 0.0001: result += 1
	return result

func _frame_stats(intervals: Array[float]) -> Dictionary:
	var sorted := intervals.duplicate()
	sorted.sort()
	var total := 0.0
	var over100 := 0
	var over200 := 0
	for value in intervals:
		total += value
		if value > 100.0: over100 += 1
		if value > 200.0: over200 += 1
	return {"count": sorted.size(), "mean_ms": total / maxf(1.0, sorted.size()), "p50_ms": sorted[maxi(0, ceili(sorted.size() * 0.5) - 1)] if not sorted.is_empty() else 0.0,
		"p95_ms": sorted[maxi(0, ceili(sorted.size() * 0.95) - 1)] if not sorted.is_empty() else 0.0,
		"max_ms": sorted[-1] if not sorted.is_empty() else 0.0, "over100": over100, "over200": over200}

func _compare_baseline() -> Array:
	var result: Array = []
	if baseline_path.is_empty(): return result
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(baseline_path))
	if not data is Dictionary or not data.get("phases") is Array:
		_check(false, "Baseline result is valid shop-performance JSON")
		return result
	_check(float(data.get("phase_seconds", -1.0)) == PHASE_SECONDS and int(data.get("fps_cap", -1)) == 30 and data.get("population", {}).get("crop_definitions", 0) == 53, "Baseline uses the same duration, FPS and full crop count")
	for row in phases:
		var matches: Array = data.phases.filter(func(old): return str(old.phase) == str(row.phase))
		_check(matches.size() == 1, str(row.phase) + ": baseline phase is present exactly once")
		if matches.size() != 1: continue
		var old: Dictionary = matches[0]
		var comparison := {"phase": row.phase, "p95_ratio": float(row.frames.p95_ms) / maxf(0.001, float(old.frames.p95_ms)), "max_ratio": float(row.frames.max_ms) / maxf(0.001, float(old.frames.max_ms)), "over100_before": old.frames.over100, "over100_after": row.frames.over100,
			"open_ratio": float(row.open_panel_ms) / maxf(0.001, float(old.open_panel_ms)), "dirty_refresh_ratio": _average(row.dirty_refresh_ms) / maxf(0.001, _average(old.dirty_refresh_ms)), "quote_ratio": _average(row.crop_quotes_ms) / maxf(0.001, _average(old.crop_quotes_ms))}
		result.append(comparison)
		if verify and bool(row.shop_open):
			if limits.has("max-open-ratio"): _check(float(comparison.open_ratio) <= float(limits["max-open-ratio"]), str(row.phase) + ": opening ratio meets supplied relative limit")
			if limits.has("max-refresh-ratio"): _check(float(comparison.dirty_refresh_ratio) <= float(limits["max-refresh-ratio"]), str(row.phase) + ": refresh ratio meets supplied relative limit")
	return result

func _average(values: Array) -> float:
	var total := 0.0
	for value in values: total += float(value)
	return total / maxf(1.0, values.size())

func _verify_metrics() -> void:
	_check(not limits.is_empty(), "Verification has explicitly supplied metrics limits; baseline does not assume a performance threshold")
	if limits.has("max-open-ratio") or limits.has("max-refresh-ratio"): _check(not baseline_path.is_empty(), "Relative verification has an explicit baseline")
	for row in phases:
		if not bool(row.shop_open): continue
		if limits.has("max-open-ms"): _check(float(row.open_panel_ms) <= float(limits["max-open-ms"]), str(row.phase) + ": initial opening meets supplied time limit")
		if limits.has("max-refresh-ms"):
			for value in row.dirty_refresh_ms: _check(float(value) <= float(limits["max-refresh-ms"]), str(row.phase) + ": forced dirty refresh meets supplied time limit")
		if limits.has("max-quote-ms"):
			for value in row.crop_quotes_ms: _check(float(value) <= float(limits["max-quote-ms"]), str(row.phase) + ": quote refresh meets supplied time limit")
		if limits.has("max-p95-ms"): _check(float(row.frames.p95_ms) <= float(limits["max-p95-ms"]), str(row.phase) + ": natural frame p95 meets supplied time limit")
		if limits.has("max-over100"): _check(int(row.frames.over100) <= int(limits["max-over100"]), str(row.phase) + ": natural long-frame count meets supplied limit")
