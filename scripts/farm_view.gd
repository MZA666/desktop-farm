class_name FarmView
extends Node2D

## One visible, lightweight pixel-art renderer. All productive state belongs
## to FarmState; animation offsets are cosmetic and never mutate the model.
signal plot_clicked(plot_id: String)
signal plots_selected(ids: Array)
signal locked_plot_clicked(plot_id: String)
signal fish_clicked(fish_id: String)
const ART = preload("res://scripts/pixel_assets.gd")
const WORLD = preload("res://scripts/world_layout.gd")

var model_state: Dictionary = {}
var config: Dictionary = {}
var scene_name := "farm"
var interactive := true
var view_width := 1920.0
var view_height := 172.0
var page := 0
var camera_offset := 0.0
var selection_mode := false
var selected_plot_ids: Array = []
var seed_preview_provider := Callable()

const INK := Color("#54382d")
const MUTED := Color("#6d6141")
const CREAM := Color("#ffebbc")
const GRASS := Color("#87ae45")
const GRASS_LIGHT := Color("#acd15b")
const GRASS_DARK := Color("#628a37")
const SOIL := Color("#bb7c45")
const SOIL_DARK := Color("#875135")
const WATER := Color("#489fbe")
const WATER_LIGHT := Color("#92d3d5")
const GOLD := Color("#ffd36c")
const RED := Color("#c65640")
const ANIMAL_SHADOW := Color("#6f943f")

const SPROUT := ["....gg....", "...lggg...", ".ggggggg..", "..gggggg..", "....s.....", "....s.....", "...sss...."]
const LEAF_CROP := ["....ll....", "..lggggl..", ".lggggggl.", ".gglgglgg.", "..gggggg..", "...gssg...", "....ss...."]
const ROOT_CROP := ["..gg..gg..", "...gggg...", "....gg....", "...pppp...", "..pppppp..", "...pppp...", "....pp....", "....p....."]
const FLOWER := ["....pp....", "...pyyp...", "..ppyypp..", "...pppp...", "....ss....", "..ggssgg..", "...gssg...", "....ss...."]
const BUSH := ["...gggg...", "..ggpggg..", ".gggggpgg.", ".gpgggggg.", "..gggpgg..", "...gggg...", "....ss....", "...ssss..."]
const WHEAT := ["..y...y...", "..yy..yy..", "..sy..sy..", ".yss.yss..", "..ss..ss..", "...ssss...", "....ss....", "....ss...."]
const FARMER := ["....hhhh....", "...hhhhhh...", "..hhhhhhhh..", "....ffff....", "....fkff....", "....ffff....", "...bbbbbb...", "..fbbbbbbf..", "..fbbbbbbf..", "...bbbbbb...", "....dd.dd...", "....dd.dd...", "...kkk.kkk.."]
const CHICKEN := ["....rr....", "...ffff...", "..ffkffy..", "..ffffff..", ".ffffffff.", ".fffffff..", "..fffff...", "...o.o....", "...o.o...."]
const DUCK := ["....ggg...", "...ggkgy..", "...ggggy..", "..ffffffff", ".ffffffff.", "..ffffff..", "...ffff...", "....o.o...", "....o.o..."]
const RABBIT := ["..ff..ff..", "..ff..ff..", "..ff..ff..", "...ffff...", "..ffkffk..", "..ffffff..", ".ffffffff.", "..ffffff..", "...ff.ff.."]
const COW := [".ss....ss.", "..fffffff.", ".ffkffkff.", "..ffffff..", "...pppp...", ".ffffffff.", ".ffssffff.", ".ffffssff.", "..f.f.f.f."]
const SHEEP := ["..fffffff.", ".fffffffff", ".ffffsfff.", ".ffsskss..", "..fsssss..", ".ffffff...", ".ffffff...", "..s.s.s..."]
const PIG := ["..pp..pp..", "...ppppp..", "..pkppkp..", "..pppppp..", "...oooo...", ".pppppppp.", ".pppppppp.", "..pppppp..", "..p.p.p.p."]
const FISH := [".....llll....", "...lfffffl...", ".llfffffkff..", "lllfffffffff.", ".llffffffff..", "...lfffffl...", ".....llll...."]

var _font := SystemFont.new()
var _crops: Dictionary = {}
var _animals: Dictionary = {}
var _fish_types: Dictionary = {}
var _plot_hits: Array = []
var _fish_hits: Array = []
var _target_positions: Dictionary = {}
var _animation_seconds := 0.0
var _frame_accumulator := 0.0
var _hover := ""
var _last_mouse := Vector2(-100, -100)
var _pond_bounds := Rect2()
var _sprite_cache: Dictionary = {}
var _net_dragging := false
var _net_previous := Vector2.ZERO
var _net_candidate := ""
var _animation_layer: Node2D
var _draw_target: CanvasItem
var _animal_draws: Array = []
var _scene_cache_ready := false
var _desktop_suspended := false
var _last_static_second := -1
var _farmer_tracks: Dictionary = {}
var _static_viewport: SubViewport
var _static_layer: Node2D
var _static_bake_count := 0
var _static_layout_key := ""
var _farm_visual_key := -1
var _terrain_visual_key := -1
var _plots_by_id: Dictionary = {}
var _farm_dragging := false
var _farm_drag_start := Vector2.ZERO
var _farm_drag_end := Vector2.ZERO
var _farm_press_hit: Dictionary = {}
var _farm_shift := false
var _last_farmer_sample := -1.0
var _seed_preview_cache: Dictionary = {}

func _ready() -> void:
	# Respect the controller's shared SystemFont. Changing its name list reloads
	# a second system font file and defeats sharing between scenery and menus.
	if _font.font_names.is_empty():
		_font.font_names = PackedStringArray(["Microsoft YaHei", "微软雅黑", "sans-serif"])
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Rasterize ground, buildings and text only on invalidation. Godot caches
	# CanvasItem commands, but submitting that long static list every OpenGL
	# frame is still expensive; the scene now samples one small strip texture.
	_static_viewport = SubViewport.new()
	_static_viewport.name = "StaticSceneryCache"
	_static_viewport.disable_3d = true
	_static_viewport.transparent_bg = true
	_static_viewport.gui_disable_input = true
	_static_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_static_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_static_viewport.size = _cache_pixel_size()
	add_child(_static_viewport)
	_static_layer = Node2D.new()
	_static_layer.name = "StaticScenery"
	_static_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_static_layer.draw.connect(_draw_static)
	_static_viewport.add_child(_static_layer)
	_static_layer.set_process(false)
	# Only the actor child's draw list is rebuilt at the animation rate.
	_animation_layer = Node2D.new()
	_animation_layer.name = "AnimatedActors"
	_animation_layer.draw.connect(_draw_animated)
	add_child(_animation_layer)
	_animation_layer.set_process(false)
	set_process(true)
	_invalidate_scene()

func configure(values: Dictionary) -> void:
	config = values
	_crops = _index(config.get("crops", []))
	_animals = _index(config.get("animals", []))
	_fish_types = _index(config.get("fish", []))
	_invalidate_scene()

func set_model(values: Dictionary, force := false) -> void:
	model_state = values
	_seed_preview_cache.clear()
	_plots_by_id.clear()
	for plot in values.get("plots", []): _plots_by_id[str(plot.get("id", ""))] = plot
	_sample_farmers(values)
	var second := int(floor(float(values.get("elapsed", 0))))
	var visual_key := _farm_state_key() if scene_name == "farm" else _farm_visual_key
	var terrain_key := _terrain_state_key(visual_key) if scene_name == "farm" else _terrain_visual_key
	var needs_update := terrain_key != _terrain_visual_key if scene_name == "farm" else second != _last_static_second
	_farm_visual_key = visual_key
	_terrain_visual_key = terrain_key
	if force or needs_update:
		_last_static_second = second
		_invalidate_scene()
	else:
		_redraw_animation()

func set_selection(ids: Array) -> void:
	selected_plot_ids = []
	for id in ids:
		var key := str(id)
		if _plots_by_id.has(key) and bool(_plots_by_id[key].get("open", false)) and not selected_plot_ids.has(key):
			selected_plot_ids.append(key)
	_redraw_animation()

func set_desktop_suspended(enabled: bool) -> void:
	_desktop_suspended = enabled
	set_process(not enabled)
	if is_instance_valid(_animation_layer): _animation_layer.visible = not enabled
	if enabled and is_instance_valid(_static_viewport):
		_static_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if not enabled: _invalidate_scene()

func set_scene(value: String) -> void:
	if value not in ["farm", "ranch", "pond"]:
		return
	scene_name = value
	_farmer_tracks.clear()
	_net_dragging = false
	_farm_dragging = false
	page = 0
	_hover = ""
	_plot_hits.clear()
	_fish_hits.clear()
	_invalidate_scene()

func resize_view(size: Vector2) -> void:
	view_width = maxf(240.0, size.x)
	view_height = maxf(172.0, size.y)
	page = clampi(page, 0, get_page_count() - 1)
	_invalidate_scene()

func set_interactive(value: bool) -> void:
	interactive = value
	_net_dragging = false
	_farm_dragging = false
	_hover = ""
	_invalidate_scene()

func page_next() -> void:
	page = mini(page + 1, get_page_count() - 1)
	_farmer_tracks.clear()
	_invalidate_scene()

func page_previous() -> void:
	page = maxi(0, page - 1)
	_farmer_tracks.clear()
	_invalidate_scene()

func _invalidate_scene() -> void:
	# set_model is called at the controller's UI cadence, or immediately after
	# a transaction. It refreshes crop stages/countdowns and actor placement.
	_scene_cache_ready = false
	if _desktop_suspended: return
	_request_static_bake()
	queue_redraw()
	_redraw_animation()

func _cache_pixel_size() -> Vector2i:
	return Vector2i(maxi(1, ceili(view_width)), maxi(1, ceili(view_height)))

func _static_key() -> String:
	return "%s/%d/%d/%d/%s" % [scene_name, page, ceili(view_width), ceili(view_height), "" if scene_name == "farm" else _hover]

func _request_static_bake() -> void:
	if _desktop_suspended or not is_instance_valid(_static_viewport): return
	var requested_size := _cache_pixel_size()
	if _static_viewport.size != requested_size: _static_viewport.size = requested_size
	_static_layout_key = _static_key()
	_static_layer.queue_redraw()
	_static_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _redraw_animation() -> void:
	if is_instance_valid(_animation_layer):
		_animation_layer.queue_redraw()

func get_page_count() -> int:
	return maxi(1, ceili(WORLD.world_size(scene_name).x / _camera_span()))

func _camera_span() -> float:
	return maxf(192.0, view_width - 48.0)

func _update_camera() -> void:
	page = clampi(page, 0, get_page_count() - 1)
	camera_offset = minf(page * _camera_span(), maxf(0.0, WORLD.world_size(scene_name).x - _camera_span()))

func _to_screen(world_position: Vector2) -> Vector2:
	return world_position + Vector2(24.0 - camera_offset, 0)

func _farm_state_key() -> int:
	var parts: Array = []
	for plot in model_state.get("plots", []):
		var status := str(plot.get("status", "empty"))
		var crop: Dictionary = _crops.get(str(plot.get("crop_id", "")), {})
		var growth := 1.0 - float(plot.get("remaining", 0)) / maxf(1.0, float(crop.get("grow_seconds", 720)))
		var stage := clampi(floori(growth * 4), 0, 3)
		var processing_step := floori((1.0 - float(plot.get("remaining", 0)) / 180.0) * 8) if status == "processing" else 0
		parts.append([plot.get("id", ""), plot.get("index", 0), plot.get("open", false), plot.get("crop_id", ""), (plot.get("product", {}) as Dictionary).get("id", ""), status, stage if status == "growing" else 0, processing_step])
	return hash(parts)

func _terrain_state_key(visual_key: int) -> int:
	return visual_key

func _index(entries: Variant) -> Dictionary:
	if entries is Dictionary:
		return entries
	var output := {}
	for entry in entries:
		output[str(entry.get("id", ""))] = entry
	return output

func _process(delta: float) -> void:
	if _desktop_suspended or not is_visible_in_tree():
		return
	var settings: Dictionary = model_state.get("settings", {})
	var fps := 15.0 if bool(settings.get("power_saving", false)) else 30.0
	_frame_accumulator += delta
	if _frame_accumulator < 1.0 / fps:
		return
	_animation_seconds += _frame_accumulator
	_frame_accumulator = 0.0
	var mouse := get_local_mouse_position()
	if mouse != _last_mouse:
		_last_mouse = mouse
		var previous_hover := _hover
		_hover = ""
		if interactive:
			_hover = str(_plot_at(mouse).get("id", ""))
		if _hover != previous_hover:
			if scene_name == "farm": _redraw_animation()
			else: _invalidate_scene()
	_redraw_animation()

func _plot_at(point: Vector2) -> Dictionary:
	for hit in _plot_hits:
		if (hit.rect as Rect2).has_point(point): return hit
	return {}

func _input(event: InputEvent) -> void:
	if not interactive or not is_visible_in_tree():
		return
	var hovered_control := get_viewport().gui_get_hovered_control()
	if hovered_control != null and hovered_control.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		if event is InputEventMouseButton and not event.pressed:
			_farm_dragging = false
			_net_dragging = false
		return
	if event is InputEventMouseMotion and scene_name == "pond" and _net_dragging:
		var drag_point: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		_track_net(drag_point)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and scene_name == "farm" and _farm_dragging:
		_farm_drag_end = get_global_transform_with_canvas().affine_inverse() * event.position
		get_viewport().set_input_as_handled()
		_redraw_animation()
		return
	if not (event is InputEventMouseButton) or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var mouse: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
	if scene_name == "farm" and not event.pressed and _farm_dragging:
		_farm_drag_end = mouse
		_finish_farm_gesture()
		get_viewport().set_input_as_handled()
		return
	if scene_name == "pond" and not event.pressed and _net_dragging:
		_track_net(mouse)
		_net_dragging = false
		fish_clicked.emit(_net_candidate)
		get_viewport().set_input_as_handled()
		_redraw_animation()
		return
	if not event.pressed: return
	if not Rect2(Vector2.ZERO, Vector2(view_width, view_height)).has_point(mouse):
		return
	if scene_name == "farm":
		_farm_dragging = true
		_farm_drag_start = mouse
		_farm_drag_end = mouse
		_farm_shift = event.shift_pressed
		_farm_press_hit = _plot_at(mouse)
		get_viewport().set_input_as_handled()
	elif scene_name == "pond" and _water_input_contains(mouse):
		_net_dragging = true
		_net_previous = mouse
		_net_candidate = ""
		_track_net(mouse)
		get_viewport().set_input_as_handled()
		_redraw_animation()

func _finish_farm_gesture() -> void:
	_farm_dragging = false
	var ids: Array = selected_plot_ids.duplicate() if _farm_shift else []
	if _farm_drag_start.distance_to(_farm_drag_end) >= 5.0:
		var selection_rect := Rect2(_farm_drag_start, _farm_drag_end - _farm_drag_start).abs()
		for hit in _plot_hits:
			if bool(_plots_by_id.get(str(hit.id), {}).get("open", false)) and selection_rect.intersects(hit.rect) and not ids.has(str(hit.id)): ids.append(str(hit.id))
		plots_selected.emit(ids)
	elif not _farm_press_hit.is_empty():
		var id := str(_farm_press_hit.id)
		if not bool(_plots_by_id.get(id, {}).get("open", false)):
			locked_plot_clicked.emit(id)
		elif not selection_mode and not _farm_shift and str(_plots_by_id.get(id, {}).get("status", "")) == "unwatered":
			plot_clicked.emit(id)
		else:
			if _farm_shift and ids.has(id): ids.erase(id)
			else: ids.append(id)
			plots_selected.emit(ids)
	else:
		plots_selected.emit(ids)
	_redraw_animation()

func _track_net(point: Vector2) -> void:
	if _net_candidate.is_empty():
		for hit in _fish_hits:
			if _segment_hits_rect(_net_previous, point, hit.rect):
				_net_candidate = str(hit.id)
				break
	_net_previous = point

func _water_input_contains(point: Vector2) -> bool:
	return _pond_bounds.has_point(point)

func cancel_gestures() -> void:
	_farm_dragging = false
	_net_dragging = false
	_farm_press_hit = {}
	_redraw_animation()

func _segment_hits_rect(start: Vector2, finish: Vector2, rect: Rect2) -> bool:
	var low := 0.0
	var high := 1.0
	var delta := finish - start
	for axis in range(2):
		if absf(delta[axis]) < 0.00001:
			if start[axis] < rect.position[axis] or start[axis] > rect.end[axis]: return false
		else:
			var first := (rect.position[axis] - start[axis]) / delta[axis]
			var last := (rect.end[axis] - start[axis]) / delta[axis]
			low = maxf(low, minf(first, last))
			high = minf(high, maxf(first, last))
			if low > high: return false
	return true

func _draw() -> void:
	if not is_instance_valid(_static_viewport): return
	# Keep compatibility with callers changing page directly then requesting
	# a redraw, without repeatedly baking this texture during actor frames.
	if _static_layout_key != _static_key():
		_scene_cache_ready = false
		_request_static_bake()
	draw_texture_rect(_static_viewport.get_texture(), Rect2(Vector2.ZERO, Vector2(view_width, view_height)), false)

func _draw_static() -> void:
	if _desktop_suspended: return
	_draw_target = _static_layer
	_plot_hits.clear()
	_target_positions.clear()
	_animal_draws.clear()
	_update_camera()
	_background()
	match scene_name:
		"farm": _draw_farm()
		"ranch": _draw_ranch()
		"pond": _draw_pond()
	_draw_target = null
	_static_bake_count += 1
	_scene_cache_ready = true
	# Redraw after rebuilding placements, including pages changed by callers
	# that set page directly and then call queue_redraw().
	_redraw_animation()

func _draw_animated() -> void:
	_fish_hits.clear()
	# CanvasItem redraw notifications may arrive in queue order. A changed
	# scene/page must rebuild positions before actors use them; _draw requeues
	# this layer once that cache is ready.
	if not _scene_cache_ready:
		return
	_draw_target = _animation_layer
	if scene_name == "ranch":
		# Keep shadows, atlas sprites and markers in separate runs. Interleaving
		# a solid rectangle and a texture for every animal prevents GL batching.
		for entry in _animal_draws:
			_box(Rect2(entry.position + Vector2(5, 24), Vector2(19, 2)), ANIMAL_SHADOW)
		for entry in _animal_draws:
			_draw_animal(entry.position, entry.animal)
		for entry in _animal_draws:
			_draw_animal_markers(entry.position, entry.animal)
	elif scene_name == "pond":
		_draw_pond_ripples()
		for item in model_state.get("fish", []):
			_draw_fish(item)
	_draw_farmers()
	if scene_name == "farm": _draw_farm_overlay()
	_draw_target = null

func _background() -> void:
	if scene_name == "farm":
		_draw_natural_background()
		return
	_canvas().draw_texture_rect(ART.terrain("grass"), Rect2(0, 0, view_width, view_height), true)
	_box(Rect2(0, 0, view_width, 3), SOIL_DARK)
	_box(Rect2(0, 3, view_width, 2), Color("#dbab62"))
	_box(Rect2(0, view_height - 5, view_width, 5), GRASS_DARK)
	for x in range(8, int(view_width), 37):
		var yy := 22 + (x * 13) % 117
		_box(Rect2(x, yy, 3, 2), GRASS_LIGHT)
		_box(Rect2(x + 5, yy + 4, 2, 2), GRASS_DARK)
	for x in range(12, int(view_width), 24):
		_box(Rect2(x, view_height - 6, 2, 4), GRASS_LIGHT)

func _draw_natural_background() -> void:
	_canvas().draw_texture_rect(ART.natural_tile("grass"), Rect2(0, 0, view_width, view_height), true)
	var scenery_width := maxi(int(WORLD.FARM_WIDTH), int(view_width + camera_offset))
	# The shared walking lane runs through the whole world. Its edges break
	# up into grass, stones and flowers rather than enclosing region cards.
	var lane := Rect2(_to_screen(Vector2(12, 123)), Vector2(scenery_width - 24, 19))
	_canvas().draw_texture_rect(ART.natural_tile("path"), lane, true)
	for x in range(16, scenery_width, 32):
		var pos := _to_screen(Vector2(x, 121 + (x / 32) % 2))
		_box(Rect2(pos, Vector2(10, 2)), Color("#a7ae78"))
		if (x / 32) % 4 == 0: _draw_decoration("flower", Vector2(x, 139), x / 32)
	for x in range(0, scenery_width, 32):
		if x >= 16 and x < 64: continue # a small open gate by the well
		_draw_decoration("fence", Vector2(x, 142))
	_draw_decoration("tree", Vector2(2, 5))
	_draw_decoration("well", Vector2(17, 83))
	_draw_decoration("sign", Vector2(15, 126))
	_draw_decoration("tree", Vector2(1100, 44), 1)
	_draw_decoration("stone", Vector2(1104, 116))
	for x in range(76, 1100, 127):
		_draw_decoration("flower", Vector2(x, 2), x / 127)
	# A small stream and orchard fill wide desktops beyond the cultivable
	# field. These are cached scenery and never change the 96 plot positions.
	if scenery_width > int(WORLD.FARM_WIDTH):
		var stream_x := WORLD.FARM_WIDTH + 168
		for y in range(0, 153, 12):
			var bend := float([0, 0, 4, 8, 8, 4, 0, -4, -8, -8, -4, 0, 4][y / 12])
			var bank := Rect2(_to_screen(Vector2(stream_x + bend, y)), Vector2(28, 14))
			_box(bank, Color("#738752"))
			_canvas().draw_texture_rect(ART.natural_tile("water", y / 12), bank.grow(-3), true)
		var bridge := _to_screen(Vector2(stream_x - 16, 121))
		_box(Rect2(bridge, Vector2(54, 21)), Color("#715b42"))
		for x in range(2, 51, 6):
			_box(Rect2(bridge + Vector2(x, 2), Vector2(5, 17)), Color("#b09365"))
		for x in range(int(WORLD.FARM_WIDTH) + 56, scenery_width - 40, 138):
			if absf(x - stream_x) < 48: continue
			_draw_decoration("tree", Vector2(x, 4 + (x / 138) % 3 * 12), x / 138)
			_draw_decoration("bush", Vector2(x - 21, 87), x / 138)
			_draw_decoration("flower", Vector2(x + 42, 83), x / 138)
			_draw_decoration("stone", Vector2(x + 49, 133), x / 138)

func _draw_decoration(kind: String, world_position: Vector2, variant := 0) -> void:
	var texture: Texture2D = ART.natural_decoration(kind, variant)
	var rect := Rect2(_to_screen(world_position), texture.get_size())
	if rect.end.x > 0 and rect.position.x < view_width: _canvas().draw_texture_rect(texture, rect, false)

func _draw_farm() -> void:
	var plots: Array = model_state.get("plots", [])
	var by_index := {}
	for plot in plots: by_index[int(plot.get("index", 0))] = plot
	for plot in plots:
		var index := int(plot.get("index", 0))
		var rect := Rect2(_to_screen(WORLD.plot_position(index)), Vector2(32, 32))
		if rect.end.x <= 0 or rect.position.x >= view_width: continue
		_plot_hits.append({"rect": rect, "id": str(plot.get("id", "")), "open": bool(plot.get("open", false)), "index": index})
		_target_positions[str(plot.get("id", ""))] = _to_screen(WORLD.target_position("farm", str(plot.get("id", "")), model_state))
		if not bool(plot.get("open", false)):
			# Fallow ground keeps the same hidden hit grid as cultivated land.
			_canvas().draw_texture_rect(ART.natural_tile("grass", index % 4), rect, false)
			if index % 11 == 2: _draw_decoration("flower", WORLD.plot_position(index), index)
			elif index % 17 == 4: _draw_decoration("stone", WORLD.plot_position(index), index)
			continue
		var edges := 0
		if index % 3 == 0 or not bool(by_index.get(index - 1, {}).get("open", false)): edges |= 1
		if not bool(by_index.get(index + 3, {}).get("open", false)): edges |= 2
		if index % 3 == 2 or not bool(by_index.get(index + 1, {}).get("open", false)): edges |= 4
		if not bool(by_index.get(index - 3, {}).get("open", false)): edges |= 8
		_draw_plot(rect, plot, edges)

func _draw_plot(rect: Rect2, plot: Dictionary, edges: int) -> void:
	var status := str(plot.get("status", "empty"))
	_canvas().draw_texture_rect(ART.natural_tile("field" if status in ["empty", "unwatered"] else "wet", int(plot.get("index", 0)), edges), rect, false)
	if status != "empty":
		var crop: Dictionary = _crops.get(str(plot.get("crop_id", "parsnip")), {})
		var growth := 0.0
		if status in ["ready", "processing"]: growth = 1.0
		elif status == "growing": growth = clampf(1.0 - float(plot.get("remaining", 0)) / maxf(1, float(crop.get("grow_seconds", 720))), 0, 1)
		_draw_crop(rect.position + Vector2(2, 2), str(crop.get("id", "parsnip")), growth, status)
		if status == "unwatered":
			_draw_drop(rect.position + Vector2(25, 3), Color("#e6bc8a"))
			_draw_drop(rect.position + Vector2(24, 2), Color("#8c5540"))
		elif status == "ready": _star(rect.position + Vector2(26, 6), GOLD)
		elif status == "processing":
			_box(Rect2(rect.position + Vector2(3, 27), Vector2(26, 3)), CREAM)
			var progress := 1.0 - float(plot.get("remaining", 0)) / 180.0
			_box(Rect2(rect.position + Vector2(3, 27), Vector2(floor(26 * clampf(progress, 0, 1)), 3)), GOLD)

func _draw_farm_overlay() -> void:
	var hovered: Dictionary = {}
	for hit in _plot_hits:
		var rect: Rect2 = hit.rect
		if selected_plot_ids.has(str(hit.id)):
			_canvas().draw_rect(rect.grow(-1), GOLD, false, 2, false)
			_box(Rect2(rect.position + Vector2(3, 3), Vector2(5, 5)), GOLD)
		if str(hit.id) == _hover:
			hovered = hit
			_canvas().draw_rect(rect.grow(-1), CREAM, false, 2, false)
			if not bool(hit.open):
				_box(Rect2(rect.position + Vector2(13, 10), Vector2(2, 10)), CREAM)
				_box(Rect2(rect.position + Vector2(9, 14), Vector2(10, 2)), CREAM)
	if _farm_dragging and _farm_drag_start.distance_to(_farm_drag_end) >= 5.0:
		var rect := Rect2(_farm_drag_start, _farm_drag_end - _farm_drag_start).abs()
		_canvas().draw_rect(rect, Color(1.0, 0.88, 0.53, 0.12), true)
		_canvas().draw_rect(rect, GOLD, false, 1, false)
	if hovered.is_empty() or _farm_dragging: return
	var plot: Dictionary = _plots_by_id.get(str(hovered.id), {})
	var width := minf(228, view_width - 16)
	var origin := Vector2(clampf((hovered.rect as Rect2).position.x, 8, view_width - width - 8), 111 if not selection_mode and (hovered.rect as Rect2).get_center().y < 80 else 4)
	var bounds := Rect2(origin, Vector2(width, 57))
	_box(bounds, Color("#66563e"))
	_box(bounds.grow(-1), Color("#f0e0b9"))
	if not bool(plot.get("open", false)):
		_label("荒地 · 可开垦", origin + Vector2(8, 17), INK)
		_label("点击查看开垦安排", origin + Vector2(8, 36), MUTED, 11)
		return
	var crop_id := str(plot.get("crop_id", ""))
	var status := str(plot.get("status", "empty"))
	var name := str(_crops.get(crop_id, {}).get("name", crop_id)) if status != "empty" else "空地"
	_label(name + (" · 已选中" if selected_plot_ids.has(str(hovered.id)) else ""), origin + Vector2(8, 16), INK, 12, width - 16)
	var stage_names := {"empty": "等待播种", "unwatered": "缺水 · 点击浇水", "growing": "生长 " + _clock(float(plot.get("remaining", 0))), "ready": "成熟 · 等待收获", "processing": "加工 " + _clock(float(plot.get("remaining", 0)))}
	_label(str(stage_names.get(status, status)), origin + Vector2(8, 33), MUTED, 11, width - 16)
	var next := str(plot.get("pending_crop_id", ""))
	if next.is_empty(): next = str(plot.get("preferred_crop_id", model_state.get("default_seed_id", "parsnip")))
	if seed_preview_provider.is_valid():
		var preview_id := str(hovered.id)
		if not _seed_preview_cache.has(preview_id): _seed_preview_cache[preview_id] = seed_preview_provider.call(preview_id)
		var preview: Dictionary = _seed_preview_cache[preview_id]
		if bool(preview.get("ok", false)): next = str(preview.get("crop_id", next))
	var reserved := false
	for claim in model_state.get("seed_reservations", []):
		if str(claim.get("plot_id", "")) == str(hovered.id): reserved = true; break
	_label("下轮 " + str(_crops.get(next, {}).get("name", next)) + (" · 种子已预留" if reserved else ""), origin + Vector2(8, 49), MUTED, 11, width - 16)

func _draw_crop(origin: Vector2, id: String, growth: float, status: String) -> void:
	if growth < 0.25 and status not in ["ready", "processing"]:
		_sprite(SPROUT, {"g": Color("#4d842f"), "l": Color("#b5d75e"), "s": Color("#729745")}, origin + Vector2(4, 11), 2)
		return
	var size := 28.0 if growth >= 0.7 or status in ["ready", "processing"] else 21.0
	var texture: Texture2D = ART.icon("crop", id)
	if texture != null:
		_canvas().draw_texture_rect(texture, Rect2(origin + Vector2(floorf((28 - size) / 2), 28 - size), Vector2(size, size)), false)

func _crop_color(id: String) -> Color:
	var fixed := {
		"parsnip": "#e8d3a0", "carrot": "#d99c66", "potato": "#c4a885", "cauliflower": "#eee3c8",
		"blue_jazz": "#a5b9d8", "tulip": "#d89198", "strawberry": "#cd8173", "blueberry": "#8b96c3",
		"sunflower": "#e3bf6e", "fairy_rose": "#d3a5be", "pumpkin": "#c99767", "eggplant": "#9b84b0",
		"corn": "#dbca7a", "melon": "#a8bf8b", "sweet_gem_berry": "#c17d84", "fiber": "#a2b484",
	}
	if fixed.has(id):
		return Color(fixed[id])
	return Color.from_hsv(float(absi(id.hash()) % 360) / 360.0, 0.30, 0.80)

func _ranch_pages() -> Array:
	# Retain page metadata for callers, but never rearrange world modules.
	var pages: Array = []
	for page_index in range(maxi(1, ceili(WORLD.RANCH_WIDTH / _camera_span()))):
		var offset := minf(page_index * _camera_span(), maxf(0, WORLD.RANCH_WIDTH - _camera_span()))
		var modules: Array = []
		if offset < 744: modules.append({"kind": "grass"})
		for barn in config.get("barns", config.get("shelters", [])):
			var x := WORLD.shelter_position(str(barn.get("id", ""))).x
			if x + 128 > offset and x < offset + _camera_span(): modules.append({"kind": "barn", "barn": barn})
		if WORLD.STORAGE_ORIGIN.x + 128 > offset and WORLD.STORAGE_ORIGIN.x < offset + _camera_span(): modules.append({"kind": "storage"})
		pages.append(modules)
	return pages

func _draw_ranch() -> void:
	_draw_grass_section(_to_screen(Vector2(24, 0)), 0, 24)
	for barn in config.get("barns", config.get("shelters", [])):
		var origin := _to_screen(WORLD.shelter_position(str(barn.get("id", ""))))
		if origin.x + 128 > 0 and origin.x < view_width: _draw_barn(origin, barn)
	var storage := _to_screen(WORLD.STORAGE_ORIGIN)
	if storage.x + 128 > 0 and storage.x < view_width: _draw_storage(storage)

func _draw_grass_section(origin: Vector2, first_column: int, columns: int) -> void:
	var width := columns * 30.0
	var cells: Array = model_state.get("grass", [])
	var open_count := 0
	for cell in cells:
		open_count += int(bool(cell.get("open", false)))
	_label("牧草地  %d / 96" % open_count, origin + Vector2(2, 18), INK, 12, width - 4)
	for row in range(4):
		for column in range(columns):
			var index := row * 24 + first_column + column
			var cell: Dictionary = cells[index] if index < cells.size() else {}
			var pos := origin + Vector2(column * 30, 28 + row * 30)
			var rect := Rect2(pos, Vector2(28, 28))
			var opened := bool(cell.get("open", false))
			_box(rect, Color("#7f936c") if opened else Color("#8b9d7d"))
			_box(rect.grow(-1), Color("#bac394") if opened else Color("#9ba98b"))
			if not opened:
				_draw_lock(pos + Vector2(11, 10), 1)
				continue
			var clumps := int(cell.get("clumps", 0))
			for tuft in range(clumps):
				var tx := 5 + (tuft % 2) * 11
				var ty := 6 + (tuft / 2) * 11
				_draw_grass_tuft(pos + Vector2(tx, ty), bool(cell.get("mother", false)))
			if bool(cell.get("mother", false)):
				_box(Rect2(pos + Vector2(1, 1), Vector2(26, 2)), GOLD)
				_star(pos + Vector2(22, 5), GOLD)
			_target_positions[str(cell.get("id", ""))] = pos + Vector2(14, 14)
	_label("金边母草保留 · 普通草留根", origin + Vector2(2, 164), MUTED, 12, width - 4)

func _draw_grass_tuft(origin: Vector2, mother: bool) -> void:
	var dark := Color("#4f7650") if not mother else Color("#557348")
	_box(Rect2(origin + Vector2(0, 4), Vector2(2, 5)), dark)
	_box(Rect2(origin + Vector2(2, 1), Vector2(2, 8)), dark)
	_box(Rect2(origin + Vector2(5, 3), Vector2(2, 6)), dark)
	_box(Rect2(origin + Vector2(1, 7), Vector2(7, 2)), Color("#71914f"))
	_box(Rect2(origin + Vector2(2, 1), Vector2(2, 2)), Color("#a1b572"))

func _draw_barn(origin: Vector2, barn: Dictionary) -> void:
	var id := str(barn.get("id", ""))
	var level := int(model_state.get("shelters", {}).get(id, 0))
	var occupants: Array = []
	for animal in model_state.get("animals", []):
		if str(_animals.get(str(animal.get("type_id", "")), {}).get("shelter_id", "")) == id:
			occupants.append(animal)
	_label(str(barn.get("name", "棚舍")) + ("  Lv.%d" % level if level > 0 else "  待建"), origin + Vector2(2, 18), INK)
	# Stepped roof, wooden frontage and fixed 4×3 paddock.
	var roof := Color("#c09075") if level > 0 else Color("#9eaa8d")
	if level > 0: roof = Color("#b75c37") if id in ["chicken_coop", "duck_coop", "rabbit_hutch"] else Color("#a74634")
	for step in range(4):
		_box(Rect2(origin + Vector2(6 + step * 4, 29 - step * 4), Vector2(116 - step * 8, 5)), SOIL_DARK)
		_box(Rect2(origin + Vector2(8 + step * 4, 28 - step * 4), Vector2(112 - step * 8, 4)), roof.lightened(step * 0.035))
		for tile in range(12 + step * 4, 115 - step * 4, 13):
			_box(Rect2(origin + Vector2(tile, 28 - step * 4), Vector2(1, 3)), roof.darkened(0.18))
	_box(Rect2(origin + Vector2(8, 32), Vector2(112, 26)), Color("#e8b979") if level > 0 else Color("#bbc1a6"))
	for board in [36, 43, 50]:
		_box(Rect2(origin + Vector2(9, board), Vector2(110, 1)), Color("#ba844e") if level > 0 else MUTED)
	_box(Rect2(origin + Vector2(9, 32), Vector2(3, 26)), SOIL_DARK)
	_box(Rect2(origin + Vector2(116, 32), Vector2(3, 26)), SOIL_DARK)
	_box(Rect2(origin + Vector2(8, 31), Vector2(112, 2)), GOLD if level > 0 else MUTED)
	_box(Rect2(origin + Vector2(18, 39), Vector2(16, 12)), SOIL_DARK)
	_box(Rect2(origin + Vector2(20, 41), Vector2(12, 8)), WATER_LIGHT)
	_box(Rect2(origin + Vector2(25, 40), Vector2(2, 10)), SOIL_DARK)
	_box(Rect2(origin + Vector2(19, 44), Vector2(14, 1)), SOIL_DARK)
	_box(Rect2(origin + Vector2(52, 38), Vector2(24, 20)), SOIL_DARK)
	_box(Rect2(origin + Vector2(54, 40), Vector2(20, 18)), Color("#ac916f"))
	_canvas().draw_texture_rect(ART.terrain("grass"), Rect2(origin + Vector2(3, 60), Vector2(122, 87)), true, Color.WHITE if level > 0 else Color("#b6bd9c"))
	_box(Rect2(origin + Vector2(3, 145), Vector2(122, 2)), SOIL_DARK)
	for px in range(3, 126, 20):
		_box(Rect2(origin + Vector2(px, 137), Vector2(4, 15)), SOIL_DARK)
		_box(Rect2(origin + Vector2(px + 1, 138), Vector2(2, 13)), Color("#eac08a"))
	_box(Rect2(origin + Vector2(3, 140), Vector2(122, 3)), Color("#dda462"))
	_box(Rect2(origin + Vector2(3, 142), Vector2(122, 1)), SOIL_DARK)
	if level == 0:
		_draw_lock(origin + Vector2(56, 91), 2)
		_label("%d 金币" % int(barn.get("costs", [0])[0]), origin + Vector2(24, 164), MUTED)
		return
	for i in range(occupants.size()):
		var animal: Dictionary = occupants[i]
		var pos := origin + Vector2(6 + (i % 4) * 30, 62 + (i / 4) * 27)
		_animal_draws.append({"position": pos, "animal": animal})
		_target_positions[str(animal.get("id", ""))] = pos + Vector2(12, 12)
	_label("%d / %d 只" % [occupants.size(), level * 4], origin + Vector2(3, 164), MUTED)
	_target_positions[id] = origin + Vector2(106, 126)

func _draw_animal(origin: Vector2, animal: Dictionary) -> void:
	var id := str(animal.get("type_id", "chicken"))
	var adult := bool(animal.get("adult", false))
	var bob := int(sin(_animation_seconds * 2 + float(absi(str(animal.get("id", "")).hash()) % 17)) > 0)
	var size := 28.0 if adult else 19.0
	var pos := origin + Vector2(floorf((30 - size) / 2), 26 - size + bob)
	var texture: Texture2D = ART.icon("animal", "chick" if not adult and id in ["chicken", "golden_chicken"] else id)
	_canvas().draw_texture_rect(texture, Rect2(pos, Vector2(size, size)), false)

func _draw_animal_markers(origin: Vector2, animal: Dictionary) -> void:
	if bool(animal.get("hungry", false)):
		_box(Rect2(origin + Vector2(24, 2), Vector2(2, 6)), RED)
		_box(Rect2(origin + Vector2(24, 10), Vector2(2, 2)), RED)
	if int(animal.get("ready", 0)) > 0:
		_star(origin + Vector2(25, 20), GOLD)

func _draw_storage(origin: Vector2) -> void:
	var levels: Array = config.get("upgrades", {}).get("hay_storage", [{"capacity": 24}])
	var storage_level := clampi(int(model_state.get("storage_level", 0)), 0, levels.size() - 1)
	var capacity := int(levels[storage_level].get("capacity", 24))
	var trough := int(model_state.get("trough_hay", 0))
	var warehouse := int(model_state.get("warehouse_hay", 0))
	_label("食槽与草仓", origin + Vector2(2, 18), INK)
	_box(Rect2(origin + Vector2(5, 35), Vector2(118, 28)), Color("#bfab84"))
	_box(Rect2(origin + Vector2(8, 38), Vector2(112, 21)), SOIL_DARK)
	_box(Rect2(origin + Vector2(11, 42), Vector2(floor(106 * minf(1, float(trough) / maxf(1, capacity))), 13)), GOLD)
	_box(Rect2(origin + Vector2(13, 64), Vector2(4, 7)), SOIL_DARK)
	_box(Rect2(origin + Vector2(111, 64), Vector2(4, 7)), SOIL_DARK)
	_label("食槽 %d / %d" % [trough, capacity], origin + Vector2(5, 91), MUTED)
	_label("草仓 %d / %d" % [warehouse, capacity], origin + Vector2(5, 113), MUTED)
	var herd_size: int = model_state.get("animals", []).size()
	_label("口粮偏低" if trough < herd_size * 2 else "口粮充足", origin + Vector2(5, 137), RED if trough < herd_size * 2 else MUTED)
	_label("先青草 · 后干草", origin + Vector2(5, 164), MUTED)
	_target_positions["trough"] = origin + Vector2(65, 58)
	_target_positions["warehouse"] = origin + Vector2(65, 106)

func _draw_pond() -> void:
	var left := _to_screen(Vector2(140, 0)).x
	_pond_bounds = Rect2(left, 25, WORLD.POND_WIDTH - 240, 127)
	_box(_pond_bounds.grow(5), Color("#d1c7a5"))
	_box(_pond_bounds.grow(2), Color("#7d9d93"))
	_box(_pond_bounds, WATER)
	_box(Rect2(_pond_bounds.position, Vector2(_pond_bounds.size.x, 7)), Color("#7eacb7"))
	_box(Rect2(_pond_bounds.position + Vector2(0, _pond_bounds.size.y - 7), Vector2(_pond_bounds.size.x, 7)), WATER_LIGHT)
	for stone in range(int(_pond_bounds.size.x / 18)):
		var sx := _pond_bounds.position.x + stone * 18
		_box(Rect2(sx, _pond_bounds.end.y + 2, 12, 3), Color("#b7a579"))
		_box(Rect2(sx + 2, _pond_bounds.end.y + 1, 8, 2), Color("#ead7a4"))
	# Deck boards and reeds form the pond's shoreline.
	_box(Rect2(left - 38, 75, 57, 46), SOIL_DARK)
	for i in range(6):
		_box(Rect2(left - 35 + i * 9, 77, 7, 42), Color("#bea37e"))
	for i in range(5):
		var reed := Vector2(_pond_bounds.end.x + 10 + (i % 2) * 11, 49 + i * 20)
		_box(Rect2(reed + Vector2(3, -8), Vector2(2, 16)), Color("#718b65"))
		_box(Rect2(reed + Vector2(1, -11), Vector2(6, 6)), Color("#a89577"))
		_draw_grass_tuft(reed, false)
	var fish: Array = model_state.get("fish", [])
	var cooldown := float(model_state.get("net_remaining", 0))
	var pending: Dictionary = model_state.get("pending_fish", {})
	var subtitle := "点击鱼使用渔网" if interactive else "观赏模式 · 鱼塘自然补充"
	if not pending.is_empty():
		subtitle = "已捕获 " + str(_fish_types.get(str(pending.get("type_id", "")), {}).get("name", "鱼")) + " · 等待选择出售或登记"
	elif cooldown > 0:
		subtitle = "渔网冷却 " + _clock(cooldown)
	_label("鱼塘  %d / 12" % fish.size(), Vector2(24, 18), INK)
	if view_width < 640:
		if not pending.is_empty():
			subtitle = "等待处理"
		elif cooldown > 0:
			subtitle = "冷却 %d 秒" % ceili(cooldown)
		else:
			subtitle = "点击捞鱼" if interactive else "观赏中"
	_label(subtitle, Vector2(left + 130 if view_width >= 640 else 134, 18), MUTED, 12, view_width - 290 if view_width >= 640 else view_width - 158)
	var spawn := float(model_state.get("fish_remaining", 180))
	_label("满池时暂停补鱼" if fish.size() >= 12 else "下一条鱼 " + _clock(spawn), Vector2(left, 167), MUTED)
	_target_positions["pond_dock"] = _to_screen(WORLD.POND_DOCK)

func _draw_pond_ripples() -> void:
	for i in range(int(_pond_bounds.size.x / 38)):
		var x := _pond_bounds.position.x + 12 + i * 38
		var y := 43 + (i * 29) % 88
		var drift := floorf(sin(_animation_seconds + i) * 2)
		_box(Rect2(x + drift, y, 13, 1), WATER_LIGHT)
		_box(Rect2(x + drift + 4, y + 3, 7, 1), Color("#9dc8ce"))

func _draw_fish(item: Dictionary) -> void:
	var id := str(item.get("id", ""))
	var type_id := str(item.get("type_id", "silver_fish"))
	var phase := float(absi(id.hash()) % 31)
	var center := _pond_bounds.position + Vector2(float(item.get("x", 0.5)) * _pond_bounds.size.x, float(item.get("y", 0.5)) * _pond_bounds.size.y)
	center += Vector2(floor(sin(_animation_seconds * 0.65 + phase) * 9), floor(sin(_animation_seconds * 0.9 + phase) * 3))
	center.x = clampf(center.x, _pond_bounds.position.x + 16, _pond_bounds.end.x - 16)
	center.y = clampf(center.y, _pond_bounds.position.y + 10, _pond_bounds.end.y - 10)
	_box(Rect2(center + Vector2(-9, 6), Vector2(19, 2)), Color("#438fab"))
	_canvas().draw_texture_rect(ART.icon("animal", type_id), Rect2(center + Vector2(-16, -12), Vector2(32, 24)), false)
	_fish_hits.append({"id": id, "rect": Rect2(center + Vector2(-17, -11), Vector2(34, 22))})

func _sample_farmers(values: Dictionary) -> void:
	var sample_time := float(values.get("elapsed", 0))
	# Positions advance at one-second simulation boundaries. Interpolate the
	# whole interval so a 32px step does not become a fast half-second sprint.
	var duration := clampf(sample_time - _last_farmer_sample, 1.0 / 30.0, 1.0)
	if sample_time < _last_farmer_sample: _farmer_tracks.clear()
	_last_farmer_sample = sample_time
	var scene_indices := {}
	for farmer in values.get("farmers", []):
		var scene := str(farmer.get("scene", "farm"))
		var index := int(scene_indices.get(scene, 0))
		scene_indices[scene] = index + 1
		var fallback: Vector2 = WORLD.farmer_idle_position(scene, index)
		var foot := Vector2(float(farmer.get("x", fallback.x)), float(farmer.get("y", fallback.y)))
		var id := str(farmer.get("id", ""))
		var track: Dictionary = _farmer_tracks.get(id, {})
		if _desktop_suspended or track.is_empty() or str(track.get("scene", "")) != scene:
			_farmer_tracks[id] = {"from": foot, "target": foot, "since": _animation_seconds, "duration": duration, "left": false, "scene": scene}
		elif (track.target as Vector2).distance_squared_to(foot) > 0.00001:
			var drawn := _farmer_position(track)
			var route: Array[Vector2] = [foot]
			if not WORLD.segment_walkable(scene,drawn,foot):
				route = WORLD.find_path(scene,drawn,foot)
				if route.is_empty(): drawn = foot
			var route_length := 0.0
			var previous_point := drawn
			for point in route:
				route_length += previous_point.distance_to(point)
				previous_point = point
			_farmer_tracks[id] = {"from": drawn, "target": foot, "since": _animation_seconds, "duration": duration, "left": foot.x < drawn.x, "scene": scene,"route":route,"route_length":route_length}

func _farmer_position(track: Dictionary) -> Vector2:
	var progress := clampf((_animation_seconds - float(track.since)) / maxf(1.0 / 30.0, float(track.duration)), 0, 1)
	if track.has("route"):
		var remaining := progress*float(track.route_length)
		var previous_point: Vector2 = track.from
		for point in track.route:
			var distance := previous_point.distance_to(point)
			if remaining <= distance: return previous_point.move_toward(point,remaining)
			remaining -= distance
			previous_point = point
		return track.target
	return (track.from as Vector2).lerp(track.target as Vector2, progress)

func _draw_farmers() -> void:
	var visible_index := 0
	for farmer in model_state.get("farmers", []):
		if str(farmer.get("scene", "")) != scene_name: continue
		var fallback: Vector2 = WORLD.farmer_idle_position(scene_name, visible_index)
		var foot := Vector2(float(farmer.get("x", fallback.x)), float(farmer.get("y", fallback.y)))
		var track: Dictionary = _farmer_tracks.get(str(farmer.get("id", "")), {"from": foot, "target": foot, "since": _animation_seconds, "duration": 0.1, "left": false})
		var drawn_world := _farmer_position(track)
		var drawn := _to_screen(drawn_world).floor()
		visible_index += 1
		if drawn.x < -17 or drawn.x > view_width + 17: continue
		var mode := str(farmer.get("mode", "idle"))
		var phase := str(farmer.get("phase", "idle"))
		var task: Dictionary = farmer.get("task", {})
		var walking := phase == "walking" or drawn_world.distance_squared_to(foot) > 0.25
		var acting := phase == "acting" and not walking
		var action := str(task.get("action", "")) if acting else "walk"
		var frame := int(_animation_seconds * 6.0) % 4 if walking or acting else 3
		var texture: Texture2D = ART.farmer(action, frame, bool(track.left))
		var sprite_rect := Rect2(drawn - Vector2(17, 37), Vector2(34, 40))
		if acting and action != "walk":
			var target := WORLD.target_position(scene_name, str(task.get("target", "")), model_state)
			if target.x < foot.x:
				sprite_rect.position.x += sprite_rect.size.x
				sprite_rect.size.x = -sprite_rect.size.x
		_canvas().draw_texture_rect(texture, sprite_rect, false, Color("#ded0ef") if str(farmer.get("home", "")) != scene_name else Color.WHITE)
		if mode == "resting": _label("z", drawn + Vector2(10, -26), CREAM)
		_box(Rect2(drawn + Vector2(-10, 3), Vector2(20, 2)), Color("#587335"))
		_box(Rect2(drawn + Vector2(-10, 3), Vector2(floor(20 * float(farmer.get("energy", 100)) / 100), 2)), GOLD)

func _sprite(pattern: Array, palette: Dictionary, origin: Vector2, pixel: int) -> void:
	# Build each small palette sprite once. One nearest-filtered texture draw
	# replaces dozens of rectangles per animal without changing pixel geometry.
	var cache_key: int = hash([pattern, palette])
	if not _sprite_cache.has(cache_key):
		var width := 1
		for line in pattern: width = maxi(width, str(line).length())
		var bitmap := Image.create(width, pattern.size(), false, Image.FORMAT_RGBA8)
		bitmap.fill(Color(0, 0, 0, 0))
		for y in range(pattern.size()):
			var row := str(pattern[y])
			for x in range(row.length()):
				var key := row.substr(x, 1)
				if palette.has(key): bitmap.set_pixel(x, y, palette[key])
		_sprite_cache[cache_key] = ImageTexture.create_from_image(bitmap)
	var texture: Texture2D = _sprite_cache[cache_key]
	_canvas().draw_texture_rect(texture, Rect2(origin.floor(), texture.get_size() * pixel), false)

func _draw_lock(origin: Vector2, pixel: int) -> void:
	var pattern := [".kkk.", "kk.kk", "k...k", "kkkkk", "kklkk", "kkkkk"]
	_sprite(pattern, {"k": Color("#798570"), "l": CREAM}, origin, pixel)

func _draw_drop(origin: Vector2, color: Color) -> void:
	_box(Rect2(origin + Vector2(2, 0), Vector2(2, 2)), color)
	_box(Rect2(origin + Vector2(1, 2), Vector2(4, 3)), color)
	_box(Rect2(origin + Vector2(2, 5), Vector2(2, 1)), color)

func _star(origin: Vector2, color: Color) -> void:
	_box(Rect2(origin + Vector2(-3, 0), Vector2(7, 1)), color)
	_box(Rect2(origin + Vector2(0, -3), Vector2(1, 7)), color)
	_box(Rect2(origin + Vector2(-1, -1), Vector2(3, 3)), color)

func _box(rect: Rect2, color: Color) -> void:
	_canvas().draw_rect(Rect2(rect.position.floor(), rect.size.floor()), color, true, -1, false)

func _label(value: String, position_value: Vector2, color: Color = INK, size: int = 12, width: float = -1) -> void:
	_canvas().draw_string(_font, position_value.floor(), value, HORIZONTAL_ALIGNMENT_LEFT, width, size, color)

func _canvas() -> CanvasItem:
	return _draw_target if _draw_target != null else self

func _clock(seconds: float) -> String:
	var rounded := ceili(maxf(0, seconds))
	return "%02d:%02d" % [rounded / 60, rounded % 60]
