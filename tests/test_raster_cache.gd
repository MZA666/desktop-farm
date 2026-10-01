extends SceneTree

const MODEL = preload("res://scripts/game_state.gd")
const VIEW = preload("res://scripts/farm_view.gd")
var failures: Array[String] = []
var assertions := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, detail: String) -> void:
	assertions += 1
	if not condition: failures.append(detail)

func _settle(frames := 4) -> void:
	for unused in range(frames): await process_frame
	await RenderingServer.frame_post_draw

func _cache_image(view: FarmView) -> Image:
	return view._static_viewport.get_texture().get_image()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Raster cache regression requires a graphical renderer; it never loads or writes a player save.")
		quit(2)
		return
	Engine.max_fps = 30
	root.size = Vector2i(960, 172)
	root.position = Vector2i(20, 40)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/production.json"))
	var model: FarmState = MODEL.new(config)
	# Test-only model, with a dry plot for a real water command and hit test.
	model.state.plots[0].status = "unwatered"
	model.state.plots[0].remaining = 720.0
	var view: FarmView = VIEW.new()
	root.add_child(view)
	view.configure(config)
	view.resize_view(Vector2(960, 172))
	view.set_interactive(false)
	view.set_model(model.state, true)
	await _settle()
	var initial := _cache_image(view)
	check(not initial.is_empty() and initial.get_size() == Vector2i(960, 172), "Cache raster is exactly the logical strip size")
	check(view._scene_cache_ready and not view._plot_hits.is_empty(), "Raster rebuild also prepares original plot hit coordinates")
	check(view._static_viewport.render_target_update_mode == SubViewport.UPDATE_ONCE, "Static viewport requests one-shot rendering instead of per-frame rendering")
	var bake_count := view._static_bake_count
	var initial_hash: int = hash(initial.get_data())
	await _settle(12)
	check(view._static_bake_count == bake_count and hash(_cache_image(view).get_data()) == initial_hash, "Actor animation frames reuse unchanged static pixels")
	check(root.get_render_info(Viewport.RENDER_INFO_TYPE_CANVAS, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME) < 30, "Main scene submits the cached strip and actors instead of all ground commands")
	view._hover = str(view._plot_hits[0].id)
	view._invalidate_scene()
	await _settle()
	check(hash(_cache_image(view).get_data()) != initial_hash, "Hover invalidation changes actual cached highlight pixels")
	var hit: Dictionary = view._plot_hits[0]
	view.set_interactive(true)
	var water_results: Array[bool] = []
	view.plot_clicked.connect(func(id: String):
		water_results.append(bool(model.command("water", {"plot_id": id}).ok))
		view.set_model(model.state, true))
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = (hit.rect as Rect2).get_center()
	view._input(click)
	await _settle()
	check(water_results == [true] and model.state.plots[0].status == "growing", "Original hit coordinates still water the real plot through input")
	view.set_interactive(false)
	view.resize_view(Vector2(640, 172))
	await _settle()
	check(_cache_image(view).get_size() == Vector2i(640, 172), "Resize reallocates only the actual requested strip")
	var first_page_hash: int = hash(_cache_image(view).get_data())
	view.page_next()
	await _settle()
	check(view.page == 1 and hash(_cache_image(view).get_data()) != first_page_hash, "Page change replaces cached region pixels")
	view.set_scene("ranch")
	var ranch_pages := view._ranch_pages()
	for index in range(ranch_pages.size()):
		if ranch_pages[index].any(func(module): return str(module.kind) == "barn" and str(module.barn.id) == "chicken_coop"):
			view.page = index
			break
	view.queue_redraw()
	await _settle()
	check(not view._animal_draws.is_empty() and _cache_image(view).get_size() == Vector2i(640, 172), "Ranch cache rebuild retains animal placements")
	view.set_scene("pond")
	await _settle()
	check(view._fish_hits.size() == 12 and view._pond_bounds.has_point((view._fish_hits[0].rect as Rect2).get_center()), "Animated fish preserve live input bounds above the cached pond")
	var before_cosmetic := JSON.stringify(model.snapshot())
	view.set_desktop_suspended(true)
	bake_count = view._static_bake_count
	view.resize_view(Vector2(720, 172))
	view.set_model(model.state, true)
	await _settle()
	check(view._static_bake_count == bake_count and view._static_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Hidden view does not bake or animate despite invalidation")
	view.set_desktop_suspended(false)
	await _settle()
	check(view._static_bake_count > bake_count and view._scene_cache_ready and _cache_image(view).get_size() == Vector2i(720, 172), "Restore rebuilds pending resized pixels and actor placements")
	check(JSON.stringify(model.snapshot()) == before_cosmetic, "Raster cache and visibility never mutate simulation state")
	view.queue_free()
	await process_frame
	if failures.is_empty():
		print("RASTER_CACHE_PASS: %d actual-pixel/input/cache/visibility assertions" % assertions)
		quit(0)
	else:
		for failure in failures: printerr("FAIL: " + failure)
		quit(1)
