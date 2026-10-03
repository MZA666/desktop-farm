extends RefCounted
## Small real HWND fixture using the product's root-toolbar ownership layout.

static func scene_for(toolbar: Window) -> Window:
	toolbar.gui_embed_subwindows = false
	toolbar.title = "Desktop Farm controlled toolbar"
	toolbar.transparent = false
	toolbar.transparent_bg = false
	toolbar.borderless = true
	toolbar.size = Vector2i(640, 32)
	var scene := Window.new()
	scene.visible = false
	scene.title = "Desktop Farm controlled scenery"
	scene.borderless = true
	scene.transparent = true
	scene.transparent_bg = true
	scene.transient = true
	scene.exclusive = false
	toolbar.add_child(scene)
	scene.show()
	return scene
