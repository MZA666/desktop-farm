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
	check(controller.model.state.animals.size() == 84 and controller.model.state.fish.size() == 36, "Expanded benchmark fixture has 84 animals and 36 fish")
	var species := {}
	for animal in controller.model.state.animals: species[str(animal.type_id)] = true
	check(species.size() == 11, "Expanded benchmark fixture includes all eleven animal species")
	check(controller.scene_window.content_scale_size.y == 388 and controller.toolbar.content_scale_size.y == 32 and controller.view.view_height == 352, "Expanded scenery uses its own 388-pixel window below the 32-pixel main toolbar")
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
	for name in ["hub", "crops", "inventory", "build", "animals", "farmers", "catalog", "settings", "pond"]:
		controller.panel_name = name
		controller._render_panel()
		check(controller.popup_body.get_child_count() > 0, "Panel renders: " + name)
	var seed_button: Button = controller.toolbar.find_child("SeedShop", true, false) as Button
	seed_button.pressed.emit()
	check(controller.panel_name == "crops" and controller.popup.visible, "Real seed shop button opens the shop panel")
	var search_field: LineEdit = controller.popup_body.find_child("CropSearch", true, false) as LineEdit
	search_field.text = "花椰菜"
	search_field.text_changed.emit(search_field.text)
	search_field.grab_focus()
	var quoted_button: Button = controller.popup_body.find_child("CropAction_cauliflower", true, false) as Button
	var prior_quote_cash: int = controller.model.balance()
	controller.model.state.coins = controller.model.protection()
	controller._refresh_open_shop()
	check(quoted_button.disabled, "A crop quote becomes unavailable when money no longer covers its reservation")
	controller.model.state.coins += 10000
	controller._refresh_open_shop()
	check(not quoted_button.disabled and controller.popup_body.find_child("CropAction_cauliflower", true, false) == quoted_button, "Natural income updates the existing crop action without replacing its control")
	check(controller.popup_body.find_child("CropSearch", true, false) == search_field and controller.popup.gui_get_focus_owner() == search_field and controller.crop_search == "花椰菜", "Quote refresh preserves the active search control, focus, and query")
	controller.model.state.coins = prior_quote_cash
	search_field.text = ""
	search_field.text_changed.emit("")
	controller._close_panel()
	check(not controller.popup.visible, "Closing a management panel hides the window")
	controller.toolbar.find_child("AnimalShop", true, false).pressed.emit()
	check(controller.panel_name == "animals", "Real animal shop button opens the animal shop")
	controller._close_panel()
	controller.crop_search = ""
	controller.crop_season = "全部"
	controller.crop_mechanism = "全部"
	controller.crop_unlocked_only = false
	controller.seed_shop_mode = "shop"
	check(controller._filtered_crops().size() == 53, "Unfiltered seed shop contains all 53 crops")
	controller.crop_search = "防风草"
	check(controller._filtered_crops().size() == 1 and controller._filtered_crops()[0].id == "parsnip", "Crop search matches the Chinese crop name")
	controller.crop_search = ""
	controller.crop_season = "夏"
	controller.crop_mechanism = "regrow"
	var filtered: Array = controller._filtered_crops()
	check(not filtered.is_empty() and filtered.all(func(c): return str(c.season).contains("夏") and str(c.mechanism) == "regrow"), "Season and harvest-type filters combine")
	controller.crop_season = "全部"
	controller.crop_mechanism = "全部"
	controller.crop_unlocked_only = true
	check(controller._filtered_crops().all(func(c): return controller.model.state.unlocked_crops.has(str(c.id))), "Unlocked-only filter excludes locked crops")
	controller.crop_unlocked_only = false
	var shop_snapshot: Dictionary = controller.model.snapshot()
	controller._prepare_preview()
	var budget_preview: Dictionary = controller._preview_command("set_default_seed", {"crop_id": "cauliflower"})
	check(budget_preview.ok and int(budget_preview.protection_after) > int(budget_preview.protection_before), "Default order preview calculates the increased seed reservation")
	check(JSON.stringify(controller.model.snapshot()) == JSON.stringify(shop_snapshot), "Command previews do not mutate live state, RNG, or transaction sequence")
	controller.model.state.coins = 0
	controller._prepare_preview()
	var blocked_preview: Dictionary = controller._preview_command("set_default_seed", {"crop_id": "cauliflower"})
	check(not blocked_preview.ok and int(blocked_preview.protection_after) > int(blocked_preview.protection_before), "Unaffordable default order still displays the proposed reservation")
	controller._open_panel("animals")
	var blocked_purchase: Button = controller.popup_body.find_child("AnimalAction_chicken", true, false) as Button
	check(blocked_purchase != null and blocked_purchase.disabled and not blocked_purchase.tooltip_text.is_empty(), "Unaffordable animal purchase is disabled with a concrete reason")
	controller.model.state.coins = controller.model.protection() + 10000
	controller._refresh_open_shop()
	check(not blocked_purchase.disabled and controller.popup_body.find_child("AnimalAction_chicken", true, false) == blocked_purchase, "Natural income enables the existing animal purchase control without rebuilding the page")
	controller.model.restore(shop_snapshot)
	controller._prepare_preview()
	check(not controller._preview_command("buy_animal", {"animal_id": "duck"}).ok, "Full shelter purchase is blocked in the UI preview")
	controller.model.state.animals = controller.model.state.animals.filter(func(animal): return str(controller.model.animal_types[str(animal.type_id)].shelter_id) != "duck_coop")
	controller.model.state.shelters.duck_coop = 0
	controller._prepare_preview()
	check(controller._preview_command("buy_animal", {"animal_id": "duck"}).message == "棚舍等级不足", "Missing shelter reports its level prerequisite")
	controller.model.restore(shop_snapshot)
	var before_buy: Dictionary = controller.model.snapshot()
	var prior_carrot: int = controller.model.seed_inventory_summary("carrot").total
	check(controller._act("buy_seeds", {"crop_id": "carrot", "count": 5}, false), "Seed quantity purchase commits through the controller")
	check(controller.model.balance() == int(before_buy.coins) - 5 * int(controller.model.crops.carrot.seed_price), "Purchase charges exactly the displayed seed quantity")
	check(int(controller.model.seed_inventory_summary("carrot").total) == prior_carrot + 5, "Purchase puts physical seeds in the library")
	controller.selected_plot_ids.clear()
	controller._choose_planting_seed("carrot")
	check(controller.view.selection_mode and controller.plant_controls.visible and not controller.popup.visible, "Choosing a seed opens field selection and the commit HUD")
	var selected_ids: Array = [str(controller.model.state.plots[0].id), str(controller.model.state.plots[1].id)]
	controller._on_plots_selected(selected_ids)
	check(controller.selected_plot_ids == selected_ids and not controller.plant_selection_button.disabled, "Multiple real plot IDs enable planting")
	controller.plant_selection_button.pressed.emit()
	check(controller.model.state.plots[0].crop_id == "parsnip" and controller.model.state.plots[0].pending_crop_id == "carrot", "Clicking the HUD preserves current crops and schedules next crops")
	check(not controller.view.selection_mode and not controller.plant_controls.visible, "Successful planting leaves selection mode")
	check(controller.saves.load_save().data.plots[0].pending_crop_id == "carrot", "Selected plot plan is saved immediately")
	check(controller._act("cancel_crop", {"plot_ids": selected_ids}, false), "Scheduled individual plans can be cancelled")
	check(int(controller.model.seed_inventory_summary("carrot").total) == prior_carrot + 5, "Cancelling the plan releases rather than destroys purchased seeds")
	controller._open_panel("inventory")
	check(controller.popup_body.find_child("SeedPlan_carrot", true, false) != null, "Purchased crop appears in the real library panel")
	await _test_inventory_search_reset(controller)
	controller._open_panel("settings")
	var speed_control: SpinBox = controller.popup_body.find_child("FarmerSpeed", true, false) as SpinBox
	check(speed_control != null and speed_control.min_value == 16 and speed_control.max_value == 48 and speed_control.step == 4, "Settings expose the bounded walking speed control")
	speed_control.value = 16
	check(int(controller.model.state.settings.farmer_speed) == 16 and int(controller.saves.load_save().data.settings.farmer_speed) == 16, "Speed selection updates model and persists immediately")
	controller.model.restore(shop_snapshot)
	var sale_animal: Dictionary = controller.model.state.animals.filter(func(animal): return str(animal.type_id) == "chicken")[0]
	var sale_instance: String = str(sale_animal.id)
	sale_animal.adult = true
	sale_animal.adult_remaining = 0.0
	sale_animal.product_remaining = 0.0
	controller.model._collect_animal(sale_animal)
	var sale_snapshot: Dictionary = controller.model.snapshot()
	var sale_details: Dictionary = controller._animal_sale_details(sale_instance)
	check(sale_details.refund == 400 and sale_details.product_value == 0 and sale_details.total == 400, "Sale confirmation quotes only the 50 percent refund")
	controller._begin_animal_sale(sale_instance)
	check(controller.panel_name == "sell_confirm" and controller.popup_body.find_child("ConfirmAnimalSale", true, false) != null, "Animal sale opens a second confirmation step")
	check(JSON.stringify(controller.model.snapshot()) == JSON.stringify(sale_snapshot), "Opening a sale confirmation does not sell or settle anything")
	controller.popup_body.find_child("ConfirmAnimalSale", true, false).pressed.emit()
	check(controller.model.balance() == int(sale_snapshot.coins) + 400 and controller.model.state.animals.size() == sale_snapshot.animals.size() - 1, "Confirming the sale commits only one refund")
	check(controller.model.state.ground_products == sale_snapshot.ground_products and controller.model.state.catalog == sale_snapshot.catalog, "Sale keeps independent ground produce and does not grant its discovery")
	var saved_sale: Dictionary = controller.saves.load_save()
	# Godot JSON decodes numbers as floats; compare equal serialized values,
	# not strict Variant types inside the nested batches/claims arrays.
	var expected_ground: Variant = JSON.parse_string(JSON.stringify(sale_snapshot.ground_products, "", true, true))
	check(saved_sale.ok and saved_sale.data.ground_products == expected_ground, "Preserved ground produce is durable immediately after the sale")
	var post_sale_cash: int = controller.model.balance()
	controller._confirm_animal_sale()
	check(controller.model.balance() == post_sale_cash, "Repeated sale confirmation cannot duplicate the refund")
	controller.catalog_category = "animal"
	check(controller._filtered_catalog_items().all(func(item): return str(item.category) == "animal"), "Catalog category filter only returns animal products")
	check(controller._catalog_sources("wool").size() == 2, "Catalog wool details include both sheep and rabbit sources")
	check(controller._catalog_sources("silver_fish") == ["鱼塘捕获 小银鱼"], "Catalog fish details point to manual fishing")
	check(controller._catalog_sources("unmilled_rice") == ["种植 未碾米"], "Raw rice catalog details include their harvest source before processing")
	check(controller.config.items.all(func(item): return not controller._catalog_sources(str(item.id)).is_empty()), "Every catalog product has at least one real acquisition source")
	controller.catalog_discovered_only = true
	check(controller._filtered_catalog_items().all(func(item): return controller.model.state.catalog.has(str(item.id))), "Discovered-only filter excludes undiscovered items")
	controller.catalog_category = "全部"
	controller.catalog_discovered_only = false
	controller.catalog_selection = "egg"
	controller.panel_name = "catalog_detail"
	controller._render_panel()
	check(controller.popup_body.get_child_count() > 0, "Catalog details render for a known product")
	controller.popup.size = Vector2i(540, 360)
	check(controller._catalog_columns() == 3, "Catalog grid adapts to the minimum supported panel width")
	controller.popup.size = Vector2i(760, 500)
	check(controller._catalog_columns() == 4, "Catalog grid uses four columns on the standard panel")
	controller._close_panel()
	_test_pond_modes_and_interaction(controller, blocker_path, valid_path)
	var renderer: FarmView = controller.view
	check(renderer._segment_hits_rect(Vector2(0, 40), Vector2(100, 40), Rect2(30, 30, 20, 20)), "Drag segment hits fish bounds")
	check(not renderer._segment_hits_rect(Vector2.ZERO, Vector2(100, 5), Rect2(30, 30, 20, 20)), "Drag segment outside fish does not catch")
	check(renderer._segment_hits_rect(Vector2(40, 40), Vector2(40, 40), Rect2(30, 30, 20, 20)), "Stationary click also hits fish")
	renderer.disconnect("net_cast_requested", controller._cast_net_area)
	var caught_centers: Array[Vector2] = []
	renderer.connect("net_cast_requested", func(center: Vector2): caught_centers.append(center))
	renderer.set_scene("pond")
	renderer.position = Vector2.ZERO
	renderer.resize_view(Vector2(1536, 352))
	renderer.page = 0
	renderer.set("camera_y", 0.0)
	renderer._update_camera()
	var world_layout = preload("res://scripts/world_layout.gd")
	var water_start := Vector2(720, 260)
	var water_finish := Vector2(810, 260)
	check(world_layout.fish_segment_safe(water_start, water_finish), "Synthetic drag fixture lies on a real safe water segment")
	var drag_start: Vector2 = renderer._to_screen(water_start)
	var drag_finish: Vector2 = renderer._to_screen(water_finish)
	renderer._pond_bounds = Rect2(renderer._to_screen(world_layout.water_bounds().position), world_layout.water_bounds().size)
	renderer._fish_hits = [{"id": "first", "rect": Rect2(drag_start + Vector2(20, -10), Vector2(20, 20))}, {"id": "second", "rect": Rect2(drag_start + Vector2(60, -10), Vector2(20, 20))}]
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = drag_start
	press.pressed = true
	renderer._input(press)
	var move := InputEventMouseMotion.new()
	move.position = drag_finish
	renderer._input(move)
	check(caught_centers.is_empty(), "Dragging does not emit before release")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = move.position
	release.pressed = false
	renderer._input(release)
	check(caught_centers == [water_finish], "Drag release emits one final area center, never fish crossed earlier")
	press.position = drag_start
	renderer._input(press)
	release.position = renderer._to_screen(Vector2(100,100))
	renderer._input(release)
	check(caught_centers.size() == 1 and not renderer.get("_net_valid"), "Dragging onto land cancels the cast")
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

func _inventory_cards(controller) -> Array[String]:
	var ids: Array[String] = []
	for button in controller.crop_list.find_children("SeedPlan_*", "Button", true, false):
		ids.append(str(button.name).trim_prefix("SeedPlan_"))
	return ids

func _stock_crop_ids(controller) -> Array[String]:
	var ids: Array[String] = []
	for crop in controller.config.crops:
		if int(controller.model.seed_inventory_summary(str(crop.id)).total) > 0: ids.append(str(crop.id))
	return ids

func _assert_crop_reset(controller, search: LineEdit, season: OptionButton, type_filter: OptionButton, unlocked: CheckBox, expected: Array[String], snapshot: Dictionary, selection: Array) -> void:
	check(controller.crop_search == "" and controller.crop_season == "全部" and controller.crop_mechanism == "全部" and not controller.crop_unlocked_only, "Clear filters resets all four controller filters")
	check(search.text.is_empty() and season.selected == 0 and type_filter.selected == 0 and not unlocked.button_pressed, "Clear filters synchronizes the existing text, dropdowns and checkbox")
	check(controller.popup_body.find_child("CropSearch", true, false) == search and controller.popup_body.find_child("CropSeasonFilter", true, false) == season and controller.popup_body.find_child("CropTypeFilter", true, false) == type_filter and controller.popup_body.find_child("CropUnlockedFilter", true, false) == unlocked, "Clearing filters preserves the original input controls")
	check(_inventory_cards(controller) == expected and expected.size() < controller.config.crops.size(), "Reset restores precisely the owned seed kinds rather than all shop crops")
	check(controller.model.snapshot() == snapshot and controller.selected_plot_ids == selection, "Reset changes no money, seed stock, transactions, crop plans or selected fields")

func _test_inventory_search_reset(controller) -> void:
	var baseline: Dictionary = controller.model.snapshot()
	var original_selection: Array = controller.selected_plot_ids.duplicate()
	var original_popup_size: Vector2i = controller.popup.size
	check(controller._act("buy_seeds", {"crop_id": "cauliflower", "count": 3}, false), "Search fixture purchases cauliflower through the real seed transaction")
	controller.selected_plot_ids = [str(controller.model.state.plots[0].id), str(controller.model.state.plots[1].id)]
	controller.view.set_selection(controller.selected_plot_ids)
	controller.crop_search = ""; controller.crop_season = "全部"; controller.crop_mechanism = "全部"; controller.crop_unlocked_only = false
	controller.toolbar.find_child("SeedInventory", true, false).pressed.emit()
	var search := controller.popup_body.find_child("CropSearch", true, false) as LineEdit
	var reset := controller.popup_body.find_child("CropClearFilters", true, false) as Button
	var season := controller.popup_body.find_child("CropSeasonFilter", true, false) as OptionButton
	var type_filter := controller.popup_body.find_child("CropTypeFilter", true, false) as OptionButton
	var unlocked := controller.popup_body.find_child("CropUnlockedFilter", true, false) as CheckBox
	check(search != null and reset != null and season != null and type_filter != null and unlocked != null, "Real inventory exposes search, reset and named filter controls")
	if search == null or reset == null or season == null or type_filter == null or unlocked == null:
		controller.model.restore(baseline)
		controller.selected_plot_ids = original_selection
		return
	check(search.clear_button_enabled and reset.text == "清除筛选", "Search has its built-in clear affordance and an explicit clear-filters button")
	var expected := _stock_crop_ids(controller)
	check(expected.size() >= 2 and expected.has("carrot") and expected.has("cauliflower") and _inventory_cards(controller) == expected, "Real purchased inventory contains both searched seed kinds before filtering")
	var protected_snapshot: Dictionary = controller.model.snapshot()
	var selected: Array = controller.selected_plot_ids.duplicate()
	for entry in [{"query": "花椰菜", "id": "cauliflower"}, {"query": "萝卜", "id": "carrot"}]:
		search.text = str(entry.query); search.text_changed.emit(search.text)
		check(_inventory_cards(controller) == [str(entry.id)], "Chinese inventory search displays a single owned crop: " + str(entry.query))
		check(not reset.disabled, "A nonempty search enables the real clear-filters button")
		reset.pressed.emit()
		_assert_crop_reset(controller, search, season, type_filter, unlocked, expected, protected_snapshot, selected)
	search.text = "花椰菜"; search.text_changed.emit(search.text)
	search.clear(); search.text_changed.emit(search.text)
	check(controller.crop_search.is_empty() and _inventory_cards(controller) == expected and controller.popup_body.find_child("CropSearch", true, false) == search, "Ordinary text clearing restores every current inventory kind without recreating search")
	search.text = "没有这个作物"; search.text_changed.emit(search.text)
	check(_inventory_cards(controller).is_empty() and not reset.disabled, "An empty result still exposes an enabled reset action")
	reset.pressed.emit()
	_assert_crop_reset(controller, search, season, type_filter, unlocked, expected, protected_snapshot, selected)
	search.text = "花椰菜"; search.text_changed.emit(search.text)
	season.select(2); season.item_selected.emit(2)
	type_filter.select(2); type_filter.item_selected.emit(2)
	unlocked.button_pressed = true
	check(controller.crop_season == "夏" and controller.crop_mechanism == "regrow" and controller.crop_unlocked_only and _inventory_cards(controller).is_empty(), "Search, season, harvest mechanism and unlocked-only restrictions combine")
	reset.pressed.emit()
	_assert_crop_reset(controller, search, season, type_filter, unlocked, expected, protected_snapshot, selected)
	# A filtered list is rebuilt once, without replacing focused input controls.
	# A dirty whitespace query keeps enough owned cards to exercise real scrolling.
	controller.popup.size = Vector2i(540, 360)
	search.text = " "; search.text_changed.emit(search.text)
	await process_frame
	await process_frame
	controller.popup_scroll.scroll_vertical = 100000
	check(controller.popup_scroll.scroll_vertical > 0, "Owned multi-kind inventory has a scrollable result before reset")
	var entered: Array[int] = [0]
	var count_entry := func(_node: Node): entered[0] += 1
	controller.crop_list.child_entered_tree.connect(count_entry)
	reset.pressed.emit()
	controller.crop_list.child_entered_tree.disconnect(count_entry)
	check(entered[0] == expected.size() + 1, "Clearing combined filters renders the result list exactly once")
	check(controller.popup_scroll.scroll_vertical == 0, "Clear filters returns the existing scroll container to the top")
	_assert_crop_reset(controller, search, season, type_filter, unlocked, expected, protected_snapshot, selected)
	controller.popup.size = original_popup_size
	search.text = "花椰菜"; search.text_changed.emit(search.text)
	search.grab_focus()
	var plan := controller.popup_body.find_child("SeedPlan_cauliflower", true, false) as Button
	var detail_before: String = controller._crop_quote_controls.cauliflower.detail.text
	controller.model.state.coins += 1
	controller._refresh_open_shop()
	check(controller.popup_body.find_child("CropSearch", true, false) == search and controller.popup.gui_get_focus_owner() == search and controller.crop_search == "花椰菜", "Quote-only refresh keeps the same focused inventory search and query")
	check(controller.popup_body.find_child("SeedPlan_cauliflower", true, false) == plan, "Quote-only refresh preserves the existing inventory card action")
	controller.model.state.seeds.cauliflower += 1
	controller._refresh_open_shop()
	check(controller.popup_body.find_child("SeedPlan_cauliflower", true, false) == plan and controller._crop_quote_controls.cauliflower.detail.text != detail_before, "Changing an existing stock quantity updates its quote without rebuilding membership")
	search.text = "萝卜"; search.text_changed.emit(search.text)
	search.grab_focus()
	controller.model.state.seeds.radish = 3
	controller._refresh_open_shop()
	check(_inventory_cards(controller) == ["carrot", "radish"] and controller.crop_search == "萝卜" and search.text == "萝卜", "A newly available matching inventory kind appears without changing the user's query")
	check(controller.popup_body.find_child("CropSearch", true, false) == search and controller.popup.gui_get_focus_owner() == search, "Natural inventory membership updates preserve the original focused input")
	controller.model.state.seeds.carrot = 0
	controller._refresh_open_shop()
	check(_inventory_cards(controller) == ["radish"] and controller.crop_search == "萝卜", "A naturally exhausted matching seed kind disappears while another match remains")
	controller.model.state.seeds.radish = 0
	controller._refresh_open_shop()
	check(_inventory_cards(controller).is_empty() and controller.crop_search == "萝卜" and not reset.disabled, "Exhausting the final matching kind preserves the query and a usable reset")
	reset.pressed.emit()
	check(_inventory_cards(controller) == _stock_crop_ids(controller) and search.text.is_empty(), "Reset after stock exhaustion recovers only the still-owned inventory kinds")
	# A one-kind vault must stay a one-kind vault after a reset; it is not the shop.
	controller.model.state.seeds = {"carrot": 2}
	controller.model.state.seed_reservations = []
	controller._refresh_open_shop()
	check(_inventory_cards(controller) == ["carrot"], "An inventory containing exactly one seed kind renders one card")
	search.text = "花椰菜"; search.text_changed.emit(search.text)
	check(_inventory_cards(controller).is_empty(), "Searching an unowned kind does not create a vault entry")
	var single_snapshot: Dictionary = controller.model.snapshot()
	reset.pressed.emit()
	_assert_crop_reset(controller, search, season, type_filter, unlocked, ["carrot"], single_snapshot, selected)
	# The final physical seed remains a vault member while a real farmer carries
	# it. Completing sow changes neither the stock dictionary nor seed claims.
	controller.model.state.seeds = {"carrot": 1}
	controller.model.state.seed_reservations = []
	controller.model.state.farmers = []
	controller.model._add_farmer("farm")
	var last_plot: Dictionary = controller.model.state.plots[0]
	last_plot.status = "empty"; last_plot.remaining = 0.0; last_plot.product = {}
	last_plot.crop_id = "carrot"; last_plot.preferred_crop_id = "carrot"
	last_plot.pending_crop_id = ""; last_plot.return_seed = false
	var last_worker: Dictionary = controller.model.state.farmers[0]
	controller.model._dispatch(last_worker)
	check(last_worker.task.action == "sow" and last_worker.task.crop_id == "carrot" and last_worker.task.seed_source == "inventory" and last_worker.phase == "walking", "Real farm dispatch claims the last physical carrot seed and starts walking")
	search.text = "胡萝卜"; search.text_changed.emit(search.text)
	search.grab_focus()
	controller._refresh_open_shop()
	var carried: Dictionary = controller.model.seed_inventory_summary("carrot")
	check(carried.total == 1 and carried.available == 0 and carried.in_flight == 1 and _inventory_cards(controller) == ["carrot"], "The last carried seed remains visible with total one despite zero available stock")
	var carried_plan := controller.popup_body.find_child("SeedPlan_carrot", true, false) as Button
	var stock_before: Dictionary = controller.model.state.seeds.duplicate(true)
	var claims_before: Array = controller.model.state.seed_reservations.duplicate(true)
	var coins_before: int = controller.model.balance()
	var protection_before: int = controller.model.protection()
	var carried_revision: String = controller._shop_state_revision()
	var route_length: float = controller.model.RANCH.path_length(controller.model.RANCH.point(last_worker), last_worker.path)
	controller.model._advance_farmer(last_worker, route_length / float(controller.model.state.settings.farmer_speed))
	check(last_worker.phase == "acting" and controller._shop_state_revision() == carried_revision, "Arriving at the plot does not change the stable carried-seed shop revision")
	controller._refresh_open_shop()
	check(controller.popup_body.find_child("SeedPlan_carrot", true, false) == carried_plan and controller.popup.gui_get_focus_owner() == search, "Travel-only progress does not rebuild the inventory card or disturb search focus")
	controller.model._advance_farmer(last_worker, float(last_worker.remaining))
	check(last_worker.task.is_empty() and last_plot.status == "unwatered" and controller.model.seed_inventory_summary("carrot").total == 0, "The full real sow action consumes the final in-flight seed exactly once")
	check(controller.model.state.seeds == stock_before and controller.model.state.seed_reservations == claims_before and controller.model.balance() == coins_before and controller.model.protection() == protection_before, "Task completion changes no stock dictionary, reservation ledger, coins or protected budget to mask the revision regression")
	controller._refresh_open_shop()
	check(_inventory_cards(controller).is_empty() and controller.popup_body.find_child("SeedPlan_carrot", true, false) == null, "Completing the last in-flight seed automatically removes that inventory member")
	check(controller.popup_body.find_child("CropSearch", true, false) == search and controller.popup.gui_get_focus_owner() == search and search.text == "胡萝卜" and controller.crop_search == "胡萝卜", "Automatic in-flight exhaustion preserves the search control, focus and user's query")
	check(controller.model.restore(baseline).ok, "Inventory search regression restores its original isolated model")
	controller.selected_plot_ids = original_selection
	controller.view.set_selection(original_selection)
	controller.crop_search = ""; controller.crop_season = "全部"; controller.crop_mechanism = "全部"; controller.crop_unlocked_only = false
	controller._close_panel()
	controller.view.set_model(controller.model.state, true)
	check(controller._save_now(), "Inventory search regression restores its original test-store snapshot")

func _test_pond_modes_and_interaction(controller, blocker_path: String, valid_path: String) -> void:
	var baseline: Dictionary = controller.model.snapshot()
	var fresh = controller.MODEL.new(controller.config)
	check(controller.model.restore(fresh.snapshot()).ok, "Pond controller tests start from a valid fresh model")
	controller.model.state.coins = 10000
	controller.save_blocked = false
	controller.saves.path = valid_path
	controller._apply_settings()
	controller._close_panel()
	var first_fish: Dictionary = controller.model.state.fish[0].duplicate(true)
	var first_product: String = str(controller.model.fish_types[str(first_fish.type_id)].product_id)
	var before_cast: Dictionary = controller.model.snapshot()
	controller.saves.path = blocker_path.path_join("cast-fails.json")
	check(not controller._act("cast_net", {"fish_id": first_fish.id}, false), "Failed disk write rejects an automatically settled catch")
	check(JSON.stringify(before_cast) == JSON.stringify(controller.model.snapshot()), "Failed catch restores fish, timers, catalog, cash, RNG and transaction ID")
	check(controller.save_blocked and not controller.popup.visible and controller.panel_name.is_empty(), "Failed catch blocks operations without opening a capture window")
	controller.saves.path = valid_path
	check(controller._save_now() and not controller.save_blocked, "Saving recovery clears a failed catch without settling it a second time")
	controller._cast_net(str(first_fish.id))
	check(controller.model.state.fish.size() == before_cast.fish.size() - 1 and controller.model.state.pending_fish.is_empty(), "One catch consumes exactly one fish immediately")
	check(controller.model.balance() == int(before_cast.coins) and controller.model.state.catalog.has(first_product), "First catch consumes the fish for automatic catalog registration")
	check(not controller.popup.visible and controller.panel_name.is_empty(), "Successful first catch does not open any window")
	var known_fish: Dictionary = controller.model.state.fish[0]
	var known_kind: Dictionary = controller.model.fish_types[str(known_fish.type_id)]
	# Make this species known independently of the random initial pool.
	controller.model.state.catalog[str(known_kind.product_id)] = {"id": str(known_kind.product_id), "name": str(known_kind.name), "count": 7, "first_obtained": 0.0, "sources": ["fish"], "sell_price": int(known_kind.sell_price)}
	controller.model.state.net_remaining = 0.0
	var catalog_before := JSON.stringify(controller.model.state.catalog)
	var cash_before: int = controller.model.balance()
	controller._cast_net(str(known_fish.id))
	check(controller.model.balance() == cash_before + int(known_kind.sell_price), "Known fish sells for its configured whole price")
	check(JSON.stringify(controller.model.state.catalog) == catalog_before, "Known fish sale leaves all catalog fields unchanged")
	check(not controller.popup.visible and controller.model.state.pending_fish.is_empty(), "Known catch also finishes without a capture window")
	var pending: Dictionary = controller.model.state.fish.pop_back()
	controller.model.state.pending_fish = pending
	controller.model.state.net_remaining = 7.0
	controller.model.state.fish_remaining = 37.0
	var pending_kind: Dictionary = controller.model.fish_types[str(pending.type_id)]
	var pending_product: String = str(pending_kind.product_id)
	var pending_known: bool = controller.model.state.catalog.has(pending_product)
	var before_pending: Dictionary = controller.model.snapshot()
	controller.saves.path = blocker_path.path_join("pending-fails.json")
	check(not controller._settle_pending_fish(), "Failed disk write rejects settlement of a migrated pending fish")
	check(JSON.stringify(before_pending) == JSON.stringify(controller.model.snapshot()), "Failed migrated settlement fully restores the captured fish and both timers")
	controller.saves.path = valid_path
	check(controller._save_now(), "Retry saving explicitly settles a retained migrated fish")
	check(controller.model.state.pending_fish.is_empty() and controller.model.state.net_remaining == 7.0 and controller.model.state.fish_remaining == 37.0, "Recovered pending settlement clears only the captured fish and keeps both timers")
	check(controller.model.balance() == int(before_pending.coins) + (int(pending_kind.sell_price) if pending_known else 0), "Recovered pending fish uses the same first-known settlement rule")
	check(controller.saves.load_save().data.pending_fish.is_empty(), "Recovered migrated fish settlement is persisted")
	var settled_cash: int = controller.model.balance()
	var settled_catalog := JSON.stringify(controller.model.state.catalog)
	check(controller._save_now() and controller.model.balance() == settled_cash and JSON.stringify(controller.model.state.catalog) == settled_catalog, "Repeated save retry cannot duplicate migrated settlement")
	var actor: Dictionary = controller.model.state.animals[0]
	actor.hungry = false
	actor.food_remaining = 300.0
	var before_progress: float = float(actor.adult_remaining)
	controller.view.emit_signal("animal_clicked", str(actor.id))
	check(float(controller.model.state.animals[0].adult_remaining) < before_progress, "Renderer animal click reaches the core interaction command")
	check(float(controller.model.state.animals[0].feedback_remaining) > 0 and controller.view.get("_feedback").has(str(actor.id)), "Committed interaction shows visible animal feedback")
	controller.model.state.coins = controller.model.protection() + 199
	controller._open_panel("pond")
	var net_button: Button = controller.popup_body.find_child("PondUpgradeNet", true, false) as Button
	var capacity_button: Button = controller.popup_body.find_child("PondUpgradeCapacity", true, false) as Button
	var area_button: Button = controller.popup_body.find_child("PondUpgradeArea", true, false) as Button
	check(net_button != null and capacity_button != null and area_button != null and area_button.disabled and net_button.disabled and not net_button.tooltip_text.is_empty(), "Pond panel disables upgrades that would consume protected seed funds")
	var before_upgrade: Dictionary = controller.model.snapshot()
	check(not controller._act("upgrade_net", {}, false) and JSON.stringify(before_upgrade) == JSON.stringify(controller.model.snapshot()), "Blocked pond upgrade changes neither coins nor timers")
	controller.model.state.coins += 10000
	controller._refresh_open_shop()
	check(not net_button.disabled and controller.popup_body.find_child("PondUpgradeNet", true, false) == net_button, "Income enables the existing pond upgrade control")
	var upgrade_cash: int = controller.model.balance()
	net_button.pressed.emit()
	check(controller.model.state.pond.net_level == 1 and controller.model.balance() == upgrade_cash - 200, "Real net upgrade button charges only the next level cost")
	capacity_button.pressed.emit()
	check(controller.model.state.pond.capacity_level == 1 and controller.model.balance() == upgrade_cash - 500, "Real pond capacity button independently charges 300")
	area_button.pressed.emit()
	check(controller.model.state.pond.net_area_level == 1 and controller.model.balance() == upgrade_cash - 800, "Real net area upgrade independently costs300")
	check(controller.saves.load_save().data.pond.net_area_level == 1 and controller.POND.net_catch_limit(controller.model.state, controller.config) == 2, "Area level and two-fish capacity persist")
	check(controller.model.state.net_remaining == 7.0 and controller.model.state.fish_remaining == 37.0, "All three UI upgrades preserve active pond timers")
	_test_area_batch(controller, blocker_path, valid_path)
	controller._close_panel()
	controller.toolbar.find_child("DisplayMode", true, false).pressed.emit()
	check(controller.model.state.settings.display_mode == "compact" and controller.scene_window.content_scale_size.y == 208 and controller.view.view_height == 172, "Real display mode button selects the compact scenery window")
	check(controller.saves.load_save().data.settings.display_mode == "compact" and controller.status_label.position.y == 188, "Compact mode and the scene-local bottom status location persist correctly")
	controller._open_panel("settings")
	var display: OptionButton = controller.popup_body.find_child("SettingsDisplayMode", true, false) as OptionButton
	controller.saves.path = blocker_path.path_join("display-fails.json")
	var before_display: Dictionary = controller.model.snapshot()
	display.select(0)
	display.item_selected.emit(0)
	check(JSON.stringify(controller.model.snapshot()) == JSON.stringify(before_display) and display.selected == 1 and controller.scene_window.content_scale_size.y == 208, "Failed display save keeps the model, actual scene height and selected settings item consistent")
	controller.saves.path = valid_path
	check(controller._save_now(), "Display setting save failure can be recovered")
	display.select(0)
	display.item_selected.emit(0)
	check(controller.model.state.settings.display_mode == "expanded" and controller.scene_window.content_scale_size.y == 388 and controller.view.view_height == 352, "Settings restore the expanded scenery without scaling sprites down")
	check(controller.saves.load_save().data.settings.display_mode == "expanded" and controller.status_label.position.y == 368, "Expanded mode and the scene-local bottom status location persist correctly")
	var prior_window_size: Vector2i = controller.scene_window.size
	controller.scene_window.size = Vector2i(640, 388)
	controller._sync_layout()
	var toolbar_row: HBoxContainer = controller.toolbar_row
	check(toolbar_row.get_combined_minimum_size().x <= 628, "Toolbar still fits the 640 logical pixel desktop width")
	check(controller.toolbar.find_child("CameraUp", true, false).visible and controller.toolbar.find_child("CameraCenter", true, false).visible and controller.toolbar.find_child("CameraNext", true, false).visible and controller.display_mode_button.visible and controller.collapse_button.visible, "Narrow toolbar keeps both-axis camera, centering, display mode and collapse controls reachable")
	controller.scene_window.size = prior_window_size
	controller._sync_layout()
	var original_camera: float = float(controller.view.get("camera_y"))
	controller.toolbar.find_child("CameraDown", true, false).pressed.emit()
	check(float(controller.view.get("camera_y")) > original_camera, "Real down camera button moves the vertical view")
	controller.toolbar.find_child("CameraUp", true, false).pressed.emit()
	check(is_equal_approx(float(controller.view.get("camera_y")), original_camera), "Up button reverses one fine down step")
	controller.toolbar.find_child("CameraCenter", true, false).pressed.emit()
	check(is_equal_approx(float(controller.view.get("camera_y")),80), "Center toolbar button shows the actual middle in expanded mode")
	controller._close_panel()
	check(controller.model.restore(baseline).ok, "Controller fixture restores after isolated pond tests")
	controller._apply_settings()
	controller.view.set_model(controller.model.state, true)
	controller._save_now()

func _test_area_batch(controller, blocker_path: String, valid_path: String) -> void:
	var before: Dictionary = controller.model.snapshot()
	controller.model.state.pond.net_area_level = 3
	controller.model.state.net_remaining = 0.0
	var template: Dictionary = controller.model.state.fish[0].duplicate(true)
	var product := str(controller.model.fish_types[str(template.type_id)].product_id)
	controller.model.state.catalog.erase(product)
	controller.model.state.fish = []
	for index in range(5):
		var fish: Dictionary = template.duplicate(true)
		fish.id = "area_ui_%d" % index
		for key in ["x", "previous_x", "target_x"]: fish[key] = 800.0 + index * 8
		for key in ["y", "previous_y", "target_y"]: fish[key] = 260.0
		controller.model.state.fish.append(fish)
	var staged: Dictionary = controller.model.snapshot()
	controller.saves.path = blocker_path.path_join("area-batch-fails.json")
	var feedback_count: int = controller.view.get("_income_feedback").size()
	controller._cast_net_area(Vector2(800,260))
	check(JSON.stringify(controller.model.snapshot()) == JSON.stringify(staged), "Failed batch save restores all fish, discoveries, cash and cooldown")
	check(controller.last_action_result.is_empty() and controller.view.get("_income_feedback").size() == feedback_count, "Rejected disk write emits no sale feedback")
	controller.saves.path = valid_path
	check(controller._save_now(), "Batch save failure can be recovered")
	var cash: int = controller.model.balance()
	controller._cast_net_area(Vector2(800,260))
	var price: int = int(controller.model.fish_types[str(template.type_id)].sell_price)
	check(controller.model.state.fish.size() == 1 and controller.last_action_result.count == 4, "Actual coordinate cast commits four of five nearby fish")
	check(controller.last_action_result.discovered_count == 1 and controller.last_action_result.sold_count == 3 and controller.model.balance() == cash + price*3, "New same-species batch consumes one and sells three")
	check(controller.model.state.catalog.has(product) and controller.panel_name == "pond", "Batch uses automatic discovery without a capture popup")
	var stored: Dictionary = controller.saves.load_save().data
	check(stored.fish.size() == 1 and stored.pond.net_area_level == 3 and stored.coins == controller.model.balance(), "Entire batch is persisted as one transaction")
	check(controller.model.restore(before).ok, "Area test restores its original valid model")
	check(controller._save_now(), "Area test restores the fixture disk snapshot")
