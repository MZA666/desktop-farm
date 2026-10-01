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
	for name in ["hub", "crops", "inventory", "build", "animals", "farmers", "catalog", "settings", "caught"]:
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
	controller.model.state.animals = controller.model.state.animals.filter(func(animal): return str(animal.type_id) != "duck")
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
	controller._open_panel("settings")
	var speed_control: SpinBox = controller.popup_body.find_child("FarmerSpeed", true, false) as SpinBox
	check(speed_control != null and speed_control.min_value == 16 and speed_control.max_value == 48 and speed_control.step == 4, "Settings expose the bounded walking speed control")
	speed_control.value = 16
	check(int(controller.model.state.settings.farmer_speed) == 16 and int(controller.saves.load_save().data.settings.farmer_speed) == 16, "Speed selection updates model and persists immediately")
	controller.model.restore(shop_snapshot)
	var sale_instance: String = controller.model.state.animals[0].id
	controller.model.state.animals[0].ready = 1
	var sale_snapshot: Dictionary = controller.model.snapshot()
	var sale_details: Dictionary = controller._animal_sale_details(sale_instance)
	check(sale_details.refund == 400 and sale_details.product_value == 50 and sale_details.total == 450, "Sale confirmation separates the 50 percent refund and mature product settlement")
	controller._begin_animal_sale(sale_instance)
	check(controller.panel_name == "sell_confirm" and controller.popup_body.find_child("ConfirmAnimalSale", true, false) != null, "Animal sale opens a second confirmation step")
	check(JSON.stringify(controller.model.snapshot()) == JSON.stringify(sale_snapshot), "Opening a sale confirmation does not sell or settle anything")
	controller.popup_body.find_child("ConfirmAnimalSale", true, false).pressed.emit()
	check(controller.model.balance() == int(sale_snapshot.coins) + 450 and controller.model.state.animals.size() == sale_snapshot.animals.size() - 1, "Confirming the sale commits refund and product settlement once")
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
