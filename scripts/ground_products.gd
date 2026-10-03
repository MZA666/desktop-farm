class_name FarmGroundProducts
extends RefCounted

## Stock stays in fixed piles until a unique farmer claim commits one unit.
## Production, claims, currency and catalog changes are pure snapshot state.
const WORLD = preload("res://scripts/world_layout.gd")

static func _uid(state: Dictionary, prefix: String) -> String:
	var id := "%s_%d" % [prefix, int(state.next_id)]
	state.next_id = int(state.next_id) + 1
	return id

static func find(state: Dictionary, id: String) -> Dictionary:
	if not state.get("ground_products") is Array: return {}
	for pile in state.get("ground_products", []):
		if pile is Dictionary and str(pile.get("id", "")) == id: return pile
	return {}

static func _batch(pile: Dictionary, id: String) -> Dictionary:
	if not pile.get("batches") is Array: return {}
	for batch in pile.get("batches", []):
		if batch is Dictionary and str(batch.get("id", "")) == id: return batch
	return {}

static func point(pile: Dictionary) -> Vector2:
	return Vector2(float(pile.x), float(pile.y))

static func complete_cycle(state: Dictionary, animal: Dictionary, kind: Dictionary, products: Dictionary = {}, queued_at := -1.0) -> Dictionary:
	if not bool(animal.adult) or (int(animal.ready) == 0 and float(animal.product_remaining) > 0.000001): return {}
	var cycle := int(animal.production_cycle)
	if int(animal.get("last_drop_cycle", -1)) >= cycle: return {}
	var position: Vector2 = WORLD.product_drop_position(Vector2(float(animal.x), float(animal.y)))
	if not WORLD.is_walkable("ranch", position): return {}
	var product_id := str(kind.product_id)
	var pile: Dictionary = {}
	for existing in state.ground_products:
		if str(existing.product_id) == product_id and point(existing).distance_squared_to(position) < 0.01:
			pile = existing
			break
	var timestamp := float(state.elapsed) if queued_at < 0 else queued_at
	if pile.is_empty():
		pile = {"id": _uid(state, "pile"), "product_id": product_id,
			"name": str(products.get(product_id, {}).get("name", kind.get("product_name", kind.name))),
			"x": position.x, "y": position.y, "quantity": 0, "queued_at": timestamp, "batches": [], "claims": []}
		state.ground_products.append(pile)
	var batch: Dictionary = {}
	for existing in pile.batches:
		if str(existing.source_animal) == str(animal.id) and str(existing.source_type) == str(kind.id) and int(existing.sell_price) == int(kind.sell_price):
			batch = existing
			break
	if batch.is_empty():
		batch = {"id": _uid(state, "batch"), "source_type": str(kind.id), "source_animal": str(animal.id),
			"sell_price": int(kind.sell_price), "quantity": 0, "queued_at": timestamp, "first_cycle": cycle, "last_cycle": cycle}
		pile.batches.append(batch)
	batch.quantity = int(batch.quantity) + 1
	batch.last_cycle = cycle
	pile.quantity = int(pile.quantity) + 1
	animal.last_drop_cycle = cycle
	animal.production_cycle = cycle + 1
	animal.ready = 0
	animal.product_remaining = float(kind.produce_seconds)
	animal.adult_bonus_used = 0.0
	animal.held_by = ""
	animal.hold_remaining = 0.0
	return pile

static func available(pile: Dictionary, batch_id := "") -> int:
	var total := int(pile.quantity) if batch_id.is_empty() else int(_batch(pile, batch_id).get("quantity", 0))
	for claim in pile.claims:
		if batch_id.is_empty() or str(claim.batch_id) == batch_id: total -= 1
	return maxi(0, total)

static func reserve(state: Dictionary, task: Dictionary, farmer_id: String) -> bool:
	var pile := find(state, str(task.get("target", "")))
	if pile.is_empty() or farmer_id.is_empty(): return false
	var requested_batch := str(task.get("batch_id", ""))
	for existing in state.ground_products:
		for claim in existing.claims:
			if str(claim.farmer_id) == farmer_id: return false
	for batch in pile.batches:
		if not requested_batch.is_empty() and str(batch.id) != requested_batch: continue
		if available(pile, str(batch.id)) <= 0: continue
		var id := _uid(state, "claim")
		pile.claims.append({"id": id, "farmer_id": farmer_id, "batch_id": str(batch.id)})
		task.claim_id = id
		task.batch_id = str(batch.id)
		task.claim_farmer_id = farmer_id
		return true
	return false

static func task_valid(state: Dictionary, task: Dictionary) -> bool:
	var pile := find(state, str(task.get("target", "")))
	if pile.is_empty() or not pile.get("batches") is Array or not pile.get("claims") is Array: return false
	var batch := _batch(pile, str(task.get("batch_id", "")))
	if batch.is_empty() or not _positive(batch.get("quantity")): return false
	for claim in pile.claims:
		if not claim is Dictionary: continue
		if str(claim.id) == str(task.get("claim_id", "")) and str(claim.batch_id) == str(batch.id) and str(claim.farmer_id) == str(task.get("claim_farmer_id", "")): return true
	return false

static func release(state: Dictionary, task: Dictionary) -> void:
	var pile := find(state, str(task.get("target", "")))
	if pile.is_empty(): return
	for index in range(pile.claims.size() - 1, -1, -1):
		var claim: Dictionary = pile.claims[index]
		if str(claim.id) == str(task.get("claim_id", "")) and str(claim.farmer_id) == str(task.get("claim_farmer_id", "")): pile.claims.remove_at(index)

static func collect(state: Dictionary, task: Dictionary) -> bool:
	if not task_valid(state, task): return false
	var pile := find(state, str(task.target))
	var batch := _batch(pile, str(task.batch_id))
	# Clear the unique token before currency is granted; replay cannot pay twice.
	release(state, task)
	batch.quantity = int(batch.quantity) - 1
	pile.quantity = int(pile.quantity) - 1
	state.coins = int(state.coins) + int(batch.sell_price)
	var id := str(pile.product_id)
	if not state.catalog.has(id):
		state.catalog[id] = {"id": id, "name": str(pile.name), "count": 0,
			"first_obtained": float(state.elapsed), "sources": [], "sell_price": int(batch.sell_price)}
	var entry: Dictionary = state.catalog[id]
	entry.count = int(entry.count) + 1
	if not entry.sources.has(str(batch.source_type)): entry.sources.append(str(batch.source_type))
	if int(batch.quantity) == 0: pile.batches.erase(batch)
	if int(pile.quantity) == 0: state.ground_products.erase(pile)
	elif not pile.batches.is_empty():
		pile.queued_at = float(pile.batches[0].queued_at)
	return true

## Reconcile stale/duplicate claim records and tasks without touching stock.
## Structural corruption is still rejected by validate(), never silently fixed.
static func reconcile(state: Dictionary) -> void:
	if not state.get("ground_products") is Array or not state.get("farmers") is Array: return
	var used := {}
	for pile in state.ground_products:
		if not pile is Dictionary or not pile.get("claims") is Array or not pile.get("batches") is Array: continue
		var counts := {}
		var kept: Array = []
		for claim in pile.claims:
			if not claim is Dictionary: kept.append(claim); continue
			var id := str(claim.get("id", ""))
			var owner := str(claim.get("farmer_id", ""))
			var batch := _batch(pile, str(claim.get("batch_id", "")))
			if id.is_empty() or batch.is_empty() or not _positive(batch.get("quantity")) or used.has(id) or used.has("owner:" + owner): continue
			var found := false
			for farmer in state.farmers:
				if not farmer is Dictionary or not farmer.get("task") is Dictionary: continue
				var task: Dictionary = farmer.task
				if str(farmer.get("id", "")) == owner and str(farmer.get("mode", "")) == "working" and str(task.get("action", "")) == "collect_product" and str(task.get("target", "")) == str(pile.get("id", "")) and str(task.get("claim_id", "")) == id and str(task.get("batch_id", "")) == str(batch.get("id", "")) and str(task.get("claim_farmer_id", "")) == owner:
					found = true; break
			if not found or int(counts.get(str(batch.id), 0)) >= int(batch.quantity): continue
			counts[str(batch.id)] = int(counts.get(str(batch.id), 0)) + 1
			used[id] = true
			used["owner:" + owner] = true
			kept.append(claim)
		pile.claims = kept

static func validate(state: Dictionary, kinds: Dictionary) -> String:
	if not state.get("ground_products") is Array: return "地面产物列表缺失"
	var ids := {}
	for group in ["animals", "farmers", "fish"]:
		for item in state[group]: ids[str(item.id)] = true
	if not state.pending_fish.is_empty(): ids[str(state.pending_fish.id)] = true
	var owners := {}
	var drop_keys := {}
	for pile in state.ground_products:
		if not pile is Dictionary or not _id(pile.get("id"), state, ids) or not pile.get("product_id") is String or not pile.get("name") is String or not _positive(pile.get("quantity")) or not _number(pile.get("queued_at")) or float(pile.queued_at) < 0 or float(pile.queued_at) > float(state.elapsed) or not _number(pile.get("x")) or not _number(pile.get("y")) or not WORLD.is_walkable("ranch", point(pile)): return "地面产物位置或数量无效"
		if not pile.get("batches") is Array or pile.batches.is_empty() or not pile.get("claims") is Array: return "产物批次或认领结构无效"
		var slot := "%s:%.3f:%.3f" % [pile.product_id, pile.x, pile.y]
		if drop_keys.has(slot): return "产物堆位置重复"
		drop_keys[slot] = true
		var total := 0
		var batches := {}
		for batch in pile.batches:
			if not batch is Dictionary or not _id(batch.get("id"), state, ids) or not kinds.has(str(batch.get("source_type", ""))) or not batch.get("source_animal") is String or str(batch.source_animal).is_empty() or not _positive(batch.get("quantity")) or not _integer(batch.get("sell_price")) or int(batch.sell_price) < 0 or not _integer(batch.get("first_cycle")) or int(batch.first_cycle) < 0 or not _integer(batch.get("last_cycle")) or int(batch.last_cycle) < int(batch.first_cycle) or not _number(batch.get("queued_at")) or float(batch.queued_at) < 0 or float(batch.queued_at) > float(state.elapsed): return "产物来源、批次或售价无效"
			if str(kinds[str(batch.source_type)].product_id) != str(pile.product_id): return "产物与来源品种不匹配"
			total += int(batch.quantity)
			batches[str(batch.id)] = batch
		if total != int(pile.quantity): return "产物数量不守恒"
		var reserved := {}
		for claim in pile.claims:
			if not claim is Dictionary or not _id(claim.get("id"), state, ids) or not batches.has(str(claim.get("batch_id", ""))) or not claim.get("farmer_id") is String or str(claim.farmer_id).is_empty() or owners.has(str(claim.farmer_id)): return "产物份额认领无效"
			owners[str(claim.farmer_id)] = true
			reserved[str(claim.batch_id)] = int(reserved.get(str(claim.batch_id), 0)) + 1
			if int(reserved[str(claim.batch_id)]) > int(batches[str(claim.batch_id)].quantity): return "产物份额重复认领"
	return ""

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floorf(float(value))

static func _positive(value: Variant) -> bool:
	return _integer(value) and int(value) > 0

static func _id(value: Variant, state: Dictionary, ids: Dictionary) -> bool:
	if not value is String or value.is_empty() or ids.has(value): return false
	var number := int(value.get_slice("_", 1))
	if number < 1 or number >= int(state.next_id): return false
	ids[value] = true
	return true
