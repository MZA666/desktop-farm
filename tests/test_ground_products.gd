extends SceneTree

const MODEL = preload("res://scripts/game_state.gd")
const PRODUCTS = preload("res://scripts/ground_products.gd")
const WORLD = preload("res://scripts/world_layout.gd")
const CONFIG = preload("res://scripts/config_loader.gd")
const STORE = preload("res://scripts/save_store.gd")
var values: Dictionary
var failures: Array[String] = []
var assertions := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok: failures.append(message)

func fresh() -> FarmState:
	var game := MODEL.new(values)
	game.state.animals = []
	game.state.farmers = []
	game.state.trough_hay = 0
	for grass in game.state.grass: grass.clumps = 1 if grass.open else 0
	return game

func adult(game: FarmState, id := "chicken") -> Dictionary:
	game.state.shelters[str(game.animal_types[id].shelter_id)] = 3
	game._add_animal(id)
	var animal: Dictionary = game.state.animals[-1]
	animal.adult = true; animal.adult_remaining = 0.0
	animal.food_remaining = 100000.0; animal.hungry = false
	animal.x = 688.0; animal.y = 336.0
	animal.previous_x = animal.x; animal.previous_y = animal.y
	animal.decision_remaining = 100000.0; animal.food_decision_remaining = 100000.0
	return animal

func drop(game: FarmState, animal: Dictionary) -> Dictionary:
	animal.product_remaining = 0.0
	return PRODUCTS.complete_cycle(game.state, animal, game.animal_types[str(animal.type_id)], values.products)

func worker(game: FarmState, pile: Dictionary) -> Dictionary:
	game._add_farmer("ranch")
	var farmer: Dictionary = game.state.farmers[-1]
	farmer.x = pile.x; farmer.y = pile.y
	farmer.path_target_x = pile.x; farmer.path_target_y = pile.y
	return farmer

func total(game: FarmState) -> int:
	var amount := 0
	for pile in game.state.ground_products: amount += int(pile.quantity)
	return amount

func _run() -> void:
	values = CONFIG.load_values()
	_test_cycles()
	_test_claims_and_sources()
	_test_worker_sale_reload()
	_test_v3_migration()
	_test_v3_task_geometry()
	_test_v3_batch_binding()
	_test_validation_and_save()
	if failures.is_empty():
		print("GROUND_PRODUCTS_PASS: %d cycle/claim/conservation/migration assertions" % assertions)
		quit(0)
	else:
		for failure in failures: printerr("FAIL: " + failure)
		quit(1)

func _test_cycles() -> void:
	var game := fresh()
	var animal := adult(game)
	var cash := game.balance()
	animal.product_remaining = 0.2
	animal.adult_bonus_used = 30.0
	game.tick(0.2)
	check(total(game) == 1 and animal.production_cycle == 1 and animal.last_drop_cycle == 0, "Timer completes exactly one identified cycle")
	check(animal.product_remaining == 300 and animal.adult_bonus_used == 0 and animal.ready == 0, "Drop immediately starts full next cycle and restores its allowance")
	check(game.balance() == cash and game.state.catalog.is_empty(), "Drop neither grants money nor discovery")
	var pile: Dictionary = game.state.ground_products[0]
	var position := PRODUCTS.point(pile)
	check(WORLD.is_walkable("ranch", position), "Drop has a finite reachable fixed ground position")
	check(PRODUCTS.complete_cycle(game.state, animal, game.animal_types.chicken).is_empty() and total(game) == 1, "Repeated completion cannot duplicate the same cycle")
	game.tick(600)
	check(total(game) == 3 and animal.production_cycle == 3, "Uncollected produce permits successive cycles and accumulating stock")
	check(PRODUCTS.point(pile) == position and pile.batches.size() == 1, "Same drop site accumulates counts in a fixed pile and source batch")
	animal.food_remaining = 0; animal.hungry = true
	var remaining := float(animal.product_remaining)
	game.tick(10)
	check(total(game) == 3 and animal.product_remaining == remaining, "Hunger pauses current production and preserves previous drops")
	animal.food_remaining = 1000; animal.hungry = false
	animal.product_remaining = 10.0
	game.state.elapsed = 1000
	var result := game.command("interact_animal", {"instance_id": animal.id})
	check(result.ok and result.reward_seconds == 10 and total(game) == 4 and animal.production_cycle == 4 and animal.adult_bonus_used == 0, "Interaction uses the same completion and allows stock to remain")
	check(animal.last_reward_elapsed == 1000 and game.state.ranch.global_reward_elapsed == 1000, "Drop retains individual and global interaction cooldowns")
	check(game.command("interact_animal", {"instance_id": animal.id}).reward_seconds == 0 and total(game) == 4, "Immediate repeated click cannot create another drop")
	game.tick(0.2)
	check(total(game) == 4, "The following timer tick cannot duplicate an interaction-completed cycle")
	for kind in values.animals:
		var all := fresh()
		var species := adult(all, str(kind.id))
		species.product_remaining = 0.2
		all.tick(0.2)
		check(total(all) == 1 and all.state.ground_products[0].product_id == kind.product_id and all.state.ground_products[0].batches[0].sell_price == kind.sell_price, "Correct source and product for " + str(kind.id))

func _test_claims_and_sources() -> void:
	var game := fresh()
	var rabbit := adult(game, "rabbit")
	var sheep := adult(game, "sheep")
	var pile := drop(game, rabbit)
	drop(game, sheep)
	check(game.state.ground_products.size() == 1 and pile.quantity == 2 and pile.batches.size() == 2, "Shared wool forms one pile while retaining rabbit and sheep batches")
	var one := worker(game, pile)
	var two := worker(game, pile)
	var first := {"action": "collect_product", "target": pile.id}
	var second := first.duplicate(true)
	check(game._reserve_task(first, str(one.id)) and game._reserve_task(second, str(two.id)), "Two workers reserve different portions of the same pile")
	check(first.claim_id != second.claim_id and first.batch_id != second.batch_id and pile.quantity == 2, "Unique claims do not reduce stock or merge source provenance")
	var third := {"action": "collect_product", "target": pile.id}
	check(not game._reserve_task(third, "farmer_unused"), "A fully claimed pile cannot be claimed again")
	var cash := game.balance()
	check(game._commit_task(second) and game._commit_task(first), "Different claimed portions settle independently")
	check(total(game) == 0 and game.balance() == cash + int(game.animal_types.rabbit.sell_price) + int(game.animal_types.sheep.sell_price), "Picking conserves stock and exact batch prices")
	check(game.state.catalog.wool.count == 2 and game.state.catalog.wool.sources.has("rabbit") and game.state.catalog.wool.sources.has("sheep"), "Shared product catalog preserves both source types")
	check(not game._commit_task(first) and not game._commit_task(second) and game.balance() == cash + 680, "Replayed pickup tokens cannot settle twice")
	var renewed := drop(game, rabbit)
	var cancel := {"action": "collect_product", "target": renewed.id}
	check(game._reserve_task(cancel, str(one.id)), "A new cycle can be independently claimed")
	one.task = cancel
	one.mode = "working"; one.phase = "acting"
	game._cancel_task(one)
	check(renewed.quantity == 1 and renewed.claims.is_empty() and game.balance() == cash + 680, "Cancellation releases one claim and retains all physical stock")

func _test_worker_sale_reload() -> void:
	var game := fresh()
	var animal := adult(game)
	var pile := drop(game, animal)
	drop(game, animal)
	var farmer := worker(game, pile)
	var next := worker(game, pile)
	game._dispatch(farmer); game._dispatch(next)
	check(pile.quantity == 2 and pile.claims.size() == 2 and farmer.remaining == 2 and next.remaining == 2, "Dispatch claims separate units and starts exactly two-second pickup")
	var before := game.snapshot()
	var cash := game.balance()
	check(game.command("sell_animal", {"instance_id": animal.id}).ok and game.balance() == cash + 400, "Animal sale grants only its standard half-price refund")
	check(pile.quantity == 2 and pile.claims.size() == 2 and farmer.task.action == "collect_product", "Selling the source preserves the drops and ongoing pickup tasks")
	var copy := MODEL.new(values)
	check(copy.restore(game.snapshot()).ok and total(copy) == 2, "Claims with a sold source are valid save state")
	game.tick(1.8); copy.tick(1.8)
	check(total(game) == 2 and game.balance() == cash + 400 and farmer.energy == 100, "No quantity, payout or energy charge before the action boundary")
	game.tick(0.2); copy.tick(0.2)
	check(total(game) == 0 and game.balance() == cash + 500 and farmer.energy == 99 and next.energy == 99, "Simultaneous workers each pick exactly one unit and use one energy")
	check(JSON.stringify(game.snapshot()) == JSON.stringify(copy.snapshot()), "Reloaded two-worker actions finish identically")
	check(game.restore(before).ok and total(game) == 2 and game.balance() == cash, "Atomic controller rollback restores drops, claims, source and currency together")
	var duplicate := game.snapshot()
	duplicate.farmers[1].task = duplicate.farmers[0].task.duplicate(true)
	check(game.restore(duplicate).ok and total(game) == 2 and game.state.ground_products[0].claims.size() == 1, "Reload releases duplicate/stale claims without deleting their product")
	check(game.state.farmers[1].task.is_empty(), "A copied task cannot retain another worker's claim")

func _v3(game: FarmState) -> Dictionary:
	var data := game.snapshot()
	data.version = 3
	data.erase("layout_version"); data.erase("ground_products")
	for animal in data.animals: animal.erase("last_drop_cycle")
	for fish in data.fish:
		var normalized: Vector2 = WORLD.fish_from_world(Vector2(float(fish.x), float(fish.y)))
		fish.x = normalized.x; fish.y = normalized.y
		for key in ["previous_x", "previous_y", "target", "heading", "phase", "swim_index"]: fish.erase(key)
	return data

func _test_v3_migration() -> void:
	var game := fresh()
	var animal := adult(game)
	var farmer: Dictionary
	game._add_farmer("ranch"); farmer = game.state.farmers[-1]
	var old := _v3(game)
	old.elapsed = 900.0
	old.animals[0].ready = 1; old.animals[0].product_remaining = 0.0
	old.animals[0].queued_at = 731.0; old.animals[0].production_cycle = 5; old.animals[0].adult_bonus_used = 30.0
	old.animals[0].last_reward_elapsed = 800.0
	old.animals[0].held_by = farmer.id; old.animals[0].hold_remaining = 1.0; old.animals[0].behavior = "being_collected"
	old.farmers[0].task = {"action": "collect_product", "target": animal.id}
	old.farmers[0].mode = "working"; old.farmers[0].phase = "acting"; old.farmers[0].remaining = 1.4
	old.farmers[0].task_elapsed = 121.3
	old.farmers[0].x = animal.x; old.farmers[0].y = animal.y
	old.farmers[0].path_target_x = animal.x; old.farmers[0].path_target_y = animal.y
	old.fish[0].x = 0.05; old.fish[0].y = 0.2
	old.net_remaining = 12.6; old.fish_remaining = 123.0
	var original := JSON.stringify(old)
	var result := game.migrate_v3(old)
	check(result.ok, "Ready v3 animal and active collection migrate safely: " + str(result.message))
	if not result.ok: return
	var migrated: Dictionary = result.data
	check(migrated.version == MODEL.SAVE_VERSION and migrated.layout_version == MODEL.LAYOUT_VERSION and migrated.ground_products.size() == 1 and migrated.ground_products[0].quantity == 1, "One v3 ready unit becomes exactly one independent drop across the complete upgrade chain")
	check(migrated.ground_products[0].queued_at == 731 and migrated.animals[0].production_cycle == 6 and migrated.animals[0].product_remaining == 300 and migrated.animals[0].adult_bonus_used == 0, "Migration retains queue age and starts the next full cycle")
	check(migrated.animals[0].last_reward_elapsed == 800 and migrated.animals[0].held_by.is_empty(), "Migration clears collection freeze while preserving interaction cooldown")
	check(migrated.farmers[0].remaining == 1.4 and migrated.farmers[0].task_elapsed == 121.3 and migrated.farmers[0].task.target == migrated.ground_products[0].id and migrated.ground_products[0].claims.size() == 1, "Acting task retains action time and its older elapsed progress without a chasing timeout")
	check(migrated.coins == old.coins and migrated.catalog == old.catalog and migrated.rng == old.rng, "Migration adds no income/discovery or random consumption")
	check(migrated.fish.size() == old.fish.size() and migrated.net_remaining == 12.6 and migrated.fish_remaining == 123 and WORLD.fish_position_safe(Vector2(migrated.fish[0].x, migrated.fish[0].y)), "Unsafe old fish moves to water while IDs, count and timers remain")
	check(JSON.stringify(old) == original and JSON.stringify(game.migrate_v3(old).data) == JSON.stringify(migrated), "Migration is deterministic, retryable and does not mutate input")
	check(game.restore(migrated).ok and total(game) == 1, "New schema reload does not repeat legacy conversion")
	game.tick(1.2)
	check(total(game) == 1, "Converted action does not finish early")
	game.tick(0.2)
	check(total(game) == 0 and game.balance() == int(old.coins) + 50 and game.state.animals[0].production_cycle == 6, "Converted action older than 120 seconds settles once without restarting or resetting the animal cycle")
	var path := ProjectSettings.globalize_path("res://.review/v3-ground-" + str(Time.get_ticks_usec()) + ".json")
	_write(path, old)
	var hash := FileAccess.get_sha256(path)
	var store := STORE.new(path, values)
	var loaded := store.load_save()
	check(loaded.ok and loaded.get("migrated", false) and FileAccess.get_sha256(loaded.get("migration_backup", "")) == hash, "v3 file upgrades atomically with an exact immutable original backup")
	check(store.load_save().ok and not store.load_save().get("migrated", false) and store.load_save().data.ground_products[0].quantity == 1, "Repeated startup does not duplicate drops or overwrite version backup")

func _test_validation_and_save() -> void:
	var game := fresh()
	var animal := adult(game)
	drop(game, animal)
	for field in ["quantity", "position", "price", "cycle", "batch", "future", "farmers", "farmer_object", "products", "batch_type", "claim_type"]:
		var bad := game.snapshot()
		match field:
			"quantity": bad.ground_products[0].quantity = 2
			"position": bad.ground_products[0].x = -1
			"price": bad.ground_products[0].batches[0].sell_price = -1
			"cycle": bad.animals[0].last_drop_cycle = 99
			"batch": bad.ground_products[0].batches[0].source_type = "unknown"
			"future": bad.version = MODEL.SAVE_VERSION + 1
			"farmers": bad.farmers = 7
			"farmer_object": bad.farmers = [7]
			"products": bad.ground_products = 7
			"batch_type": bad.ground_products[0].batches = [7]
			"claim_type": bad.ground_products[0].claims = [7]
		check(not MODEL.new(values).restore(bad).ok, "Validation rejects corrupt " + field)
	var copy := MODEL.new(values)
	check(copy.restore(game.snapshot()).ok, "Valid stock and safe fish state restore")
	var rng: Dictionary = game.state.rng.duplicate(true)
	for unused in range(50): game.tick(0.2)
	copy.tick(10)
	check(JSON.stringify(game.snapshot()) == JSON.stringify(copy.snapshot()) and game.state.rng == rng, "Persistent fish motion and production replay identically without consuming production RNG")
	for fish in game.state.fish:
		check(WORLD.fish_position_safe(Vector2(fish.x, fish.y)) and WORLD.fish_segment_safe(Vector2(fish.x, fish.y), Vector2(fish.target.x, fish.target.y)), "Every fish body and current path stays wholly inside safe water")
	var path := ProjectSettings.globalize_path("res://.review/v4-save-" + str(Time.get_ticks_usec()) + ".json")
	var store := STORE.new(path, values)
	check(store.save(game.snapshot()).ok, "v4 stock state saves")
	var hash := FileAccess.get_sha256(path)
	var bad := game.snapshot(); bad.ground_products[0].quantity += 1
	check(not store.save(bad).ok and FileAccess.get_sha256(path) == hash, "Invalid conservation is rejected before the current file changes")
	var future := game.snapshot(); future.version = MODEL.SAVE_VERSION + 1
	_write(path, future); _write(path + ".bak", game.snapshot())
	var future_hash := FileAccess.get_sha256(path)
	check(not store.load_save().ok and FileAccess.get_sha256(path) == future_hash, "Future schema is refused without falling back to an older backup")
	check(not store.save(game.snapshot()).ok and FileAccess.get_sha256(path) == future_hash, "Even an accidental current-version save cannot overwrite a future file")

func _test_v3_task_geometry() -> void:
	var game := fresh()
	game._add_farmer("farm")
	var farmer: Dictionary = game.state.farmers[0]
	var task := {"action": "sow", "target": "plot_0_0"}
	check(game._reserve_task(task), "Migration fixture reserves its seed once")
	farmer.task = task; farmer.mode = "working"; farmer.phase = "walking"
	var origin: Vector2 = WORLD.V3.farmer_idle_position("farm", 0)
	var old_target: Vector2 = WORLD.V3.target_position("farm", "plot_0_0", game.state)
	farmer.x = origin.x; farmer.y = origin.y
	farmer.path_target_x = old_target.x; farmer.path_target_y = old_target.y
	farmer.path = preload("res://scripts/ranch_life.gd").pack_path(WORLD.V3.find_path("farm", origin, old_target))
	farmer.remaining = preload("res://scripts/ranch_life.gd").path_length(origin, farmer.path) / 32.0
	var old := _v3(game)
	var migrated := game.migrate_v3(old)
	check(migrated.ok, "Walking prepaid v3 farm task migrates: " + str(migrated.message))
	if not migrated.ok: return
	var current: Dictionary = migrated.data.farmers[0]
	var new_target: Vector2 = WORLD.target_position("farm", "plot_0_0", migrated.data)
	check(current.task == old.farmers[0].task and migrated.data.seeds == old.seeds and migrated.data.coins == old.coins and migrated.data.rng == old.rng, "Farm rerouting preserves prepaid task, physical seeds, money and random state")
	check(Vector2(current.x, current.y) == origin and Vector2(current.path_target_x, current.path_target_y) == new_target and new_target != old_target and current.phase == "walking", "Walking farmer retains passable position and routes toward new plot ID target")
	check(WORLD.segment_walkable("farm", Vector2(current.path[-1].x, current.path[-1].y), new_target), "New route actually reaches the relocated work point")
	for index in range(96):
		check(migrated.data.plots[index] == old.plots[index], "All crop state and pending plans remain intact at stable index %d" % index)
	old.farmers[0].phase = "acting"; old.farmers[0].path = []; old.farmers[0].remaining = 0.6
	old.farmers[0].x = old_target.x; old.farmers[0].y = old_target.y
	migrated = game.migrate_v3(old)
	check(migrated.ok and migrated.data.farmers[0].remaining == 0.6 and Vector2(migrated.data.farmers[0].x, migrated.data.farmers[0].y) == new_target, "Acting farm task moves to the new work point while retaining its last 0.6 seconds")
	var ranch := fresh()
	var cow := adult(ranch, "cow")
	ranch.state.trough_hay = 2; ranch.state.warehouse_hay = 4
	check(ranch._meal(cow), "Migration fixture contains a real reserved meal route")
	ranch._add_farmer("ranch")
	var ranch_worker: Dictionary = ranch.state.farmers[0]
	var feeding := {"action": "add_hay", "target": "trough"}
	check(ranch._reserve_task(feeding), "Migration fixture contains a reserved hay transfer")
	ranch_worker.task = feeding; ranch_worker.mode = "working"; ranch_worker.phase = "acting"; ranch_worker.remaining = 1.1
	var trough: Vector2 = WORLD.target_position("ranch", "trough", ranch.state)
	ranch_worker.x = trough.x; ranch_worker.y = trough.y
	ranch_worker.path_target_x = trough.x; ranch_worker.path_target_y = trough.y
	var pasture := _v3(ranch)
	var result := ranch.migrate_v3(pasture)
	check(result.ok, "Noncollection ranch work and food reservation migrate: " + str(result.message))
	if result.ok:
		check(result.data.farmers[0] == pasture.farmers[0] and result.data.animals[0].meal == pasture.animals[0].meal and result.data.animals[0].path == pasture.animals[0].path, "Ranch transfer timer, physical food reservation and animal path remain intact")
		check(result.data.warehouse_hay == 4 and result.data.trough_hay == 2 and result.data.ground_products.is_empty(), "Migration does not consume food, transfer hay or create unready produce")
	# Two stale workers pointing at one ready animal must not invent two units.
	var duplicate := fresh()
	var chicken := adult(duplicate)
	for unused in range(2):
		duplicate._add_farmer("ranch")
		var person: Dictionary = duplicate.state.farmers[-1]
		person.task = {"action": "collect_product", "target": chicken.id}
		person.mode = "working"; person.phase = "acting"; person.remaining = 1.0
		person.x = chicken.x; person.y = chicken.y
		person.path_target_x = chicken.x; person.path_target_y = chicken.y
	var duplicated := _v3(duplicate)
	duplicated.animals[0].ready = 1; duplicated.animals[0].product_remaining = 0
	var resolved := duplicate.migrate_v3(duplicated)
	check(resolved.ok and resolved.data.ground_products[0].quantity == 1 and resolved.data.ground_products[0].claims.size() == 1 and resolved.data.farmers[1].task.is_empty(), "Duplicate legacy workers release their invalid extra claim without creating or deleting stock")
	var path := ProjectSettings.globalize_path("res://.review/v3-ground-failed-" + str(Time.get_ticks_usec()) + ".json")
	_write(path, duplicated)
	var hash := FileAccess.get_sha256(path)
	DirAccess.make_dir_recursive_absolute(path + ".tmp")
	var store := STORE.new(path, values)
	var failure := store.load_save()
	check(not failure.ok and failure.get("migration_write_failed", false) and FileAccess.get_sha256(path) == hash, "Failed v3 migration save leaves the exact original and never retries against an older backup")
	DirAccess.remove_absolute(path + ".tmp")
	var retry := store.load_save()
	check(retry.ok and retry.data.ground_products[0].quantity == 1 and retry.data.ground_products[0].claims.size() == 1, "Retrying a blocked migration creates exactly the original one unit")

func _write(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data, "", true, true)); file.close()

func _test_v3_batch_binding() -> void:
	var game := fresh()
	var rabbit := adult(game, "rabbit")
	var sheep := adult(game, "sheep")
	# Animal ordering drops rabbit first; worker ordering requests sheep first.
	for source in [sheep, rabbit]:
		game._add_farmer("ranch")
		var farmer: Dictionary = game.state.farmers[-1]
		farmer.task = {"action": "collect_product", "target": str(source.id)}
		farmer.mode = "working"; farmer.phase = "acting"; farmer.remaining = 0.8
		farmer.x = source.x; farmer.y = source.y
		farmer.path_target_x = source.x; farmer.path_target_y = source.y
	var old := _v3(game)
	for animal in old.animals: animal.ready = 1; animal.product_remaining = 0.0
	var result := game.migrate_v3(old)
	check(result.ok, "Two wool sources sharing one legacy drop point migrate safely")
	if not result.ok: return
	var pile: Dictionary = result.data.ground_products[0]
	check(result.data.ground_products.size() == 1 and pile.quantity == 2 and pile.batches.size() == 2 and pile.claims.size() == 2, "Legacy sheep and rabbit produce a shared pile with two source batches and two claims")
	for index in range(2):
		var task: Dictionary = result.data.farmers[index].task
		var source_id := str(old.farmers[index].task.target)
		var batch: Dictionary = pile.batches.filter(func(item): return str(item.id) == str(task.batch_id))[0]
		check(str(batch.source_animal) == source_id, "Converted worker %d claims its original animal batch rather than the first pile batch" % index)
	check(game.restore(result.data).ok, "Source-bound legacy claims reload")
	var cash := game.balance()
	game.tick(0.8)
	check(total(game) == 0 and game.balance() == cash + 680 and game.state.catalog.wool.sources == ["sheep", "rabbit"], "Worker completion order preserves the original source discoveries and exactly two payouts")
