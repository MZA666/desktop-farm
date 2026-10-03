class_name FarmIllustratedView
extends "res://scripts/farm_view.gd"

## Illustrated terrain is cached; live plants and actors share foot-depth order.
## All model coordinates stay in the world when the camera or height changes.
signal animal_clicked(instance_id: String)
const SCENE_ART = preload("res://scripts/scene_assets.gd")
const POND_RULES = preload("res://scripts/pond_rules.gd")
var camera_y := 96.0
var _scene_camera := {"farm": 96.0, "ranch": 0.0, "pond": 72.0}
var _animal_hits: Array = []
var _animal_tracks: Dictionary = {}
var _feedback: Dictionary = {}
var _panning := false
var _pan_mouse := Vector2.ZERO
var _pan_origin := Vector2.ZERO
var _ranch_visual_key := -1
var _animal_hover := ""
var _net_flash_until := 0.0

func _ready() -> void:
	super._ready()
	_invalidate_scene()

func set_model(values: Dictionary, force := false) -> void:
	_sample_animals(values)
	super.set_model(values, force)
	var visual_key := hash([values.get("grass", []), values.get("shelters", {}), values.get("pond", {}), values.get("trough_hay", 0), values.get("warehouse_hay", 0)])
	if scene_name != "farm" and visual_key != _ranch_visual_key:
		_ranch_visual_key = visual_key
		_invalidate_scene()

func set_scene(value: String) -> void:
	_scene_camera[scene_name] = camera_y
	super.set_scene(value)
	camera_y = float(_scene_camera.get(scene_name, 0.0))
	_animal_hits.clear()
	_animal_hover = ""
	_update_camera()
	_invalidate_scene()

func resize_view(size: Vector2) -> void:
	view_width = maxf(240.0, size.x)
	view_height = maxf(32.0, size.y)
	_update_camera()
	_invalidate_scene()

func _static_key() -> String:
	return "%s/%d/%d/%d/%d" % [scene_name, page, ceili(view_width), ceili(view_height), roundi(camera_y)]

func _update_camera() -> void:
	super._update_camera()
	camera_y = clampf(camera_y, 0, maxf(0, WORLD.world_size(scene_name).y - view_height))

func _to_screen(world_position: Vector2) -> Vector2:
	var inset := maxf(0.0, (view_width - WORLD.world_size(scene_name).x) * 0.5) if view_width >= WORLD.world_size(scene_name).x else 24.0
	return world_position + Vector2(inset - camera_offset, -camera_y)

func _camera_span() -> float:
	return view_width if view_width >= WORLD.world_size(scene_name).x else maxf(192.0, view_width - 48.0)

func camera_up() -> void:
	camera_y -= maxf(56, view_height * 0.55)
	_update_camera()
	_invalidate_scene()

func camera_down() -> void:
	camera_y += maxf(56, view_height * 0.55)
	_update_camera()
	_invalidate_scene()

func focus_world(position_value: Vector2) -> void:
	page = clampi(floori(position_value.x / _camera_span()), 0, get_page_count() - 1)
	camera_y = position_value.y - view_height * 0.5
	_update_camera()
	_invalidate_scene()

func show_animal_feedback(id: String) -> void:
	_feedback[id] = _animation_seconds + 1.6
	_redraw_animation()

func show_net_feedback() -> void:
	_net_flash_until = _animation_seconds + 0.65
	_redraw_animation()

func _process(delta: float) -> void:
	super._process(delta)
	_animal_hover = ""
	if interactive and scene_name == "ranch":
		var mouse := get_local_mouse_position()
		for index in range(_animal_hits.size() - 1, -1, -1):
			if (_animal_hits[index].rect as Rect2).has_point(mouse):
				_animal_hover = str(_animal_hits[index].id)
				break

func _input(event: InputEvent) -> void:
	if not interactive or _desktop_suspended or not is_visible_in_tree(): return
	var control := get_viewport().gui_get_hovered_control()
	if control != null and control.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		super._input(event)
		return
	if event is InputEventMouseMotion and _panning:
		var mouse: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		var movement := mouse - _pan_mouse
		camera_y = _pan_origin.y - movement.y
		_update_camera()
		_invalidate_scene()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mouse: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed and Rect2(Vector2.ZERO, Vector2(view_width, view_height)).has_point(mouse):
				_panning = true
				_pan_mouse = mouse
				_pan_origin = Vector2(camera_offset, camera_y)
			else: _panning = false
			get_viewport().set_input_as_handled()
			return
		if event.pressed and Rect2(Vector2.ZERO, Vector2(view_width, view_height)).has_point(mouse):
			if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
				if event.shift_pressed:
					if event.button_index == MOUSE_BUTTON_WHEEL_UP: page_previous()
					else: page_next()
				elif event.button_index == MOUSE_BUTTON_WHEEL_UP: camera_up()
				else: camera_down()
				get_viewport().set_input_as_handled()
				return
			if scene_name == "ranch" and event.button_index == MOUSE_BUTTON_LEFT:
				for index in range(_animal_hits.size() - 1, -1, -1):
					if (_animal_hits[index].rect as Rect2).has_point(mouse):
						animal_clicked.emit(str(_animal_hits[index].id))
						get_viewport().set_input_as_handled()
						return
	super._input(event)

func _draw_static() -> void:
	if _desktop_suspended: return
	_draw_target = _static_layer
	_plot_hits.clear()
	_target_positions.clear()
	_animal_draws.clear()
	_update_camera()
	_box(Rect2(Vector2.ZERO, Vector2(view_width, view_height)), Color("#709a32"))
	var background: Texture2D = SCENE_ART.background(scene_name)
	if background != null:
		_draw_woodland_margins(background)
		_canvas().draw_texture_rect(background, Rect2(_to_screen(Vector2.ZERO), WORLD.world_size(scene_name)), false)
	match scene_name:
		"farm": _illustrated_soil()
		"ranch": _illustrated_grass()
		"pond": _pond_bounds = Rect2(_to_screen(WORLD.water_bounds().position), WORLD.water_bounds().size)
	_draw_target = null
	_static_bake_count += 1
	_scene_cache_ready = true
	_redraw_animation()

func _draw_woodland_margins(background: Texture2D) -> void:
	# Wide desktops reveal illustrated border strips, preserving the shared
	# world scale instead of flat bars or stretching the playable composition.
	var left := _to_screen(Vector2.ZERO).x
	var right := left + WORLD.world_size(scene_name).x
	var source_height := minf(view_height, background.get_height() - camera_y)
	if left > 0:
		var width := minf(96, background.get_width() * 0.06)
		var x := left
		while x > 0:
			var span := minf(width, x)
			x -= span
			_canvas().draw_texture_rect_region(background, Rect2(x, 0, span, source_height), Rect2(0, camera_y, span, source_height))
	if right < view_width:
		var width := minf(96, background.get_width() * 0.06)
		var x := right
		while x < view_width:
			var span := minf(width, view_width - x)
			_canvas().draw_texture_rect_region(background, Rect2(x, 0, span, source_height), Rect2(background.get_width() - span, camera_y, span, source_height))
			x += span

func _illustrated_soil() -> void:
	for plot in model_state.get("plots", []):
		var index := int(plot.get("index", 0))
		var bounds := Rect2(_to_screen(WORLD.plot_position(index)), Vector2(WORLD.PLOT_SIZE, WORLD.PLOT_SIZE))
		if not bounds.intersects(Rect2(Vector2.ZERO, Vector2(view_width, view_height))): continue
		_plot_hits.append({"rect": bounds, "id": str(plot.id), "open": bool(plot.open), "index": index})
		if not bool(plot.open):
			# Fallow land is textured ground from the plate, without boxed tiles.
			continue
		var wet := str(plot.status) in ["growing", "ready", "processing"]
		_canvas().draw_rect(bounds.grow(-1), Color(0.20, 0.09, 0.025, 0.32 if wet else 0.14))
		# Small connected ridges let planted land remain part of natural soil.
		for row in range(3):
			var yy := bounds.position.y + 14 + row * 13
			_canvas().draw_line(Vector2(bounds.position.x + 4, yy), Vector2(bounds.end.x - 4, yy), Color(0.30, 0.15, 0.07, 0.38), 1)

func _illustrated_grass() -> void:
	for patch in model_state.get("grass", []):
		if not bool(patch.get("open", false)) or int(patch.get("clumps", 0)) == 0: continue
		var fallback: Vector2 = WORLD.grass_anchor(int(patch.get("index", 0)))
		var foot := _to_screen(Vector2(float(patch.get("x", fallback.x)), float(patch.get("y", fallback.y))))
		var texture: Texture2D = SCENE_ART.grass(clampi(int(patch.clumps) - 1, 0, 3))
		if texture != null:
			var variation := int(patch.get("appearance", patch.get("index", 0)))
			var width := 42.0 + posmod(variation, 3) * 4
			_canvas().draw_texture_rect(texture, Rect2(foot - Vector2(width / 2, 32), Vector2(width, 34)), false, Color("#9ed765") if bool(patch.get("mother", false)) else Color.WHITE)
	# Storage remains a world target, with a small physical crate and trough.
	var origin := _to_screen(WORLD.STORAGE_ORIGIN)
	var hay: Texture2D = ART.icon("item", "hay")
	if hay != null: _canvas().draw_texture_rect(hay, Rect2(origin + Vector2(24, 76), Vector2(48, 48)), false)
	_box(Rect2(origin + Vector2(22, 128), Vector2(100, 24)), Color("#705036"))
	_box(Rect2(origin + Vector2(26, 131), Vector2(92, 13)), Color("#e6c166") if int(model_state.get("trough_hay", 0)) > 0 else Color("#3e3027"))

func _sample_animals(values: Dictionary) -> void:
	var present := {}
	for animal in values.get("animals", []):
		var id := str(animal.id)
		present[id] = true
		var foot := Vector2(float(animal.get("x", 168)), float(animal.get("y", 184)))
		var previous: Dictionary = _animal_tracks.get(id, {})
		if previous.is_empty() or _desktop_suspended:
			_animal_tracks[id] = {"from": foot, "target": foot, "since": _animation_seconds, "duration": 0.2}
		elif (previous.target as Vector2).distance_squared_to(foot) > 0.0001:
			_animal_tracks[id] = {"from": _actor_position(previous), "target": foot, "since": _animation_seconds, "duration": 0.2}
	for id in _animal_tracks.keys():
		if not present.has(id): _animal_tracks.erase(id)

func _actor_position(track: Dictionary) -> Vector2:
	var portion := clampf((_animation_seconds - float(track.since)) / maxf(0.03, float(track.duration)), 0, 1)
	return (track.from as Vector2).lerp(track.target as Vector2, portion)

func _draw_animated() -> void:
	_fish_hits.clear()
	_animal_hits.clear()
	_animal_draws.clear()
	if not _scene_cache_ready: return
	_draw_target = _animation_layer
	var actors: Array = []
	if scene_name == "farm":
		for plot in model_state.get("plots", []):
			if not bool(plot.open) or str(plot.status) == "empty": continue
			var foot := WORLD.plot_position(int(plot.index)) + Vector2(WORLD.PLOT_SIZE / 2, WORLD.PLOT_SIZE - 4)
			actors.append({"kind": "crop", "foot": foot, "data": plot})
	elif scene_name == "ranch":
		for animal in model_state.get("animals", []):
			var foot := Vector2(float(animal.get("x", 168)), float(animal.get("y", 184)))
			var track: Dictionary = _animal_tracks.get(str(animal.id), {})
			if not track.is_empty(): foot = _actor_position(track)
			actors.append({"kind": "animal", "foot": foot, "data": animal})
	elif scene_name == "pond":
		_illustrated_water()
		for fish in model_state.get("fish", []): _illustrated_fish(fish)
	var farmer_index := 0
	for farmer in model_state.get("farmers", []):
		if str(farmer.get("scene", "")) != scene_name: continue
		var fallback: Vector2 = WORLD.farmer_idle_position(scene_name, farmer_index)
		farmer_index += 1
		var foot := Vector2(float(farmer.get("x", fallback.x)), float(farmer.get("y", fallback.y)))
		var track: Dictionary = _farmer_tracks.get(str(farmer.id), {})
		if not track.is_empty(): foot = _farmer_position(track)
		actors.append({"kind": "farmer", "foot": foot, "data": farmer, "track": track})
	actors.sort_custom(func(a, b): return (a.foot as Vector2).y < (b.foot as Vector2).y)
	for actor in actors:
		var foot := _to_screen(actor.foot).floor()
		if foot.x < -100 or foot.x > view_width + 100 or foot.y < -5 or foot.y > view_height + 100: continue
		match str(actor.kind):
			"crop": _illustrated_crop(foot, actor.data)
			"animal": _illustrated_animal(foot, actor.data)
			"farmer": _illustrated_farmer(foot, actor.data, actor.get("track", {}))
	var foreground: Texture2D = SCENE_ART.foreground(scene_name)
	if foreground != null: _canvas().draw_texture_rect(foreground, Rect2(_to_screen(Vector2.ZERO), WORLD.world_size(scene_name)), false)
	if scene_name == "farm": _draw_farm_overlay()
	elif scene_name == "ranch": _animal_tooltip()
	elif scene_name == "pond": _pond_hint()
	_draw_target = null

func _illustrated_crop(foot: Vector2, plot: Dictionary) -> void:
	var id := str(plot.crop_id)
	var crop: Dictionary = _crops.get(id, {})
	var status := str(plot.status)
	var stage := 0
	if status in ["ready", "processing"]: stage = 3
	elif status == "growing":
		var growth := 1.0 - float(plot.remaining) / maxf(1, float(crop.get("grow_seconds", 720)))
		stage = clampi(floori(growth * 4), 0, 3)
	# Wild seed crops show their actual persisted roll once it is known.
	if not (plot.get("product", {}) as Dictionary).is_empty():
		var product_id := str(plot.product.get("id", id))
		if ART.CROP_IDS.has(product_id): id = product_id
	var texture: Texture2D = SCENE_ART.crop(id, stage)
	if texture != null: _canvas().draw_texture_rect(texture, Rect2(foot - Vector2(32, 94), Vector2(64, 96)), false)
	if status == "unwatered": _draw_drop(foot + Vector2(18, -12), Color("#acddea"))
	elif status == "ready": _star(foot + Vector2(22, -34), GOLD)
	elif status == "processing":
		var remaining := clampf(1.0 - float(plot.remaining) / 180.0, 0, 1)
		_box(Rect2(foot + Vector2(-18, -1), Vector2(36, 3)), Color("#654526"))
		_box(Rect2(foot + Vector2(-18, -1), Vector2(36 * remaining, 3)), GOLD)

func _illustrated_animal(foot: Vector2, animal: Dictionary) -> void:
	var id := str(animal.type_id)
	var definition: Dictionary = _animals.get(id, {})
	var direction := str(animal.get("facing", "down"))
	var behavior := str(animal.get("behavior", "idle"))
	var moving := not (animal.get("path", []) as Array).is_empty()
	var eating := behavior == "eating"
	var frame := posmod(floori(_animation_seconds * (5 if eating else 7)), 5) if moving or eating else 0
	var size_value := 80.0 if str(definition.get("size", "small")) == "large" or id in ["cow", "goat", "sheep", "pig", "ostrich"] else 52.0
	if not bool(animal.get("adult", false)): size_value *= 0.78
	var rect := Rect2(foot - Vector2(size_value / 2, size_value - 2), Vector2(size_value, size_value))
	_canvas().draw_circle(foot + Vector2(0, -1), size_value * 0.23, Color(0.18, 0.28, 0.10, 0.15))
	var texture: Texture2D = SCENE_ART.animal(id, direction, frame, not bool(animal.get("adult", false)), eating)
	if texture != null: _canvas().draw_texture_rect(texture, rect, false)
	_animal_hits.append({"id": str(animal.id), "rect": rect.grow(-3), "animal": animal})
	_animal_draws.append({"position": foot, "animal": animal})
	if bool(animal.get("hungry", false)): _draw_drop(foot + Vector2(size_value * 0.30, -size_value * 0.75), RED)
	elif int(animal.get("ready", 0)) > 0: _star(foot + Vector2(size_value * 0.30, -size_value * 0.75), GOLD)
	if float(animal.get("feedback_remaining", 0)) > 0 or float(_feedback.get(str(animal.id), 0)) > _animation_seconds:
		var top := foot + Vector2(0, -size_value - 4 - sin(_animation_seconds * 4) * 2)
		_canvas().draw_circle(top + Vector2(-3, -2), 4, Color("#ef8e8c"))
		_canvas().draw_circle(top + Vector2(3, -2), 4, Color("#ef8e8c"))
		_canvas().draw_colored_polygon(PackedVector2Array([top + Vector2(-7, -1), top + Vector2(7, -1), top + Vector2(0, 7)]), Color("#ef8e8c"))

func _illustrated_farmer(foot: Vector2, farmer: Dictionary, track: Dictionary) -> void:
	var phase := str(farmer.get("phase", "idle"))
	var walking := phase == "walking"
	var action := str((farmer.get("task", {}) as Dictionary).get("action", "walk")) if phase == "acting" else "walk"
	var direction := str(farmer.get("facing", "down"))
	if not track.is_empty():
		var movement: Vector2 = (track.target as Vector2) - (track.from as Vector2)
		if absf(movement.x) > absf(movement.y): direction = "left" if movement.x < 0 else "right"
		elif absf(movement.y) > 0.1: direction = "up" if movement.y < 0 else "down"
	var frame := posmod(floori(_animation_seconds * 6), 4) if walking or phase == "acting" else 0
	var texture: Texture2D = SCENE_ART.farmer(action, direction, frame)
	_canvas().draw_circle(foot, 12, Color(0.18, 0.25, 0.08, 0.17))
	if texture != null: _canvas().draw_texture_rect(texture, Rect2(foot - Vector2(32, 78), Vector2(64, 80)), false)
	if str(farmer.get("mode", "")) == "resting": _label("z", foot + Vector2(24, -60), CREAM)

func _illustrated_water() -> void:
	var area: Rect2 = WORLD.water_bounds()
	for index in range(18):
		var center := _to_screen(area.position + Vector2(48 + (index * 113) % 1000, 38 + (index * 47) % 250))
		var drift := sin(_animation_seconds * 0.75 + index) * 7
		_canvas().draw_line(center + Vector2(drift, 0), center + Vector2(drift + 12, 0), Color(0.78, 0.95, 0.94, 0.34), 1)
		_canvas().draw_line(center + Vector2(drift + 3, 3), center + Vector2(drift + 8, 3), Color(0.23, 0.67, 0.77, 0.27), 1)
	if _net_dragging:
		_canvas().draw_circle(_net_previous, 18, Color(1, 0.91, 0.58, 0.16))
		_canvas().draw_arc(_net_previous, 18, 0, TAU, 16, GOLD, 1)
	elif _net_flash_until > _animation_seconds:
		_canvas().draw_arc(_net_previous, 14 + (_animation_seconds + 0.65 - _net_flash_until) * 30, 0, TAU, 20, Color(1, 0.91, 0.58, 0.6), 2)
	var level := int((model_state.get("pond", {}) as Dictionary).get("net_level", 0))
	var dock := _to_screen(WORLD.POND_DOCK)
	for index in range(level + 1):
		_canvas().draw_line(dock + Vector2(-20 + index * 5, -20), dock + Vector2(-10 + index * 5, -8), Color("#d3b776"), 1)

func _illustrated_fish(fish: Dictionary) -> void:
	var area: Rect2 = WORLD.water_bounds()
	var seed_value := absi(str(fish.id).hash())
	var phase := float(seed_value % 1000) * 0.013
	var travel := _animation_seconds * 0.08 + phase
	var x := clampf(float(fish.get("x", 0.5)) + sin(travel) * 0.07, 0.05, 0.95)
	var y := clampf(float(fish.get("y", 0.5)) + sin(travel * 0.66 + phase) * 0.035, 0.10, 0.90)
	var center := _to_screen(area.position + area.size * Vector2(x, y)).floor()
	var size_value := Vector2(46, 30)
	var rect := Rect2(center - size_value / 2, size_value)
	if not rect.intersects(Rect2(Vector2.ZERO, Vector2(view_width, view_height))): return
	var texture: Texture2D = SCENE_ART.fish(str(fish.type_id), posmod(floori(_animation_seconds * 4 + phase), 4))
	if texture != null:
		var draw_rect := rect
		if cos(travel) < 0:
			draw_rect.position.x += draw_rect.size.x
			draw_rect.size.x = -draw_rect.size.x
		_canvas().draw_texture_rect(texture, draw_rect, false, Color(0.85, 0.96, 1, 0.85))
	_fish_hits.append({"id": str(fish.id), "rect": rect})

func _pond_hint() -> void:
	var cooldown := float(model_state.get("net_remaining", 0))
	var message := "%d / %d条 · " % [(model_state.get("fish", []) as Array).size(), POND_RULES.capacity(model_state, config)]
	message += "渔网 " + _clock(cooldown) if cooldown > 0 else ("点击或拖过鱼撒网" if interactive else "观察中")
	var width := minf(320, view_width - 24)
	_box(Rect2(12, view_height - 27, width, 23), Color(0.96, 0.91, 0.74, 0.90))
	_label(message, Vector2(20, view_height - 11), INK, 12, width - 16)

func _animal_tooltip() -> void:
	if _animal_hover.is_empty(): return
	for hit in _animal_hits:
		if str(hit.id) != _animal_hover: continue
		var animal: Dictionary = hit.animal
		var definition: Dictionary = _animals.get(str(animal.type_id), {})
		var title := str(definition.get("name", animal.type_id)) + (" · 成年" if bool(animal.adult) else " · 幼年")
		var detail := "缺粮，成长与产出暂停" if bool(animal.hungry) else ("产物待收" if int(animal.ready) > 0 else "点击互动 · 每只120秒奖励冷却")
		var position_value := Vector2(clampf((hit.rect as Rect2).position.x, 8, maxf(8, view_width - 250)), 8)
		_box(Rect2(position_value, Vector2(242, 45)), Color("#f0e0b9"))
		_label(title, position_value + Vector2(8, 17), INK, 12, 226)
		_label(detail, position_value + Vector2(8, 35), MUTED, 11, 226)
		break

func _ranch_pages() -> Array:
	# Compatibility for tooling: ordinary camera pages contain nearby barns.
	var pages: Array = []
	for index in range(get_page_count()):
		var modules: Array = []
		for shelter in config.get("shelters", []):
			if floori(WORLD.shelter_position(str(shelter.id)).x / _camera_span()) == index:
				modules.append({"kind": "barn", "barn": shelter})
		pages.append(modules)
	return pages
