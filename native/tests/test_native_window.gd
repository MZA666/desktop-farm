extends SceneTree

var test_failed := false

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
	verify(native != null)
	root.size = Vector2i(400, 120)
	root.title = "Native desktop validation"
	root.borderless = true
	root.transparent = true
	root.transparent_bg = true
	root.position = Vector2i(80, 80)
	root.show()
	var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, root.get_window_id())
	verify(bool(native.call("attach", handle)))
	verify((int(native.call("native_status")) & 127) == 127)
	verify(bool(native.call("set_interactive", true)))
	verify((int(native.call("native_status")) & 4) == 0)
	verify(bool(native.call("set_interactive", false)))
	verify((int(native.call("native_status")) & 4) != 0)
	native.call("set_suspend_callback", Callable(self, "_on_suspend"))
	verify(OS.create_process(ProjectSettings.globalize_path("res://native/bin/power_probe.exe"), [str(handle)]) != -1)

func _on_suspend() -> void:
	suspend_callbacks += 1
	verify(bool(native.call("is_suspended")), "Suspend state must be set before save callback")
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
		verify(suspend_callbacks == 1)
		verify(was_suspended)
		verify(not bool(native.call("is_suspended")))
		verify(int(native.call("power_epoch")) == 2)
		verify(int(native.call("suspend_epoch")) == 1)
		native.call("release")
		native = null
		print("NATIVE_WINDOW_PASS: HWND attach, Windows style toggle, synchronous suspend callback, resume event")
		print("Actual system sleep remains a manual acceptance test.")
		quit(1 if test_failed else 0)
	return false

func verify(condition: bool, message: String = "Native acceptance check failed") -> bool:
	if not condition:
		test_failed = true
		push_error(message)
		quit(1)
	return condition
