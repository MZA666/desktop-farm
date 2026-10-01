extends SceneTree

var test_failed := false

const HOST = preload("res://scripts/desktop_host.gd")
var host: DesktopHost
var toolbar: Window
var label: Label
var ticks := 0
var first_pixels := PackedByteArray()

func _initialize() -> void:
	Engine.max_fps = 30
	call_deferred("_start_test")

func _start_test() -> void:
	root.gui_embed_subwindows = false
	toolbar = Window.new()
	toolbar.title = "Collapsed toolbar rendering validation"
	toolbar.size = Vector2i(400, 32)
	root.add_child(toolbar)
	var background := ColorRect.new()
	background.color = Color(0.15, 0.18, 0.21)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	toolbar.add_child(background)
	label = Label.new()
	label.text = "BEFORE 111"
	label.add_theme_font_size_override("font_size", 26)
	label.modulate = Color(1.0, 0.1, 0.1)
	toolbar.add_child(label)
	toolbar.show()
	host = HOST.new()
	root.add_child(host)
	verify(host.start(root, toolbar, {}))
	host.set_collapsed(true)

func _process(_delta: float) -> bool:
	if host == null:
		return false
	ticks += 1
	if ticks == 12:
		var before := toolbar.get_texture().get_image()
		first_pixels = before.get_data()
		before.save_png("res://.review/collapsed-toolbar-before.png")
		label.text = "AFTER 99999"
		label.modulate = Color(0.1, 1.0, 0.1)
	elif ticks == 24:
		var after := toolbar.get_texture().get_image()
		after.save_png("res://.review/collapsed-toolbar-after.png")
		var changed := first_pixels != after.get_data()
		print("COLLAPSED_RENDER_", "PASS" if changed else "FAIL", ": actual toolbar pixel buffer changed=", changed)
		verify(not bool(host.native.call("is_visible")))
		host.shutdown()
		quit(0 if changed and not test_failed else 1)
	return false

func verify(condition: bool, message: String = "Native acceptance check failed") -> bool:
	if not condition:
		test_failed = true
		push_error(message)
		quit(1)
	return condition
