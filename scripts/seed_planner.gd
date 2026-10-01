class_name FarmSeedPlanner
extends RefCounted

## One allocator is used by real sow claims and by the budget projection.
## `seeds` contains only unreserved stock; reservations already own their seeds.
static func choose(plot: Dictionary, seeds: Dictionary, reservations: Array, crops: Dictionary, order: Array, default_id: String, purpose := "pending_first") -> Dictionary:
	var preferred := str(plot.get("pending_crop_id", ""))
	if preferred.is_empty(): preferred = str(plot.get("preferred_crop_id", plot.get("crop_id", default_id)))
	var actual := str(plot.get("crop_id", ""))
	var explicit_next := str(plot.get("pending_crop_id", ""))
	if bool(plot.get("return_seed", false)) and (explicit_next.is_empty() or actual == explicit_next):
		plot.return_seed = false
		return {"crop_id": actual, "source": "dedicated", "cost": 0}
	for i in range(reservations.size()):
		var claim: Dictionary = reservations[i]
		var matches_purpose := str(claim.get("purpose", "")) == purpose
		if purpose == "pending_first" and str(plot.get("pending_crop_id", "")).is_empty() and str(claim.get("purpose", "")) == "pending_next": matches_purpose = true
		if str(claim.get("plot_id", "")) == str(plot.id) and matches_purpose and int(claim.get("quantity", 0)) > 0:
			var id := str(claim.crop_id)
			claim.quantity = int(claim.quantity) - 1
			if int(claim.quantity) == 0: reservations.remove_at(i)
			return {"crop_id": id, "source": "reservation", "cost": 0}
	if int(seeds.get(preferred, 0)) > 0:
		seeds[preferred] = int(seeds[preferred]) - 1
		return {"crop_id": preferred, "source": "inventory", "cost": 0}
	for id in order:
		if int(seeds.get(id, 0)) > 0:
			seeds[id] = int(seeds[id]) - 1
			return {"crop_id": str(id), "source": "inventory", "cost": 0}
	return {"crop_id": default_id, "source": "automatic", "cost": int(crops[default_id].seed_price)}

static func protection(state: Dictionary, crops: Dictionary, order: Array) -> int:
	var seeds: Dictionary = state.seeds.duplicate(true)
	var reservations: Array = state.get("seed_reservations", []).duplicate(true)
	var default_id := str(state.get("default_seed_id", "parsnip"))
	var active := {}
	for farmer in state.farmers:
		var task: Dictionary = farmer.get("task", {})
		if str(task.get("action", "")) == "sow": active[str(task.target)] = task
	var subsequent: Array = []
	var total := 0
	# First sowings and explicit switches have priority over the following batch.
	for source in state.plots:
		if not bool(source.open): continue
		var plot: Dictionary = source.duplicate(true)
		var pending := str(plot.get("pending_crop_id", ""))
		var switching := not pending.is_empty() and pending != str(plot.crop_id)
		var current := str(active.get(str(plot.id), {}).get("crop_id", plot.crop_id))
		if switching or (str(plot.status) == "empty" and not active.has(str(plot.id))):
			if switching: plot.return_seed = false
			var chosen := choose(plot, seeds, reservations, crops, order, default_id)
			total += int(chosen.cost)
			current = str(chosen.crop_id)
			# After this first batch the pending preference has taken effect.
			if not pending.is_empty(): plot.preferred_crop_id = pending
			plot.pending_crop_id = ""
		else:
			plot.pending_crop_id = ""
		if not bool(crops[current].get("regrow", false)):
			plot.crop_id = current
			plot.return_seed = bool(crops[current].get("return_seed", false))
			subsequent.append(plot)
	for plot in subsequent:
		var chosen := choose(plot, seeds, reservations, crops, order, default_id, "pending_next")
		total += int(chosen.cost)
	return total
