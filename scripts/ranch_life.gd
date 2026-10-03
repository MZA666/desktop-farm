class_name FarmRanchLife
extends RefCounted

## Pure 5 Hz world behaviour. Meal claims remain physical stock until an
## animal visits every claimed patch and finishes the complete meal.
const WORLD = preload("res://scripts/world_layout.gd")
const PRODUCTS = preload("res://scripts/ground_products.gd")
const BEHAVIORS := ["leaving", "idle", "wandering", "to_food", "eating", "being_collected", "interacting"]

static func point(object: Dictionary) -> Vector2:
	return Vector2(float(object.x), float(object.y))

static func pack_path(points: Array) -> Array:
	var packed: Array = []
	for position in points: packed.append({"x": position.x, "y": position.y})
	return packed

static func path_length(start: Vector2, path: Array) -> float:
	var length := 0.0
	for entry in path:
		var next := point(entry)
		length += start.distance_to(next)
		start = next
	return length

static func initialize_grass(state: Dictionary) -> void:
	for grass in state.grass:
		var position: Vector2 = WORLD.grass_anchor(int(grass.index))
		grass.x = position.x
		grass.y = position.y
		grass.appearance = (int(grass.index) * 73 + 19) % 997

static func initialize_animal(state: Dictionary, animal: Dictionary, kinds: Dictionary) -> void:
	var kind: Dictionary = kinds[str(animal.type_id)]
	var shelter := str(kind.shelter_id)
	var position: Vector2 = WORLD.shelter_exit(shelter)
	var slot := 0
	for other in state.animals:
		if other == animal: break
		if str(other.get("shelter_id", "")) == shelter: slot += 1
	position = WORLD.clamp_to_walkable("ranch", position + Vector2((slot % 4 - 1.5) * 10, (slot / 4) * 8))
	animal.merge({"shelter_id": shelter, "x": position.x, "y": position.y,
		"previous_x": position.x, "previous_y": position.y, "facing": "down", "behavior": "leaving",
		"path": [], "target": {}, "decision_remaining": 0.0, "food_decision_remaining": 0.0, "meal": {}, "eating_remaining": 2.0,
		"held_by": "", "hold_remaining": 0.0, "feedback_remaining": 0.0,
		"last_reward_elapsed": -120.0, "juvenile_bonus_used": 0.0, "adult_bonus_used": 0.0,
		"production_cycle": 0, "last_drop_cycle": -1}, true)

static func _random(state: Dictionary) -> float:
	state.rng.animal = (int(state.rng.animal) * 48271) % 2147483647
	return float(state.rng.animal) / 2147483647.0

static func grass_reserved(state: Dictionary, id: String, except_animal := "", except_task: Dictionary = {}) -> int:
	var reserved := 0
	for animal in state.animals:
		if str(animal.id) == except_animal: continue
		for claim in animal.get("meal", {}).get("grass", []):
			if str(claim.id) == id: reserved += int(claim.amount)
	for farmer in state.farmers:
		var task: Dictionary = farmer.task
		if task == except_task: continue
		if str(task.get("action", "")) == "cut_grass" and str(task.get("target", "")) == id:
			reserved += int(task.get("grass_amount", 3))
	return reserved

static func grass_available(state: Dictionary, grass: Dictionary, except_animal := "", except_task: Dictionary = {}) -> int:
	if not grass.open or grass.mother: return 0
	return maxi(0, int(grass.clumps) - 1 - grass_reserved(state, str(grass.id), except_animal, except_task))

static func hay_reserved(state: Dictionary, except_animal := "") -> int:
	var reserved := 0
	for animal in state.animals:
		if str(animal.id) != except_animal and str(animal.get("meal", {}).get("source", "")) == "hay": reserved += 1
	return reserved

static func grass_ledger(state: Dictionary) -> Dictionary:
	var ledger := {}
	for animal in state.animals:
		for claim in animal.get("meal", {}).get("grass", []):
			ledger[str(claim.id)] = int(ledger.get(str(claim.id), 0)) + int(claim.amount)
	for farmer in state.farmers:
		if str(farmer.task.get("action", "")) == "cut_grass":
			var id := str(farmer.task.target)
			ledger[id] = int(ledger.get(id, 0)) + int(farmer.task.get("grass_amount", 3))
	return ledger

static func _find(entries: Array, id: String) -> Dictionary:
	for entry in entries:
		if str(entry.id) == id: return entry
	return {}

static func release_meal(animal: Dictionary) -> void:
	animal.meal = {}
	animal.path = []
	animal.target = {}
	animal.eating_remaining = 2.0
	animal.behavior = "idle"
	animal.decision_remaining = 1.0
	animal.food_decision_remaining = 1.0

static func reserve_meal(state: Dictionary, animal: Dictionary, kinds: Dictionary, due_only := false) -> bool:
	if not animal.meal.is_empty(): return true
	var needs := int(kinds[str(animal.type_id)].food_grass)
	var candidates: Array = []
	var origin := point(animal)
	var ledger := grass_ledger(state)
	for grass in state.grass:
		if grass.open and not grass.mother and int(grass.clumps) - 1 - int(ledger.get(str(grass.id), 0)) > 0: candidates.append(grass)
	candidates.sort_custom(func(a, b): return origin.distance_squared_to(point(a)) < origin.distance_squared_to(point(b)))
	var claims: Array = []
	var route: Array = []
	var position := origin
	for grass in candidates:
		var available := maxi(0, int(grass.clumps) - 1 - int(ledger.get(str(grass.id), 0)))
		var destination := point(grass)
		var path: Array = WORLD.find_path("ranch", position, destination)
		if path.is_empty() and position.distance_to(destination) > 0.1: continue
		var take := mini(needs, available)
		claims.append({"id": str(grass.id), "amount": take})
		route.append_array(pack_path(path))
		position = destination
		needs -= take
		if needs == 0: break
	var source := "grass"
	if needs > 0:
		if int(state.trough_hay) - hay_reserved(state) < 1: return false
		position = WORLD.target_position("ranch", "trough", state)
		var path: Array = WORLD.find_path("ranch", origin, position)
		if path.is_empty() and origin.distance_to(position) > 0.1: return false
		route = pack_path(path)
		claims = []
		source = "hay"
	var speed := 12.0 if int(kinds[str(animal.type_id)].food_grass) == 2 else 10.0
	# Decide using the reachable itinerary, not a fixed hunger threshold. The
	# Between five-second decisions a wandering animal can move away at full
	# speed while its food timer also counts down. Budget both changes, the
	# two-second eating action, and fixed-step rounding before departure.
	if due_only and float(animal.food_remaining) > path_length(origin, route) / speed + 13.0: return false
	# No claim is published until the entire meal has a reachable itinerary.
	animal.meal = {"source": source, "grass": claims, "remaining": 240.0}
	animal.path = route
	animal.target = {"kind": source, "x": position.x, "y": position.y}
	animal.behavior = "to_food" if not route.is_empty() else "eating"
	animal.eating_remaining = 2.0
	return true

static func _meal_valid(state: Dictionary, animal: Dictionary, kinds: Dictionary) -> bool:
	var meal: Dictionary = animal.meal
	if meal.is_empty(): return false
	if str(meal.source) == "hay": return int(state.trough_hay) - hay_reserved(state, str(animal.id)) >= 1
	var total := 0
	for claim in meal.grass:
		var grass := _find(state.grass, str(claim.id))
		if grass.is_empty() or grass_available(state, grass, str(animal.id)) < int(claim.amount): return false
		total += int(claim.amount)
	return total == int(kinds[str(animal.type_id)].food_grass)

static func _consume(state: Dictionary, animal: Dictionary, kinds: Dictionary, meal_seconds: float) -> bool:
	if not _meal_valid(state, animal, kinds): return false
	if str(animal.meal.source) == "hay": state.trough_hay = int(state.trough_hay) - 1
	else:
		for claim in animal.meal.grass:
			var grass := _find(state.grass, str(claim.id))
			grass.clumps = int(grass.clumps) - int(claim.amount)
	release_meal(animal)
	animal.food_remaining = meal_seconds
	animal.hungry = false
	animal.decision_remaining = 2.0 + _random(state) * 4.0
	return true

static func _spatial_key(position: Vector2) -> String:
	return "%d:%d" % [floori(position.x / 24.0), floori(position.y / 24.0)]

static func _nearby(spatial: Dictionary, position: Vector2) -> Array:
	var neighbors: Array = []
	var cell := Vector2i(floori(position.x / 24.0), floori(position.y / 24.0))
	for y in range(-1, 2):
		for x in range(-1, 2): neighbors.append_array(spatial.get("%d:%d" % [cell.x + x, cell.y + y], []))
	return neighbors

static func _move(state: Dictionary, animal: Dictionary, dt: float, kinds: Dictionary, spatial: Dictionary) -> void:
	var position := point(animal)
	var speed := 12.0 if int(kinds[str(animal.type_id)].food_grass) == 2 else 10.0
	var budget := speed * dt
	while not animal.path.is_empty() and budget > 0.0001:
		var destination := point(animal.path[0])
		var distance := position.distance_to(destination)
		var moved := minf(budget, distance)
		var next := position.move_toward(destination, moved)
		if distance > moved + 1.0:
			# Steer softly around local actors without spending extra distance or
			# steering through an obstacle/corner. The 24px index is rebuilt at
			# 5Hz, rather than an 84x84 scan on every rendered frame.
			for other in _nearby(spatial, next):
				if str(other.id) == str(animal.id): continue
				var away := next - point(other)
				if away.length_squared() >= 100.0: continue
				if away.length_squared() < 0.001: away = Vector2(0, -1 if int(str(animal.id).get_slice("_", 1)) % 2 == 0 else 1)
				var steering := (destination - position).normalized() + away.normalized() * 0.25
				var candidate := position + steering.normalized() * moved
				if WORLD.segment_walkable("ranch", position, candidate) and WORLD.segment_walkable("ranch", candidate, destination): next = candidate
				break
		if not WORLD.is_walkable("ranch", next):
			release_meal(animal)
			break
		var difference := next - position
		if absf(difference.x) > absf(difference.y): animal.facing = "right" if difference.x >= 0 else "left"
		elif difference.length_squared() > 0.001: animal.facing = "down" if difference.y >= 0 else "up"
		position = next
		budget -= moved
		if position.distance_to(destination) <= 0.0001: animal.path.pop_front()
		else: break
	# Soft separation uses only the unused movement budget and never steps
	# through walls. It does not claim food or perturb the production RNG.
	if budget > 0.01:
		for other in _nearby(spatial, position):
			if str(other.id) == str(animal.id): continue
			var away := position - point(other)
			if away.length_squared() < 36.0 and away.length_squared() > 0.001:
				var separated := position + away.normalized() * minf(budget, 0.5)
				if WORLD.is_walkable("ranch", separated): position = separated
				break
	animal.x = position.x
	animal.y = position.y

static func _collector(state: Dictionary, animal: Dictionary) -> String:
	for farmer in state.farmers:
		if str(farmer.scene) != "ranch" or str(farmer.mode) != "working": continue
		if str(farmer.task.get("action", "")) == "collect_product" and str(farmer.task.target) == str(animal.id) and point(farmer).distance_to(point(animal)) <= 8.0:
			return str(farmer.id)
	return ""

static func _wander(state: Dictionary, animal: Dictionary) -> void:
	var origin := point(animal)
	var distance := 28.0 + _random(state) * 85.0
	var angle := _random(state) * TAU
	var destination: Vector2 = WORLD.clamp_to_walkable("ranch", origin + Vector2(cos(angle), sin(angle)) * distance)
	animal.path = pack_path(WORLD.find_path("ranch", origin, destination))
	animal.target = {"kind": "wander", "x": destination.x, "y": destination.y}
	animal.decision_remaining = 2.0 + _random(state) * 6.0
	animal.behavior = "wandering" if not animal.path.is_empty() else "idle"

static func step(state: Dictionary, kinds: Dictionary, dt: float, meal_seconds := 300.0) -> void:
	var spatial := {}
	for animal in state.animals:
		var key := _spatial_key(point(animal))
		if not spatial.has(key): spatial[key] = []
		spatial[key].append(animal)
	for animal in state.animals:
		animal.previous_x = float(animal.x)
		animal.previous_y = float(animal.y)
		animal.feedback_remaining = maxf(0, float(animal.feedback_remaining) - dt)
		animal.decision_remaining = maxf(0, float(animal.decision_remaining) - dt)
		animal.food_decision_remaining = maxf(0, float(animal.food_decision_remaining) - dt)
		if not animal.meal.is_empty():
			animal.meal.remaining = maxf(0, float(animal.meal.remaining) - dt)
			if float(animal.meal.remaining) <= 0 or not _meal_valid(state, animal, kinds): release_meal(animal)
		animal.held_by = ""
		animal.hold_remaining = 0.0
		if not animal.meal.is_empty():
			if not animal.path.is_empty():
				animal.behavior = "to_food"
				_move(state, animal, dt, kinds, spatial)
			else:
				animal.behavior = "eating"
				animal.eating_remaining = maxf(0, float(animal.eating_remaining) - dt)
				if float(animal.eating_remaining) <= 0.0001 and float(animal.food_remaining) <= 0.0001:
					if not _consume(state, animal, kinds, meal_seconds): release_meal(animal)
			continue
		if float(animal.food_decision_remaining) <= 0:
			animal.food_decision_remaining = 5.0
			if reserve_meal(state, animal, kinds, true): continue
		if not animal.path.is_empty():
			animal.behavior = "wandering"
			_move(state, animal, dt, kinds, spatial)
		elif float(animal.decision_remaining) <= 0:
			_wander(state, animal)
		else: animal.behavior = "interacting" if float(animal.feedback_remaining) > 0 else "idle"

static func interact(state: Dictionary, animal: Dictionary, kinds: Dictionary, products: Dictionary = {}) -> Dictionary:
	if not bool(state.settings.interactive): return {"ok": false, "message": "观察模式不能奖励动物"}
	animal.feedback_remaining = 2.0
	if animal.hungry: return {"ok": true, "message": "它需要食物", "reward_seconds": 0.0}
	var now := float(state.elapsed)
	if now - float(animal.last_reward_elapsed) < 120.0 or now - float(state.ranch.global_reward_elapsed) < 2.0:
		return {"ok": true, "message": "它很开心，奖励仍在冷却", "reward_seconds": 0.0}
	var kind: Dictionary = kinds[str(animal.type_id)]
	var bonus := 0.0
	if not animal.adult:
		bonus = minf(30.0, minf(float(animal.adult_remaining), maxf(0, float(kind.adult_seconds) * 0.2 - float(animal.juvenile_bonus_used))))
		animal.adult_remaining = float(animal.adult_remaining) - bonus
		animal.juvenile_bonus_used = float(animal.juvenile_bonus_used) + bonus
		if float(animal.adult_remaining) <= 0:
			animal.adult = true
			animal.product_remaining = float(kind.produce_seconds)
	else:
		bonus = minf(float(kind.produce_seconds) * 0.05, minf(float(animal.product_remaining), maxf(0, float(kind.produce_seconds) * 0.1 - float(animal.adult_bonus_used))))
		animal.product_remaining = float(animal.product_remaining) - bonus
		animal.adult_bonus_used = float(animal.adult_bonus_used) + bonus
		if float(animal.product_remaining) <= 0:
			PRODUCTS.complete_cycle(state, animal, kind, products)
	if bonus > 0:
		animal.last_reward_elapsed = now
		state.ranch.global_reward_elapsed = now
	return {"ok": true, "message": "互动使进度加快 %.1f 秒" % bonus if bonus > 0 else "本阶段互动额度已用完", "reward_seconds": bonus}

static func validate(state: Dictionary, kinds: Dictionary, legacy := false) -> String:
	if not state.get("ranch") is Dictionary or not _number(state.ranch.get("global_reward_elapsed")) or float(state.ranch.global_reward_elapsed) < -2.0 or float(state.ranch.global_reward_elapsed) > float(state.elapsed): return "全局互动计时无效"
	if not _integer(state.rng.get("animal")) or int(state.rng.animal) <= 0 or int(state.rng.animal) >= 2147483647: return "动物随机流无效"
	var ledger := {}
	var hay := 0
	for grass in state.grass:
		if not _position_valid(grass) or not _integer(grass.get("appearance")) or int(grass.appearance) < 0 or int(grass.appearance) >= 997: return "自然草点位置或外观无效"
	for animal in state.animals:
		var kind: Dictionary = kinds[str(animal.type_id)]
		if not legacy and (not _integer(animal.get("last_drop_cycle")) or int(animal.last_drop_cycle) != int(animal.production_cycle) - 1 or int(animal.ready) != 0 or str(animal.get("held_by", "")).length() > 0 or float(animal.get("hold_remaining", 0)) != 0 or str(animal.get("behavior", "")) == "being_collected"): return "动物循环或旧收取冻结状态无效"
		if str(animal.get("shelter_id", "")) != str(kind.shelter_id) or not _position_valid(animal) or not BEHAVIORS.has(str(animal.get("behavior", ""))) or not ["up", "down", "left", "right"].has(str(animal.get("facing", ""))): return "动物位置或行为无效"
		if not animal.get("path") is Array or not animal.get("target") is Dictionary or not animal.get("meal") is Dictionary: return "动物路径或整餐预约无效"
		for key in ["previous_x", "previous_y", "decision_remaining", "food_decision_remaining", "eating_remaining", "hold_remaining", "feedback_remaining", "last_reward_elapsed", "juvenile_bonus_used", "adult_bonus_used", "production_cycle"]:
			if not _number(animal.get(key)): return "动物计时字段无效"
		if float(animal.last_reward_elapsed) < -120 or float(animal.last_reward_elapsed) > float(state.elapsed) or float(animal.juvenile_bonus_used) < 0 or float(animal.juvenile_bonus_used) > float(kind.adult_seconds) * 0.2 + 0.001 or float(animal.adult_bonus_used) < 0 or float(animal.adult_bonus_used) > float(kind.produce_seconds) * 0.1 + 0.001 or not _integer(animal.production_cycle) or int(animal.production_cycle) < 0: return "互动冷却或额度无效"
		for key in ["decision_remaining", "food_decision_remaining", "eating_remaining", "hold_remaining", "feedback_remaining"]:
			if float(animal[key]) < 0: return "动物行为计时为负"
		if not animal.get("held_by") is String: return "动物照料认领无效"
		if not WORLD.is_walkable("ranch", Vector2(float(animal.previous_x), float(animal.previous_y))): return "动物旧位置越界"
		var origin := point(animal)
		for waypoint in animal.path:
			if not waypoint is Dictionary or not _position_valid(waypoint) or not WORLD.segment_walkable("ranch", origin, point(waypoint)): return "动物路径越界或穿墙"
			origin = point(waypoint)
		if not animal.target.is_empty() and (not _position_valid(animal.target) or not ["wander", "grass", "hay"].has(str(animal.target.get("kind", "")))): return "动物目标无效"
		if animal.meal.is_empty(): continue
		if not ["grass", "hay"].has(str(animal.meal.get("source", ""))) or not animal.meal.get("grass") is Array or not _number(animal.meal.get("remaining")) or float(animal.meal.remaining) <= 0 or float(animal.meal.remaining) > 240.001: return "整餐预约结构无效"
		if str(animal.meal.source) == "hay":
			if not animal.meal.grass.is_empty(): return "干草预约混入青草"
			hay += 1
		else:
			var total := 0
			var seen := {}
			for claim in animal.meal.grass:
				if not claim is Dictionary or not _integer(claim.get("amount")) or int(claim.amount) < 1 or seen.has(str(claim.get("id", ""))): return "草量预约无效"
				var grass := _find(state.grass, str(claim.get("id", "")))
				if grass.is_empty() or not grass.open or grass.mother: return "草量预约目标无效"
				seen[str(grass.id)] = true
				ledger[str(grass.id)] = int(ledger.get(str(grass.id), 0)) + int(claim.amount)
				total += int(claim.amount)
			if total != int(kind.food_grass): return "整餐预约不足或超量"
		if animal.target.is_empty() or str(animal.target.kind) != str(animal.meal.source): return "整餐预约目标缺失"
		var final_position: Vector2 = WORLD.target_position("ranch", "trough", state) if str(animal.meal.source) == "hay" else point(_find(state.grass, str(animal.meal.grass[-1].id)))
		if point(animal.target).distance_to(final_position) > 0.01 or origin.distance_to(final_position) > 1.0: return "整餐路线没有到达食物"
	for farmer in state.farmers:
		if str(farmer.task.get("action", "")) == "cut_grass":
			var id := str(farmer.task.target)
			if int(farmer.task.get("grass_amount", 3)) != 3: return "割草预约量无效"
			ledger[id] = int(ledger.get(id, 0)) + 3
	for id in ledger:
		var grass := _find(state.grass, str(id))
		if grass.is_empty() or grass.mother or int(ledger[id]) > maxi(0, int(grass.clumps) - 1): return "青草重复预约"
	if hay > int(state.trough_hay): return "干草重复预约"
	return ""

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floorf(float(value))

static func _position_valid(value: Dictionary) -> bool:
	return _number(value.get("x")) and _number(value.get("y")) and WORLD.is_walkable("ranch", point(value))
