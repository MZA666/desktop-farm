extends SceneTree

const WORLD = preload("res://scripts/world_layout.gd")
const PREVIOUS = preload("res://scripts/world_layout_v5.gd")
const BACKGROUND := "res://assets/pixel/v0.8.1/runtime/farm-background.png"
var failures: Array[String] = []
var assertions := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition: failures.append(message)

func _run() -> void:
	check(WORLD.LAYOUT_VERSION == 6 and WORLD.V5.LAYOUT_VERSION == 5, "Append-only expansion uses version 6 and preserves its predecessor")
	check(WORLD.PLOT_COUNT == 100 and PREVIOUS.PLOT_COUNT == 96, "Exactly four additional expansion cells")
	check(WORLD.PLOT_RECT_SIZE == Vector2(54,40) and WORLD.PLOT_RECT_SIZE == PREVIOUS.PLOT_RECT_SIZE, "Single-cell size is unchanged")
	check(WORLD.PLOT_STRIDE == PREVIOUS.PLOT_STRIDE and WORLD.PLOT_ROWS == PREVIOUS.PLOT_ROWS, "Existing row spacing and row count are unchanged")
	check(WORLD.PLOT_ROW_COUNTS == PREVIOUS.PLOT_ROW_COUNTS and WORLD.PLOT_ROW_ORIGINS == PREVIOUS.PLOT_ROW_ORIGINS, "Original row mapping remains immutable")
	check(WORLD.SOIL_BACKGROUND_SHA256 == PREVIOUS.SOIL_BACKGROUND_SHA256 and FileAccess.get_sha256(BACKGROUND) == WORLD.SOIL_BACKGROUND_SHA256, "All cells reference the same unchanged original painting")
	check(WORLD.SOIL_MARGIN == 2, "Entire field retains the two-pixel soil safety margin")
	var expected_extra := [Vector2(338,308),Vector2(1290,308),Vector2(1188,350),Vector2(1244,350)]
	var plots: Array[Dictionary] = []
	var seen := {}
	var total_area := 0.0
	for index in range(WORLD.PLOT_COUNT):
		var rect: Rect2 = WORLD.plot_rect(index)
		check(rect.size == Vector2(54,40), "Unchanged cell dimensions %d" % index)
		check(not seen.has(rect.position), "Unique expansion position %d" % index)
		seen[rect.position] = true
		check(WORLD.soil_contains_rect(rect), "Whole cell and margin inside the independently traced soil boundary %d" % index)
		check(WORLD.field_bounds().encloses(rect), "Farm envelope includes %d" % index)
		check(WORLD.plot_bounds(index) == rect and WORLD.plot_center(index) == rect.get_center(), "Rendering and click rectangle use one geometry %d" % index)
		check(WORLD.plot_worker_target(index) == rect.position + Vector2(27,37), "Worker target follows the unchanged cell size %d" % index)
		check(WORLD.plot_crop_anchor(index) == rect.position + Vector2(27,36), "Crop roots follow the unchanged cell size %d" % index)
		check(rect.has_point(WORLD.plot_worker_target(index)) and rect.has_point(WORLD.plot_crop_anchor(index)), "Actor and crop anchors stay inside each cell %d" % index)
		if index < 96:
			check(rect == PREVIOUS.plot_rect(index), "Original cell is never moved %d" % index)
			check(WORLD.plot_row(index) == PREVIOUS.plot_row(index) and WORLD.plot_column(index) == PREVIOUS.plot_column(index), "Original visual row and column survive %d" % index)
			check(WORLD.plot_worker_target(index) == PREVIOUS.plot_worker_target(index) and WORLD.plot_crop_anchor(index) == PREVIOUS.plot_crop_anchor(index), "Existing task and crop anchors survive %d" % index)
		else:
			check(rect.position == expected_extra[index-96], "Only the approved four empty soil positions are appended %d" % index)
			var expected_row := 4 if index < 98 else 5
			check(WORLD.plot_row(index) == expected_row, "New slots belong to the bottom two existing rows %d" % index)
		plots.append({"id":"plot_%d_%d" % [index/16,index%16],"global_index":index})
		total_area += rect.get_area()
		for slot in range(3):
			_check_route(WORLD.farmer_idle_position("farm",slot),WORLD.plot_worker_target(index),"Worker %d reaches plot %d" % [slot,index])
	check(seen.size() == 100 and total_area == 216000, "100 distinct unchanged-size cells increase cultivated area by 8640 pixels")
	check(WORLD.field_bounds() == Rect2(338,140,1048,250), "Added cells fill both sides without adding a seventh row")
	check(WORLD.plot_position(-1) == WORLD.plot_position(0) and WORLD.plot_position(100) == WORLD.plot_position(99), "Out-of-range indices clamp to actual first and final cell")
	for first in range(WORLD.PLOT_COUNT):
		check(WORLD.target_position("farm",plots[first].id,{"plots":plots}) == WORLD.plot_worker_target(first), "Every stable ID resolves via its global index %d" % first)
		for second in range(first+1,WORLD.PLOT_COUNT):
			check(not WORLD.plot_rect(first).grow(1).intersects(WORLD.plot_rect(second).grow(1)), "Cells maintain at least two pixels clear %d/%d" % [first,second])
	for index in range(96,100):
		_check_route(WORLD.plot_worker_target(95),WORLD.plot_worker_target(index),"Original cell to new expansion cell %d" % index)
	check(not WORLD.soil_contains_rect(Rect2(400,370,60,60)), "Left path and grass still reject field expansion")
	check(not WORLD.soil_contains_rect(Rect2(1340,360,54,40)), "Right bank still rejects a cell that would cross into grass")
	check(not WORLD.soil_contains_rect(Rect2(1188,392,54,40)), "A seventh row would cross the lower boundary and remains forbidden")
	_test_unrelated_geometry()
	if failures.is_empty(): print("WORLD_LAYOUT_V6_PASS: %d assertions" % assertions)
	else:
		for failure in failures: printerr("FAIL: "+failure)
	quit(0 if failures.is_empty() else 1)

func _check_route(start: Vector2, finish: Vector2, label: String) -> void:
	check(WORLD.is_walkable("farm",start) and WORLD.is_walkable("farm",finish),label+" endpoints valid")
	var route: Array[Vector2] = WORLD.find_path("farm",start,finish)
	check(not route.is_empty() or start.is_equal_approx(finish),label+" route exists")
	var point := start
	for waypoint in route:
		check(WORLD.segment_walkable("farm",point,waypoint),label+" segments avoid buildings")
		point = waypoint
	check(point.is_equal_approx(finish),label+" reaches the exact cell")

func _test_unrelated_geometry() -> void:
	for scene in ["farm","ranch","pond"]:
		check(WORLD.world_size(scene) == PREVIOUS.world_size(scene),"World size unchanged "+scene)
		check(WORLD.obstacles(scene) == PREVIOUS.obstacles(scene),"Static obstacles unchanged "+scene)
		for slot in range(3): check(WORLD.farmer_idle_position(scene,slot) == PREVIOUS.farmer_idle_position(scene,slot),"Idle position unchanged "+scene)
	for index in range(96): check(WORLD.grass_anchor(index) == PREVIOUS.grass_anchor(index),"Pasture site unchanged %d" % index)
	for id in WORLD.SHELTER_IDS:
		check(WORLD.shelter_bounds(id) == PREVIOUS.shelter_bounds(id) and WORLD.shelter_exit(id) == PREVIOUS.shelter_exit(id),"Shelter unchanged "+id)
	check(WORLD.trough_position() == PREVIOUS.trough_position() and WORLD.warehouse_position() == PREVIOUS.warehouse_position(),"Hay storage geometry unchanged")
	check(WORLD.water_bounds() == PREVIOUS.water_bounds() and WORLD.POND_DOCK == PREVIOUS.POND_DOCK,"Water and dock geometry unchanged")
	for index in range(64):
		var point := Vector2((index*83)%2200-100,(index*37)%700-100)
		check(WORLD.product_drop_position(point) == PREVIOUS.product_drop_position(point),"Ground product sites unchanged %d" % index)
		check(WORLD.sample_fish_position(float(index)/64,float((index*7)%64)/64) == PREVIOUS.sample_fish_position(float(index)/64,float((index*7)%64)/64),"Fish movement samples unchanged %d" % index)
