extends SceneTree

const MODEL = preload("res://scripts/game_state.gd")
const CONFIG = preload("res://scripts/config_loader.gd")
const VIEW = preload("res://scripts/illustrated_view.gd")
var failures: Array[String] = []
var assertions := 0

func check(value: bool, message: String) -> void:
	assertions += 1
	if not value: failures.append(message)

func _initialize() -> void:
	_run.call_deferred()

func settle() -> void:
	for unused in range(5): await process_frame
	await RenderingServer.frame_post_draw

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Illustrated view tests require an actual graphical renderer")
		quit(2)
		return
	Engine.max_fps = 30
	root.size = Vector2i(1536, 352)
	root.position = Vector2i(0, 40)
	var model = MODEL.new(CONFIG.load_values())
	var view = VIEW.new()
	root.add_child(view)
	view.configure(model.config)
	view.resize_view(Vector2(1536, 352))
	for index in range(model.state.plots.size()):
		var plot: Dictionary = model.state.plots[index]
		plot.open = true
		plot.crop_id = str(model.config.crops[posmod(index, model.config.crops.size())].id)
		plot.status = "ready" if index % 4 == 3 else "growing"
		plot.remaining = float(model.crops[str(plot.crop_id)].grow_seconds) * float(4 - index % 4) / 4
	view.set_model(model.state, true)
	await settle()
	check(view._plot_hits.size() == 96, "Expanded farm camera shows all96 independent soil hits")
	var farm_image := root.get_texture().get_image()
	check(farm_image.get_size() == Vector2i(1536, 352), "Farm raster uses expanded viewport at actual entity scale")
	farm_image.save_png("res://.review/v081-illustrated-farm.png")
	var snapshot := JSON.stringify(model.snapshot())
	view.camera_down()
	view.page_next()
	view.resize_view(Vector2(640, 172))
	await settle()
	check(JSON.stringify(model.snapshot()) == snapshot, "Camera, page and compact mode never mutate crop progress or coordinates")
	check(view.camera_y >= 0 and view.camera_y <= 340, "Compact vertical camera stays inworld bounds")
	view.camera_up()
	check(view.camera_y >= 0, "Camera up clamps to world edge")
	view.resize_view(Vector2(1920, 352))
	root.size = Vector2i(1920, 352)
	view.set_scene("ranch")
	view.set_model(model.state, true)
	await settle()
	check(not view._animal_hits.is_empty(), "Real animal bodies create live interaction geometry")
	var signals: Array[String] = []
	view.animal_clicked.connect(func(id): signals.append(id))
	var hit: Dictionary = view._animal_hits[-1]
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = (hit.rect as Rect2).get_center()
	view._input(click)
	check(signals.size() == 1, "One click on overlapping animals emits one topmost instanceID")
	view.set_interactive(false)
	view._input(click)
	check(signals.size() == 1, "Observation mode emits no animal interaction")
	view.set_interactive(true)
	var initial_position := Vector2(float(model.state.animals[0].x), float(model.state.animals[0].y))
	for unused in range(30): model.tick(0.2)
	view.set_model(model.state, true)
	await settle()
	var current := Vector2(float(model.state.animals[0].x), float(model.state.animals[0].y))
	check(current.distance_to(initial_position) > 1, "View consumes actual movedanimal model coordinates")
	var same_animal: Dictionary = {}
	for candidate in view._animal_hits:
		if str(candidate.id) == str(model.state.animals[0].id): same_animal = candidate; break
	check(not same_animal.is_empty(), "Moved animal maintains the same interaction ID")
	root.get_texture().get_image().save_png("res://.review/v081-illustrated-ranch.png")
	view.set_scene("pond")
	view.set_model(model.state, true)
	await settle()
	check(view._fish_hits.size() == 12, "Full expanded pond exposes all initial fish hit targets")
	check(view._pond_bounds.size == Vector2(1130, 324), "Pond hit water follows newworldgeometry")
	root.get_texture().get_image().save_png("res://.review/v081-illustrated-pond.png")
	var before_hidden := JSON.stringify(model.snapshot())
	view.set_desktop_suspended(true)
	var bake_count: int = view._static_bake_count
	view.camera_down()
	await settle()
	check(view._static_bake_count == bake_count, "Hidden illustratedview does not bake camera changes")
	view.set_desktop_suspended(false)
	await settle()
	check(view._static_bake_count > bake_count, "Resume bakes the pending camera region")
	check(JSON.stringify(model.snapshot()) == before_hidden, "Visibility and animation leave all economicstate unchanged")
	view.queue_free()
	await process_frame
	if failures.is_empty():
		print("ILLUSTRATED_VIEW_PASS: %d geometry/input/raster/state assertions" % assertions)
		quit(0)
	else:
		for failure in failures: printerr("FAIL: " + failure)
		quit(1)
