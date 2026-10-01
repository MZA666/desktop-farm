extends SceneTree

const Simulation = preload("res://scripts/game_state.gd")
const Persistence = preload("res://scripts/save_store.gd")
var values: Dictionary
var failures: Array[String] = []
var assertions := 0
var full_scale_report: Dictionary = {}

func _init() -> void:
	values = JSON.parse_string(FileAccess.get_file_as_string("res://data/production.json"))
	_test_initial_and_cycles()
	_test_water_and_task_restore()
	_test_special_crops()
	_test_all_crop_routes()
	_test_protection_and_switches()
	_test_ranch()
	_test_grass()
	_test_farmers()
	_test_fish_and_rng()
	_test_persistence()
	_test_full_scale()
	if failures.is_empty():
		print("PASS: %d simulation/persistence assertions" % assertions)
		print("FULL_SCALE: " + JSON.stringify(full_scale_report))
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		quit(1)

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures.append(message)

func fresh() -> FarmState:
	return Simulation.new(values)

func single_crop(id: String) -> FarmState:
	var game := fresh()
	game.state.coins = 1000000
	game.state.animals = []
	game.state.farmers = game.state.farmers.filter(func(f): return str(f.home) == "farm")
	game.state.seeds = {}
	for plot in game.state.plots:
		plot.open = str(plot.id) == "plot_0_0"
		plot.crop_id = id
	game.state.regions[0].current_crop_id = id
	if not game.state.unlocked_crops.has(id):
		game.state.unlocked_crops.append(id)
	return game

func plot0(game: FarmState) -> Dictionary:
	return game.state.plots[0]

func _test_initial_and_cycles() -> void:
	var game := fresh()
	check(game.balance() == 1000, "Initial cash is 1000")
	check(game.protection() == 480 and game.investable() == 520, "Initial reserve excludes first-batch gift seeds")
	check(game.state.seeds.parsnip == 24, "Initial seeds 24")
	check(game.state.plots.filter(func(p): return p.open).size() == 24, "Initial crop plots 24")
	check(game.state.grass.filter(func(g): return g.open and int(g.clumps) == 4).size() == 6, "Initial grass 6 full plots")
	check(game.state.animals.size() == 4 and game.state.trough_hay == 8, "Initial four chicks and eight trough hay")
	check(game.state.farmers.size() == 3 and game.state.paid_hires == 0, "Gift workers do not advance hire cost")
	check(game.state.fish.size() == 12, "Initial fish 12")
	check(game.command("settings", {"values": {"window_position": [-120, 840]}}).ok, "Window position accepts monitor coordinates including negative x")
	check(game.state.settings.window_position == [-120, 840], "Window position persists as controller-compatible array")
	check(not game.command("settings", {"values": {"window_position": [100]}}).ok, "Malformed window position rejected")
	game.tick(200)
	check(int(game.state.seeds.parsnip) == 0, "Exactly 24 gift seeds are sown")
	check(game.balance() == 1000, "Initial crop planting has no charge")
	check(game.state.plots.filter(func(p): return p.open and p.status != "empty").size() == 24, "All initial plots planted")
	game.tick(2300)
	check(game.balance() >= 0 and game.state.catalog.get("parsnip", {}).get("count", 0) >= 72, "At least three crop cycles and no debt")
	check(game.state.catalog.has("egg"), "Animal produce automatically sells and registers")

func _test_water_and_task_restore() -> void:
	var game := single_crop("parsnip")
	game.tick(4)
	check(plot0(game).status == "unwatered", "Sowing waits for water")
	var f: Dictionary = game.state.farmers[0]
	check(f.task.action == "water", "Automatic water task exists")
	var energy := float(f.energy)
	check(game.command("water", {"plot_id": "plot_0_0"}).ok, "Manual water succeeds")
	check(f.task.is_empty() and float(f.energy) == energy, "Manual water cancels queued action without energy charge")
	game.state.farmers = []
	var remaining := float(plot0(game).remaining)
	game.tick(remaining - 1)
	check(plot0(game).status == "growing" and float(plot0(game).remaining) == 1, "Crop exact growth boundary")
	game.tick(1)
	check(plot0(game).status == "ready", "Crop matures exactly at deadline")
	game.tick(5000)
	check(plot0(game).status == "ready" and game.state.catalog.is_empty(), "Mature crop neither rots nor auto-stacks")
	var paused := single_crop("parsnip")
	paused.tick(2)
	var snapshot := paused.snapshot()
	var restored := fresh()
	check(restored.restore(snapshot).ok, "Active sow task restores")
	var before_cash := restored.balance()
	check(restored.state.farmers[0].remaining == paused.state.farmers[0].remaining, "Task remaining time retained")
	paused.tick(10)
	restored.tick(10)
	check(JSON.stringify(paused.snapshot()) == JSON.stringify(restored.snapshot()), "Save/reload resumes task deterministically without buying seed twice")
	check(restored.balance() == before_cash, "Restored already reserved seed not charged twice")
	var dry := single_crop("parsnip")
	dry.tick(4)
	dry.state.farmers = []
	remaining = float(plot0(dry).remaining)
	dry.tick(999)
	check(float(plot0(dry).remaining) == remaining, "Unwatered growth freezes")

func _test_special_crops() -> void:
	var berry := single_crop("strawberry")
	berry.tick(7)
	plot0(berry).remaining = 1.0
	berry.tick(4)
	check(berry.state.catalog.strawberry.count == 1, "Strawberry first harvest")
	check(plot0(berry).status == "unwatered" and plot0(berry).remaining == 2400, "Regrowth uses one-third first interval and needs water")
	check(berry.protection() == 0, "Established regrowth has no seed reserve")
	var flower := single_crop("sunflower")
	flower.tick(7)
	var after_seed := flower.balance()
	plot0(flower).remaining = 1.0
	flower.tick(4)
	check(flower.balance() == after_seed + 80, "Sunflower sells exactly one flower")
	check(flower.state.farmers[0].task.get("seed_source", "") == "dedicated", "Sunflower dedicated seed reserved for same plot")
	flower.tick(6)
	check(flower.balance() == after_seed + 80 and plot0(flower).remaining == 2520, "Sunflower replants freely at full first interval")
	var rice := single_crop("unmilled_rice")
	rice.tick(7)
	var original := rice.balance()
	plot0(rice).remaining = 1.0
	rice.tick(4)
	check(plot0(rice).status == "processing" and plot0(rice).remaining == 180, "Rice harvest enters three-minute serial processing")
	check(rice.balance() == original, "Raw rice is not also sold")
	rice.state.farmers = []
	rice.tick(179)
	check(rice.balance() == original and plot0(rice).remaining == 1, "Rice cannot sell before processing finishes")
	rice.tick(1)
	check(rice.balance() == original + 100 and rice.state.catalog.rice.count == 1, "Processing sells one rice for 100")

func _test_all_crop_routes() -> void:
	check(values.crops.size() == 53, "All 53 crop definitions available")
	for crop in values.crops:
		var game := single_crop(str(crop.id))
		game.tick(7)
		check(plot0(game).status == "growing" and float(plot0(game).remaining) == float(crop.first_seconds), "%s configured first growth used" % crop.id)
		var selected_product: Dictionary = plot0(game).product.duplicate(true)
		var cash := game.balance()
		plot0(game).remaining = 1.0
		game.tick(4)
		if float(crop.processing_seconds) > 0:
			game.state.farmers = []
			game.tick(float(crop.processing_seconds))
		else:
			# Release any next-cycle seed already reserved by immediate dispatch.
			for farmer in game.state.farmers:
				game._cancel_task(farmer)
		var seed_spend := int(crop.seed_price) if (not crop.regrow and not crop.return_seed and float(crop.processing_seconds) == 0) else 0
		check(game.balance() == cash + int(selected_product.sell_price) - seed_spend, "%s sells actual integer product price once" % crop.id)
		check(game.state.catalog.has(str(selected_product.id)), "%s registers actual product" % crop.id)

func _test_protection_and_switches() -> void:
	var game := fresh()
	check(game.command("expand_plot", {"region": 0}).ok, "Affordable expansion succeeds")
	check(game.balance() == 650 and game.protection() == 520, "Expansion reserves initial and following seed for new plot")
	var before := game.snapshot()
	check(not game.command("expand_plot", {"region": 0}).ok, "Unaffordable expansion rejected")
	check(JSON.stringify(before) == JSON.stringify(game.snapshot()), "Rejected investment has no side effects")
	var switch := fresh()
	switch.state.coins = 1000000
	switch.tick(200)
	var old_reserve := switch.protection()
	check(switch.command("set_crop", {"region": 0, "crop_id": "cauliflower"}).ok, "Growing region accepts pending switch")
	check(switch.state.regions[0].pending_crop_id == "cauliflower", "Pending region retained")
	check(switch.protection() > old_reserve, "Pending first and next batches continuously protected")
	check(switch.command("cancel_crop", {"region": 0}).ok and switch.protection() == old_reserve, "Cancel releases pending-only budget")
	switch.command("set_crop", {"region": 0, "crop_id": "cauliflower"})
	plot0(switch).remaining = 1
	switch.tick(10)
	check(plot0(switch).crop_id == "cauliflower" and switch.state.plots[1].crop_id == "parsnip", "Switch applies per plot after its harvest")
	var restored := fresh()
	check(restored.restore(switch.snapshot()).ok, "Mixed crop region survives reload")
	check(restored.state.plots[0].crop_id == "cauliflower" and restored.state.plots[1].crop_id == "parsnip", "Reload keeps per-plot actual crop IDs")
	check(restored.command("cancel_crop", {"region": 0}).ok and restored.state.plots[0].crop_id == "cauliflower", "Cancel does not undo plots already switched")
	var zero := single_crop("parsnip")
	zero.state.coins = 0
	zero.tick(100)
	check(plot0(zero).status == "empty" and zero.balance() == 0, "No cash means sow waits without debt")

func _test_ranch() -> void:
	var game := fresh()
	game.state.farmers = []
	game.state.coins = 0
	game.state.trough_hay = 0
	for grass in game.state.grass:
		if not grass.mother:
			grass.clumps = 1
	var chick: Dictionary = game.state.animals[0]
	game.tick(30)
	check(chick.adult_remaining == 900 and chick.hungry, "Hungry juvenile progress freezes")
	game.state.trough_hay = 1
	game.tick(1)
	check(chick.adult_remaining == 899 and game.state.trough_hay == 0, "A full meal resumes remaining juvenile progress")
	for grass in game.state.grass:
		if grass.open and not grass.mother:
			grass.clumps = 1
	game.state.grass[2].clumps = 2
	var hungry: Dictionary = game.state.animals[1]
	hungry.food_remaining = 0
	game.tick(1)
	check(game.state.grass[2].clumps == 2 and hungry.hungry, "Insufficient grass is not deducted as half a meal")
	check(game.state.grass[0].clumps == 4 and game.state.grass[1].clumps == 4, "Mother grass never consumed")
	game.state.coins = 100000
	var first_id := str(game.state.animals[0].id)
	game.state.animals[0].adult = true
	game.state.animals[0].ready = 1
	var cash := game.balance()
	check(game.command("sell_animal", {"instance_id": first_id}).ok, "Gift animal can be sold")
	check(game.balance() == cash + 450 and game.state.animals.size() == 3, "Gift chicken sale refunds 400 and existing egg sells once")
	check(not game.command("sell_animal", {"instance_id": first_id}).ok, "Cannot sell same animal twice")
	check(game.command("upgrade_shelter", {"shelter_id": "chicken_coop"}).ok, "Coop upgrades to level two")
	check(game.command("buy_animal", {"animal_id": "void_chicken"}).ok, "Special chicken shares normal coop slots")
	check(game.state.animals.size() == 4 and game.shelter_capacity("chicken_coop") == 8, "Special animal does not add capacity")
	var all_types := fresh()
	all_types.state.coins = 10000000
	for sid in all_types.shelter_types:
		all_types.state.shelters[sid] = 3
	for kind in values.animals:
		check(all_types.command("buy_animal", {"animal_id": str(kind.id)}).ok, "%s animal route purchasable" % kind.id)
	var restore := fresh()
	check(restore.restore(all_types.snapshot()).ok, "All eleven animal types save and restore")
	all_types.state.farmers = []
	for animal in all_types.state.animals:
		animal.adult_remaining = 1
		animal.food_remaining = 100000
	all_types.tick(1)
	for animal in all_types.state.animals:
		check(animal.adult and animal.product_remaining == all_types.animal_types[str(animal.type_id)].produce_seconds, "%s starts produce only after adulthood" % animal.type_id)
		animal.product_remaining = 1
	all_types.tick(1)
	all_types.tick(1000)
	check(all_types.state.animals.all(func(a): return int(a.ready) == 1), "All animals keep at most one ready product until collection")
	var recovery := fresh()
	recovery.state.coins = 0
	recovery.state.seeds = {}
	recovery.tick(1800)
	check(int(recovery.state.catalog.get("egg", {}).get("count", 0)) >= 4, "Zero-cash ranch recovers income through free feed and automatic egg collection")
	check(recovery.state.plots.any(func(p): return p.open and p.status != "empty") and recovery.balance() >= 0, "Recovered ranch income can restart seedless crop plots without debt")

func _test_grass() -> void:
	var game := fresh()
	game.state.animals = []
	game.state.farmers = []
	for grass in game.state.grass:
		grass.open = int(grass.index) < 3
		grass.mother = false
		grass.clumps = 4 if int(grass.index) == 0 else 0
	game.state.rng.grass = 2
	var copy := fresh()
	check(copy.restore(game.snapshot()).ok, "Grass random snapshot restores")
	game.tick(180)
	copy.tick(180)
	check(game.state.grass[1].clumps >= 1 and game.state.grass[1].clumps <= 2, "Deterministic spread actually creates new grass without same-batch growth")
	check(game.state.grass[2].clumps == 0, "Newly spread grass does not cascade within same batch")
	check(JSON.stringify(game.snapshot()) == JSON.stringify(copy.snapshot()), "Random grass stream deterministic after reload")
	check(game.state.grass.filter(func(g): return int(g.clumps) > 4 or (not g.open and int(g.clumps) > 0)).is_empty(), "Grass growth respects bounds/open plots")
	var full := fresh()
	full.state.animals = []
	for plot in full.state.plots:
		plot.open = false
	full.state.warehouse_hay = 24
	full.state.trough_hay = 24
	full.tick(30)
	check(full.state.grass[2].clumps == 4 and full.state.warehouse_hay == 24, "Full warehouse and trough do not cut/discard hay")

func _test_farmers() -> void:
	var game := fresh()
	game.state.coins = 100000
	var cash := game.balance()
	check(game.command("hire_farmer", {"scene": "farm"}).ok and game.balance() == cash - 1000, "First global hire costs 1000")
	cash = game.balance()
	check(game.command("hire_farmer", {"scene": "ranch"}).ok and game.balance() == cash - 2000, "Second hire in other scene costs 2000")
	var pond: Dictionary = game.state.farmers.filter(func(f): return str(f.home) == "pond")[0]
	check(game.command("transfer_farmer", {"farmer_id": pond.id, "scene": "farm"}).ok, "Idle free permanent transfer")
	check(game.state.paid_hires == 2, "Transfer does not reset global hire ordinal")
	check(not game.command("hire_farmer", {"scene": "farm"}).ok, "Home capacity limited to three")
	game.tick(1)
	for farmer in game.state.farmers:
		if farmer.mode == "outbound":
			check(farmer.energy == 80 and farmer.remaining == 5, "Support charges 20 once with five-second travel")
	game.tick(3000)
	for scene in ["farm", "ranch", "pond"]:
		check(game._occupancy(scene) <= 3, "Support occupancy <= 3 in %s" % scene)
	check(game.state.farmers.all(func(f): return float(f.energy) >= 0 and float(f.energy) <= 100), "Worker energy stays in range")
	var support := fresh()
	support.tick(1)
	var supporter: Dictionary = support.state.farmers.filter(func(f): return str(f.home) == "pond")[0]
	check(supporter.mode == "outbound" and supporter.energy == 80, "Pond worker supports active farm")
	var resumed := fresh()
	check(resumed.restore(support.snapshot()).ok, "Support trip restores")
	resumed.tick(1)
	check(resumed.state.farmers.filter(func(f): return str(f.home) == "pond")[0].energy == 80, "Reload does not repay support cost")
	var cycle := fresh()
	cycle.state.coins = 1000000
	for scene in ["farm", "ranch", "pond"]:
		cycle.command("hire_farmer", {"scene": scene})
		cycle.command("hire_farmer", {"scene": scene})
	var destinations := {"farm": "ranch", "ranch": "pond", "pond": "farm"}
	for farmer in cycle.state.farmers:
		farmer.scene = destinations[str(farmer.home)]
	cycle._return_home(cycle.state.farmers[0])
	check(cycle.state.farmers.filter(func(f): return f.mode == "returning").size() == 3, "Three full scenes plan chained visitor return without deadlock")
	for scene in ["farm", "ranch", "pond"]:
		check(cycle._occupancy(scene) == 3, "Planned return retains exactly three reservations in %s" % scene)
	check(fresh().restore(cycle.snapshot()).ok, "Chained return claims form a valid save snapshot")

func _test_fish_and_rng() -> void:
	var game := fresh()
	game.state.animals = []
	game.state.farmers = []
	for plot in game.state.plots:
		plot.open = false
	var before_cash := game.balance()
	game.tick(3600)
	check(game.balance() == before_cash and game.state.fish.size() == 12, "Unattended pond earns zero, stays at capacity")
	check(game.state.fish_remaining == 180, "Full pond freezes spawn remainder")
	var fish_id := str(game.state.fish[0].id)
	check(game.command("cast_net", {"fish_id": fish_id}).ok, "Manual cast catches at most one fish")
	check(game.state.fish.size() == 11 and not game.state.pending_fish.is_empty(), "Caught fish held pending separately")
	check(not game.command("cast_net", {"fish_id": game.state.fish[0].id}).ok, "Pending fish blocks new casts")
	var restored := fresh()
	check(restored.restore(game.snapshot()).ok and restored.state.pending_fish.id == fish_id, "Pending fish preserved through save/reload")
	var price := int(game.fish_types[str(game.state.pending_fish.type_id)].sell_price)
	check(restored.command("resolve_fish", {"choice": "sell"}).ok and restored.balance() == before_cash + price, "Pending fish sale pays actual price")
	check(not restored.command("resolve_fish", {"choice": "sell"}).ok, "Pending fish cannot sell twice")
	game.command("resolve_fish", {"choice": "catalog"})
	check(game.balance() == before_cash and game.state.catalog.size() == 1, "Catalog choice consumes fish without money")
	game.tick(20)
	check(game.command("cast_net", {}).ok and game.state.net_remaining == 20, "Miss also consumes cooldown")
	game.tick(159)
	check(game.state.fish.size() == 11 and game.state.fish_remaining == 1, "Spawn exact boundary retained after catch")
	var copy := fresh()
	check(copy.restore(game.snapshot()).ok, "Fish RNG snapshot restores")
	game.tick(1)
	copy.tick(1)
	check(game.state.fish.size() == 12 and JSON.stringify(game.snapshot()) == JSON.stringify(copy.snapshot()), "Natural fish spawn deterministic after reload")

func _test_persistence() -> void:
	var game := fresh()
	game.tick(2)
	var path := "user://test-simulation-save.json"
	var store := Persistence.new(path)
	check(store.save(game.snapshot()).ok, "First atomic file save")
	game.command("sell_animal", {"instance_id": game.state.animals[0].id})
	check(store.save(game.snapshot()).ok, "Second atomic save preserves backup")
	var loaded := store.load_save()
	check(loaded.ok, "Read saved file")
	var restored := fresh()
	check(restored.restore(loaded.data).ok and restored.balance() == game.balance(), "Latest sale transaction persists")
	var file := FileAccess.open(store.path, FileAccess.WRITE)
	file.store_string("{broken")
	file.close()
	var fallback := store.load_save()
	check(fallback.ok and fallback.get("from_backup", false), "Damaged main file falls back to complete backup")
	check(restored.restore(fallback.data).ok, "Backup snapshot valid")
	check(store.save(fallback.data).ok, "Recovered backup atomically repairs damaged main")
	var preserved := store.load_backup()
	check(preserved.ok and JSON.stringify(preserved.data) == JSON.stringify(fallback.data), "Recovery never replaces valid backup with corrupt main")
	# Semantic corruption also uses load_backup() before repairing the main.
	var invalid_main := game.snapshot()
	invalid_main.coins = -1
	file = FileAccess.open(store.path, FileAccess.WRITE)
	file.store_string(JSON.stringify(invalid_main))
	file.close()
	preserved = store.load_backup()
	check(preserved.ok and store.save(preserved.data).ok, "Semantic corruption repair retains the previous valid backup")
	check(store.load_backup().ok, "Valid backup survives semantic repair")
	var invalid := game.snapshot()
	invalid.coins = -1
	check(not restored.restore(invalid).ok, "Negative resources rejected")
	invalid = game.snapshot()
	invalid.animals[0].type_id = "unknown"
	check(not restored.restore(invalid).ok, "Unknown content ID rejected")
	invalid = game.snapshot()
	invalid.version = 99
	check(not restored.restore(invalid).ok, "Unknown schema rejected without silently clearing save")
	for suffix in ["", ".bak", ".tmp", ".bak.tmp"]:
		if FileAccess.file_exists(store.path + suffix):
			DirAccess.remove_absolute(store.path + suffix)

func _test_full_scale() -> void:
	var game := fresh()
	game.state.coins = 1000000
	for region in game.state.regions:
		region.unlocked = true
	for plot in game.state.plots:
		plot.open = true
	for grass in game.state.grass:
		grass.open = true
		grass.clumps = 4
	game.state.storage_level = 3
	game.state.warehouse_hay = 256
	game.state.trough_hay = 256
	game.state.animals = []
	for sid in game.shelter_types:
		game.state.shelters[sid] = 3
	for kind in values.animals:
		if int(kind.min_level) != 1:
			continue
		for unused in range(12):
			game._add_animal(str(kind.id))
	for animal in game.state.animals:
		animal.adult = true
		animal.adult_remaining = 0
	game.state.farmers = []
	for scene in ["farm", "ranch", "pond"]:
		for unused in range(3):
			game._add_farmer(scene)
	game.state.paid_hires = 6
	check(game.state.plots.size() == 96 and game.state.grass.size() == 96 and game.state.animals.size() == 84 and game.state.farmers.size() == 9 and game.state.fish.size() == 12, "Full-scale fixture matches all documented caps")
	var total_started := Time.get_ticks_usec()
	game.tick(900)
	var midpoint := game.snapshot()
	var resumed := fresh()
	check(resumed.restore(midpoint).ok, "Full-scale midpoint snapshot restores active work/resources")
	var resumed_started := Time.get_ticks_usec()
	resumed.tick(900)
	var resumed_ms := float(Time.get_ticks_usec() - resumed_started) / 1000.0
	game.tick(900)
	var total_ms := float(Time.get_ticks_usec() - total_started) / 1000.0
	check(JSON.stringify(game.snapshot()) == JSON.stringify(resumed.snapshot()), "Full-scale 30-minute result identical across halfway restore, including random streams")
	check(float(game.state.elapsed) == 1800 and game.balance() >= 0, "Full-scale advances exactly 1800 active seconds without debt")
	check(game.state.animals.all(func(a): return int(a.ready) >= 0 and int(a.ready) <= 1), "Full-scale animal backlog bounded to one each")
	check(game.state.grass.all(func(g): return int(g.clumps) >= 1 and int(g.clumps) <= 4), "Full-scale grass roots and clump cap maintained")
	check(game.state.grass[0].clumps == 4 and game.state.grass[1].clumps == 4, "Full-scale mother grass remains untouched")
	check(game.state.warehouse_hay <= 256 and game.state.trough_hay <= 256 and game.state.warehouse_hay >= 0 and game.state.trough_hay >= 0, "Full-scale both hay capacities and nonnegative stock respected")
	for scene in ["farm", "ranch", "pond"]:
		check(game._occupancy(scene) <= 3 and game._home_count(scene) == 3, "Full-scale worker capacity respected in %s" % scene)
	check(game.state.fish.size() == 12 and game.state.fish_remaining == 180, "Full-scale unattended pond preserves capacity and spawn remainder")
	var obtained := 0
	for item in game.state.catalog.values():
		obtained += int(item.count)
	check(obtained > 0 and game.state.catalog.has("parsnip"), "Full-scale queues produce and register actual goods")
	full_scale_report = {"active_seconds": 1800, "coins": game.balance(), "protection": game.protection(),
		"catalog_products": game.state.catalog.size(), "collected_total": obtained,
		"hay_warehouse": game.state.warehouse_hay, "hay_trough": game.state.trough_hay,
		"hungry_animals": game.state.animals.filter(func(a): return a.hungry).size(),
		"ready_animals": game.state.animals.filter(func(a): return int(a.ready) == 1).size(),
		"occupancy": {"farm": game._occupancy("farm"), "ranch": game._occupancy("ranch"), "pond": game._occupancy("pond")},
		"random_state": game.state.rng.duplicate(true), "restore_identical": true,
		"900_seconds_resumed_wall_ms": resumed_ms, "1800_plus_900_replay_wall_ms": total_ms}
