class_name FarmFishMotion
extends RefCounted

## Authoritative v4 movement. Persistent short segments, independent of view,
## camera and frame rate. ID/counter sampling never touches economy RNG.
const WORLD = preload("res://scripts/world_layout.gd")

static func initialize(fish: Dictionary) -> void:
	var point := WORLD.project_fish_position(Vector2(float(fish.get("x", 832)), float(fish.get("y", 256)))).snapped(Vector2.ONE * 0.000001)
	fish.x = point.x
	fish.y = point.y
	fish.previous_x = point.x
	fish.previous_y = point.y
	fish.target = {"x": point.x, "y": point.y}
	fish.heading = 0.0
	fish.phase = 0.0
	fish.swim_index = 0
	_choose_target(fish)

static func step(state: Dictionary, dt: float) -> void:
	if not is_finite(dt) or dt <= 0: return
	for fish in state.get("fish", []):
		fish.previous_x = fish.x
		fish.previous_y = fish.y
		fish.phase = snappedf(float(fish.phase) + dt, 0.000001)
		var remaining := dt
		for unused in range(16):
			if remaining <= 0.000001: break
			var origin := position(fish)
			var destination := position(fish.target)
			var difference := destination - origin
			var distance := difference.length()
			if distance < 0.01:
				_choose_target(fish)
				destination = position(fish.target)
				difference = destination - origin
				distance = difference.length()
				if distance < 0.01: break
			var speed := (16.0 + absi(str(fish.id).hash()) % 8) * (0.72 + minf(distance / 28.0, 1.0) * 0.28)
			var used := minf(remaining, distance / speed)
			var next := origin.move_toward(destination, used * speed)
			# The entire saved target segment was validated when selected.
			fish.x = snappedf(next.x, 0.000001)
			fish.y = snappedf(next.y, 0.000001)
			fish.heading = snappedf(difference.angle(), 0.000001)
			remaining -= used
			# One saved interpolation interval must stay on one proven segment.
			# Defer the next turn until the next fixed simulation step.
			if distance <= used * speed + 0.000001: break

static func _choose_target(fish: Dictionary) -> void:
	var origin := position(fish)
	var index := int(fish.swim_index)
	var seed := absi((str(fish.id) + ":" + str(index)).hash())
	for attempt in range(16):
		var angle := float(seed % 6283) * 0.001 + attempt * 2.399963
		var distance := maxf(8, (36 + seed % 85) * pow(0.86, attempt / 3))
		var target := (origin + Vector2(cos(angle), sin(angle)) * distance).snapped(Vector2.ONE * 0.000001)
		if WORLD.fish_segment_safe(origin, target):
			fish.target = {"x": target.x, "y": target.y}
			fish.swim_index = index + 1
			return
	fish.target = {"x": origin.x, "y": origin.y}
	fish.swim_index = index + 1

static func position(object: Dictionary) -> Vector2:
	return Vector2(float(object.get("x", 0)), float(object.get("y", 0)))

static func validate(fish: Dictionary) -> String:
	for key in ["x", "y", "previous_x", "previous_y", "heading", "phase", "swim_index"]:
		if not _number(fish.get(key)): return "鱼游动数值无效"
	if float(fish.phase) < 0 or float(fish.swim_index) < 0 or float(fish.swim_index) != floorf(float(fish.swim_index)) or absf(float(fish.heading)) > PI + 0.000001: return "鱼游动阶段无效"
	if not fish.get("target") is Dictionary or not _number(fish.target.get("x")) or not _number(fish.target.get("y")): return "鱼游动目标无效"
	var current := position(fish)
	var previous := Vector2(float(fish.previous_x), float(fish.previous_y))
	if not WORLD.fish_position_safe(current) or not WORLD.fish_segment_safe(previous, current) or not WORLD.fish_segment_safe(current, position(fish.target)): return "鱼身或游动路径越出真实水面"
	return ""

static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))
