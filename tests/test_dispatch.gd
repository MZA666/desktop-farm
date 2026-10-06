extends SceneTree

const MODEL = preload("res://scripts/game_state.gd")
const CONFIG = preload("res://scripts/config_loader.gd")
const WORLD = preload("res://scripts/world_layout.gd")
const RANCH = preload("res://scripts/ranch_life.gd")
var values: Dictionary
var failures: Array[String] = []
var assertions := 0

class FifoFarm:
	extends FarmState
	func _farm_dispatch_choice(farmer: Dictionary, tasks: Array) -> Dictionary:
		# Previous FIFO ordering, with the same actual reservation and work code.
		if tasks.is_empty(): return {}
		var task: Dictionary = tasks.front()
		var route: Array = WORLD.find_path("farm", RANCH.point(farmer), _task_destination("farm", task))
		return {"task": task, "route": route}

func _init() -> void:
	values = CONFIG.load_values()
	_test_priority_nearby()
	_test_age_window_and_fairness()
	_test_shortest_safe_route()
	_test_claims_reload_and_ranch()
	_test_distance_benchmark()
	if failures.is_empty():
		print("DISPATCH_PASS: %d priority/distance/age/fairness/replay assertions" % assertions)
		quit(0)
	else:
		for failure in failures: printerr("FAIL: " + failure)
		quit(1)

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition: failures.append(message)

func fresh() -> FarmState:
	var game := MODEL.new(values)
	game.state.animals = []
	game.state.farmers = []
	game._add_farmer("farm")
	for plot in game.state.plots: plot.open = false
	return game

func work(game: FarmState, index: int, status: String, queued := 0.0) -> void:
	var plot: Dictionary = game.state.plots[index]
	plot.open = true; plot.status = status; plot.queued_at = queued
	plot.product = game._product_for_crop(game.crops.parsnip) if status != "empty" else {}
	plot.remaining = float(game.crops.parsnip.first_seconds) if status == "unwatered" else 0.0

func place(game: FarmState, position: Vector2) -> Dictionary:
	var farmer: Dictionary = game.state.farmers[0]
	farmer.x = position.x; farmer.y = position.y
	farmer.path_target_x = position.x; farmer.path_target_y = position.y
	return farmer

func _test_priority_nearby() -> void:
	var game := fresh()
	work(game, 0, "ready"); work(game, 23, "ready")
	var farmer := place(game, WORLD.plot_worker_target(23))
	game._dispatch(farmer)
	check(farmer.task.target == str(game.state.plots[23].id) and farmer.phase == "acting", "Same-age harvest uses the closest plot instead of the first array ID")
	check(farmer.remaining == 2 and farmer.path.is_empty(), "An already-arrived worker still performs the full harvest action")
	var priority := fresh()
	work(priority, 0, "ready"); work(priority, 23, "unwatered"); work(priority, 24, "empty")
	farmer = place(priority, WORLD.plot_worker_target(23))
	priority._dispatch(farmer)
	check(farmer.task.action == "harvest" and farmer.task.target == "plot_0_0", "Distant harvest retains priority over nearby water and sow")
	var water := fresh()
	work(water, 0, "unwatered"); work(water, 23, "empty")
	farmer = place(water, WORLD.plot_worker_target(23))
	water._dispatch(farmer)
	check(farmer.task.action == "water" and farmer.task.target == "plot_0_0", "Distant water retains priority over nearby sow")
	var exhausted := fresh()
	work(exhausted, 23, "empty")
	farmer = exhausted.state.farmers[0]; farmer.energy = 1.0
	var stock: Dictionary = exhausted.state.seeds.duplicate(true)
	exhausted._dispatch(farmer)
	check(farmer.mode == "resting" and exhausted.state.seeds == stock and farmer.task.is_empty(), "Insufficient stamina rests before claiming any near seed")

func _test_age_window_and_fairness() -> void:
	for near_age in [30.0, 30.001]:
		var game := fresh()
		game.state.elapsed = 59.999
		work(game, 0, "ready", 0.0); work(game, 23, "ready", near_age)
		var farmer := place(game, WORLD.plot_worker_target(23))
		game._dispatch(farmer)
		var expected := str(game.state.plots[23 if near_age == 30.0 else 0].id)
		check(str(farmer.task.target) == expected, "30-second queue-age boundary is inclusive and excludes later work: %.3f" % near_age)
	for waited in [59.999, 60.0, 60.001]:
		var game := fresh()
		game.state.elapsed = waited
		work(game, 0, "ready", 0.0); work(game, 23, "ready", 30.0)
		var farmer := place(game, WORLD.plot_worker_target(23))
		game._dispatch(farmer)
		check(str(farmer.task.target) == str(game.state.plots[0 if waited >= 60.0 else 23].id), "The oldest task wins at the exact 60-second fairness boundary: %.3f" % waited)
	var tied := fresh()
	work(tied, 0, "ready", 1.0); work(tied, 1, "ready", 2.0)
	var midpoint := (WORLD.plot_worker_target(0) + WORLD.plot_worker_target(1)) * 0.5
	var farmer := place(tied, midpoint)
	tied._dispatch(farmer)
	check(farmer.task.target == "plot_0_0", "Equal route lengths prefer the older queue time")
	var stable := fresh()
	work(stable, 0, "ready"); work(stable, 1, "ready")
	farmer = place(stable, midpoint)
	stable._dispatch(farmer)
	check(farmer.task.target == "plot_0_0", "Equal distance and age use deterministic original order")
	var fairness := fresh()
	fairness.state.elapsed = 60.0
	work(fairness, 0, "ready", 0.0); work(fairness, 23, "ready", 50.0)
	farmer = place(fairness, WORLD.plot_worker_target(23))
	fairness._dispatch(farmer)
	check(farmer.task.target == "plot_0_0", "New nearby jobs cannot indefinitely starve an older same-priority plot")

func _test_shortest_safe_route() -> void:
	var game := fresh()
	game.state.elapsed = 10.0
	for index in range(100): work(game, index, "ready", 0.0)
	for position in [Vector2(24, 208), Vector2(300, 40), Vector2(1350, 440), Vector2(1040, 260)]:
		var farmer := place(game, position)
		var tasks := game._tasks("farm")
		var selected := game._farm_dispatch_choice(farmer, tasks)
		var expected := INF
		for task in tasks:
			var target := WORLD.target_position("farm", str(task.target), game.state)
			var route: Array = WORLD.find_path("farm", position, target)
			if not route.is_empty() or position.distance_to(target) < 0.001:
				expected = minf(expected, RANCH.path_length(position, RANCH.pack_path(route)))
		check(not selected.is_empty() and is_equal_approx(float(selected.distance), expected), "Actual traversable routes choose the shortest among all 100 plots at " + str(position))
		if not selected.is_empty(): check(game._route_safe("farm", position, RANCH.pack_path(selected.route)), "Nearest route respects real walls and world edges at " + str(position))
	var invalid_farmer := place(game, Vector2(160, 40))
	var before := game.snapshot()
	game._dispatch(invalid_farmer)
	check(game.snapshot() == before and invalid_farmer.task.is_empty(), "An unreachable farm position cannot claim seeds or start a through-wall task")

func _test_claims_reload_and_ranch() -> void:
	var game := fresh()
	work(game, 0, "ready"); work(game, 23, "ready")
	game._add_farmer("farm")
	var first := place(game, WORLD.plot_worker_target(23))
	var second: Dictionary = game.state.farmers[1]
	second.x = first.x; second.y = first.y
	second.path_target_x = first.x; second.path_target_y = first.y
	game._dispatch(first); game._dispatch(second)
	check(first.task.target == str(game.state.plots[23].id) and second.task.target == "plot_0_0", "Concurrent farmers choose different claims even from identical nearby positions")
	var saved := game.snapshot()
	var replay := MODEL.new(values)
	check(replay.restore(saved).ok and replay.snapshot() == saved, "Nearby claims retain their selected route and exact remaining time on reload")
	game.tick(3); replay.tick(3)
	check(game.snapshot() == replay.snapshot(), "Nearest dispatch consumes no RNG and replays exactly across reload")
	var ranch := MODEL.new(values)
	ranch.state.farmers = []; ranch._add_farmer("ranch")
	ranch.state.warehouse_hay = 4; ranch.state.trough_hay = 0
	var expected: Dictionary = ranch._tasks("ranch").front()
	var worker: Dictionary = ranch.state.farmers[0]
	ranch._dispatch(worker)
	check(worker.task.action == expected.action and worker.task.target == expected.target and worker.task.action == "add_hay", "Ranch keeps its established feeding-before-other-work queue")

func _distance_run(fifo: bool, seed: int) -> float:
	var game: FarmState = FifoFarm.new(values) if fifo else MODEL.new(values)
	game.state.farmers = []; game.state.animals = []; game._add_farmer("farm")
	for plot in game.state.plots: plot.open = false
	var start := Vector2(1280 - seed * 13, 196 + seed * 7)
	place(game, start)
	var indices := [0, 4, 12, 15, 21, 29, 47, 65, 80, 95, 96, 99]
	for offset in range(indices.size()):
		var index := int(indices[(offset + seed) % indices.size()])
		work(game, index, "ready", 0.0)
	var distance := 0.0
	for unused in indices:
		var farmer: Dictionary = game.state.farmers[0]
		game._dispatch(farmer)
		if farmer.task.is_empty():
			check(false, "Benchmark expected a reachable harvest task")
			return INF
		var travel := RANCH.path_length(RANCH.point(farmer), farmer.path)
		distance += travel
		var seconds := travel / float(game.state.settings.farmer_speed) + 2.0
		game._advance_farmer(farmer, seconds + 0.00001)
		game.state.elapsed += seconds
	check(game.state.plots.filter(func(p): return p.open and p.status == "ready").is_empty(), "Benchmark finishes every harvest without suppressing distant tasks")
	return distance

func _test_distance_benchmark() -> void:
	var baseline := 0.0
	var nearest := 0.0
	for seed in range(8):
		baseline += _distance_run(true, seed)
		nearest += _distance_run(false, seed)
	check(nearest < baseline, "Actual age-bounded dispatch reduces total walking versus previous FIFO over eight seeded cohorts")
	print("DISPATCH_DISTANCE: " + JSON.stringify({"fixtures": 8, "tasks_each": 12, "fifo_world_pixels": baseline, "nearest_world_pixels": nearest, "reduction_percent": 100.0 * (baseline - nearest) / baseline, "age_window_seconds": 30, "oldest_fairness_seconds": 60}))
