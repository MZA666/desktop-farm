extends SceneTree

const MODEL = preload("res://scripts/game_state.gd")
const STORE = preload("res://scripts/save_store.gd")
const CONFIG = preload("res://scripts/config_loader.gd")
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
	check(initial_model.restore(loaded.data).ok, "Migrated startup passes strict v3 validation")
	check(loaded.data.version == 4 and loaded.data.layout_version == 4 and not loaded.data.has("regions"), "Migration removes region state and initializes current world")
	check(initial_model.balance() == 1000 and initial_model.protection() == 480, "Initial coins and seed protection preserved")
	check(loaded.data.plots.filter(func(p): return p.open).size() == 24, "Original open count preserved")
	check(FileAccess.get_sha256(initial_path + ".bak") == FileAccess.get_sha256(loaded.migration_backup), "Original v1 and versioned backup retain exact bytes")
	var original_backup: String = loaded.migration_backup
	var original_hash := FileAccess.get_sha256(original_backup)
	var repeated: Dictionary = initial_store.load_save()
	check(repeated.ok and not repeated.get("migrated", false), "Second startup does not migrate v3 again")
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
	_finish()

func _test_v2() -> void:
	var model := MODEL.new(values)
	model.tick(1)
	var v2 := model.snapshot()
	v2.version = 2
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
	check(loaded.data.version == 4 and loaded.data.pond.net_level == 0 and loaded.data.pond.capacity_level == 0, "New upgrade fields begin at zero without fish gifts")
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
