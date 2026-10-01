class_name FarmWorldLayout
extends RefCounted

## Fixed simulation coordinates. All actor positions are feet, independent of
## display size, DPI, scrolling and the view's rendering scale.
const WORLD_HEIGHT := 172.0
const FARM_WIDTH := 1152.0
const RANCH_WIDTH := 1920.0
const POND_WIDTH := 1152.0
const PLOT_COUNT := 96
const SHELTER_IDS := ["chicken_coop", "duck_coop", "rabbit_hutch", "cow_barn", "goat_barn", "sheep_pen", "pig_pen"]
const ANIMAL_SHELTERS := {
	"chicken": "chicken_coop", "void_chicken": "chicken_coop", "golden_chicken": "chicken_coop",
	"duck": "duck_coop", "dinosaur": "duck_coop", "rabbit": "rabbit_hutch",
	"cow": "cow_barn", "ostrich": "cow_barn", "goat": "goat_barn",
	"sheep": "sheep_pen", "pig": "pig_pen",
}
const STORAGE_ORIGIN := Vector2(1768, 0)
const POND_DOCK := Vector2(128, 112)

static func world_size(scene: String) -> Vector2:
	match scene:
		"farm": return Vector2(FARM_WIDTH, WORLD_HEIGHT)
		"ranch": return Vector2(RANCH_WIDTH, WORLD_HEIGHT)
		"pond": return Vector2(POND_WIDTH, WORLD_HEIGHT)
	return Vector2.ZERO

static func is_position_valid(scene: String, position: Vector2) -> bool:
	var size := world_size(scene)
	return size.x > 0.0 and position.is_finite() and position.x >= 0.0 and position.y >= 0.0 and position.x < size.x and position.y < size.y

## Top-left corner of a 32x32 crop plot: 3 rows, up to 32 columns.
static func plot_position(index: int) -> Vector2:
	return Vector2(64 + floori(float(index) / 3.0) * 32, 20 + (index % 3) * 32)

## Top-left corner of the existing 28x28 grass cell, on a 30px grid.
static func grass_position(index: int) -> Vector2:
	return Vector2(24 + (index % 24) * 30, 28 + floori(float(index) / 24.0) * 30)

## Building module origin, shared with the renderer's 128px barn drawing.
static func shelter_position(shelter_id: String) -> Vector2:
	var index := SHELTER_IDS.find(shelter_id)
	return Vector2(760 + maxi(0, index) * 144, 0)

static func farmer_idle_position(scene: String, index: int) -> Vector2:
	var slot := clampi(index, 0, 2)
	match scene:
		"farm": return Vector2(24 + slot * 16, 136)
		"ranch": return Vector2(24 + slot * 18, 156)
		"pond": return POND_DOCK + Vector2((slot - 1) * 16, 0)
	return Vector2.ZERO

## Animal sprite anchor within its shelter's fixed 4x3 paddock. Ordering is
## the persisted animal-list order within that shelter, matching the view.
static func animal_position(target: String, state: Dictionary) -> Vector2:
	var animals: Array = state.get("animals", [])
	var chosen: Dictionary = {}
	for animal in animals:
		if str(animal.get("id", "")) == target:
			chosen = animal
			break
	if chosen.is_empty():
		return farmer_idle_position("ranch", 0)
	var shelter := _animal_shelter(chosen)
	if not SHELTER_IDS.has(shelter):
		return farmer_idle_position("ranch", 0)
	var slot := 0
	for animal in animals:
		if str(animal.get("id", "")) == target:
			break
		if _animal_shelter(animal) == shelter:
			slot += 1
	slot = clampi(slot, 0, 11)
	return shelter_position(shelter) + Vector2(6 + (slot % 4) * 30, 62 + floori(float(slot) / 4.0) * 27)

static func target_position(scene: String, target: String, state: Dictionary) -> Vector2:
	match scene:
		"farm":
			var index := _target_index(state.get("plots", []), target)
			if index >= 0:
				return plot_position(clampi(index, 0, PLOT_COUNT - 1)) + Vector2(16, 32)
		"ranch":
			if target == "trough": return STORAGE_ORIGIN + Vector2(65, 72)
			if target == "warehouse": return STORAGE_ORIGIN + Vector2(65, 120)
			if SHELTER_IDS.has(target): return shelter_position(target) + Vector2(106, 126)
			var index := _target_index(state.get("grass", []), target)
			if index >= 0:
				return grass_position(clampi(index, 0, PLOT_COUNT - 1)) + Vector2(14, 28)
			for animal in state.get("animals", []):
				if str(animal.get("id", "")) == target:
					if SHELTER_IDS.has(_animal_shelter(animal)):
						return animal_position(target, state) + Vector2(26, 26)
		"pond":
			return POND_DOCK
	return farmer_idle_position(scene, 0)

static func _target_index(entries: Array, target: String) -> int:
	for entry in entries:
		if str(entry.get("id", "")) == target:
			# Version 2 uses a global index; legacy region coordinates are migrated
			# by the model before simulation or drawing consumes the state.
			return int(entry.get("global_index", entry.get("globalindex", entry.get("index", -1))))
	return -1

static func _animal_shelter(animal: Dictionary) -> String:
	var explicit := str(animal.get("shelter_id", animal.get("shelter", "")))
	if not explicit.is_empty(): return explicit
	return str(ANIMAL_SHELTERS.get(str(animal.get("type_id", animal.get("type", ""))), ""))
