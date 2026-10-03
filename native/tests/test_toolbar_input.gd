extends SceneTree
## Exercises real HWND routing from a second process into actual product buttons.
const MAIN = preload("res://scenes/main.tscn")
var controller: Node
var probe_pid := -1
var prefix := ""
var failed := false
var click_count := 0
var window_events := 0
var button_events := 0
var evidence: Array = []

func _initialize() -> void:
	if DisplayServer.get_name() == "headless" or not OS.get_cmdline_user_args().has("--benchmark-fixture"):
		printerr("Real toolbar input needs an unlocked Windows desktop and --benchmark-fixture")
		quit(2)
		return
	call_deferred("_start")

func require(condition: bool, message: String) -> bool:
	if condition: return true
	failed = true
	printerr("FAIL: " + message)
	return false

func _start() -> void:
	prefix = ProjectSettings.globalize_path("res://.review/toolbar-input-%d" % OS.get_process_id())
	controller = MAIN.instantiate()
	root.add_child(controller)
	for unused in range(12): await process_frame
	if not require(controller.get("host") != null and controller.host.ready_for_desktop, "Product host starts"): _finish(); return
	controller.toolbar.window_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT: window_events += 1)
	for button in controller.toolbar_row.get_children():
		if button is Button: button.pressed.connect(func(): button_events += 1)
	var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, root.get_window_id())
	probe_pid = OS.create_process(ProjectSettings.globalize_path("res://native/bin/toolbar_input_probe.exe"), [prefix, str(handle)])
	if not require(probe_pid > 0, "Mouse helper launches"): _finish(); return
	var started := Time.get_ticks_msec()
	while not FileAccess.file_exists(prefix + ".ready") and OS.is_process_running(probe_pid) and Time.get_ticks_msec() - started < 5000:
		await process_frame
	if not require(FileAccess.file_exists(prefix + ".ready"), "Unlocked desktop helper ready"): _finish(); return
	for round_index in range(100):
		var mode := round_index / 20
		controller.model.command("settings", {"values": {"interactive": mode % 2 == 0, "collapsed": mode == 3, "display_mode": "compact" if mode == 2 else "expanded"}})
		controller._apply_settings()
		if mode == 4:
			# Exercise real seed-shop ownership repeatedly; the lighter settings
			# panel covers remaining open/close rounds without rebuilding 64 cards.
			controller._open_panel("crops" if round_index % 5 == 0 else "settings")
			await process_frame
			controller._close_panel()
		if not _check_windows(handle): break
		# Keep the isolated fixture away from the player's existing bottom-strip
		# release. This is a test-only placement; production geometry above was
		# checked before it. Scene and toolbar stay physically disjoint. Hidden
		# scenery in collapsed mode is moved with the same test strip.
		var work: Rect2i = controller.host.get_work_area()
		controller.toolbar.position = work.position + Vector2i(0, 150)
		controller.scene_window.position = controller.toolbar.position + Vector2i(0, controller.toolbar.size.y)
		var expected: String = ["farm", "ranch", "pond"][round_index % 3]
		# Deliberately begin in a different scene so a missing click cannot pass.
		controller._set_scene(["pond", "farm", "ranch"][round_index % 3])
		for unused in range(2): await process_frame
		var button: Button = controller.toolbar_row.get_child(1 + round_index % 3)
		var center: Vector2 = button.get_global_rect().get_center()
		var scale := Vector2(controller.toolbar.size) / Vector2(controller.toolbar.content_scale_size)
		var screen: Vector2i = controller.toolbar.position + Vector2i((center * scale).round())
		var before := button_events
		var file := FileAccess.open(prefix + ".step", FileAccess.WRITE)
		file.store_string("%d %d %d" % [round_index, screen.x, screen.y])
		file.close()
		var ack := ""
		var deadline := Time.get_ticks_msec() + 2500
		while Time.get_ticks_msec() < deadline and OS.is_process_running(probe_pid):
			await process_frame
			if FileAccess.file_exists(prefix + ".ack"):
				var candidate := FileAccess.get_file_as_string(prefix + ".ack").strip_edges()
				if candidate.split(" ").size() == 4 and int(candidate.get_slice(" ", 0)) == round_index: ack = candidate; break
		if not require(not ack.is_empty() and int(ack.get_slice(" ", 1)) == 1, "Cross-process real click reaches toolbar round %d" % round_index): break
		if not require(controller.current_scene == expected and button_events == before + 1, "First click executes exactly one scene change round %d" % round_index): break
		click_count += 1
		evidence.append({"round": round_index, "mode": mode, "scene": expected, "ack": ack, "button_events": button_events, "window_events": window_events})
	_finish()

func _check_windows(main_handle: int) -> bool:
	var host = controller.host
	var native = host.native
	var scene_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, controller.scene_window.get_window_id())
	var main_style := int(native.call("window_extended_style", main_handle))
	var scene_style := int(native.call("window_extended_style", scene_handle))
	if not require((main_style & 0x40000) != 0 and (main_style & (0x80 | 0x8000000 | 0x20)) == 0, "Main toolbar is sole activatable taskbar app"): return false
	if not require((scene_style & 0x40000) == 0 and (scene_style & (0x80 | 0x8000000)) == (0x80 | 0x8000000), "Scenery is nonactivating owned tool"): return false
	if not require(int(native.call("window_owner_handle", scene_handle)) == main_handle, "Scenery owner matches root"): return false
	if not require(bool(native.call("window_is_enabled", main_handle)), "Toolbar remains enabled"): return false
	if not require(controller.scene_window.position.y >= controller.toolbar.position.y + controller.toolbar.size.y, "Scene never overlaps toolbar"): return false
	if controller.popup.get_window_id() >= 0:
		var panel_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, controller.popup.get_window_id())
		if not require((int(native.call("window_extended_style", panel_handle)) & 0x40000) == 0, "Panel has no second app entry"): return false
	return true

func _finish() -> void:
	var done := FileAccess.open(prefix + ".done", FileAccess.WRITE)
	if done != null: done.store_string("1"); done.close()
	var wait_started := Time.get_ticks_msec()
	while probe_pid > 0 and OS.is_process_running(probe_pid) and Time.get_ticks_msec() - wait_started < 3000: await process_frame
	if probe_pid > 0 and OS.is_process_running(probe_pid): OS.kill(probe_pid)
	var output := FileAccess.open(prefix + ".json", FileAccess.WRITE)
	if output != null:
		output.store_string(JSON.stringify({"passed": not failed and click_count == 100, "rounds": click_count, "samples": evidence}))
		output.close()
	print("PRODUCT_TOOLBAR_INPUT_", "PASS" if not failed and click_count == 100 else "FAIL", " real_rounds=", click_count)
	if is_instance_valid(controller) and controller.get("host") != null: controller.host.shutdown()
	quit(0 if not failed and click_count == 100 else 1)
