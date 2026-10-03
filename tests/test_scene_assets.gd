extends SceneTree

const Assets = preload("res://scripts/scene_assets.gd")
var assertions := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition: failures.append(message)

func _run() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Assets.ROOT + "manifest.json"))
	check(not manifest.is_empty() and manifest.source_preserved and manifest.generator == "OpenAI imagegen", "Runtime manifest records original imagegen provenance")
	for kind in ["animals", "young", "actions"]:
		check(int(manifest.atlases[kind].columns) == 20 and int(manifest.atlases[kind].cells) == 220, "Every animal sheet exposes five runtime frames in four directions: " + kind)
		var counts: Array = manifest.atlases[kind].authored_direction_frames
		check(int(manifest.atlases[kind].authored_columns) == 19 and counts.size() == 4 and int(counts[0]) == 5 and int(counts[1]) == 5 and int(counts[2]) == 5 and int(counts[3]) == 4, "Manifest preserves the inspected nineteen-pose source instead of claiming twenty original poses: " + kind)
		_validate_alpha(kind, Assets.ANIMAL_CELL)
	for id in ["cow", "goat", "sheep", "pig"]:
		check(manifest.atlases.has(id), "Every large animal has an independent complete walk atlas: " + id)
		if manifest.atlases.has(id):
			_validate_alpha(id, Assets.ANIMAL_CELL)
			var source_image := Image.load_from_file(ProjectSettings.globalize_path(Assets.ROOT + id + "-atlas.png"))
			for row in range(4):
				var hashes := {}
				for column in range(4):
					var frame := source_image.get_region(Rect2i(column * 96, row * 96, 96, 96))
					hashes[hash(frame.get_data())] = true
					check(Assets.animal(id, Assets.DIRECTIONS[row], column).get_region().position == Vector2(column * 96, row * 96), "Direction and phase use the independent authored cell: " + id)
				check(hashes.size() == 4, "Four actual distinct phases per large animal direction: " + id + " " + Assets.DIRECTIONS[row])
	_validate_alpha("crops", Assets.CROP_CELL)
	_validate_alpha("farmer", Assets.FARMER_CELL)
	_validate_alpha("nature", Assets.NATURE_CELL)
	for scene in ["farm", "ranch", "pond"]:
		var texture := Assets.background(scene)
		check(texture != null and texture.get_height() == 512 and texture.get_width() == (1920 if scene == "ranch" else 1536), "Background matches scene world bounds without runtime resampling: " + scene)
		check(Assets.loaded_background_scene() == scene, "Only the current background is kept in the scene cache")
	Assets.release_background()
	check(Assets.loaded_background_scene().is_empty(), "Switching/closing a scene can release its large background")
	for id in Assets.CROP_IDS:
		for stage in range(4):
			var texture := Assets.crop(id, stage)
			check(texture != null and Vector2i(texture.get_size()) == Assets.CROP_CELL, "Real authored crop growth cell exists: %s stage %d" % [id, stage])
	for id in Assets.ANIMAL_IDS:
		for direction in Assets.DIRECTIONS:
			for frame in range(5):
				check(Assets.animal(id, direction, frame) != null and Assets.animal(id, direction, frame, true) != null and Assets.animal(id, direction, frame, false, true) != null, "Adult, juvenile and eating frame all exist: %s %s %d" % [id, direction, frame])
	check(Assets.animal("chicken", "down", 5) == Assets.animal("chicken", "down", 0), "Five-frame animation wraps to the first frame")
	check(Assets.crop("missing", 3) == null and Assets.animal("missing") == null, "Unknown IDs never silently display another species")
	for action in ["idle", "walking", "water", "sow", "harvest", "collect_product", "cut_grass", "pet"]:
		for direction in Assets.DIRECTIONS:
			check(Assets.farmer(action, direction, 0) != null, "Farmer pose is available for active work: " + action + " " + direction)
	for fish in Assets.FISH_IDS:
		for frame in range(4): check(Assets.fish(fish, frame) != null, "Authored transparent fish frame exists: " + fish)
	for variant in range(4): check(Assets.grass(variant) != null, "Natural grass silhouette exists for clump state")
	check(Assets.crop("parsnip", 3) == Assets.crop("parsnip", 3), "Repeated draws reuse the same immutable atlas region")
	Assets.release_all()
	if failures.is_empty():
		print("SCENE_ASSETS_PASS: %d source/layout/alpha/cache assertions" % assertions)
		quit(0)
	else:
		for failure in failures: printerr("FAIL: " + failure)
		quit(1)

func _validate_alpha(kind: String, cell: Vector2i) -> void:
	var image := Image.load_from_file(ProjectSettings.globalize_path(Assets.ROOT + kind + "-atlas.png"))
	check(image != null and not image.is_empty() and image.detect_alpha() != Image.ALPHA_NONE, "Scene sprite atlas has true transparency: " + kind)
	if image == null or image.is_empty(): return
	var rows: int = image.get_height() / cell.y
	var columns: int = image.get_width() / cell.x
	for row in range(rows):
		for column in range(columns):
			var area := Rect2i(column * cell.x, row * cell.y, cell.x, cell.y)
			var sprite := image.get_region(area)
			var used := sprite.get_used_rect()
			check(used.size.x > 0 and used.size.y > 0, "Baked cell is visible: %s %d,%d" % [kind, column, row])
			check(sprite.get_pixel(0, 0).a == 0 and sprite.get_pixel(cell.x - 1, cell.y - 1).a == 0, "Cell padding remains transparent: %s %d,%d" % [kind, column, row])
			check(used.position.x >= 1 and used.end.x <= cell.x - 1 and used.end.y <= cell.y - 1, "Trimmed sprite does not bleed into a neighbor: %s %d,%d" % [kind, column, row])
