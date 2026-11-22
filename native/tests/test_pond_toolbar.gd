extends SceneTree

var controller: Node
var report_path := ""
var ticks := 0
var toolbar_buttons := {}
var root_clicks := 0
var toolbar_clicks := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if not OS.get_cmdline_user_args().has("--benchmark-fixture"):
		quit(2)
		return
	report_path = "res://.review/pond-toolbar-%d.json" % OS.get_process_id()
	controller = load("res://scenes/main.tscn").instantiate()
	root.add_child(controller)
	controller.saves.path = "user://test-data/toolbar-fishing.json"
	for child in controller.toolbar.get_child(1).get_children():
		if child is Button and child.text in ["农场", "鱼塘"]:
			toolbar_buttons[child.text] = child
	root.window_input.connect(func(event):
		if event is InputEventMouseButton: root_clicks += 1)
	controller.toolbar.window_input.connect(func(event):
		if event is InputEventMouseButton: toolbar_clicks += 1)
	process_frame.connect(_report)

func _screen_point(point: Vector2, window: Window) -> Array:
	var client := point * Vector2(window.size) / Vector2(window.content_scale_size)
	var physical := window.position + Vector2i(client)
	return [physical.x, physical.y]

func _report() -> void:
	ticks += 1
	if ticks < 4 or ticks % 3 != 0: return
	var fish_hits: Array = controller.view._fish_hits
	var target: Array = []
	if not fish_hits.is_empty():
		target = _screen_point((fish_hits[0].rect as Rect2).get_center() + controller.view.position, root)
	var payload := {"scene": controller.current_scene, "fish": controller.model.state.fish.size(), "pond_tile": target,
		"root_id": DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, root.get_window_id()),
		"bar_id": DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, controller.toolbar.get_window_id()),
		"root_events": root_clicks, "bar_events": toolbar_clicks, "net": controller.model.state.net_remaining,
		"farm_button": _screen_point(toolbar_buttons["农场"].get_global_rect().get_center(), controller.toolbar),
		"pond_button": _screen_point(toolbar_buttons["鱼塘"].get_global_rect().get_center(), controller.toolbar)}
	var report := FileAccess.open(report_path, FileAccess.WRITE)
	if report:
		report.store_string(JSON.stringify(payload))
	else:
		printerr("Cannot write toolbar test data: ", FileAccess.get_open_error())
		quit(2)
