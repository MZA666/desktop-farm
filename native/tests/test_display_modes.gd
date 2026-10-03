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
	_test_split_geometry(areas)
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
	host.free()
	print("DISPLAY_MODE_GEOMETRY_", "FAIL" if failed else "PASS", ": %d expanded/compact/collapsed DPI/work-area assertions" % assertions)
	quit(1 if failed else 0)

func _test_split_geometry(areas: Array[Rect2i]) -> void:
	# Unattached Window objects are geometry fixtures, never real desktop UI.
	var host := HOST.new()
	var toolbar := Window.new()
	var scene := Window.new()
	host.toolbar_window=toolbar
	host.scene_window=scene
	for area in areas:
		for scale in [1.0,1.25,1.5,2.0,3.0]:
			for mode in ["expanded","compact"]:
				for collapsed in [false,true]:
					host._work_area=area
					host.dpi_scale=scale
					host.display_mode=mode
					host.collapsed=collapsed
					host._manual_position=false
					host._layout_windows()
					var toolbar_rect := Rect2i(toolbar.position,toolbar.size)
					var scene_rect := Rect2i(scene.position,scene.size)
					check(area.encloses(toolbar_rect), "Toolbar geometry stays entirely in monitor work area")
					check(not toolbar_rect.intersects(scene_rect), "Toolbar and scenery have no native hit-test overlap")
					check(scene.position.y==toolbar_rect.end.y, "Scenery begins immediately below the control toolbar")
					if not collapsed and host._group_size.y>toolbar.size.y:
						check(area.encloses(scene_rect), "Visible scenery fits remaining physical work area")
						check(toolbar.size.y+scene.size.y==host._group_size.y, "One combined game footprint keeps420/240logical height")
					else:
						check(host.visible_scene_height()==0, "Collapsed or clamped-away scenery has no logical content")
	toolbar.free()
	scene.free()
	host.free()

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failed = true
		printerr("FAIL: " + message)
