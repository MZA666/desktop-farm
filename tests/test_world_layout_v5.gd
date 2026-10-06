extends SceneTree

const WORLD = preload("res://scripts/world_layout_v5.gd")
const PREVIOUS = preload("res://scripts/world_layout_v4.gd")
var failures: Array[String] = []
var assertions := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition: failures.append(message)

func _run() -> void:
	check(WORLD.LAYOUT_VERSION == 5, "Contour farmland explicitly uses layout 5")
	check(WORLD.V4.LAYOUT_VERSION == 4 and WORLD.V3.LAYOUT_VERSION == 3, "Both old geometries remain frozen")
	check(PREVIOUS.plot_rect(95) == Rect2(1198,334,48,36), "Frozen v4 last tile retains independent dimensions")
	check(PREVIOUS.farmer_idle_position("farm",0) == Vector2(208,404), "Frozen v4 old farm idle anchor")
	check(WORLD.PLOT_COUNT == 96 and WORLD.PLOT_ROWS == 6, "No plot quantity or economic capacity changes")
	check(WORLD.PLOT_RECT_SIZE == Vector2(54,40), "New tile dimensions support wider crops")
	check(WORLD.PLOT_STRIDE - WORLD.PLOT_RECT_SIZE == Vector2(2,2), "Natural two-pixel spacing between cells and rows")
	check(WORLD.PLOT_ROW_COUNTS == [15,16,18,18,16,13], "Narrow top, wide middle and curved lower field")
	check(WORLD.SOIL_POLYGON == PREVIOUS.SOIL_POLYGON and WORLD.SOIL_MARGIN == 2, "Soil boundary and safety margin stay independent of slots")
	check(FileAccess.get_sha256("res://assets/pixel/v0.8.1/runtime/farm-background.png") == WORLD.SOIL_BACKGROUND_SHA256, "Geometry references the original unchanged farm image")
	var expected_origins := [Vector2(448,140),Vector2(430,182),Vector2(380,224),Vector2(354,266),Vector2(394,308),Vector2(460,350)]
	var seen := {}
	var total_area := 0.0
	var old_area := 0.0
	var next_index := 0
	var plots: Array[Dictionary] = []
	for row in range(WORLD.PLOT_ROWS):
		for column in range(WORLD.PLOT_ROW_COUNTS[row]):
			var index := next_index
			var rect: Rect2 = WORLD.plot_rect(index)
			check(WORLD.plot_row(index) == row and WORLD.plot_column(index) == column, "Stable index maps into the contour row %d" % index)
			check(rect.position == expected_origins[row] + Vector2(column*56,0), "Row origin and horizontal stride %d" % index)
			check(WORLD.plot_bounds(index) == rect and WORLD.plot_center(index) == rect.get_center(), "Drawing, hit testing and center share one rectangle %d" % index)
			check(WORLD.soil_contains_rect(rect), "Entire rectangle plus two-pixel margin on real soil %d" % index)
			check(not seen.has(rect.position), "Every stable plot has a unique position %d" % index)
			seen[rect.position] = true
			check(WORLD.field_bounds().encloses(rect), "Contour field envelope includes tile %d" % index)
			check(WORLD.plot_worker_target(index) == rect.position + Vector2(27,37), "Worker feet follow actual new tile %d" % index)
			check(WORLD.plot_crop_anchor(index) == rect.position + Vector2(27,36), "Crop roots use the same tile dimensions %d" % index)
			check(rect.has_point(WORLD.plot_worker_target(index)) and rect.has_point(WORLD.plot_crop_anchor(index)), "Work and crop anchors inside tile %d" % index)
			for slot in range(3):
				_check_route(WORLD.farmer_idle_position("farm",slot),WORLD.plot_worker_target(index),"All 96 tasks reachable from worker %d plot %d" % [slot,index])
			plots.append({"id":"plot_%d_%d" % [index/16,index%16],"global_index":index})
			total_area += rect.get_area()
			old_area += PREVIOUS.plot_rect(index).get_area()
			next_index += 1
	check(next_index == 96 and seen.size() == 96, "Variable visual rows preserve all 96 stable cells")
	check(total_area == 207360 and total_area >= old_area*1.25, "Actual planted area increases by 25 percent over v4")
	check(WORLD.field_bounds() == Rect2(354,140,1032,250), "Rows spread across upper, middle and lower soil")
	check(WORLD.plot_row(0) == 0 and WORLD.plot_row(14) == 0 and WORLD.plot_row(15) == 1 and WORLD.plot_column(23) == 8, "Initial 24 open first row plus nine next-row plots")
	check(WORLD.plot_position(-1) == WORLD.plot_position(0) and WORLD.plot_position(96) == WORLD.plot_position(95), "Invalid display indices clamp consistently")
	for first in range(96):
		for second in range(first+1,96):
			check(not WORLD.plot_rect(first).grow(1).intersects(WORLD.plot_rect(second).grow(1)), "Tiles keep at least two pixels clear %d/%d" % [first,second])
		var id: String = plots[first].id
		check(WORLD.target_position("farm",id,{"plots":plots}) == WORLD.plot_worker_target(first), "Legacy-named ID resolves via stable global index %s" % id)
		_check_route(PREVIOUS.plot_worker_target(first),WORLD.plot_worker_target(first),"Old valid workpoint reaches remapped stable cell %d" % first)
		if first > 0: _check_route(WORLD.plot_worker_target(first-1),WORLD.plot_worker_target(first),"Adjacent work sequence remains reachable %d" % first)
	check(not WORLD.soil_contains_rect(Rect2(400,370,60,60)), "Path-side out-of-soil tile stays rejected")
	check(not WORLD.soil_contains_rect(Rect2(1340,360,54,40)), "Right-bank edge remains protected despite larger cells")
	_test_other_scenes_unchanged()
	if failures.is_empty(): print("WORLD_LAYOUT_V5_PASS: %d assertions" % assertions)
	else:
		for failure in failures: printerr("FAIL: "+failure)
	quit(0 if failures.is_empty() else 1)

func _check_route(start: Vector2,finish: Vector2,label: String) -> void:
	check(WORLD.is_walkable("farm",start) and WORLD.is_walkable("farm",finish),label+" endpoints valid")
	var route: Array[Vector2] = WORLD.find_path("farm",start,finish)
	check(not route.is_empty() or start.is_equal_approx(finish),label+" route exists")
	var point := start
	for waypoint in route:
		check(WORLD.segment_walkable("farm",point,waypoint),label+" continuous segment valid")
		point = waypoint
	check(point.is_equal_approx(finish),label+" arrives at exact workpoint")

func _test_other_scenes_unchanged() -> void:
	for scene in ["ranch","pond"]:
		check(WORLD.world_size(scene) == PREVIOUS.world_size(scene),"Unrelated world dimensions stay unchanged "+scene)
		for slot in range(3): check(WORLD.farmer_idle_position(scene,slot) == PREVIOUS.farmer_idle_position(scene,slot),"Unrelated worker idle positions stay unchanged")
	for index in range(96): check(WORLD.grass_anchor(index) == PREVIOUS.grass_anchor(index),"Pasture anchors unchanged %d" % index)
	for id in WORLD.SHELTER_IDS: check(WORLD.shelter_bounds(id) == PREVIOUS.shelter_bounds(id) and WORLD.shelter_exit(id) == PREVIOUS.shelter_exit(id),"Barn geometry unchanged "+id)
	check(WORLD.trough_position() == PREVIOUS.trough_position() and WORLD.warehouse_position() == PREVIOUS.warehouse_position(),"Hay warehouse and trough anchors unchanged")
	check(WORLD.water_bounds() == PREVIOUS.water_bounds() and WORLD.POND_DOCK == PREVIOUS.POND_DOCK,"Fish and dock coordinate domains unchanged")
	for index in range(64):
		var point := Vector2((index*83)%2200-100,(index*37)%700-100)
		check(WORLD.product_drop_position(point) == PREVIOUS.product_drop_position(point),"Ground product merge sites unchanged")
		var u := float(index)/64
		var v := float((index*7)%64)/64
		check(WORLD.sample_fish_position(u,v) == PREVIOUS.sample_fish_position(u,v),"Existing fish sample and motion geometry unchanged")
