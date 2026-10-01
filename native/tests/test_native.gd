extends SceneTree

func _initialize() -> void:
	if not ClassDB.class_exists("DesktopNative"):
		GDExtensionManager.load_extension("res://native/desktop_native.gdextension")
	assert(ClassDB.class_exists("DesktopNative"), "Native class must be loaded")
	var first := ClassDB.instantiate("DesktopNative") as RefCounted
	var second := ClassDB.instantiate("DesktopNative") as RefCounted
	assert(first != null and second != null)
	assert(bool(first.call("try_single_instance")), "First process lock must succeed")
	assert(not bool(second.call("try_single_instance")), "Second instance must be rejected")
	var area: Rect2i = first.call("get_work_area")
	assert(area.size.x > 0 and area.size.y > 0, "Windows monitor work area must be valid")
	assert((int(first.call("native_status")) & 32) != 0, "Unbiased awake clock must be available")
	var before := int(first.call("elapsed_awake_msec"))
	for index in range(10000):
		assert(int(first.call("elapsed_awake_msec")) >= before)
	assert(not bool(first.call("attach", 0)), "Invalid HWND must be rejected")
	assert(not bool(first.call("set_interactive", true)), "Detached input update must fail safely")
	assert(not bool(first.call("is_suspended")))
	assert(is_equal_approx(float(first.call("get_dpi_scale")), 1.0))
	first.call("release")
	assert(bool(second.call("try_single_instance")), "Closing first lock must release singleton")
	second.call("release")
	print("NATIVE_API_PASS: instances, singleton, work area, awake clock, invalid handle, release")
	quit(0)
