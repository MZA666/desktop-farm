extends SceneTree

const ART = preload("res://scripts/pixel_assets.gd")
const VIEW = preload("res://scripts/farm_view.gd")
const MODEL = preload("res://scripts/game_state.gd")
const WORLD = preload("res://scripts/world_layout.gd")
var failures: Array[String] = []
var assertions := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, detail: String) -> void:
	assertions += 1
	if not condition: failures.append(detail)

func _run() -> void:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/production.json"))
	for kind in ["crops", "animals", "products", "fish"]:
		var entries: Array = config[kind].values() if config[kind] is Dictionary else config[kind]
		for entry in entries:
			var id := str(entry.id)
			var mapped: bool = id in ART.CROP_IDS or id in ART.ANIMAL_IDS or id in ART.PRODUCT_IDS
			check(mapped, "Actual configuration ID has an atlas cell: " + id)
			var texture: Texture2D = ART.icon("animal" if kind == "animals" else "item", id)
			check(texture != null and texture.get_size() == Vector2(32, 32), "Normalized 32px icon: " + id)
			check(texture == ART.icon("animal" if kind == "animals" else "item", id), "Shared region cache: " + id)
	check(ART.icon("animal", "cow") != ART.icon("animal", "goat") and ART.icon("animal", "cow") != ART.icon("animal", "dinosaur"), "Cow, goat and dinosaur use different regions")
	check(ART.icon("item", "pumpkin") != ART.icon("item", "blueberry"), "Pumpkin and blueberry use different regions")
	check(ART.farmer("walk", 0) != ART.farmer("water", 0) and ART.farmer("walk", 0) != ART.farmer("walk", 0, true), "Farmer directions and actions use separate frames")
	check(ART.farmer("harvest", 4) == ART.farmer("harvest", 0), "Animation frame wraps at four frames")
	check(ART.terrain("soil") != ART.terrain("wet_soil") and ART.terrain("grass") == ART.terrain("grass"), "Wet ground is distinct and terrain cache is shared")
	check(ART.farmer("sow", 0) == ART.farmer("plant", 0), "Real sow phase uses the farmer's tool animation")
	for kind in ["grass", "field", "wet", "path"]:
		for variant in range(4):
			var texture: Texture2D = ART.natural_tile(kind, variant, 3)
			check(texture.get_size() == Vector2(32, 32) and texture == ART.natural_tile(kind, variant + 4, 3), "Small natural terrain variants have a bounded shared cache: " + kind)
	check(ART.natural_tile("field", 0, 0).get_image().get_pixel(0, 0) != ART.natural_tile("field", 0, 1).get_image().get_pixel(0, 0), "Connected soil draws an exterior rim only on exposed sides")
	check(ART.natural_decoration("tree").get_size() == Vector2(48, 72), "Original trees use small cached pixel textures")
	var model = MODEL.new(config)
	var view = VIEW.new()
	root.add_child(view)
	view.configure(config)
	view.set_model(model.state, true)
	view._scene_cache_ready = true
	view.set_model(model.state)
	check(view._scene_cache_ready, "Unchanged displayed second preserves static draw cache")
	view.set_model(model.state, true)
	check(not view._scene_cache_ready, "Committed action forces immediate redraw")
	view._scene_cache_ready = true
	model.state.elapsed += 1
	view.set_model(model.state)
	check(view._scene_cache_ready, "An empty field does not bake all terrain for each elapsed second")
	var fixture := {"elapsed": 10.0, "plots": [{"id": "p0", "index": 0, "open": true, "status": "unwatered"}, {"id": "p1", "index": 1, "open": true, "status": "empty"}, {"id": "p2", "index": 2, "open": false, "status": "empty"}], "farmers": [{"id": "worker", "scene": "farm", "x": 320.0, "y": 440.0, "phase": "idle"}]}
	view.set_model(fixture, true)
	view._plot_hits = [{"id": "p0", "index": 0, "open": true, "rect": Rect2(88, 20, 32, 32)}, {"id": "p1", "index": 1, "open": true, "rect": Rect2(88, 52, 32, 32)}, {"id": "p2", "index": 2, "open": false, "rect": Rect2(88, 84, 32, 32)}]
	var watered: Array = []
	var locked: Array = []
	view.plot_clicked.connect(func(id): watered.append(id))
	view.locked_plot_clicked.connect(func(id): locked.append(id))
	view.plots_selected.connect(func(ids): view.set_selection(ids))
	_click(view, Vector2(100, 32))
	check(watered == ["p0"] and view.selected_plot_ids.is_empty(), "Ordinary dry-plot click retains direct manual watering")
	view.selection_mode = true
	_click(view, Vector2(100, 32))
	_click(view, Vector2(100, 64), true)
	check(view.selected_plot_ids == ["p0", "p1"] and watered == ["p0"], "Seed selection and Shift-click select dry plots without watering")
	_click(view, Vector2(100, 32), true)
	check(view.selected_plot_ids == ["p1"], "Shift-click toggles an existing selected plot")
	_click(view, Vector2(100, 96))
	check(locked == ["p2"] and view.selected_plot_ids == ["p1"], "Fallow land emits a separate development request without entering selection")
	_mouse(view, Vector2(90, 22), true)
	_mouse(view, Vector2(116, 79), false)
	check(view.selected_plot_ids == ["p0", "p1"] and watered == ["p0"], "Box selection includes intersected open plots and does not water its starting plot")
	var track: Dictionary = view._farmer_tracks.worker
	view._animation_seconds += 1
	fixture.elapsed = 10.5
	fixture.farmers[0].x = 336.0
	fixture.farmers[0].phase = "walking"
	view.set_model(fixture)
	track = view._farmer_tracks.worker
	check(track.target == Vector2(336, 440) and track.from == Vector2(320, 440), "Farmer interpolation samples actual model feet rather than task targets")
	view._animation_seconds += 0.25
	check(view._farmer_position(track).is_equal_approx(Vector2(328, 440)), "Thirty/fifteen FPS interpolation stays between physical model samples")
	view._animation_seconds += 0.25
	fixture.elapsed = 11.5
	fixture.farmers[0].x = 368.0
	view.set_model(fixture)
	track = view._farmer_tracks.worker
	view._animation_seconds += 0.5
	check(view._farmer_position(track).is_equal_approx(Vector2(352, 440)), "A one-second 32px model step takes a full second to render at the configured walking speed")
	view.resize_view(Vector2(640, 172))
	view._update_camera()
	check(view.get_page_count() == 3 and view.camera_offset == 0, "Continuous1536px farmland paginates from viewport capacity")
	view.page_next()
	view._update_camera()
	check(view.camera_offset == 592 and track.target == Vector2(368, 440), "Paging changes camera only and keeps the farmer's world coordinate")
	view.set_desktop_suspended(true)
	fixture.elapsed = 20.0
	fixture.farmers[0].x = 400.0
	view.set_model(fixture)
	track = view._farmer_tracks.worker
	check(track.from == Vector2(400, 440) and track.target == Vector2(400, 440), "Hidden simulation updates actor samples without replaying stale travel on restore")
	view.set_desktop_suspended(false)
	_test_obstacle_interpolation(view,fixture)
	view.set_model(model.state, true)
	view.set_desktop_suspended(true)
	check(not view.is_processing() and not view._animation_layer.visible, "Desktop hide suspends drawing and animation")
	var before := JSON.stringify(model.snapshot())
	view.set_scene("ranch")
	view.set_scene("pond")
	view.set_scene("farm")
	check(JSON.stringify(model.snapshot()) == before, "Cosmetic view changes never modify simulation or save state")
	view.set_desktop_suspended(false)
	check(view.is_processing() and view._animation_layer.visible and not view._scene_cache_ready, "Desktop restore resumes animation and refreshes scene")
	view.queue_free()
	await process_frame
	if failures.is_empty():
		print("PIXEL_ART_PASS: %d mapping/cache/visibility assertions" % assertions)
		quit(0)
	else:
		for failure in failures: printerr("FAIL: " + failure)
		quit(1)

func _test_obstacle_interpolation(view: FarmView, fixture: Dictionary) -> void:
	view.set_desktop_suspended(true)
	fixture.elapsed=30.0
	fixture.farmers[0].x=304.0
	fixture.farmers[0].y=40.0
	view.set_model(fixture)
	view.set_desktop_suspended(false)
	fixture.elapsed=31.0
	fixture.farmers[0].x=208.0
	fixture.farmers[0].y=216.0
	view.set_model(fixture)
	var track: Dictionary=view._farmer_tracks.worker
	check(not WORLD.segment_walkable("farm",Vector2(304,40),Vector2(208,216)), "Regression fixture's direct interpolation crosses the farm tool shed")
	check(track.has("route") and (track.route as Array).size()>1, "Visible worker interpolation follows a real detour instead of cutting through a building")
	for index in range(16):
		view._animation_seconds=float(track.since)+float(track.duration)*(index+1)/16.0
		check(WORLD.is_walkable("farm",view._farmer_position(track)), "15/30FPS interpolated feet remain outside the shed")

func _mouse(view: FarmView, position: Vector2, pressed: bool, shift := false) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.pressed = pressed
	event.shift_pressed = shift
	view._input(event)

func _click(view: FarmView, position: Vector2, shift := false) -> void:
	_mouse(view, position, true, shift)
	_mouse(view, position, false, shift)
