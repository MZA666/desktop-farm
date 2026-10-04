class_name FarmIllustratedView
extends "res://scripts/farm_view.gd"

## Illustrated terrain is cached; live plants and actors share foot-depth order.
## All model coordinates stay in the world when the camera or height changes.
signal animal_clicked(instance_id: String)
signal shelter_clicked(shelter_id: String)
const SCENE_ART = preload("res://scripts/scene_assets.gd")
const POND_RULES = preload("res://scripts/pond_rules.gd")
const CAMERA_BUTTON_STEP := 32.0
const CAMERA_WHEEL_STEP := 16.0
var camera_y := 170.0
# Remember the world point being viewed, so changing the strip height does
# not change the chosen subject. All three scenes initially face mid-height.
var _scene_camera := {"farm": 256.0, "ranch": 256.0, "pond": 256.0}
var _animal_hits: Array = []
var _animal_tracks: Dictionary = {}
var _feedback: Dictionary = {}
var _panning := false
var _pan_mouse := Vector2.ZERO
var _pan_origin := Vector2.ZERO
var _ranch_visual_key := -1
var _animal_hover := ""
var _net_flash_until := 0.0
var _fish_tracks: Dictionary = {}
var _last_fish_sample := -1.0
var _gait_tracks: Dictionary = {}
var _shelter_hits: Array = []
var _shelter_hover := ""
var _shelter_counts: Dictionary = {}
var _product_draws: Array = []
var _crop_hits: Array = []
var _crop_hit_key := 0
# One bit per original atlas pixel, at most 64 crops x four stages (~192KiB).
# Images are read once to build these masks and are never retained by the view.
var _crop_masks: Dictionary = {}
const SHELTER_PORTRAITS := ["chicken", "duck", "rabbit", "cow", "goat", "sheep", "pig"]
# Measured on the baked painting: barn art is not equally spaced like the
# simulation exits. Labels belong to gables, not to animal world coordinates.
const SHELTER_SIGN_ANCHORS := [Vector2(216,72), Vector2(426,48), Vector2(682,66), Vector2(954,44), Vector2(1206,70), Vector2(1498,58), Vector2(1746,74)]

func _ready() -> void:
	super._ready()
	_invalidate_scene()

func set_model(values: Dictionary, force := false) -> void:
	_sample_animals(values)
	_sample_fish(values)
	_shelter_counts.clear()
	for animal in values.get("animals", []):
		var sid := str(animal.get("shelter_id", WORLD.ANIMAL_SHELTERS.get(str(animal.type_id), "")))
		if not _shelter_counts.has(sid): _shelter_counts[sid] = {"total": 0, "kinds": {}}
		var entry: Dictionary = _shelter_counts[sid]
		entry.total = int(entry.total) + 1
		entry.kinds[str(animal.type_id)] = int(entry.kinds.get(str(animal.type_id), 0)) + 1
	super.set_model(values, force)
	var visual_key := hash([values.get("grass", []), values.get("shelters", {}), values.get("pond", {}), values.get("storage_level", 0), values.get("trough_hay", 0), values.get("warehouse_hay", 0)])
	if scene_name != "farm" and visual_key != _ranch_visual_key:
		_ranch_visual_key = visual_key
		_invalidate_scene()

func set_scene(value: String) -> void:
	super.set_scene(value)
	camera_y = float(_scene_camera.get(scene_name, WORLD.world_size(scene_name).y * 0.5)) - view_height * 0.5
	_animal_hits.clear()
	_animal_hover = ""
	_shelter_hover = ""
	_fish_tracks.clear()
	_crop_hits.clear()
	_update_camera()
	_invalidate_scene()

func resize_view(size: Vector2) -> void:
	# Retain the desired center even if a taller viewport cannot center there.
	# Returning to compact mode can then recover the previously chosen edge.
	var center_y := float(_scene_camera.get(scene_name, camera_y + view_height * 0.5))
	view_width = maxf(240.0, size.x)
	view_height = maxf(32.0, size.y)
	camera_y = center_y - view_height * 0.5
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

func _to_world(screen_position: Vector2) -> Vector2:
	return screen_position - _to_screen(Vector2.ZERO)

func cancel_gestures() -> void:
	super.cancel_gestures()
	_panning = false

func _camera_span() -> float:
	return view_width if view_width >= WORLD.world_size(scene_name).x else maxf(192.0, view_width - 48.0)

func camera_up() -> void:
	camera_scroll(-CAMERA_BUTTON_STEP)

func camera_down() -> void:
	camera_scroll(CAMERA_BUTTON_STEP)

func camera_scroll(pixels: float) -> void:
	camera_y += pixels
	_update_camera()
	_scene_camera[scene_name] = camera_y + view_height * 0.5
	_invalidate_scene()

func camera_center() -> void:
	camera_y = (WORLD.world_size(scene_name).y - view_height) * 0.5
	_update_camera()
	_scene_camera[scene_name] = camera_y + view_height * 0.5
	_invalidate_scene()

func focus_world(position_value: Vector2) -> void:
	page = clampi(floori(position_value.x / _camera_span()), 0, get_page_count() - 1)
	_scene_camera[scene_name] = position_value.y
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
	_shelter_hover = ""
	if interactive and scene_name == "ranch":
		var mouse := get_local_mouse_position()
		if _hay_hud_rect().has_point(mouse): return
		for hit in _shelter_hits:
			if (hit.rect as Rect2).has_point(mouse): _shelter_hover = str(hit.id); break
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
		_scene_camera[scene_name] = camera_y + view_height * 0.5
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
				else:
					var direction := -1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
					camera_scroll(direction * CAMERA_WHEEL_STEP * maxf(0.0, event.factor))
				get_viewport().set_input_as_handled()
				return
			if scene_name == "ranch" and event.button_index == MOUSE_BUTTON_LEFT:
				if _hay_hud_rect().has_point(mouse):
					get_viewport().set_input_as_handled()
					return
				for hit in _shelter_hits:
					if (hit.rect as Rect2).has_point(mouse):
						shelter_clicked.emit(str(hit.id))
						get_viewport().set_input_as_handled()
						return
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
		_draw_margin_seams()
	match scene_name:
		"farm": _illustrated_soil()
		"ranch": _illustrated_grass()
		"pond": _pond_bounds = Rect2(_to_screen(WORLD.water_bounds().position), WORLD.water_bounds().size)
	_draw_target = null
	_static_bake_count += 1
	_scene_cache_ready = true
	_redraw_animation()

func _draw_woodland_margins(_background: Texture2D) -> void:
	# One continuous independent panorama per margin. Never replicate strips
	# of the playable painting (which contain coops, boats and fences).
	var left := _to_screen(Vector2.ZERO).x
	var right := left + WORLD.world_size(scene_name).x
	var forest: Texture2D = SCENE_ART.border("farm")
	if forest == null: return
	var height := minf(view_height, forest.get_height() - camera_y)
	if left > 0:
		var span := minf(left, forest.get_width()-48)
		_canvas().draw_texture_rect_region(forest, Rect2(0,0,left,height), Rect2(forest.get_width()-span-48,camera_y,span,height))
	if right < view_width:
		var width := view_width - right
		if scene_name == "pond":
			var shore: Texture2D = SCENE_ART.border("pond")
			var half := shore.get_width() * 0.5
			var span := minf(width, half-48)
			_canvas().draw_texture_rect_region(shore, Rect2(right,0,span,height), Rect2(half+48,camera_y,span,height))
			if width > span:
				_canvas().draw_texture_rect_region(forest, Rect2(right+span,0,width-span,height), Rect2(0,camera_y,minf(width-span,forest.get_width()),height))
		else:
			_canvas().draw_texture_rect_region(forest, Rect2(right,0,width,height), Rect2(48,camera_y,minf(width,forest.get_width()-48),height))

func _draw_margin_seams() -> void:
	# Crossfade only the decorative outside edges. The soil and navigable
	# water remain the original painting with their measured world boundaries.
	var left := _to_screen(Vector2.ZERO).x
	var right := left+WORLD.world_size(scene_name).x
	var forest: Texture2D = SCENE_ART.border("farm")
	var height := minf(view_height,forest.get_height()-camera_y)
	for column in range(48):
		if left > 0:
			_canvas().draw_texture_rect_region(forest,Rect2(left+column,0,1,height),Rect2(forest.get_width()-48+column,camera_y,1,height),Color(1,1,1,1.0-float(column)/47))
		if right < view_width:
			var texture: Texture2D = SCENE_ART.border("pond") if scene_name == "pond" else forest
			var source_x := texture.get_width()*0.5 if scene_name == "pond" else 0.0
			_canvas().draw_texture_rect_region(texture,Rect2(right-48+column,0,1,height),Rect2(source_x+column,camera_y,1,height),Color(1,1,1,float(column)/47))

func _illustrated_soil() -> void:
	for plot in model_state.get("plots", []):
		var index := int(plot.get("index", 0))
		var world_bounds: Rect2 = WORLD.plot_rect(index)
		var bounds := Rect2(_to_screen(world_bounds.position), world_bounds.size)
		if not bounds.intersects(Rect2(Vector2.ZERO, Vector2(view_width, view_height))): continue
		_plot_hits.append({"rect": bounds, "id": str(plot.id), "open": bool(plot.open), "index": index})
		if not bool(plot.open):
			# Fallow land is textured ground from the plate, without boxed tiles.
			continue
		var wet := str(plot.status) in ["growing", "ready", "processing"]
		_canvas().draw_rect(bounds.grow(-1), Color(0.20, 0.09, 0.025, 0.32 if wet else 0.14))
		# Small connected ridges let planted land remain part of natural soil.
		for row in range(3):
			var yy := bounds.position.y + floorf(bounds.size.y * float(row + 1) / 4.0)
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
	_box(Rect2(origin + Vector2(26, 131), Vector2(92, 13)), Color("#3e3027"))
	var stock := hay_summary()
	_box(Rect2(origin + Vector2(26, 131), Vector2(floorf(92.0 * stock.trough / maxf(1, stock.capacity)), 13)), Color("#e6c166"))

func hay_summary() -> Dictionary:
	var levels: Array = (config.get("upgrades", {}) as Dictionary).get("hay_storage", [])
	var level := clampi(int(model_state.get("storage_level", 0)), 0, maxi(0, levels.size() - 1))
	var capacity := int(levels[level].capacity) if not levels.is_empty() else 24
	return {"warehouse": int(model_state.get("warehouse_hay", 0)), "trough": int(model_state.get("trough_hay", 0)), "capacity": capacity}

func _hay_hud_rect() -> Rect2:
	return Rect2(10, maxf(8, view_height - 58), 284, 50)

func _draw_hay_hud() -> void:
	# Screen-fixed: stock stays readable on every ranch page and camera height.
	var bounds := _hay_hud_rect()
	var stock := hay_summary()
	_box(bounds, Color("#60412a"))
	_box(bounds.grow(-2), Color("#ffebbc"))
	var hay: Texture2D = ART.icon("item", "hay")
	for row in range(2):
		var amount := int(stock.warehouse) if row == 0 else int(stock.trough)
		var origin := bounds.position + Vector2(8, 4 + row * 23)
		if hay != null: _canvas().draw_texture_rect(hay, Rect2(origin, Vector2(20, 20)), false)
		_label("%s %d / %d" % ["草仓" if row == 0 else "食槽", amount, int(stock.capacity)], origin + Vector2(26, 15), INK, 13, 146)
		_box(Rect2(origin + Vector2(166, 6), Vector2(98, 9)), Color("#c4af85"))
		_box(Rect2(origin + Vector2(167, 7), Vector2(floorf(96.0 * clampf(float(amount) / maxf(1, stock.capacity), 0, 1)), 7)), Color("#b88e3f"))
	if interactive and bounds.has_point(get_local_mouse_position()):
		var tip := Rect2(bounds.position - Vector2(0, 25), Vector2(284, 23))
		_box(tip, CREAM)
		_label("农夫把草仓干草搬入食槽，供动物食用", tip.position + Vector2(6, 16), INK, 12, 272)

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
	_shelter_hits.clear()
	_product_draws.clear()
	_animal_draws.clear()
	_crop_hits.clear()
	if not _scene_cache_ready: return
	_draw_target = _animation_layer
	var actors: Array = []
	if scene_name == "farm":
		for plot in model_state.get("plots", []):
			if not bool(plot.open) or str(plot.status) == "empty": continue
			var foot := WORLD.plot_crop_anchor(int(plot.index))
			actors.append({"kind": "crop", "foot": foot, "data": plot})
	elif scene_name == "ranch":
		for pile in model_state.get("ground_products", []):
			actors.append({"kind": "product", "foot": Vector2(float(pile.x), float(pile.y)), "data": pile})
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
			"product": _illustrated_product(foot, actor.data)
			"farmer": _illustrated_farmer(foot, actor.data, actor.get("track", {}), actor.foot)
	if scene_name == "farm":
		var hit_key := hash([page, view_width, view_height, camera_y, _crop_hits])
		if hit_key != _crop_hit_key:
			_crop_hit_key = hit_key
			# Re-evaluate a stationary pointer after a camera move or a changed
			# crop silhouette; otherwise the tooltip keeps the previous plot.
			_last_mouse = Vector2(INF, INF)
	var foreground: Texture2D = SCENE_ART.foreground(scene_name)
	if foreground != null: _canvas().draw_texture_rect(foreground, Rect2(_to_screen(Vector2.ZERO), WORLD.world_size(scene_name)), false)
	if scene_name == "farm": _draw_farm_overlay()
	elif scene_name == "ranch":
		_draw_shelter_signs()
		if not _shelter_hover.is_empty(): _shelter_tooltip()
		else: _animal_tooltip()
		_draw_hay_hud()
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
	if texture != null:
		var rect := Rect2(foot - Vector2(26, 76), Vector2(52, 78))
		_canvas().draw_texture_rect(texture, rect, false)
		var mask := _crop_mask(id, stage, texture)
		if mask != null:
			_crop_hits.append({"id": str(plot.id), "index": int(plot.index), "rect": rect, "mask": mask})
	if status == "unwatered": _draw_drop(foot + Vector2(18, -12), Color("#acddea"))
	elif status == "ready": _star(foot + Vector2(22, -34), GOLD)
	elif status == "processing":
		var remaining := clampf(1.0 - float(plot.remaining) / 180.0, 0, 1)
		_box(Rect2(foot + Vector2(-18, -1), Vector2(36, 3)), Color("#654526"))
		_box(Rect2(foot + Vector2(-18, -1), Vector2(36 * remaining, 3)), GOLD)

func _crop_mask(id: String, stage: int, texture: Texture2D) -> BitMap:
	var key := "%s/%d" % [id, stage]
	if _crop_masks.has(key): return _crop_masks[key] as BitMap
	var pixels := texture.get_image()
	if pixels == null or pixels.is_empty(): return null
	var mask := BitMap.new()
	mask.create_from_image_alpha(pixels, 0.1)
	_crop_masks[key] = mask
	return mask

func _plot_at(point: Vector2) -> Dictionary:
	if scene_name != "farm": return super._plot_at(point)
	if not _scene_cache_ready or not Rect2(Vector2.ZERO, Vector2(view_width, view_height)).has_point(point): return {}
	# The records follow the actual crop draw order, so the last opaque pixel
	# wins. A transparent border reveals the crop/soil behind it. Box selection
	# still uses the original ground rectangles in _finish_farm_gesture.
	for offset in range(_crop_hits.size() - 1, -1, -1):
		var hit: Dictionary = _crop_hits[offset]
		var rect: Rect2 = hit.rect
		if not rect.has_point(point): continue
		var mask: BitMap = hit.mask
		var pixel := Vector2i(((point - rect.position) / rect.size * Vector2(mask.get_size())).floor())
		if not mask.get_bitv(pixel): continue
		var soil: Rect2 = WORLD.plot_rect(int(hit.index))
		return {"id": str(hit.id), "index": int(hit.index), "open": true, "rect": Rect2(_to_screen(soil.position), soil.size)}
	return super._plot_at(point)

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
	if float(animal.get("feedback_remaining", 0)) > 0 or float(_feedback.get(str(animal.id), 0)) > _animation_seconds:
		var top := foot + Vector2(0, -size_value - 4 - sin(_animation_seconds * 4) * 2)
		_canvas().draw_circle(top + Vector2(-3, -2), 4, Color("#ef8e8c"))
		_canvas().draw_circle(top + Vector2(3, -2), 4, Color("#ef8e8c"))
		_canvas().draw_colored_polygon(PackedVector2Array([top + Vector2(-7, -1), top + Vector2(7, -1), top + Vector2(0, 7)]), Color("#ef8e8c"))

func _illustrated_farmer(foot: Vector2, farmer: Dictionary, track: Dictionary, world_foot: Vector2) -> void:
	var phase := str(farmer.get("phase", "idle"))
	# Rendering trails the fixed simulation step slightly. Finish the visible
	# approach before playing the action, and measure stride in world pixels:
	# scrolling the camera must never advance a stationary farmer's legs.
	var walking := phase == "walking" or (not track.is_empty() and world_foot.distance_to(track.target) > 0.15)
	var action := str((farmer.get("task", {}) as Dictionary).get("action", "walk")) if phase == "acting" and not walking else "walk"
	var direction := str(farmer.get("facing", "down"))
	if walking and not track.is_empty():
		var movement: Vector2 = (track.target as Vector2) - (track.from as Vector2)
		if absf(movement.x) > absf(movement.y): direction = "left" if movement.x < 0 else "right"
		elif absf(movement.y) > 0.1: direction = "up" if movement.y < 0 else "down"
	var id := str(farmer.id)
	var gait: Dictionary = _gait_tracks.get(id, {"foot": world_foot, "distance": 0.0})
	if walking:
		gait.distance = float(gait.distance) + (gait.foot as Vector2).distance_to(world_foot)
	else: gait.distance = 0.0
	gait.foot = world_foot
	_gait_tracks[id] = gait
	var count: int = SCENE_ART.farmer_frame_count(action)
	var neutral := 6 if direction == "up" else 2
	var frame := posmod(floori(float(gait.distance) / 3.0), count) if walking else (posmod(floori(_animation_seconds * 4), count) if phase == "acting" else neutral)
	gait.frame = frame
	gait.walking = walking
	var texture: Texture2D = SCENE_ART.farmer(action, direction, frame)
	_canvas().draw_circle(foot, 12, Color(0.18, 0.25, 0.08, 0.17))
	if texture != null: _canvas().draw_texture_rect(texture, Rect2(foot - Vector2(32, 78), Vector2(64, 80)), false)
	if str(farmer.get("mode", "")) == "resting": _label("z", foot + Vector2(24, -60), CREAM)

func _illustrated_product(foot: Vector2, pile: Dictionary) -> void:
	_product_draws.append({"id":str(pile.id),"foot":foot,"quantity":int(pile.quantity)})
	var texture: Texture2D = ART.icon("item", str(pile.product_id))
	_canvas().draw_circle(foot, 10, Color(0.18,0.25,0.08,0.20))
	if texture != null: _canvas().draw_texture_rect(texture, Rect2(foot-Vector2(14,24),Vector2(28,28)),false)
	if int(pile.quantity) > 1:
		var label_text := str(int(pile.quantity))
		var width := maxf(20, label_text.length()*7+6)
		_box(Rect2(foot+Vector2(5,-4),Vector2(width,14)),Color("#68472d"))
		_label(label_text,foot+Vector2(8,7),CREAM,10,width-4)

func _draw_shelter_signs() -> void:
	var shelters: Array = config.get("shelters", [])
	for index in range(mini(7,shelters.size())):
		var definition: Dictionary = shelters[index]
		var sid := str(definition.id)
		var level := int((model_state.get("shelters",{}) as Dictionary).get(sid,0))
		var count: Dictionary = _shelter_counts.get(sid,{"total":0,"kinds":{}})
		var anchor := _to_screen(SHELTER_SIGN_ANCHORS[index])
		var rect := Rect2(anchor-Vector2(36,14),Vector2(72,28))
		if not rect.intersects(Rect2(Vector2.ZERO,Vector2(view_width,view_height))): continue
		_box(rect,Color("#674327"))
		_box(rect.grow(-2),Color("#dca75e") if level > 0 else Color("#ada084"))
		var portrait: Texture2D = SCENE_ART.portrait(SHELTER_PORTRAITS[index])
		if portrait != null: _canvas().draw_texture_rect(portrait,Rect2(rect.position+Vector2(3,2),Vector2(24,24)),false,Color.WHITE if level>0 else Color(0.65,0.65,0.65))
		var capacity := int((definition.get("capacities",[]) as Array)[level-1]) if level>0 else 0
		if level > 0: _label("%d/%d" % [int(count.total),capacity],rect.position+Vector2(29,19),INK,12,40)
		else:
			_canvas().draw_arc(rect.position+Vector2(44,10),4,PI,TAU,8,INK,2)
			_box(Rect2(rect.position+Vector2(39,10),Vector2(10,9)),INK)
		var extras := 0
		for kind in ["void_chicken","golden_chicken","dinosaur","ostrich"]:
			if not (count.kinds as Dictionary).has(kind): continue
			var badge: Texture2D = SCENE_ART.portrait(kind)
			if badge != null: _canvas().draw_texture_rect(badge,Rect2(rect.end+Vector2(-20-extras*19,0),Vector2(18,18)),false)
			extras += 1
		_shelter_hits.append({"id":sid,"rect":rect,"definition":definition,"count":count,"level":level})

func _shelter_tooltip() -> void:
	for hit in _shelter_hits:
		if str(hit.id) != _shelter_hover: continue
		var names := PackedStringArray()
		for kind in (hit.count.kinds as Dictionary): names.append("%s %d" % [str(_animals.get(kind,{}).get("name",kind)),int(hit.count.kinds[kind])])
		var text := "点击建设扩展" if int(hit.level)==0 else (" · ".join(names) if not names.is_empty() else "尚未购买动物")
		var origin := Vector2(clampf((hit.rect as Rect2).position.x,8,maxf(8,view_width-300)),minf(view_height-52,(hit.rect as Rect2).end.y+22))
		_box(Rect2(origin,Vector2(292,47)),Color("#f0e0b9"))
		_label("%s · %d级" % [str(hit.definition.name),int(hit.level)],origin+Vector2(8,17),INK,12,276)
		_label(text,origin+Vector2(8,36),MUTED,11,276)
		return

func _illustrated_water() -> void:
	var area: Rect2 = WORLD.water_bounds()
	for index in range(18):
		var center := _to_screen(area.position + Vector2(48 + (index * 113) % 1000, 38 + (index * 47) % 250))
		if not WORLD.water_contains(_to_world(center)) or not WORLD.water_contains(_to_world(center+Vector2(20,3))): continue
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
	var seed_value := absi(str(fish.id).hash())
	var phase := float(seed_value % 1000) * 0.013
	var world_center: Vector2 = WORLD.fish_visual_position(fish)
	var track: Dictionary = _fish_tracks.get(str(fish.id),{})
	if not track.is_empty(): world_center = _fish_position(track)
	var center := _to_screen(world_center)
	var size_value := Vector2(46, 30)
	var rect := Rect2(center - size_value / 2, size_value)
	if not rect.intersects(Rect2(Vector2.ZERO, Vector2(view_width, view_height))): return
	var texture: Texture2D = SCENE_ART.fish(str(fish.type_id), posmod(floori(_animation_seconds * 4 + phase), 4))
	if texture != null:
		var draw_rect := rect
		if cos(float(fish.get("heading",0))) < 0:
			draw_rect.position.x += draw_rect.size.x
			draw_rect.size.x = -draw_rect.size.x
		_canvas().draw_texture_rect(texture, draw_rect, false, Color(0.85, 0.96, 1, 0.85))
	_fish_hits.append({"id": str(fish.id), "rect": rect})

func _sample_fish(values: Dictionary) -> void:
	var sample_time := float(values.get("elapsed",0))
	var duration := clampf(sample_time-_last_fish_sample,1.0/30.0,1.0)
	if sample_time < _last_fish_sample: _fish_tracks.clear()
	_last_fish_sample = sample_time
	var present := {}
	for fish in values.get("fish",[]):
		var id := str(fish.id)
		present[id] = true
		var point: Vector2 = WORLD.fish_visual_position(fish)
		var previous: Dictionary = _fish_tracks.get(id,{})
		if previous.is_empty() or _desktop_suspended:
			_fish_tracks[id] = {"from":point,"target":point,"since":_animation_seconds,"duration":duration,"via":point}
		elif (previous.target as Vector2).distance_squared_to(point)>0.000001:
			var from := _fish_position(previous)
			var via := from if WORLD.fish_segment_safe(from,point) else (previous.target as Vector2)
			# A delayed UI sample can span several simulation turns. Never join
			# those endpoints across a shore; resume the last verified model leg.
			if not WORLD.fish_segment_safe(from,via) or not WORLD.fish_segment_safe(via,point):
				from = Vector2(float(fish.previous_x),float(fish.previous_y))
				via = from
			_fish_tracks[id] = {"from":from,"target":point,"since":_animation_seconds,"duration":duration,"via":via}
	for id in _fish_tracks.keys():
		if not present.has(id): _fish_tracks.erase(id)

func _fish_position(track: Dictionary) -> Vector2:
	var from: Vector2 = track.from
	var via: Vector2 = track.via
	var target: Vector2 = track.target
	var first := from.distance_to(via)
	var total := first + via.distance_to(target)
	if total<0.000001: return target
	var distance := clampf((_animation_seconds-float(track.since))/maxf(0.03,float(track.duration)),0,1)*total
	return from.move_toward(via,distance) if distance<first else via.move_toward(target,distance-first)

func _water_input_contains(point: Vector2) -> bool:
	return WORLD.water_contains(_to_world(point))

func _track_net(point: Vector2) -> void:
	if _net_candidate.is_empty():
		var start := _to_world(_net_previous)
		var finish := _to_world(point)
		for interval in WORLD.net_segment_intervals(start,finish):
			var safe_start := _to_screen(start.lerp(finish,interval.x))
			var safe_finish := _to_screen(start.lerp(finish,interval.y))
			for hit in _fish_hits:
				if _segment_hits_rect(safe_start,safe_finish,hit.rect):
					_net_candidate = str(hit.id)
					break
			if not _net_candidate.is_empty(): break
	_net_previous = point

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
		var detail := "缺粮，成长与产出暂停" if bool(animal.hungry) else "点击互动 · 每只120秒奖励冷却"
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
