extends SceneTree

const VIEW = preload("res://scripts/illustrated_view.gd")
const MODEL = preload("res://scripts/game_state.gd")
const CONFIG = preload("res://scripts/config_loader.gd")
var assertions := 0
var failures: Array[String] = []

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition: failures.append(message)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var model = MODEL.new(CONFIG.load_values())
	var view = VIEW.new()
	root.add_child(view)
	view.configure(model.config)
	view.set_model(model.state)
	view.resize_view(Vector2(1536,352))
	var original := JSON.stringify(model.snapshot())
	for scene in ["farm", "ranch", "pond"]:
		view.set_scene(scene)
		check(is_equal_approx(view.camera_y,80), "Each scene initially has a middle expanded view: " + scene)
		view.camera_up()
		check(is_equal_approx(view.camera_y,48), "One up click is a fine 32px step: " + scene)
		view.camera_down()
		check(is_equal_approx(view.camera_y,80), "One down click returns to the same view: " + scene)
		view.camera_up()
		view.resize_view(Vector2(640,172))
		check(is_equal_approx(view.camera_y,138), "Resizing keeps the observed world center: " + scene)
		view.camera_center()
		check(is_equal_approx(view.camera_y,170), "Compact center is a real middle position: " + scene)
		view.camera_scroll(16)
		check(is_equal_approx(view.camera_y,186), "Wheel moves half the button step: " + scene)
		view.camera_scroll(-8)
		check(is_equal_approx(view.camera_y,178), "High resolution half-notch is preserved: " + scene)
		view.resize_view(Vector2(1536,352))
		check(is_equal_approx(view.camera_y,88), "Compact to expanded preserves the world center: " + scene)
		view.camera_scroll(-10000)
		check(is_equal_approx(view.camera_y,0), "Upper edge cannot show blank outside world: " + scene)
		view.camera_scroll(10000)
		check(is_equal_approx(view.camera_y,160), "Lower edge cannot show blank outside world: " + scene)
		view.camera_center()
	view.set_scene("farm")
	view.camera_down()
	view.set_scene("ranch")
	view.resize_view(Vector2(640,172))
	view.camera_up()
	view.set_scene("farm")
	check(is_equal_approx(view.camera_y,202), "Farm keeps its own world center across scene and height changes")
	view.set_scene("ranch")
	check(is_equal_approx(view.camera_y,138), "Ranch separately remembers its camera position")
	view.camera_scroll(10000)
	view.resize_view(Vector2(640,352))
	check(is_equal_approx(view.camera_y,160), "Expanded view safely clamps a compact lower edge")
	view.set_scene("farm")
	view.resize_view(Vector2(640,172))
	view.set_scene("ranch")
	check(is_equal_approx(view.camera_y,340), "Compact lower edge survives height and scene round trip")
	view.camera_scroll(-10000)
	view.resize_view(Vector2(640,352))
	check(is_equal_approx(view.camera_y,0), "Expanded view safely clamps a compact upper edge")
	view.resize_view(Vector2(640,172))
	check(is_equal_approx(view.camera_y,0), "Compact upper edge is recovered after expanded round trip")
	check(JSON.stringify(model.snapshot()) == original, "Camera operations leave economy and production completely unchanged")
	for level in range(4):
		model.state.storage_level = level
		model.state.warehouse_hay = model.storage_capacity()
		model.state.trough_hay = level + 1
		view.set_model(model.state)
		var hay: Dictionary = view.hay_summary()
		check(hay.capacity == model.storage_capacity(), "Hay UI follows upgraded model capacity, level %d" % level)
		check(hay.warehouse == model.state.warehouse_hay and hay.trough == model.state.trough_hay, "Two storage totals are kept distinct, level %d" % level)
	model.state.warehouse_hay = 0
	model.state.trough_hay = 0
	view.set_model(model.state)
	check(view.hay_summary().warehouse == 0 and view.hay_summary().trough == 0, "Empty stocks visibly report zero")
	var hud: Rect2 = view._hay_hud_rect()
	view.camera_scroll(10000)
	view.page_next()
	check(hud == view._hay_hud_rect(), "Hay display stays visible independent of ranch camera and page")
	check(Rect2(0,0,640,172).encloses(hud), "Both hay rows fit the compact minimum desktop viewport")
	if failures.is_empty(): print("CAMERA_HAY_PASS: %d assertions" % assertions)
	else:
		for failure in failures: printerr("FAIL: " + failure)
	quit(0 if failures.is_empty() else 1)
