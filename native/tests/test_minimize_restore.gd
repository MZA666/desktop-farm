extends SceneTree
## Native minimize/restore commands against root and owned product windows.
const HOST = preload("res://scripts/desktop_host.gd")
const WINDOWS = preload("res://native/tests/window_fixture.gd")
const MAIN = preload("res://scenes/main.tscn")
var host: DesktopHost
var controller: Node
var scenery: Window
var popup: Window
var failed := false
var checks := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless" or not OS.get_cmdline_user_args().has("--benchmark-fixture"):
		printerr("Minimize regression requires Windows GUI and --benchmark-fixture")
		quit(2)
		return
	Engine.max_fps = 30
	call_deferred("_start")

func require(condition: bool, message: String) -> bool:
	checks += 1
	if condition: return true
	failed = true
	printerr("FAIL: " + message)
	return false

func visible(window: Window) -> bool:
	if window.get_window_id() < 0: return false
	var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window.get_window_id())
	return bool(host.native.call("window_is_visible", handle))

func _start() -> void:
	if OS.get_cmdline_user_args().has("--actual-main-fixture"):
		controller = MAIN.instantiate()
		root.add_child(controller)
		for frame in range(12): await process_frame
		host = controller.host
		if not require(host != null and host.ready_for_desktop, "Actual main root-toolbar host starts"): _finish(); return
		scenery = controller.scene_window
		popup = controller.popup
		controller._open_panel("settings")
	else:
		scenery = WINDOWS.scene_for(root)
		host = HOST.new()
		root.add_child(host)
		if not require(host.start(scenery, root), "Isolated root-toolbar host starts"): _finish(); return
		popup = Window.new()
		popup.visible = false
		popup.transient = true
		popup.exclusive = false
		popup.size = Vector2i(280, 160)
		popup.position = Vector2i(640, 200)
		root.add_child(popup)
		popup.show()
		host.prepare_auxiliary_window(popup)
		host.register_auxiliary_window(popup)
	for collapsed_mode in [false, true]:
		if controller != null:
			controller.model.command("settings", {"values": {"collapsed": collapsed_mode}})
			controller._apply_settings()
		else: host.set_collapsed(collapsed_mode)
		host.consume_elapsed_msec()
		root.mode = Window.MODE_MINIMIZED
		for frame in range(40):
			await process_frame
			host.refresh_desktop_visibility()
			if not require(root.mode == Window.MODE_MINIMIZED, "Polling never restores minimized owner"): _finish(); return
			if not require(visible(root), "Minimized owner retains its native taskbar entry"): _finish(); return
			if not require(not visible(scenery) and not visible(popup), "Polling never re-shows minimized owner's scene/panel"): _finish(); return
			if not require(not host.is_desktop_visible() and not bool(host._window_viewport_active.get(root.get_instance_id(), true)), "Minimized content and root rendering remain suspended"): _finish(); return
		if not require(host.consume_elapsed_msec() > 0, "Awake production clock progresses while minimized"): _finish(); return
		root.mode = Window.MODE_WINDOWED
		for frame in range(3): await process_frame
		host.refresh_desktop_visibility()
		if not require(visible(root) and visible(popup) and visible(scenery) == not collapsed_mode, "Restoration preserves open panel and collapse setting"): _finish(); return
	if controller != null: controller._close_panel()
	else: popup.hide()
	root.mode = Window.MODE_MINIMIZED
	for frame in range(10): await process_frame; host.refresh_desktop_visibility()
	root.mode = Window.MODE_WINDOWED
	for frame in range(3): await process_frame
	host.refresh_desktop_visibility()
	require(not visible(popup), "Closed panel stays closed after minimize/restore")
	_finish()

func _finish() -> void:
	root.mode = Window.MODE_WINDOWED
	if host != null: host.shutdown()
	print("MINIMIZE_RESTORE_", "FAIL" if failed else "PASS", " checks=", checks, " actual_main=", controller != null)
	quit(1 if failed else 0)
