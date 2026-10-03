extends SceneTree

## Frozen geometry is a migration contract; current geometry is tested in v4.
const World = preload("res://scripts/world_layout_v3.gd")
var failures: Array[String] = []
var assertions := 0

func _initialize() -> void:
	_test_fields()
	_test_grass_and_homes()
	_test_paths()
	_test_targets_and_legacy()
	if failures.is_empty():
		print("WORLD_LAYOUT_V3_PASS: %d geometry/grass/navigation/legacy assertions" % assertions)
	else:
		for failure in failures: printerr("FAIL: " + failure)
	quit(0 if failures.is_empty() else 1)

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition: failures.append(message)

func _test_fields() -> void:
	check(World.world_size("farm") == Vector2(1536, 512), "Farm world is independent of 352/172px viewport")
	check(World.world_size("ranch") == Vector2(1920, 512), "Ranch world bounds")
	check(World.world_size("pond") == Vector2(1536, 512), "Pond world bounds")
	check(World.world_size("unknown") == Vector2.ZERO, "Unknown world has no valid positions")
	check(World.plot_position(0) == Vector2(352, 112), "First stable plot")
	check(World.plot_position(15) == Vector2(1192, 112), "Sixteenth plot ends first row")
	check(World.plot_position(16) == Vector2(352, 168), "Seventeenth plot begins second row")
	check(World.plot_position(95) == Vector2(1192, 392), "Final plot is sixth-row sixteenth-column")
	var unique := {}
	for index in range(96):
		var rect := World.plot_bounds(index)
		check(World.field_bounds().encloses(rect), "Plot remains inside the continuous field %d" % index)
		check(rect.size == Vector2(56, 56), "Readable 56px field cell %d" % index)
		check(not unique.has(rect.position), "No duplicate plot position %d" % index)
		unique[rect.position] = true
		var target := rect.position + Vector2(28, 56)
		check(World.is_walkable("farm", target), "Plot work feet are walkable %d" % index)
		_check_path("farm", World.farmer_idle_position("farm", 0), target)
	for scene in ["farm", "ranch", "pond"]:
		for slot in range(3): check(World.is_walkable(scene, World.farmer_idle_position(scene, slot)), "All initial worker positions valid %s %d" % [scene, slot])
	check(not World.is_position_valid("farm", Vector2(NAN, 20)), "NaN boundary rejected")
	check(not World.is_walkable("farm", Vector2(INF, 20)), "Infinite foot position rejected")
	check(not World.is_walkable("missing", Vector2.ZERO), "Unknown navigation scene rejected")

func _test_grass_and_homes() -> void:
	var points := {}
	for index in range(96):
		var position := World.grass_anchor(index)
		check(position == World.grass_anchor(index), "Grass placement deterministic %d" % index)
		check(World.pasture_bounds().has_point(position), "Grass remains on open pasture %d" % index)
		check(World.is_walkable("ranch", position), "Grass does not intersect a building %d" % index)
		check(not points.has(position), "Grass sites unique %d" % index)
		points[position] = true
		var neighbors := World.grass_neighbors(index)
		check(neighbors.size() <= 4, "Spread retains at most four neighbors %d" % index)
		for neighbor in neighbors:
			check(neighbor >= 0 and neighbor < 96 and neighbor != index, "Spread site range valid")
			check(World.grass_neighbors(neighbor).has(index), "Spread adjacency reciprocal")
			check(position.distance_to(World.grass_anchor(neighbor)) < 150, "Spread is local, despite irregular visual positions")
	for id in World.SHELTER_IDS:
		var exit := World.shelter_exit(id)
		check(World.is_walkable("ranch", exit), "Each shelter has a clear home exit " + id)
		check(not World.is_walkable("ranch", World.shelter_bounds(id).get_center()), "Shelter interiors cannot be crossed " + id)
		for index in range(96):
			_check_path("ranch", exit, World.grass_anchor(index))
	for index in range(6):
		check(World.shelter_exit("chicken_coop").distance_to(World.grass_anchor(index)) < 300, "Gift grass near gifted chicks %d" % index)
	check(World.is_walkable("ranch", World.trough_position()), "Trough meal point is outside building collision")
	check(World.is_walkable("ranch", World.warehouse_position()), "Warehouse task point is outside building collision")
	check(World.grass_neighbors(-1).is_empty() and World.grass_neighbors(96).is_empty(), "Invalid spread sites rejected")

func _check_path(scene: String, start: Vector2, finish: Vector2) -> void:
	var path: Array[Vector2] = World.find_path(scene, start, finish)
	if start.is_equal_approx(finish):
		check(path.is_empty(), "Already arrived path has no motion")
		return
	check(not path.is_empty(), "Reachable endpoint has a path %s %s -> %s" % [scene, start, finish])
	if path.is_empty(): return
	check(path.back().is_equal_approx(finish), "Path preserves exact destination")
	check(not path.front().is_equal_approx(start), "Path does not repeat start")
	var previous := start
	for point in path:
		check(World.is_walkable(scene, point), "Path waypoint has actor clearance")
		check(World.segment_walkable(scene, previous, point), "Whole segment avoids obstacles, not just endpoints")
		previous = point
	check(path == World.find_path(scene, start, finish), "Route selection deterministic")

func _test_paths() -> void:
	check(not World.segment_walkable("ranch", Vector2(48, 40), Vector2(288, 40)), "Barn blocks an otherwise valid straight path")
	_check_path("ranch", Vector2(48, 40), Vector2(288, 40))
	_check_path("farm", Vector2(304, 40), Vector2(208, 216))
	check(not World.is_walkable("pond", Vector2(900, 250)), "Fish water is impassable to workers")
	check(World.is_walkable("pond", World.POND_DOCK), "Pier is passable over water")
	check(not World.segment_walkable("pond", Vector2(280, 60), Vector2(1480, 480)), "Opposite shores cannot cut through water")
	_check_path("pond", Vector2(280, 60), Vector2(1480, 480))
	_check_path("pond", World.POND_DOCK, Vector2(280, 60))
	check(World.find_path("ranch", Vector2(168, 184), Vector2(168, 40)).is_empty(), "Invalid destination inside house rejected")
	check(World.find_path("pond", Vector2(900, 250), World.POND_DOCK).is_empty(), "Invalid starting point cannot teleport out of water")
	for scene in ["farm", "ranch", "pond"]:
		for position in [Vector2(-999, -999), Vector2(9999, 9999), Vector2(100, 100), Vector2(NAN, INF)]:
			check(World.is_walkable(scene, World.clamp_to_walkable(scene, position)), "Migration fallback returns clear feet %s %s" % [scene, position])

func _test_targets_and_legacy() -> void:
	var state := {"plots": [{"id": "plot_5_15", "index": 95}],
		"grass": [{"id": "grass_2", "index": 2, "x": 500.0, "y": 300.0}],
		"animals": [{"id": "animal_1", "type_id": "cow", "x": 650.0, "y": 350.0}]}
	check(World.target_position("farm", "plot_5_15", state) == Vector2(1220, 448), "Stable plot ID resolves new target feet")
	check(World.target_position("ranch", "grass_2", state) == Vector2(500, 300), "Saved grass position takes precedence")
	check(World.target_position("ranch", "animal_1", state) == Vector2(650, 350), "Worker follows actual roaming animal")
	check(World.legacy_plot_position(0) == Vector2(64, 20) and World.legacy_plot_position(95) == Vector2(1056, 84), "Old field geometry frozen for migration")
	check(World.legacy_world_size("farm") == Vector2(1152, 172) and World.legacy_world_size("ranch") == Vector2(1920, 172), "V2 save bounds frozen")
	check(World.legacy_grass_position(95) == Vector2(714, 118), "Old grass geometry frozen")
	check(World.legacy_target_position("ranch", "trough", {}) == Vector2(1833, 72), "Old work target frozen")
