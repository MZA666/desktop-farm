extends SceneTree

const HOST = preload("res://scripts/desktop_host.gd")
const WINDOWS = preload("res://native/tests/window_fixture.gd")
var host: DesktopHost
var toolbar: Window
var scenery: Window
var stage := 0
var frames := 0
var hidden_elapsed := 0
var test_failed := false

func _initialize() -> void:
	Engine.max_fps = 30
	call_deferred("_start_test")

func _start_test() -> void:
	root.gui_embed_subwindows = false
	toolbar = root
	scenery = WINDOWS.scene_for(root)
	toolbar.title = "Collapse validation toolbar"
	toolbar.size = Vector2i(400, 32)
	toolbar.show()
	host = HOST.new()
	root.add_child(host)
	host.status_changed.connect(func(message: String): print(message))
	verify(host.start(scenery, toolbar, {}))
	print("WINDOW_IDS root=", root.get_window_id(), " toolbar=", toolbar.get_window_id(), " logical_visible=", toolbar.visible)
	print("BEFORE_COLLAPSE toolbar_native_visible=", host.native.call("window_is_visible", DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, toolbar.get_window_id())))
	verify(bool(host.native.call("is_visible")))
	host.consume_elapsed_msec()
	host.set_collapsed(true)
	verify(not bool(host.native.call("is_visible")), "Main HWND must be hidden")
	assert_toolbar_visible()
	stage = 1

func assert_toolbar_visible() -> void:
	var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, toolbar.get_window_id())
	if not bool(host.native.call("window_is_visible", handle)):
		push_error("Independent toolbar must remain visible")
		test_failed = true

func _process(_delta: float) -> bool:
	if stage == 0:
		return false
	frames += 1
	if stage == 1:
		hidden_elapsed += host.consume_elapsed_msec()
		verify(not bool(host.native.call("is_visible")))
		assert_toolbar_visible()
		if frames >= 30:
			verify(hidden_elapsed >= 800, "Awake clock must advance while scenery is collapsed")
			host.set_collapsed(false)
			verify(bool(host.native.call("is_visible")), "Expanded HWND must be visible")
			assert_toolbar_visible()
			stage = 2
			frames = 0
	elif frames >= 15:
		print("COLLAPSE_GUI_", "FAIL" if test_failed else "PASS", ": hidden HWND false, expanded true, toolbar visible, hidden clock advanced ", hidden_elapsed, " ms")
		host.shutdown()
		quit(1 if test_failed else 0)
	return false

func verify(condition: bool, message: String = "Native acceptance check failed") -> bool:
	if not condition:
		test_failed = true
		push_error(message)
		quit(1)
	return condition
