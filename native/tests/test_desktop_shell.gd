extends SceneTree

const HOST = preload("res://scripts/desktop_host.gd")
const MENU_REPORT := "res://.review/tray-menu-result.txt"
var host: DesktopHost
var toolbar: Window
var second: RefCounted
var second_window: Window
var events: Array[String] = []
var frames := 0
var failed := false

func _initialize() -> void:
	if not OS.get_cmdline_user_args().has("--benchmark-fixture"):
		printerr("Shell acceptance test requires --benchmark-fixture")
		quit(2)
		return
	call_deferred("_start")

func check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)
		quit(1)

func _start() -> void:
	root.gui_embed_subwindows = false
	toolbar = Window.new()
	root.add_child(toolbar)
	host = HOST.new()
	root.add_child(host)
	check(host.start(root, toolbar), "Fixture desktop host must start independently of the player")
	check(host.test_instance and host.tray_available, "Isolated fixture tray must be present")
	check(not host.hotkey_available, "Host fixture must leave the player's Ctrl+Alt+F alone")
	host.tray_action.connect(func(action: String): events.append(action))
	var shell_handle := int(host.native.call("shell_window_handle"))
	check(shell_handle != 0 and not bool(host.native.call("window_is_visible", shell_handle)), "Message sink must stay invisible")
	check(bool(host.native.call("register_toggle_hotkey")), "Isolated Ctrl+Alt+Shift+F12 test key must register")
	second_window = Window.new()
	second_window.visible = false
	root.add_child(second_window)
	second_window.show()
	second = ClassDB.instantiate("DesktopNative") as RefCounted
	check(bool(second.call("set_test_namespace", true)), "Second test namespace must be selected before attachment")
	var second_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, second_window.get_window_id())
	check(bool(second.call("attach", second_handle)), "Second test HWND must attach")
	second.call("set_visible", false)
	check(not bool(second.call("register_toggle_hotkey")), "Duplicate hotkey registration must fail")
	check(int(second.call("shell_last_error")) == 1409, "Collision must report ERROR_HOTKEY_ALREADY_REGISTERED")
	if FileAccess.file_exists(MENU_REPORT):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(MENU_REPORT))
	check(OS.create_process(ProjectSettings.globalize_path("res://native/bin/shell_probe.exe"), [str(shell_handle), ProjectSettings.globalize_path(MENU_REPORT)]) > 0,
		"Shell message probe must start")

func _process(_delta: float) -> bool:
	if host == null or not host.ready_for_desktop:
		return false
	frames += 1
	if frames > 30 and events.size() == 6:
		check(FileAccess.file_exists(MENU_REPORT) and FileAccess.get_file_as_string(MENU_REPORT).strip_edges() == "1",
			"Actual native tray context menu must enter the menu loop")
		check(events == ["toggle_visibility", "toggle_visibility", "toggle_interactive", "open_seed_shop", "open_animal_shop", "quit"],
			"Native tray/hotkey notifications must map to the documented deferred signals")
		host.set_user_hidden(true)
		check(not bool(host.native.call("is_visible")), "Session-hidden scenery must be hidden")
		var toolbar_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, toolbar.get_window_id())
		check(not bool(host.native.call("window_is_visible", toolbar_handle)), "Session-hidden toolbar must be hidden")
		host.set_user_hidden(false)
		check(bool(host.native.call("is_visible")), "Showing session-hidden scenery must restore it")
		host.shutdown()
		check(not bool(second.call("window_is_visible", int(second.call("shell_window_handle")))), "Second shell remains hidden")
		check(bool(second.call("register_toggle_hotkey")), "Releasing first instance must free only its hotkey registration")
		second.call("release")
		print("DESKTOP_SHELL_", "FAIL" if failed else "PASS", ": tray added, real context menu, invisible sink, real keyboard shortcut, deferred commands, test hotkey collision=1409, cleanup and session hide/show")
		quit(1 if failed else 0)
	elif frames > 180:
		check(false, "Shell messages timed out")
	return false
