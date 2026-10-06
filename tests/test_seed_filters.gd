extends SceneTree

## Source main-scene GUI regression. Queries and stock are isolated fixture
## setup; every reset button/LineEdit clear-icon action is a real native click.
const MAIN = preload("res://scenes/main.tscn")
const STOCK_IDS := ["parsnip", "carrot", "cauliflower"]
const SCREENSHOTS := "res://docs/screenshots/v0.8.5"
var controller: Node
var probe_pid := -1
var prefix := ""
var failed := false
var checks := 0
var steps := 0
var evidence: Array = []

func _initialize() -> void:
	if OS.get_name() != "Windows" or DisplayServer.get_name() == "headless" or not OS.get_cmdline_user_args().has("--benchmark-fixture"):
		printerr("Seed-filter real-input regression requires Windows GUI and --benchmark-fixture")
		quit(2)
		return
	_start.call_deferred()

func require(condition: bool, message: String) -> bool:
	checks += 1
	if condition: return true
	failed = true
	printerr("FAIL: " + message)
	return false

func _start() -> void:
	var review := ProjectSettings.globalize_path("res://.review")
	if not require(DirAccess.make_dir_recursive_absolute(review) == OK, "Create isolated evidence directory"): quit(1); return
	prefix = review.path_join("seed-filter-input-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	controller = MAIN.instantiate()
	root.add_child(controller)
	# Stop this fixture before its first simulation/process frame. The native
	# host still polls its own windows, so real focus and input stay exercised.
	controller.set_process(false)
	if not require(controller.get("benchmark_fixture") == true and controller.get("host") != null and controller.host.ready_for_desktop, "Actual source main starts in the independent benchmark namespace"):
		await _finish(); return
	controller.host.set_clock_paused(true)
	controller.saves.path = prefix + "-fixture-save.json"
	controller.model.state.seeds = {"parsnip": 20, "carrot": 8, "cauliflower": 6}
	controller.model.state.seed_reservations = []
	controller.model.command("settings", {"values": {"interactive": true, "collapsed": false, "display_mode": "expanded"}})
	controller._apply_settings()
	if not require(controller.model._validate(controller.model.snapshot()).ok, "Three-species seed stock remains a legal SAVE6 fixture"):
		await _finish(); return
	controller.crop_search = ""
	controller.crop_season = "全部"
	controller.crop_mechanism = "全部"
	controller.crop_unlocked_only = false
	controller._open_panel("inventory")
	await _place_panel(Vector2i(760, 500))
	var popup_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, controller.popup.get_window_id())
	if not require(popup_handle != 0, "Fixture management window has a native handle"):
		await _finish(); return
	# camera_input_probe's first handle is its guarded real-click target; its
	# second is the wheel target. Use this same owned popup for both roles.
	# The helper validates the HWND's PID and WindowFromPoint before SendInput,
	# and activates only the external window that it created itself.
	probe_pid = OS.create_process(ProjectSettings.globalize_path("res://native/bin/camera_input_probe.exe"), [prefix, str(popup_handle), str(popup_handle)])
	if not require(probe_pid > 0, "Existing PID/WindowFromPoint-guarded native helper launches"):
		await _finish(); return
	var deadline := Time.get_ticks_msec() + 5000
	while not FileAccess.file_exists(prefix + ".ready") and OS.is_process_running(probe_pid) and Time.get_ticks_msec() < deadline:
		await process_frame
	if not require(FileAccess.file_exists(prefix + ".ready"), "Unlocked-desktop helper is ready"):
		await _finish(); return
	if not (await _cases()): failed = true
	await _finish()

func _cases() -> bool:
	if not _inventory_matches(STOCK_IDS, "Initial library exposes all three owned seed types"): return false
	var search := _search()
	if not require(search != null and search.clear_button_enabled, "Search exposes the native LineEdit clear icon"): return false
	await _query("花椰菜")
	if not _inventory_matches(["cauliflower"], "Searching a Chinese crop name shows exactly that owned type"): return false
	if not (await _capture("seed-library-filtered")): return false
	if not (await _reset("single_result_reset")): return false
	if not _inventory_matches(STOCK_IDS, "One real reset click restores all owned seeds"): return false
	if not require(_search() == search, "Reset updates the existing search control instead of replacing it"): return false
	if not (await _capture("seed-library-reset")): return false
	await _query("胡萝卜")
	# Use the configured display name because source translations may change.
	if controller._filtered_crops().size() != 1:
		await _query(str(controller.model.crops.carrot.name))
	if not _inventory_matches(["carrot"], "Second search isolates the other seed type"): return false
	if not (await _clear_icon("builtin_clear_icon")): return false
	if not require(controller.crop_search.is_empty() and _search().text.is_empty(), "LineEdit X clears both the visible text and authoritative query"): return false
	if not _inventory_matches(STOCK_IDS, "Real LineEdit X restores the full library without a panel rebuild"): return false
	await _query("不存在的测试作物")
	if not _inventory_matches([], "An unmatched query renders zero results"): return false
	if not (await _reset("zero_result_reset")): return false
	if not _inventory_matches(STOCK_IDS, "Zero-result reset restores the complete owned set"): return false
	await _set_combined_filters()
	if not require(not controller.crop_search.is_empty() and controller.crop_season != "全部" and controller.crop_mechanism != "全部" and controller.crop_unlocked_only, "All four filters are active before the combined reset"): return false
	if not (await _reset("combined_filter_reset")): return false
	if not _all_filters_clear(): return false
	if not _inventory_matches(STOCK_IDS, "Combined reset restores all owned types, including other seasons and mechanisms"): return false
	# Stock can change while the player is reading this panel. Membership should
	# update without destroying search text, focus, or the persistent controls.
	var original_search := _search()
	controller.model.state.seeds.carrot = 0
	controller._refresh_open_shop()
	await _settle_layout()
	if not _inventory_matches(["parsnip", "cauliflower"], "Using the final seed removes its now-empty inventory card"): return false
	if not require(_search() == original_search, "Membership removal retains the same search control"): return false
	controller.model.state.seeds.carrot = 8
	controller._refresh_open_shop()
	await _settle_layout()
	if not _inventory_matches(STOCK_IDS, "Newly received stock appears without closing the inventory"): return false
	await _query("花椰菜")
	search = _search()
	search.grab_focus()
	search.caret_column = 2
	var card_button: Button = controller.popup_body.find_child("SeedPlan_cauliflower", true, false) as Button
	controller.model.state.seeds.cauliflower += 3
	controller._refresh_open_shop()
	await _settle_layout()
	if not require(_search() == search and controller.popup.gui_get_focus_owner() == search and search.caret_column == 2 and controller.crop_search == "花椰菜", "Same-membership stock refresh preserves search control, query, caret, and focus"): return false
	if not require(controller.popup_body.find_child("SeedPlan_cauliflower", true, false) == card_button, "Quantity-only refresh preserves the existing seed action"): return false
	if not (await _reset("after_stock_refresh_reset")): return false
	# Reopening another panel must not inherit a deep scroll position. Switching
	# tabs keeps the chosen filters, with an explicit reachable reset on either.
	controller._open_panel("crops")
	await _place_panel(Vector2i(760, 500))
	await _query("花椰菜")
	if not (await _reset("shop_single_result_reset")): return false
	if not require(controller._filtered_crops().size() == controller.config.crops.size() and controller._crop_list_ids.size() == 53, "Shop reset exposes all 53 offered crop types rather than inventory-only stock"): return false
	controller.popup_scroll.scroll_vertical = 1000
	await _settle_layout()
	if not require(controller.popup_scroll.scroll_vertical > 0, "Long shop panel can be deliberately scrolled for the reopening regression"): return false
	controller._open_panel("inventory")
	await _place_panel(Vector2i(540, 360))
	if not require(controller.popup.size == Vector2i(540, 360) and controller.popup_scroll.scroll_vertical == 0, "Opening the narrow library restores its top position"): return false
	await _query("花椰菜")
	var bar: VScrollBar = controller.popup_scroll.get_v_scroll_bar()
	var scroll_room := maxi(0, floori(bar.max_value - bar.page))
	controller.popup_scroll.scroll_vertical = mini(24, scroll_room)
	await _settle_layout()
	if not require(controller.popup_scroll.scroll_vertical > 0, "Narrow filtered panel exercises a nonzero scroll before reset"): return false
	if not (await _capture("seed-library-narrow-filtered")): return false
	if not (await _reset("narrow_reachable_reset_returns_top")): return false
	if not _inventory_matches(STOCK_IDS, "Narrow reset restores all stock types"): return false
	if not require(controller.popup_scroll.scroll_vertical == 0, "Real reset returns the narrow panel to the top"): return false
	if not (await _capture("seed-library-narrow-reset")): return false
	await _query("花椰菜")
	if not (await _clear_icon("narrow_builtin_clear_icon")): return false
	return _inventory_matches(STOCK_IDS, "The built-in clear icon remains usable at 540x360")

func _query(value: String) -> void:
	var search := _search()
	search.text = value
	# Fixture setup replaces keyboard entry; clearing always uses real input.
	search.text_changed.emit(value)
	await _settle_layout()

func _set_combined_filters() -> void:
	await _query("防风草")
	var seasons: OptionButton = controller.popup_body.find_child("CropSeasonFilter", true, false) as OptionButton
	var types: OptionButton = controller.popup_body.find_child("CropTypeFilter", true, false) as OptionButton
	var unlocked: CheckBox = controller.popup_body.find_child("CropUnlockedFilter", true, false) as CheckBox
	seasons.select(2)
	seasons.item_selected.emit(2)
	types.select(2)
	types.item_selected.emit(2)
	unlocked.set_pressed_no_signal(true)
	unlocked.toggled.emit(true)
	await _settle_layout()

func _search() -> LineEdit:
	return controller.popup_body.find_child("CropSearch", true, false) as LineEdit

func _all_filters_clear() -> bool:
	var seasons: OptionButton = controller.popup_body.find_child("CropSeasonFilter", true, false) as OptionButton
	var types: OptionButton = controller.popup_body.find_child("CropTypeFilter", true, false) as OptionButton
	var unlocked: CheckBox = controller.popup_body.find_child("CropUnlockedFilter", true, false) as CheckBox
	return require(controller.crop_search.is_empty() and controller.crop_season == "全部" and controller.crop_mechanism == "全部" and not controller.crop_unlocked_only and _search().text.is_empty() and seasons.selected == 0 and types.selected == 0 and not unlocked.button_pressed, "Reset synchronizes all four model-side filters and their existing controls")

func _inventory_matches(expected: Array, label: String) -> bool:
	var wanted: Array = expected.duplicate()
	wanted.sort()
	var actual: Array = []
	for crop in controller._filtered_crops(): actual.append(str(crop.id))
	actual.sort()
	var rendered: Array = controller._crop_quote_controls.keys()
	rendered.sort()
	return require(actual == wanted and rendered == wanted, label + "; expected=" + str(wanted) + " actual=" + str(actual) + " rendered=" + str(rendered))

func _reset(label: String) -> bool:
	var button: Button = controller.popup_body.find_child("CropClearFilters", true, false) as Button
	if not require(button != null and not button.disabled, "Explicit reset is available: " + label): return false
	var event_count := {"pressed": 0}
	button.pressed.connect(func(): event_count.pressed += 1, CONNECT_ONE_SHOT)
	if not (await _real_click(button, button.size * 0.5, label)): return false
	return require(event_count.pressed == 1 and controller.popup_scroll.scroll_vertical == 0, "One real button event clears the filter and returns to top: " + label)

func _clear_icon(label: String) -> bool:
	var search := _search()
	if not require(search != null and search.clear_button_enabled and not search.text.is_empty(), "Visible nonempty LineEdit exposes its built-in X: " + label): return false
	var icon: Texture2D = search.get_theme_icon("clear", "LineEdit")
	var style: StyleBox = search.get_theme_stylebox("normal", "LineEdit")
	if not require(icon != null and style != null, "Use the actual clear-icon and padding dimensions"): return false
	var event_count := {"changed": 0}
	search.text_changed.connect(func(_value: String): event_count.changed += 1, CONNECT_ONE_SHOT)
	var point := Vector2(search.size.x - style.get_margin(SIDE_RIGHT) - icon.get_width() * 0.5, search.size.y * 0.5)
	if not (await _real_click(search, point, label)): return false
	return require(event_count.changed == 1 and search.text.is_empty() and controller.crop_search.is_empty(), "One actual X click emits one text change and clears both query representations: " + label)

func _place_panel(size_value: Vector2i) -> void:
	var work: Rect2i = controller.host.get_work_area()
	controller.popup.size = size_value
	# Leave the helper's own external-app target at work+(40,40) unobstructed.
	controller.popup.position = work.position + Vector2i(280, 160)
	await _settle_layout()

func _settle_layout() -> void:
	for unused in range(6): await process_frame

func _real_click(control: Control, local_point: Vector2, label: String) -> bool:
	await _settle_layout()
	var bounds := control.get_global_rect()
	var clip: Rect2 = controller.popup_scroll.get_global_rect()
	if not require(control.is_visible_in_tree() and clip.encloses(bounds), "Action is fully reachable within the visible scroll viewport: " + label): return false
	var logical_point: Vector2 = control.get_global_transform_with_canvas() * local_point
	var visible: Rect2 = controller.popup.get_visible_rect()
	var scale := Vector2(controller.popup.size) / visible.size
	var native_origin := DisplayServer.window_get_position(controller.popup.get_window_id())
	var screen := native_origin + Vector2i((logical_point * scale).round())
	var snapshot := JSON.stringify(controller.model.snapshot(), "", true, true)
	if not (await _native_step(screen, label)): return false
	await _settle_layout()
	return require(JSON.stringify(controller.model.snapshot(), "", true, true) == snapshot, "Search/filter input does not alter money, seeds, plots, timers, RNG, or transactions: " + label)

func _native_step(point: Vector2i, label: String) -> bool:
	var file := FileAccess.open(prefix + ".step", FileAccess.WRITE)
	if not require(file != null, "Write guarded input handshake"): return false
	file.store_string("%d %d %d 0" % [steps, point.x, point.y])
	file.close()
	var ack := ""
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline and OS.is_process_running(probe_pid):
		await process_frame
		if FileAccess.file_exists(prefix + ".ack"):
			var value := FileAccess.get_file_as_string(prefix + ".ack").strip_edges()
			if value.split(" ").size() == 4 and int(value.get_slice(" ", 0)) == steps:
				ack = value
				break
	if not require(not ack.is_empty() and int(ack.get_slice(" ", 1)) == 1, "WindowFromPoint/PID and real foreground guards passed: " + label): return false
	evidence.append({"step": steps, "case": label, "native_point": [point.x, point.y], "popup_size": [controller.popup.size.x, controller.popup.size.y], "native_ack": ack})
	steps += 1
	return true

func _capture(name_value: String) -> bool:
	var directory := ProjectSettings.globalize_path(SCREENSHOTS)
	if not require(DirAccess.make_dir_recursive_absolute(directory) == OK, "Create requested screenshot directory"): return false
	await RenderingServer.frame_post_draw
	var pixels: Image = controller.popup.get_texture().get_image()
	return require(pixels != null and not pixels.is_empty() and pixels.save_png(directory.path_join(name_value + ".png")) == OK, "Save actual management-window screenshot: " + name_value)

func _finish() -> void:
	var done := FileAccess.open(prefix + ".done", FileAccess.WRITE)
	if done != null:
		done.store_string("1")
		done.close()
	var deadline := Time.get_ticks_msec() + 3000
	while probe_pid > 0 and OS.is_process_running(probe_pid) and Time.get_ticks_msec() < deadline:
		await process_frame
	if probe_pid > 0 and OS.is_process_running(probe_pid): OS.kill(probe_pid)
	var output := FileAccess.open(prefix + ".json", FileAccess.WRITE)
	if output != null:
		output.store_string(JSON.stringify({"passed": not failed, "checks": checks, "real_clicks": steps, "samples": evidence}, "", true, true))
		output.close()
	if is_instance_valid(controller) and controller.get("host") != null: controller.host.shutdown()
	print("SEED_FILTER_GUI_", "FAIL" if failed else "PASS", " real_clicks=", steps, " checks=", checks)
	quit(1 if failed else 0)
