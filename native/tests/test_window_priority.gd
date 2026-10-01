extends SceneTree

const HOST = preload("res://scripts/desktop_host.gd")
const REPORT := "res://.review/host-priority-result.txt"
var host: DesktopHost
var toolbar: Window
var popup: Window
var frames := 0
var probe_pid := -1

func _initialize() -> void:
	Engine.max_fps = 30
	call_deferred("_start_test")

func _start_test() -> void:
	root.gui_embed_subwindows = false
	toolbar = Window.new()
	toolbar.title = "Controlled priority toolbar"
	root.add_child(toolbar)
	host = HOST.new()
	root.add_child(host)
	assert(host.start(root, toolbar, {"topmost": true, "interactive": true}))
	assert(not host.topmost, "Legacy topmost saves must use ordinary Windows Z order")
	assert(not root.always_on_top and not toolbar.always_on_top)
	popup = Window.new()
	popup.title = "Controlled priority shop"
	popup.size = Vector2i(320, 160)
	popup.position = Vector2i(600, 200)
	root.add_child(popup)
	popup.show()
	var handles: Array[String] = []
	for window in [root, toolbar, popup]:
		var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window.get_window_id())
		assert(bool(host.native.call("make_independent_window", handle)))
		assert(not bool(host.native.call("window_is_topmost", handle)))
		handles.append(str(handle))
	if FileAccess.file_exists(REPORT):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(REPORT))
	probe_pid = OS.create_process(ProjectSettings.globalize_path("res://native/bin/priority_probe.exe"),
		["--handles", ProjectSettings.globalize_path(REPORT)] + handles)
	assert(probe_pid > 0)

func _process(_delta: float) -> bool:
	if host == null or not host.ready_for_desktop:
		return false
	frames += 1
	# Repeated legacy settings, visible refresh, mode changes, and monitor layout
	# must not promote the desktop windows above the controlled foreground app.
	if frames % 15 == 0:
		host.set_topmost(true)
		host.set_interactive(frames % 30 == 0)
		host.set_collapsed(false)
		var area := host.get_work_area()
		var offset := 8 if frames % 30 == 0 else 0
		host.set_position_clamped(Vector2i(area.position.x, area.end.y - root.size.y - offset))
		host.call("_layout_windows")
	if FileAccess.file_exists(REPORT):
		var passed := FileAccess.get_file_as_string(REPORT).strip_edges() == "1"
		print("HOST_WINDOW_PRIORITY_", "PASS" if passed else "FAIL", ": three real Godot HWNDs behind a clicked app from another process")
		host.shutdown()
		quit(0 if passed else 1)
	elif frames > 240:
		push_error("Priority probe timed out")
		if probe_pid > 0 and OS.is_process_running(probe_pid):
			OS.kill(probe_pid)
		host.shutdown()
		quit(1)
	return false
