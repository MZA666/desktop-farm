class_name FarmState
extends RefCounted

## Pure simulation: no Nodes, wall-clock reads or rendering dependencies.
## All seconds measure active process time. tick() is the only clock entry point.
signal changed

const SAVE_VERSION := 2
const SEED_PLAN = preload("res://scripts/seed_planner.gd")
const WORLD = preload("res://scripts/world_layout.gd")
const SCENES := ["farm", "ranch", "pond"]
var config: Dictionary = {}
var state: Dictionary = {}
var crops: Dictionary = {}
var animal_types: Dictionary = {}
var shelter_types: Dictionary = {}
var fish_types: Dictionary = {}
var _tick_fraction := 0.0
var crop_order: Array = []

func _init(values: Dictionary = {}) -> void:
	config_from(values)
	if not crops.is_empty():
		new_game()

func config_from(values: Dictionary) -> void:
	config = values.duplicate(true)
	crops = _index(config.get("crops", []))
	crop_order = []
	for crop in config.get("crops", []): crop_order.append(str(crop.id))
	animal_types = _index(config.get("animals", []))
	shelter_types = _index(config.get("shelters", []))
	fish_types = _index(config.get("fish", []))

func _index(items: Variant) -> Dictionary:
	if items is Dictionary:
		return items.duplicate(true)
	var result := {}
	for item in items:
		result[str(item.id)] = item
	return result

func _p(key: String, fallback: Variant) -> Variant:
	return config.get("parameters", {}).get(key, fallback)

func _uid(prefix: String) -> String:
	var result := "%s_%d" % [prefix, int(state.next_id)]
	state.next_id = int(state.next_id) + 1
	return result

func new_game() -> void:
	var initial: Dictionary = config.get("initial", {})
	var default_crop := str(initial.get("crop_id", "parsnip"))
	state = {
		"version": SAVE_VERSION, "config_version": str(config.get("version", "0.5")),
		"coins": int(initial.get("coins", 1000)), "elapsed": 0.0, "next_id": 1,
		"tick_fraction": 0.0, "paid_hires": 0, "transaction_id": 0,
		"plots": [], "seeds": initial.get("seeds", {"parsnip": 24}).duplicate(true),
		"default_seed_id": "parsnip", "previous_default_seed_id": "", "seed_reservations": [],
		"unlocked_crops": [], "grass": [], "grass_seeds": 0,
		"grass_remaining": float(_p("grass_growth_seconds", 180)),
		"warehouse_hay": int(initial.get("warehouse_hay", 0)),
		"trough_hay": int(initial.get("trough_hay", 8)), "storage_level": 0,
		"shelters": initial.get("barn_levels", {"chicken_coop": 1}).duplicate(true),
		"animals": [], "farmers": [], "fish": [], "pending_fish": {},
		"fish_remaining": float(_p("fish_spawn_seconds", 180)), "net_remaining": 0.0,
		"catalog": {}, "rng": {"grass": 1567331, "fish": 3917737, "crop": 998231},
		"settings": {"topmost": false, "interactive": true, "power_saving": false, "collapsed": false, "farmer_speed": 32.0},
	}
	_tick_fraction = 0.0
	for id in crops:
		if int(crops[id].get("unlock_price", 0)) == 0:
			state.unlocked_crops.append(id)
	for index in range(96):
		state.plots.append({"id": "plot_%d_%d" % [index / 16, index % 16], "index": index,
			"open": index < int(initial.get("crop_plots", 24)), "crop_id": default_crop,
			"preferred_crop_id": default_crop, "pending_crop_id": "",
			"status": "empty", "remaining": 0.0, "return_seed": false, "product": {}, "queued_at": 0.0})
	for gi in range(int(_p("max_grass_plots", 96))):
		var opened := gi < int(initial.get("grass_plots", 6))
		state.grass.append({"id": "grass_%d" % gi, "index": gi, "open": opened,
			"clumps": int(initial.get("grass_clumps", 4)) if opened else 0,
			"mother": gi < int(initial.get("mother_grass_plots", 2))})
	for id in shelter_types:
		if not state.shelters.has(id):
			state.shelters[id] = 0
	for entry in initial.get("animals", [{"id": "chicken", "count": 4}]):
		for unused in range(int(entry.get("count", 1))):
			_add_animal(str(entry.id))
	for scene in SCENES:
		for unused in range(int(initial.get("farmers_per_scene", 1))):
			_add_farmer(scene)
	for unused in range(int(initial.get("fish_count", 12))):
		_spawn_fish()
	changed.emit()

func balance() -> int:
	return int(state.get("coins", 0))

func investable() -> int:
	return maxi(0, balance() - protection())

## Seed inventory is assigned in stable plot order, first to unsown current
## batches, then to the next batch. An in-flight sow reservation is never also
## counted as a free seed. Pending switches replace the old next-batch budget.
func protection() -> int:
	return SEED_PLAN.protection(state, crops, crop_order)

func get_plots() -> Array:
	return state.plots

func plot_expansion_price() -> int:
	var owned: int = state.plots.filter(func(p): return bool(p.open)).size()
	var prices: Array = config.get("upgrades", {}).get("individual_plot_costs", [])
	return int(prices[owned - 24]) if owned >= 24 and owned < 96 and prices.size() == 72 else -1

func seed_preview(plot_id: String) -> Dictionary:
	var plot := _find(state.plots, plot_id)
	if plot.is_empty(): return _result(false, "地块不存在")
	for farmer in state.farmers:
		var task: Dictionary = farmer.task
		if str(task.get("action", "")) == "sow" and str(task.get("target", "")) == plot_id:
			return {"ok": true, "crop_id": str(task.crop_id), "source": str(task.seed_source), "cost": 0, "in_flight": true}
	var chosen: Dictionary = SEED_PLAN.choose(plot.duplicate(true), state.seeds.duplicate(true), state.seed_reservations.duplicate(true), crops, crop_order, str(state.default_seed_id))
	chosen.ok = true
	chosen.in_flight = false
	return chosen

func seed_inventory_summary(crop_id: String) -> Dictionary:
	var reserved := 0
	var in_flight := 0
	for claim in state.seed_reservations:
		if str(claim.crop_id) == crop_id: reserved += int(claim.quantity)
	for farmer in state.farmers:
		var task: Dictionary = farmer.task
		if str(task.get("action", "")) == "sow" and str(task.get("crop_id", "")) == crop_id and str(task.get("seed_source", "")) != "dedicated": in_flight += 1
	var available := int(state.seeds.get(crop_id, 0))
	return {"available": available, "reserved": reserved, "in_flight": in_flight, "total": available + reserved + in_flight}
func get_animals() -> Array:
	return state.animals
func get_farmers() -> Array:
	return state.farmers
func get_fish() -> Array:
	return state.fish
func get_grass() -> Array:
	return state.grass
func get_catalog() -> Dictionary:
	return state.catalog

func storage_capacity() -> int:
	var levels: Array = config.get("upgrades", {}).get("hay_storage", [{"capacity": 24}, {"capacity": 64}, {"capacity": 128}, {"capacity": 256}])
	return int(levels[int(state.storage_level)].capacity)

func shelter_capacity(id: String) -> int:
	var level := int(state.shelters.get(id, 0))
	if level == 0:
		return 0
	var capacities: Array = shelter_types.get(id, {}).get("capacities", [4, 8, 12])
	return int(capacities[level - 1])

func snapshot() -> Dictionary:
	var result := state.duplicate(true)
	result.tick_fraction = _tick_fraction
	return result

func restore(data: Dictionary) -> Dictionary:
	if _integer(data.get("version")) and int(data.version) == 1:
		var migrated := migrate_v1(data)
		if not migrated.ok: return migrated
		data = migrated.data
	var checked := _validate(data)
	if not checked.ok:
		return checked
	state = data.duplicate(true)
	_tick_fraction = float(state.get("tick_fraction", 0.0))
	# Bad/stale claims are safely released; valid active actions resume their timer.
	var claims := {}
	for farmer in state.farmers:
		var task: Dictionary = farmer.get("task", {})
		if task.is_empty():
			continue
		var key := "%s:%s" % [task.get("action", ""), task.get("target", "")]
		if claims.has(key) or not _task_valid(task):
			_cancel_task(farmer)
		else:
			claims[key] = true
	changed.emit()
	return _result(true, "存档已恢复")

func _validate(data: Dictionary) -> Dictionary:
	if not _integer(data.get("version")) or int(data.version) != SAVE_VERSION:
		return _result(false, "不支持的存档版本")
	if data.has("regions") or not data.get("seed_reservations") is Array:
		return _result(false, "存档种植结构无效")
	if not data.has("previous_default_seed_id"): return _result(false, "存档缺少上一默认种")
	if not data.get("unlocked_crops") is Array or not crops.has(str(data.get("default_seed_id", ""))) or not data.unlocked_crops.has(str(data.default_seed_id)):
		return _result(false, "默认订购种无效")
	if not str(data.get("previous_default_seed_id", "")).is_empty() and not crops.has(str(data.previous_default_seed_id)):
		return _result(false, "上一默认订购种无效")
	if not data.get("settings") is Dictionary or not _number(data.settings.get("farmer_speed")) or float(data.settings.farmer_speed) < 16 or float(data.settings.farmer_speed) > 48:
		return _result(false, "农夫速度无效")
	if not data.get("plots") is Array or data.plots.size() != 96: return _result(false, "地块数量无效")
	if not data.get("farmers") is Array: return _result(false, "农夫列表无效")
	var legacy := data.duplicate(true)
	legacy.version = 1
	legacy.regions = []
	for ri in range(6): legacy.regions.append({"index": ri, "unlocked": true, "current_crop_id": "parsnip", "pending_crop_id": ""})
	for i in range(data.plots.size()):
		var plot: Variant = data.plots[i]
		if not plot is Dictionary or plot.has("region") or not _integer(plot.get("index")) or int(plot.index) != i:
			return _result(false, "地块全局位置无效")
		if not crops.has(str(plot.get("preferred_crop_id", ""))) or (not str(plot.get("pending_crop_id", "")).is_empty() and not crops.has(str(plot.pending_crop_id))):
			return _result(false, "地块种植计划无效")
		legacy.plots[i].region = i / 16
		legacy.plots[i].index = i % 16
	var common := _validate_v1(legacy)
	if not common.ok: return common
	var claim_keys := {}
	for claim in data.seed_reservations:
		if not claim is Dictionary or not _integer(claim.get("quantity")) or int(claim.quantity) != 1 or not ["pending_first", "pending_next"].has(str(claim.get("purpose", ""))):
			return _result(false, "种子预留数量或用途无效")
		var plot := _find(data.plots, str(claim.get("plot_id", "")))
		var expected := str(plot.get("pending_crop_id", ""))
		if expected.is_empty(): expected = str(plot.get("preferred_crop_id", ""))
		var key := str(claim.plot_id) + ":" + str(claim.purpose)
		if plot.is_empty() or not bool(plot.open) or str(claim.get("crop_id", "")) != expected or claim_keys.has(key): return _result(false, "种子预留绑定无效")
		claim_keys[key] = true
	for farmer in data.farmers:
		for key in ["x", "y", "path_target_x", "path_target_y"]:
			if not _number(farmer.get(key)): return _result(false, "农夫坐标无效")
		if not WORLD.is_position_valid(str(farmer.scene), Vector2(float(farmer.x), float(farmer.y))) or not WORLD.is_position_valid(str(farmer.scene), Vector2(float(farmer.path_target_x), float(farmer.path_target_y))): return _result(false, "农夫超出世界边界")
		if not ["idle", "walking", "acting"].has(str(farmer.get("phase", ""))) or (str(farmer.mode) == "working" and str(farmer.phase) == "idle") or (str(farmer.mode) != "working" and str(farmer.phase) != "idle"):
			return _result(false, "农夫任务阶段无效")
		if str(farmer.phase) == "acting" and Vector2(float(farmer.x), float(farmer.y)).distance_to(Vector2(float(farmer.path_target_x), float(farmer.path_target_y))) > 0.001: return _result(false, "动作阶段尚未到达")
	return _result(true, "有效")

func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floorf(float(value))

func _finite_tree(value: Variant) -> bool:
	if value is float: return is_finite(value)
	if value is Array:
		for item in value:
			if not _finite_tree(item): return false
	elif value is Dictionary:
		for item in value.values():
			if not _finite_tree(item): return false
	return true

func migrate_v1(data: Dictionary) -> Dictionary:
	var checked := _validate_v1(data)
	if not checked.ok: return checked
	var migrated := data.duplicate(true)
	migrated.version = SAVE_VERSION
	migrated.default_seed_id = "parsnip"
	migrated.previous_default_seed_id = ""
	migrated.seed_reservations = []
	migrated.settings.farmer_speed = 32.0
	for i in range(migrated.plots.size()):
		var plot: Dictionary = migrated.plots[i]
		var pending := str(data.regions[int(plot.region)].pending_crop_id)
		plot.preferred_crop_id = str(plot.crop_id)
		plot.pending_crop_id = pending if bool(plot.open) and pending != str(plot.crop_id) else ""
		plot.erase("region")
		plot.index = i
	migrated.erase("regions")
	var slots := {"farm": 0, "ranch": 0, "pond": 0}
	for farmer in migrated.farmers:
		var scene := str(farmer.scene)
		var pos: Vector2 = WORLD.farmer_idle_position(scene, int(slots[scene]))
		slots[scene] = int(slots[scene]) + 1
		farmer.phase = "idle"
		if str(farmer.mode) == "working":
			pos = WORLD.target_position(scene, str(farmer.task.get("target", "")), migrated)
			farmer.phase = "acting"
		farmer.x = pos.x
		farmer.y = pos.y
		farmer.path_target_x = pos.x
		farmer.path_target_y = pos.y
	_fill_seed_reservations(migrated)
	var valid := _validate(migrated)
	if not valid.ok: return valid
	return {"ok": true, "data": migrated, "message": "v1存档已转换为独立地块"}

func _validate_v1(data: Dictionary) -> Dictionary:
	if not _finite_tree(data): return _result(false, "旧存档包含非有限数值")
	if not _integer(data.get("version")) or int(data.version) != 1:
		return _result(false, "不支持的旧存档版本")
	for key in ["config_version", "coins", "elapsed", "next_id", "regions", "plots", "seeds", "unlocked_crops", "grass", "animals", "farmers", "fish", "shelters", "rng", "catalog", "pending_fish", "settings", "storage_level", "warehouse_hay", "trough_hay", "grass_seeds", "paid_hires", "transaction_id", "grass_remaining", "fish_remaining", "net_remaining"]:
		if not data.has(key):
			return _result(false, "存档缺少字段：" + key)
	for key in ["regions", "plots", "unlocked_crops", "grass", "animals", "farmers", "fish"]:
		if not data[key] is Array:
			return _result(false, "存档字段类型无效：" + key)
	for key in ["seeds", "shelters", "rng", "catalog", "pending_fish", "settings"]:
		if not data[key] is Dictionary:
			return _result(false, "存档字段类型无效：" + key)
	for key in ["topmost", "interactive", "power_saving", "collapsed"]:
		if not data.settings.get(key) is bool: return _result(false, "存档窗口设置无效：" + key)
	if data.settings.has("window_position"):
		var position: Variant = data.settings.window_position
		if not position is Array or position.size() != 2 or not _number(position[0]) or not _number(position[1]): return _result(false, "存档窗口位置无效")
	for key in ["regions", "plots", "grass", "animals", "farmers", "fish"]:
		for object in data[key]:
			if not object is Dictionary:
				return _result(false, "存档对象类型无效：" + key)
	for key in ["coins", "elapsed", "next_id", "warehouse_hay", "trough_hay", "grass_seeds", "paid_hires", "transaction_id", "grass_remaining", "fish_remaining", "net_remaining"]:
		if not (data[key] is int or data[key] is float) or float(data[key]) < 0 or not is_finite(float(data[key])):
			return _result(false, "存档资源或计时无效：" + key)
	for key in ["coins", "next_id", "warehouse_hay", "trough_hay", "grass_seeds", "paid_hires", "transaction_id", "storage_level"]:
		if not _integer(data.get(key)): return _result(false, "存档整数资源无效：" + key)
	if not _number(data.get("tick_fraction", 0.0)) or float(data.get("tick_fraction", 0.0)) < 0 or float(data.get("tick_fraction", 0.0)) >= 1: return _result(false, "存档分数时钟无效")
	if int(data.storage_level) < 0 or int(data.storage_level) > 3 or int(data.paid_hires) > 6:
		return _result(false, "存档升级等级无效")
	var storage_levels: Array = config.get("upgrades", {}).get("hay_storage", [{"capacity": 24}, {"capacity": 64}, {"capacity": 128}, {"capacity": 256}])
	var capacity := int(storage_levels[int(data.storage_level)].capacity)
	if int(data.warehouse_hay) > capacity or int(data.trough_hay) > capacity:
		return _result(false, "存档干草超出容量")
	if data.regions.size() != 6 or data.plots.size() != 96 or data.grass.size() != 96 or data.fish.size() > 12 or data.farmers.size() > 9:
		return _result(false, "存档对象数量无效")
	var ids := {}
	var highest_generated_id := 0
	var home_counts := {"farm": 0, "ranch": 0, "pond": 0}
	var present_counts := {"farm": 0, "ranch": 0, "pond": 0}
	var shelter_counts := {}
	for ri in range(data.regions.size()):
		var region: Dictionary = data.regions[ri]
		if not _integer(region.get("index")) or int(region.index) != ri or not region.get("unlocked") is bool:
			return _result(false, "存档区域位置无效")
		if not crops.has(str(region.get("current_crop_id", ""))) or (not str(region.get("pending_crop_id", "")).is_empty() and not crops.has(str(region.pending_crop_id))):
			return _result(false, "存档区域作物无效")
	for pi in range(data.plots.size()):
		var plot: Dictionary = data.plots[pi]
		for key in ["id", "region", "index", "open", "crop_id", "status", "remaining", "return_seed", "product", "queued_at"]:
			if not plot.has(key):
				return _result(false, "存档地块缺少字段：" + key)
		if not _valid_object_id(plot, ids) or not crops.has(str(plot.get("crop_id", ""))) or not ["empty", "unwatered", "growing", "ready", "processing"].has(str(plot.get("status", ""))):
			return _result(false, "存档地块无效")
		if not _integer(plot.region) or not _integer(plot.index) or int(plot.region) != pi / 16 or int(plot.index) != pi % 16 or str(plot.id) != "plot_%d_%d" % [pi / 16, pi % 16] or not _number(plot.remaining) or float(plot.remaining) < 0 or not _number(plot.queued_at) or float(plot.queued_at) < 0 or not plot.product is Dictionary or not plot.open is bool or not plot.return_seed is bool:
			return _result(false, "存档地块计时或位置无效")
		if plot.open and not data.regions[int(plot.region)].unlocked:
			return _result(false, "存档未解锁区域存在开放地块")
	for gi in range(data.grass.size()):
		var grass: Dictionary = data.grass[gi]
		if not _valid_object_id(grass, ids) or not _integer(grass.get("index")) or int(grass.index) != gi or not _integer(grass.get("clumps")) or int(grass.clumps) < 0 or int(grass.clumps) > 4 or not grass.get("mother") is bool or not grass.get("open") is bool:
			return _result(false, "存档牧草无效")
	for animal in data.animals:
		for key in ["id", "type_id", "adult", "adult_remaining", "product_remaining", "food_remaining", "hungry", "ready", "queued_at"]:
			if not animal.has(key):
				return _result(false, "存档动物缺少字段：" + key)
		if not _valid_object_id(animal, ids) or not animal_types.has(str(animal.get("type_id", ""))):
			return _result(false, "存档动物无效")
		highest_generated_id = maxi(highest_generated_id, int(str(animal.id).get_slice("_", 1)))
		for key in ["adult_remaining", "product_remaining", "food_remaining", "ready"]:
			if not _number(animal.get(key)) or float(animal[key]) < 0:
				return _result(false, "存档动物计时无效")
		if not animal.adult is bool or not animal.hungry is bool or not _integer(animal.ready) or not _number(animal.queued_at): return _result(false, "存档动物状态无效")
		if int(animal.ready) > 1:
			return _result(false, "存档动物产物数量无效")
		var sid := str(animal_types[str(animal.type_id)].shelter_id)
		shelter_counts[sid] = int(shelter_counts.get(sid, 0)) + 1
	for id in shelter_types:
		var level := int(data.shelters.get(id, 0))
		if not _integer(data.shelters.get(id)) or level < 0 or level > 3 or int(shelter_counts.get(id, 0)) > level * 4:
			return _result(false, "存档棚舍容量无效")
	for farmer in data.farmers:
		for key in ["id", "home", "scene", "energy", "mode", "remaining", "destination", "task"]:
			if not farmer.has(key):
				return _result(false, "存档农夫缺少字段：" + key)
		if not _valid_object_id(farmer, ids) or not SCENES.has(str(farmer.get("home", ""))) or not SCENES.has(str(farmer.get("scene", ""))):
			return _result(false, "存档农夫无效")
		highest_generated_id = maxi(highest_generated_id, int(str(farmer.id).get_slice("_", 1)))
		if not _number(farmer.energy) or not _number(farmer.remaining) or float(farmer.energy) < 0 or float(farmer.energy) > 100 or float(farmer.remaining) < 0 or not farmer.task is Dictionary or not ["idle", "resting", "working", "outbound", "returning"].has(str(farmer.get("mode", ""))):
			return _result(false, "存档农夫状态无效")
		if str(farmer.mode) == "working" and farmer.task.is_empty(): return _result(false, "工作任务缺失")
		if not farmer.task.is_empty():
			if not ["sow", "water", "harvest", "cut_grass", "sow_grass", "add_hay", "collect_product"].has(str(farmer.task.get("action", ""))) or str(farmer.task.get("target", "")).is_empty(): return _result(false, "旧任务结构无效")
			if str(farmer.task.action) == "sow" and (not crops.has(str(farmer.task.get("crop_id", ""))) or not ["inventory", "dedicated", "reservation", "automatic"].has(str(farmer.task.get("seed_source", "")))): return _result(false, "播种领用无效")
		home_counts[str(farmer.home)] += 1
		if str(farmer.mode) in ["outbound", "returning"]:
			if not SCENES.has(str(farmer.destination)):
				return _result(false, "存档支援目的地无效")
			present_counts[str(farmer.destination)] += 1
		else:
			present_counts[str(farmer.scene)] += 1
	for count in home_counts.values():
		if int(count) > 3:
			return _result(false, "存档农夫本岗容量无效")
	for count in present_counts.values():
		if int(count) > 3:
			return _result(false, "存档农夫在场或预留容量无效")
	for fish in data.fish:
		if not _valid_object_id(fish, ids) or not fish_types.has(str(fish.get("type_id", ""))):
			return _result(false, "存档鱼无效")
		highest_generated_id = maxi(highest_generated_id, int(str(fish.id).get_slice("_", 1)))
	if not data.pending_fish.is_empty() and not fish_types.has(str(data.pending_fish.get("type_id", ""))):
		return _result(false, "存档待处理鱼无效")
	if not data.pending_fish.is_empty():
		if not _valid_object_id(data.pending_fish, ids):
			return _result(false, "存档待处理鱼ID无效")
		highest_generated_id = maxi(highest_generated_id, int(str(data.pending_fish.id).get_slice("_", 1)))
	if int(data.next_id) <= highest_generated_id:
		return _result(false, "存档对象序号无效")
	for id in data.seeds:
		if not crops.has(str(id)) or not _integer(data.seeds[id]) or int(data.seeds[id]) < 0:
			return _result(false, "存档种子库存无效")
	for id in data.unlocked_crops:
		if not crops.has(str(id)):
			return _result(false, "存档解锁作物无效")
	for stream in ["crop", "grass", "fish"]:
		if not _integer(data.rng.get(stream)) or int(data.rng[stream]) <= 0 or int(data.rng[stream]) >= 2147483647:
			return _result(false, "存档随机状态无效")
	return _result(true, "有效")

func _valid_object_id(object: Dictionary, ids: Dictionary) -> bool:
	var id := str(object.get("id", ""))
	if id.is_empty() or ids.has(id):
		return false
	ids[id] = true
	return true

func _result(ok: bool, message: String) -> Dictionary:
	return {"ok": ok, "message": message}

## UI persists successful user commands immediately. Automatic production is
## captured by the regular 30 second snapshot, without disk I/O in this class.
func command(action: String, payload: Dictionary = {}) -> Dictionary:
	var before := snapshot()
	var result := _execute_command(action, payload)
	if not result.ok:
		state = before
		_tick_fraction = float(before.tick_fraction)
		return result
	state.transaction_id = int(state.transaction_id) + 1
	changed.emit()
	return result

func _check_investment() -> Dictionary:
	if balance() < protection():
		return _result(false, "金币不足：需要保留 %d 金币补种预算" % protection())
	return _result(true, "操作完成")

func _execute_command(action: String, payload: Dictionary) -> Dictionary:
	match action:
		"water":
			var plot := _find(state.plots, str(payload.get("plot_id", "")))
			if plot.is_empty() or not plot.open or str(plot.status) != "unwatered":
				return _result(false, "这块地暂时不需要浇水")
			_cancel_target("water", str(plot.id))
			plot.status = "growing"
			plot.queued_at = float(state.elapsed)
			return _result(true, "已浇水")
		"set_crop":
			var id := str(payload.get("crop_id", ""))
			var plots := _selected_plots(payload)
			if plots.is_empty() or not crops.has(id): return _result(false, "地块或作物无效")
			if not state.unlocked_crops.has(id):
				return _result(false, "请先解锁此作物")
			for plot in plots:
				_release_plot_reservations(str(plot.id))
				if str(plot.status) == "empty" and not _has_task("sow", str(plot.id)):
					plot.preferred_crop_id = id
					plot.pending_crop_id = ""
					if str(plot.crop_id) != id: plot.return_seed = false
				else: plot.pending_crop_id = id if id != str(plot.crop_id) else ""
			_fill_seed_reservations(state)
			return _check_investment()
		"cancel_crop":
			var plots := _selected_plots(payload)
			if plots.is_empty(): return _result(false, "地块无效")
			for plot in plots:
				plot.pending_crop_id = ""
				_release_plot_reservations(str(plot.id))
			return _result(true, "已取消尚未生效的切换")
		"buy_seeds":
			var id := str(payload.get("crop_id", ""))
			var count: Variant = payload.get("count", 1)
			if not crops.has(id) or not state.unlocked_crops.has(id) or not _integer(count) or int(count) < 1 or int(count) > 1000000:
				return _result(false, "种子品种或购买数量无效")
			state.coins = balance() - int(count) * int(crops[id].seed_price)
			state.seeds[id] = int(state.seeds.get(id, 0)) + int(count)
			_fill_seed_reservations(state)
			return _check_investment()
		"set_default_seed":
			var id := str(payload.get("crop_id", ""))
			if not crops.has(id) or not state.unlocked_crops.has(id): return _result(false, "请先解锁默认种子")
			state.previous_default_seed_id = str(state.default_seed_id)
			state.default_seed_id = id
			return _check_investment()
		"unlock_crop":
			var id := str(payload.get("crop_id", ""))
			if not crops.has(id) or state.unlocked_crops.has(id):
				return _result(false, "此作物不存在或已解锁")
			state.coins = balance() - int(crops[id].unlock_price)
			state.unlocked_crops.append(id)
			return _check_investment()
		"expand_plot":
			var price := plot_expansion_price()
			if price < 0: return _result(false, "地块已开满或费用配置无效")
			var target := {}
			for plot in state.plots:
				if not plot.open:
					target = plot
					break
			if target.is_empty(): return _result(false, "地块已开满96格")
			state.coins = balance() - price
			target.open = true
			target.preferred_crop_id = str(state.default_seed_id)
			return _check_investment()
		"expand_grass":
			var target := {}
			for grass in state.grass:
				if not grass.open:
					target = grass
					break
			if target.is_empty():
				return _result(false, "牧草地已开满")
			var costs: Array = config.get("upgrades", {}).get("grass_plot_costs", [])
			var cost := int(costs[int(target.index)]) if not costs.is_empty() else 50 * (1 + floori(float(int(target.index) - 6) / 6.0))
			state.coins = balance() - cost
			target.open = true
			return _check_investment()
		"buy_grass_seed":
			var count := int(payload.get("count", 1))
			if count < 1 or count > 96:
				return _result(false, "购买数量无效")
			state.coins = balance() - count * int(_p("grass_seed_cost", 100))
			state.grass_seeds = int(state.grass_seeds) + count
			return _check_investment()
		"upgrade_storage":
			var next := int(state.storage_level) + 1
			var levels: Array = config.get("upgrades", {}).get("hay_storage", [{"capacity": 24, "cost": 0}, {"capacity": 64, "cost": 400}, {"capacity": 128, "cost": 1200}, {"capacity": 256, "cost": 3000}])
			if next >= levels.size():
				return _result(false, "草仓和食槽已满级")
			state.coins = balance() - int(levels[next].cost)
			state.storage_level = next
			return _check_investment()
		"upgrade_shelter":
			var id := str(payload.get("shelter_id", ""))
			if not shelter_types.has(id):
				return _result(false, "棚舍无效")
			var level := int(state.shelters[id])
			if level >= 3:
				return _result(false, "棚舍已满级")
			state.coins = balance() - int(shelter_types[id].costs[level])
			state.shelters[id] = level + 1
			return _check_investment()
		"buy_animal":
			var id := str(payload.get("animal_id", ""))
			if not animal_types.has(id):
				return _result(false, "动物无效")
			var kind: Dictionary = animal_types[id]
			var sid := str(kind.shelter_id)
			if int(state.shelters.get(sid, 0)) < int(kind.min_level):
				return _result(false, "棚舍等级不足")
			if _animals_in_shelter(sid) >= shelter_capacity(sid):
				return _result(false, "棚位已满，可出售旧动物腾位")
			state.coins = balance() - int(kind.price)
			_add_animal(id)
			return _check_investment()
		"sell_animal":
			var instance_id := str(payload.get("instance_id", ""))
			var animal := _find(state.animals, instance_id)
			if animal.is_empty():
				return _result(false, "动物已不存在")
			_cancel_target("collect_product", instance_id)
			if int(animal.ready) > 0:
				_collect_animal(animal)
			var refund := floori(float(animal_types[str(animal.type_id)].price) * float(_p("animal_refund_ratio", 0.5)))
			state.coins = balance() + refund
			state.animals.erase(animal)
			return _result(true, "出售完成，返还 %d 金币" % refund)
		"hire_farmer":
			var scene := str(payload.get("scene", ""))
			if not SCENES.has(scene) or _home_count(scene) >= 3 or _occupancy(scene) >= 3:
				return _result(false, "本岗或在场名额已满（上限3人）")
			var costs: Array = config.get("upgrades", {}).get("farmer_costs", [1000, 2000, 4000, 8000, 16000, 32000])
			if int(state.paid_hires) >= costs.size():
				return _result(false, "已达到农夫总人数上限")
			state.coins = balance() - int(costs[int(state.paid_hires)])
			state.paid_hires = int(state.paid_hires) + 1
			_add_farmer(scene)
			return _check_investment()
		"transfer_farmer":
			var farmer := _find(state.farmers, str(payload.get("farmer_id", "")))
			var scene := str(payload.get("scene", ""))
			if farmer.is_empty() or not SCENES.has(scene) or str(farmer.home) == scene:
				return _result(false, "农夫或目标岗位无效")
			if not ["idle", "resting"].has(str(farmer.mode)) or str(farmer.scene) != str(farmer.home):
				return _result(false, "请等农夫完成动作并回到本岗")
			if _home_count(scene) >= 3 or _occupancy(scene) >= 3:
				return _result(false, "目标岗位已满")
			farmer.home = scene
			farmer.scene = scene
			var position: Vector2 = WORLD.farmer_idle_position(scene, _home_count(scene) - 1)
			farmer.x = position.x
			farmer.y = position.y
			farmer.path_target_x = position.x
			farmer.path_target_y = position.y
			return _result(true, "免费转岗完成")
		"cast_net":
			if not state.pending_fish.is_empty():
				return _result(false, "请先处理刚捕到的鱼")
			if float(state.net_remaining) > 0:
				return _result(false, "渔网还需冷却 %d 秒" % ceili(float(state.net_remaining)))
			state.net_remaining = float(_p("net_cooldown_seconds", 20))
			var fish := _find(state.fish, str(payload.get("fish_id", "")))
			if fish.is_empty():
				return _result(true, "未命中，渔网进入冷却")
			state.pending_fish = fish.duplicate(true)
			state.fish.erase(fish)
			return _result(true, "捕获成功，请选择出售或登记图鉴")
		"resolve_fish":
			if state.pending_fish.is_empty():
				return _result(false, "没有待处理的鱼")
			var choice := str(payload.get("choice", ""))
			if not ["sell", "catalog"].has(choice):
				return _result(false, "请选择出售或登记")
			var fish: Dictionary = state.pending_fish
			var kind: Dictionary = fish_types[str(fish.type_id)]
			if choice == "sell":
				state.coins = balance() + int(kind.sell_price)
			else:
				_register_product(str(kind.get("product_id", kind.id)), str(kind.name), "fish", int(kind.sell_price))
			state.pending_fish = {}
			return _result(true, "鱼已出售" if choice == "sell" else "已登记图鉴")
		"settings":
			var raw_values: Variant = payload.get("values", {})
			if not raw_values is Dictionary: return _result(false, "设置格式无效")
			var values: Dictionary = raw_values
			for key in ["topmost", "interactive", "power_saving", "collapsed"]:
				if values.has(key) and not values[key] is bool: return _result(false, "设置开关格式无效")
			if values.has("farmer_speed") and (not _number(values.farmer_speed) or float(values.farmer_speed) < 16 or float(values.farmer_speed) > 48): return _result(false, "农夫速度范围为16至48")
			if values.has("window_position"):
				var position: Variant = values.window_position
				if not position is Array or position.size() != 2 or not (position[0] is int or position[0] is float) or not (position[1] is int or position[1] is float) or not is_finite(float(position[0])) or not is_finite(float(position[1])):
					return _result(false, "窗口位置无效")
			for key in ["topmost", "interactive", "power_saving", "collapsed", "window_x", "window_y", "window_position", "monitor", "farmer_speed"]:
				if values.has(key):
					state.settings[key] = values[key]
			return _result(true, "设置已更新")
	return _result(false, "未知操作：" + action)

func _find(items: Array, id: String) -> Dictionary:
	for item in items:
		if str(item.id) == id:
			return item
	return {}

func _selected_plots(payload: Dictionary) -> Array:
	var ids: Variant = payload.get("plot_ids", [])
	if not ids is Array or ids.is_empty(): return []
	var selected: Array = []
	var seen := {}
	for id in ids:
		if not id is String or seen.has(id): return []
		var plot := _find(state.plots, str(id))
		if plot.is_empty() or not bool(plot.open): return []
		seen[id] = true
		selected.append(plot)
	return selected

func _release_plot_reservations(id: String) -> void:
	for i in range(state.seed_reservations.size() - 1, -1, -1):
		var claim: Dictionary = state.seed_reservations[i]
		if str(claim.plot_id) == id:
			state.seeds[str(claim.crop_id)] = int(state.seeds.get(str(claim.crop_id), 0)) + int(claim.quantity)
			state.seed_reservations.remove_at(i)

func _fill_seed_reservations(target_state: Dictionary) -> void:
	# Fill every first-batch claim before any second-batch claim.
	for purpose in ["pending_first", "pending_next"]:
		for plot in target_state.plots:
			var id := str(plot.get("pending_crop_id", ""))
			if not bool(plot.open) or id.is_empty(): continue
			if purpose == "pending_next" and (bool(crops[id].regrow) or bool(crops[id].return_seed)): continue
			var exists := false
			for claim in target_state.seed_reservations:
				if str(claim.plot_id) == str(plot.id) and str(claim.purpose) == purpose: exists = true; break
			if not exists and int(target_state.seeds.get(id, 0)) > 0:
				target_state.seeds[id] = int(target_state.seeds[id]) - 1
				target_state.seed_reservations.append({"plot_id": str(plot.id), "crop_id": id, "quantity": 1, "purpose": purpose})

func _add_animal(id: String) -> void:
	var kind: Dictionary = animal_types[id]
	state.animals.append({"id": _uid("animal"), "type_id": id, "adult": false,
		"adult_remaining": float(kind.adult_seconds), "product_remaining": float(kind.produce_seconds),
		"food_remaining": 0.0, "hungry": true, "ready": 0, "queued_at": float(state.elapsed)})

func _add_farmer(scene: String) -> void:
	var pos: Vector2 = WORLD.farmer_idle_position(scene, _home_count(scene))
	state.farmers.append({"id": _uid("farmer"), "home": scene, "scene": scene,
		"energy": 100.0, "mode": "idle", "remaining": 0.0, "destination": "", "task": {},
		"x": pos.x, "y": pos.y, "path_target_x": pos.x, "path_target_y": pos.y, "phase": "idle"})

func _animals_in_shelter(id: String) -> int:
	var count := 0
	for animal in state.animals:
		if str(animal_types[str(animal.type_id)].shelter_id) == id:
			count += 1
	return count

func _home_count(scene: String) -> int:
	return state.farmers.filter(func(f): return str(f.home) == scene).size()

func _occupancy(scene: String, excluding: String = "") -> int:
	var count := 0
	for farmer in state.farmers:
		if str(farmer.id) == excluding:
			continue
		if str(farmer.mode) in ["outbound", "returning"]:
			if str(farmer.destination) == scene:
				count += 1
		elif str(farmer.scene) == scene:
			count += 1
	return count

func tick(delta: float) -> void:
	if delta <= 0 or state.is_empty():
		return
	_tick_fraction += delta
	var steps := floori(_tick_fraction)
	_tick_fraction -= float(steps)
	for unused in range(steps):
		_step(1.0)
	if steps > 0:
		changed.emit()

func _step(dt: float) -> void:
	state.elapsed = float(state.elapsed) + dt
	for plot in state.plots:
		if not plot.open:
			continue
		if str(plot.status) == "growing":
			plot.remaining = maxf(0, float(plot.remaining) - dt)
			if float(plot.remaining) == 0:
				plot.status = "ready"
				plot.queued_at = float(state.elapsed)
		elif str(plot.status) == "processing":
			plot.remaining = maxf(0, float(plot.remaining) - dt)
			if float(plot.remaining) == 0:
				_sell_plot_product(plot)
				_finish_crop_cycle(plot)
	state.grass_remaining = float(state.grass_remaining) - dt
	while float(state.grass_remaining) <= 0:
		_grow_grass()
		state.grass_remaining = float(state.grass_remaining) + float(_p("grass_growth_seconds", 180))
	for animal in state.animals:
		_advance_animal(animal, dt)
	state.net_remaining = maxf(0, float(state.net_remaining) - dt)
	if state.fish.size() < int(_p("fish_capacity", 12)):
		state.fish_remaining = float(state.fish_remaining) - dt
		if float(state.fish_remaining) <= 0:
			_spawn_fish()
			state.fish_remaining = float(_p("fish_spawn_seconds", 180))
	for farmer in state.farmers:
		_advance_farmer(farmer, dt)
	# Home workers returning from visits have priority over visitor claims.
	for farmer in state.farmers:
		if str(farmer.scene) != str(farmer.home) and str(farmer.mode) == "idle":
			if _has_work(str(farmer.home)) or not _has_work(str(farmer.scene)):
				_return_home(farmer)
	for farmer in state.farmers:
		if str(farmer.mode) == "idle":
			_dispatch(farmer)

func _random(stream: String) -> float:
	# Park-Miller generator fits safely inside signed 64-bit integers and survives JSON.
	var value := (int(state.rng[stream]) * 48271) % 2147483647
	state.rng[stream] = value
	return float(value) / 2147483647.0

func _random_int(stream: String, low: int, high: int) -> int:
	return low + mini(high - low, floori(_random(stream) * float(high - low + 1)))

func _grow_grass() -> void:
	var before: Array = state.grass.duplicate(true)
	var additions := {}
	for grass in before:
		if not grass.open or int(grass.clumps) == 0:
			continue
		var index := int(grass.index)
		var grown := mini(4, int(grass.clumps) + _random_int("grass", 1, 3))
		state.grass[index].clumps = grown
		if _random("grass") >= float(_p("grass_extra_probability", 0.65)):
			continue
		if grown < 4:
			state.grass[index].clumps = mini(4, grown + _random_int("grass", 0, 2))
		else:
			var column := index % 24
			var neighbors: Array = [index - 24, index + 24]
			if column > 0:
				neighbors.append(index - 1)
			if column < 23:
				neighbors.append(index + 1)
			for ni in neighbors:
				if int(ni) < 0 or int(ni) >= before.size():
					continue
				var target: Dictionary = before[int(ni)]
				if target.open and int(target.clumps) == 0 and _random("grass") < float(_p("grass_spread_probability", 0.25)):
					additions[int(ni)] = int(additions.get(int(ni), 0)) + _random_int("grass", 1, 2)
	for index in additions:
		state.grass[int(index)].clumps = mini(4, int(additions[index]))

func _meal(animal: Dictionary) -> bool:
	var needs := int(animal_types[str(animal.type_id)].food_grass)
	var available := 0
	for grass in state.grass:
		if grass.open and not grass.mother:
			available += maxi(0, int(grass.clumps) - 1)
	if available >= needs:
		for grass in state.grass:
			if not grass.open or grass.mother:
				continue
			var take := mini(needs, maxi(0, int(grass.clumps) - 1))
			grass.clumps = int(grass.clumps) - take
			needs -= take
			if needs == 0:
				break
	elif int(state.trough_hay) > 0:
		state.trough_hay = int(state.trough_hay) - 1
	else:
		animal.hungry = true
		return false
	animal.food_remaining = float(_p("meal_seconds", 300))
	animal.hungry = false
	return true

func _advance_animal(animal: Dictionary, dt: float) -> void:
	if float(animal.food_remaining) <= 0:
		_meal(animal)
	var effective := minf(dt, float(animal.food_remaining))
	var progress := effective
	if not animal.adult:
		var used := minf(progress, float(animal.adult_remaining))
		animal.adult_remaining = maxf(0, float(animal.adult_remaining) - used)
		progress -= used
		if float(animal.adult_remaining) == 0:
			animal.adult = true
			animal.product_remaining = float(animal_types[str(animal.type_id)].produce_seconds)
	if animal.adult and int(animal.ready) == 0:
		animal.product_remaining = maxf(0, float(animal.product_remaining) - progress)
		if float(animal.product_remaining) == 0:
			animal.ready = 1
			animal.queued_at = float(state.elapsed)
	animal.food_remaining = maxf(0, float(animal.food_remaining) - dt)
	if float(animal.food_remaining) <= 0:
		_meal(animal)

func _spawn_fish() -> void:
	var total := 0.0
	for fish in fish_types.values():
		total += float(fish.get("weight", 1.0))
	var choice := _random("fish") * total
	var chosen := ""
	for id in fish_types:
		chosen = str(id)
		choice -= float(fish_types[id].get("weight", 1.0))
		if choice < 0:
			break
	if chosen.is_empty():
		return
	state.fish.append({"id": _uid("fish"), "type_id": chosen,
		"x": 0.05 + _random("fish") * 0.9, "y": 0.15 + _random("fish") * 0.7})

func _product_for_crop(crop: Dictionary) -> Dictionary:
	var pool: Array = crop.get("pool", [])
	if pool.is_empty():
		var product_id := str(crop.get("product_id", crop.id))
		var product: Dictionary = config.get("products", {}).get(product_id, {})
		return {"id": product_id, "name": str(product.get("name", crop.get("product_name", crop.name))), "sell_price": int(crop.sell_price)}
	var total := 0.0
	for item in pool:
		total += float(item.get("weight", 1))
	var choice := _random("crop") * total
	for item in pool:
		choice -= float(item.get("weight", 1))
		if choice < 0:
			return {"id": str(item.product_id), "name": str(item.name), "sell_price": int(item.sell_price)}
	var last: Dictionary = pool.back()
	return {"id": str(last.product_id), "name": str(last.name), "sell_price": int(last.sell_price)}

func _register_product(id: String, product_name: String, source: String, price: int) -> void:
	if not state.catalog.has(id):
		state.catalog[id] = {"id": id, "name": product_name, "count": 0,
			"first_obtained": float(state.elapsed), "sources": [], "sell_price": price}
	state.catalog[id].count = int(state.catalog[id].count) + 1
	if not state.catalog[id].sources.has(source):
		state.catalog[id].sources.append(source)

func _sell_plot_product(plot: Dictionary) -> void:
	var product: Dictionary = plot.product
	if product.is_empty():
		product = _product_for_crop(crops[str(plot.crop_id)])
	state.coins = balance() + int(product.sell_price)
	_register_product(str(product.id), str(product.name), str(plot.crop_id), int(product.sell_price))

func _finish_crop_cycle(plot: Dictionary) -> void:
	var crop: Dictionary = crops[str(plot.crop_id)]
	var pending := str(plot.pending_crop_id)
	if not pending.is_empty() and pending != str(plot.crop_id):
		plot.preferred_crop_id = pending
		plot.pending_crop_id = ""
		plot.status = "empty"
		plot.return_seed = false
		plot.product = {}
		plot.remaining = 0.0
		plot.queued_at = float(state.elapsed)
		return
	if bool(crop.get("regrow", false)):
		plot.status = "unwatered"
		plot.remaining = float(crop.repeat_seconds)
		plot.product = _product_for_crop(crop)
	else:
		plot.status = "empty"
		plot.remaining = 0.0
		plot.product = {}
		plot.return_seed = bool(crop.get("return_seed", false))
	plot.queued_at = float(state.elapsed)

func _collect_animal(animal: Dictionary) -> void:
	if int(animal.ready) == 0:
		return
	var kind: Dictionary = animal_types[str(animal.type_id)]
	state.coins = balance() + int(kind.sell_price)
	var product: Dictionary = config.get("products", {}).get(str(kind.product_id), {})
	_register_product(str(kind.product_id), str(product.get("name", kind.get("product_name", kind.name))), str(kind.id), int(kind.sell_price))
	animal.ready = 0
	animal.product_remaining = float(kind.produce_seconds)

func _has_task(action: String, target: String) -> bool:
	for farmer in state.get("farmers", []):
		var task: Dictionary = farmer.get("task", {})
		if str(task.get("action", "")) == action and str(task.get("target", "")) == target:
			return true
	return false

func _reserved_amount(action: String) -> int:
	var count := 0
	for farmer in state.farmers:
		var task: Dictionary = farmer.task
		if str(task.get("action", "")) == action:
			count += int(task.get("amount", 1))
	return count

func _tasks(scene: String) -> Array:
	var tasks: Array = []
	if scene == "farm":
		for plot in state.plots:
			if not plot.open:
				continue
			var action := ""
			var priority := 0
			match str(plot.status):
				"ready":
					action = "harvest"
					priority = 0
				"unwatered":
					action = "water"
					priority = 1
				"empty":
					var preview := seed_preview(str(plot.id))
					if int(preview.cost) <= balance():
						action = "sow"
						priority = 2
			if not action.is_empty() and not _has_task(action, str(plot.id)):
				tasks.append({"action": action, "target": str(plot.id), "priority": priority, "queued_at": float(plot.queued_at)})
	elif scene == "ranch":
		var low: bool = int(state.trough_hay) < state.animals.size() * 2
		var room := storage_capacity() - int(state.trough_hay) - _reserved_amount("add_hay")
		if int(state.warehouse_hay) > 0 and room > 0 and not _has_task("add_hay", "trough"):
			tasks.append({"action": "add_hay", "target": "trough", "priority": 0 if low else 2, "queued_at": 0.0})
		for animal in state.animals:
			if int(animal.ready) == 1 and not _has_task("collect_product", str(animal.id)):
				tasks.append({"action": "collect_product", "target": str(animal.id), "priority": 2 if low else 0, "queued_at": float(animal.queued_at)})
		for grass in state.grass:
			if not grass.open or grass.mother:
				continue
			if int(grass.clumps) == 4 and int(state.warehouse_hay) + _reserved_amount("cut_grass") < storage_capacity() and not _has_task("cut_grass", str(grass.id)):
				tasks.append({"action": "cut_grass", "target": str(grass.id), "priority": 1, "queued_at": 0.0})
			elif int(grass.clumps) == 0 and int(state.grass_seeds) > 0 and not _has_task("sow_grass", str(grass.id)):
				tasks.append({"action": "sow_grass", "target": str(grass.id), "priority": 3, "queued_at": 0.0})
	for i in range(tasks.size()):
		tasks[i].order = i
	tasks.sort_custom(func(a, b):
		if int(a.priority) != int(b.priority):
			return int(a.priority) < int(b.priority)
		if float(a.queued_at) != float(b.queued_at):
			return float(a.queued_at) < float(b.queued_at)
		return int(a.order) < int(b.order))
	return tasks

func _has_work(scene: String) -> bool:
	return not _tasks(scene).is_empty()

func _task_cost(action: String) -> int:
	var costs: Dictionary = _p("task_energy", {"sow": 2, "water": 1, "harvest": 1, "cut_grass": 1, "add_hay": 1, "sow_grass": 2, "collect_product": 1})
	return int(costs.get(action, 1))

func _dispatch(farmer: Dictionary) -> void:
	var tasks := _tasks(str(farmer.scene))
	if not tasks.is_empty():
		var task: Dictionary = tasks.front()
		if float(farmer.energy) < _task_cost(str(task.action)):
			if str(farmer.scene) != str(farmer.home):
				_return_home(farmer)
			else:
				farmer.mode = "resting"
			return
		if _reserve_task(task):
			farmer.task = task
			farmer.mode = "working"
			var destination: Vector2 = WORLD.target_position(str(farmer.scene), str(task.target), state)
			farmer.path_target_x = destination.x
			farmer.path_target_y = destination.y
			var distance := Vector2(float(farmer.x), float(farmer.y)).distance_to(destination)
			farmer.phase = "walking" if distance > 0.001 else "acting"
			farmer.remaining = distance / float(state.settings.farmer_speed) if distance > 0.001 else float(_p("action_seconds", 2))
		return
	if str(farmer.scene) == str(farmer.home) and float(farmer.energy) >= 100:
		for scene in SCENES:
			if scene != str(farmer.home) and _occupancy(scene) < 3 and _has_work(scene):
				farmer.energy = float(farmer.energy) - float(_p("support_energy", 20))
				farmer.mode = "outbound"
				farmer.phase = "idle"
				farmer.destination = scene
				farmer.remaining = float(_p("support_seconds", 5))
				return

func _reserve_task(task: Dictionary) -> bool:
	var action := str(task.action)
	if action == "sow":
		var plot := _find(state.plots, str(task.target))
		if plot.is_empty() or str(plot.status) != "empty":
			return false
		var seeds: Dictionary = state.seeds.duplicate(true)
		var claims: Array = state.seed_reservations.duplicate(true)
		var projected := plot.duplicate(true)
		var chosen: Dictionary = SEED_PLAN.choose(projected, seeds, claims, crops, crop_order, str(state.default_seed_id))
		if int(chosen.cost) > balance(): return false
		state.seeds = seeds
		state.seed_reservations = claims
		state.coins = balance() - int(chosen.cost)
		plot.return_seed = bool(projected.return_seed)
		if not str(plot.pending_crop_id).is_empty():
			plot.preferred_crop_id = str(plot.pending_crop_id)
			plot.pending_crop_id = ""
		plot.crop_id = str(chosen.crop_id)
		task.crop_id = str(chosen.crop_id)
		task.seed_source = str(chosen.source)
	elif action == "add_hay":
		var room := storage_capacity() - int(state.trough_hay) - _reserved_amount("add_hay")
		var amount := mini(int(_p("hay_transfer_max", 4)), mini(room, int(state.warehouse_hay)))
		if amount <= 0:
			return false
		task.amount = amount
		# Keep reserved outgoing hay in the warehouse until the atomic transfer.
		# Otherwise another worker could fill the freed slots and make cancellation
		# overflow the warehouse. Only one trough transfer may be claimed at once.
	elif action == "sow_grass":
		if int(state.grass_seeds) <= 0:
			return false
		state.grass_seeds = int(state.grass_seeds) - 1
	return true

func _task_valid(task: Dictionary) -> bool:
	var action := str(task.get("action", ""))
	var target := str(task.get("target", ""))
	match action:
		"sow", "water", "harvest":
			var plot := _find(state.plots, target)
			if plot.is_empty() or not plot.open:
				return false
			if action == "sow" and (str(task.get("crop_id", "")) != str(plot.crop_id) or not ["inventory", "dedicated", "reservation", "automatic"].has(str(task.get("seed_source", "")))):
				return false
			return str(plot.status) == {"sow": "empty", "water": "unwatered", "harvest": "ready"}[action]
		"add_hay":
			return int(task.get("amount", 0)) > 0 and int(state.warehouse_hay) >= int(task.amount) and int(state.trough_hay) + int(task.amount) <= storage_capacity()
		"cut_grass", "sow_grass":
			var grass := _find(state.grass, target)
			if grass.is_empty() or not grass.open or grass.mother:
				return false
			return (int(grass.clumps) == 4 and int(state.warehouse_hay) < storage_capacity()) if action == "cut_grass" else int(grass.clumps) == 0
		"collect_product":
			var animal := _find(state.animals, target)
			return not animal.is_empty() and int(animal.ready) == 1
	return false

func _advance_farmer(farmer: Dictionary, dt: float) -> void:
	match str(farmer.mode):
		"working":
			if not _task_valid(farmer.task): _cancel_task(farmer); return
			var available := dt
			if str(farmer.phase) == "walking":
				var position := Vector2(float(farmer.x), float(farmer.y))
				var destination := Vector2(float(farmer.path_target_x), float(farmer.path_target_y))
				var speed := float(state.settings.farmer_speed)
				var distance := position.distance_to(destination)
				var travel := minf(available, distance / speed)
				position = position.move_toward(destination, speed * travel)
				farmer.x = position.x
				farmer.y = position.y
				available -= travel
				farmer.remaining = position.distance_to(destination) / speed
				if float(farmer.remaining) > 0.000001: return
				farmer.phase = "acting"
				farmer.remaining = float(_p("action_seconds", 2))
			farmer.remaining = maxf(0, float(farmer.remaining) - available)
			if float(farmer.remaining) <= 0.000001:
				_commit_task(farmer.task)
				farmer.energy = maxf(0, float(farmer.energy) - _task_cost(str(farmer.task.action)))
				farmer.task = {}
				farmer.mode = "idle"
				farmer.phase = "idle"
				farmer.remaining = 0.0
		"outbound", "returning":
			farmer.remaining = maxf(0, float(farmer.remaining) - dt)
			if float(farmer.remaining) == 0:
				farmer.scene = str(farmer.destination)
				farmer.destination = ""
				farmer.mode = "idle"
				farmer.phase = "idle"
				var position: Vector2 = WORLD.farmer_idle_position(str(farmer.scene), int(str(farmer.id).get_slice("_", 1)) % 3)
				farmer.x = position.x
				farmer.y = position.y
				farmer.path_target_x = position.x
				farmer.path_target_y = position.y
		"resting", "idle":
			farmer.energy = minf(100, float(farmer.energy) + float(_p("rest_energy_per_second", 2)) * dt)
			if str(farmer.mode) == "resting" and float(farmer.energy) >= 100:
				farmer.mode = "idle"

func _commit_task(task: Dictionary) -> void:
	match str(task.action):
		"sow":
			var plot := _find(state.plots, str(task.target))
			var crop: Dictionary = crops[str(plot.crop_id)]
			plot.status = "unwatered"
			plot.remaining = float(crop.first_seconds)
			plot.product = _product_for_crop(crop)
			plot.queued_at = float(state.elapsed)
		"water":
			var plot := _find(state.plots, str(task.target))
			plot.status = "growing"
			plot.queued_at = float(state.elapsed)
		"harvest":
			var plot := _find(state.plots, str(task.target))
			var crop: Dictionary = crops[str(plot.crop_id)]
			if float(crop.get("processing_seconds", 0)) > 0:
				var raw_id := str(crop.get("raw_product_id", ""))
				if not raw_id.is_empty():
					var raw: Dictionary = config.get("products", {}).get(raw_id, {"name": "未碾米", "sell_price": 30})
					_register_product(raw_id, str(raw.get("name", "未碾米")), str(crop.id), int(raw.get("sell_price", raw.get("sale_price", 30))))
				plot.status = "processing"
				plot.remaining = float(crop.processing_seconds)
			else:
				_sell_plot_product(plot)
				_finish_crop_cycle(plot)
		"cut_grass":
			var grass := _find(state.grass, str(task.target))
			grass.clumps = 1
			state.warehouse_hay = int(state.warehouse_hay) + 1
		"sow_grass":
			var grass := _find(state.grass, str(task.target))
			grass.clumps = 4
		"add_hay":
			state.warehouse_hay = int(state.warehouse_hay) - int(task.amount)
			state.trough_hay = int(state.trough_hay) + int(task.amount)
		"collect_product":
			_collect_animal(_find(state.animals, str(task.target)))

func _cancel_task(farmer: Dictionary) -> void:
	var task: Dictionary = farmer.task
	match str(task.get("action", "")):
		"sow":
			var id := str(task.get("crop_id", ""))
			if str(task.get("seed_source", "")) == "dedicated":
				var plot := _find(state.plots, str(task.target))
				if not plot.is_empty() and str(plot.crop_id) == id:
					plot.return_seed = true
			elif crops.has(id):
				state.seeds[id] = int(state.seeds.get(id, 0)) + 1
		"sow_grass":
			state.grass_seeds = int(state.grass_seeds) + 1
	farmer.task = {}
	farmer.remaining = 0.0
	farmer.mode = "idle"
	farmer.phase = "idle"
	farmer.path_target_x = float(farmer.x)
	farmer.path_target_y = float(farmer.y)
	_fill_seed_reservations(state)

func _cancel_target(action: String, target: String) -> void:
	for farmer in state.farmers:
		if str(farmer.task.get("action", "")) == action and str(farmer.task.get("target", "")) == target:
			_cancel_task(farmer)

func _return_home(farmer: Dictionary) -> void:
	if str(farmer.scene) == str(farmer.home):
		return
	# Plan all dependent visitor departures before changing any reservations.
	# This handles a three-scene cycle just like a two-scene exchange, without
	# transiently reserving four arrivals or waiting for mutually occupied slots.
	var moves := {}
	if not _plan_return(farmer, moves):
		return
	for scene in SCENES:
		if _planned_occupancy(scene, moves) > 3:
			return
	for id in moves:
		var returning := _find(state.farmers, str(id))
		returning.mode = "returning"
		returning.destination = str(moves[id])
		returning.remaining = float(_p("support_seconds", 5))

func _planned_occupancy(scene: String, moves: Dictionary) -> int:
	var count := 0
	for farmer in state.farmers:
		var place := str(farmer.scene)
		if moves.has(str(farmer.id)):
			place = str(moves[str(farmer.id)])
		elif str(farmer.mode) in ["outbound", "returning"]:
			place = str(farmer.destination)
		if place == scene:
			count += 1
	return count

func _plan_return(farmer: Dictionary, moves: Dictionary) -> bool:
	if moves.has(str(farmer.id)):
		return true
	var home := str(farmer.home)
	moves[str(farmer.id)] = home
	while _planned_occupancy(home, moves) > 3:
		var candidate := {}
		for visitor in state.farmers:
			if str(visitor.scene) == home and str(visitor.home) != home and str(visitor.mode) == "idle" and not moves.has(str(visitor.id)):
				candidate = visitor
				break
		if candidate.is_empty() or not _plan_return(candidate, moves):
			return false
	return true
