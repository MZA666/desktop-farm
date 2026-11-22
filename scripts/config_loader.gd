class_name FarmConfigLoader
extends RefCounted

## Keep the imported v0.5 workbook intact; explicit gameplay changes live in
## a separate versioned file and are shared by the app and regression tests.
static func load_values() -> Dictionary:
	var original: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/production.json"))
	var changes: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/gameplay-v0.8.json"))
	if not original is Dictionary or not changes is Dictionary:
		push_error("Farm gameplay configuration is invalid")
		return {}
	var values: Dictionary = original.duplicate(true)
	values["base_version"] = str(values.get("version", "0.5"))
	values["version"] = str(changes.version)
	for section in ["parameters", "upgrades"]:
		for key in changes.get(section, {}):
			values[section][key] = changes[section][key].duplicate(true) if changes[section][key] is Array or changes[section][key] is Dictionary else changes[section][key]
	var plot_prices := []
	for tier in values.upgrades.get("plot_price_tiers", []):
		for offset in range(int(tier.count)):
			plot_prices.append(int(tier.start) + offset * int(tier.step))
	values.upgrades.individual_plot_costs = plot_prices
	_apply_crop_prices(values, changes)
	return values

static func _apply_crop_prices(values: Dictionary, changes: Dictionary) -> void:
	var levels := {}
	var tiers: Array = changes.crop_price_tiers
	for index in range(tiers.size()):
		for id in tiers[index].crops:
			levels[id] = index + 1
	var active_crops := []
	var retired_crops := []
	var sale_prices: Dictionary = changes.retired_pool_prices.duplicate()
	for crop in values.crops:
		var level := int(levels.get(crop.id, 0))
		var tier: Dictionary = tiers[level - 1] if level > 0 else changes.retired_crop_profiles[crop.id]
		crop.price_level = level
		crop.retired = level == 0
		if crop.retired: retired_crops.append(crop)
		else: active_crops.append(crop)
		crop.seed_cost = int(tier.seed_cost)
		crop.seed_price = crop.seed_cost
		crop.unlock_cost = int(tier.unlock_cost)
		crop.unlock_price = crop.unlock_cost
		crop.initial_unlocked = not crop.retired and crop.unlock_cost == 0
		crop.grow_seconds = int(tier.grow_minutes) * 60
		crop.first_seconds = crop.grow_seconds
		crop.regrow_seconds = int(tier.repeat_minutes) * 60 if crop.regrow else 0
		crop.repeat_seconds = crop.regrow_seconds
		crop.replant_cost = 0 if crop.regrow or crop.return_seed else crop.seed_price
		if not crop.pool.is_empty(): continue
		crop.sale_price = int(tier.sale_price)
		crop.sell_price = crop.sale_price
		crop.expected_sale_price = crop.sale_price
		sale_prices[crop.product_id] = crop.sale_price
	for crop in values.crops:
		if crop.pool.is_empty(): continue
		var expected := 0.0
		for item in crop.pool:
			item.sale_price = sale_prices[item.product_id]
			item.sell_price = item.sale_price
			expected += int(item.sale_price) * float(item.weight)
		crop.expected_sale_price = expected
	for id in sale_prices:
		values.products[id].sale_price = sale_prices[id]
		values.products[id].sell_price = sale_prices[id]
	for item in values.items:
		if not sale_prices.has(item.id): continue
		item.sale_price = sale_prices[item.id]
		item.sell_price = item.sale_price
	values.crops = active_crops
	values.retired_crops = retired_crops
	values.retired_products = changes.retired_pool_prices.keys()
