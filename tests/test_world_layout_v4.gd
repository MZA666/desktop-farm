extends SceneTree

const WORLD = preload("res://scripts/world_layout.gd")
const MOTION = preload("res://scripts/fish_motion.gd")
var failures: Array[String] = []
var assertions := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition: failures.append(message)

func _run() -> void:
	check(WORLD.LAYOUT_VERSION == 4, "V4 geometry explicitly versioned")
	check(WORLD.V3.LAYOUT_VERSION == 3, "Frozen v3 geometry")
	check(WORLD.v3_plot_position(95) == Vector2(1192, 392), "Frozen old bottom row")
	check(WORLD.v3_water_bounds() == Rect2(320,96,1130,324), "Frozen normalized fish transform")
	var occupied := {}
	for index in range(96):
		var rect: Rect2 = WORLD.plot_rect(index)
		check(WORLD.soil_contains_rect(rect), "Whole tile and margin inside independently authored soil %d" % index)
		check(rect.has_point(WORLD.plot_worker_target(index)), "Work target inside actual tile %d" % index)
		check(rect.has_point(WORLD.plot_crop_anchor(index)), "Crop roots inside tile %d" % index)
		check(not occupied.has(rect.position), "Stable slot unique %d" % index)
		occupied[rect.position] = true
		check(WORLD.is_walkable("farm", WORLD.plot_worker_target(index)), "New tile target walkable %d" % index)
		check(not WORLD.find_path("farm", WORLD.farmer_idle_position("farm", 0), WORLD.plot_worker_target(index)).is_empty(), "All96farmtasksreachable %d" % index)
	check(not WORLD.soil_contains_rect(WORLD.V3.plot_bounds(95)), "Original out-of-soil bottom row detected")
	check(not WORLD.soil_contains_rect(Rect2(400,370,60,60)), "Road tile rejected independently of logical field rectangle")
	check(not WORLD.water_contains(Vector2(376.5,258)), "Pier point previously classified as water rejected")
	check(not WORLD.water_contains(Vector2(376.5,160.8)), "Boat point previously classified as water rejected")
	check(WORLD.water_contains(Vector2(800,240)), "Open water accepted")
	check(not WORLD.fish_position_safe(Vector2(240,290)), "Fish wholebody excluded near curved bank")
	for index in range(320):
		var point: Vector2 = WORLD.sample_fish_position(float(index) / 320, float((index * 37) % 320) / 320)
		check(WORLD.fish_position_safe(point), "All sampled whole fish safe %d" % index)
	for point in [Vector2(0,0), Vector2(376.5,258), Vector2(376.5,160.8), Vector2(1490,400), Vector2(800,240), Vector2(INF,NAN)]:
		var projected: Vector2 = WORLD.project_fish_position(point)
		check(WORLD.fish_position_safe(projected), "Projection produces fullbody safe point %s" % point)
		check(projected == WORLD.project_fish_position(point), "Projection deterministic %s" % point)
	check(WORLD.project_fish_position(Vector2(800,240)) == Vector2(800,240), "Existing valid fish is not moved")
	var intervals: Array = WORLD.net_segment_intervals(Vector2(100,260), Vector2(800,260))
	check(not intervals.is_empty() and intervals[0].x > 0.35, "Net path excludes the pier and land")
	for interval in intervals:
		check(WORLD.water_contains(Vector2(100,260).lerp(Vector2(800,260),(interval.x + interval.y)*0.5)), "Every clipped net segment is water")
	for slot in range(3): check(WORLD.is_walkable("pond",WORLD.farmer_idle_position("pond",slot)), "Three dock worker feet fit real boards")
	check(WORLD.is_walkable("pond", WORLD.POND_DOCK), "Original dock workpoint remains usable")
	check(not WORLD.is_walkable("pond", Vector2(800,240)), "Workers cannot enter actual water")
	for endpoints in [[Vector2(280,60), Vector2(1480,480)], [WORLD.POND_DOCK, Vector2(120,240)]]:
		var route: Array = WORLD.find_path("pond",endpoints[0],endpoints[1])
		check(not route.is_empty(), "Shore or pier navigation remains reachable %s" % str(endpoints))
		var origin: Vector2 = endpoints[0]
		for waypoint in route:
			check(WORLD.segment_walkable("pond",origin,waypoint), "Full walker route avoids water")
			origin = waypoint
	var sites := {}
	for index in range(1000):
		var input := Vector2((index*83)%2200-100,(index*37)%700-100)
		var point: Vector2 = WORLD.product_drop_position(input)
		check(WORLD.is_walkable("ranch",point), "Drop lattice always on reachable pasture")
		check(point == WORLD.product_drop_position(input), "Drop lattice deterministic")
		sites[point] = true
	check(sites.size() <= 522, "Drop sprites bounded by finite 58x9 lattice")
	_test_motion()
	if failures.is_empty(): print("WORLD_LAYOUT_V4_PASS: %d assertions" % assertions)
	else:
		for failure in failures: printerr("FAIL: "+failure)
	quit(0 if failures.is_empty() else 1)

func _test_motion() -> void:
	var fish: Array = []
	for index in range(36):
		var point: Vector2 = WORLD.sample_fish_position(float(index)/36, float((index*7)%36)/36)
		var item := {"id":"fish_%d"%index,"type_id":["silver_fish","blueback_fish","goldstripe_fish"][index%3],"x":point.x,"y":point.y}
		MOTION.initialize(item)
		fish.append(item)
	var state := {"fish":fish,"rng":{"fish":12345},"coins":999}
	var starts := fish.duplicate(true)
	var continuation := {}
	for frame in range(300):
		MOTION.step(state,0.2)
		for item in state.fish:
			check(MOTION.validate(item).is_empty(), "60s continuous wholebody/persistedroute safe %s frame%d"%[item.id,frame])
		if frame==149: continuation=JSON.parse_string(JSON.stringify(state))
		elif frame>149: MOTION.step(continuation,0.2)
	check(JSON.stringify(state.fish)==JSON.stringify(continuation.fish), "Save/reload at30s exactly reproduces remaining30s motion")
	check(state.rng.fish==12345 and state.coins==999, "Movement never touches economy RNG or money")
	for index in range(36): check(Vector2(state.fish[index].x,state.fish[index].y).distance_to(Vector2(starts[index].x,starts[index].y))>1, "All fish visibly move %d"%index)
	var bad:Dictionary=state.fish[0].duplicate(true)
	bad.target={"x":376.5,"y":258.0}
	check(not MOTION.validate(bad).is_empty(), "Saved trajectory into pier rejected")
