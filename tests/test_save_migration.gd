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
	check(initial_model.restore(loaded.data).ok, "Migrated startup passes strict v2 validation")
	check(loaded.data.version == 2 and not loaded.data.has("regions"), "Migration removes region state")
	check(initial_model.balance() == 1000 and initial_model.protection() == 480, "Initial coins and seed protection preserved")
	check(loaded.data.plots.filter(func(p): return p.open).size() == 24, "Original open count preserved")
	check(FileAccess.get_sha256(initial_path + ".bak") == FileAccess.get_sha256(loaded.migration_backup), "Original v1 and versioned backup retain exact bytes")
	var original_backup: String = loaded.migration_backup
	var original_hash := FileAccess.get_sha256(original_backup)
	var repeated: Dictionary = initial_store.load_save()
	check(repeated.ok and not repeated.get("migrated", false), "Second startup does not migrate v2 again")
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
	check(JSON.stringify(resumed.state.rng) == JSON.stringify(old.rng), "Migration preserves all independent random streams")
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
	_finish()

func _write(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()

func _finish() -> void:
	if failures.is_empty():
		print("SAVE_MIGRATION_PASS: %d assertions" % assertions)
		quit(0)
	else:
		for message in failures: printerr("FAIL: " + message)
		quit(1)
