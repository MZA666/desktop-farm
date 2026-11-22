extends SceneTree

const Model = preload("res://scripts/game_state.gd")
const Config = preload("res://scripts/config_loader.gd")
const World = preload("res://scripts/world_layout.gd")
var failures: Array[String] = []
var assertions := 0
var values: Dictionary

func _init() -> void:
	values = Config.load_values()
	_test_budget_and_library()
	_test_claims_and_rollback()
	_test_world_and_travel()
	_test_farmer_idle_activity()
	_test_migration()
	if failures.is_empty():
		print("STAGE_A_MODEL_PASS: %d budget/library/claims/world/migration assertions" % assertions)
		quit(0)
	else:
		for failure in failures: printerr("FAIL: " + failure)
		quit(1)

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition: failures.append(message)

func fresh() -> FarmState:
	return Model.new(values)

func growing() -> FarmState:
	var game := fresh()
	game.state.farmers = []
	game.state.animals = []
	game.state.seeds = {}
	for plot in game.state.plots:
		if plot.open:
			plot.status = "growing"
			plot.remaining = 720.0
			plot.product = game._product_for_crop(game.crops.parsnip)
	return game

func _test_farmer_idle_activity() -> void:
	var game := growing()
	game.state.warehouse_hay = game.storage_capacity()
	game.state.trough_hay = game.storage_capacity()
	for index in range(48):
		var plot: Dictionary = game.state.plots[index]
		plot.open = true
		plot.status = "growing"
		plot.remaining = 720.0
		plot.product = game._product_for_crop(game.crops.parsnip)
	game._add_farmer("farm")
	var farmer: Dictionary = game.state.farmers[0]
	var start := Vector2(float(farmer.x), float(farmer.y))
	var cash := game.balance()
	var seed_stock: Dictionary = game.state.seeds.duplicate()
	game.tick(10)
	check(Vector2(float(farmer.x), float(farmer.y)) == start, "Farm worker waits before starting a leisure route")
	game.tick(16)
	check(farmer.mode == "idle" and farmer.task.is_empty() and farmer.get("idle_activity", {}).get("action", "") == "patrol" and Vector2(float(farmer.x), float(farmer.y)) != start, "Idle farmer starts walking along the ridge")
	var walking := game.snapshot()
	var resumed := fresh()
	check(resumed.restore(walking).ok and JSON.stringify(resumed.snapshot()) == JSON.stringify(walking), "Idle route survives saving mid-walk")
	game.tick(0.6)
	resumed.tick(0.6)
	check(JSON.stringify(resumed.snapshot()) == JSON.stringify(game.snapshot()), "Restored worker advances the same route on reload")
	var interrupted: Dictionary = resumed.state.farmers[0]
	var before := Vector2(float(interrupted.x), float(interrupted.y))
	resumed.state.plots[0].remaining = 0.2
	resumed.tick(0.2)
	check(not interrupted.has("idle_activity") and interrupted.mode == "working" and interrupted.task.action == "harvest", "Ready crops immediately preempt leisure")
	check(Vector2(float(interrupted.x), float(interrupted.y)) == before, "An interrupted farmer begins work from the current position")
	var helping := fresh()
	check(helping.restore(walking).ok, "Idle route can be resumed before a support request")
	helping.state.warehouse_hay = 0
	helping.tick(0.2)
	var helper: Dictionary = helping.state.farmers[0]
	check(helper.mode == "outbound" and helper.destination == "ranch" and not helper.has("idle_activity"), "Prioritized ranch support also preempts leisure")

	var actions_seen := {}
	var flower_trip := {}
	for second in range(160):
		game.tick(1)
		var activity: Dictionary = farmer.get("idle_activity", {})
		if activity.is_empty(): continue
		if activity.path.is_empty(): actions_seen[activity.action] = true
		if flower_trip.is_empty() and activity.action == "flower_box" and not activity.path.is_empty(): flower_trip = game.snapshot()
	check(actions_seen.has("patrol") and actions_seen.has("flower_box") and actions_seen.has("stone_well") and actions_seen.has("rest"), "Farmer completes patrol, flower care, well visit and rest")
	check(game.balance() == cash and game.state.seeds == seed_stock and farmer.energy == 100.0, "Leisure consumes no cash, seeds or energy")
	var rerouted := fresh()
	check(not flower_trip.is_empty() and rerouted.restore(flower_trip).ok, "An in-progress decoration visit restores")
	check(rerouted.command("set_decoration", {"decoration_id": "flower_box", "placement": 1}).ok and not rerouted.state.farmers[0].has("idle_activity"), "Moving a planter cancels the visit to its former location")

func _test_budget_and_library() -> void:
	var game := fresh()
	check(game.state.version == 3 and not game.state.has("regions"), "V3 retains independent plots and no region state")
	check(game.state.plots.size() == 96 and game.state.plots[23].open and not game.state.plots[24].open, "Initial first 24 of 96 plots open")
	for i in range(96):
		check(int(game.state.plots[i].index) == i and str(game.state.plots[i].id) == "plot_%d_%d" % [i / 16, i % 16], "Stable legacy ID and global index %d" % i)
	check(game.protection() == 480, "Gift first batch leaves 480 budget")
	game.tick(1)
	check(game.protection() == 480 and int(game.state.seeds.parsnip) == 23, "Claimed first seed is not counted twice")
	check(game.seed_preview("plot_0_0").in_flight and game.seed_preview("plot_0_0").cost == 0, "Preview reports owned in-flight seed without another quote")
	var bought := fresh()
	check(bought.command("buy_seeds", {"crop_id": "parsnip", "count": 24}).ok, "Seed purchase may convert protected cash into inventory")
	check(bought.balance() == 520 and bought.state.seeds.parsnip == 48 and bought.protection() == 0 and bought.investable() == 520, "Purchase cash/stock/budget conserve investable money")
	var mixed := growing()
	mixed.state.unlocked_crops.append("cauliflower")
	mixed.state.seeds = {"carrot": 1, "cauliflower": 1}
	check(mixed.protection() == 440, "Library rotation uses two different existing seeds before 22 orders")
	var before := JSON.stringify(mixed.snapshot())
	check(not mixed.command("set_default_seed", {"crop_id": "cauliflower"}).ok and JSON.stringify(mixed.snapshot()) == before, "Default change exceeding 1760 budget rolls back fully")
	mixed.state.coins = 5000
	check(mixed.command("set_default_seed", {"crop_id": "cauliflower"}).ok and mixed.protection() == 1760, "Only 22 orders use changed default price")
	check(mixed.command("set_default_seed", {"crop_id": str(mixed.state.previous_default_seed_id)}).ok and mixed.protection() == 440, "Restoring earlier default releases remaining-order budget")
	mixed.state.default_seed_id = "cauliflower"
	mixed.state.coins = 200
	check(mixed.command("set_default_seed", {"crop_id": "parsnip"}).ok and mixed.balance() == 200 and mixed.protection() == 440, "A cash-poor save can reduce its future seed budget even while it is still below reserve")
	var preview := mixed.seed_preview("plot_0_0")
	check(preview.crop_id == "carrot" and preview.source == "inventory" and preview.cost == 0, "Fixed config order selects carrot before cauliflower")
	check(mixed.state.seeds.carrot == 1, "Preview does not consume inventory")
	var cost_sum := 0
	var previous_price := 0
	var all := fresh()
	all.state.coins = 10000000
	check(all.plot_expansion_price() == 900, "First extra plot costs 900")
	var placement := {"decoration_id": "flower_box", "placement": 1}
	var locked := all.snapshot()
	check(not all.command("set_decoration", placement).ok and all.snapshot() == locked, "Locked decor cannot be moved")
	for i in range(72):
		var price := all.plot_expansion_price()
		check(price > previous_price, "Plot expansion price rises at purchase %d" % (i + 1))
		previous_price = price
		cost_sum += price
		var expansion := all.command("expand_plot")
		check(expansion.ok, "Independent expansion %d succeeds without region gates" % i)
		if i == 3:
			check(str(expansion.message).contains("木制花箱") and Model.DECOR.placement(all.state, "flower_box") == 0, "28th plot automatically places flower box")
	check(previous_price == 692000 and cost_sum == 9754200 and all.plot_expansion_price() == -1, "72 prices end at 692000 and sum to 9754200")
	var wrong := all.snapshot()
	check(not all.command("expand_plot").ok and JSON.stringify(wrong) == JSON.stringify(all.snapshot()), "Full expansion rejects without mutation")
	var cash := all.balance()
	check(all.command("set_decoration", placement).ok and all.balance() == cash, "Moving decor leaves cash unchanged")
	var copy := fresh()
	check(copy.restore(all.snapshot()).ok and Model.DECOR.placement(copy.state, "flower_box") == 1, "Alternative decoration position survives restore")
	check(copy.command("set_decoration", {"decoration_id": "flower_box", "placement": -1}).ok and Model.DECOR.placement(copy.state, "flower_box") == -1, "Unlocked pieces can be put away")
	check(not copy.command("set_decoration", {"decoration_id": "stone_well", "placement": 2}).ok, "Out-of-range locations are rejected")

func _test_claims_and_rollback() -> void:
	var game := growing()
	game.state.unlocked_crops.append("cauliflower")
	game.state.seeds = {"carrot": 1, "cauliflower": 1}
	check(game.command("set_crop", {"plot_ids": ["plot_0_0"], "crop_id": "cauliflower"}).ok, "Pending explicit crop accepts stock binding")
	check(game.protection() == 460 and game.seed_inventory_summary("cauliflower").reserved == 1 and game.seed_inventory_summary("cauliflower").available == 0, "Bound cauliflower plus following batch has exact 460 budget")
	check(game.seed_preview("plot_0_1").crop_id == "carrot", "Other plot cannot steal pending cauliflower")
	var copy := fresh()
	check(copy.restore(game.snapshot()).ok and JSON.stringify(copy.snapshot()) == JSON.stringify(game.snapshot()), "Pending seed ledger roundtrips unchanged")
	check(game.command("cancel_crop", {"plot_ids": ["plot_0_0"]}).ok and game.protection() == 440 and game.state.seeds.cauliflower == 1, "Cancel releases owned seed and pending-only budget")
	var before := JSON.stringify(game.snapshot())
	check(not game.command("set_crop", {"plot_ids": ["plot_0_0", "bad"], "crop_id": "carrot"}).ok and JSON.stringify(game.snapshot()) == before, "Batch command validates every target before changing any")
	check(not game.command("buy_seeds", {"crop_id": "carrot", "count": 0.5}).ok and JSON.stringify(game.snapshot()) == before, "Fractional purchase cannot mutate money or seeds")
	var task_game := fresh()
	task_game.tick(1)
	var farmer: Dictionary = task_game.state.farmers[0]
	var actual := str(farmer.task.crop_id)
	check(task_game.command("set_crop", {"plot_ids": [str(farmer.task.target)], "crop_id": "carrot"}).ok and farmer.task.crop_id == actual, "Changing preference leaves in-flight seed immutable")
	task_game._cancel_task(farmer)
	check(task_game.state.seeds.parsnip == 24 and farmer.task.is_empty(), "Cancelled uncommitted sow returns exactly its seed")
	var special := fresh()
	special.state.farmers = []
	special.state.seeds = {"ancient_fruit": 1}
	for plot in special.state.plots: plot.open = int(plot.index) == 0
	check(special.protection() == 0, "Actual rotated regrowing seed has no following sow cost")
	special.state.seeds = {"carrot": 1}
	special.state.plots[0].preferred_crop_id = "ancient_fruit"
	check(special.protection() == 20, "Missing preferred regrow seed actually uses carrot then needs default order")
	special.state.seeds = {"sunflower": 1}
	check(special.protection() == 0, "Actual rotated sunflower returns its own seed for the following batch")
	special.state.plots[0].crop_id = "sunflower"
	special.state.plots[0].return_seed = true
	special.state.seeds = {}
	check(special.seed_preview("plot_0_0").source == "dedicated", "Rotated sunflower retains dedicated seed despite the older preference")
	check(special.command("set_crop", {"plot_ids": ["plot_0_0"], "crop_id": "parsnip"}).ok and special.seed_preview("plot_0_0").source == "automatic", "Explicit replacement discards the original-plot seed")

func _test_world_and_travel() -> void:
	check(World.legacy_plot_position(0) == Vector2(64, 20) and World.legacy_plot_position(23) == Vector2(288, 84) and World.legacy_plot_position(95) == Vector2(1056, 84), "Legacy coordinate mapping remains available for strict migration")
	check(World.plot_position(0) == Vector2(352, 112) and World.plot_position(23) == Vector2(744, 168) and World.plot_position(95) == Vector2(1192, 392), "New world keeps exact 16-by-6 independent plot coordinates")
	var game := fresh()
	game.state.farmers = game.state.farmers.filter(func(f): return f.home == "farm")
	game.tick(1)
	var farmer: Dictionary = game.state.farmers[0]
	var start := Vector2(float(farmer.x), float(farmer.y))
	var target := Vector2(float(farmer.path_target_x), float(farmer.path_target_y))
	check(farmer.phase == "walking" and farmer.mode == "working" and game.state.plots[0].status == "empty", "Sow remains uncommitted during real travel")
	game.tick(1)
	check(is_equal_approx(Vector2(float(farmer.x), float(farmer.y)).distance_to(start), 32.0), "Default speed moves 32 real world pixels in one second")
	var position := Vector2(float(farmer.x), float(farmer.y))
	check(game.command("settings", {"values": {"farmer_speed": 16}}).ok and Vector2(float(farmer.x), float(farmer.y)) == position, "Mid-walk speed change does not teleport")
	var saved := game.snapshot()
	var resumed := fresh()
	check(resumed.restore(saved).ok, "Walking position, target and phase restore")
	game.tick(30)
	resumed.tick(30)
	check(JSON.stringify(game.snapshot()) == JSON.stringify(resumed.snapshot()), "Real-distance work deterministic across restore")
	check(game.state.plots[0].status == "growing" and target == World.target_position("farm", "plot_0_0", game.state), "Only arrival plus full actions starts growth")
	var invalid := saved.duplicate(true)
	invalid.farmers[0].x = NAN
	check(not resumed.restore(invalid).ok, "NaN world position rejected")
	var exact := fresh()
	exact.state.farmers = exact.state.farmers.filter(func(f): return f.home == "farm")
	var worker: Dictionary = exact.state.farmers[0]
	exact._dispatch(worker)
	var distance := Vector2(float(worker.x), float(worker.y)).distance_to(Vector2(float(worker.path_target_x), float(worker.path_target_y)))
	exact._advance_farmer(worker, distance / 32.0)
	check(worker.phase == "acting" and is_equal_approx(float(worker.remaining), 2.0) and exact.state.plots[0].status == "empty", "Exact arrival starts full two-second action without early commit")
	exact._advance_farmer(worker, 1.999)
	check(exact.state.plots[0].status == "empty", "Action cannot commit before the last millisecond")
	exact._advance_farmer(worker, 0.001)
	check(exact.state.plots[0].status == "unwatered" and worker.task.is_empty(), "Arrival plus exactly two seconds commits once")

func legacy_fixture() -> Dictionary:
	var data := fresh().snapshot()
	data.version = 1
	data.regions = []
	for ri in range(6): data.regions.append({"index": ri, "unlocked": ri < 4, "current_crop_id": "parsnip", "pending_crop_id": ""})
	for i in range(96):
		var plot: Dictionary = data.plots[i]
		plot.region = i / 16
		plot.index = i % 16
		plot.open = i / 16 < 4 and i % 16 < 6
		plot.erase("preferred_crop_id")
		plot.erase("pending_crop_id")
	for farmer in data.farmers:
		for key in ["x", "y", "path_target_x", "path_target_y", "phase"]: farmer.erase(key)
	data.settings.erase("farmer_speed")
	for key in ["default_seed_id", "previous_default_seed_id", "seed_reservations"]: data.erase(key)
	return data

func _test_migration() -> void:
	var data := legacy_fixture()
	data.regions[0].pending_crop_id = "cauliflower"
	data.seeds.cauliflower = 1
	data.seeds.parsnip = 23
	data.farmers[0].mode = "working"
	data.farmers[0].remaining = 1.75
	data.farmers[0].task = {"action": "sow", "target": "plot_0_0", "crop_id": "parsnip", "seed_source": "inventory"}
	data.plots[1].crop_id = "mixed_seeds"
	data.plots[1].status = "growing"
	data.plots[1].remaining = 123.0
	data.plots[1].product = {"id": "potato", "name": "土豆", "sell_price": 80}
	data.plots[2].crop_id = "unmilled_rice"
	data.plots[2].status = "processing"
	data.plots[2].remaining = 99.0
	data.plots[2].product = {"id": "rice", "name": "大米", "sell_price": 100}
	var original := JSON.stringify(data)
	var game := fresh()
	var migrated := game.migrate_v1(data)
	check(migrated.ok and JSON.stringify(data) == original, "Migration validates and converts without touching source")
	if migrated.ok:
		check(migrated.data.plots.filter(func(p): return p.open).size() == 24 and not migrated.data.has("regions"), "Migration retains exact opened plots and removes regions")
		check(migrated.data.farmers[0].phase == "acting" and migrated.data.farmers[0].remaining == 1.75 and migrated.data.seeds.parsnip == 23, "Prepaid old action and remaining time retain their seed")
		check(migrated.data.plots[1].crop_id == "mixed_seeds" and migrated.data.plots[1].remaining == 123 and migrated.data.plots[1].product == data.plots[1].product and migrated.data.rng.crop == data.rng.crop and migrated.data.rng.grass == data.rng.grass and migrated.data.rng.fish == data.rng.fish, "Migration retains mixed package, frozen random product, timing and production RNG")
		check(migrated.data.plots[2].status == "processing" and migrated.data.plots[2].remaining == 99 and migrated.data.plots[2].product == data.plots[2].product, "Migration preserves in-progress serial rice processing")
		check(game.restore(data).ok and game.state.seed_reservations.size() == 1, "Restore accepts valid V1 and binds pending stock")
		var coins := game.balance()
		game.tick(2)
		check(game.balance() == coins and game.state.plots[0].status == "unwatered", "Old reserved sow completes without second purchase")
	for variant in ["missing", "empty", "bad_regions", "nan", "negative", "fractional_seed"]:
		var bad := legacy_fixture()
		match variant:
			"missing": bad.erase("coins")
			"empty": bad.plots[0] = {}
			"bad_regions": bad.regions[0] = {}
			"nan": bad.rng.crop = NAN
			"negative": bad.coins = -1
			"fractional_seed": bad.seeds.parsnip = 1.5
		var before := JSON.stringify(game.snapshot())
		check(not game.migrate_v1(bad).ok and not game.restore(bad).ok and JSON.stringify(game.snapshot()) == before, "Invalid legacy %s cannot overwrite current model" % variant)
