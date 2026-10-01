extends SceneTree

const HOST = preload("res://scripts/desktop_host.gd")
var host: DesktopHost
var toolbar: Window
var stage := 0
var frames := 0
var hidden_elapsed := 0
var test_failed := false

func _initialize() -> void:
	Engine.max_fps = 30
	call_deferred("_start_test")

func _start_test() -> void:
	root.gui_embed_subwindows = false
	toolbar = Window.new()
	toolbar.title = "Collapse validation toolbar"
	toolbar.size = Vector2i(400, 32)
	root.add_child(toolbar)
	toolbar.show()
	host = HOST.new()
	root.add_child(host)
	host.status_changed.connect(func(message: String): print(message))
	assert(host.start(root, toolbar, {}))
	print("WINDOW_IDS root=", root.get_window_id(), " toolbar=", toolbar.get_window_id(), " logical_visible=", toolbar.visible)
	print("BEFORE_COLLAPSE toolbar_native_visible=", host.native.call("window_is_visible", DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, toolbar.get_window_id())))
	assert(bool(host.native.call("is_visible")))
	host.consume_elapsed_msec()
	host.set_collapsed(true)
	assert(not bool(host.native.call("is_visible")), "Main HWND must be hidden")
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
		assert(not bool(host.native.call("is_visible")))
		assert_toolbar_visible()
		if frames >= 30:
			assert(hidden_elapsed >= 800, "Awake clock must advance while scenery is collapsed")
			host.set_collapsed(false)
			assert(bool(host.native.call("is_visible")), "Expanded HWND must be visible")
			assert_toolbar_visible()
			stage = 2
			frames = 0
	elif frames >= 15:
		print("COLLAPSE_GUI_", "FAIL" if test_failed else "PASS", ": hidden HWND false, expanded true, toolbar visible, hidden clock advanced ", hidden_elapsed, " ms")
		host.shutdown()
		quit(1 if test_failed else 0)
	return false
