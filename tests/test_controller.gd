extends SceneTree

var failures: Array[String] = []
var assertions := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, detail: String) -> void:
	assertions += 1
	if not value: failures.append(detail)

func _run() -> void:
	var controller = load("res://scenes/main.tscn").instantiate()
	root.add_child(controller)
	controller.set_process(false)
	check(controller.benchmark_fixture, "Controller test uses isolated fixture")
	check(not controller.popup.visible and controller.panel_name.is_empty(), "Startup management window stays hidden and unrendered")
	check(not controller.popup.always_on_top and not controller.model.state.settings.topmost, "Startup uses normal window order")
	check(controller.toolbar.find_child("SeedShop", true, false) != null and controller.toolbar.find_child("AnimalShop", true, false) != null, "Both shops have direct toolbar buttons")
	var review_directory := ProjectSettings.globalize_path("res://.review")
	var directory_error := DirAccess.make_dir_recursive_absolute(review_directory)
	check(directory_error == OK, "Controller test output directory can be created on a clean clone")
	if directory_error != OK:
		printerr("Cannot create controller test output directory: " + error_string(directory_error))
		controller.host.shutdown()
		quit(1)
		return
	var valid_path := review_directory.path_join("controller-test-save.json")
	var blocker_path := ProjectSettings.globalize_path("res://.review/controller-test-blocker")
	var blocker := FileAccess.open(blocker_path, FileAccess.WRITE)
	blocker.store_string("This is a file, not a directory.")
	blocker.close()
	controller.saves.path = blocker_path.path_join("cannot-save.json")
	var before: Dictionary = controller.model.snapshot()
	var instance_id: String = controller.model.state.animals[0].id
	check(not controller._act("sell_animal", {"instance_id": instance_id}, false), "Failed disk write rejects sale")
	check(JSON.stringify(before) == JSON.stringify(controller.model.snapshot()), "Failed disk write rolls back the whole model")
	check(controller.save_blocked, "Controller blocks more investments after disk failure")
	controller.saves.path = valid_path
	check(controller._save_now() and not controller.save_blocked, "Retry save clears blocked state")
	check(controller._act("sell_animal", {"instance_id": instance_id}, false), "Sale succeeds after save recovery")
	check(controller.model.balance() == int(before.coins) + 400, "Gift-price refund is exactly 400")
	var readback: Dictionary = controller.saves.load_save()
	check(readback.ok and int(readback.data.coins) == controller.model.balance(), "Committed sale is immediately persisted")
	for name in ["hub", "crops", "build", "animals", "farmers", "catalog", "settings", "caught"]:
		controller.panel_name = name
		controller._render_panel()
		check(controller.popup_body.get_child_count() > 0, "Panel renders: " + name)
	var renderer: FarmView = controller.view
	check(renderer._segment_hits_rect(Vector2(0, 40), Vector2(100, 40), Rect2(30, 30, 20, 20)), "Drag segment hits fish bounds")
	check(not renderer._segment_hits_rect(Vector2.ZERO, Vector2(100, 5), Rect2(30, 30, 20, 20)), "Drag segment outside fish does not catch")
	check(renderer._segment_hits_rect(Vector2(40, 40), Vector2(40, 40), Rect2(30, 30, 20, 20)), "Stationary click also hits fish")
	renderer.fish_clicked.disconnect(controller._cast_net)
	var caught_ids: Array[String] = []
	renderer.fish_clicked.connect(func(id: String): caught_ids.append(id))
	renderer.set_scene("pond")
	renderer.position = Vector2.ZERO
	renderer._pond_bounds = Rect2(0, 0, 200, 120)
	renderer._fish_hits = [{"id": "first", "rect": Rect2(30, 30, 20, 20)}, {"id": "second", "rect": Rect2(70, 30, 20, 20)}]
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = Vector2(10, 40)
	press.pressed = true
	renderer._input(press)
	var move := InputEventMouseMotion.new()
	move.position = Vector2(100, 40)
	renderer._input(move)
	check(caught_ids.is_empty(), "Dragging does not emit before release")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = move.position
	release.pressed = false
	renderer._input(release)
	check(caught_ids == ["first"], "Crossing two fish emits only the first on one release")
	controller.host.shutdown()
	controller.queue_free()
	await process_frame
	for path in [blocker_path, valid_path, valid_path + ".bak", valid_path + ".tmp", valid_path + ".bak.tmp"]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	if failures.is_empty():
		print("PASS: %d controller transaction/panel assertions" % assertions)
		quit(0)
	else:
		for detail in failures: printerr("FAIL: " + detail)
		quit(1)
