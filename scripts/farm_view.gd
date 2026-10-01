class_name FarmView
extends Node2D

## One visible, lightweight pixel-art renderer. All productive state belongs
## to FarmState; animation offsets are cosmetic and never mutate the model.
signal plot_clicked(plot_id: String)
signal fish_clicked(fish_id: String)

var model_state: Dictionary = {}
var config: Dictionary = {}
var scene_name := "farm"
var interactive := true
var view_width := 1920.0
var view_height := 172.0
var page := 0

const INK := Color("#314638")
const MUTED := Color("#657666")
const CREAM := Color("#f1eedc")
const GRASS := Color("#9bb785")
const GRASS_LIGHT := Color("#b5c99a")
const GRASS_DARK := Color("#748f65")
const SOIL := Color("#a98869")
const SOIL_DARK := Color("#80664f")
const WATER := Color("#93bec8")
const WATER_LIGHT := Color("#b5d7d7")
const GOLD := Color("#efd387")
const RED := Color("#bf7965")

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

func _ready() -> void:
	_font.font_names = PackedStringArray(["Microsoft YaHei", "微软雅黑", "Noto Sans CJK SC", "sans-serif"])
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# The parent keeps Godot's cached ground/building/text commands. Only this
	# child's draw list is rebuilt at the animation rate; it has no _process.
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

func set_model(values: Dictionary) -> void:
	model_state = values
	_invalidate_scene()

func set_scene(value: String) -> void:
	if value not in ["farm", "ranch", "pond"]:
		return
	scene_name = value
	_net_dragging = false
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
	_hover = ""
	_invalidate_scene()

func page_next() -> void:
	page = mini(page + 1, get_page_count() - 1)
	_invalidate_scene()

func page_previous() -> void:
	page = maxi(0, page - 1)
	_invalidate_scene()

func _invalidate_scene() -> void:
	# set_model is called at the controller's UI cadence, or immediately after
	# a transaction. It refreshes crop stages/countdowns and actor placement.
	_scene_cache_ready = false
	queue_redraw()
	_redraw_animation()

func _redraw_animation() -> void:
	if is_instance_valid(_animation_layer):
		_animation_layer.queue_redraw()

func get_page_count() -> int:
	if scene_name == "farm":
		return maxi(1, ceili(6.0 / float(_farm_slots())))
	if scene_name == "ranch":
		return maxi(1, _ranch_pages().size())
	return 1

func _index(entries: Variant) -> Dictionary:
	if entries is Dictionary:
		return entries
	var output := {}
	for entry in entries:
		output[str(entry.get("id", ""))] = entry
	return output

func _process(delta: float) -> void:
	if not is_visible_in_tree():
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
			for hit in _plot_hits:
				if hit.rect.has_point(mouse):
					_hover = str(hit.id)
		if _hover != previous_hover:
			queue_redraw()
	_redraw_animation()

func _input(event: InputEvent) -> void:
	if not interactive or not is_visible_in_tree():
		return
	if event is InputEventMouseMotion and scene_name == "pond" and _net_dragging:
		var drag_point: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		_track_net(drag_point)
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventMouseButton) or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var mouse: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
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
		for hit in _plot_hits:
			if hit.rect.has_point(mouse):
				plot_clicked.emit(str(hit.id))
				get_viewport().set_input_as_handled()
				_redraw_animation()
				return
	elif scene_name == "pond" and _pond_bounds.has_point(mouse):
		_net_dragging = true
		_net_previous = mouse
		_net_candidate = ""
		_track_net(mouse)
		get_viewport().set_input_as_handled()
		_redraw_animation()

func _track_net(point: Vector2) -> void:
	if _net_candidate.is_empty():
		for hit in _fish_hits:
			if _segment_hits_rect(_net_previous, point, hit.rect):
				_net_candidate = str(hit.id)
				break
	_net_previous = point

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
	_plot_hits.clear()
	_target_positions.clear()
	_animal_draws.clear()
	_background()
	match scene_name:
		"farm": _draw_farm()
		"ranch": _draw_ranch()
		"pond": _draw_pond()
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
		for entry in _animal_draws:
			_draw_animal(entry.position, entry.animal)
	elif scene_name == "pond":
		_draw_pond_ripples()
		for item in model_state.get("fish", []):
			_draw_fish(item)
	_draw_farmers()
	_draw_target = null

func _background() -> void:
	_box(Rect2(0, 0, view_width, view_height), GRASS)
	_box(Rect2(0, 0, view_width, 3), GRASS_DARK)
	_box(Rect2(0, view_height - 8, view_width, 8), GRASS_DARK)
	for x in range(8, int(view_width), 37):
		var yy := 22 + (x * 13) % 117
		_box(Rect2(x, yy, 3, 2), GRASS_LIGHT)
		_box(Rect2(x + 5, yy + 4, 2, 2), GRASS_DARK)
	for x in range(12, int(view_width), 24):
		_box(Rect2(x, view_height - 6, 2, 4), GRASS_LIGHT)

func _farm_slots() -> int:
	return clampi(int(floor((view_width - 48.0 + 16.0) / 296.0)), 1, 6)

func _draw_farm() -> void:
	var slots := _farm_slots()
	var usable := int(view_width) - 48 - (slots - 1) * 16
	var base_width := int(floor(float(usable) / float(slots)))
	var remainder := usable - base_width * slots
	var cursor := 24.0
	var regions: Array = model_state.get("regions", [])
	var plots: Array = model_state.get("plots", [])
	for slot in range(slots):
		var index := page * slots + slot
		if index >= 6:
			break
		var region: Dictionary = regions[index] if index < regions.size() else {}
		var card_width := float(base_width + int(slot < remainder))
		var origin := Vector2(cursor, 0)
		_draw_region(origin, card_width, index, region, plots)
		cursor += card_width + 16

func _draw_region(origin: Vector2, width: float, index: int, region: Dictionary, plots: Array) -> void:
	var opened := bool(region.get("unlocked", false))
	var crop: Dictionary = _crops.get(str(region.get("current_crop_id", "parsnip")), {})
	var title := "%02d  %s" % [index + 1, str(crop.get("name", "防风草"))]
	if not opened:
		title = "%02d  待开辟" % [index + 1]
	_box(Rect2(origin + Vector2(0, 3), Vector2(width, 23)), CREAM if opened else Color("#c3c5ac"))
	_box(Rect2(origin + Vector2(0, 25), Vector2(width, 2)), SOIL_DARK)
	_label(title, origin + Vector2(8, 19), INK, 12, width - 16)
	if not str(region.get("pending_crop_id", "")).is_empty() and opened:
		_box(Rect2(origin + Vector2(width - 15, 10), Vector2(7, 7)), GOLD)
	var ready := 0
	var dry := 0
	var opened_count := 0
	var minimum_time := 0.0
	for plot in plots:
		if int(plot.get("region", -1)) != index:
			continue
		var number := int(plot.get("index", 0))
		var rect := Rect2(origin + Vector2(4 + (number % 4) * 36, 28 + (number / 4) * 36), Vector2(32, 32))
		_draw_plot(rect, plot, opened)
		if not bool(plot.get("open", false)):
			continue
		opened_count += 1
		var status := str(plot.get("status", "empty"))
		ready += int(status == "ready")
		dry += int(status == "unwatered")
		var remaining := float(plot.get("remaining", 0))
		if remaining > 0 and (minimum_time == 0 or remaining < minimum_time):
			minimum_time = remaining
	if width < 220:
		return
	var side := origin + Vector2(156, 45)
	if not opened:
		_draw_lock(side + Vector2(20, 20), 3)
		var costs: Array = config.get("upgrades", {}).get("region_costs", [0, 0, 0, 0, 10000, 20000])
		_label("开辟区域", side + Vector2(0, 65), MUTED)
		_label("%s 金币" % int(costs[index]), side + Vector2(0, 84), SOIL_DARK)
		_label("赠送6格地块", side + Vector2(0, 107), MUTED)
		return
	_label("%d / 16 地块" % opened_count, side, MUTED)
	_label("成熟 %d  缺水 %d" % [ready, dry], side + Vector2(0, 22), SOIL_DARK if dry > 0 else MUTED)
	if minimum_time > 0:
		_label("下一收获 " + _clock(minimum_time), side + Vector2(0, 44), MUTED)
	elif ready > 0:
		_label("等待农夫收获", side + Vector2(0, 44), INK)
	else:
		_label("农夫正在照料", side + Vector2(0, 44), MUTED)
	var pending := str(region.get("pending_crop_id", ""))
	if not pending.is_empty():
		_label("下轮 → " + str(_crops.get(pending, {}).get("name", pending)), side + Vector2(0, 66), SOIL_DARK, 12, width - 162)
	elif interactive:
		_label("点击地块浇水", side + Vector2(0, 66), MUTED)
	else:
		_label("观赏模式", side + Vector2(0, 66), MUTED)
	# A tiny water barrel makes the open space feel like a field, not a table.
	_box(Rect2(side + Vector2(2, 82), Vector2(20, 24)), SOIL_DARK)
	_box(Rect2(side + Vector2(4, 84), Vector2(16, 20)), Color("#bfa683"))
	_box(Rect2(side + Vector2(4, 83), Vector2(16, 5)), WATER)
	_box(Rect2(side + Vector2(2, 92), Vector2(20, 2)), Color("#7b8071"))
	_box(Rect2(side + Vector2(2, 101), Vector2(20, 2)), Color("#7b8071"))
	_target_positions["region_" + str(index)] = side + Vector2(53, 95)

func _draw_plot(rect: Rect2, plot: Dictionary, region_open: bool) -> void:
	var opened := region_open and bool(plot.get("open", false))
	if not opened:
		_box(rect, Color("#91a283") if region_open else Color("#8ca080"))
		_box(rect.grow(-2), Color("#a2ae92"))
		_draw_lock(rect.position + Vector2(12, 12), 1)
		return
	var status := str(plot.get("status", "empty"))
	var tint := SOIL if status in ["empty", "unwatered"] else Color("#886e56")
	_box(rect, SOIL_DARK)
	_box(rect.grow(-1), tint)
	_box(Rect2(rect.position + Vector2(2, 2), Vector2(28, 2)), Color("#b69a77"))
	for row in [10, 18, 26]:
		_box(Rect2(rect.position + Vector2(3, row), Vector2(26, 1)), SOIL_DARK)
	_plot_hits.append({"rect": rect, "id": str(plot.get("id", ""))})
	_target_positions[str(plot.get("id", ""))] = rect.get_center()
	if status != "empty":
		var crop: Dictionary = _crops.get(str(plot.get("crop_id", "parsnip")), {})
		var growth := 0.0
		if status in ["ready", "processing"]:
			growth = 1.0
		elif status == "growing":
			growth = clampf(1.0 - float(plot.get("remaining", 0)) / maxf(1, float(crop.get("grow_seconds", 720))), 0, 1)
		_draw_crop(rect.position + Vector2(6, 6), str(crop.get("id", "parsnip")), growth, status)
		if status == "unwatered":
			_draw_drop(rect.position + Vector2(25, 3), RED)
		elif status == "ready":
			_star(rect.position + Vector2(26, 6), GOLD)
		elif status == "processing":
			_box(Rect2(rect.position + Vector2(3, 27), Vector2(26, 3)), CREAM)
			var progress := 1.0 - float(plot.get("remaining", 0)) / 180.0
			_box(Rect2(rect.position + Vector2(3, 27), Vector2(floor(26 * clampf(progress, 0, 1)), 3)), GOLD)
	if str(plot.get("id", "")) == _hover:
		_canvas().draw_rect(rect, CREAM, false, 2, false)

func _draw_crop(origin: Vector2, id: String, growth: float, status: String) -> void:
	var color := _crop_color(id)
	var palette := {"g": Color("#527850"), "l": Color("#81a46b"), "s": Color("#647249"), "p": color, "y": GOLD}
	var pattern: Array = SPROUT
	if growth > 0.33 or status in ["ready", "processing"]:
		pattern = LEAF_CROP
	if growth > 0.7 or status in ["ready", "processing"]:
		if id in ["blue_jazz", "tulip", "poppy", "summer_spangle", "fairy_rose", "sunflower", "mixed_flower_seeds"]:
			pattern = FLOWER
		elif id in ["unmilled_rice", "wheat", "fiber", "hops", "tea_leaves"]:
			pattern = WHEAT
		elif bool(_crops.get(id, {}).get("regrow", false)):
			pattern = BUSH
		else:
			pattern = ROOT_CROP
	_sprite(pattern, palette, origin, 2)

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
	var available := maxf(192, view_width - 48)
	var columns := clampi(int(floor(available / 30.0)), 6, 24)
	var modules: Array = []
	var first := 0
	while first < 24:
		var count := mini(columns, 24 - first)
		modules.append({"kind": "grass", "first": first, "columns": count, "width": count * 30.0})
		first += count
	for barn in config.get("barns", config.get("shelters", [])):
		modules.append({"kind": "barn", "barn": barn, "width": 128.0})
	modules.append({"kind": "storage", "width": 128.0})
	var pages: Array = []
	var current: Array = []
	var used := 0.0
	for module in modules:
		var gap := 0.0 if current.is_empty() else 16.0
		if used + gap + float(module.width) > available and not current.is_empty():
			pages.append(current)
			current = []
			used = 0.0
			gap = 0.0
		current.append(module)
		used += gap + float(module.width)
	if not current.is_empty():
		pages.append(current)
	return pages

func _draw_ranch() -> void:
	var pages := _ranch_pages()
	var current: Array = pages[clampi(page, 0, pages.size() - 1)]
	var x := 24.0
	for module in current:
		match str(module.kind):
			"grass": _draw_grass_section(Vector2(x, 0), int(module.first), int(module.columns))
			"barn": _draw_barn(Vector2(x, 0), module.barn)
			"storage": _draw_storage(Vector2(x, 0))
		x += float(module.width) + 16

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
	for step in range(4):
		_box(Rect2(origin + Vector2(8 + step * 4, 30 - step * 4), Vector2(112 - step * 8, 4)), roof)
	_box(Rect2(origin + Vector2(8, 34), Vector2(112, 24)), Color("#e1d4af") if level > 0 else Color("#bbc1a6"))
	_box(Rect2(origin + Vector2(18, 39), Vector2(16, 12)), SOIL_DARK)
	_box(Rect2(origin + Vector2(20, 41), Vector2(12, 8)), WATER_LIGHT)
	_box(Rect2(origin + Vector2(52, 38), Vector2(24, 20)), SOIL_DARK)
	_box(Rect2(origin + Vector2(54, 40), Vector2(20, 18)), Color("#ac916f"))
	_box(Rect2(origin + Vector2(3, 60), Vector2(122, 87)), Color("#afbd92") if level > 0 else Color("#a0af8f"))
	_box(Rect2(origin + Vector2(3, 145), Vector2(122, 2)), SOIL_DARK)
	for px in range(3, 126, 20):
		_box(Rect2(origin + Vector2(px, 137), Vector2(3, 15)), Color("#cebd94"))
	_box(Rect2(origin + Vector2(3, 140), Vector2(122, 3)), Color("#d9c9a2"))
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
	var pattern: Array = CHICKEN
	var body := Color("#f0e8c8")
	match id:
		"duck", "dinosaur": pattern = DUCK
		"rabbit": pattern = RABBIT
		"cow", "goat", "ostrich": pattern = COW
		"sheep": pattern = SHEEP
		"pig":
			pattern = PIG
			body = Color("#d9aaa0")
	if id == "void_chicken": body = Color("#897889")
	if id == "golden_chicken": body = GOLD
	if id == "dinosaur": body = Color("#b4c48f")
	if id == "ostrich": body = Color("#c8bca5")
	var adult := bool(animal.get("adult", false))
	var pixel := 2 if adult else 1
	var bob := int(sin(_animation_seconds * 2 + float(absi(str(animal.get("id", "")).hash()) % 17)) > 0)
	var pos := origin + Vector2(3 if adult else 8, 2 + bob if adult else 9 + bob)
	_box(Rect2(origin + Vector2(5, 23), Vector2(18, 2)), Color("#94a482"))
	var palette := {"f": body, "r": Color("#b97e6d"), "k": INK, "y": GOLD,
		"o": Color("#c89d69"), "g": Color("#729975"), "s": Color("#8c8777"), "p": Color("#d4b5a3")}
	_sprite(pattern, palette, pos, pixel)
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
	var left := 140.0 if view_width >= 640 else 44.0
	var right := 100.0 if view_width >= 640 else 30.0
	_pond_bounds = Rect2(left, 25, maxf(160, view_width - left - right), 127)
	_box(_pond_bounds.grow(5), Color("#d1c7a5"))
	_box(_pond_bounds.grow(2), Color("#7d9d93"))
	_box(_pond_bounds, WATER)
	_box(Rect2(_pond_bounds.position, Vector2(_pond_bounds.size.x, 7)), Color("#7eacb7"))
	_box(Rect2(_pond_bounds.position + Vector2(0, _pond_bounds.size.y - 7), Vector2(_pond_bounds.size.x, 7)), WATER_LIGHT)
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
	_target_positions["pond_dock"] = Vector2(left - 12, 104)

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
	var color := Color("#e0e8d9")
	if type_id == "blueback_fish": color = Color("#6c97a2")
	if type_id == "goldstripe_fish": color = Color("#e6c486")
	_box(Rect2(center + Vector2(-9, 5), Vector2(19, 2)), Color("#81adb9"))
	_sprite(FISH, {"l": color.darkened(0.1), "f": color, "k": INK}, center + Vector2(-13, -7), 2)
	_fish_hits.append({"id": id, "rect": Rect2(center + Vector2(-17, -11), Vector2(34, 22))})

func _draw_farmers() -> void:
	var farmers: Array = model_state.get("farmers", [])
	var visible_index := 0
	for farmer in farmers:
		if str(farmer.get("scene", "")) != scene_name:
			continue
		var mode := str(farmer.get("mode", "idle"))
		var pos := Vector2(180 + visible_index * 30, 126)
		if scene_name == "ranch":
			pos = Vector2(50 + visible_index * 30, 129)
		elif scene_name == "pond":
			pos = _target_positions.get("pond_dock", Vector2(60, 108)) + Vector2(-11 + visible_index * 25, -19)
		elif scene_name == "farm":
			var region_index := page * _farm_slots()
			pos = _target_positions.get("region_" + str(region_index), pos) + Vector2(-11 + visible_index * 25, -15)
		var task: Dictionary = farmer.get("task", {})
		var target := str(task.get("target", ""))
		if mode == "working" and _target_positions.has(target):
			var target_pos: Vector2 = _target_positions[target]
			pos = target_pos + Vector2(7, -12)
			pos.y = clampf(pos.y, 27, 134)
			pos.x = clampf(pos.x, 4, view_width - 28)
		var moving := mode in ["working", "outbound", "returning"]
		var bob := int(sin(_animation_seconds * 8) > 0) if moving else 0
		var shirt := Color("#799b94") if str(farmer.get("home", "")) == scene_name else Color("#9a98ad")
		_sprite(FARMER, {"h": Color("#d3bc82"), "f": Color("#d9bba0"), "k": INK,
			"b": shirt, "d": Color("#69828a")}, pos + Vector2(0, bob), 2)
		if mode == "resting":
			_label("z", pos + Vector2(21, 3), CREAM)
		elif mode == "working":
			var action := str(task.get("action", ""))
			if action == "water":
				_box(Rect2(pos + Vector2(20, 16), Vector2(6, 6)), WATER_LIGHT)
				_draw_drop(pos + Vector2(26, 25), WATER_LIGHT)
			elif action in ["harvest", "collect_product", "cut_grass"]:
				_box(Rect2(pos + Vector2(23, 13), Vector2(2, 15)), SOIL_DARK)
				_box(Rect2(pos + Vector2(20, 12), Vector2(8, 3)), CREAM)
		_box(Rect2(pos + Vector2(2, 28), Vector2(20, 2)), Color("#718769"))
		_box(Rect2(pos + Vector2(2, 28), Vector2(floor(20 * float(farmer.get("energy", 100)) / 100), 2)), GOLD)
		visible_index += 1

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
