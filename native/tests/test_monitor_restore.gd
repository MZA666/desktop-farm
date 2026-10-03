extends SceneTree

var test_failed := false

const HOST = preload("res://scripts/desktop_host.gd")

func _initialize() -> void:
	var screens: Array[Rect2i] = [Rect2i(0, 0, 1920, 1040), Rect2i(-1920, 0, 1920, 1040),
		Rect2i(1920, -900, 1600, 900)]
	verify(HOST.visible_area_for_point(Vector2i(-1900, 500), screens) == screens[1])
	verify(HOST.visible_area_for_point(Vector2i(2000, -800), screens) == screens[2])
	verify(HOST.visible_area_for_point(Vector2i(40, 700), screens) == screens[0])
	verify(HOST.visible_area_for_point(Vector2i(-6000, 0), screens) == Rect2i())
	verify(HOST.visible_area_for_point(Vector2i(-1920, 0), screens) == screens[1])
	for scale in [1.0, 1.5, 2.0]:
		var size := HOST.scenery_size_for_area(screens[1], scale, "compact")
		verify(size == Vector2i(1920, int(240 * scale)), "100/150/200 percent DPI must produce correct physical scenery height")
		var point := HOST.clamped_position(Vector2i(-9999, 9999), size, screens[1])
		verify(point.x == -1920 and point.y == 1040 - size.y, "DPI scaling must clamp inside negative-coordinate monitor work area")
		verify(screens[1].encloses(Rect2i(point, size)), "Scaled strip must stay completely inside the usable monitor")
	var short_area := Rect2i(-800, -200, 800, 180)
	verify(HOST.scenery_size_for_area(short_area, 2.0) == Vector2i(800, 180), "Very short work areas must limit scaled window height")
	verify(HOST.clamped_position(Vector2i(0, 0), Vector2i(800, 180), short_area) == short_area.position)
	print("MONITOR_RESTORE_", "FAIL" if test_failed else "PASS", ": negative/above monitor coordinates, removed monitor fallback, 100/150/200 percent physical DPI sizes and clamping")
	quit(1 if test_failed else 0)

func verify(condition: bool, message: String = "Native acceptance check failed") -> bool:
	if not condition:
		test_failed = true
		push_error(message)
		quit(1)
	return condition
