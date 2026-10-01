extends SceneTree

const ART = preload("res://scripts/pixel_assets.gd")
const VIEW = preload("res://scripts/farm_view.gd")
const MODEL = preload("res://scripts/game_state.gd")
var failures: Array[String] = []
var assertions := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, detail: String) -> void:
	assertions += 1
	if not condition: failures.append(detail)

func _run() -> void:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/production.json"))
	for kind in ["crops", "animals", "products", "fish"]:
		var entries: Array = config[kind].values() if config[kind] is Dictionary else config[kind]
		for entry in entries:
			var id := str(entry.id)
			var mapped: bool = id in ART.CROP_IDS or id in ART.ANIMAL_IDS or id in ART.PRODUCT_IDS
			check(mapped, "Actual configuration ID has an atlas cell: " + id)
			var texture: Texture2D = ART.icon("animal" if kind == "animals" else "item", id)
			check(texture != null and texture.get_size() == Vector2(32, 32), "Normalized 32px icon: " + id)
			check(texture == ART.icon("animal" if kind == "animals" else "item", id), "Shared region cache: " + id)
	check(ART.icon("animal", "cow") != ART.icon("animal", "goat") and ART.icon("animal", "cow") != ART.icon("animal", "dinosaur"), "Cow, goat and dinosaur use different regions")
	check(ART.icon("item", "pumpkin") != ART.icon("item", "blueberry"), "Pumpkin and blueberry use different regions")
	check(ART.farmer("walk", 0) != ART.farmer("water", 0) and ART.farmer("walk", 0) != ART.farmer("walk", 0, true), "Farmer directions and actions use separate frames")
	check(ART.farmer("harvest", 4) == ART.farmer("harvest", 0), "Animation frame wraps at four frames")
	check(ART.terrain("soil") != ART.terrain("wet_soil") and ART.terrain("grass") == ART.terrain("grass"), "Wet ground is distinct and terrain cache is shared")
	var model = MODEL.new(config)
	var view = VIEW.new()
	root.add_child(view)
	view.configure(config)
	view.set_model(model.state, true)
	view._scene_cache_ready = true
	view.set_model(model.state)
	check(view._scene_cache_ready, "Unchanged displayed second preserves static draw cache")
	view.set_model(model.state, true)
	check(not view._scene_cache_ready, "Committed action forces immediate redraw")
	view.set_desktop_suspended(true)
	check(not view.is_processing() and not view._animation_layer.visible, "Desktop hide suspends drawing and animation")
	var before := JSON.stringify(model.snapshot())
	view.set_scene("ranch")
	view.set_scene("pond")
	view.set_scene("farm")
	check(JSON.stringify(model.snapshot()) == before, "Cosmetic view changes never modify simulation or save state")
	view.set_desktop_suspended(false)
	check(view.is_processing() and view._animation_layer.visible and not view._scene_cache_ready, "Desktop restore resumes animation and refreshes scene")
	view.queue_free()
	await process_frame
	if failures.is_empty():
		print("PIXEL_ART_PASS: %d mapping/cache/visibility assertions" % assertions)
		quit(0)
	else:
		for failure in failures: printerr("FAIL: " + failure)
		quit(1)
