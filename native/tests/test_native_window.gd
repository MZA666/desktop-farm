extends SceneTree

var native: RefCounted
var suspend_callbacks := 0
var countdown := 90
var was_suspended := false

func _initialize() -> void:
	Engine.max_fps = 30
	call_deferred("_test_start")

func _test_start() -> void:
	if not ClassDB.class_exists("DesktopNative"):
		GDExtensionManager.load_extension("res://native/desktop_native.gdextension")
	native = ClassDB.instantiate("DesktopNative") as RefCounted
	assert(native != null)
	root.size = Vector2i(400, 120)
	root.title = "Native desktop validation"
	root.borderless = true
	root.transparent = true
	root.transparent_bg = true
	root.position = Vector2i(80, 80)
	root.show()
	var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, root.get_window_id())
	assert(bool(native.call("attach", handle)))
	assert((int(native.call("native_status")) & 127) == 127)
	assert(bool(native.call("set_interactive", true)))
	assert((int(native.call("native_status")) & 4) == 0)
	assert(bool(native.call("set_interactive", false)))
	assert((int(native.call("native_status")) & 4) != 0)
	native.call("set_suspend_callback", Callable(self, "_on_suspend"))
	assert(OS.create_process(ProjectSettings.globalize_path("res://native/bin/power_probe.exe"), [str(handle)]) != -1)

func _on_suspend() -> void:
	suspend_callbacks += 1
	assert(bool(native.call("is_suspended")), "Suspend state must be set before save callback")
	var snapshot := FileAccess.open("res://.review/native-suspend-snapshot.json", FileAccess.WRITE)
	snapshot.store_string(JSON.stringify({"saved_during_suspend_callback": true,
		"suspend_count": int(native.call("suspend_epoch"))}))
	snapshot.flush()

func _process(_delta: float) -> bool:
	if native == null:
		return false
	was_suspended = was_suspended or bool(native.call("is_suspended"))
	countdown -= 1
	if countdown == 0:
		print("POWER_TEST_STATE callbacks=", suspend_callbacks, " was_suspended=", was_suspended,
			" epochs=", native.call("power_epoch"), "/", native.call("suspend_epoch"))
		assert(suspend_callbacks == 1)
		assert(was_suspended)
		assert(not bool(native.call("is_suspended")))
		assert(int(native.call("power_epoch")) == 2)
		assert(int(native.call("suspend_epoch")) == 1)
		native.call("release")
		native = null
		print("NATIVE_WINDOW_PASS: HWND attach, Windows style toggle, synchronous suspend callback, resume event")
		print("Actual system sleep remains a manual acceptance test.")
		quit(0)
	return false
