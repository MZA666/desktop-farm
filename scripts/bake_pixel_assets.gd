extends SceneTree
## Offline asset build: preserve imagegen originals, ship small nearest-sampled
## atlases. Avoid decoding/uploading/readback of 1254px authoring images at play.
func _initialize() -> void:
	var directory := "res://assets/pixel/runtime"
	var result := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	if result != OK:
		printerr("Cannot create runtime atlas directory: " + error_string(result))
		quit(1)
		return
	for kind in ["crops", "animals", "farmer", "products"]:
		var image := Image.load_from_file(ProjectSettings.globalize_path("res://assets/pixel/" + kind + "-atlas-v0.7.png"))
		if image == null or image.is_empty():
			printerr("Missing authoring atlas: " + kind)
			quit(1)
			return
		var columns := 8 if kind == "crops" else 4
		image.resize(columns * 32, columns * 32, Image.INTERPOLATE_NEAREST)
		result = image.save_png(directory + "/" + kind + "-atlas-v0.7.png")
		if result != OK:
			printerr("Cannot write runtime atlas: " + kind)
			quit(1)
			return
		print("PIXEL_ATLAS_BAKED ", kind, " ", image.get_size())
	quit(0)
