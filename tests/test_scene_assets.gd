extends SceneTree

const Assets = preload("res://scripts/scene_assets.gd")
var assertions := 0
var failures: Array[String] = []
var _reported_pixel_difference := false

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
	_validate_v082()
	check(Assets.crop("parsnip", 3) == Assets.crop("parsnip", 3), "Repeated draws reuse the same immutable atlas region")
	Assets.release_all()
	if failures.is_empty():
		print("SCENE_ASSETS_PASS: %d source/layout/alpha/cache assertions" % assertions)
		quit(0)
	else:
		for failure in failures: printerr("FAIL: " + failure)
		quit(1)

func _validate_alpha(kind: String, cell: Vector2i, asset_root: String = Assets.ROOT) -> void:
	var image := Image.load_from_file(ProjectSettings.globalize_path(asset_root + kind + "-atlas.png"))
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
			var border_clear := true
			for x in range(cell.x):
				if sprite.get_pixel(x,0).a != 0 or sprite.get_pixel(x,cell.y-1).a != 0: border_clear = false
			for y in range(cell.y):
				if sprite.get_pixel(0,y).a != 0 or sprite.get_pixel(cell.x-1,y).a != 0: border_clear = false
			check(border_clear, "Full perimeter stays transparent: %s %d,%d" % [kind,column,row])

func _validate_v082() -> void:
	var extra: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Assets.EXTRA_ROOT + "manifest.json"))
	check(not extra.is_empty() and extra.status=="ready" and extra.version=="0.8.2" and extra.source_preserved, "v082 manifest describes a completed original-source bake")
	if extra.is_empty(): return
	check(extra.generator=="OpenAI imagegen" and not str(extra.prompt_provenance).is_empty(), "v082 generator and prompt provenance recorded")
	check(int(extra.foot_anchor[0])==32 and int(extra.foot_anchor[1])==78, "All v082 farmer cells share the declared foot anchor")
	for kind in extra.sources:
		var record: Dictionary = extra.sources[kind]
		check(FileAccess.get_sha256(str(record.path))==str(record.sha256), "Preserved source SHA matches the bake: "+kind)
	var walk: Dictionary = extra.atlases["farmer-walk"]
	check(int(walk.columns)==8 and int(walk.rows)==4 and int(walk.authored_columns)==4, "Walk atlas honestly distinguishes four original contacts from eight held phases")
	var held_mapping := true
	for row in range(4):
		var expected: Array = [0,0,2,2,1,1,3,3] if row==2 else [0,0,1,1,2,2,3,3]
		var mapping: Array = walk.runtime_source_columns_by_direction[Assets.DIRECTIONS[row]]
		for phase in range(8):
			if int(mapping[phase])!=int(expected[phase]): held_mapping=false
	check(held_mapping, "Runtime phases map to the intended held contacts")
	check(walk.directions==Assets.DIRECTIONS, "All four direction rows keep the public API order")
	_validate_alpha("farmer-walk",Assets.FARMER_CELL,Assets.EXTRA_ROOT)
	_validate_alpha("pickup",Assets.FARMER_CELL,Assets.EXTRA_ROOT)
	var image := Image.load_from_file(ProjectSettings.globalize_path(str(walk.path)))
	check(image.get_size()==Vector2i(512,320), "Walk runtime file is8x4 cells without dynamic resizing")
	for row in range(4):
		var poses: Array[Image] = []
		for column in range(8):
			var frame := image.get_region(Rect2i(column*64,row*80,64,80))
			check(frame.get_used_rect().end.y==78, "Contact foot stays at y78 across direction/phase %d,%d"%[row,column])
			poses.append(frame)
			var api: Texture2D = Assets.farmer("walk",Assets.DIRECTIONS[row],column)
			check(api is AtlasTexture and (api as AtlasTexture).region==Rect2(column*64,row*80,64,80), "Farmer API selects the actual v082 direction and phase %d,%d"%[row,column])
			check(_visible_pixels_equal(api.get_image(),frame), "Imported walk alpha and opaque pixels match the latest baked file %d,%d"%[row,column])
			check(api==Assets.farmer("walking",Assets.DIRECTIONS[row],column), "Walking action alias shares the immutable atlas region")
		for authored in range(4): check(poses[authored*2].get_data()==poses[authored*2+1].get_data(), "Each authored contact held twice rather than fabricated %d,%d"%[row,authored])
		check(poses[0].get_data()!=poses[4].get_data(), "Left/right contact poses have genuinely different silhouettes: "+Assets.DIRECTIONS[row])
		check(poses[0].get_region(Rect2i(0,52,64,26)).get_data()!=poses[4].get_region(Rect2i(0,52,64,26)).get_data(), "Difference reaches the legs instead of only hat/face: "+Assets.DIRECTIONS[row])
		check(poses[0].get_data()!=poses[2].get_data() and poses[4].get_data()!=poses[6].get_data(), "Both contact poses transition through a separate passing/standing pose")
		check(Assets.farmer("walk",Assets.DIRECTIONS[row],8)==Assets.farmer("walk",Assets.DIRECTIONS[row],0), "Eight runtime walk phases wrap")
	# Front/back contact alternation shifts the boots to opposite sides.
	for row in [0,2]:
		var left := image.get_region(Rect2i(0,row*80,64,80))
		var right := image.get_region(Rect2i(4*64,row*80,64,80))
		check(absf(_boot_center(left)-_boot_center(right))>=3, "Front/back frames alternate the contacting left/right boot %s (%0.2f vs %0.2f)"%[Assets.DIRECTIONS[row],_boot_center(left),_boot_center(right)])
	for record in walk.sprites:
		check(is_equal_approx(float(record.scale),float(walk.common_scale)), "Farmer directions/phases use one common scale")
		check(int(record.foot_anchor[0])==32 and int(record.foot_anchor[1])==78, "Every walk source record preserves one foot anchor")
	var pickup: Dictionary = extra.atlases.pickup
	check(int(pickup.source_sheet_columns)==8 and int(pickup.source_sheet_rows)==5 and int(pickup.source_sheet_row)==4 and int(pickup.authored_columns)==8, "Pickup uses the last eight authored source frames")
	var pickup_image := Image.load_from_file(ProjectSettings.globalize_path(str(pickup.path)))
	check(pickup_image.get_size()==Vector2i(512,80), "Pickup runtime atlas contains exactly eight frames")
	for column in range(8):
		var pose := pickup_image.get_region(Rect2i(column*64,0,64,80))
		check(pose.get_used_rect().end.y==78, "Pickup preserves foot anchor during bending and return")
		check(Assets.farmer("pickup","down",column)==Assets.farmer("collect_product","left",column), "Fixed ground-product pickup selects the new authored action")
		check(Assets.farmer("pickup","down",column)!=Assets.farmer("harvest","down",column), "Pickup does not reuse crop-scythe animation")
	check(pickup_image.get_region(Rect2i(0,0,64,80)).get_used_rect().position.y < pickup_image.get_region(Rect2i(3*64,0,64,80)).get_used_rect().position.y, "Pickup visibly lowers the body while feet stay planted")
	check(Assets.farmer_frame_count("walk")==8 and Assets.farmer_frame_count("pickup")==8 and Assets.farmer_frame_count("water")==4, "Action phase counts follow their real atlas layouts")
	for scene in ["farm","ranch","pond"]:
		var border: Texture2D = Assets.border(scene)
		check(border!=null and border.get_size()==Vector2(1536,512), "Complete independent wide border plate exists: "+scene)
		check(border==Assets.border(scene), "Border plate cached without per-frame decoding")
	check(Assets.border("pond")!=Assets.border("farm"), "Pond does not repeat farm's architectural edge strip")
	for id in Assets.ANIMAL_IDS:
		var portrait: Texture2D = Assets.portrait(id)
		check(portrait!=null and portrait.get_size()==Vector2(48,48) and portrait.get_image().get_used_rect().has_area(), "Shelter portrait has a visible crop for correct species: "+id)
		check(portrait==Assets.portrait(id), "Shelter portrait reuses cached region: "+id)
	check(Assets.portrait("missing")==null, "Invalid shelter portrait does not substitute another animal")

func _boot_center(image: Image) -> float:
	var total := 0.0
	var weighted := 0.0
	for y in range(70,78):
		for x in range(64):
			var color := image.get_pixel(x,y)
			if color.a>0.5 and color.r>color.g+0.035 and color.g>color.b+0.035:
				total+=color.a
				weighted+=x*color.a
	return weighted/total if total>0 else 32.0

func _visible_pixels_equal(left: Image, right: Image) -> bool:
	if left.get_size()!=right.get_size(): return false
	for y in range(left.get_height()):
		for x in range(left.get_width()):
			var a := left.get_pixel(x,y)
			var b := right.get_pixel(x,y)
			if a.a!=b.a or (a.a>=0.5 and (a.r!=b.r or a.g!=b.g or a.b!=b.b)):
				if not _reported_pixel_difference:
					print("RUNTIME_PIXEL_DIFFERENCE ",Vector2i(x,y)," imported ",a," png ",b)
					_reported_pixel_difference=true
				return false
	# Godot's alpha-border fix changes RGB in faint edge pixels. Verify all
	# alpha and the opaque body so stale imports still fail without halo noise.
	return true
