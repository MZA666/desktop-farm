extends SceneTree

const MODEL = preload("res://scripts/game_state.gd")
const CONFIG = preload("res://scripts/config_loader.gd")
const VIEW = preload("res://scripts/illustrated_view.gd")
const WORLD = preload("res://scripts/world_layout.gd")
const GROUND = preload("res://scripts/ground_products.gd")
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
	DirAccess.make_dir_recursive_absolute("res://docs/screenshots/v0.8.3")
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
	farm_image.save_png("res://docs/screenshots/v0.8.3/farm-1536.png")
	for soil_hit in view._plot_hits:
		var actual := Rect2(view._to_world(soil_hit.rect.position),soil_hit.rect.size)
		check(actual == WORLD.plot_rect(int(soil_hit.index)), "Rendered slot uses authoritative soil rectangle %s" % soil_hit.id)
		check(WORLD.soil_contains_rect(actual), "Rendered slot stays on actual painted soil %s" % soil_hit.id)
	await _test_crop_pixel_hits(view,model)
	root.size = Vector2i(2560,352)
	view.resize_view(Vector2(2560,352))
	await settle()
	root.get_texture().get_image().save_png("res://docs/screenshots/v0.8.3/farm-2560.png")
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
	view.camera_scroll(-1000)
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
	check(view._shelter_hits.size() == 7, "Seven gable signs are visible across the ranch")
	var signs: Array[String] = []
	view.shelter_clicked.connect(func(id): signs.append(id))
	click.position = (view._shelter_hits[0].rect as Rect2).get_center()
	view._input(click)
	check(signs == ["chicken_coop"], "Gable sign opens its own shelter without petting an animal")
	check(int(view._shelter_counts.chicken_coop.total) == 4, "Barn count follows assigned animals outside the house")
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
	root.get_texture().get_image().save_png("res://docs/screenshots/v0.8.3/ranch-1920.png")
	# Three units in one fixed pile while the producer continues its next cycle.
	var producer: Dictionary = model.state.animals[0]
	producer.adult = true
	producer.adult_remaining = 0.0
	for unused in range(3):
		producer.product_remaining = 0.0
		GROUND.complete_cycle(model.state,producer,model.animal_types[str(producer.type_id)])
	view.set_model(model.state,true)
	await settle()
	check(view._product_draws.size() == 1 and int(view._product_draws[0].quantity) == 3, "One ground sprite exposes the accumulated stack quantity")
	check((view._product_draws[0].foot as Vector2).distance_to(view._to_screen(GROUND.point(model.state.ground_products[0])).floor()) < 0.01, "Ground sprite is anchored to the fixed collection target")
	root.get_texture().get_image().save_png("res://docs/screenshots/v0.8.3/ranch-products.png")
	root.size = Vector2i(2560,352)
	view.resize_view(Vector2(2560,352))
	await settle()
	root.get_texture().get_image().save_png("res://docs/screenshots/v0.8.3/ranch-2560.png")
	view.camera_center()
	model.state.warehouse_hay = 16
	model.state.trough_hay = 6
	view.set_model(model.state,true)
	await settle()
	check(view.hay_summary().warehouse == 16 and view.hay_summary().trough == 6, "Visible ranch hay HUD uses distinct actual stocks")
	root.get_texture().get_image().save_png("res://docs/screenshots/v0.8.3/ranch-hay-middle.png")
	root.size = Vector2i(640,172)
	view.resize_view(Vector2(640,172))
	view.page_next()
	await settle()
	check(Rect2(0,0,640,172).encloses(view._hay_hud_rect()), "Ranch hay stays on-screen when scrolling a narrow compact scene")
	root.get_texture().get_image().save_png("res://docs/screenshots/v0.8.3/ranch-hay-compact.png")
	root.size = Vector2i(2560,352)
	view.resize_view(Vector2(2560,352))
	view.set_scene("pond")
	view.set_model(model.state, true)
	await settle()
	check(view._fish_hits.size() == 12, "Full expanded pond exposes all initial fish hit targets")
	check(view._pond_bounds.size == WORLD.water_bounds().size, "Pond bounding box follows the authoritative water region")
	check(not view._water_input_contains(view._to_screen(Vector2(300,260))), "Dock input is rejected despite lying in the water bounding box")
	check(view._water_input_contains(view._to_screen(Vector2(800,260))), "Open water accepts net input")
	root.get_texture().get_image().save_png("res://docs/screenshots/v0.8.3/pond-2560.png")
	root.size = Vector2i(1920,352)
	view.resize_view(Vector2(1920,352))
	await settle()
	root.get_texture().get_image().save_png("res://docs/screenshots/v0.8.3/pond-1920.png")
	view.set_process(false)
	for unused in range(30):
		model.tick(0.2)
		view.set_model(model.state)
		for part in range(5):
			view._animation_seconds += 0.04
			for fish_track in view._fish_tracks.values():
				check(WORLD.fish_position_safe(view._fish_position(fish_track)), "Interpolated fish body stays on the real water")
	for unused in range(20):
		model.tick(2.4)
		view.set_model(model.state)
		for part in range(10):
			view._animation_seconds += 0.1
			for fish_track in view._fish_tracks.values():
				check(WORLD.fish_position_safe(view._fish_position(fish_track)), "Delayed UI sampling never shortcuts a fish across a shore")
	view.set_process(true)
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
	# A rendered farmer's stride follows real world displacement, never camera pan.
	view.set_scene("farm")
	view.resize_view(Vector2(1536,352))
	var walker: Dictionary = model.state.farmers[0]
	walker.phase = "walking"
	walker.x = 600.0
	walker.y = 260.0
	view.set_model(model.state,true)
	await settle()
	view.set_process(false)
	view._farmer_tracks.clear()
	view._gait_tracks.clear()
	view.set_model(model.state,true)
	await settle()
	var start_distance := float(view._gait_tracks[str(walker.id)].distance)
	walker.x += 12
	view.set_model(model.state,true)
	view._animation_seconds += 0.3
	view._redraw_animation()
	await settle()
	check(is_equal_approx(float(view._gait_tracks[str(walker.id)].distance)-start_distance,12.0), "Walking advances stride by actual world distance")
	var distance_before_camera := float(view._gait_tracks[str(walker.id)].distance)
	view.camera_down()
	await settle()
	check(is_equal_approx(float(view._gait_tracks[str(walker.id)].distance),distance_before_camera), "Camera pan does not animate stationary walking feet")
	walker.phase = "idle"
	view.set_model(model.state,true)
	await settle()
	check(int(view._gait_tracks[str(walker.id)].frame) == 2, "Idle farmer uses a neutral standing pose")
	view.queue_free()
	await process_frame
	if failures.is_empty():
		print("ILLUSTRATED_VIEW_PASS: %d geometry/input/raster/state assertions" % assertions)
		quit(0)
	else:
		for failure in failures: printerr("FAIL: " + failure)
		quit(1)

func _test_crop_pixel_hits(view,model) -> void:
	var original_plots: Array = model.state.plots.duplicate(true)
	var original_selection: Array = view.selected_plot_ids.duplicate()
	var original_mode: bool = view.selection_mode
	for plot in model.state.plots:
		plot.status = "empty"
		plot.product = {}
	# These real mature atlas sprites cross the previous soil row, at both
	# the left side of the world and the second narrow-camera page.
	for index in [16,22]:
		model.state.plots[index].crop_id = "parsnip"
		model.state.plots[index].status = "ready"
		model.state.plots[index].remaining = 0.0
	view.selection_mode = true
	var selections: Array = []
	var selected := func(ids): selections.append(ids.duplicate())
	view.plots_selected.connect(selected)
	view.set_model(model.state,true)
	view.camera_center()
	await settle()
	_check_crop_probe(view,model,16,1,selections,"expanded")
	var masks_before: int = view._crop_masks.size()
	var mask_before: BitMap = view._crop_masks["parsnip/3"]
	view.camera_down()
	await settle()
	_check_crop_probe(view,model,16,1,selections,"scrolled")
	check(view._crop_masks.size() == masks_before and view._crop_masks["parsnip/3"] == mask_before,"Camera redraw reuses compact alpha masks instead of reading images per frame")
	root.size = Vector2i(640,172)
	view.resize_view(Vector2(640,172))
	view.focus_world(WORLD.plot_center(22))
	await settle()
	check(view.page == 1,"Real crop hit fixture uses a horizontally shifted 640-pixel page")
	_check_crop_probe(view,model,22,7,selections,"compact second page")
	check(view._crop_masks.size() <= 256,"Mask cache has at most one bit plane per crop and stage")
	view.plots_selected.disconnect(selected)
	model.state.plots = original_plots
	view.selection_mode = original_mode
	view.set_model(model.state,true)
	view.set_selection(original_selection)
	view.page = 0
	root.size = Vector2i(1536,352)
	view.resize_view(Vector2(1536,352))
	view.camera_center()
	await settle()

func _check_crop_probe(view,model,index: int,upper_index: int,selections: Array,label: String) -> void:
	var texture: Texture2D = view.SCENE_ART.crop("parsnip",3)
	var pixels := texture.get_image()
	check(pixels.get_pixel(32,40).a > 0.1 and pixels.get_pixel(32,1).a == 0,"Real mature parsnip atlas supplies opaque and transparent samples "+label)
	var foot: Vector2 = view._to_screen(WORLD.plot_crop_anchor(index)).floor()
	var rect := Rect2(foot-Vector2(26,76),Vector2(52,78))
	var opaque := rect.position + Vector2(32.5,40.5) / Vector2(texture.get_size()) * rect.size
	var clear := rect.position + Vector2(32.5,1.5) / Vector2(texture.get_size()) * rect.size
	check(Rect2(Vector2.ZERO,Vector2(view.view_width,view.view_height)).has_point(opaque) and Rect2(Vector2.ZERO,Vector2(view.view_width,view.view_height)).has_point(clear),"Both actual raster pixels visible after camera transform "+label)
	check(WORLD.plot_rect(upper_index).has_point(view._to_world(opaque)) and WORLD.plot_rect(upper_index).has_point(view._to_world(clear)),"Both pixels occupy the prior soil row, reproducing the original wrong-row click "+label)
	check(str(view._plot_at(opaque).get("id","")) == str(model.state.plots[index].id),"Opaque visible crop resolves its own stable plot for click and hover "+label)
	check(str(view._plot_at(clear).get("id","")) == str(model.state.plots[upper_index].id),"Transparent crop pixel reveals the actual soil behind it "+label)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = opaque
	view._input(press)
	var release: InputEventMouseButton = press.duplicate()
	release.pressed = false
	view._input(release)
	check(not selections.is_empty() and selections[-1] == [str(model.state.plots[index].id)],"Real press/release selects the visible crop instead of the upper soil "+label)
	press.position = clear
	release.position = clear
	view._input(press)
	view._input(release)
	check(selections[-1] == [str(model.state.plots[upper_index].id)],"Real press/release on transparency selects the underlying soil "+label)
	press.position = opaque
	release.position = opaque+Vector2(9,3)
	view._input(press)
	view._input(release)
	check(selections[-1] == [str(model.state.plots[upper_index].id)],"Drag box still selects soil rectangles despite pressing on a tall crop "+label)
