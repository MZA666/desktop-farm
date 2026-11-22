extends SceneTree

const HOST = preload("res://scripts/desktop_host.gd")
var assertions := 0
var failed := false

func _initialize() -> void:
	var areas: Array[Rect2i] = [Rect2i(0, 0, 1920, 1040), Rect2i(-1920, -200, 1920, 1040),
		Rect2i(1920, -900, 1600, 900), Rect2i(-800, -200, 800, 180)]
	check(HOST.display_height_for_mode("expanded") == 420 and HOST.scene_height_for_mode("expanded") == 352, "Default expanded logical heights")
	check(HOST.display_height_for_mode("compact") == 240 and HOST.scene_height_for_mode("compact") == 172, "Compact logical heights")
	check(HOST.display_height_for_mode("unknown") == 420, "Invalid saved mode safely defaults expanded")
	for area in areas:
		for scale in [1.0, 1.25, 1.5, 2.0, 3.0]:
			for mode in ["expanded", "compact"]:
				for collapsed in [false, true]:
					var logical := 32 if collapsed else (420 if mode == "expanded" else 240)
					var size := HOST.scenery_size_for_area(area, scale, mode, collapsed)
					check(size == Vector2i(area.size.x, mini(area.size.y, int(round(logical * scale)))), "DPI conversion before work-area clamp")
					var point := HOST.clamped_position(Vector2i(-9999, 9999), size, area)
					check(area.encloses(Rect2i(point, size)), "Every mode remains inside negative/above/short work areas")
					check(point.y == area.end.y - size.y, "Default visible footprint anchors above taskbar")
			var toolbar := HOST.toolbar_size_for_area(area, scale)
			check(toolbar.y == mini(area.size.y, int(round(32 * scale))), "Collapsed toolbar keeps independent physical size")
	check(HOST.scenery_size_for_area(Rect2i(), 1.0) == Vector2i.ZERO, "Missing display has no fake size")
	check(HOST.scenery_size_for_area(areas[0], NAN) == Vector2i(1920, 420), "Invalid DPI falls back to 100 percent")
	check(HOST.scenery_size_for_area(areas[1], 1.5, "compact", false, Vector2i(800, 300)) == Vector2i(1200, 450), "Custom dimensions use target monitor DPI")
	check(HOST.scenery_size_for_area(areas[1], 1.5, "compact", true, Vector2i(800, 300)) == Vector2i(1200, 48), "Collapse keeps custom width and reserves custom height for expansion")
	var origin := Rect2i(-1920, 300, 1400, 420)
	check(HOST.resized_bounds(origin, Vector2i(-400, 100), areas[1], 1.0, false) == Rect2i(-1920, 400, 1000, 320), "Top-right drag keeps bottom-left fixed")
	check(HOST.resized_bounds(origin, Vector2i(-4000, 4000), areas[1], 1.0, false).size == HOST.MIN_WINDOW_SIZE, "Resize stops at a usable size")
	check(HOST.resized_bounds(origin, Vector2i(4000, -4000), areas[1], 1.0, false) == Rect2i(-1920, -200, 1920, 920), "Resize stops at usable monitor edges including negative coordinates")
	var strip := Rect2i(-1920, 300, 1400, 32)
	check(HOST.resized_bounds(strip, Vector2i(-400, 100), areas[1], 1.0, true) == Rect2i(-1920, 300, 1000, 32), "Collapsed drag changes width only")
	var host := HOST.new()
	check(host.display_mode == "expanded", "Fresh desktop defaults expanded")
	check(host.set_display_mode("compact") and host.display_mode == "compact", "Mode API accepts compact")
	check(host.logical_window_height() == 240 and host.visible_scene_height() == 172, "Unstarted host exposes compact logical layout")
	check(not host.set_display_mode("invalid") and host.display_mode == "compact", "Mode API rejects invalid values without mutation")
	host.set_collapsed(true)
	check(host.logical_window_height() == 32 and host.visible_scene_height() == 0, "Collapsed display has no rendered scene space")
	check(host.set_display_mode("expanded") and host.logical_window_height() == 32, "Mode change while collapsed stays collapsed")
	host.set_collapsed(false)
	check(host.logical_window_height() == 420 and host.visible_scene_height() == 352, "Expanded restore is independent of collapse state")
	check(host.export_settings().display_mode == "expanded" and not host.export_settings().topmost, "Persist display mode without reviving topmost")
	check(host.set_display_mode("expanded", Vector2i(1000, 320)) and host.visible_scene_height() == 252, "Custom height changes the viewport")
	check(host.export_settings().window_size == [1000, 320], "Save logical dimensions independently of the monitor")
	host.free()
	print("DISPLAY_MODE_GEOMETRY_", "FAIL" if failed else "PASS", ": %d expanded/compact/collapsed DPI/work-area assertions" % assertions)
	quit(1 if failed else 0)

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failed = true
		printerr("FAIL: " + message)
