class_name FarmWaterRegion
extends RefCounted

## Hand-authored against the immutable 1536x512 v0.8.1 pond plate.
## These deliberately conservative boundaries exclude reeds, shore stones,
## the boat and pier. They are asset geometry, never colour segmentation.
const BACKGROUND_SHA256 := "9d71928cb83fc208c44a0403048e33901886232ee66b776ad59229f175e88788"
const FISH_SIZE := Vector2(46, 30)
const FISH_MARGIN := 3.0
const SAMPLE_STEP := 24.0
const OUTLINE := [Vector2(416,114), Vector2(532,88), Vector2(660,70), Vector2(808,62),
	Vector2(950,70), Vector2(1090,91), Vector2(1230,110), Vector2(1336,146),
	Vector2(1432,206), Vector2(1444,270), Vector2(1404,314), Vector2(1296,360),
	Vector2(1174,392), Vector2(1040,414), Vector2(928,420), Vector2(818,406),
	Vector2(718,399), Vector2(616,404), Vector2(508,383), Vector2(430,389),
	Vector2(330,365), Vector2(258,337), Vector2(220,298), Vector2(252,241),
	Vector2(278,198), Vector2(340,144)]
const BOAT := [Vector2(266,113), Vector2(299,98), Vector2(403,142),
	Vector2(413,178), Vector2(392,201), Vector2(324,194), Vector2(286,173)]
const DOCK := [Vector2(104,207), Vector2(158,196), Vector2(249,211),
	Vector2(304,231), Vector2(420,265), Vector2(427,317), Vector2(393,350),
	Vector2(320,336), Vector2(251,312), Vector2(178,294), Vector2(124,269)]
## Walkable boards are narrower than the fish exclusion (posts and nets).
const WALK_DOCK := [Vector2(124,221), Vector2(169,211), Vector2(243,228),
	Vector2(305,251), Vector2(409,274), Vector2(415,310), Vector2(385,335),
	Vector2(320,315), Vector2(238,291), Vector2(172,271), Vector2(129,254)]
const BOUNDS := Rect2(220, 62, 1224, 358)
static var _sample_cells: Array[Rect2] = []
static var _sample_ready := false
static var _walker_nodes: Dictionary = {}

static func contains(point: Vector2) -> bool:
	if not point.is_finite() or not BOUNDS.has_point(point): return false
	return Geometry2D.is_point_in_polygon(point, PackedVector2Array(OUTLINE)) and not Geometry2D.is_point_in_polygon(point, PackedVector2Array(BOAT)) and not Geometry2D.is_point_in_polygon(point, PackedVector2Array(DOCK))

static func fish_safe(point: Vector2, size: Vector2 = FISH_SIZE) -> bool:
	if not point.is_finite() or not size.is_finite() or size.x <= 0 or size.y <= 0: return false
	return polygon_safe(_rect_points(Rect2(point - size * 0.5, size).grow(FISH_MARGIN)))

static func fish_segment_safe(start: Vector2, finish: Vector2, size: Vector2 = FISH_SIZE) -> bool:
	if not start.is_finite() or not finish.is_finite() or not size.is_finite() or size.x <= 0 or size.y <= 0: return false
	var corners := _rect_points(Rect2(start - size * 0.5, size).grow(FISH_MARGIN))
	corners.append_array(_rect_points(Rect2(finish - size * 0.5, size).grow(FISH_MARGIN)))
	return polygon_safe(Geometry2D.convex_hull(corners))

static func polygon_safe(polygon: PackedVector2Array) -> bool:
	for point in polygon:
		if not contains(point): return false
	for boundary in [OUTLINE, BOAT, DOCK]:
		for index in range(polygon.size()):
			for edge in range(boundary.size()):
				if Geometry2D.segment_intersects_segment(polygon[index], polygon[(index + 1) % polygon.size()], boundary[edge], boundary[(edge + 1) % boundary.size()]) != null: return false
	# A hull can surround an entire excluded object without crossing its edges.
	for hole in [BOAT, DOCK]:
		if Geometry2D.is_point_in_polygon(hole[0], polygon): return false
	return true

static func sample(u: float, v: float) -> Vector2:
	_prepare_samples()
	if _sample_cells.is_empty(): return Vector2(INF, INF)
	var scaled := clampf(u if is_finite(u) else 0.5, 0.0, 0.999999) * _sample_cells.size()
	var cell: Rect2 = _sample_cells[floori(scaled)]
	return cell.position + Vector2((scaled - floorf(scaled)) * cell.size.x, clampf(v if is_finite(v) else 0.5, 0, 1) * cell.size.y)

static func project(point: Vector2) -> Vector2:
	if fish_safe(point): return point
	_prepare_samples()
	if _sample_cells.is_empty(): return Vector2(INF, INF)
	var origin := point if point.is_finite() else Vector2(832, 256)
	var best := Vector2(INF, INF)
	var distance := INF
	for cell in _sample_cells:
		var candidate := Vector2(clampf(origin.x, cell.position.x, cell.end.x), clampf(origin.y, cell.position.y, cell.end.y))
		var next := origin.distance_squared_to(candidate)
		if next < distance:
			best = candidate
			distance = next
	return best

static func _prepare_samples() -> void:
	if _sample_ready: return
	_sample_ready = true
	for y in range(80, 420, int(SAMPLE_STEP)):
		for x in range(240, 1440, int(SAMPLE_STEP)):
			var center := Vector2(x, y)
			# Every point in this cell remains safe for the full fish body.
			if fish_safe(center, FISH_SIZE + Vector2(SAMPLE_STEP, SAMPLE_STEP)):
				_sample_cells.append(Rect2(center - Vector2.ONE * SAMPLE_STEP * 0.5, Vector2.ONE * SAMPLE_STEP))

## Exact intervals on [0,1], including holes. Used for net path clipping.
static func segment_intervals(start: Vector2, finish: Vector2) -> Array[Vector2]:
	var result: Array[Vector2] = []
	if not start.is_finite() or not finish.is_finite(): return result
	if start.is_equal_approx(finish):
		if contains(start): result.append(Vector2(0, 1))
		return result
	var cuts: Array[float] = [0.0, 1.0]
	var difference := finish - start
	for boundary in [OUTLINE, BOAT, DOCK]:
		for edge in range(boundary.size()):
			var intersection: Variant = Geometry2D.segment_intersects_segment(start, finish, boundary[edge], boundary[(edge + 1) % boundary.size()])
			if intersection != null: cuts.append(clampf((intersection - start).dot(difference) / difference.length_squared(), 0, 1))
	cuts.sort()
	for index in range(cuts.size() - 1):
		if cuts[index + 1] - cuts[index] <= 0.000001: continue
		if contains(start.lerp(finish, (cuts[index] + cuts[index + 1]) * 0.5)):
			result.append(Vector2(cuts[index], cuts[index + 1]))
	return result

static func walker_safe(point: Vector2, radius := 8.0) -> bool:
	if not point.is_finite() or not is_finite(radius) or radius < 0: return false
	var footprint := _rect_points(Rect2(point - Vector2.ONE * radius, Vector2.ONE * radius * 2))
	return _walk_polygon_safe(footprint)

static func walker_segment_safe(start: Vector2, finish: Vector2, radius := 8.0) -> bool:
	if not start.is_finite() or not finish.is_finite() or not is_finite(radius) or radius < 0: return false
	var corners := _rect_points(Rect2(start - Vector2.ONE * radius, Vector2.ONE * radius * 2))
	corners.append_array(_rect_points(Rect2(finish - Vector2.ONE * radius, Vector2.ONE * radius * 2)))
	return _walk_polygon_safe(Geometry2D.convex_hull(corners))

static func _walk_polygon_safe(polygon: PackedVector2Array) -> bool:
	if absf(_area(polygon)) < 0.00001:
		return not Geometry2D.is_point_in_polygon(polygon[0], PackedVector2Array(OUTLINE)) or Geometry2D.is_point_in_polygon(polygon[0], PackedVector2Array(WALK_DOCK))
	var overlap := Geometry2D.intersect_polygons(polygon, PackedVector2Array(OUTLINE))
	var blocked_area := 0.0
	for region in overlap:
		blocked_area += absf(_area(region))
		for boards in Geometry2D.intersect_polygons(region, PackedVector2Array(WALK_DOCK)):
			blocked_area -= absf(_area(boards))
	return blocked_area <= 0.01

static func walker_nodes(radius := 8.0) -> Array[Vector2]:
	var key := snappedf(radius, 0.001)
	if _walker_nodes.has(key): return _walker_nodes[key].duplicate()
	var result: Array[Vector2] = []
	for polygon in Geometry2D.offset_polygon(PackedVector2Array(OUTLINE), radius * 1.42 + 4.0):
		for point in polygon:
			if walker_safe(point, radius): result.append(point)
	for point in [Vector2(150,236), Vector2(200,250), Vector2(250,269), Vector2(300,287), Vector2(350,304), Vector2(384,288)]:
		if walker_safe(point, radius): result.append(point)
	_walker_nodes[key] = result
	return result.duplicate()

static func _rect_points(rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])

static func _area(polygon: PackedVector2Array) -> float:
	var area := 0.0
	for index in range(polygon.size()): area += polygon[index].cross(polygon[(index + 1) % polygon.size()])
	return area * 0.5
