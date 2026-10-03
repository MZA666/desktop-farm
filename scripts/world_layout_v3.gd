class_name FarmWorldLayoutV3
extends RefCounted

## Stable simulation coordinates measured at actor feet. Camera, display
## mode and DPI never change these coordinates or the model's persisted IDs.
const LAYOUT_VERSION := 3
const WORLD_HEIGHT := 512.0
const FARM_WIDTH := 1536.0
const RANCH_WIDTH := 1920.0
const POND_WIDTH := 1536.0
const PLOT_COUNT := 96
const PLOT_COLUMNS := 16
const PLOT_ROWS := 6
const PLOT_SIZE := 56.0
const PLOT_ORIGIN := Vector2(352, 112)
const GRASS_COUNT := 96
const GRASS_COLUMNS := 24
const STORAGE_ORIGIN := Vector2(1760, 32)
const POND_WATER := Rect2(320, 96, 1130, 324)
const POND_DOCK_RECT := Rect2(240, 224, 176, 88)
const POND_DOCK := Vector2(384, 288)
const ACTOR_RADIUS := 8.0
const SHELTER_IDS := ["chicken_coop", "duck_coop", "rabbit_hutch", "cow_barn", "goat_barn", "sheep_pen", "pig_pen"]
const ANIMAL_SHELTERS := {
	"chicken": "chicken_coop", "void_chicken": "chicken_coop", "golden_chicken": "chicken_coop",
	"duck": "duck_coop", "dinosaur": "duck_coop", "rabbit": "rabbit_hutch",
	"cow": "cow_barn", "ostrich": "cow_barn", "goat": "goat_barn",
	"sheep": "sheep_pen", "pig": "pig_pen",
}

static func world_size(scene: String) -> Vector2:
	match scene:
		"farm": return Vector2(FARM_WIDTH, WORLD_HEIGHT)
		"ranch": return Vector2(RANCH_WIDTH, WORLD_HEIGHT)
		"pond": return Vector2(POND_WIDTH, WORLD_HEIGHT)
	return Vector2.ZERO

static func is_position_valid(scene: String, position: Vector2) -> bool:
	var size := world_size(scene)
	return size.x > 0.0 and position.is_finite() and position.x >= 0.0 and position.y >= 0.0 and position.x < size.x and position.y < size.y

## Row-major index; the 96 legacy plot_*_* IDs remain unchanged in the model.
static func plot_position(index: int) -> Vector2:
	var safe := clampi(index, 0, PLOT_COUNT - 1)
	return PLOT_ORIGIN + Vector2((safe % PLOT_COLUMNS) * PLOT_SIZE, (safe / PLOT_COLUMNS) * PLOT_SIZE)

static func plot_bounds(index: int) -> Rect2:
	return Rect2(plot_position(index), Vector2(PLOT_SIZE, PLOT_SIZE))

static func field_bounds() -> Rect2:
	return Rect2(PLOT_ORIGIN, Vector2(PLOT_COLUMNS * PLOT_SIZE, PLOT_ROWS * PLOT_SIZE))

## Deterministic irregular sites consume no simulation RNG. Grass/animals
## are traversable pasture contents, never static collision boxes.
static func grass_anchor(index: int) -> Vector2:
	if index < 0 or index >= GRASS_COUNT: return Vector2.ZERO
	var column := index % GRASS_COLUMNS
	var row := index / GRASS_COLUMNS
	var jitter_x := ((index * 73 + 19) % 47) - 23
	var jitter_y := ((index * 37 + 11) % 43) - 21
	return Vector2(64 + column * 76 + jitter_x, 220 + row * 80 + jitter_y)

static func grass_position(index: int) -> Vector2:
	return grass_anchor(index) - Vector2(24, 40)

## Four stable neighbors preserve the accepted non-cascading spread rule.
static func grass_neighbors(index: int) -> Array[int]:
	var output: Array[int] = []
	if index < 0 or index >= GRASS_COUNT: return output
	if index >= GRASS_COLUMNS: output.append(index - GRASS_COLUMNS)
	if index + GRASS_COLUMNS < GRASS_COUNT: output.append(index + GRASS_COLUMNS)
	if index % GRASS_COLUMNS > 0: output.append(index - 1)
	if index % GRASS_COLUMNS < GRASS_COLUMNS - 1: output.append(index + 1)
	return output

static func shelter_position(shelter_id: String) -> Vector2:
	return Vector2(64 + maxi(0, SHELTER_IDS.find(shelter_id)) * 240, 24)

static func shelter_bounds(shelter_id: String) -> Rect2:
	return Rect2(shelter_position(shelter_id), Vector2(208, 136))

static func shelter_exit(shelter_id: String) -> Vector2:
	return shelter_position(shelter_id) + Vector2(104, 160)

static func shelter_entrance(shelter_id: String) -> Vector2:
	return shelter_exit(shelter_id)

static func pasture_bounds() -> Rect2:
	return Rect2(24, 192, RANCH_WIDTH - 48, 296)

static func trough_position() -> Vector2:
	return STORAGE_ORIGIN + Vector2(68, 160)

static func warehouse_position() -> Vector2:
	return STORAGE_ORIGIN + Vector2(68, 132)

static func water_bounds() -> Rect2:
	return POND_WATER

static func dock_bounds() -> Rect2:
	return POND_DOCK_RECT

static func farmer_idle_position(scene: String, index: int) -> Vector2:
	var slot := clampi(index, 0, 2)
	match scene:
		"farm": return Vector2(208 + slot * 32, 440)
		"ranch": return Vector2(88 + slot * 32, 192)
		"pond": return POND_DOCK + Vector2((slot - 1) * 16, 0)
	return Vector2.ZERO

## Impassable houses and water only. Splitting the water around the pier
## gives the same collision test to workers, animals and saved path checks.
static func obstacles(scene: String) -> Array[Rect2]:
	var output: Array[Rect2] = []
	match scene:
		"farm":
			output.append(Rect2(24, 24, 264, 168))
			output.append(Rect2(1376, 32, 112, 112))
		"ranch":
			for id in SHELTER_IDS: output.append(shelter_bounds(id))
			output.append(Rect2(STORAGE_ORIGIN, Vector2(136, 112)))
		"pond":
			output.append(Rect2(320, 96, 1130, 128))
			output.append(Rect2(320, 312, 1130, 108))
			output.append(Rect2(416, 224, 1034, 88))
	return output

static func navigation_bounds(scene: String) -> Rect2:
	var size := world_size(scene)
	return Rect2(Vector2(16, 16), size - Vector2(32, 32)) if size != Vector2.ZERO else Rect2()

static func is_walkable(scene: String, position: Vector2, radius: float = ACTOR_RADIUS) -> bool:
	if not position.is_finite() or radius < 0.0 or not is_finite(radius): return false
	var bounds := navigation_bounds(scene).grow(-radius)
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or not bounds.has_point(position): return false
	for rect in obstacles(scene):
		if rect.grow(radius).has_point(position): return false
	return true

static func segment_walkable(scene: String, start: Vector2, finish: Vector2, radius: float = ACTOR_RADIUS) -> bool:
	if not is_walkable(scene, start, radius) or not is_walkable(scene, finish, radius): return false
	for rect in obstacles(scene):
		if _segment_hits_rect(start, finish, rect.grow(radius)): return false
	return true

## Open pasture usually returns one segment. Blocked routes use a small
## deterministic visibility graph, with no per-frame grid or large texture.
## Excludes start/includes finish; [] means invalid, unreachable or arrived.
static func find_path(scene: String, start: Vector2, finish: Vector2, radius: float = ACTOR_RADIUS) -> Array[Vector2]:
	var empty: Array[Vector2] = []
	if not is_walkable(scene, start, radius) or not is_walkable(scene, finish, radius): return empty
	if start.distance_squared_to(finish) < 0.0001: return empty
	if segment_walkable(scene, start, finish, radius): return [finish]
	var nodes: Array[Vector2] = [start, finish]
	for rect in obstacles(scene):
		var grown := rect.grow(radius + 2.0)
		for corner in [grown.position, Vector2(grown.end.x, grown.position.y), grown.end, Vector2(grown.position.x, grown.end.y)]:
			if is_walkable(scene, corner, radius): nodes.append(corner)
	var distances: Array[float] = []
	var previous: Array[int] = []
	var closed: Array[bool] = []
	for unused in nodes:
		distances.append(INF)
		previous.append(-1)
		closed.append(false)
	distances[0] = 0.0
	for unused in nodes:
		var current := -1
		var best := INF
		for index in range(nodes.size()):
			var estimate := distances[index] + nodes[index].distance_to(finish)
			if not closed[index] and estimate < best:
				best = estimate
				current = index
		if current < 0: break
		if current == 1:
			var result: Array[Vector2] = []
			var cursor := 1
			while cursor > 0:
				result.push_front(nodes[cursor])
				cursor = previous[cursor]
				if cursor < 0: return empty
			return result
		closed[current] = true
		for index in range(1, nodes.size()):
			if closed[index] or index == current or not segment_walkable(scene, nodes[current], nodes[index], radius): continue
			var candidate := distances[current] + nodes[current].distance_to(nodes[index])
			if candidate < distances[index]:
				distances[index] = candidate
				previous[index] = current
	return empty

static func clamp_to_walkable(scene: String, position: Vector2, radius: float = ACTOR_RADIUS) -> Vector2:
	var bounds := navigation_bounds(scene).grow(-maxf(0.0, radius))
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0: return Vector2.ZERO
	var point := position if position.is_finite() else farmer_idle_position(scene, 0)
	point = Vector2(clampf(point.x, bounds.position.x, bounds.end.x - 0.01), clampf(point.y, bounds.position.y, bounds.end.y - 0.01))
	if is_walkable(scene, point, radius): return point
	var candidates: Array[Vector2] = [farmer_idle_position(scene, 0)]
	for rect in obstacles(scene):
		var grown := rect.grow(radius + 2.0)
		candidates.append(Vector2(grown.position.x, point.y))
		candidates.append(Vector2(grown.end.x, point.y))
		candidates.append(Vector2(point.x, grown.position.y))
		candidates.append(Vector2(point.x, grown.end.y))
		candidates.append(grown.position)
		candidates.append(grown.end)
		candidates.append(Vector2(grown.position.x, grown.end.y))
		candidates.append(Vector2(grown.end.x, grown.position.y))
	var selected := Vector2.ZERO
	var closest := INF
	for candidate in candidates:
		if is_walkable(scene, candidate, radius) and candidate.distance_squared_to(point) < closest:
			selected = candidate
			closest = candidate.distance_squared_to(point)
	return selected

## Actual roaming feet first; v2 fixed-paddock actors use their new doorway.
static func animal_position(target: String, state: Dictionary) -> Vector2:
	for animal in state.get("animals", []):
		if str(animal.get("id", "")) != target: continue
		if animal.has("x") and animal.has("y"):
			var saved := Vector2(float(animal.x), float(animal.y))
			if is_walkable("ranch", saved): return saved
		return shelter_exit(_animal_shelter(animal))
	return farmer_idle_position("ranch", 0)

static func target_position(scene: String, target: String, state: Dictionary) -> Vector2:
	match scene:
		"farm":
			var index := _target_index(state.get("plots", []), target)
			if index >= 0: return plot_position(index) + Vector2(PLOT_SIZE * 0.5, PLOT_SIZE)
		"ranch":
			if target == "trough": return trough_position()
			if target == "warehouse": return warehouse_position()
			if SHELTER_IDS.has(target): return shelter_exit(target)
			for grass in state.get("grass", []):
				if str(grass.get("id", "")) != target: continue
				if grass.has("x") and grass.has("y"): return Vector2(float(grass.x), float(grass.y))
				return grass_anchor(int(grass.get("index", -1)))
			for animal in state.get("animals", []):
				if str(animal.get("id", "")) == target: return animal_position(target, state)
		"pond": return POND_DOCK
	return farmer_idle_position(scene, 0)

static func _target_index(entries: Array, target: String) -> int:
	for entry in entries:
		if str(entry.get("id", "")) == target:
			return int(entry.get("global_index", entry.get("globalindex", entry.get("index", -1))))
	return -1

static func _animal_shelter(animal: Dictionary) -> String:
	var explicit := str(animal.get("shelter_id", animal.get("shelter", "")))
	return explicit if not explicit.is_empty() else str(ANIMAL_SHELTERS.get(str(animal.get("type_id", animal.get("type", ""))), ""))

static func _segment_hits_rect(start: Vector2, finish: Vector2, rect: Rect2) -> bool:
	var low := 0.0
	var high := 1.0
	var delta := finish - start
	for axis in range(2):
		if absf(delta[axis]) < 0.00001:
			if start[axis] < rect.position[axis] or start[axis] > rect.end[axis]: return false
		else:
			var first := (rect.position[axis] - start[axis]) / delta[axis]
			var last := (rect.end[axis] - start[axis]) / delta[axis]
			low = maxf(low, minf(first, last))
			high = minf(high, maxf(first, last))
			if low > high: return false
	return true

## Frozen v0.8 coordinates, solely for migrating old walking tasks/saves.
static func legacy_world_size(scene: String) -> Vector2:
	return Vector2(1920 if scene == "ranch" else 1152, 172) if scene in ["farm", "ranch", "pond"] else Vector2.ZERO

static func legacy_plot_position(index: int) -> Vector2:
	return Vector2(64 + (index / 3) * 32, 20 + (index % 3) * 32)

static func legacy_grass_position(index: int) -> Vector2:
	return Vector2(24 + (index % 24) * 30, 28 + (index / 24) * 30)

static func legacy_shelter_position(shelter_id: String) -> Vector2:
	return Vector2(760 + maxi(0, SHELTER_IDS.find(shelter_id)) * 144, 0)

static func legacy_farmer_idle_position(scene: String, index: int) -> Vector2:
	var slot := clampi(index, 0, 2)
	match scene:
		"farm": return Vector2(24 + slot * 16, 136)
		"ranch": return Vector2(24 + slot * 18, 156)
		"pond": return Vector2(128 + (slot - 1) * 16, 112)
	return Vector2.ZERO

static func legacy_animal_position(target: String, state: Dictionary) -> Vector2:
	var shelter := ""
	var slot := 0
	for animal in state.get("animals", []):
		if str(animal.get("id", "")) == target:
			shelter = _animal_shelter(animal)
			break
	if shelter.is_empty(): return legacy_farmer_idle_position("ranch", 0)
	for animal in state.get("animals", []):
		if str(animal.get("id", "")) == target: break
		if _animal_shelter(animal) == shelter: slot += 1
	slot = clampi(slot, 0, 11)
	return legacy_shelter_position(shelter) + Vector2(6 + (slot % 4) * 30, 62 + (slot / 4) * 27)

static func legacy_target_position(scene: String, target: String, state: Dictionary) -> Vector2:
	match scene:
		"farm":
			var index := _target_index(state.get("plots", []), target)
			if index >= 0: return legacy_plot_position(index) + Vector2(16, 32)
		"ranch":
			if target == "trough": return Vector2(1833, 72)
			if target == "warehouse": return Vector2(1833, 120)
			if SHELTER_IDS.has(target): return legacy_shelter_position(target) + Vector2(106, 126)
			var index := _target_index(state.get("grass", []), target)
			if index >= 0: return legacy_grass_position(index) + Vector2(14, 28)
			for animal in state.get("animals", []):
				if str(animal.get("id", "")) == target: return legacy_animal_position(target, state) + Vector2(26, 26)
		"pond": return Vector2(128, 112)
	return legacy_farmer_idle_position(scene, 0)
