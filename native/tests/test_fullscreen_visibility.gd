extends SceneTree

const HOST = preload("res://scripts/desktop_host.gd")
const WINDOWS = preload("res://native/tests/window_fixture.gd")
const PREFIX := "res://.review/fullscreen-host"
var host: DesktopHost
var toolbar: Window
var scenery: Window
var popup: Window
var frames := 0
var phase := 0
var failed := false
var hidden_awake_msec := 0

func _initialize() -> void:
	if not OS.get_cmdline_user_args().has("--benchmark-fixture"):
		printerr("Fullscreen acceptance test requires --benchmark-fixture")
		quit(2)
		return
	Engine.max_fps = 30
	call_deferred("_start")

func check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)
		quit(1)

func _start() -> void:
	root.gui_embed_subwindows = false
	toolbar = root
	scenery = WINDOWS.scene_for(root)
	host = HOST.new()
	root.add_child(host)
	check(host.start(scenery, toolbar), "Fixture host must start")
	popup = Window.new()
	popup.visible = false
	popup.size = Vector2i(320, 160)
	popup.position = Vector2i(600, 250)
	root.add_child(popup)
	popup.show()
	RenderingServer.viewport_set_parent_viewport(popup.get_viewport_rid(), RID())
	var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, popup.get_window_id())
	host.prepare_auxiliary_window(popup)
	host.register_auxiliary_window(popup)
	for suffix in ["phase", "ack", "result"]:
		var path := ProjectSettings.globalize_path(PREFIX + "." + suffix)
		if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	host.consume_elapsed_msec()
	check(OS.create_process(ProjectSettings.globalize_path("res://native/bin/fullscreen_probe.exe"),
		[ProjectSettings.globalize_path(PREFIX)]) > 0, "Fullscreen probe must start")

func visible(window: Window) -> bool:
	if window.get_window_id() < 0:
		return false
	var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window.get_window_id())
	return bool(host.native.call("window_is_visible", handle))

func _process(_delta: float) -> bool:
	if host == null or not host.ready_for_desktop:
		return false
	frames += 1
	var elapsed := host.consume_elapsed_msec()
	if host.fullscreen_suppressed:
		hidden_awake_msec += elapsed
	var phase_path := PREFIX + ".phase"
	if FileAccess.file_exists(phase_path):
		var incoming := int(FileAccess.get_file_as_string(phase_path))
		if incoming > phase:
			phase = incoming
			host.refresh_desktop_visibility()
			check(host.fullscreen_suppressed == (phase % 2 == 0), "Only borderless whole-screen app is fullscreen; ordinary maximized app must not suppress")
			if phase % 2 == 0:
				check(not visible(scenery) and not visible(toolbar) and not visible(popup), "Fullscreen must hide every registered game HWND")
			if phase == 1:
				check(visible(scenery) and visible(toolbar) and visible(popup), "Ordinary maximization keeps farm windows available")
			elif phase == 2:
				host.set_user_hidden(true)
			elif phase == 3:
				check(not visible(scenery) and not visible(toolbar) and not visible(popup), "Manual session hiding wins over automatic fullscreen restoration")
				host.set_user_hidden(false)
				check(visible(scenery) and visible(toolbar) and visible(popup), "Explicit show restores the prior open popup")
			elif phase == 4:
				host.set_collapsed(true)
			elif phase == 5:
				check(not visible(scenery) and visible(toolbar) and visible(popup), "Exiting fullscreen preserves user's collapsed scenery and open popup")
				popup.hide()
			elif phase == 7:
				check(not visible(scenery) and visible(toolbar) and not visible(popup), "A closed popup must stay closed after another fullscreen round")
				host.set_collapsed(false)
				check(visible(scenery) and visible(toolbar) and not visible(popup), "Expansion restores only intended windows")
			var file := FileAccess.open(PREFIX + ".ack", FileAccess.WRITE)
			file.store_string(str(phase))
			file.close()
	if FileAccess.file_exists(PREFIX + ".result"):
		check(int(FileAccess.get_file_as_string(PREFIX + ".result")) == 1, "External app must retain foreground through all restores")
		check(phase == 7, "All seven fullscreen/normal transition stages must complete")
		check(hidden_awake_msec > 0, "Awake production clock must continue while fullscreen-suppressed")
		# Recreating a previously closed native popup must refresh viewport state
		# rather than reusing the suppression cache from its former HWND.
		popup.show()
		RenderingServer.viewport_set_parent_viewport(popup.get_viewport_rid(), RID())
		host.refresh_desktop_visibility()
		check(visible(popup), "Closed/reopened popup must become visible again")
		print("FULLSCREEN_VISIBILITY_", "FAIL" if failed else "PASS", ": seven real cross-process transitions, normal maximized exclusion, three-window hide, session/collapse/popup restore, no focus steal, hidden clock=", hidden_awake_msec, "ms")
		host.shutdown()
		quit(1 if failed else 0)
	elif frames > 900:
		check(false, "Fullscreen test timed out")
	return false
