extends SceneTree

const HOST = preload("res://scripts/desktop_host.gd")

func _initialize() -> void:
	var screens: Array[Rect2i] = [Rect2i(0, 0, 1920, 1040), Rect2i(-1920, 0, 1920, 1040),
		Rect2i(1920, -900, 1600, 900)]
	assert(HOST.visible_area_for_point(Vector2i(-1900, 500), screens) == screens[1])
	assert(HOST.visible_area_for_point(Vector2i(2000, -800), screens) == screens[2])
	assert(HOST.visible_area_for_point(Vector2i(40, 700), screens) == screens[0])
	assert(HOST.visible_area_for_point(Vector2i(-6000, 0), screens) == Rect2i())
	assert(HOST.visible_area_for_point(Vector2i(-1920, 0), screens) == screens[1])
	print("MONITOR_RESTORE_PASS: negative/above monitor coordinates, visible boundaries, removed monitor fallback")
	quit(0)
