extends Node

const MODEL = preload("res://scripts/game_state.gd")
const STORE = preload("res://scripts/save_store.gd")
const VIEW = preload("res://scripts/farm_view.gd")
const HOST = preload("res://scripts/desktop_host.gd")
const SCENE_NAMES := {"farm": "农场", "ranch": "牧场", "pond": "鱼塘"}
const INK := Color("#314638")
const CREAM := Color("#f1eedc")
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
	result.default_font_size = 13
	result.set_color("font_color", "Label", INK)
	result.set_color("font_color", "Button", INK)
	result.set_color("font_hover_color", "Button", INK)
	result.set_color("font_pressed_color", "Button", INK)
	result.set_color("font_disabled_color", "Button", Color("#879486"))
	for item in ["normal", "hover", "pressed", "disabled", "focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = Color("#dde6cc") if item == "normal" else Color("#c4d5ae")
		if item == "disabled": box.bg_color = Color("#e8eadf")
		if item == "focus": box.bg_color = Color(0, 0, 0, 0)
		box.border_color = Color("#91a77d")
		box.set_border_width_all(1)
		box.content_margin_left = 8
		box.content_margin_right = 8
		box.content_margin_top = 3
		box.content_margin_bottom = 3
		result.set_stylebox(item, "Button", box)
	result.set_constant("separation", "HBoxContainer", 6)
	result.set_constant("separation", "VBoxContainer", 8)
	return result

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
	_refresh_labels()

func _process(delta: float) -> void:
	if model == null or startup_blocked: return
	var elapsed := float(host.consume_elapsed_msec()) / 1000.0 if is_instance_valid(host) and host.ready_for_desktop else delta
	model.tick(elapsed)
	auto_save_elapsed += elapsed
	ui_elapsed += delta
	toast_remaining = maxf(0, toast_remaining - delta)
	if auto_save_elapsed >= 30.0:
		auto_save_elapsed = 0.0
		_save_now()
	if ui_elapsed >= 0.5:
		ui_elapsed = 0.0
		view.set_model(model.state)
		_refresh_labels()

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
			view.set_model(model.state)
			_refresh_labels()
			return false
	_show_message(str(result.message))
	view.set_model(model.state)
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
	view.set_process(not bool(settings.collapsed))
	_refresh_labels()

func _cast_net(id: String) -> void:
	if _act("cast_net", {"fish_id": id}, false) and not model.state.pending_fish.is_empty(): _open_panel("caught")

func _open_panel(name: String) -> void:
	panel_name = name
	_render_panel()
	var area := host.get_work_area() if is_instance_valid(host) and host.ready_for_desktop else Rect2i(Vector2i.ZERO, DisplayServer.screen_get_usable_rect().size)
	popup.size = Vector2i(mini(760, maxi(540, area.size.x - 40)), mini(500, maxi(360, area.size.y - 100)))
	popup.position = area.position + Vector2i((area.size.x - popup.size.x) / 2, maxi(20, area.size.y - 240 - popup.size.y - 16))
	popup.show()
	# This HWND must keep rendering when the scenery viewport is suspended.
	RenderingServer.viewport_set_parent_viewport(popup.get_viewport_rid(), RID())
	if is_instance_valid(host) and host.native != null:
		var popup_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, popup.get_window_id())
		host.native.call("make_independent_window", popup_handle)
		host.native.call("show_window", popup_handle)
	popup.grab_focus()

func _close_panel() -> void:
	popup.hide()
	panel_name = ""

func _render_panel() -> void:
	for child in popup_body.get_children():
		popup_body.remove_child(child)
		child.queue_free()
	match panel_name:
		"hub": _panel_hub()
		"crops": _panel_crops()
		"build": _panel_build()
		"animals": _panel_animals()
		"farmers": _panel_farmers()
		"catalog": _panel_catalog()
		"settings": _panel_settings()
		"caught": _panel_caught()
		"save_error": _panel_save_error()
	if panel_name != "save_error":
		_label(popup_body, "金币 %d  |  补种保护 %d  |  可投资 %d" % [model.balance(), model.protection(), model.investable()])

func _panel_hub() -> void:
	popup.title = "经营"
	for entry in [{"id": "crops", "text": "种子商店 / 区域作物"}, {"id": "animals", "text": "动物商店 / 购买与出售"}, {"id": "build", "text": "建设扩展"}, {"id": "farmers", "text": "农夫管理"}, {"id": "catalog", "text": "收藏图鉴"}, {"id": "settings", "text": "设置 / 帮助"}]:
		var target := str(entry.id)
		_button(popup_body, str(entry.text), func(): _open_panel(target))

func _panel_crops() -> void:
	popup.title = "种子商店 · 区域作物"
	_paragraph("选择区域和作物即可安排种植。农夫播种时先用现有种子，用完后按下方单价自动购买；无需手动囤种。只有实际播种才扣种子费用。")
	_paragraph("各格完成本轮后再换种，等待时持续保护新种子的预算。取消仅影响尚未切换的地块；作物解锁费只支付一次。")
	var selector := OptionButton.new()
	popup_body.add_child(selector)
	for region in model.state.regions:
		selector.add_item("区域 %d%s" % [int(region.index) + 1, "" if region.unlocked else "（未开）"], int(region.index))
	selector.select(region_selection)
	selector.item_selected.connect(func(index: int): region_selection = index; _render_panel())
	var selected: Dictionary = model.state.regions[region_selection]
	if not selected.unlocked:
		_paragraph("请先在建设扩展中解锁此区域。")
		return
	var crop_name := str(model.crops[str(selected.current_crop_id)].name)
	_paragraph("当前：%s%s" % [crop_name, "  →  " + str(model.crops[str(selected.pending_crop_id)].name) if not str(selected.pending_crop_id).is_empty() else ""])
	if not str(selected.pending_crop_id).is_empty():
		_button(popup_body, "取消尚未生效的切换", func(): _act("cancel_crop", {"region": region_selection}))
	for crop in config.crops:
		var crop_id := str(crop.id)
		var unlocked: bool = model.state.unlocked_crops.has(crop_id)
		var row := _row()
		var detail := "%s  ·  种价 %d  ·  库存 %d  ·  首轮 %s" % [crop.name, int(crop.seed_price), int(model.state.seeds.get(crop_id, 0)), _duration(crop.first_seconds)]
		if bool(crop.regrow): detail += "  ·  再熟 %s" % _duration(crop.repeat_seconds)
		if str(crop.mechanism) == "mixed": detail += "  ·  随机产物"
		elif str(crop.mechanism) == "processing": detail += "  ·  加工后售 %d" % int(crop.sell_price)
		else: detail += "  ·  售 %d" % int(crop.sell_price)
		var label := _label(row, detail)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if unlocked:
			_button(row, "选用 / 自动购种", func(): _act("set_crop", {"region": region_selection, "crop_id": crop_id}))
		else:
			_button(row, "解锁 %d" % int(crop.unlock_price), func(): _act("unlock_crop", {"crop_id": crop_id}))

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
	popup.title = "动物商店 · 标准购入价50%退款"
	_paragraph("动物自动吃草或干草，饥饿会暂停成长与生产。特殊动物占用对应棚舍；出售可腾位，赠送动物也退款，已成熟的产物会先结算。")
	_title("购买动物")
	for kind in config.animals:
		var id := str(kind.id)
		var row := _row()
		_expand_label(row, "%s  ·  %s ≥%d级  ·  长大 %s  ·  产出 %s" % [kind.name, model.shelter_types[str(kind.shelter_id)].name, int(kind.min_level), _duration(kind.adult_seconds), _duration(kind.produce_seconds)])
		_button(row, "购买 %d" % int(kind.price), func(): _act("buy_animal", {"animal_id": id}))
	_title("现有动物（%d）" % model.state.animals.size())
	for animal in model.state.animals:
		var instance := str(animal.id)
		var kind: Dictionary = model.animal_types[str(animal.type_id)]
		var row := _row()
		_expand_label(row, "%s · %s  %s%s" % [kind.name, instance, "成年" if animal.adult else "幼崽", " · 饥饿" if animal.hungry else ""])
		_button(row, "出售 +%d" % floori(float(kind.price) * 0.5), func(): _act("sell_animal", {"instance_id": instance}))

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
	_paragraph("作物和动物产物收获后自动登记并出售；鱼需在捕获后选择登记，登记的鱼会消耗。每一种实际产物独立收录。")
	_title("已发现 %d / %d" % [model.state.catalog.size(), config.items.size()])
	for item in config.items:
		var id := str(item.id)
		var entry: Dictionary = model.state.catalog.get(id, {})
		var row := _row()
		var label := _expand_label(row, "%s  ·  %s" % ["◆ " + str(item.name) if not entry.is_empty() else "◇ 未发现 · " + str(item.name), "累计登记 %d" % int(entry.get("count", 0)) if not entry.is_empty() else "等待收录"])
		if entry.is_empty(): label.modulate = Color("#83927d")
		_label(row, "参考售价 %d" % int(item.get("sale_price", item.get("sell_price", 0))))

func _panel_settings() -> void:
	popup.title = "设置 / 试玩说明"
	_paragraph("窗口遵循普通应用的前后顺序。点击其他应用时，其他应用显示在农场和经营窗口前方；农场仍继续生产。")
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

func _paragraph(content: String) -> void:
	var label := _label(popup_body, content)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

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
	if not is_finite(options.seconds) or options.seconds < 1.0 or options.seconds > 120.0:
		printerr("Benchmark duration must be between 1 and 120 seconds.")
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
