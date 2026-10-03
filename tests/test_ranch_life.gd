extends SceneTree

const MODEL = preload("res://scripts/game_state.gd")
const CONFIG = preload("res://scripts/config_loader.gd")
const LIFE = preload("res://scripts/ranch_life.gd")
const WORLD = preload("res://scripts/world_layout.gd")
var values: Dictionary
var assertions := 0
var failures: Array[String] = []

func _init() -> void:
	values = CONFIG.load_values()
	_test_motion()
	_test_meals()
	_test_hay_and_release()
	_test_early_departure()
	_test_interactions()
	_test_collection()
	_test_validation()
	if failures.is_empty():
		print("RANCH_LIFE_PASS: %d motion/meal/ledger/interaction/collection assertions" % assertions)
		quit(0)
	else:
		for failure in failures: printerr("FAIL: " + failure)
		quit(1)

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition and failures.size() < 100: failures.append(message)

func fresh() -> FarmState:
	var game := MODEL.new(values)
	game.state.farmers = []
	game.state.animals = []
	game.state.trough_hay = 0
	for plot in game.state.plots: plot.open = false
	for grass in game.state.grass:
		if not grass.mother: grass.clumps = 1 if grass.open else 0
	for id in game.state.shelters: game.state.shelters[id] = 3
	return game

func add(game: FarmState, kind: String, fed := true) -> Dictionary:
	game._add_animal(kind)
	var animal: Dictionary = game.state.animals[-1]
	if fed:
		animal.food_remaining = 300.0
		animal.hungry = false
	return animal

func _test_motion() -> void:
	var game := fresh()
	var origins := {}
	var maximums := {}
	for kind in values.animals:
		var animal := add(game, str(kind.id))
		origins[str(animal.id)] = LIFE.point(animal)
		maximums[str(animal.id)] = 0.0
	var old_rng: Dictionary = game.state.rng.duplicate(true)
	for tick_index in range(300):
		var before := {}
		for animal in game.state.animals: before[str(animal.id)] = LIFE.point(animal)
		game.tick(0.2)
		for animal in game.state.animals:
			check(WORLD.is_walkable("ranch", LIFE.point(animal)), "All 11 types remain on reachable ground")
			var speed := 12.0 if int(game.animal_types[str(animal.type_id)].food_grass) == 2 else 10.0
			check(LIFE.point(animal).distance_to(before[str(animal.id)]) <= speed * 0.2 + 0.001, "Motion is bounded by actual world speed")
			maximums[str(animal.id)] = maxf(float(maximums[str(animal.id)]), LIFE.point(animal).distance_to(origins[str(animal.id)]))
	for id in maximums: check(float(maximums[id]) > 24.0, "Every type genuinely leaves its initial point: " + id)
	for stream in ["grass", "crop", "fish"]: check(game.state.rng[stream] == old_rng[stream], "Actor motion does not consume production RNG " + stream)
	var copy := MODEL.new(values)
	check(copy.restore(game.snapshot()).ok, "Positions, behaviour, paths and animal RNG restore")
	game.tick(17.6)
	for unused in range(88): copy.tick(0.2)
	check(JSON.stringify(game.snapshot()) == JSON.stringify(copy.snapshot()), "Chunked and single-call 5 Hz replay match exactly")
	var hungry := fresh()
	var starving := add(hungry, "chicken", false)
	var start := LIFE.point(starving)
	var growth := float(starving.adult_remaining)
	hungry.tick(20)
	check(starving.hungry and starving.adult_remaining == growth, "Hungry animals pause growth")
	check(LIFE.point(starving).distance_to(start) > 5, "Hungry animals still wander and search")

func _test_meals() -> void:
	var game := fresh()
	for index in [2, 3]:
		game.state.grass[index].open = true
		game.state.grass[index].clumps = 4
	var cow := add(game, "cow", false)
	var other := add(game, "cow", false)
	var origin := LIFE.point(game.state.grass[2]) + Vector2(-24, 0)
	cow.x = origin.x
	cow.y = origin.y
	cow.previous_x = origin.x
	cow.previous_y = origin.y
	check(LIFE.reserve_meal(game.state, cow, game.animal_types), "Big animal claims a complete multi-patch meal")
	check(cow.meal.grass.size() == 2 and int(cow.meal.grass[0].amount) + int(cow.meal.grass[1].amount) == 4, "A full ordinary patch has only three edible clumps")
	check(game.state.grass[2].clumps == 4 and game.state.grass[3].clumps == 4, "Reservation does not consume any stock")
	check(not LIFE.reserve_meal(game.state, other, game.animal_types) and other.meal.is_empty(), "Two big animals cannot claim the same meal or a half meal")
	check(not game._reserve_task({"action": "cut_grass", "target": "grass_2"}), "Grass cutting cannot steal animal-reserved clumps")
	game.tick(1)
	check(game.state.grass[2].clumps == 4 and game.state.grass[3].clumps == 4 and cow.hungry, "Food is not remotely consumed before arrival")
	var copy := MODEL.new(values)
	check(copy.restore(game.snapshot()).ok, "In-flight full meal and route restore")
	game.tick(40)
	copy.tick(40)
	check(JSON.stringify(game.snapshot()) == JSON.stringify(copy.snapshot()), "In-flight meal resumes without duplicate consumption")
	check(int(game.state.grass[2].clumps) + int(game.state.grass[3].clumps) == 4 and not cow.hungry, "Whole meal consumes exactly four clumps on physical arrival")
	check(game.state.grass[0].clumps == 4 and game.state.grass[1].clumps == 4, "Mother grass is never eaten")
	var cutting := fresh()
	cutting.state.grass[2].clumps = 4
	cutting.state.grass[3].clumps = 4
	cutting._add_farmer("ranch")
	var task := {"action": "cut_grass", "target": "grass_2"}
	check(cutting._reserve_task(task), "Worker reserves three edible clumps")
	cutting.state.farmers[0].task = task
	var grazing := add(cutting, "cow", false)
	check(not LIFE.reserve_meal(cutting.state, grazing, cutting.animal_types), "Animal cannot steal worker-reserved cutting stock")
	cutting._commit_task(task)
	cutting.state.farmers[0].task = {}
	check(cutting.state.grass[2].clumps == 1 and cutting.state.warehouse_hay == 1, "Cutting conserves stock and leaves roots")

func _test_hay_and_release() -> void:
	var game := fresh()
	game.state.trough_hay = 1
	var cow := add(game, "cow", false)
	var second := add(game, "cow", false)
	var trough: Vector2 = WORLD.target_position("ranch", "trough", game.state)
	var start := trough + Vector2(-20, 0)
	cow.x = start.x
	cow.y = start.y
	cow.previous_x = start.x
	cow.previous_y = start.y
	check(LIFE.reserve_meal(game.state, cow, game.animal_types) and cow.meal.source == "hay", "No complete grass meal falls back to one hay")
	check(game.state.trough_hay == 1 and not LIFE.reserve_meal(game.state, second, game.animal_types), "Hay reservation remains stock and cannot be double reserved")
	game.tick(1)
	check(game.state.trough_hay == 1, "Hay is not consumed at a distance")
	game.tick(5)
	check(game.state.trough_hay == 0 and not cow.hungry and cow.meal.is_empty(), "Arrived animal consumes exactly one hay meal")
	var released := fresh()
	released.state.trough_hay = 1
	var doomed := add(released, "cow", false)
	check(LIFE.reserve_meal(released.state, doomed, released.animal_types), "Sell fixture holds hay reservation")
	check(released.command("sell_animal", {"instance_id": doomed.id}).ok and LIFE.hay_reserved(released.state) == 0 and released.state.trough_hay == 1, "Selling releases unconsumed reservation without losing hay")
	var timeout := add(released, "cow", false)
	LIFE.reserve_meal(released.state, timeout, released.animal_types)
	timeout.meal.remaining = 0.2
	LIFE.step(released.state, released.animal_types, 0.2)
	check(timeout.meal.is_empty() and released.state.trough_hay == 1, "Timed-out path releases the whole untouched meal")

func _test_interactions() -> void:
	var game := fresh()
	var chick := add(game, "chicken")
	var next := add(game, "chicken")
	var result := game.command("interact_animal", {"instance_id": chick.id})
	check(result.ok and result.reward_seconds == 30 and chick.juvenile_bonus_used == 30, "Juvenile click awards up to 30 seconds")
	check(game.command("interact_animal", {"instance_id": chick.id}).reward_seconds == 0, "Same instance cannot repeat before 120 seconds")
	check(game.command("interact_animal", {"instance_id": next.id}).reward_seconds == 0, "Global two-second interval applies to different animals")
	game.state.elapsed = 2
	check(game.command("interact_animal", {"instance_id": next.id}).reward_seconds == 30, "Another animal can reward at exact global boundary")
	for index in range(1, 7):
		game.state.elapsed = index * 120.0
		game.command("interact_animal", {"instance_id": chick.id})
	check(chick.juvenile_bonus_used == 180 and chick.adult_remaining == 720, "Chicken juvenile lifetime bonus capped at 20 percent")
	var copy := MODEL.new(values)
	check(copy.restore(game.snapshot()).ok and copy.state.animals[0].last_reward_elapsed == chick.last_reward_elapsed, "Reward cooldown and lifetime quota survive reload")
	chick.adult = true
	chick.adult_remaining = 0
	chick.product_remaining = 300
	game.state.elapsed = 1000
	check(game.command("interact_animal", {"instance_id": chick.id}).reward_seconds == 15, "Adult single click is at most five percent")
	game.state.elapsed = 1120
	check(game.command("interact_animal", {"instance_id": chick.id}).reward_seconds == 15, "Adult second click reaches ten percent cycle limit")
	game.state.elapsed = 1240
	check(game.command("interact_animal", {"instance_id": chick.id}).reward_seconds == 0 and chick.adult_bonus_used == 30, "Adult bonus never exceeds cycle cap")
	chick.ready = 1
	game._collect_animal(chick)
	check(chick.adult_bonus_used == 0 and chick.production_cycle == 1 and chick.last_reward_elapsed == 1120, "Collection resets cycle quota but preserves reward cooldown")
	chick.hungry = true
	var global_before := float(game.state.ranch.global_reward_elapsed)
	check(game.command("interact_animal", {"instance_id": chick.id}).reward_seconds == 0 and chick.adult_bonus_used == 0 and game.state.ranch.global_reward_elapsed == global_before, "Hungry feedback consumes no economic allowance")
	game.state.settings.interactive = false
	var before := JSON.stringify(game.snapshot())
	check(not game.command("interact_animal", {"instance_id": chick.id}).ok and JSON.stringify(game.snapshot()) == before, "Observation mode cannot trigger reward")
	var near := fresh()
	var almost_adult := add(near, "chicken")
	almost_adult.adult_remaining = 5.0
	check(near.command("interact_animal", {"instance_id": almost_adult.id}).reward_seconds == 5 and almost_adult.adult and almost_adult.product_remaining == 300, "Juvenile reward uses only actual remaining time and never spills into adulthood")
	check(near.command("interact_animal", {"instance_id": almost_adult.id}).reward_seconds == 0, "Adulthood does not reset the instance reward cooldown")

func _test_early_departure() -> void:
	var game := fresh()
	game.state.trough_hay = 2
	var cow := add(game, "cow")
	var start: Vector2 = WORLD.shelter_exit("chicken_coop")
	cow.x = start.x
	cow.y = start.y
	cow.previous_x = start.x
	cow.previous_y = start.y
	cow.food_remaining = 180.0
	game.tick(12)
	check(not cow.meal.is_empty() and cow.meal.source == "hay" and cow.food_remaining > 60, "Long reachable food trip causes departure before a fixed sixty-second threshold")
	check(game.state.trough_hay == 2, "Early departure only reserves its future meal")
	var copy := MODEL.new(values)
	check(copy.restore(game.snapshot()).ok, "Early food decision and reservation survive reload")
	var ever_hungry := false
	for unused in range(845):
		game.tick(0.2)
		if cow.hungry: ever_hungry = true
	copy.tick(169)
	check(not ever_hungry and game.state.trough_hay == 1, "Estimated travel and eating margin prevents starvation and consumes once when due")
	check(JSON.stringify(game.snapshot()) == JSON.stringify(copy.snapshot()), "Forecast feeding resumes identically across process restart")

func _test_collection() -> void:
	var game := fresh()
	var animal := add(game, "chicken")
	animal.adult = true
	animal.adult_remaining = 0
	animal.ready = 1
	game._add_farmer("ranch")
	var farmer: Dictionary = game.state.farmers[0]
	var start := LIFE.point(animal) + Vector2(0, 48)
	farmer.x = start.x
	farmer.y = start.y
	farmer.path_target_x = start.x
	farmer.path_target_y = start.y
	var cash := game.balance()
	game.tick(0.2)
	check(farmer.task.get("action", "") == "collect_product" and animal.ready == 1, "Worker claims animal ID and travels before collection")
	var copy := MODEL.new(values)
	check(copy.restore(game.snapshot()).ok, "Moving-target collection path restores")
	game.tick(30)
	copy.tick(30)
	check(game.balance() == cash + 50 and animal.ready == 0, "Farmer reaches moving animal and collects exactly one egg")
	check(animal.held_by.is_empty() and JSON.stringify(game.snapshot()) == JSON.stringify(copy.snapshot()), "Collection releases actor and resumes deterministically")

func _test_validation() -> void:
	var game := fresh()
	var animal := add(game, "cow")
	for key in ["x", "facing", "juvenile_bonus_used", "last_reward_elapsed"]:
		var bad := game.snapshot()
		match key:
			"x": bad.animals[0].x = -1
			"facing": bad.animals[0].facing = "diagonal"
			"juvenile_bonus_used": bad.animals[0].juvenile_bonus_used = 999999
			"last_reward_elapsed": bad.animals[0].last_reward_elapsed = 1000
		check(not game.restore(bad).ok, "Strict v3 rejects corrupt actor " + key)
	var crossing := game.snapshot()
	var finish := Vector2(1008, 100)
	crossing.animals[0].x = 760.0
	crossing.animals[0].y = 100.0
	crossing.animals[0].previous_x = 760.0
	crossing.animals[0].previous_y = 100.0
	check(WORLD.is_walkable("ranch", finish), "Path corruption fixture has a legal endpoint")
	crossing.animals[0].path = [{"x": finish.x, "y": finish.y}]
	crossing.animals[0].target = {"kind": "wander", "x": finish.x, "y": finish.y}
	check(not game.restore(crossing).ok, "A legal endpoint cannot conceal a route through a barn")
	var claimed := fresh()
	claimed.state.grass[2].clumps = 4
	claimed.state.grass[3].clumps = 4
	var first := add(claimed, "cow", false)
	var second := add(claimed, "cow", false)
	LIFE.reserve_meal(claimed.state, first, claimed.animal_types)
	var overbooked := claimed.snapshot()
	overbooked.animals[1].meal = overbooked.animals[0].meal.duplicate(true)
	overbooked.animals[1].path = overbooked.animals[0].path.duplicate(true)
	overbooked.animals[1].target = overbooked.animals[0].target.duplicate(true)
	check(not claimed.restore(overbooked).ok, "Reload rejects two durable claims to the same complete grass meal")
	var remote := claimed.snapshot()
	remote.animals[0].path = []
	remote.animals[0].behavior = "eating"
	check(not claimed.restore(remote).ok, "Reload cannot remotely consume a meal before reaching its target")
	check(not game.command("interact_animal", {"instance_id": "missing"}).ok, "Removed animal cannot reward")
