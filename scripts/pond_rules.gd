class_name FarmPondRules
extends RefCounted

## Pure pond commands. The caller owns transaction IDs, snapshots and disk I/O.
## A rejected command leaves its input untouched; an entire cast settles once.
const WORLD = preload("res://scripts/world_layout.gd")
const NET_LEVELS := [
	{"cooldown": 20, "cost": 0}, {"cooldown": 15, "cost": 200},
	{"cooldown": 10, "cost": 400}, {"cooldown": 5, "cost": 800},
]
const CAPACITY_LEVELS := [
	{"capacity": 12, "cost": 0}, {"capacity": 18, "cost": 300},
	{"capacity": 24, "cost": 600}, {"capacity": 36, "cost": 1800},
]
const NET_AREA_LEVELS := [
	{"radius": 20, "cost": 0}, {"radius": 29, "cost": 300},
	{"radius": 35, "cost": 700}, {"radius": 40, "cost": 1500},
]

static func cooldown(state: Dictionary, config: Dictionary = {}) -> float:
	var levels := _levels(config, "net_levels", NET_LEVELS)
	var level := clampi(int(state.get("pond", {}).get("net_level", 0)), 0, levels.size() - 1)
	return float(levels[level].cooldown)

static func capacity(state: Dictionary, config: Dictionary = {}) -> int:
	var levels := _levels(config, "pond_capacity_levels", CAPACITY_LEVELS)
	var level := clampi(int(state.get("pond", {}).get("capacity_level", 0)), 0, levels.size() - 1)
	return int(levels[level].capacity)

static func net_radius(state: Dictionary, config: Dictionary = {}) -> float:
	var levels := _levels(config, "net_area_levels", NET_AREA_LEVELS)
	var level := clampi(int(state.get("pond", {}).get("net_area_level", 0)), 0, levels.size() - 1)
	return float(levels[level].radius)

static func net_area(state: Dictionary, config: Dictionary = {}) -> float:
	return PI * pow(net_radius(state, config), 2)

static func net_catch_limit(state: Dictionary, config: Dictionary = {}) -> int:
	var base := float(_levels(config, "net_area_levels", NET_AREA_LEVELS)[0].radius)
	return clampi(floori(pow(net_radius(state, config) / base, 2) + 0.000001), 1, 4)

static func command(state: Dictionary, config: Dictionary, action: String, payload: Dictionary = {}, protection: int = 0) -> Dictionary:
	match action:
		"cast_net":
			if not state.get("pending_fish", {}).is_empty():
				return _result(false, "旧版捕获尚未结算，请先重试保存")
			if float(state.get("net_remaining", 0.0)) > 0:
				return _result(false, "渔网还需冷却 %d 秒" % ceili(float(state.net_remaining)))
			return _cast(state, config, payload)
		"resolve_pending_fish":
			var fish: Dictionary = state.get("pending_fish", {})
			if fish.is_empty(): return _result(false, "没有待结算的旧版鱼")
			var settlement := _settlement(state, config, fish)
			if not settlement.ok: return settlement
			_apply_settlement(state, settlement)
			state.pending_fish = {}
			# The fish already left the pond when it was caught. Keep both timers.
			return settlement
		"upgrade_net":
			return _upgrade(state, config, "net_level", "net_levels", NET_LEVELS, protection, "渔网")
		"upgrade_net_area":
			return _upgrade(state, config, "net_area_level", "net_area_levels", NET_AREA_LEVELS, protection, "渔网面积")
		"upgrade_pond":
			return _upgrade(state, config, "capacity_level", "pond_capacity_levels", CAPACITY_LEVELS, protection, "鱼塘")
	return _result(false, "未知鱼塘操作")

static func _cast(state: Dictionary, config: Dictionary, payload: Dictionary) -> Dictionary:
	var radius := net_radius(state, config)
	var limit := net_catch_limit(state, config)
	var candidates: Array[Dictionary] = []
	var center := Vector2.ZERO
	if payload.has("center_x") or payload.has("center_y"):
		if not _finite_number(payload.get("center_x")) or not _finite_number(payload.get("center_y")):
			return _result(false, "渔网位置无效")
		center = Vector2(float(payload.center_x), float(payload.center_y))
	else:
		# Old saved replay/test commands may address one fish. Real positioned fish
		# always pass through the same authoritative area selection as a water tap.
		var fish_id := str(payload.get("fish_id", ""))
		var target: Dictionary = {}
		for fish in state.fish:
			if str(fish.id) == fish_id:
				target = fish
				break
		if target.is_empty(): return _miss(state, config, radius, limit)
		if not target.has("x") and not target.has("y"):
			candidates.append({"fish": target, "distance_squared": 0.0})
			return _settle_cast(state, config, candidates, radius, limit)
		if not _finite_number(target.get("x")) or not _finite_number(target.get("y")):
			return _result(false, "鱼的位置无效")
		center = Vector2(float(target.x), float(target.y))
	if not WORLD.water_contains(center): return _result(false, "请在水面投网")
	for fish in state.fish:
		# Coordinate-less compatibility fixtures are never caught by area casts.
		if not fish.has("x") and not fish.has("y"): continue
		if not _finite_number(fish.get("x")) or not _finite_number(fish.get("y")):
			return _result(false, "鱼的位置无效")
		var distance_squared := center.distance_squared_to(Vector2(float(fish.x), float(fish.y)))
		if distance_squared <= radius * radius + 0.000001:
			candidates.append({"fish": fish, "distance_squared": distance_squared})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.distance_squared == b.distance_squared: return str(a.fish.id) < str(b.fish.id)
		return a.distance_squared < b.distance_squared)
	if candidates.is_empty(): return _miss(state, config, radius, limit)
	if candidates.size() > limit: candidates.resize(limit)
	return _settle_cast(state, config, candidates, radius, limit)

static func _settle_cast(state: Dictionary, config: Dictionary, candidates: Array[Dictionary], radius: float, limit: int) -> Dictionary:
	# Work on a private catalog until every selected fish definition validates.
	# A malformed second fish must not remove/pay/register the first fish.
	var staged := {"coins": int(state.coins), "catalog": state.get("catalog", {}).duplicate(true), "elapsed": float(state.get("elapsed", 0.0))}
	var caught_ids: Array[String] = []
	var sold_count := 0
	var discovered_count := 0
	var sale_value := 0
	var first_settlement: Dictionary = {}
	for candidate in candidates:
		var settlement := _settlement(staged, config, candidate.fish)
		if not settlement.ok: return settlement
		if first_settlement.is_empty(): first_settlement = settlement
		_apply_settlement(staged, settlement)
		caught_ids.append(str(candidate.fish.id))
		if settlement.settlement == "sell": sold_count += 1
		else: discovered_count += 1
		sale_value += int(settlement.sale_value)
	var remaining: Array = []
	for fish in state.fish:
		if not caught_ids.has(str(fish.id)): remaining.append(fish)
	state.fish = remaining
	state.coins = staged.coins
	if discovered_count > 0: state.catalog = staged.catalog
	state.net_remaining = cooldown(state, config)
	var result := first_settlement.duplicate(true)
	result.merge({"count": caught_ids.size(), "caught_ids": caught_ids, "sold_count": sold_count,
		"discovered_count": discovered_count, "sale_value": sale_value, "radius": radius, "limit": limit}, true)
	if caught_ids.size() > 1:
		result.message = "捕获 %d 条鱼，出售 %d 条 +%d 金币" % [caught_ids.size(), sold_count, sale_value]
		if discovered_count > 0: result.message += "，新收录 %d 种" % discovered_count
	return result

static func _miss(state: Dictionary, config: Dictionary, radius: float, limit: int) -> Dictionary:
	state.net_remaining = cooldown(state, config)
	return {"ok": true, "message": "未命中，渔网进入冷却", "count": 0, "caught_ids": [],
		"sold_count": 0, "discovered_count": 0, "sale_value": 0, "radius": radius, "limit": limit}

static func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func _settlement(state: Dictionary, config: Dictionary, fish: Dictionary) -> Dictionary:
	var type_id := str(fish.get("type_id", ""))
	var kind: Dictionary = {}
	var definitions: Variant = config.get("fish", [])
	if definitions is Dictionary:
		var definition: Variant = definitions.get(type_id, {})
		if definition is Dictionary: kind = definition
	elif definitions is Array:
		for item in definitions:
			if item is Dictionary and str(item.get("id", "")) == type_id:
				kind = item
				break
	if kind.is_empty(): return _result(false, "捕获鱼种配置无效")
	var configured_product: Variant = kind.get("product_id", type_id)
	if not configured_product is String: return _result(false, "捕获鱼种配置无效")
	var product_id := str(configured_product)
	var configured_price: Variant = kind.get("sell_price", kind.get("sale_price", null))
	if product_id.is_empty() or not _finite_number(configured_price) or float(configured_price) < 0 or float(configured_price) != floor(float(configured_price)):
		return _result(false, "捕获鱼种配置无效")
	var known: bool = state.get("catalog", {}).has(product_id)
	var price := int(configured_price)
	var fish_name := str(kind.get("name", type_id))
	return {"ok": true, "fish_id": str(fish.id), "product_id": product_id,
		"settlement": "sell" if known else "catalog", "sale_value": price if known else 0,
		"product_name": fish_name, "product_price": price,
		"message": "%s 已出售 +%d 金币" % [fish_name, price] if known else "%s 首次捕获，已消耗这条鱼登记图鉴" % fish_name}

static func _apply_settlement(state: Dictionary, settlement: Dictionary) -> void:
	if str(settlement.settlement) == "sell":
		state.coins = int(state.coins) + int(settlement.sale_value)
		return
	state.catalog[str(settlement.product_id)] = {
		"id": str(settlement.product_id), "name": str(settlement.product_name), "count": 1,
		"first_obtained": float(state.get("elapsed", 0.0)), "sources": ["fish"],
		"sell_price": int(settlement.product_price),
	}

static func _upgrade(state: Dictionary, config: Dictionary, field: String, key: String, fallback: Array, protection: int, label: String) -> Dictionary:
	var pond: Dictionary = state.get("pond", {})
	var current := int(pond.get(field, 0))
	var levels := _levels(config, key, fallback)
	if current < 0 or current >= levels.size() - 1: return _result(false, "%s已达最高等级" % label)
	var cost := int(levels[current + 1].cost)
	if int(state.coins) - cost < maxi(0, protection):
		return _result(false, "金币不足：升级%s需 %d 金币，并保留 %d 金币补种预算" % [label, cost, maxi(0, protection)])
	var upgraded := pond.duplicate(true)
	upgraded[field] = current + 1
	state.pond = upgraded
	state.coins = int(state.coins) - cost
	# An upgrade applies to later casts/capacity without restarting any timer.
	return {"ok": true, "message": "%s升级完成" % label, "cost": cost, "level": current + 1}

static func _levels(config: Dictionary, key: String, fallback: Array) -> Array:
	var configured: Variant = config.get("upgrades", {}).get(key, [])
	return configured if configured is Array and configured.size() == fallback.size() else fallback

static func _result(ok: bool, message: String) -> Dictionary:
	return {"ok": ok, "message": message}
