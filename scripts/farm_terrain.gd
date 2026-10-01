class_name FarmNaturalTerrain
extends RefCounted

## Original, small pixel tiles. Variants are deterministic world decoration;
## they never draw from the simulator's economic random-number generator.
static var _textures: Dictionary = {}

static func tile(kind: String, variant := 0, edges := 0) -> Texture2D:
	variant = posmod(variant, 4)
	edges = clampi(edges, 0, 15)
	var key := "%s/%d/%d" % [kind, variant, edges]
	if _textures.has(key): return _textures[key]
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var grass := Color("#91a866")
	var soil := Color("#b88a5a") if kind != "wet" else Color("#98744f")
	image.fill(grass)
	if kind in ["field", "wet"]:
		image.fill(soil)
		# Only the exterior of connected land has a rim. Adjacent plots join
		# into a single field rather than ninety-six bordered UI cards.
		for y in [7, 15, 23, 31]:
			image.fill_rect(Rect2i(1, y, 30, 1), soil.darkened(0.10))
			image.fill_rect(Rect2i(3 + variant, y - 1, 23, 1), soil.lightened(0.045))
		if edges & 1: _rim(image, Rect2i(0, 0, 32, 2), soil, variant)
		if edges & 2: _rim(image, Rect2i(30, 0, 2, 32), soil, variant)
		if edges & 4: _rim(image, Rect2i(0, 30, 32, 2), soil, variant)
		if edges & 8: _rim(image, Rect2i(0, 0, 2, 32), soil, variant)
	elif kind == "path":
		image.fill(Color("#c4ad7a"))
		for i in range(13):
			var point := Vector2i((i * 13 + variant * 5) % 31, (i * 7 + variant) % 30)
			image.fill_rect(Rect2i(point, Vector2i(2, 1)), Color("#b7a172") if i % 3 else Color("#d3bd8b"))
	elif kind == "water":
		image.fill(Color("#6cabb1"))
		for i in range(8):
			var point := Vector2i((i * 13 + variant * 3) % 26, (i * 9 + variant * 7) % 31)
			image.fill_rect(Rect2i(point, Vector2i(6, 1)), Color("#91c1be") if i % 2 else Color("#5e969e"))
	else:
		for i in range(22):
			var point := Vector2i((i * 17 + variant * 7 + 5) % 30, (i * 11 + variant * 3 + 7) % 30)
			image.fill_rect(Rect2i(point, Vector2i(2, 1)), Color("#a0b774") if i % 3 else Color("#849b5d"))
		for i in range(3):
			var point := Vector2i((i * 11 + variant * 7 + 3) % 29, (i * 9 + variant * 5 + 3) % 28)
			image.fill_rect(Rect2i(point, Vector2i(1, 3)), Color("#b0bf84"))
	var texture := ImageTexture.create_from_image(image)
	_textures[key] = texture
	return texture

static func _rim(image: Image, rect: Rect2i, soil: Color, variant: int) -> void:
	image.fill_rect(rect, soil.darkened(0.17))
	for i in range(8):
		var point := rect.position + Vector2i((i * 5 + variant) % maxi(1, rect.size.x), (i * 7 + variant) % maxi(1, rect.size.y))
		image.set_pixelv(point, Color("#9aa96b"))

static func decoration(kind: String, variant := 0) -> Texture2D:
	variant = posmod(variant, 3)
	var key := "decor/%s/%d" % [kind, variant]
	if _textures.has(key): return _textures[key]
	var size := Vector2i(48, 72) if kind == "tree" else Vector2i(32, 32)
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	match kind:
		"tree":
			image.fill_rect(Rect2i(19, 38, 9, 30), Color("#775c40"))
			image.fill_rect(Rect2i(24, 43, 3, 25), Color("#94724b"))
			image.fill_rect(Rect2i(14, 65, 23, 4), Color("#6e8351"))
			var rows := [Vector3i(15, 3, 20), Vector3i(9, 8, 31), Vector3i(4, 17, 40), Vector3i(2, 27, 43), Vector3i(6, 37, 36), Vector3i(12, 45, 26)]
			for row in rows:
				image.fill_rect(Rect2i(row.x, row.y, row.z, 10), Color("#647f4a"))
			image.fill_rect(Rect2i(12, 12, 22, 7), Color("#8eaa63"))
			image.fill_rect(Rect2i(8, 22, 29, 6), Color("#789852"))
			image.fill_rect(Rect2i(5, 32, 20, 5), Color("#819e58"))
			for i in range(9):
				image.fill_rect(Rect2i(9 + (i * 7) % 28, 16 + (i * 9) % 26, 3, 2), Color("#a1b773") if i % 3 else Color("#caa16e"))
		"fence":
			image.fill_rect(Rect2i(0, 14, 32, 3), Color("#a6865b"))
			image.fill_rect(Rect2i(0, 22, 32, 3), Color("#8c704d"))
			for x in [2, 24]:
				image.fill_rect(Rect2i(x, 9, 5, 21), Color("#765d42"))
				image.fill_rect(Rect2i(x + 1, 10, 2, 18), Color("#b39467"))
		"bush":
			image.fill_rect(Rect2i(3, 24, 26, 4), Color("#6d8151"))
			image.fill_rect(Rect2i(7, 11, 17, 16), Color("#657f48"))
			image.fill_rect(Rect2i(3, 16, 26, 8), Color("#71904e"))
			image.fill_rect(Rect2i(10, 8, 10, 16), Color("#8ba35d"))
			for i in range(7):
				image.fill_rect(Rect2i(6 + i * 3, 13 + (i * 7 + variant) % 11, 2, 2), Color("#b79978") if variant == 1 else Color("#aaba73"))
		"stone":
			image.fill_rect(Rect2i(7, 22, 18, 3), Color("#768456"))
			image.fill_rect(Rect2i(9, 15, 14, 8), Color("#8f9183"))
			image.fill_rect(Rect2i(12, 12, 9, 4), Color("#b6b5a0"))
			image.fill_rect(Rect2i(10, 17, 6, 2), Color("#c4c1a8"))
		"flower":
			for i in range(3):
				var x := 5 + i * 9
				var y := 13 + (i * 7 + variant * 3) % 9
				image.fill_rect(Rect2i(x, y + 3, 1, 8), Color("#6f8d50"))
				image.fill_rect(Rect2i(x - 2, y, 5, 3), Color("#d4b38a") if variant == 0 else Color("#c7bc8d") if variant == 1 else Color("#b7a6b4"))
				image.set_pixel(x, y + 1, Color("#eddb9e"))
		"well":
			image.fill_rect(Rect2i(6, 11, 23, 19), Color("#787d75"))
			image.fill_rect(Rect2i(8, 14, 19, 13), Color("#b3b09a"))
			for y in [17, 23]: image.fill_rect(Rect2i(8, y, 19, 1), Color("#929b8b"))
			image.fill_rect(Rect2i(9, 11, 17, 5), Color("#557e83"))
			for x in [7, 26]: image.fill_rect(Rect2i(x, 4, 2, 17), Color("#826745"))
			image.fill_rect(Rect2i(5, 3, 25, 3), Color("#a38b60"))
		"sign":
			image.fill_rect(Rect2i(15, 15, 3, 17), Color("#80633f"))
			image.fill_rect(Rect2i(3, 5, 27, 13), Color("#82613d"))
			image.fill_rect(Rect2i(5, 7, 23, 9), Color("#c3a778"))
			image.fill_rect(Rect2i(12, 10, 8, 2), Color("#806b49"))
	var texture := ImageTexture.create_from_image(image)
	_textures[key] = texture
	return texture
