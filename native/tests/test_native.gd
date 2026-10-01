extends SceneTree

var test_failed := false

func _initialize() -> void:
	if not OS.get_cmdline_user_args().has("--benchmark-fixture"):
		printerr("Native singleton test requires --benchmark-fixture; player namespace was not touched.")
		quit(2)
		return
	if not ClassDB.class_exists("DesktopNative"):
		GDExtensionManager.load_extension("res://native/desktop_native.gdextension")
	verify(ClassDB.class_exists("DesktopNative"), "Native class must be loaded")
	var first := ClassDB.instantiate("DesktopNative") as RefCounted
	var second := ClassDB.instantiate("DesktopNative") as RefCounted
	verify(first != null and second != null)
	if first == null or second == null:
		return
	verify(bool(first.call("set_test_namespace", true)))
	verify(bool(second.call("set_test_namespace", true)))
	verify(bool(first.call("try_single_instance")), "First process lock must succeed")
	verify(not bool(second.call("try_single_instance")), "Second instance must be rejected")
	var area: Rect2i = first.call("get_work_area")
	verify(area.size.x > 0 and area.size.y > 0, "Windows monitor work area must be valid")
	verify((int(first.call("native_status")) & 32) != 0, "Unbiased awake clock must be available")
	var before := int(first.call("elapsed_awake_msec"))
	for index in range(10000):
		verify(int(first.call("elapsed_awake_msec")) >= before)
	verify(not bool(first.call("attach", 0)), "Invalid HWND must be rejected")
	verify(not bool(first.call("set_interactive", true)), "Detached input update must fail safely")
	verify(not bool(first.call("is_suspended")))
	verify(is_equal_approx(float(first.call("get_dpi_scale")), 1.0))
	first.call("release")
	verify(bool(second.call("try_single_instance")), "Closing first lock must release singleton")
	second.call("release")
	print("NATIVE_API_", "FAIL" if test_failed else "PASS", ": isolated instances, singleton, work area, awake clock, invalid handle, release")
	quit(1 if test_failed else 0)

func verify(condition: bool, message: String = "Native acceptance check failed") -> bool:
	if not condition:
		test_failed = true
		push_error(message)
		quit(1)
	return condition
