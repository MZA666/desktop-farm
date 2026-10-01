class_name FarmPixelAssets
extends RefCounted
## Shared imported atlases. Atlas regions are cached; drawing never creates images.

const CROP_IDS := ["blue_jazz", "carrot", "cauliflower", "coffee_bean", "garlic", "green_bean", "kale", "parsnip", "potato", "rhubarb", "strawberry", "tulip", "unmilled_rice", "blueberry", "corn", "hops", "hot_pepper", "melon", "poppy", "radish", "red_cabbage", "starfruit", "summer_spangle", "summer_squash", "sunflower", "tomato", "wheat", "amaranth", "artichoke", "beet", "bok_choy", "broccoli", "cranberry", "eggplant", "fairy_rose", "grape", "pumpkin", "yam", "powdermelon", "ancient_fruit", "cactus_fruit", "fiber", "pineapple", "qi_fruit", "sweet_gem_berry", "taro_root", "tea_leaves", "spring_seeds", "summer_seeds", "fall_seeds", "winter_seeds", "mixed_seeds", "mixed_flower_seeds", "wild_horseradish", "daffodil", "leek", "dandelion", "spice_berry", "sweet_pea", "common_mushroom", "wild_plum", "hazelnut", "blackberry", "winter_root"]
const ANIMAL_IDS := ["chicken", "duck", "rabbit", "cow", "goat", "sheep", "pig", "void_chicken", "golden_chicken", "dinosaur", "ostrich", "chick", "silver_fish", "blueback_fish", "goldstripe_fish", "hay"]
const PRODUCT_IDS := ["rice", "crystal_fruit", "snow_yam", "crocus", "egg", "duck_egg", "wool", "milk", "goat_milk", "truffle", "void_egg", "golden_egg", "dinosaur_egg", "ostrich_egg", "grass_seed", "hay"]
static var _atlases: Dictionary = {}
static var _regions: Dictionary = {}

static func _region(atlas_name: String, index: int, columns: int) -> Texture2D:
	var key := atlas_name + ":" + str(index)
	if _regions.has(key): return _regions[key]
	if not _atlases.has(atlas_name):
		# Originals stay in the repository. The offline bake ships only 32px
		# cells, avoiding large temporary texture/CPU buffers during game startup.
		_atlases[atlas_name] = load("res://assets/pixel/runtime/" + atlas_name + "-atlas-v0.7.png") as Texture2D
	var atlas: Texture2D = _atlases[atlas_name]
	if atlas == null: return null
	var size := atlas.get_size()
	var column := index % columns
	var row := index / columns
	var left := floorf(size.x * column / columns)
	var top := floorf(size.y * row / columns)
	var right := floorf(size.x * (column + 1) / columns)
	var bottom := floorf(size.y * (row + 1) / columns)
	var texture := AtlasTexture.new()
	texture.atlas = atlas
	texture.region = Rect2(left, top, right - left, bottom - top)
	texture.filter_clip = true
	_regions[key] = texture
	return texture

static func icon(kind: String, id: String) -> Texture2D:
	var product_index := PRODUCT_IDS.find(id)
	if kind != "animal" and product_index >= 0: return _region("products", product_index, 4)
	var animal_index := ANIMAL_IDS.find(id)
	if kind == "animal" or animal_index >= 0:
		return _region("animals", maxi(0, animal_index), 4)
	var crop_index := CROP_IDS.find(id)
	if crop_index >= 0: return _region("crops", crop_index, 8)
	return _region("crops", 7, 8)

static func farmer(action: String, frame: int, facing_left := false) -> Texture2D:
	var row := 1 if facing_left else 0
	if action == "water": row = 2
	elif action in ["harvest", "collect_product", "cut_grass", "plant", "sow_grass"]: row = 3
	return _region("farmer", row * 4 + posmod(frame, 4), 4)

static func terrain(kind: String) -> Texture2D:
	var key := "terrain:" + kind
	if _regions.has(key): return _regions[key]
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var base := Color("#87ae45")
	if kind == "soil": base = Color("#bd814b")
	elif kind == "wet_soil": base = Color("#965d39")
	image.fill(base)
	if kind in ["soil", "wet_soil"]:
		for y in [8, 16, 24]:
			image.fill_rect(Rect2i(2, y, 28, 1), base.darkened(0.2))
			image.fill_rect(Rect2i(3, y - 1, 24, 1), base.lightened(0.09))
	else:
		for i in range(22):
			var x := (i * 17 + 5) % 30
			var y := (i * 11 + 7) % 30
			image.fill_rect(Rect2i(x, y, 2, 1), Color("#9ebc54") if i % 3 else Color("#7ba13e"))
		for point in [Vector2i(3, 3), Vector2i(20, 15), Vector2i(11, 26)]:
			image.fill_rect(Rect2i(point, Vector2i(1, 3)), Color("#b0c867"))
	var texture := ImageTexture.create_from_image(image)
	_regions[key] = texture
	return texture
