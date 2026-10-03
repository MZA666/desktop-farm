class_name FarmSceneAssets
extends RefCounted

## Scene art is baked offline. Getters only load/cache immutable runtime textures.
const ROOT := "res://assets/pixel/v0.8.1/runtime/"
const EXTRA_ROOT := "res://assets/pixel/v0.8.2/runtime/"
const ICONS = preload("res://scripts/pixel_assets.gd")
const CROP_IDS = ICONS.CROP_IDS
const ANIMAL_IDS := ["chicken", "duck", "rabbit", "cow", "goat", "sheep", "pig", "void_chicken", "golden_chicken", "dinosaur", "ostrich"]
const DIRECTIONS := ["down", "right", "up", "left"]
const FISH_IDS := ["silver_fish", "blueback_fish", "goldstripe_fish"]
const CROP_CELL := Vector2i(64, 96)
const ANIMAL_CELL := Vector2i(96, 96)
const FARMER_CELL := Vector2i(64, 80)
const NATURE_CELL := Vector2i(64, 64)
static var _atlases: Dictionary = {}
static var _regions: Dictionary = {}
static var _background_scene := ""
static var _background_texture: Texture2D

static func background(scene: String) -> Texture2D:
	if not ["farm", "ranch", "pond"].has(scene): return null
	if scene != _background_scene:
		release_background()
		_background_scene = scene
		_background_texture = _load_texture(ROOT + scene + "-background.png")
	return _background_texture

static func release_background() -> void:
	_background_texture = null
	_background_scene = ""

static func loaded_background_scene() -> String:
	return _background_scene

static func release_all() -> void:
	release_background()
	_regions.clear()
	_atlases.clear()

static func crop(id: String, stage: int) -> Texture2D:
	var index: int = CROP_IDS.find(id)
	if index < 0: return null
	return _region("crops", index % 16, (index / 16) * 4 + clampi(stage, 0, 3), CROP_CELL)

static func animal(id: String, direction := "down", frame := 0, juvenile := false, eating := false) -> Texture2D:
	if FISH_IDS.has(id): return fish(id, frame)
	if id == "chick":
		id = "chicken"
		juvenile = true
	var row: int = ANIMAL_IDS.find(id)
	if row < 0: return null
	if not juvenile and not eating and id in ["cow", "goat", "sheep", "pig"] and _has_asset(id):
		return _region(id, posmod(frame, 4), maxi(0, DIRECTIONS.find(direction)), ANIMAL_CELL)
	var atlas := "actions" if eating else ("young" if juvenile else "animals")
	var column: int = maxi(0, DIRECTIONS.find(direction)) * 5 + posmod(frame, 5)
	return _region(atlas, column, row, ANIMAL_CELL)

static func fish(id: String, frame := 0) -> Texture2D:
	var row: int = FISH_IDS.find(id)
	if row < 0: return null
	return _region("nature", posmod(frame, 4), row, NATURE_CELL)

static func farmer(action: String, direction := "down", frame := 0) -> Texture2D:
	var row: int = maxi(0, DIRECTIONS.find(direction))
	if action in ["idle", "walk", "walking"]:
		return _extra_region("farmer-walk", posmod(frame, 8), row, FARMER_CELL)
	if action in ["collect_product", "pickup"]:
		return _extra_region("pickup", posmod(frame, 8), 0, FARMER_CELL)
	if action == "water": row = 4
	elif action in ["sow", "sow_grass", "plant"]: row = 5
	elif action in ["harvest", "collect_product", "cut_grass"]: row = 6
	elif action in ["pet", "feed", "interact_animal"]: row = 7
	return _region("farmer", posmod(frame, 4), row, FARMER_CELL)

static func farmer_frame_count(action: String) -> int:
	return 8 if action in ["idle", "walk", "walking", "collect_product", "pickup"] else 4

static func border(scene: String) -> Texture2D:
	var kind := "pond-margins" if scene == "pond" else "woodland"
	var key := "extra:" + kind
	if not _atlases.has(key): _atlases[key] = _load_texture(EXTRA_ROOT + kind + ".png")
	return _atlases[key]

static func portrait(id: String) -> Texture2D:
	var key := "portrait:" + id
	if _regions.has(key): return _regions[key]
	var sprite := animal(id, "down", 0)
	if sprite == null: return null
	var portrait_texture := AtlasTexture.new()
	portrait_texture.atlas = sprite
	portrait_texture.region = Rect2(24, 14, 48, 48)
	portrait_texture.filter_clip = true
	_regions[key] = portrait_texture
	return portrait_texture

static func _extra_region(kind: String, column: int, row: int, cell: Vector2i) -> Texture2D:
	var key := "extra:%s:%d:%d" % [kind, column, row]
	if _regions.has(key): return _regions[key]
	var atlas_key := "extra:" + kind
	if not _atlases.has(atlas_key): _atlases[atlas_key] = _load_texture(EXTRA_ROOT + kind + "-atlas.png")
	var texture: Texture2D = _atlases[atlas_key]
	if texture == null: return null
	var region := AtlasTexture.new()
	region.atlas = texture
	region.region = Rect2(Vector2(column * cell.x, row * cell.y), Vector2(cell))
	region.filter_clip = true
	_regions[key] = region
	return region

static func grass(variant := 0) -> Texture2D:
	return _region("nature", posmod(variant, 4), 3, NATURE_CELL)

static func foreground(_scene: String) -> Texture2D:
	# The supplied backgrounds are complete paintings; no fake opaque cutout.
	return null

static func _region(kind: String, column: int, row: int, cell: Vector2i) -> Texture2D:
	var key := "%s:%d:%d" % [kind, column, row]
	if _regions.has(key): return _regions[key]
	if not _atlases.has(kind): _atlases[kind] = _load_texture(ROOT + kind + "-atlas.png")
	var texture: Texture2D = _atlases[kind]
	if texture == null: return null
	var region := AtlasTexture.new()
	region.atlas = texture
	region.region = Rect2(Vector2(column * cell.x, row * cell.y), Vector2(cell))
	region.filter_clip = true
	_regions[key] = region
	return region

static func _load_texture(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		var imported := ResourceLoader.load(path)
		if imported is Texture2D: return imported
	# A fresh offline bake is usable before the editor's next PNG import.
	if not FileAccess.file_exists(path):
		push_error("Missing baked scene asset: " + path)
		return null
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	return ImageTexture.create_from_image(image) if image != null and not image.is_empty() else null

static func _has_asset(kind: String) -> bool:
	var path := ROOT + kind + "-atlas.png"
	return ResourceLoader.exists(path) or FileAccess.file_exists(path)
