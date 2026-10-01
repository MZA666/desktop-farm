extends Node

const MODEL = preload("res://scripts/game_state.gd")
const STORE = preload("res://scripts/save_store.gd")
const VIEW = preload("res://scripts/farm_view.gd")
const HOST = preload("res://scripts/desktop_host.gd")
const ASSETS = preload("res://scripts/pixel_assets.gd")
const SCENE_NAMES := {"farm": "农场", "ranch": "牧场", "pond": "鱼塘"}
const INK := Color("#4f3828")
const CREAM := Color("#f4e6c8")
const MUTED := Color("#8a735b")
const ALERT := Color("#a14732")
const CATEGORY_NAMES := {"crop": "作物", "animal": "动物产物", "fish": "鱼"}
var model: FarmState
var saves: FarmSaveStore
var view: FarmView
var host: DesktopHost
var config: Dictionary
var toolbar: Window
var popup: Window
var popup_body: VBoxContainer
var coin_label: Label
var status_label: Label
var mode_button: Button
var collapse_button: Button
var page_label: Label
var theme: Theme
var current_scene := "farm"
var panel_name := ""
var region_selection := 0
var auto_save_elapsed := 0.0
var ui_elapsed := 0.0
var toast := "欢迎来到桌面农场。农夫会自动照料，你也可以点击地块浇水。"
var toast_remaining := 12.0
var save_blocked := false
var startup_blocked := false
var quitting := false
var smoke_path := ""
var benchmark_fixture := false
var benchmark_options: Dictionary = {}
var _dragging := false
var _drag_mouse := Vector2i.ZERO
var _drag_origin := Vector2i.ZERO
var crop_search := ""
var crop_season := "全部"
var crop_mechanism := "全部"
var crop_unlocked_only := false
var crop_list: VBoxContainer
var catalog_category := "全部"
var catalog_discovered_only := false
var catalog_search := ""
var catalog_selection := ""
var catalog_grid: GridContainer
var sell_selection := ""
var animal_shop_mode := "buy"
var animal_shelter_filter := "全部"
var _preview_model: FarmState
var _preview_snapshot: Dictionary = {}
var _shop_refresh_elapsed := 0.0
var _shop_revision := ""
var _crop_quote_controls: Dictionary = {}
var _animal_quote_controls: Dictionary = {}
var _owned_animal_controls: Dictionary = {}
var _catalog_revision := 0
var _catalog_count_label: Label
var _budget_footer: Label
var _region_status_label: Label
var _sale_controls: Dictionary = {}

func _ready() -> void:
	get_tree().auto_accept_quit = false
	Engine.max_fps = 30
	config = JSON.parse_string(FileAccess.get_file_as_string("res://data/production.json"))
	model = MODEL.new(config)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--smoke-screenshot="):
			smoke_path = argument.trim_prefix("--smoke-screenshot=")
		if argument == "--benchmark-fixture": benchmark_fixture = true
	if not _parse_benchmark_options():
		get_tree().quit(2)
		return
	var test_directory := "res://.review" if OS.has_feature("editor") else "user://test-data"
	saves = STORE.new("user://test-data/benchmark-save.json" if benchmark_fixture else ("user://desktop-farm-save.json" if smoke_path.is_empty() else test_directory.path_join("ui-smoke-save.json")))
	theme = _make_theme()
	if benchmark_fixture: _make_benchmark_fixture()
	else: _load_game()
	# The desktop game follows normal application Z order, including old saves.
	model.state.settings.topmost = false
	view = VIEW.new()
	# Reuse the same system-font resource for menus and scenery text.
	view._font = theme.default_font as SystemFont
	view.position = Vector2(0, 40)
	view.configure(config)
	view.set_model(model.state)
	view.plot_clicked.connect(func(id: String): _act("water", {"plot_id": id}, false))
	view.fish_clicked.connect(_cast_net)
	add_child(view)
	_build_status()
	_build_toolbar()
	_build_popup()
	host = HOST.new()
	add_child(host)
	host.status_changed.connect(_show_message)
	host.suspend_requested.connect(_save_now)
	host.display_changed.connect(func(_area: Rect2i): _sync_layout())
	host.tray_action.connect(_on_tray_action)
	host.desktop_visibility_changed.connect(func(visible: bool, _reason: String):
		view.set_process(visible and not bool(model.state.settings.collapsed))
		if view.has_method("set_desktop_suspended"):
			view.call("set_desktop_suspended", not visible or bool(model.state.settings.collapsed)))
	host.register_auxiliary_window(popup)
	var desktop_ok := host.start(get_window(), toolbar, model.state.settings)
	if not desktop_ok and DisplayServer.get_name() != "headless":
		if ClassDB.class_exists("DesktopNative") and host.native == null:
			get_tree().quit(2)
			return
		get_window().size = Vector2i(1280, 240)
		get_window().position = Vector2i(80, 600)
		toolbar.size = Vector2i(1280, 32)
		toolbar.position = get_window().position
	get_window().transparent_bg = true
	get_window().size_changed.connect(_sync_layout)
	toolbar.close_requested.connect(_quit_game)
	_sync_layout()
	_apply_settings()
	_refresh_labels()
	if startup_blocked:
		_open_panel("save_error")
	elif not model.state.pending_fish.is_empty():
		_open_panel("caught")
	if not smoke_path.is_empty():
		_smoke_capture.call_deferred()
	if not benchmark_options.is_empty():
		_run_benchmark.call_deferred()

func _make_theme() -> Theme:
	var result := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "微软雅黑", "sans-serif"])
	result.default_font = font
	result.default_font_size = 14
	result.set_color("font_color", "Label", INK)
	result.set_color("font_color", "Button", INK)
	result.set_color("font_hover_color", "Button", INK)
	result.set_color("font_pressed_color", "Button", INK)
	result.set_color("font_disabled_color", "Button", Color("#879486"))
	for control_type in ["CheckBox", "OptionButton", "LineEdit"]:
		result.set_color("font_color", control_type, INK)
		result.set_color("font_hover_color", control_type, INK)
		result.set_color("font_pressed_color", control_type, INK)
		result.set_color("font_disabled_color", control_type, MUTED)
	result.set_color("font_placeholder_color", "LineEdit", MUTED)
	result.set_color("caret_color", "LineEdit", INK)
	for item in ["normal", "hover", "pressed", "disabled", "focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = Color("#e9c995") if item == "normal" else Color("#efd9b0")
		if item == "pressed": box.bg_color = Color("#d7b57f")
		if item == "disabled": box.bg_color = Color("#e2d8c3")
		if item == "focus": box.bg_color = Color(0, 0, 0, 0)
		box.border_color = Color("#876042") if item != "focus" else Color("#c38d40")
		box.set_border_width_all(2)
		box.content_margin_left = 8
		box.content_margin_right = 8
		box.content_margin_top = 3
		box.content_margin_bottom = 3
		result.set_stylebox(item, "Button", box)
		result.set_stylebox(item, "OptionButton", box)
		result.set_stylebox(item, "LineEdit", box)
	result.set_stylebox("panel", "PanelContainer", _wood_panel_style())
	result.set_constant("separation", "HBoxContainer", 6)
	result.set_constant("separation", "VBoxContainer", 8)
	return result

func _wood_panel_style() -> StyleBoxFlat:
	var frame := StyleBoxFlat.new()
	frame.bg_color = Color("#f9eed5")
	frame.border_color = Color("#9c704b")
	frame.set_border_width_all(3)
	frame.content_margin_left = 10
	frame.content_margin_right = 10
	frame.content_margin_top = 8
	frame.content_margin_bottom = 8
	return frame

func _load_game() -> void:
	var loaded := saves.load_save()
	if loaded.ok:
		var restored := model.restore(loaded.data)
		if not restored.ok:
			var backup := saves.load_backup()
			if backup.ok and model.restore(backup.data).ok:
				_show_message("主存档规则校验失败，已恢复上一完整备份。")
			else:
				startup_blocked = true
				_show_message(restored.message)
		elif loaded.get("from_backup", false):
			_show_message(loaded.message)
	elif not loaded.get("missing", false):
		startup_blocked = true
		_show_message(loaded.message)
	else:
		var saved := saves.save(model.snapshot())
		if not saved.ok:
			save_blocked = true
			_show_message(saved.message)

func _build_toolbar() -> void:
	toolbar = Window.new()
	toolbar.title = "桌面农场 · 控制栏"
	toolbar.borderless = true
	toolbar.unresizable = true
	toolbar.transparent = false
	toolbar.theme = theme
	toolbar.min_size = Vector2i(600, 32)
	add_child(toolbar)
	var background := ColorRect.new()
	background.color = CREAM
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	toolbar.add_child(background)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 6
	row.offset_right = -6
	row.offset_top = 1
	row.offset_bottom = -1
	toolbar.add_child(row)
	var grip := _label(row, "≡")
	grip.mouse_filter = Control.MOUSE_FILTER_STOP
	grip.tooltip_text = "按住拖动农场位置"
	grip.custom_minimum_size = Vector2(20, 0)
	grip.gui_input.connect(_drag_toolbar)
	for id in ["farm", "ranch", "pond"]:
		var scene_id := str(id)
		_button(row, SCENE_NAMES[id], func(): _set_scene(scene_id))
	_button(row, "种子商店", func(): _open_panel("crops")).name = "SeedShop"
	_button(row, "动物商店", func(): _open_panel("animals")).name = "AnimalShop"
	_button(row, "经营", func(): _open_panel("hub")).name = "Management"
	coin_label = _label(row, "")
	coin_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	coin_label.clip_text = true
	coin_label.tooltip_text = "补种预算是金币保护额，持续预留；经营操作不得动用。"
	_button(row, "‹", func(): view.page_previous(); _refresh_labels())
	page_label = _label(row, "1/1")
	_button(row, "›", func(): view.page_next(); _refresh_labels())
	mode_button = _button(row, "可交互", _toggle_interaction)
	collapse_button = _button(row, "收起", _toggle_collapse)
	_button(row, "退出", _quit_game)
	toolbar.show()

func _build_status() -> void:
	var bar := ColorRect.new()
	bar.name = "StatusBackground"
	bar.color = Color("#edf0dc")
	bar.position = Vector2(0, 220)
	bar.size = Vector2(1920, 20)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)
	status_label = Label.new()
	status_label.theme = theme
	status_label.position = Vector2(10, 220)
	status_label.size = Vector2(1900, 20)
	status_label.add_theme_font_size_override("font_size", 12)
	status_label.clip_text = true
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(status_label)

func _build_popup() -> void:
	popup = Window.new()
	popup.name = "ManagementPanel"
	# Window defaults to visible. Hide before entering the tree so an empty
	# 760x500 native window cannot appear at (0,0) during normal startup.
	popup.visible = false
	popup.title = "桌面农场"
	popup.borderless = false
	popup.size = Vector2i(760, 500)
	popup.min_size = Vector2i(540, 360)
	popup.theme = theme
	popup.always_on_top = false
	popup.close_requested.connect(_close_panel)
	popup.window_input.connect(func(event: InputEvent):
		if event.is_action_pressed("ui_cancel"): _close_panel())
	add_child(popup)
	var background := ColorRect.new()
	background.color = CREAM
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	popup.add_child(background)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 16
	scroll.offset_top = 12
	scroll.offset_right = -16
	scroll.offset_bottom = -12
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	popup.add_child(scroll)
	popup_body = VBoxContainer.new()
	popup_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(popup_body)

func _sync_layout() -> void:
	if not is_instance_valid(view): return
	var scale := host.dpi_scale if is_instance_valid(host) and host.ready_for_desktop else 1.0
	var logical_width := maxi(640, int(round(get_window().size.x / scale)))
	get_window().content_scale_size = Vector2i(logical_width, 240)
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	toolbar.content_scale_size = Vector2i(logical_width, 32)
	toolbar.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	view.resize_view(Vector2(logical_width, 172))
	get_node("StatusBackground").size.x = logical_width
	status_label.size.x = logical_width - 20
	# Keep every action reachable at narrow desktop widths without forcing a
	# taller strip. The management hub also contains both shop entry points.
	for button_name in ["SeedShop", "AnimalShop"]:
		var shop_button := toolbar.find_child(button_name, true, false)
		if shop_button != null: shop_button.visible = logical_width >= 1000
	coin_label.visible = logical_width >= 850
	if is_instance_valid(catalog_grid): catalog_grid.columns = _catalog_columns()
	_refresh_labels()

func _process(delta: float) -> void:
	if model == null or startup_blocked: return
	var elapsed := float(host.consume_elapsed_msec()) / 1000.0 if is_instance_valid(host) and host.ready_for_desktop else delta
	model.tick(elapsed)
	auto_save_elapsed += elapsed
	ui_elapsed += delta
	_shop_refresh_elapsed += delta
	toast_remaining = maxf(0, toast_remaining - delta)
	if auto_save_elapsed >= 30.0:
		auto_save_elapsed = 0.0
		_save_now()
	if ui_elapsed >= 0.5:
		ui_elapsed = 0.0
		view.set_model(model.state)
		_refresh_labels()
	if _shop_refresh_elapsed >= 2.0:
		_shop_refresh_elapsed = 0.0
		_refresh_open_shop()

func _act(action: String, payload: Dictionary = {}, rebuild := true) -> bool:
	if startup_blocked:
		_open_panel("save_error")
		return false
	if save_blocked:
		_show_message("存档尚未恢复，暂停经营操作。请在设置中重试保存。")
		return false
	var before := model.snapshot()
	var result := model.command(action, payload)
	if result.ok:
		var saved := saves.save(model.snapshot())
		if not saved.ok:
			model.restore(before)
			save_blocked = true
			_show_message("操作已撤回：" + str(saved.message))
			view.set_model(model.state, true)
			_refresh_labels()
			return false
	_show_message(str(result.message))
	view.set_model(model.state, true)
	_refresh_labels()
	if result.ok and rebuild and popup.visible: _render_panel()
	return bool(result.ok)

func _save_now() -> bool:
	if startup_blocked: return false
	var result := saves.save(model.snapshot())
	save_blocked = not result.ok
	if not result.ok: _show_message("保存失败：" + str(result.message))
	return bool(result.ok)

func _show_message(message: String) -> void:
	toast = message
	toast_remaining = 10.0
	if is_instance_valid(status_label): _refresh_labels()

func _refresh_labels() -> void:
	if not is_instance_valid(coin_label): return
	coin_label.text = "金币 %d  ·  补种 %d  ·  可用 %d" % [model.balance(), model.protection(), model.investable()]
	page_label.text = "%d/%d" % [view.page + 1, view.get_page_count()]
	mode_button.text = "可交互" if model.state.settings.interactive else "观察中"
	collapse_button.text = "展开" if model.state.settings.collapsed else "收起"
	if toast_remaining > 0:
		status_label.text = toast
	else:
		var working: int = model.state.farmers.filter(func(f): return str(f.mode) == "working").size()
		var hungry: int = model.state.animals.filter(func(a): return bool(a.hungry)).size()
		status_label.text = "运行 %s  ·  农夫 %d（工作 %d）  ·  动物 %d（饥饿 %d）  ·  草仓 %d/%d  ·  食槽 %d/%d  ·  鱼 %d/12  ·  %s" % [_duration(model.state.elapsed), model.state.farmers.size(), working, model.state.animals.size(), hungry, model.state.warehouse_hay, model.storage_capacity(), model.state.trough_hay, model.storage_capacity(), model.state.fish.size(), "保存异常" if save_blocked else "每30秒自动保存"]

func _set_scene(id: String) -> void:
	current_scene = id
	view.set_scene(id)
	_refresh_labels()
	if id == "pond" and not model.state.pending_fish.is_empty(): _open_panel("caught")

func _toggle_interaction() -> void:
	if _act("settings", {"values": {"interactive": not bool(model.state.settings.interactive)}}, false): _apply_settings()

func _toggle_collapse() -> void:
	if _act("settings", {"values": {"collapsed": not bool(model.state.settings.collapsed)}}, false): _apply_settings()

func _apply_settings() -> void:
	var settings: Dictionary = model.state.settings
	settings.topmost = false
	view.set_interactive(bool(settings.interactive))
	host.set_interactive(bool(settings.interactive))
	host.set_topmost(false)
	popup.always_on_top = false
	host.set_power_saving(bool(settings.power_saving))
	host.set_collapsed(bool(settings.collapsed))
	view.set_process(host.is_desktop_visible() and not bool(settings.collapsed))
	if view.has_method("set_desktop_suspended"):
		view.call("set_desktop_suspended", not host.is_desktop_visible() or bool(settings.collapsed))
	_refresh_labels()

func _on_tray_action(action: String) -> void:
	match action:
		"toggle_visibility": host.toggle_user_hidden()
		"toggle_interactive": _toggle_interaction()
		"open_seed_shop", "open_animal_shop":
			host.set_user_hidden(false)
			_open_panel("crops" if action == "open_seed_shop" else "animals")
		"quit": _quit_game()

func _cast_net(id: String) -> void:
	if _act("cast_net", {"fish_id": id}, false) and not model.state.pending_fish.is_empty(): _open_panel("caught")

func _open_panel(name: String) -> void:
	panel_name = name
	_render_panel()
	var area := host.get_work_area() if is_instance_valid(host) and host.ready_for_desktop else Rect2i(Vector2i.ZERO, DisplayServer.screen_get_usable_rect().size)
	popup.size = Vector2i(mini(760, maxi(540, area.size.x - 40)), mini(500, maxi(360, area.size.y - 100)))
	popup.position = area.position + Vector2i((area.size.x - popup.size.x) / 2, maxi(20, area.size.y - 240 - popup.size.y - 16))
	if is_instance_valid(catalog_grid): catalog_grid.columns = _catalog_columns()
	popup.show()
	# This HWND must keep rendering when the scenery viewport is suspended.
	RenderingServer.viewport_set_parent_viewport(popup.get_viewport_rid(), RID())
	if is_instance_valid(host) and host.native != null:
		var popup_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, popup.get_window_id())
		host.native.call("make_independent_window", popup_handle)
		host.native.call("show_window", popup_handle)
	popup.grab_focus()
	host.refresh_desktop_visibility()

func _close_panel() -> void:
	popup.hide()
	panel_name = ""

func _render_panel() -> void:
	crop_list = null
	catalog_grid = null
	_catalog_count_label = null
	_budget_footer = null
	_region_status_label = null
	_crop_quote_controls.clear()
	_animal_quote_controls.clear()
	_owned_animal_controls.clear()
	_sale_controls.clear()
	for child in popup_body.get_children():
		popup_body.remove_child(child)
		child.queue_free()
	if panel_name != "save_error":
		var navigation := HFlowContainer.new()
		popup_body.add_child(navigation)
		if panel_name != "hub": _button(navigation, "‹ 经营首页", func(): _open_panel("hub"))
		_button(navigation, "关闭面板 ×", _close_panel)
	_prepare_preview()
	match panel_name:
		"hub": _panel_hub()
		"crops": _panel_crops()
		"build": _panel_build()
		"animals": _panel_animals()
		"sell_confirm": _panel_sell_confirm()
		"farmers": _panel_farmers()
		"catalog": _panel_catalog()
		"catalog_detail": _panel_catalog_detail()
		"settings": _panel_settings()
		"caught": _panel_caught()
		"save_error": _panel_save_error()
	if panel_name != "save_error":
		_budget_footer = _wrapped_label(popup_body, _budget_summary())
	_shop_revision = _shop_state_revision()

func _prepare_preview() -> void:
	if _preview_model == null: _preview_model = MODEL.new(config)
	_preview_snapshot = model.snapshot()

func _preview_command(action: String, payload: Dictionary = {}) -> Dictionary:
	if _preview_snapshot.is_empty(): _prepare_preview()
	_preview_model.restore(_preview_snapshot)
	var preview: Dictionary = _preview_model.command(action, payload)
	# The public command restores failed mutations. A second dry calculation
	# on this disposable model keeps the proposed reservation visible even
	# when it is unaffordable; no signal or disk write reaches the live model.
	if not preview.ok and action in ["set_crop", "unlock_crop"]:
		_preview_model._execute_command(action, payload)
	var result := {"ok": bool(preview.ok), "message": str(preview.message),
		"balance_before": int(_preview_snapshot.coins), "balance_after": _preview_model.balance(),
		"protection_before": model.protection(), "protection_after": _preview_model.protection(),
		"investable_before": model.investable(), "investable_after": _preview_model.investable()}
	if startup_blocked or save_blocked:
		result.ok = false
		result.message = "存档异常，请先在设置中恢复保存"
	return result

func _shop_state_revision() -> String:
	return "%d/%d/%d/%d/%d/%s" % [model.balance(), model.protection(), hash(model.state.animals), hash(model.state.catalog), hash(model.state.seeds), str(save_blocked)]

func _budget_summary() -> String:
	return "金币 %d  |  补种保护 %d  |  可投资 %d" % [model.balance(), model.protection(), model.investable()]

func _refresh_open_shop() -> void:
	if not popup.visible or _shop_state_revision() == _shop_revision: return
	if is_instance_valid(_budget_footer): _budget_footer.text = _budget_summary()
	_prepare_preview()
	if panel_name == "crops" and is_instance_valid(crop_list):
		_refresh_crop_quotes()
	elif panel_name == "animals":
		_refresh_animal_quotes()
		_refresh_owned_animal_cards()
	elif panel_name == "catalog" and hash(model.state.catalog) != _catalog_revision:
		_render_catalog_grid()
		if is_instance_valid(_catalog_count_label): _catalog_count_label.text = "已发现 %d / %d" % [model.state.catalog.size(), config.items.size()]
	elif panel_name == "sell_confirm":
		_refresh_sale_confirmation()
	elif panel_name == "catalog_detail" and hash(model.state.catalog) != _catalog_revision:
		_render_panel()
	_shop_revision = _shop_state_revision()

func _panel_hub() -> void:
	popup.title = "经营"
	_title("桌面农场 · 经营手册")
	_paragraph("安排作物、扩建牧场、招募农夫。生产在后台继续；需要专心工作时可隐藏整个农场。")
	for entry in [{"id": "crops", "text": "种子商店 / 区域作物"}, {"id": "animals", "text": "动物商店 / 购买与出售"}, {"id": "build", "text": "建设扩展"}, {"id": "farmers", "text": "农夫管理"}, {"id": "catalog", "text": "收藏图鉴"}, {"id": "settings", "text": "设置 / 帮助"}]:
		var target := str(entry.id)
		_button(popup_body, str(entry.text), func(): _open_panel(target))
	_button(popup_body, "隐藏整个农场（后台继续生产）", func(): host.set_user_hidden(true))
	_paragraph("可通过系统托盘图标或 Ctrl+Alt+F 返回农场。", MUTED)

func _panel_crops() -> void:
	popup.title = "种子商店 · 区域作物"
	_title("种子商店")
	_paragraph("选择区域与作物，农夫会先用库存，再按单价自动购种。只有实际播种才扣种子费用；解锁费只支付一次。已解锁作物全年可种。")
	var selector := OptionButton.new()
	selector.name = "RegionSelector"
	popup_body.add_child(selector)
	for region in model.state.regions:
		selector.add_item("区域 %d%s" % [int(region.index) + 1, "" if region.unlocked else "（未开）"], int(region.index))
	selector.select(region_selection)
	selector.item_selected.connect(func(index: int): region_selection = index; _render_panel())
	var selected: Dictionary = model.state.regions[region_selection]
	_region_status_label = _wrapped_label(popup_body, _region_summary())
	if not selected.unlocked:
		_paragraph("区域尚未开放，可先浏览种子；在建设扩展中解锁后才能安排种植。")
		_button(popup_body, "前往建设扩展", func(): _open_panel("build"))
	if not str(selected.pending_crop_id).is_empty():
		_button(popup_body, "取消尚未生效的切换", func(): _act("cancel_crop", {"region": region_selection}))
	var search := LineEdit.new()
	search.name = "CropSearch"
	search.placeholder_text = "搜索作物名称…"
	search.text = crop_search
	popup_body.add_child(search)
	search.text_changed.connect(func(value: String): crop_search = value; _render_crop_list())
	var filters := HFlowContainer.new()
	popup_body.add_child(filters)
	var seasons := OptionButton.new()
	filters.add_child(seasons)
	for label in ["全部季节", "春", "夏", "秋", "冬", "全年"]: seasons.add_item(label)
	seasons.select(["全部", "春", "夏", "秋", "冬", "全年"].find(crop_season))
	seasons.item_selected.connect(func(index: int): crop_season = ["全部", "春", "夏", "秋", "冬", "全年"][index]; _render_crop_list())
	var mechanisms := OptionButton.new()
	filters.add_child(mechanisms)
	for label in ["全部类型", "单次收获", "连续收获", "随机种包", "返种", "加工", "材料作物"]: mechanisms.add_item(label)
	mechanisms.select(["全部", "single", "regrow", "mixed", "return_seed", "processing", "material"].find(crop_mechanism))
	mechanisms.item_selected.connect(func(index: int): crop_mechanism = ["全部", "single", "regrow", "mixed", "return_seed", "processing", "material"][index]; _render_crop_list())
	var available := CheckBox.new()
	available.text = "只看已解锁"
	available.button_pressed = crop_unlocked_only
	filters.add_child(available)
	available.toggled.connect(func(value: bool): crop_unlocked_only = value; _render_crop_list())
	crop_list = VBoxContainer.new()
	crop_list.name = "CropList"
	popup_body.add_child(crop_list)
	_render_crop_list()

func _filtered_crops() -> Array:
	var result := []
	for crop in config.crops:
		if not crop_search.strip_edges().is_empty() and not str(crop.name).contains(crop_search.strip_edges()): continue
		if crop_season != "全部" and not str(crop.season).contains(crop_season): continue
		if crop_mechanism != "全部" and str(crop.mechanism) != crop_mechanism: continue
		if crop_unlocked_only and not model.state.unlocked_crops.has(str(crop.id)): continue
		result.append(crop)
	return result

func _render_crop_list() -> void:
	if not is_instance_valid(crop_list): return
	_clear_children(crop_list)
	_crop_quote_controls.clear()
	_prepare_preview()
	var filtered := _filtered_crops()
	_label(crop_list, "显示 %d / %d 种作物" % [filtered.size(), config.crops.size()])
	if filtered.is_empty(): _wrapped_label(crop_list, "没有符合条件的作物，可修改搜索或筛选。")
	for crop in filtered:
		var crop_id := str(crop.id)
		var unlocked: bool = model.state.unlocked_crops.has(crop_id)
		var card := _card(crop_list, "crop", crop_id)
		var heading := _wrapped_label(card, "%s · %s · %s" % [crop.name, crop.season, "已解锁" if unlocked else "未解锁"])
		heading.add_theme_font_size_override("font_size", 16)
		var detail_label := _wrapped_label(card, _crop_description(crop))
		var action := "set_crop" if unlocked else "unlock_crop"
		var payload := {"region": region_selection, "crop_id": crop_id} if unlocked else {"crop_id": crop_id}
		var quote := _wrapped_label(card, "")
		if unlocked:
			_wrapped_label(card, "完成本轮后逐格切换；现在仅预留预算，不扣种价。", MUTED)
		var text := "选用 / 自动购种" if unlocked else "解锁 %d" % int(crop.unlock_price)
		var button := _button(card, text, func(): _act(action, payload))
		button.name = "CropAction_" + crop_id
		var reason_label := _wrapped_label(card, "", ALERT)
		_crop_quote_controls[crop_id] = {"crop": crop, "button": button, "quote": quote, "reason": reason_label, "detail": detail_label}
	_refresh_crop_quotes()

func _crop_description(crop: Dictionary) -> String:
	var detail := "种价 %d / 份 · 库存 %d · 首轮 %s" % [int(crop.seed_price), int(model.state.seeds.get(str(crop.id), 0)), _duration(crop.first_seconds)]
	if bool(crop.regrow): detail += "  ·  再熟 %s" % _duration(crop.repeat_seconds)
	if str(crop.mechanism) == "mixed": detail += "  ·  随机产物，按实售出"
	elif str(crop.mechanism) == "processing": detail += "  ·  加工后售 %d" % int(crop.sell_price)
	else: detail += "  ·  售 %d" % int(crop.sell_price)
	return detail

func _region_summary() -> String:
	var selected: Dictionary = model.state.regions[region_selection]
	return "区域 %d · %s%s" % [region_selection + 1, str(model.crops[str(selected.current_crop_id)].name), "  →  " + str(model.crops[str(selected.pending_crop_id)].name) if not str(selected.pending_crop_id).is_empty() else ""]

func _refresh_crop_quotes() -> void:
	if is_instance_valid(_region_status_label): _region_status_label.text = _region_summary()
	for crop_id in _crop_quote_controls:
		var controls: Dictionary = _crop_quote_controls[crop_id]
		var crop: Dictionary = controls.crop
		controls.detail.text = _crop_description(crop)
		var unlocked: bool = model.state.unlocked_crops.has(crop_id)
		var preview := _preview_command("set_crop" if unlocked else "unlock_crop", {"region": region_selection, "crop_id": crop_id} if unlocked else {"crop_id": crop_id})
		var reason := ""
		var selected: Dictionary = model.state.regions[region_selection]
		if unlocked and str(selected.current_crop_id) == str(crop_id) and str(selected.pending_crop_id).is_empty():
			preview.ok = false
			reason = "本区正在种植此作物"
		elif not preview.ok: reason = str(preview.message)
		controls.quote.text = "换种预览：补种保护 %d → %d · 可投资 %d → %d" % [preview.protection_before, preview.protection_after, preview.investable_before, preview.investable_after] if unlocked else "一次解锁 %d · 解锁后可投资 %d" % [int(crop.unlock_price), preview.investable_after]
		controls.button.disabled = not bool(preview.ok)
		controls.button.tooltip_text = reason
		controls.reason.text = reason
		controls.reason.visible = not reason.is_empty()
		controls.reason.add_theme_color_override("font_color", MUTED if reason == "本区正在种植此作物" else ALERT)

func _panel_build() -> void:
	popup.title = "建设扩展"
	_paragraph("所有费用按数值表执行。扩建后的空地也会计入补种预算，余额不足时操作会完整撤回。")
	_title("耕地与区域")
	for region in model.state.regions:
		var ri := int(region.index)
		var row := _row()
		var count := model.get_plots(ri).filter(func(p): return bool(p.open)).size()
		_expand_label(row, "区域 %d  ·  已开 %d/16" % [ri + 1, count])
		if not region.unlocked:
			_button(row, "解锁 %d" % int(config.upgrades.region_costs[ri]), func(): _act("unlock_region", {"region": ri}))
		elif count < 16:
			_button(row, "加1格 %d" % int(config.upgrades.plot_costs[count]), func(): _act("expand_plot", {"region": ri}))
		else: _label(row, "已满")
	_title("牧草与储粮")
	var grass_count: int = model.state.grass.filter(func(g): return bool(g.open)).size()
	var row := _row()
	_expand_label(row, "草地 %d/96  ·  草种库存 %d" % [grass_count, int(model.state.grass_seeds)])
	if grass_count < 96:
		_button(row, "加1格 %d" % int(config.upgrades.grass_plot_costs[grass_count]), func(): _act("expand_grass"))
	_button(row, "草种 100", func(): _act("buy_grass_seed"))
	row = _row()
	_expand_label(row, "草仓与食槽容量各 %d" % model.storage_capacity())
	var next := int(model.state.storage_level) + 1
	if next < config.upgrades.hay_storage.size():
		_button(row, "升级 %d" % int(config.upgrades.hay_storage[next].cost), func(): _act("upgrade_storage"))
	_title("棚舍")
	for shelter in config.shelters:
		var sid := str(shelter.id)
		var level := int(model.state.shelters[sid])
		row = _row()
		_expand_label(row, "%s  ·  %d级  ·  容量 %d" % [shelter.name, level, model.shelter_capacity(sid)])
		if level < 3:
			_button(row, "%s %d" % ["建造" if level == 0 else "升级", int(shelter.costs[level])], func(): _act("upgrade_shelter", {"shelter_id": sid}))

func _panel_animals() -> void:
	popup.title = "动物商店"
	_title("动物商店")
	_paragraph("动物自动吃草或干草，饥饿时暂停成长和生产。先建好对应棚舍，再购买动物；特殊动物共用普通棚位。")
	var tabs := HFlowContainer.new()
	popup_body.add_child(tabs)
	var buy_tab := _button(tabs, "购买动物", func(): animal_shop_mode = "buy"; _render_panel())
	buy_tab.disabled = animal_shop_mode == "buy"
	var owned_tab := _button(tabs, "我的动物 · %d" % model.state.animals.size(), func(): animal_shop_mode = "owned"; _render_panel())
	owned_tab.disabled = animal_shop_mode == "owned"
	var shelter_filter := OptionButton.new()
	shelter_filter.add_item("全部棚舍")
	var shelter_ids := ["全部"]
	for shelter in config.shelters:
		shelter_filter.add_item(str(shelter.name))
		shelter_ids.append(str(shelter.id))
	shelter_filter.select(shelter_ids.find(animal_shelter_filter))
	popup_body.add_child(shelter_filter)
	shelter_filter.item_selected.connect(func(index: int): animal_shelter_filter = str(shelter_ids[index]); _render_panel())
	if animal_shop_mode == "owned":
		_panel_owned_animals()
		return
	for shelter in config.shelters:
		var sid := str(shelter.id)
		if animal_shelter_filter != "全部" and animal_shelter_filter != sid: continue
		var count := 0
		for animal in model.state.animals:
			if str(model.animal_types[str(animal.type_id)].shelter_id) == sid: count += 1
		_title("%s · %d级 · 棚位 %d / %d" % [shelter.name, int(model.state.shelters[sid]), count, model.shelter_capacity(sid)])
		for kind in config.animals:
			if str(kind.shelter_id) != sid: continue
			var id := str(kind.id)
			var card := _card(popup_body, "animal", id)
			var product: Dictionary = config.products.get(str(kind.product_id), {})
			_wrapped_label(card, "%s · %s ≥%d级" % [kind.name, shelter.name, int(kind.min_level)])
			_wrapped_label(card, "长大 %s · 每 %s 产出 %s · 售价 %d" % [_duration(kind.adult_seconds), _duration(kind.produce_seconds), product.get("name", "产物"), int(kind.sell_price)], MUTED)
			var button := _button(card, "购买 %d 金币" % int(kind.price), func(): _act("buy_animal", {"animal_id": id}))
			button.name = "AnimalAction_" + id
			_animal_quote_controls[id] = {"kind": kind, "button": button, "reason": _wrapped_label(card, "", ALERT)}
			if count >= model.shelter_capacity(sid) and count > 0:
				_button(card, "查看本棚动物 / 腾出棚位", func(): animal_shop_mode = "owned"; animal_shelter_filter = sid; _render_panel())
	_refresh_animal_quotes()

func _refresh_animal_quotes() -> void:
	for id in _animal_quote_controls:
		var controls: Dictionary = _animal_quote_controls[id]
		var kind: Dictionary = controls.kind
		var sid := str(kind.shelter_id)
		var preview := _preview_command("buy_animal", {"animal_id": id})
		var reason := ""
		if not preview.ok:
			reason = str(preview.message)
			if reason.begins_with("金币不足"):
				reason = "可投资 %d，购买需 %d，还差 %d 金币；补种预算受保护。" % [model.investable(), int(kind.price), maxi(0, int(kind.price) - model.investable())]
			elif reason == "棚舍等级不足": reason = "%s需要%d级，当前%d级；请先在建设扩展中建造或升级。" % [model.shelter_types[sid].name, int(kind.min_level), int(model.state.shelters[sid])]
			elif reason.begins_with("棚位已满"):
				var count := 0
				for animal in model.state.animals:
					if str(model.animal_types[str(animal.type_id)].shelter_id) == sid: count += 1
				reason = "棚位 %d/%d 已满；升级棚舍或出售旧动物可腾位。" % [count, model.shelter_capacity(sid)]
		controls.button.disabled = not bool(preview.ok)
		controls.button.tooltip_text = reason
		controls.reason.text = reason
		controls.reason.visible = not reason.is_empty()

func _panel_owned_animals() -> void:
	_title("我的动物 · %d 只" % model.state.animals.size())
	_paragraph("出售退还标准购入价的50%，赠送动物也退款。若有成熟产物，会先登记图鉴并自动出售。")
	var shown := 0
	for animal in model.state.animals:
		var instance := str(animal.id)
		var kind: Dictionary = model.animal_types[str(animal.type_id)]
		if animal_shelter_filter != "全部" and str(kind.shelter_id) != animal_shelter_filter: continue
		shown += 1
		var card := _card(popup_body, "animal", str(kind.id))
		var status := _wrapped_label(card, "")
		var details := _animal_sale_details(instance)
		var button := _button(card, "出售… 退款 %d" % int(details.refund), func(): _begin_animal_sale(instance))
		button.name = "SellAnimal_" + instance
		button.disabled = save_blocked or startup_blocked
		_owned_animal_controls[instance] = {"status": status, "product": _wrapped_label(card, "", MUTED), "button": button}
	if shown == 0: _paragraph("这个棚舍暂时没有动物，可在购买页选择合适的品种。", MUTED)
	_refresh_owned_animal_cards()

func _refresh_owned_animal_cards() -> void:
	for animal in model.state.animals:
		var instance := str(animal.id)
		if not _owned_animal_controls.has(instance): continue
		var controls: Dictionary = _owned_animal_controls[instance]
		var kind: Dictionary = model.animal_types[str(animal.type_id)]
		controls.status.text = "%s · 编号%s · %s%s" % [kind.name, instance.trim_prefix("animal_"), "成年" if animal.adult else "幼崽", " · 饥饿" if animal.hungry else ""]
		var details := _animal_sale_details(instance)
		controls.product.text = "另有成熟产物待结算：%s +%d" % [details.product_name, details.product_value]
		controls.product.visible = int(details.product_value) > 0
		controls.button.disabled = save_blocked or startup_blocked

func _animal_sale_details(instance: String) -> Dictionary:
	for animal in model.state.animals:
		if str(animal.id) != instance: continue
		var kind: Dictionary = model.animal_types[str(animal.type_id)]
		var product: Dictionary = config.products.get(str(kind.product_id), {})
		var refund := floori(float(kind.price) * 0.5)
		var product_value := int(kind.sell_price) if int(animal.ready) > 0 else 0
		return {"exists": true, "name": str(kind.name), "kind": str(kind.id), "refund": refund,
			"product_name": str(product.get("name", "产物")), "product_value": product_value, "total": refund + product_value}
	return {"exists": false}

func _begin_animal_sale(instance: String) -> void:
	sell_selection = instance
	animal_shop_mode = "owned"
	_open_panel("sell_confirm")

func _panel_sell_confirm() -> void:
	popup.title = "确认出售动物"
	var details := _animal_sale_details(sell_selection)
	if not details.exists:
		_paragraph("这只动物已不存在，请返回商店。")
		_button(popup_body, "返回动物商店", func(): _open_panel("animals"))
		return
	_title("确认出售 %s？" % details.name)
	var card := _card(popup_body, "animal", str(details.kind))
	_wrapped_label(card, "动物编号：" + sell_selection.trim_prefix("animal_"))
	_wrapped_label(card, "退款：%d 金币（标准购入价的50%%）" % int(details.refund))
	var product_label := _wrapped_label(card, "")
	var total_label := _wrapped_label(card, "")
	_wrapped_label(card, "出售后这只动物会离开牧场，可在商店重新购买。成熟产物如已被农夫收取，不会重复结算。", MUTED)
	var controls := HFlowContainer.new()
	popup_body.add_child(controls)
	_button(controls, "取消，保留动物", func(): _open_panel("animals"))
	var confirm := _button(controls, "确认出售", _confirm_animal_sale)
	confirm.name = "ConfirmAnimalSale"
	_sale_controls = {"product": product_label, "total": total_label, "button": confirm}
	_refresh_sale_confirmation()

func _refresh_sale_confirmation() -> void:
	if _sale_controls.is_empty(): return
	var details := _animal_sale_details(sell_selection)
	if not details.exists:
		_sale_controls.button.disabled = true
		_sale_controls.product.text = "这只动物已经不在牧场，请返回商店。"
		return
	_sale_controls.product.text = "待结算产物：%s · +%d 金币，并登记图鉴" % [details.product_name, details.product_value] if int(details.product_value) > 0 else "待结算产物：无"
	_sale_controls.total.text = "本次合计 +%d 金币 · 释放1个棚位" % int(details.total)
	_sale_controls.button.disabled = not bool(_preview_command("sell_animal", {"instance_id": sell_selection}).ok)

func _confirm_animal_sale() -> void:
	if _act("sell_animal", {"instance_id": sell_selection}, false):
		sell_selection = ""
		_open_panel("animals")

func _panel_farmers() -> void:
	popup.title = "农夫管理"
	_paragraph("每个场景最多3人（含支援）；精力满且本岗无事时自动支援，出发消耗20精力，步行5秒。完成工作回到本岗后可免费转岗。")
	var index := int(model.state.paid_hires)
	var price := int(config.upgrades.farmer_costs[index]) if index < config.upgrades.farmer_costs.size() else 0
	for id in SCENE_NAMES:
		var scene_id := str(id)
		var count: int = model.state.farmers.filter(func(f): return str(f.home) == scene_id).size()
		var row := _row()
		_expand_label(row, "%s本岗 %d/3" % [SCENE_NAMES[id], count])
		if price > 0: _button(row, "招聘 %d" % price, func(): _act("hire_farmer", {"scene": scene_id}))
	_title("人员与转岗")
	for farmer in model.state.farmers:
		var farmer_id := str(farmer.id)
		var row := _row()
		_expand_label(row, "%s · 本岗%s · 在%s · 精力%d · %s" % [farmer.id, SCENE_NAMES[str(farmer.home)], SCENE_NAMES.get(str(farmer.scene), "途中"), int(farmer.energy), _farmer_mode(str(farmer.mode))])
		var choice := OptionButton.new()
		row.add_child(choice)
		for id in ["farm", "ranch", "pond"]: choice.add_item(SCENE_NAMES[id])
		choice.select(["farm", "ranch", "pond"].find(str(farmer.home)))
		choice.item_selected.connect(func(i: int): _act("transfer_farmer", {"farmer_id": farmer_id, "scene": ["farm", "ranch", "pond"][i]}))

func _panel_catalog() -> void:
	popup.title = "收藏图鉴"
	_title("收藏图鉴")
	_paragraph("作物与动物产物收获后自动登记并出售。鱼需捕获后选择登记，登记会消耗这条鱼。点击图标查看详情与获取来源。")
	_catalog_count_label = _wrapped_label(popup_body, "已发现 %d / %d" % [model.state.catalog.size(), config.items.size()])
	_catalog_count_label.add_theme_font_size_override("font_size", 16)
	var search := LineEdit.new()
	search.placeholder_text = "搜索图鉴名称…"
	search.text = catalog_search
	popup_body.add_child(search)
	search.text_changed.connect(func(value: String): catalog_search = value; _render_catalog_grid())
	var filters := HFlowContainer.new()
	popup_body.add_child(filters)
	var category := OptionButton.new()
	filters.add_child(category)
	for label in ["全部分类", "作物", "动物产物", "鱼"]: category.add_item(label)
	category.select(["全部", "crop", "animal", "fish"].find(catalog_category))
	category.item_selected.connect(func(index: int): catalog_category = ["全部", "crop", "animal", "fish"][index]; _render_catalog_grid())
	var discovered := CheckBox.new()
	discovered.text = "只看已发现"
	discovered.button_pressed = catalog_discovered_only
	filters.add_child(discovered)
	discovered.toggled.connect(func(value: bool): catalog_discovered_only = value; _render_catalog_grid())
	catalog_grid = GridContainer.new()
	catalog_grid.name = "CatalogGrid"
	catalog_grid.columns = _catalog_columns()
	catalog_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	popup_body.add_child(catalog_grid)
	_render_catalog_grid()

func _catalog_columns() -> int:
	return clampi(int((popup.size.x - 60) / 152), 2, 4)

func _filtered_catalog_items() -> Array:
	var result := []
	for item in config.items:
		if catalog_category != "全部" and str(item.category) != catalog_category: continue
		if catalog_discovered_only and not model.state.catalog.has(str(item.id)): continue
		if not catalog_search.strip_edges().is_empty() and not str(item.name).contains(catalog_search.strip_edges()): continue
		result.append(item)
	return result

func _render_catalog_grid() -> void:
	if not is_instance_valid(catalog_grid): return
	_catalog_revision = hash(model.state.catalog)
	_clear_children(catalog_grid)
	for item in _filtered_catalog_items():
		var id := str(item.id)
		var entry: Dictionary = model.state.catalog.get(id, {})
		var button := _button(catalog_grid, "", func(): catalog_selection = id; _open_panel("catalog_detail"))
		button.name = "CatalogItem_" + id
		button.custom_minimum_size = Vector2(144, 112)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.tooltip_text = "%s · %s · 点击查看获取来源" % [item.name, "已发现" if not entry.is_empty() else "等待发现"]
		var contents := VBoxContainer.new()
		contents.mouse_filter = Control.MOUSE_FILTER_IGNORE
		contents.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		contents.offset_left = 6
		contents.offset_right = -6
		contents.offset_top = 6
		contents.offset_bottom = -6
		button.add_child(contents)
		var picture := _icon(contents, "item", id)
		picture.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		picture.modulate = Color.WHITE if not entry.is_empty() else Color(0.55, 0.51, 0.44, 0.7)
		var name_label := _wrapped_label(contents, str(item.name))
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var state_label := _label(contents, "已登记 %d" % int(entry.count) if not entry.is_empty() else "未发现")
		state_label.add_theme_font_size_override("font_size", 12)
		state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		state_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		state_label.add_theme_color_override("font_color", MUTED)
	if catalog_grid.get_child_count() == 0: _wrapped_label(catalog_grid, "没有符合条件的图鉴。")

func _catalog_sources(item_id: String) -> Array[String]:
	var sources: Array[String] = []
	for crop in config.crops:
		var matches := str(crop.product_id) == item_id or str(crop.get("raw_product_id", "")) == item_id
		for product in crop.pool:
			if str(product.get("product_id", "")) == item_id: matches = true
		if matches: sources.append("种植 " + str(crop.name))
	for animal in config.animals:
		if str(animal.product_id) == item_id: sources.append("饲养 " + str(animal.name))
	for fish in config.fish:
		if str(fish.get("product_id", fish.id)) == item_id: sources.append("鱼塘捕获 " + str(fish.name))
	return sources

func _panel_catalog_detail() -> void:
	popup.title = "图鉴详情"
	_catalog_revision = hash(model.state.catalog)
	var item: Dictionary = {}
	for candidate in config.items:
		if str(candidate.id) == catalog_selection: item = candidate; break
	if item.is_empty():
		_paragraph("请选择一项图鉴。")
		_button(popup_body, "返回图鉴", func(): _open_panel("catalog"))
		return
	var entry: Dictionary = model.state.catalog.get(catalog_selection, {})
	_title(str(item.name))
	var card := _card(popup_body, "item", catalog_selection)
	_wrapped_label(card, "%s · %s" % [CATEGORY_NAMES.get(str(item.category), "产物"), "已发现" if not entry.is_empty() else "未发现"])
	_wrapped_label(card, "参考售价 %d 金币 · 累计登记 %d 次" % [int(item.sell_price), int(entry.get("count", 0))])
	var sources := _catalog_sources(catalog_selection)
	_wrapped_label(card, "获取来源：" + "、".join(sources))
	var raw_crop: Dictionary = {}
	for crop in config.crops:
		if str(crop.get("raw_product_id", "")) == catalog_selection: raw_crop = crop; break
	if str(item.category) == "fish":
		_wrapped_label(card, "登记方法：在鱼塘手动捕获后选择「登记图鉴」。选择出售只获得金币。", MUTED)
	elif not raw_crop.is_empty():
		_wrapped_label(card, "登记方法：收获时登记这份原料，不单独出售。自动加工 %s 后登记成品，并按 %d 金币出售一次。" % [_duration(raw_crop.processing_seconds), int(raw_crop.sell_price)], MUTED)
	else:
		_wrapped_label(card, "登记方法：农夫收取成熟产物时自动登记并出售，无需保留库存。随机种包只登记实际抽中的产物。", MUTED)
	if not entry.is_empty():
		_wrapped_label(card, "首次发现：开局后 " + _duration(float(entry.get("first_obtained", 0))))
	_button(popup_body, "‹ 返回图鉴", func(): _open_panel("catalog"))

func _panel_settings() -> void:
	popup.title = "设置 / 试玩说明"
	_paragraph("窗口遵循普通应用的前后顺序。点击其他应用时，其他应用显示在农场和经营窗口前方；农场仍继续生产。")
	_paragraph("检测到前台全屏应用时自动让出显示，回到普通桌面后恢复。Ctrl+Alt+F 或托盘菜单可隐藏 / 返回整个农场。")
	_button(popup_body, "隐藏整个农场", func(): host.set_user_hidden(true))
	for entry in [{"key": "power_saving", "name": "省电模式（15 FPS）"}, {"key": "interactive", "name": "场景可交互（关闭后鼠标穿透到桌面）"}]:
		var key := str(entry.key)
		var check := CheckBox.new()
		check.text = entry.name
		check.button_pressed = bool(model.state.settings[key])
		popup_body.add_child(check)
		check.toggled.connect(func(enabled: bool):
			if _act("settings", {"values": {key: enabled}}, false): _apply_settings())
	var row := _row()
	_button(row, "重试保存" if save_blocked else "立即保存", func():
		if _save_now(): _show_message("存档已保存，经营操作已恢复。")
		_render_panel())
	_button(row, "恢复屏幕底部位置", func():
		var area := host.get_work_area()
		if area.size.x > 0:
			host.set_position_clamped(Vector2i(area.position.x, area.end.y - get_window().size.y))
			_act("settings", {"values": {"window_position": host.export_settings().window_position}}, false))
	_button(row, "打开存档目录", func(): OS.shell_open(saves.path.get_base_dir()))
	_paragraph("入门：工具栏的种子商店、动物商店可直接购买/安排生产；经营可扩建、管理农夫和查看图鉴。农夫自动播种、浇水和收获，鱼塘需手动捕鱼。窄屏可用 ‹ › 切换页面。")
	_paragraph("时间：关机、退出和休眠均暂停，不计算离线收益；收起、切场景和锁屏仍继续生产。已捕到但未处理的鱼会保留到下次启动。")
	_paragraph("经济：补种预算持续预留，菜单显示可投资金币；购买不足时不会扣款。成熟作物和动物产物最多等待1份，不会腐烂。")
	_paragraph("存档路径：" + saves.path)
	_paragraph("版本 %s · Windows 11 本地试玩 · 原创占位像素素材。正式美术、发布签名和长期性能测试另行安排。" % ProjectSettings.get_setting("application/config/version"))

func _panel_caught() -> void:
	popup.title = "捕获结果"
	if model.state.pending_fish.is_empty():
		_paragraph("当前没有待处理的鱼。")
		return
	var kind: Dictionary = model.fish_types[str(model.state.pending_fish.type_id)]
	_title("捕获：%s" % kind.name)
	_paragraph("选择出售获得 %d 金币，或消耗这条鱼登记图鉴。关闭面板可以稍后处理；再次捕鱼前需完成选择。" % int(kind.sell_price))
	var row := _row()
	_button(row, "出售 +%d" % int(kind.sell_price), func():
		if _act("resolve_fish", {"choice": "sell"}, false): popup.hide(); panel_name = "")
	_button(row, "登记图鉴", func():
		if _act("resolve_fish", {"choice": "catalog"}, false): popup.hide(); panel_name = "")

func _panel_save_error() -> void:
	popup.title = "存档读取失败 · 游戏暂停"
	_title("没有覆盖原存档")
	_paragraph(toast)
	_paragraph("请保留主存档及 .bak 备份。可以检查目录权限、恢复有效备份后重新启动。当前不会自动新开游戏，也不会推进生产。")
	_button(popup_body, "打开存档目录", func(): OS.shell_open(saves.path.get_base_dir()))
	_button(popup_body, "安全退出", func(): get_tree().quit(3))

func _row() -> HBoxContainer:
	var row := HBoxContainer.new()
	popup_body.add_child(row)
	return row

func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()

func _icon(parent: Node, kind: String, id: String) -> TextureRect:
	var picture := TextureRect.new()
	picture.texture = ASSETS.icon(kind, id)
	picture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	picture.custom_minimum_size = Vector2(40, 40)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(picture)
	return picture

func _card(parent: Node, kind: String, id: String) -> VBoxContainer:
	var frame := PanelContainer.new()
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(frame)
	var row := HBoxContainer.new()
	frame.add_child(row)
	var picture := _icon(row, kind, id)
	picture.custom_minimum_size = Vector2(48, 48)
	picture.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var contents := VBoxContainer.new()
	contents.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(contents)
	return contents

func _wrapped_label(parent: Node, content: String, color := INK) -> Label:
	var label := _label(parent, content)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", color)
	return label

func _label(parent: Node, content: String) -> Label:
	var label := Label.new()
	label.text = content
	parent.add_child(label)
	return label

func _expand_label(parent: Node, content: String) -> Label:
	var label := _label(parent, content)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func _paragraph(content: String, color := INK) -> void:
	_wrapped_label(popup_body, content, color)

func _title(content: String) -> void:
	var label := _label(popup_body, content)
	label.add_theme_font_size_override("font_size", 16)

func _button(parent: Node, content: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = content
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _duration(seconds: float) -> String:
	var whole := maxi(0, ceili(seconds))
	if whole >= 3600: return "%d时%02d分" % [whole / 3600, (whole % 3600) / 60]
	if whole >= 60: return "%d分%02d秒" % [whole / 60, whole % 60]
	return "%d秒" % whole

func _farmer_mode(mode: String) -> String:
	return {"idle": "待命", "resting": "休息", "working": "工作", "outbound": "支援途中", "returning": "返岗途中"}.get(mode, mode)

func _drag_toolbar(event: InputEvent) -> void:
	if not is_instance_valid(host) or not host.ready_for_desktop: return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if event.pressed:
			_drag_mouse = DisplayServer.mouse_get_position()
			_drag_origin = get_window().position
		else:
			_act("settings", {"values": {"window_position": host.export_settings().window_position}}, false)
	elif event is InputEventMouseMotion and _dragging:
		host.set_position_clamped(_drag_origin + DisplayServer.mouse_get_position() - _drag_mouse)

func _parse_benchmark_options() -> bool:
	# Duration activates this normal-entry test runner. Fixture-only controller
	# tests and the source SceneTree helper keep their own lifetime unchanged.
	var arguments := OS.get_cmdline_user_args()
	if not benchmark_fixture: return true
	var duration_text := ""
	var options := {"scene": "farm", "power": false, "collapsed": false, "output": ""}
	for argument in arguments:
		if argument.begins_with("--benchmark-scene="): options.scene = argument.trim_prefix("--benchmark-scene=")
		elif argument == "--benchmark-power": options.power = true
		elif argument == "--benchmark-collapsed": options.collapsed = true
		elif argument.begins_with("--benchmark-seconds="): duration_text = argument.trim_prefix("--benchmark-seconds=")
		elif argument.begins_with("--benchmark-output="): options.output = argument.trim_prefix("--benchmark-output=")
	if duration_text.is_empty(): return true
	if not SCENE_NAMES.has(str(options.scene)) or not duration_text.is_valid_float() or not str(options.output).is_absolute_path():
		printerr("Benchmark needs a valid scene, duration, and absolute output directory.")
		return false
	options.seconds = float(duration_text)
	if not is_finite(options.seconds) or options.seconds < 1.0 or options.seconds > 3600.0:
		printerr("Benchmark duration must be between 1 and 3600 seconds.")
		return false
	options.phase = "collapsed_30" if options.collapsed else str(options.scene) + ("_15" if options.power else "_30")
	benchmark_options = options
	return true

func _benchmark_write(name: String, content: Dictionary) -> bool:
	var file := FileAccess.open(str(benchmark_options.output).path_join(name), FileAccess.WRITE)
	if file == null:
		printerr("Benchmark evidence write failed: ", FileAccess.get_open_error())
		return false
	file.store_string(JSON.stringify(content))
	file.flush()
	file.close()
	return true

func _benchmark_stage(measuring: bool) -> bool:
	return _benchmark_write("benchmark-stage.json", {"phase": benchmark_options.phase,
		"measuring": measuring, "process_id": OS.get_process_id(), "tick_msec": Time.get_ticks_msec()})

func _benchmark_visibility() -> Dictionary:
	var toolbar_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, toolbar.get_window_id())
	return {"scene_hwnd_visible": bool(host.native.call("is_visible")),
		"toolbar_hwnd_visible": bool(host.native.call("window_is_visible", toolbar_handle)),
		"scene_animation_processing": view.is_processing()}

func _run_benchmark() -> void:
	if DisplayServer.get_name() == "headless" or not host.ready_for_desktop or host.native == null:
		printerr("Graphical benchmark requires the desktop native host.")
		host.shutdown()
		get_tree().quit(2)
		return
	if DirAccess.make_dir_recursive_absolute(str(benchmark_options.output)) != OK or not _benchmark_stage(false):
		host.shutdown()
		get_tree().quit(4)
		return
	_set_scene(str(benchmark_options.scene))
	model.command("settings", {"values": {"interactive": false, "power_saving": benchmark_options.power, "collapsed": benchmark_options.collapsed}})
	_apply_settings()
	await get_tree().create_timer(2.0).timeout
	var visibility_start := _benchmark_visibility()
	if visibility_start.scene_hwnd_visible == bool(benchmark_options.collapsed) or not visibility_start.toolbar_hwnd_visible:
		printerr("Benchmark HWND visibility precondition failed.")
		host.shutdown()
		get_tree().quit(3)
		return
	if not _benchmark_stage(true):
		host.shutdown()
		get_tree().quit(4)
		return
	var started := Time.get_ticks_usec()
	var logic_started := float(model.state.elapsed)
	var frame_count := 0
	var draw_sums := [0.0, 0.0, 0.0, 0.0]
	var process_peak := 0.0
	var static_memory_peak := 0.0
	while float(Time.get_ticks_usec() - started) / 1000000.0 < float(benchmark_options.seconds):
		await get_tree().process_frame
		frame_count += 1
		process_peak = maxf(process_peak, Performance.get_monitor(Performance.TIME_PROCESS))
		static_memory_peak = maxf(static_memory_peak, Performance.get_monitor(Performance.MEMORY_STATIC))
		draw_sums[0] += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		# Actual API order: RenderInfoType, RenderInfo. Child viewports render
		# independently while the collapsed scenery viewport is suspended.
		draw_sums[1] += get_window().get_render_info(Viewport.RENDER_INFO_TYPE_CANVAS, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
		draw_sums[2] += toolbar.get_render_info(Viewport.RENDER_INFO_TYPE_CANVAS, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
		draw_sums[3] += popup.get_render_info(Viewport.RENDER_INFO_TYPE_CANVAS, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var wall := float(Time.get_ticks_usec() - started) / 1000000.0
	var logic_delta := float(model.state.elapsed) - logic_started
	var saved := _save_now()
	var result := {"engine": Engine.get_version_info(), "process_id": OS.get_process_id(),
		"app_version": str(ProjectSettings.get_setting("application/config/version")),
		"benchmark_fixture": benchmark_fixture, "test_instance_namespace": "Local\\DesktopFarm.v07.test.%d" % OS.get_process_id() if host.test_instance else "",
		"native_diagnostics": host.diagnostics(),
		"phase": benchmark_options.phase, "scene": current_scene, "collapsed": benchmark_options.collapsed,
		"power_saving": benchmark_options.power, "fps_cap": Engine.max_fps, "wall_seconds": wall,
		"logic_seconds": logic_delta, "logic_drift_seconds": logic_delta - wall,
		"process_frames": frame_count, "process_fps": float(frame_count) / wall,
		"max_process_frame_seconds": process_peak, "static_memory_peak_bytes": static_memory_peak,
		"average_total_draw_calls": draw_sums[0] / frame_count,
		"average_scene_canvas_draw_calls": draw_sums[1] / frame_count,
		"average_toolbar_canvas_draw_calls": draw_sums[2] / frame_count,
		"average_popup_canvas_draw_calls": draw_sums[3] / frame_count,
		"visibility_start": visibility_start, "visibility_end": _benchmark_visibility(),
		"population": {"plots": model.state.plots.filter(func(p): return p.open).size(),
			"grass": model.state.grass.filter(func(g): return g.open).size(), "animals": model.state.animals.size(),
			"farmers": model.state.farmers.size(), "fish": model.state.fish.size()},
		"save_path": "user://test-data/benchmark-save.json", "save_absolute_path": saves.path, "save_ok": saved, "native_ready": host.ready_for_desktop,
		"executable_path": OS.get_executable_path(), "resource_root": ProjectSettings.globalize_path("res://"),
		"main_scene_resource": scene_file_path,
		"main_scene_physical_file_exists": FileAccess.file_exists(ProjectSettings.globalize_path("res://scenes/main.tscn")),
		"editor_feature": OS.has_feature("editor"), "debug_feature": OS.has_feature("debug"),
		"video_adapter": RenderingServer.get_video_adapter_name(), "api_version": RenderingServer.get_video_adapter_api_version(),
		"dpi_scale": host.dpi_scale, "window_pixels": [get_window().size.x, get_window().size.y],
		"screen_pixels": [DisplayServer.screen_get_size().x, DisplayServer.screen_get_size().y]}
	var written := _benchmark_write("benchmark-runtime.json", result)
	_benchmark_stage(false)
	print("RELEASE_BENCHMARK_COMPLETE ", JSON.stringify(result))
	host.shutdown()
	get_tree().quit(0 if saved and written else 4)

func _make_benchmark_fixture() -> void:
	model.state.coins = 1000000
	model.state.storage_level = 3
	model.state.warehouse_hay = 192
	model.state.trough_hay = 160
	for region in model.state.regions: region.unlocked = true
	for plot in model.state.plots:
		plot.open = true
		plot.status = "growing"
		plot.remaining = 1.0 + int(plot.index) * 40
	for grass in model.state.grass:
		grass.open = true
		grass.clumps = 4
	for id in model.shelter_types: model.state.shelters[id] = 3
	model.state.animals = []
	for kind in config.animals:
		if int(kind.min_level) != 1: continue
		for unused in range(12):
			model._add_animal(str(kind.id))
			var animal: Dictionary = model.state.animals[-1]
			animal.adult = true
			animal.adult_remaining = 0.0
			animal.hungry = false
			animal.food_remaining = 300.0
	model.state.farmers = []
	model.state.paid_hires = 6
	for id in SCENE_NAMES:
		for unused in range(3): model._add_farmer(str(id))

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST: _quit_game()

func _quit_game() -> void:
	if quitting: return
	if not startup_blocked and not _save_now():
		_show_message("退出前保存失败，已取消退出。请检查存档目录并重试。")
		_open_panel("settings")
		return
	quitting = true
	host.shutdown()
	get_tree().quit()

func _smoke_capture() -> void:
	for unused in range(20): await get_tree().process_frame
	if (panel_name.is_empty() and popup.visible) or (popup.visible and popup_body.get_child_count() == 0):
		push_error("UI_STARTUP_EMPTY_WINDOW")
		host.shutdown()
		get_tree().quit(8)
		return
	for window in [get_window(), toolbar]:
		var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window.get_window_id())
		if bool(host.native.call("window_is_topmost", handle)):
			push_error("UI_WINDOW_STILL_TOPMOST")
			host.shutdown()
			get_tree().quit(9)
			return
	print("UI_STARTUP_WINDOW_OK")
	await RenderingServer.frame_post_draw
	var frame := get_viewport().get_texture().get_image()
	var toolbar_frame := toolbar.get_texture().get_image()
	frame.blit_rect(toolbar_frame, Rect2i(Vector2i.ZERO, toolbar_frame.get_size()), Vector2i.ZERO)
	frame.save_png(smoke_path)
	print("UI_SMOKE_CAPTURE ", smoke_path)
	for scene_id in ["ranch", "pond"]:
		_set_scene(scene_id)
		for unused in range(3): await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(smoke_path.get_basename() + "-" + scene_id + ".png")
	_cast_net(str(model.state.fish[0].id))
	for name in ["hub", "crops", "build", "animals", "farmers", "catalog", "settings", "caught"]:
		var direct_buttons := {"hub": "Management", "crops": "SeedShop", "animals": "AnimalShop"}
		if direct_buttons.has(name):
			var entry_button := toolbar.find_child(str(direct_buttons[name]), true, false) as Button
			entry_button.pressed.emit()
		else:
			_open_panel(name)
		if panel_name != name or not popup.visible:
			push_error("UI_SHOP_ENTRY_FAILED")
			host.shutdown()
			get_tree().quit(10)
			return
		for unused in range(3): await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var panel_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, popup.get_window_id())
		if bool(host.native.call("window_is_topmost", panel_handle)):
			push_error("UI_POPUP_STILL_TOPMOST")
			host.shutdown()
			get_tree().quit(9)
			return
		popup.get_texture().get_image().save_png(smoke_path.get_basename() + "-menu-" + name + ".png")
		if name in ["crops", "animals", "catalog"]:
			popup.size = Vector2i(540, 500)
			if is_instance_valid(catalog_grid): catalog_grid.columns = _catalog_columns()
			for unused in range(3): await get_tree().process_frame
			await RenderingServer.frame_post_draw
			popup.get_texture().get_image().save_png(smoke_path.get_basename() + "-menu-" + name + "-narrow.png")
			popup.size = Vector2i(760, 500)
		if name == "animals" and not model.state.animals.is_empty():
			_begin_animal_sale(str(model.state.animals[0].id))
			for unused in range(3): await get_tree().process_frame
			await RenderingServer.frame_post_draw
			popup.get_texture().get_image().save_png(smoke_path.get_basename() + "-menu-sell-confirm.png")
		if name == "catalog":
			catalog_selection = "wool"
			_open_panel("catalog_detail")
			for unused in range(3): await get_tree().process_frame
			await RenderingServer.frame_post_draw
			popup.get_texture().get_image().save_png(smoke_path.get_basename() + "-menu-catalog-detail.png")
	print("UI_PANELS_OK")
	var previous_popup_hash: int = hash(popup.get_texture().get_image().get_data())
	_toggle_collapse()
	for unused in range(3): await get_tree().process_frame
	var toolbar_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, toolbar.get_window_id())
	if bool(host.native.call("is_visible")) or not bool(host.native.call("window_is_visible", toolbar_handle)):
		push_error("UI_COLLAPSE_VISIBILITY_FAILED")
		host.shutdown()
		get_tree().quit(6)
		return
	_open_panel("settings")
	for unused in range(3): await get_tree().process_frame
	var popup_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, popup.get_window_id())
	var collapsed_menu := popup.get_texture().get_image()
	if not bool(host.native.call("window_is_visible", popup_handle)) or hash(collapsed_menu.get_data()) == previous_popup_hash:
		push_error("UI_COLLAPSED_MENU_DID_NOT_UPDATE")
		host.shutdown()
		get_tree().quit(7)
		return
	collapsed_menu.save_png(smoke_path.get_basename() + "-menu-collapsed.png")
	print("UI_COLLAPSED_MENU_OK")
	var escape := InputEventAction.new()
	escape.action = "ui_cancel"
	escape.pressed = true
	popup.window_input.emit(escape)
	await get_tree().process_frame
	if popup.visible or not panel_name.is_empty() or bool(host.native.call("window_is_visible", popup_handle)):
		push_error("UI_CLOSE_PANEL_FAILED")
		host.shutdown()
		get_tree().quit(11)
		return
	print("UI_SHOPS_AND_CLOSE_OK")
	_toggle_collapse()
	host.shutdown()
	get_tree().quit()
