class_name FarmPondRules
extends RefCounted

## Pure pond commands. The caller owns transaction IDs, snapshots and disk I/O.
## A rejected command leaves its input untouched; one catch settles in one call.
const NET_LEVELS := [
	{"cooldown": 20, "cost": 0}, {"cooldown": 15, "cost": 200},
	{"cooldown": 10, "cost": 400}, {"cooldown": 5, "cost": 800},
]
const CAPACITY_LEVELS := [
	{"capacity": 12, "cost": 0}, {"capacity": 18, "cost": 300},
	{"capacity": 24, "cost": 600}, {"capacity": 36, "cost": 1800},
]

static func cooldown(state: Dictionary, config: Dictionary = {}) -> float:
	var levels := _levels(config, "net_levels", NET_LEVELS)
	var level := clampi(int(state.get("pond", {}).get("net_level", 0)), 0, levels.size() - 1)
	return float(levels[level].cooldown)

static func capacity(state: Dictionary, config: Dictionary = {}) -> int:
	var levels := _levels(config, "pond_capacity_levels", CAPACITY_LEVELS)
	var level := clampi(int(state.get("pond", {}).get("capacity_level", 0)), 0, levels.size() - 1)
	return int(levels[level].capacity)

static func command(state: Dictionary, config: Dictionary, action: String, payload: Dictionary = {}, protection: int = 0) -> Dictionary:
	match action:
		"cast_net":
			if not state.get("pending_fish", {}).is_empty():
				return _result(false, "旧版捕获尚未结算，请先重试保存")
			if float(state.get("net_remaining", 0.0)) > 0:
				return _result(false, "渔网还需冷却 %d 秒" % ceili(float(state.net_remaining)))
			var fish_id := str(payload.get("fish_id", ""))
			var fish_index := -1
			var fish: Dictionary = {}
			for i in range(state.fish.size()):
				if str(state.fish[i].id) == fish_id:
					fish = state.fish[i]
					fish_index = i
					break
			if fish_index < 0:
				state.net_remaining = cooldown(state, config)
				return _result(true, "未命中，渔网进入冷却")
			var settlement := _settlement(state, config, fish)
			if not settlement.ok: return settlement
			state.fish.remove_at(fish_index)
			state.net_remaining = cooldown(state, config)
			_apply_settlement(state, settlement)
			return settlement
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
		"upgrade_pond":
			return _upgrade(state, config, "capacity_level", "pond_capacity_levels", CAPACITY_LEVELS, protection, "鱼塘")
	return _result(false, "未知鱼塘操作")

static func _settlement(state: Dictionary, config: Dictionary, fish: Dictionary) -> Dictionary:
	var type_id := str(fish.get("type_id", ""))
	var kind: Dictionary = {}
	var definitions: Variant = config.get("fish", [])
	if definitions is Dictionary:
		kind = definitions.get(type_id, {})
	else:
		for item in definitions:
			if str(item.id) == type_id:
				kind = item
				break
	if kind.is_empty(): return _result(false, "捕获鱼种配置无效")
	var product_id := str(kind.get("product_id", type_id))
	var known: bool = state.get("catalog", {}).has(product_id)
	var price := int(kind.get("sell_price", kind.get("sale_price", 0)))
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
