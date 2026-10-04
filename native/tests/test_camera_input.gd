extends SceneTree
## Real native clicks/wheel into the actual main scene, never pressed.emit().
const MAIN = preload("res://scenes/main.tscn")
const WORLD = preload("res://scripts/world_layout.gd")
var controller: Node
var probe_pid := -1
var prefix := ""
var failed := false
var checks := 0
var steps := 0
var button_events := 0
var wheel_events := 0
var fixture_width := 1920
var evidence: Array = []

func _initialize() -> void:
	if DisplayServer.get_name() == "headless" or not OS.get_cmdline_user_args().has("--benchmark-fixture"):
		printerr("Camera real-input self-test requires Windows GUI and --benchmark-fixture")
		quit(2)
		return
	call_deferred("_start")

func require(condition: bool, message: String) -> bool:
	checks += 1
	if condition: return true
	failed = true
	printerr("FAIL: " + message)
	return false

func _start() -> void:
	prefix = ProjectSettings.globalize_path("res://.review/camera-input-%d" % OS.get_process_id())
	controller = MAIN.instantiate()
	root.add_child(controller)
	for frame in range(12): await process_frame
	if not require(controller.get("host") != null and controller.host.ready_for_desktop, "Actual main host starts"): _finish(); return
	# Freeze only this fixture's simulation so camera operations can be checked
	# against an unchanged complete economic/world snapshot.
	controller.host.set_clock_paused(true)
	controller.model.command("settings", {"values": {"interactive": true, "collapsed": false, "display_mode": "expanded"}})
	controller._apply_settings()
	fixture_width = mini(1920, roundi(controller.host.get_work_area().size.x / controller.host.dpi_scale))
	for control in controller.toolbar_row.get_children():
		if control is Button: control.pressed.connect(func(): button_events += 1)
	controller.scene_window.window_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]: wheel_events += 1)
	var toolbar_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, controller.toolbar.get_window_id())
	var scene_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, controller.scene_window.get_window_id())
	probe_pid = OS.create_process(ProjectSettings.globalize_path("res://native/bin/camera_input_probe.exe"), [prefix, str(toolbar_handle), str(scene_handle)])
	if not require(probe_pid > 0, "Native guarded helper launches"): _finish(); return
	var deadline := Time.get_ticks_msec() + 5000
	while not FileAccess.file_exists(prefix + ".ready") and OS.is_process_running(probe_pid) and Time.get_ticks_msec() < deadline: await process_frame
	if not require(FileAccess.file_exists(prefix + ".ready"), "Unlocked desktop helper ready"): _finish(); return
	if not (await _cases()): failed = true
	_finish()

func _cases() -> bool:
	if not require(is_equal_approx(float(controller.view.view_height), 352.0) and is_equal_approx(float(controller.view.camera_y), 80.0), "First expanded view is world-centered at y80"): return false
	if not (await _button("CameraUp", 48.0, "expanded_up32")): return false
	if not (await _button("CameraDown", 80.0, "expanded_down32")): return false
	if not (await _button("CameraCenter", 80.0, "expanded_center")): return false
	if not (await _wheel(1, 64.0, "expanded_wheel_up16")): return false
	if not (await _wheel(-1, 80.0, "expanded_wheel_down16")): return false
	if not (await _edges(160.0, "expanded")): return false
	if not (await _button("CameraCenter", 80.0, "expanded_reset")): return false
	if not (await _button("DisplayMode", 170.0, "actual_compact_button", true)): return false
	if not require(is_equal_approx(float(controller.view.view_height), 172.0), "Actual mode button selects compact height172"): return false
	if not (await _button("CameraUp", 138.0, "compact_up32")): return false
	if not (await _button("CameraDown", 170.0, "compact_down32")): return false
	if not (await _button("CameraCenter", 170.0, "compact_center")): return false
	if not (await _wheel(1, 154.0, "compact_wheel_up16")): return false
	if not (await _wheel(-1, 170.0, "compact_wheel_down16")): return false
	if not (await _edges(340.0, "compact")): return false
	# Desired world centers must survive clamping by a taller viewport. The
	# current compact bottom center426 becomes expanded y160, then must return
	# to compact y340 rather than replacing its remembered center with336.
	if not (await _button("DisplayMode", 160.0, "compact_bottom_to_expanded_clamp", true)): return false
	if not (await _button("DisplayMode", 340.0, "compact_bottom_roundtrip_preserves426", true)): return false
	if not (await _reach_edge(-1, 340.0, "compact_top_roundtrip_setup")): return false
	if not (await _button("CameraDown", 32.0, "compact_top_first_reverse_leaves_edge")): return false
	if not (await _button("CameraUp", 0.0, "compact_top_restore_exact_edge")): return false
	if not (await _button("DisplayMode", 0.0, "compact_top_to_expanded_clamp", true)): return false
	if not (await _button("DisplayMode", 0.0, "compact_top_roundtrip_preserves86", true)): return false
	# Save an extreme in one scene, resize while viewing another, then return.
	if not (await _scene("ranch", 170.0)): return false
	if not (await _reach_edge(1, 340.0, "ranch_compact_bottom_setup")): return false
	if not (await _button("CameraUp", 308.0, "ranch_bottom_first_reverse_leaves_edge")): return false
	if not (await _button("CameraDown", 340.0, "ranch_bottom_restore_exact_edge")): return false
	if not (await _scene("pond", 170.0)): return false
	if not (await _button("DisplayMode", 80.0, "pond_expand_keeps_its_center", true)): return false
	if not (await _scene("ranch", 160.0)): return false
	if not (await _button("DisplayMode", 340.0, "ranch_extreme_survives_cross_scene_height", true)): return false
	if not (await _button("CameraCenter", 170.0, "ranch_reset_after_extreme_memory")): return false
	if not (await _scene("farm", 0.0)): return false
	if not (await _button("CameraCenter", 170.0, "compact_reset")): return false
	if not (await _button("CameraUp", 138.0, "remember_farm_center224")): return false
	if not (await _scene("ranch", 170.0)): return false
	if not (await _button("CameraUp", 138.0, "remember_ranch_center224")): return false
	if not (await _scene("pond", 170.0)): return false
	if not (await _button("CameraDown", 202.0, "remember_pond_center288")): return false
	if not (await _scene("farm", 138.0)): return false
	if not (await _button("DisplayMode", 48.0, "preserve_world_center_on_expand", true)): return false
	if not (await _scene("ranch", 48.0)): return false
	if not (await _scene("pond", 112.0)): return false
	if not (await _scene("farm", 48.0)): return false
	if not (await _button("CameraCenter", 80.0, "farm_default_again")): return false
	fixture_width = 640
	if not (await _button("CameraUp", 48.0, "640_expanded_up_reachable")): return false
	if not (await _button("CameraDown", 80.0, "640_expanded_down_reachable")): return false
	if not (await _button("CameraCenter", 80.0, "640_expanded_center_reachable")): return false
	if not (await _button("DisplayMode", 170.0, "640_actual_compact_button", true)): return false
	if not (await _button("CameraUp", 138.0, "640_compact_up_reachable")): return false
	if not (await _button("CameraDown", 170.0, "640_compact_down_reachable")): return false
	return await _button("CameraCenter", 170.0, "640_compact_center_reachable")

func _place_fixture() -> void:
	# Only our own windows move away from any player's running bottom strip.
	var work: Rect2i = controller.host.get_work_area()
	var dpi: float = controller.host.dpi_scale
	var width := roundi(fixture_width * dpi)
	controller.toolbar.size.x = width
	controller.scene_window.size.x = width
	controller.toolbar.position = work.position + Vector2i(0, 150)
	controller.scene_window.position = controller.toolbar.position + Vector2i(0, controller.toolbar.size.y)
	controller._sync_layout()
	for frame in range(3): await process_frame

func _button(name_value: String, expected: float, label: String, changes_model := false) -> bool:
	var button := controller.toolbar_row.get_node_or_null(name_value) as Button
	if not require(button != null, "Actual camera/mode button exists: " + name_value): return false
	return await _press(button, expected, label, changes_model)

func _scene(scene_value: String, expected: float) -> bool:
	var index := ["farm", "ranch", "pond"].find(scene_value)
	var button := controller.toolbar_row.get_child(index + 1) as Button
	if not (await _press(button, expected, "actual_scene_" + scene_value)): return false
	return require(controller.current_scene == scene_value, "Real scene button switches to " + scene_value)

func _press(button: Button, expected: float, label: String, changes_model := false) -> bool:
	await _place_fixture()
	var bounds := button.get_global_rect()
	if not require(button.is_visible_in_tree() and bounds.position.x >= 0 and bounds.end.x <= float(fixture_width) + 0.5 and bounds.end.y <= 32.5, "Button remains fully reachable: " + label): return false
	var scale := Vector2(controller.toolbar.size) / Vector2(controller.toolbar.content_scale_size)
	var screen: Vector2i = controller.toolbar.position + Vector2i((bounds.get_center() * scale).round())
	var before := button_events
	var snapshot := JSON.stringify(controller.model.snapshot())
	if not (await _native_step(screen, 0, label, expected)): return false
	if not require(button_events == before + 1, "One actual native click causes one button event: " + label): return false
	if not changes_model and not require(JSON.stringify(controller.model.snapshot()) == snapshot, "Camera/scene click never alters economy or world state: " + label): return false
	return true

func _wheel(direction: int, expected: float, label: String) -> bool:
	await _place_fixture()
	var logical: Vector2 = controller.view.position + Vector2(fixture_width * 0.5, float(controller.view.view_height) * 0.5)
	var scale := Vector2(controller.scene_window.size) / Vector2(controller.scene_window.content_scale_size)
	var screen: Vector2i = controller.scene_window.position + Vector2i((logical * scale).round())
	var before := wheel_events
	var snapshot := JSON.stringify(controller.model.snapshot())
	if not (await _native_step(screen, direction, label, expected)): return false
	return require(wheel_events == before + 1 and JSON.stringify(controller.model.snapshot()) == snapshot, "One actual wheel event moves view16 and preserves model: " + label)

func _native_step(point: Vector2i, kind: int, label: String, expected: float) -> bool:
	var file := FileAccess.open(prefix + ".step", FileAccess.WRITE)
	if not require(file != null, "Write native input handshake"): return false
	file.store_string("%d %d %d %d" % [steps, point.x, point.y, kind])
	file.close()
	var ack := ""
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline and OS.is_process_running(probe_pid):
		await process_frame
		if FileAccess.file_exists(prefix + ".ack"):
			var value := FileAccess.get_file_as_string(prefix + ".ack").strip_edges()
			if value.split(" ").size() == 4 and int(value.get_slice(" ", 0)) == steps: ack = value; break
	if not require(not ack.is_empty() and int(ack.get_slice(" ", 1)) == 1, "Guarded actual input reaches only fixture: " + label): return false
	var camera: float = controller.view.camera_y
	if not require(is_equal_approx(camera, expected), "%s y expected%.1f actual%.1f" % [label, expected, camera]): return false
	if not require(camera >= 0.0 and camera + float(controller.view.view_height) <= WORLD.WORLD_HEIGHT, "Camera rectangle stays inside painting: " + label): return false
	evidence.append({"step": steps, "case": label, "kind": kind, "width": fixture_width, "height": controller.view.view_height, "camera_y": camera, "native_ack": ack})
	steps += 1
	return true

func _edges(maximum: float, name_value: String) -> bool:
	for index in range(ceili(maximum / 32.0) + 2):
		var expected := maxf(0.0, float(controller.view.camera_y) - 32.0)
		if not (await _button("CameraUp", expected, "%s_top_%d" % [name_value, index])): return false
	if not (await _capture(name_value + "-top")): return false
	for index in range(ceili(maximum / 32.0) + 2):
		var expected := minf(maximum, float(controller.view.camera_y) + 32.0)
		if not (await _button("CameraDown", expected, "%s_bottom_%d" % [name_value, index])): return false
	return await _capture(name_value + "-bottom")

func _reach_edge(direction: int, maximum: float, label: String) -> bool:
	var button_name := "CameraUp" if direction < 0 else "CameraDown"
	for index in range(ceili(maximum / 32.0) + 2):
		var expected := clampf(float(controller.view.camera_y) + direction * 32.0, 0.0, maximum)
		if not (await _button(button_name, expected, "%s_%d" % [label, index])): return false
	return require(is_equal_approx(float(controller.view.camera_y), 0.0 if direction < 0 else maximum), "Actual arrow reaches remembered edge: " + label)

func _capture(name_value: String) -> bool:
	await RenderingServer.frame_post_draw
	var image: Image = controller._composed_frame()
	image.save_png(prefix + "-" + name_value + ".png")
	var scale_y := float(controller.scene_window.size.y) / float(controller.scene_window.content_scale_size.y)
	var top: int = controller.toolbar.size.y + roundi((float(controller.view.position.y) + 2.0) * scale_y)
	var bottom: int = controller.toolbar.size.y + roundi((float(controller.view.position.y) + float(controller.view.view_height) - 3.0) * scale_y)
	for fraction in [0.1, 0.5, 0.9]:
		var x := clampi(roundi(image.get_width() * fraction), 0, image.get_width() - 1)
		if not require(image.get_pixel(x, top).a > 0.95 and image.get_pixel(x, bottom).a > 0.95, "Actual extreme viewport has no transparent top/bottom gap: " + name_value): return false
	return true

func _finish() -> void:
	var done := FileAccess.open(prefix + ".done", FileAccess.WRITE)
	if done != null: done.store_string("1"); done.close()
	var deadline := Time.get_ticks_msec() + 3000
	while probe_pid > 0 and OS.is_process_running(probe_pid) and Time.get_ticks_msec() < deadline: await process_frame
	if probe_pid > 0 and OS.is_process_running(probe_pid): OS.kill(probe_pid)
	var output := FileAccess.open(prefix + ".json", FileAccess.WRITE)
	if output != null:
		output.store_string(JSON.stringify({"passed": not failed, "checks": checks, "steps": steps, "samples": evidence}))
		output.close()
	if is_instance_valid(controller) and controller.get("host") != null: controller.host.shutdown()
	print("PRODUCT_CAMERA_INPUT_", "FAIL" if failed else "PASS", " real_steps=", steps, " checks=", checks)
	quit(1 if failed else 0)
