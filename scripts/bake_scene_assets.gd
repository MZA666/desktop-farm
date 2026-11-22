extends SceneTree

## Offline Godot image pipeline; original imagegen files are never modified.
const SOURCE := "res://assets/pixel/v0.8.1/source/"
const OUTPUT := "res://assets/pixel/v0.8.1/runtime/"
const ASSETS = preload("res://scripts/scene_assets.gd")
const DECOR = preload("res://scripts/farm_decor.gd")
const FARMER_WALK_SOURCE := "res://assets/pixel/v0.8.7/source/farmer-walk.png"
const FARMER_SIDE_SOURCE := "res://assets/pixel/v0.8.7/source/farmer-side-walk.png"
const DECOR_SOURCE := "res://assets/pixel/v0.8.4/source/farm-decorations.png"
const DECOR_CROPS := {
	"flower_box": Rect2i(78, 176, 492, 293),
	"scarecrow": Rect2i(730, 48, 422, 520),
	"stone_well": Rect2i(103, 675, 428, 546),
	"garden_lantern": Rect2i(761, 670, 359, 550),
}
const ALPHA_THRESHOLD := 24.0 / 255.0
const ANIMAL_ROWS := [0, 81, 163, 236, 333, 430, 515, 596, 684, 768, 853, 992]
const YOUNG_ROWS := [0, 83, 164, 242, 333, 430, 518, 597, 686, 769, 853, 992]
const ACTION_ROWS := [0, 86, 164, 236, 334, 430, 519, 598, 682, 771, 850, 992]
const ANIMAL_CENTERS := [52, 127, 204, 284, 358, 442, 525, 608, 688, 769, 857, 931, 1006, 1085, 1158, 1250, 1334, 1421, 1508]
const FARMER_ROWS := [0, 226, 439, 667, 881, 1117, 1325, 1545, 1774]
const CROP_ROWS := [0, 48, 108, 180, 292, 357, 423, 506, 609, 679, 748, 833, 932, 994, 1059, 1146, 1254]
var manifest := {"version": "0.8.1", "generator": "OpenAI imagegen", "source_preserved": true,
	"prompt_provenance": "Original generated pixel art; source images preserved. Generation requirements and large-animal prompts: assets/pixel/v0.8.1/generation-prompts.md. Full historical prompts are in the development conversation.",
	"resampling": "nearest", "trim_alpha_threshold": 24, "transparent_rgb_cleanup_alpha_max": 8,
	"anchor": "bottom-center, two pixels above the runtime cell bottom", "sources": {}, "atlases": {}}
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT)) != OK:
		printerr("Cannot create scene asset directory")
		quit(1)
		return
	for scene in ["farm", "ranch", "pond"]: _background(scene)
	_bake("animals", 20, ANIMAL_ROWS, ASSETS.ANIMAL_CELL, "row")
	_bake("young", 20, YOUNG_ROWS, ASSETS.ANIMAL_CELL, "row")
	_bake("actions", 20, ACTION_ROWS, ASSETS.ANIMAL_CELL, "row")
	_bake("farmer", 4, FARMER_ROWS, ASSETS.FARMER_CELL, "all")
	_bake_farmer_walk()
	_bake("crops", 16, CROP_ROWS, ASSETS.CROP_CELL, "crop")
	_bake("nature", 4, [0, 256, 512, 736, 1024], ASSETS.NATURE_CELL, "row")
	for id in ["cow", "goat", "sheep", "pig"]:
		if FileAccess.file_exists(SOURCE + "large-" + id + ".png"):
			_bake(id, 4, [0, 256, 512, 768, 1024], ASSETS.ANIMAL_CELL, "all", "large-" + id)
	_bake_decorations()
	var file := FileAccess.open(OUTPUT + "manifest.json", FileAccess.WRITE)
	if file == null: failures.append("Cannot save scene asset manifest")
	else:
		file.store_string(JSON.stringify(manifest, "\t"))
		file.close()
	if failures.is_empty():
		print("SCENE_ASSETS_BAKED runtime atlases verified; original layout recorded in manifest.json")
		quit(0)
	else:
		for failure in failures: printerr(failure)
		quit(1)

func _bake_farmer_walk() -> void:
	var main := _farmer_sheet_frames(FARMER_WALK_SOURCE, Vector2i(5, 3))
	var side := _farmer_sheet_frames(FARMER_SIDE_SOURCE, Vector2i(2, 2))
	if main.size() != 15 or side.size() != 4: return
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ASSETS.FARMER_WALK_ROOT)) != OK:
		failures.append("Cannot create farmer walk asset directory")
		return
	# Pair each planted forward foot with a passing pose on that same foot.
	# Mirror the back-view contact and pass to replace the repeated leg in the source.
	var right := [main[5], side[0], side[1], side[2], side[3]]
	var poses := [
		[main[0], main[1], _mirrored_sprite(main[2]), main[3], main[2]],
		right,
		[main[10], main[11], main[12], _mirrored_sprite(main[11]), _mirrored_sprite(main[12])],
		right.map(func(sprite): return _mirrored_sprite(sprite)),
	]
	var columns := ASSETS.FARMER_WALK_FRAMES + 1
	var cell: Vector2i = ASSETS.FARMER_CELL
	var atlas := Image.create(columns * cell.x, poses.size() * cell.y, false, Image.FORMAT_RGBA8)
	atlas.fill(Color.TRANSPARENT)
	for row in range(poses.size()):
		for column in range(columns):
			var sprite: Image = poses[row][column].duplicate()
			var hat := _bounds(sprite, Rect2i(0, 0, sprite.get_width(), roundi(sprite.get_height() * 0.34)))
			var height := 70 if column in [1, 3] else 72
			var scale := minf(float(cell.x - 4) / sprite.get_width(), float(height) / sprite.get_height())
			var size := Vector2i(roundi(sprite.get_width() * scale), roundi(sprite.get_height() * scale))
			var x := clampi(cell.x / 2 - roundi(hat.get_center().x * scale), 2, cell.x - size.x - 2)
			var offset := Vector2i(x, cell.y - size.y - 2)
			sprite.resize(size.x, size.y, Image.INTERPOLATE_NEAREST)
			atlas.blit_rect(sprite, Rect2i(Vector2i.ZERO, size), Vector2i(column, row) * cell + offset)
	_save_image(atlas, ASSETS.FARMER_WALK_ROOT + "farmer-walk-atlas.png")
	print("FARMER_WALK_BAKED: idle and four walking poses per direction")

func _farmer_sheet_frames(path: String, grid: Vector2i) -> Array[Image]:
	var source := Image.load_from_file(ProjectSettings.globalize_path(path))
	if source == null or source.is_empty():
		failures.append("Missing original farmer walk sheet: " + path)
		return []
	source.convert(Image.FORMAT_RGBA8)
	var output: Array[Image] = []
	var size := Vector2(source.get_size()) / Vector2(grid)
	for y in range(grid.y):
		for x in range(grid.x):
			var start := Vector2i(Vector2(x, y) * size)
			var finish := Vector2i(Vector2(x + 1, y + 1) * size)
			var components := _components(source, Rect2i(start, finish - start), 100)
			if components.is_empty():
				failures.append("Missing farmer pose at %s %d,%d" % [path, x, y])
				return []
			components.sort_custom(func(a, b): return a.pixels > b.pixels)
			output.append(components[0].image)
	return output

func _mirrored_sprite(image: Image) -> Image:
	var sprite := image.duplicate() as Image
	sprite.flip_x()
	return sprite

func _bake_decorations() -> void:
	var source := Image.load_from_file(ProjectSettings.globalize_path(DECOR_SOURCE))
	if source == null or source.get_size() != Vector2i(1254, 1254) or source.detect_alpha() == Image.ALPHA_NONE:
		failures.append("Missing or invalid decoration sprite sheet: " + DECOR_SOURCE)
		return
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ASSETS.DECOR_ROOT)) != OK:
		failures.append("Cannot create decoration asset directory")
		return
	for id in DECOR.ITEMS:
		var sprite := source.get_region(DECOR_CROPS[id])
		var bounds: Vector2 = DECOR.ITEMS[id].max_size
		var factor := minf(bounds.x / sprite.get_width(), bounds.y / sprite.get_height())
		sprite.resize(roundi(sprite.get_width() * factor), roundi(sprite.get_height() * factor), Image.INTERPOLATE_NEAREST)
		_save_image(sprite, ASSETS.DECOR_ROOT + id + ".png")

func _source(kind: String) -> Image:
	var path := SOURCE + kind + ".png"
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty():
		failures.append("Missing original scene asset: " + path)
		return null
	manifest.sources[kind] = {"path": path, "width": image.get_width(), "height": image.get_height(), "sha256": FileAccess.get_sha256(path)}
	image.convert(Image.FORMAT_RGBA8)
	return image

func _background(scene: String) -> void:
	var image := _source(scene)
	if image == null: return
	# Preserve building proportions and the seven ranch doors' world X mapping.
	if scene == "ranch":
		image.resize(1920, 640, Image.INTERPOLATE_NEAREST)
		image = image.get_region(Rect2i(0, 40, 1920, 512))
	else:
		image.resize(1536, 512, Image.INTERPOLATE_NEAREST)
	_save_image(image, OUTPUT + scene + "-background.png")
	manifest.atlases[scene + "_background"] = {"cell": [image.get_width(), image.get_height()], "cells": 1, "aspect_preserved": true}

func _bake(kind: String, columns: int, authored_rows: Array, cell: Vector2i, scale_mode: String, source_kind := "") -> void:
	var source := _source(kind if source_kind.is_empty() else source_kind)
	if source == null: return
	var row_edges: Array[int] = []
	var reference_height: int = int(authored_rows[-1])
	for edge in authored_rows: row_edges.append(roundi(float(edge) / reference_height * source.get_height()))
	row_edges[0] = 0
	row_edges[-1] = source.get_height()
	var rows := row_edges.size() - 1
	var animal_sheet := kind in ["animals", "young", "actions"]
	var frames: Array[Dictionary] = []
	var row_scales: Array[float] = []
	var row_baselines: Array[int] = []
	for row in range(rows):
		var top: int = row_edges[row]
		var bottom: int = row_edges[row + 1]
		var separators := _animal_column_edges(source, top, bottom) if animal_sheet else _column_edges(source, columns, top, bottom)
		var isolated: Array = _animal_frames(source, top, bottom, row, kind) if animal_sheet else []
		var max_width := 1
		var max_height := 1
		var baseline := top
		for column in range(columns):
			# Inspection found 19 authored poses: 5/5/5/4. Repeat left frame zero
			# in the twentieth runtime slot instead of slicing the last animal in two.
			var source_column := 15 if animal_sheet and column == 19 else column
			var area := Rect2i(separators[source_column], top, separators[source_column + 1] - separators[source_column], bottom - top)
			if scale_mode == "crop": area = _crop_area(source, area, row, row_edges)
			elif animal_sheet: area = _animal_area(source, area, row, rows)
			var bounds: Rect2i = isolated[source_column].bounds if isolated.size() == 19 else _bounds(source, area)
			var large_component: Dictionary = {}
			if kind in ["cow", "goat", "sheep", "pig"]:
				var components := _components(source, area, 100)
				components.sort_custom(func(a, b): return a.pixels > b.pixels)
				if not components.is_empty():
					large_component = components[0]
					bounds = large_component.bounds
			if bounds.size.x <= 0 or bounds.size.y <= 0:
				failures.append("Empty original sprite: %s row %d col %d" % [kind, row, column])
				bounds = Rect2i(area.position, Vector2i.ONE)
			var entry := {"bounds": bounds, "column": column, "row": row}
			if not large_component.is_empty(): entry.image = large_component.image
			if isolated.size() == 19: entry.image = isolated[source_column].image
			frames.append(entry)
			max_width = maxi(max_width, bounds.size.x)
			max_height = maxi(max_height, bounds.size.y)
			baseline = maxi(baseline, bounds.end.y)
		row_scales.append(minf(float(cell.x - 4) / max_width, float(cell.y - 4) / max_height))
		row_baselines.append(baseline)
	var common_scale: float = row_scales.min()
	var atlas := Image.create(columns * cell.x, rows * cell.y, false, Image.FORMAT_RGBA8)
	atlas.fill(Color.TRANSPARENT)
	var records: Array = []
	for entry in frames:
		var bounds: Rect2i = entry.bounds
		var scale: float = common_scale if scale_mode == "all" else row_scales[int(entry.row)]
		if scale_mode == "crop":
			var group: int = int(entry.row) / 4
			var max_width := 1
			var max_height := 1
			for stage in range(4):
				var sibling: Rect2i = frames[(group * 4 + stage) * columns + int(entry.column)].bounds
				max_width = maxi(max_width, sibling.size.x)
				max_height = maxi(max_height, sibling.size.y)
			scale = minf(float(cell.x - 4) / max_width, float(cell.y - 4) / max_height)
		var sprite: Image = entry.image.duplicate() if entry.has("image") else source.get_region(bounds)
		_clean_transparent_rgb(sprite)
		var resized := Vector2i(maxi(1, roundi(bounds.size.x * scale)), maxi(1, roundi(bounds.size.y * scale)))
		sprite.resize(resized.x, resized.y, Image.INTERPOLATE_NEAREST)
		var offset := Vector2i((cell.x - resized.x) / 2, cell.y - 2 - resized.y)
		if scale_mode != "crop": offset.y -= roundi((row_baselines[int(entry.row)] - bounds.end.y) * scale)
		offset.y = maxi(2, offset.y)
		var destination := Vector2i(int(entry.column) * cell.x, int(entry.row) * cell.y) + offset
		atlas.blit_rect(sprite, Rect2i(Vector2i.ZERO, resized), destination)
		records.append({"row": entry.row, "column": entry.column, "source_bounds": [bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y], "scale": scale, "offset": [offset.x, offset.y]})
	_save_image(atlas, OUTPUT + kind + "-atlas.png")
	manifest.atlases[kind] = {"columns": columns, "rows": rows, "cell": [cell.x, cell.y], "cells": columns * rows, "row_edges": row_edges, "sprites": records}
	if animal_sheet:
		manifest.atlases[kind].authored_columns = 19
		manifest.atlases[kind].authored_direction_frames = [5, 5, 5, 4]
		manifest.atlases[kind].runtime_left_fifth_frame = "repeat first authored left frame"
	print("SCENE_ATLAS_BAKED ", kind, " ", atlas.get_size(), " frames=", columns * rows)

func _column_edges(image: Image, columns: int, top: int, bottom: int) -> Array[int]:
	var edges: Array[int] = [0]
	var nominal := float(image.get_width()) / columns
	for column in range(1, columns):
		var expected := roundi(column * nominal)
		var radius := roundi(nominal * 0.24)
		var best := expected
		var best_count := 1000000
		for x in range(maxi(edges[-1] + 1, expected - radius), mini(image.get_width() - 1, expected + radius) + 1):
			var count := 0
			for y in range(top, bottom):
				if image.get_pixel(x, y).a >= ALPHA_THRESHOLD: count += 1
			if count < best_count or (count == best_count and absi(x - expected) < absi(best - expected)):
				best = x
				best_count = count
		edges.append(best)
	edges.append(image.get_width())
	return edges

func _animal_column_edges(image: Image, top: int, bottom: int) -> Array[int]:
	var edges: Array[int] = [0]
	var ratio := float(image.get_width()) / 1586.0
	for index in range(ANIMAL_CENTERS.size() - 1):
		var expected := roundi((ANIMAL_CENTERS[index] + ANIMAL_CENTERS[index + 1]) * 0.5 * ratio)
		var best := expected
		var best_count := 1000000
		for x in range(maxi(edges[-1] + 1, expected - 10), mini(image.get_width() - 1, expected + 10) + 1):
			var count := 0
			for y in range(top, bottom):
				if image.get_pixel(x, y).a >= ALPHA_THRESHOLD: count += 1
			if count < best_count or (count == best_count and absi(x - expected) < absi(best - expected)):
				best = x
				best_count = count
		edges.append(best)
	edges.append(image.get_width())
	return edges

func _animal_area(image: Image, area: Rect2i, row: int, rows: int) -> Rect2i:
	var top := area.position.y
	var bottom := area.end.y
	if row > 0: top = _local_row_seam(image, area.position.x, area.end.x, top, 8)
	if row < rows - 1: bottom = _local_row_seam(image, area.position.x, area.end.x, bottom, 8)
	return Rect2i(area.position.x, top, area.size.x, maxi(1, bottom - top))

func _animal_frames(source: Image, top: int, bottom: int, row: int, kind: String) -> Array:
	var expanded_top := maxi(0, top - 10)
	var expanded_bottom := mini(source.get_height(), bottom + 10)
	# In the eating sheet rabbit ground shadows touch the next cow's horns.
	# The inspected cow body starts at 239; keep the two rows on separate sides.
	if kind == "actions" and row == 2: expanded_bottom = 239
	if kind == "actions" and row == 3: expanded_top = 239
	var area := Rect2i(0, expanded_top, source.get_width(), expanded_bottom - expanded_top)
	var components := _components(source, area, 300)
	var selected: Array = []
	for component in components:
		var bounds: Rect2i = component.bounds
		var center := bounds.position.y + bounds.size.y * 0.5
		if center > top + 8 and center < bottom - 8: selected.append(component)
	selected.sort_custom(func(a: Dictionary, b: Dictionary): return a.bounds.position.x < b.bounds.position.x)
	if selected.size() < 19:
		# Some authored cow poses touch; merged pixels cannot truthfully be split
		# into independent original silhouettes. Reuse a complete reference pose.
		var merged_index := -1
		for i in range(selected.size()):
			if (selected[i].bounds as Rect2i).size.x >= 140:
				merged_index = i
				break
		if merged_index >= 0:
			var group_start := 5 if merged_index >= 5 and merged_index < 10 else (10 if merged_index >= 10 and merged_index < 15 else (15 if merged_index >= 15 else 0))
			var reference: Dictionary = selected[mini(group_start, selected.size() - 1)]
			var found_clean := false
			var left_limit: int = [0, 400, 817, 1200][group_start / 5]
			var right_limit: int = [400, 817, 1200, source.get_width()][group_start / 5]
			for candidate in selected:
				var bounds: Rect2i = candidate.bounds
				var center := bounds.position.x + bounds.size.x * 0.5
				if center > left_limit and center < right_limit and bounds.size.x < 140:
					reference = candidate
					found_clean = true
					break
			if not found_clean:
				var ratio := float(source.get_width()) / 1586.0
				var first_side := Rect2i(roundi(400 * ratio), top, roundi(103 * ratio), bottom - top)
				var choices := _components(source, first_side, 100)
				choices.sort_custom(func(a: Dictionary, b: Dictionary): return a.pixels > b.pixels)
				if not choices.is_empty(): reference = choices[0]
			var copies := 20 - selected.size()
			selected.remove_at(merged_index)
			for i in range(copies): selected.insert(merged_index + i, reference)
			manifest.atlases[kind + "_" + str(ASSETS.ANIMAL_IDS[row]) + "_repair"] = {"reason": "Touching source silhouettes cannot be cropped without fragments", "direction": ASSETS.DIRECTIONS[group_start / 5], "reference_pose_repeats": copies, "authored_source_preserved": true}
	if selected.size() != 19:
		failures.append("Cannot isolate nineteen animal silhouettes: %s row %d found %d" % [kind, row, selected.size()])
	return selected

func _components(source: Image, area: Rect2i, minimum_pixels: int) -> Array:
	var image := source.get_region(area)
	var width := image.get_width()
	var height := image.get_height()
	var data := image.get_data()
	var visited := PackedByteArray()
	visited.resize(width * height)
	var result: Array = []
	for start in range(width * height):
		if visited[start] != 0 or data[start * 4 + 3] < 24: continue
		var queue := PackedInt32Array([start])
		visited[start] = 1
		var head := 0
		var left := start % width
		var right := left + 1
		var upper := start / width
		var lower := upper + 1
		while head < queue.size():
			var pixel := int(queue[head])
			head += 1
			var x := pixel % width
			var y := pixel / width
			left = mini(left, x)
			right = maxi(right, x + 1)
			upper = mini(upper, y)
			lower = maxi(lower, y + 1)
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0: continue
					var xx := x + dx
					var yy := y + dy
					if xx < 0 or xx >= width or yy < 0 or yy >= height: continue
					var neighbor := yy * width + xx
					if visited[neighbor] == 0 and data[neighbor * 4 + 3] >= 24:
						visited[neighbor] = 1
						queue.append(neighbor)
		if queue.size() < minimum_pixels: continue
		var isolated := Image.create(right - left, lower - upper, false, Image.FORMAT_RGBA8)
		isolated.fill(Color.TRANSPARENT)
		for pixel in queue:
			var x := int(pixel) % width
			var y := int(pixel) / width
			isolated.set_pixel(x - left, y - upper, image.get_pixel(x, y))
		result.append({"bounds": Rect2i(area.position + Vector2i(left, upper), isolated.get_size()), "image": isolated, "pixels": queue.size()})
	return result

func _crop_area(image: Image, area: Rect2i, row: int, edges: Array[int]) -> Rect2i:
	# Tall leaves can overlap a global stage separator in one crop column.
	# Use that column's alpha valley, keeping the four stage bands in order.
	var top := area.position.y
	var bottom := area.end.y
	if row % 4 > 0: top = _local_row_seam(image, area.position.x, area.end.x, top, 12)
	if row % 4 < 3: bottom = _local_row_seam(image, area.position.x, area.end.x, bottom, 12)
	return Rect2i(area.position.x, maxi(edges[row - row % 4], top), area.size.x, maxi(1, bottom - top))

func _local_row_seam(image: Image, left: int, right: int, expected: int, radius: int) -> int:
	var best := expected
	var best_count := 1000000
	for y in range(maxi(0, expected - radius), mini(image.get_height() - 1, expected + radius) + 1):
		var count := 0
		for x in range(left, right):
			if image.get_pixel(x, y).a >= ALPHA_THRESHOLD: count += 1
		if count < best_count or (count == best_count and absi(y - expected) < absi(best - expected)):
			best = y
			best_count = count
	return best

func _bounds(image: Image, area: Rect2i) -> Rect2i:
	var left := area.end.x
	var right := area.position.x
	var top := area.end.y
	var bottom := area.position.y
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			if image.get_pixel(x, y).a < ALPHA_THRESHOLD: continue
			left = mini(left, x)
			right = maxi(right, x + 1)
			top = mini(top, y)
			bottom = maxi(bottom, y + 1)
	return Rect2i(left, top, maxi(0, right - left), maxi(0, bottom - top))

func _clean_transparent_rgb(image: Image) -> void:
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a <= 8.0 / 255.0: image.set_pixel(x, y, Color.TRANSPARENT)

func _save_image(image: Image, path: String) -> void:
	var result := image.save_png(path)
	if result != OK: failures.append("Cannot write scene asset: " + path + " " + error_string(result))
