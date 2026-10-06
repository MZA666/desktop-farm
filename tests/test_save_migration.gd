extends SceneTree

const MODEL = preload("res://scripts/game_state.gd")
const STORE = preload("res://scripts/save_store.gd")
const CONFIG = preload("res://scripts/config_loader.gd")
const WORLD = preload("res://scripts/world_layout.gd")
const V4 = preload("res://scripts/world_layout_v4.gd")
const V5 = preload("res://scripts/world_layout_v5.gd")
const RANCH = preload("res://scripts/ranch_life.gd")
const PRODUCTS = preload("res://scripts/ground_products.gd")
var failures: Array[String] = []
var assertions := 0
var directory := ""
var values: Dictionary

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition: failures.append(message)

func _run() -> void:
	values = CONFIG.load_values()
	directory = ProjectSettings.globalize_path("res://.review/migration-" + str(Time.get_ticks_usec()))
	check(DirAccess.make_dir_recursive_absolute(directory) == OK, "Isolated migration directory created")
	var initial: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/save-v1-initial.json"))
	var old: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/save-v1-active.json"))
	var initial_path := directory.path_join("initial.json")
	_write(initial_path, initial)
	var initial_store: FarmSaveStore = STORE.new(initial_path, values)
	var loaded: Dictionary = initial_store.load_save()
	check(loaded.ok and loaded.get("migrated", false), "Real v1 startup fixture migrates")
	if not loaded.ok:
		printerr(loaded.message)
		_finish()
		return
	var initial_model: FarmState = MODEL.new(values)
	check(initial_model.restore(loaded.data).ok, "Migrated startup passes strict current validation")
	check(loaded.data.version == MODEL.SAVE_VERSION and loaded.data.layout_version == MODEL.LAYOUT_VERSION and not loaded.data.has("regions"), "Migration removes region state and initializes current world")
	check(initial_model.balance() == 1000 and initial_model.protection() == 480, "Initial coins and seed protection preserved")
	check(loaded.data.plots.filter(func(p): return p.open).size() == 24, "Original open count preserved")
	check(FileAccess.get_sha256(initial_path + ".bak") == FileAccess.get_sha256(loaded.migration_backup), "Original v1 and versioned backup retain exact bytes")
	var original_backup: String = loaded.migration_backup
	var original_hash := FileAccess.get_sha256(original_backup)
	var repeated: Dictionary = initial_store.load_save()
	check(repeated.ok and not repeated.get("migrated", false), "Second startup does not migrate the current save again")
	check(FileAccess.get_sha256(original_backup) == original_hash, "Repeated startup never overwrites the versioned backup")
	initial_model.state.coins += 7
	check(initial_store.save(initial_model.snapshot()).ok, "Ordinary save after migration succeeds")
	check(FileAccess.get_sha256(original_backup) == original_hash, "Ordinary saves cannot replace original migration backup")
	var active_path := directory.path_join("active.json")
	_write(active_path, old)
	var active_store: FarmSaveStore = STORE.new(active_path, values)
	var active: Dictionary = active_store.load_save()
	check(active.ok and active.get("migrated", false), "Active legacy game migrates")
	if not active.ok:
		printerr(active.message)
		_finish()
		return
	var resumed: FarmState = MODEL.new(values)
	check(resumed.restore(active.data).ok, "Active migrated state is usable")
	check(resumed.balance() == int(old.coins) and float(resumed.state.elapsed) == float(old.elapsed), "Migration preserves cash and effective clock")
	check(resumed.state.rng.crop == old.rng.crop and resumed.state.rng.grass == old.rng.grass and resumed.state.rng.fish == old.rng.fish, "Migration preserves all independent production random streams")
	check(JSON.stringify(resumed.state.catalog) == JSON.stringify(old.catalog), "Migration preserves catalog")
	check(resumed.state.farmers[0].task == old.farmers[0].task, "Already paid seed task preserves source, crop and target")
	check(float(resumed.state.farmers[0].remaining) == float(old.farmers[0].remaining), "Legacy task retains remaining work")
	for plot in old.plots:
		var migrated: Dictionary = resumed.state.plots.filter(func(p): return str(p.id) == str(plot.id))[0]
		check(migrated.open == plot.open and migrated.crop_id == plot.crop_id and migrated.status == plot.status and migrated.remaining == plot.remaining and migrated.product == plot.product, "Legacy plot entity retained: " + str(plot.id))
		if plot.open and str(plot.crop_id) != "cauliflower" and int(plot.region) == 0:
			check(migrated.pending_crop_id == "cauliflower", "Old pending target expanded to this unfinished plot: " + str(plot.id))
	var before_seed_total := 0
	for quantity in old.seeds.values(): before_seed_total += int(quantity)
	var after_seed_total := 0
	for quantity in resumed.state.seeds.values(): after_seed_total += int(quantity)
	for claim in resumed.state.seed_reservations: after_seed_total += int(claim.quantity)
	check(after_seed_total == before_seed_total, "Binding pending reservations neither duplicates nor loses physical seeds")
	var snapshot := resumed.snapshot()
	resumed.tick(1.0)
	check(resumed.balance() == int(old.coins), "Resuming prepaid task does not buy its seed again")
	var after_restart := MODEL.new(values)
	check(after_restart.restore(snapshot).ok, "Migrated actor task reloads")
	after_restart.tick(1.0)
	check(JSON.stringify(resumed.snapshot()) == JSON.stringify(after_restart.snapshot()), "Migrated task resumes deterministically")
	var bad_v1 := old.duplicate(true)
	bad_v1.plots[0].remaining = -1
	var corrupt_path := directory.path_join("corrupt-v1.json")
	_write(corrupt_path, bad_v1)
	_write(corrupt_path + ".bak", old)
	var healthy_backup_hash := FileAccess.get_sha256(corrupt_path + ".bak")
	var recovery: Dictionary = STORE.new(corrupt_path, values).load_save()
	check(recovery.ok and recovery.get("from_backup", false) and recovery.get("migrated", false), "Semantically bad legacy main falls back to a valid legacy backup")
	check(FileAccess.get_sha256(corrupt_path + ".bak") == healthy_backup_hash, "Bad main never replaces the healthy legacy backup")
	var corrupt_v2_path := directory.path_join("corrupt-v2.json")
	var bad_v2: Dictionary = active.data.duplicate(true)
	bad_v2.coins = -1
	_write(corrupt_v2_path, bad_v2)
	_write(corrupt_v2_path + ".bak", active.data)
	var fallback: Dictionary = STORE.new(corrupt_v2_path, values).load_save()
	check(fallback.ok and fallback.get("from_backup", false), "Semantically invalid v2 also tries a valid backup")
	var future_path := directory.path_join("future.json")
	var future: Dictionary = active.data.duplicate(true)
	future.version = 99
	_write(future_path, future)
	_write(future_path + ".bak", initial)
	var future_hash := FileAccess.get_sha256(future_path)
	check(not STORE.new(future_path, values).load_save().ok, "Unknown future schema rejected despite an older valid backup")
	check(FileAccess.get_sha256(future_path) == future_hash, "Unknown future save stays untouched")
	var failed_path := directory.path_join("failed-write.json")
	_write(failed_path, old)
	var before_failure := FileAccess.get_sha256(failed_path)
	_write(failed_path + ".bak", initial)
	var older_backup_hash := FileAccess.get_sha256(failed_path + ".bak")
	DirAccess.make_dir_recursive_absolute(failed_path + ".tmp")
	var failed_migration: Dictionary = STORE.new(failed_path, values).load_save()
	check(not failed_migration.ok and failed_migration.get("migration_write_failed", false), "Valid main migration write failure blocks startup instead of rolling back to older backup")
	check(FileAccess.get_sha256(failed_path) == before_failure, "Failed migrated write leaves original file intact")
	check(FileAccess.get_sha256(failed_path + ".bak") == older_backup_hash, "Blocked migration leaves older backup intact")
	_test_v2()
	_test_v4()
	_test_v5()
	_finish()

func _test_v2() -> void:
	var model := MODEL.new(values)
	model.tick(1)
	var v2 := model.snapshot()
	v2.version = 2
	v2.plots.resize(96)
	for key in ["pond", "ranch", "layout_version", "ground_products"]: v2.erase(key)
	for fish in v2.fish:
		var normalized: Vector2 = preload("res://scripts/world_layout.gd").fish_from_world(Vector2(fish.x, fish.y))
		fish.x = normalized.x; fish.y = normalized.y
		for key in ["previous_x", "previous_y", "target", "heading", "phase", "swim_index"]: fish.erase(key)
	v2.rng.erase("animal")
	v2.settings.erase("display_mode")
	for grass in v2.grass:
		for key in ["x", "y", "appearance"]: grass.erase(key)
	for animal in v2.animals:
		for key in ["shelter_id", "x", "y", "previous_x", "previous_y", "facing", "behavior", "path", "target", "decision_remaining", "food_decision_remaining", "meal", "eating_remaining", "held_by", "hold_remaining", "feedback_remaining", "last_reward_elapsed", "juvenile_bonus_used", "adult_bonus_used", "production_cycle", "last_drop_cycle"]: animal.erase(key)
	v2.animals[0].food_remaining = 123.0
	v2.animals[0].hungry = false
	v2.animals[0].adult = true
	v2.animals[0].adult_remaining = 0.0
	v2.animals[0].ready = 1
	v2.animals[0].product_remaining = 0.0
	var layout = preload("res://scripts/world_layout.gd")
	for farmer in v2.farmers:
		for key in ["path", "facing", "task_elapsed", "track_remaining"]: farmer.erase(key)
		var origin: Vector2 = layout.legacy_farmer_idle_position(str(farmer.scene), 0)
		var destination := origin
		if str(farmer.mode) == "working":
			destination = layout.legacy_target_position(str(farmer.scene), str(farmer.task.target), v2)
			farmer.phase = "walking"
			origin = origin.lerp(destination, 0.5)
			farmer.remaining = origin.distance_to(destination) / float(v2.settings.farmer_speed)
		farmer.x = origin.x
		farmer.y = origin.y
		farmer.path_target_x = destination.x
		farmer.path_target_y = destination.y
	v2.pending_fish = v2.fish.pop_front()
	v2.net_remaining = 7.5
	v2.fish_remaining = 141.0
	var path := directory.path_join("real-v2.json")
	_write(path, v2)
	var original_hash := FileAccess.get_sha256(path)
	var store := STORE.new(path, values)
	var loaded := store.load_save()
	check(loaded.ok and loaded.get("migrated", false), "Strict real v2 state migrates to v3")
	if not loaded.ok:
		printerr(loaded.message)
		return
	check(loaded.data.version == MODEL.SAVE_VERSION and loaded.data.pond.net_level == 0 and loaded.data.pond.capacity_level == 0, "New upgrade fields begin at zero without fish gifts")
	check(loaded.data.animals[0].food_remaining == 123 and loaded.data.animals[0].ready == 0 and loaded.data.animals[0].product_remaining == 300 and loaded.data.ground_products[0].quantity == 1, "Animal meal interval is preserved while old ready product drops and starts next cycle")
	var same_seeds: bool = loaded.data.seeds.size() == v2.seeds.size()
	for id in v2.seeds: same_seeds = same_seeds and int(loaded.data.seeds.get(id, -1)) == int(v2.seeds[id])
	var paid: Dictionary = loaded.data.farmers[0].task
	var previous: Dictionary = v2.farmers[0].task
	check(same_seeds and int(loaded.data.coins) == int(v2.coins) and paid.action == previous.action and paid.target == previous.target and paid.crop_id == previous.crop_id and paid.seed_source == previous.seed_source, "Walking prepaid task keeps inventory, cash, target and seed source")
	check(not loaded.data.farmers[0].path.is_empty() and loaded.data.farmers[0].phase == "walking", "Old route is rebuilt in the new world instead of instantly completing")
	check(loaded.data.pending_fish == v2.pending_fish and loaded.data.net_remaining == 7.5 and loaded.data.fish_remaining == 141 and loaded.data.catalog == v2.catalog, "Migration retains legacy pending fish without side-effect settlement")
	check(FileAccess.get_sha256(loaded.migration_backup) == original_hash and str(loaded.migration_backup).contains("version-v2-"), "Immutable v2 backup contains exact pre-upgrade bytes")
	var copy := MODEL.new(values)
	check(copy.restore(loaded.data).ok and copy.state.pending_fish == v2.pending_fish and copy.balance() == int(v2.coins), "Restore does not secretly settle a pending fish")
	var before := copy.snapshot()
	check(copy.command("resolve_pending_fish").ok and copy.state.pending_fish.is_empty(), "Controller can explicitly settle the preserved legacy fish")
	check(copy.restore(before).ok and copy.state.pending_fish == v2.pending_fish, "Failed-save rollback restores the legacy fish, catalog and money")
	copy.command("resolve_pending_fish")
	check(store.save(copy.snapshot()).ok and store.load_save().data.pending_fish.is_empty(), "Successful compatibility settlement is durable")
	check(not copy.command("resolve_pending_fish").ok and FileAccess.get_sha256(loaded.migration_backup) == original_hash, "Legacy fish never pays twice and ordinary saves preserve version backup")
	for field in ["y", "seed", "timer"]:
		var invalid := v2.duplicate(true)
		match field:
			"y": invalid.farmers[0].y = 300.0
			"seed": invalid.seeds.parsnip = 0.5
			"timer": invalid.animals[0].food_remaining = -1
		check(not MODEL.new(values).migrate_v2(invalid).ok, "Strict v2 migration rejects corrupt legacy " + field)

func _v4_fixture() -> Dictionary:
	var game := MODEL.new(values)
	game.state.farmers = []
	game.state.elapsed = 50.0
	game.state.coins = 4321
	game._tick_fraction = 0.13
	game.state.settings.window_position = [80, 120]
	game.state.plots[5].pending_crop_id = "cauliflower"
	game.state.seeds.cauliflower = 2
	game.state.seed_reservations = [{"plot_id": "plot_0_5", "crop_id": "cauliflower", "quantity": 1, "purpose": "pending_next"}]
	game._add_farmer("farm")
	game._add_farmer("farm")
	var walking: Dictionary = game.state.farmers[0]
	var sow := {"action": "sow", "target": "plot_0_0"}
	check(game._reserve_task(sow), "v4 fixture prepays its physical sow seed once")
	walking.task = sow; walking.mode = "working"; walking.phase = "walking"
	var origin: Vector2 = V4.farmer_idle_position("farm", 0)
	var target: Vector2 = V4.target_position("farm", str(sow.target), game.state)
	walking.x = origin.x; walking.y = origin.y
	walking.path_target_x = target.x; walking.path_target_y = target.y
	walking.path = RANCH.pack_path(V4.find_path("farm", origin, target))
	walking.remaining = RANCH.path_length(origin, walking.path) / 32.0
	walking.task_elapsed = 17.3; walking.energy = 88.0
	var acting: Dictionary = game.state.farmers[1]
	game.state.plots[1].status = "unwatered"
	game.state.plots[1].remaining = float(game.crops.parsnip.first_seconds)
	game.state.plots[1].product = game._product_for_crop(game.crops.parsnip)
	acting.task = {"action": "water", "target": "plot_0_1"}
	acting.mode = "working"; acting.phase = "acting"; acting.remaining = 0.6
	target = V4.target_position("farm", str(acting.task.target), game.state)
	acting.x = target.x; acting.y = target.y
	acting.path_target_x = target.x; acting.path_target_y = target.y
	acting.path = []; acting.task_elapsed = 9.4; acting.energy = 91.0
	var animal: Dictionary = game.state.animals[0]
	animal.adult = true; animal.adult_remaining = 0.0; animal.food_remaining = 123.5
	animal.product_remaining = 0.0
	var pile: Dictionary = PRODUCTS.complete_cycle(game.state, animal, game.animal_types[str(animal.type_id)], values.products)
	animal.product_remaining = 0.0
	PRODUCTS.complete_cycle(game.state, animal, game.animal_types[str(animal.type_id)], values.products)
	game._add_farmer("ranch")
	var collector: Dictionary = game.state.farmers[2]
	var pickup := {"action": "collect_product", "target": str(pile.id)}
	check(PRODUCTS.reserve(game.state, pickup, str(collector.id)), "v4 fixture owns exactly one ground unit")
	collector.task = pickup; collector.mode = "working"; collector.phase = "acting"
	collector.remaining = 0.8; collector.task_elapsed = 127.3
	collector.x = pile.x; collector.y = pile.y
	collector.path_target_x = pile.x; collector.path_target_y = pile.y
	collector.path = []
	game._add_farmer("pond")
	game.state.net_remaining = 6.75; game.state.fish_remaining = 117.25
	var result := game.snapshot()
	result.version = 4; result.layout_version = 4
	result.plots.resize(96)
	result.pond.erase("net_area_level")
	return result

func _test_v4() -> void:
	var old := _v4_fixture()
	var original := JSON.stringify(old, "", true, true)
	var checker := MODEL.new(values)
	check(checker._validate_v4(old).ok, "Frozen v4 strictly validates the original active fixture")
	var result := checker.migrate_v4(old)
	check(result.ok, "Strict v4 farm routes migrate to the current layout: " + str(result.message))
	if not result.ok: return
	var current: Dictionary = result.data
	check(current.version == MODEL.SAVE_VERSION and current.layout_version == MODEL.LAYOUT_VERSION, "Version markers advance through frozen SAVE5/Layout5 to SAVE6/Layout6")
	check(JSON.stringify(old, "", true, true) == original, "In-memory v4 migration does not mutate its source")
	for key in ["coins", "elapsed", "tick_fraction", "next_id", "transaction_id", "paid_hires", "seeds", "seed_reservations", "default_seed_id", "previous_default_seed_id", "unlocked_crops", "catalog", "rng", "settings", "ranch", "shelters", "storage_level", "warehouse_hay", "trough_hay", "grass_seeds", "grass_remaining", "fish_remaining", "net_remaining", "pending_fish", "animals", "grass", "fish", "ground_products"]:
		check(current[key] == old[key], "v4 migration preserves existing resource/production state: " + key)
	check(current.pond.net_level == old.pond.net_level and current.pond.capacity_level == old.pond.capacity_level and current.pond.net_area_level == 0, "Existing pond upgrades are preserved and the new net-area track begins at zero")
	for index in range(96):
		check(current.plots[index] == old.plots[index], "v4 stable ID, crop state, timers and pending plans remain exact at index %d" % index)
	checker.state = old.duplicate(true)
	var old_budget := checker.protection()
	check(checker.restore(current).ok and checker.protection() == old_budget, "Seed protection budget is identical before and after farm migration")
	var walking: Dictionary = current.farmers[0]
	var old_walking: Dictionary = old.farmers[0]
	var destination: Vector2 = WORLD.target_position("farm", str(walking.task.target), current)
	check(RANCH.point(walking) == RANCH.point(old_walking) and walking.task == old_walking.task and walking.phase == "walking", "Walking farmer retains its still-walkable old foot position and prepaid task")
	check(Vector2(walking.path_target_x, walking.path_target_y) == destination and RANCH.point(walking.path[-1]) == destination, "Walking path reaches the new stable plot-ID target")
	check(is_equal_approx(float(walking.remaining), RANCH.path_length(RANCH.point(walking), walking.path) / float(current.settings.farmer_speed)), "Walking remaining seconds reflect the new safe route length")
	check(walking.task_elapsed == old_walking.task_elapsed and walking.energy == old_walking.energy, "Rerouting retains elapsed work and stamina without another seed reservation")
	var acting: Dictionary = current.farmers[1]
	destination = WORLD.target_position("farm", str(acting.task.target), current)
	check(RANCH.point(acting) == destination and acting.path.is_empty() and acting.phase == "acting", "An acting farm worker anchors to its relocated plot")
	check(acting.remaining == old.farmers[1].remaining and acting.task_elapsed == old.farmers[1].task_elapsed and acting.task == old.farmers[1].task and acting.energy == old.farmers[1].energy, "Acting retains the exact remaining 0.6 seconds, task resources and stamina")
	for index in [2, 3]:
		check(current.farmers[index] == old.farmers[index], "Ranch pickup and pond farmer retain all position/task/remaining fields: %d" % index)
	var replay := MODEL.new(values)
	check(replay.restore(current).ok, "Migrated v4 current snapshot restores")
	checker.tick(0.6); replay.tick(0.6)
	check(JSON.stringify(checker.snapshot(), "", true, true) == JSON.stringify(replay.snapshot(), "", true, true), "Migrated action and fish motion replay exactly after reload")
	# The saved tick fraction contributes 0.13 seconds; 0.6 input performs
	# three model steps, completing water but not the 0.8-second pickup.
	check(checker.state.plots[1].status == "growing" and checker.state.ground_products[0].quantity == 2, "Water completes its residual work without instantly settling the separate ranch claim")
	var coins_before := checker.balance()
	checker.tick(0.2)
	check(checker.state.ground_products[0].quantity == 1 and checker.balance() == coins_before + int(old.ground_products[0].batches[0].sell_price), "Existing ranch claim completes once at its retained 0.8 seconds")
	var path := directory.path_join("real-v4.json")
	_write(path, old)
	var source_hash := FileAccess.get_sha256(path)
	var store := STORE.new(path, values)
	var loaded := store.load_save()
	check(loaded.ok and loaded.get("migrated", false), "Store atomically upgrades a real v4 file")
	if not loaded.ok: return
	var migration_backup: String = loaded.migration_backup
	check(str(migration_backup).contains("version-v4-") and FileAccess.get_sha256(migration_backup) == source_hash and FileAccess.get_sha256(path + ".bak") == source_hash, "v4 immutable migration backup and initial normal backup contain the exact original bytes")
	check(store.load_save().ok and not store.load_save().get("migrated", false), "Repeated v5 startup performs no second v4 migration")
	check(store.save(loaded.data).ok and FileAccess.get_sha256(migration_backup) == source_hash, "Later saves cannot overwrite the original v4 versioned backup")
	for field in ["segment", "endpoint", "plot_binding", "layout", "remaining"]:
		var invalid := old.duplicate(true)
		match field:
			"segment": invalid.farmers[0].path.push_front({"x": 160.0, "y": 40.0})
			"endpoint": invalid.farmers[0].path.pop_back()
			"plot_binding": invalid.farmers[0].path_target_x += 50
			"layout": invalid.layout_version = 5
			"remaining": invalid.farmers[1].remaining = -0.1
		check(not MODEL.new(values).migrate_v4(invalid).ok, "Strict old v4 validation rejects corruption before rerouting: " + field)
	var failed_path := directory.path_join("blocked-v4.json")
	_write(failed_path, old)
	var failed_hash := FileAccess.get_sha256(failed_path)
	DirAccess.make_dir_recursive_absolute(failed_path + ".tmp")
	var blocked := STORE.new(failed_path, values).load_save()
	check(not blocked.ok and blocked.get("migration_write_failed", false) and FileAccess.get_sha256(failed_path) == failed_hash, "Blocked v4 atomic replace preserves original main bytes")
	DirAccess.remove_absolute(failed_path + ".tmp")
	check(STORE.new(failed_path, values).load_save().ok, "A blocked v4 migration safely retries after its write failure clears")
	var future := current.duplicate(true)
	future.version = MODEL.SAVE_VERSION + 1
	var future_path := directory.path_join("future-after-v5.json")
	_write(future_path, future); _write(future_path + ".bak", old)
	var future_hash := FileAccess.get_sha256(future_path)
	var future_store := STORE.new(future_path, values)
	check(not future_store.load_save().ok and not future_store.save(current).ok and FileAccess.get_sha256(future_path) == future_hash, "Future version is never overwritten or replaced by a migrated v4 backup")

func _test_v5() -> void:
	# Captured from the v0.8.3 migration test before SAVE6 existed. This real
	# old-schema file includes a prepaid walk, partial water and a claimed pile.
	var fixture := "res://tests/fixtures/save-v5-active.json"
	check(FileAccess.get_sha256(fixture) == "d7a3b71a4094e88f4cd64f8bd5a77fb77d4eca721965f6a51374f6a7955b5b3c", "Frozen v0.8.3 fixture retains its exact recorded bytes")
	var old: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(fixture))
	var original := JSON.stringify(old, "", true, true)
	var checker := MODEL.new(values)
	check(checker._validate_v5(old).ok, "Real active v5 fixture validates with frozen World5")
	checker.state = old.duplicate(true)
	var old_budget := checker.protection()
	var result := checker.migrate_v5(old)
	check(result.ok, "Active v5 save adds the four locked plots: " + str(result.message))
	if not result.ok: return
	var current: Dictionary = result.data
	check(JSON.stringify(old, "", true, true) == original, "v5 append migration never mutates its source")
	check(current.version == 6 and current.layout_version == 6 and current.plots.size() == 100, "v5 migrates to SAVE6/Layout6 with exactly 100 entities")
	for key in old:
		if key in ["version", "layout_version", "plots", "pond"]: continue
		check(current[key] == old[key], "Appending plots retains every old top-level value: " + str(key))
	for index in range(96):
		check(current.plots[index] == old.plots[index] and WORLD.plot_position(index) == V5.plot_position(index), "Original plot state, identity and coordinates exact at %d" % index)
	for index in range(96, 100):
		var plot: Dictionary = current.plots[index]
		check(plot.id == "plot_6_%d" % (index - 96) and plot.index == index and not plot.open and plot.status == "empty" and plot.remaining == 0 and plot.product.is_empty() and not plot.return_seed and plot.pending_crop_id.is_empty(), "Only appended locked empty plot %d is introduced" % index)
	check(current.pond.net_level == old.pond.net_level and current.pond.capacity_level == old.pond.capacity_level and current.pond.net_area_level == 0, "Net area starts at zero while old cooldown/capacity levels remain exact")
	check(checker.restore(current).ok and checker.protection() == old_budget, "Four locked plots add no seeds, money or protected budget")
	for index in range(old.farmers.size()):
		check(checker.state.farmers[index] == old.farmers[index], "Each v5 actor retains exact route, remaining work, paid resources and ground claim: %d" % index)
	var replay := MODEL.new(values)
	check(replay.restore(current).ok, "Appended schema reloads with active tasks")
	checker.tick(1.0); replay.tick(1.0)
	check(checker.snapshot() == replay.snapshot(), "Active v5 water/pickup and fish movement replay deterministically after migration")
	var path := directory.path_join("real-v5.json")
	check(DirAccess.copy_absolute(ProjectSettings.globalize_path(fixture), path) == OK, "Real v5 bytes copied into an isolated test store")
	var source_hash := FileAccess.get_sha256(path)
	var store := STORE.new(path, values)
	var loaded := store.load_save()
	check(loaded.ok and loaded.get("migrated", false), "Store upgrades an actual v5 file atomically")
	if not loaded.ok: return
	var backup: String = loaded.migration_backup
	check(backup.contains("version-v5-") and FileAccess.get_sha256(backup) == source_hash and FileAccess.get_sha256(path + ".bak") == source_hash, "Both v5 backups preserve exact pre-upgrade bytes")
	check(store.load_save().ok and not store.load_save().get("migrated", false), "Second SAVE6 startup does not append four more plots")
	check(store.save(current).ok and FileAccess.get_sha256(backup) == source_hash, "Ordinary save cannot overwrite the immutable v5 migration backup")
	for field in ["count", "identity", "binding", "endpoint", "layout", "remaining"]:
		var invalid := old.duplicate(true)
		match field:
			"count": invalid.plots.append(current.plots[96])
			"identity": invalid.plots[95].id = "plot_6_0"
			"binding": invalid.farmers[0].task.target = "plot_6_0"
			"endpoint": invalid.farmers[0].path.pop_back()
			"layout": invalid.layout_version = 6
			"remaining": invalid.farmers[1].remaining = -0.1
		check(not MODEL.new(values).migrate_v5(invalid).ok, "Frozen v5 validation rejects bad data before additions: " + field)
	for field in ["missing_area", "fractional_area", "negative_area", "future_area", "last_index", "last_identity", "last_timer"]:
		var invalid := current.duplicate(true)
		match field:
			"missing_area": invalid.pond.erase("net_area_level")
			"fractional_area": invalid.pond.net_area_level = 0.5
			"negative_area": invalid.pond.net_area_level = -1
			"future_area": invalid.pond.net_area_level = 4
			"last_index": invalid.plots[99].index = 98
			"last_identity": invalid.plots[99].id = "plot_6_2"
			"last_timer": invalid.plots[99].remaining = -1
		check(not MODEL.new(values).restore(invalid).ok, "SAVE6 checks all appended fields and area level: " + field)
	# Appended IDs are full entities: seed bindings and paid actions survive a
	# reload, and none of the final four can bypass normal seed protection.
	var appended := MODEL.new(values)
	appended.state.coins = 1000000
	for index in range(76): check(appended.command("expand_plot").ok, "100-plot fixture expands atomically %d" % index)
	appended.state.farmers = []
	for index in range(96, 100):
		check(appended.command("set_crop", {"plot_ids": [str(appended.state.plots[index].id)], "crop_id": "cauliflower"}).ok, "New plot participates in normal pending seed/budget plan %d" % index)
	appended._add_farmer("farm")
	var farmer: Dictionary = appended.state.farmers[0]
	var paid := {"action": "sow", "target": "plot_6_3"}
	check(appended._reserve_task(paid, str(farmer.id)), "Final appended ID claims a single paid sow seed")
	farmer.task = paid; farmer.mode = "working"
	check(appended._set_farmer_path(farmer, WORLD.target_position("farm", "plot_6_3", appended.state)), "Final appended ID binds to its actual added soil position")
	var saved := appended.snapshot()
	var resumed := MODEL.new(values)
	check(resumed.restore(saved).ok and resumed.protection() == appended.protection() and resumed.state.farmers[0] == farmer, "100-plot seed reservations and active last-ID task roundtrip without another charge")
	appended.tick(60); resumed.tick(60)
	check(appended.snapshot() == resumed.snapshot(), "All 100 plot bindings replay identically after a mid-walk reload")
	var blocked_path := directory.path_join("blocked-v5.json")
	_write(blocked_path, old)
	var blocked_hash := FileAccess.get_sha256(blocked_path)
	DirAccess.make_dir_recursive_absolute(blocked_path + ".tmp")
	var blocked := STORE.new(blocked_path, values).load_save()
	check(not blocked.ok and blocked.get("migration_write_failed", false) and FileAccess.get_sha256(blocked_path) == blocked_hash, "Blocked v5 atomic replace preserves the original main file")
	DirAccess.remove_absolute(blocked_path + ".tmp")
	check(STORE.new(blocked_path, values).load_save().ok, "v5 migration retries after an unavailable write clears")
	var future := current.duplicate(true)
	future.version = 7
	var future_path := directory.path_join("future-after-v6.json")
	_write(future_path, future); _write(future_path + ".bak", old)
	var future_hash := FileAccess.get_sha256(future_path)
	check(not STORE.new(future_path, values).load_save().ok and not STORE.new(future_path, values).save(current).ok and FileAccess.get_sha256(future_path) == future_hash, "Future save remains untouched despite an older valid v5 backup")

func _write(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data, "", true, true))
	file.close()

func _finish() -> void:
	if failures.is_empty():
		print("SAVE_MIGRATION_PASS: %d assertions" % assertions)
		quit(0)
	else:
		for message in failures: printerr("FAIL: " + message)
		quit(1)
