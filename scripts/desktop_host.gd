class_name DesktopHost
extends Node
## Physical desktop window layout and the awake-only clock; production belongs to FarmSim.

signal suspend_requested
signal resumed
signal display_changed(work_area: Rect2i)
signal status_changed(message: String)
signal tray_action(action: String)
signal desktop_visibility_changed(visible: bool, reason: String)

const SCENE_HEIGHT := 240
const TOOLBAR_HEIGHT := 32
const NATIVE_READY_MASK := 1 | 2 | 8 | 16 | 32 | 64 | 128

var native: RefCounted
var scene_window: Window
var toolbar_window: Window
var interactive := false
var collapsed := false
var power_saving := false
var topmost := false
var dpi_scale := 1.0
var ready_for_desktop := false
var user_hidden := false
var fullscreen_suppressed := false
var hotkey_available := false
var tray_available := false
var test_instance := false
var _clock_anchor := 0
var _clock_paused := false
var _last_power_epoch := 0
var _last_suspend_epoch := 0
var _monitor_poll := 0.0
var _work_area := Rect2i()
var _manual_position := false
var _last_dpi := 1.0
var _viewport_active := true
var _fullscreen_poll := 0.0
var _auxiliary_windows: Array[Window] = []
var _last_desktop_visible := true
var _last_visibility_reason := "visible"
var _window_viewport_active: Dictionary = {}
var _window_logical_visible: Dictionary = {}
var _window_native_id: Dictionary = {}

func start(scene: Window, toolbar: Window = null, settings: Dictionary = {}) -> bool:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.get_name() != "Windows" or DisplayServer.get_name() == "headless":
		status_changed.emit("桌面层仅在 Windows 图形模式启动。")
		return false
	if not ClassDB.class_exists("DesktopNative"):
		status_changed.emit("桌面原生模块未加载，请先运行 native/build.ps1。")
		return false
	native = ClassDB.instantiate("DesktopNative") as RefCounted
	# Only this explicit fixture flag isolates native tests from a player's
	# running game. Test saves are handled independently by the main controller.
	test_instance = OS.get_cmdline_user_args().has("--benchmark-fixture")
	native.call("set_test_namespace", test_instance)
	if not bool(native.call("try_single_instance")):
		status_changed.emit("农场已经运行，请使用现有窗口。")
		native = null
		return false
	get_tree().root.gui_embed_subwindows = false
	scene_window = scene
	toolbar_window = toolbar
	# A desktop farm follows ordinary Windows focus/Z order. Old saves may
	# contain topmost=true; never let them cover the user's foreground app.
	topmost = false
	interactive = bool(settings.get("interactive", false))
	collapsed = bool(settings.get("collapsed", false))
	power_saving = bool(settings.get("power_saving", false))
	scene_window.borderless = true
	scene_window.unresizable = true
	scene_window.transparent = true
	scene_window.transparent_bg = true
	scene_window.always_on_top = topmost
	scene_window.visible = true
	var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, scene_window.get_window_id())
	if not bool(native.call("attach", handle)):
		status_changed.emit("无法附加 Windows 桌面窗口。")
		shutdown()
		return false
	native.call("set_suspend_callback", Callable(self, "_on_native_suspend"))
	native.call("set_action_callback", Callable(self, "_on_native_action"))
	if toolbar_window != null:
		toolbar_window.borderless = true
		toolbar_window.unresizable = true
		toolbar_window.always_on_top = topmost
		toolbar_window.visible = true
		var toolbar_handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, toolbar_window.get_window_id())
		if not bool(native.call("make_independent_window", toolbar_handle)):
			status_changed.emit("无法建立独立的桌面工具栏。")
			shutdown()
			return false
		# Only the scenery HWND is layered and click-through. This independent
		# native window keeps toolbar controls usable in observation mode.
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, false, toolbar_window.get_window_id())
		# Native top-level windows must also be independent in the renderer.
		# Disabling the hidden scenery viewport must not freeze toolbar updates.
		RenderingServer.viewport_set_parent_viewport(toolbar_window.get_viewport_rid(), RID())
	ready_for_desktop = true
	tray_available = bool(native.call("install_tray"))
	if not tray_available:
		status_changed.emit("Windows 托盘入口创建失败（错误 %d），工具栏仍可使用。" % int(native.call("shell_last_error")))
	# Fixtures leave the player's Ctrl+Alt+F registration alone. Direct native
	# tests can exercise a separate Ctrl+Alt+Shift+F12 registration instead.
	if not test_instance:
		hotkey_available = bool(native.call("register_toggle_hotkey"))
		if not hotkey_available:
			status_changed.emit("Ctrl+Alt+F 注册失败，可能已被其他应用使用（错误 %d）。请使用托盘或工具栏。" % int(native.call("shell_last_error")))
	set_interactive(interactive)
	# Locate saved points against every monitor before any clamping. In
	# particular, a secondary monitor may have negative desktop coordinates.
	var saved_position: Variant = null
	var target_area := Rect2i()
	var position_data: Variant = settings.get("window_position", null)
	if position_data is Array and position_data.size() == 2:
		var candidate := Vector2i(int(position_data[0]), int(position_data[1]))
		var visible_areas: Array[Rect2i] = []
		for screen_index in range(DisplayServer.get_screen_count()):
			visible_areas.append(DisplayServer.screen_get_usable_rect(screen_index))
		target_area = visible_area_for_point(candidate, visible_areas)
		if target_area.size.x > 0:
			saved_position = candidate
	if target_area.size.x <= 0:
		target_area = DisplayServer.screen_get_usable_rect(DisplayServer.SCREEN_PRIMARY)
	_manual_position = saved_position != null
	# Make the native window fit wholly inside the chosen monitor before
	# querying its DPI/work area, so MonitorFromWindow cannot select a
	# neighbouring monitor based on the old wide window's overlap.
	scene_window.size = Vector2i(target_area.size.x, mini(target_area.size.y, SCENE_HEIGHT))
	scene_window.position = target_area.position
	dpi_scale = float(native.call("get_dpi_scale"))
	_work_area = native.call("get_work_area")
	_layout_windows()
	if saved_position != null:
		set_position_clamped(saved_position)
	set_collapsed(collapsed)
	set_power_saving(power_saving)
	_last_power_epoch = int(native.call("power_epoch"))
	_last_suspend_epoch = int(native.call("suspend_epoch"))
	reset_clock_anchor()
	refresh_desktop_visibility()
	return true

func _process(delta: float) -> void:
	if not ready_for_desktop:
		return
	var epoch := int(native.call("power_epoch"))
	var suspend_count := int(native.call("suspend_epoch"))
	if epoch != _last_power_epoch:
		_last_power_epoch = epoch
		# The native callback saves before actual sleep. This fallback reports
		# unhandled transitions; never apply the elapsed sleeping wall time.
		if suspend_count != _last_suspend_epoch:
			_last_suspend_epoch = suspend_count
		if not bool(native.call("is_suspended")):
			reset_clock_anchor()
			resumed.emit()
	_monitor_poll += delta
	if _monitor_poll >= 1.0:
		_monitor_poll = 0.0
		var area: Rect2i = native.call("get_work_area")
		var scale := float(native.call("get_dpi_scale"))
		if area != _work_area or not is_equal_approx(scale, dpi_scale):
			_work_area = area
			dpi_scale = scale
			_layout_windows()
			display_changed.emit(area)
	_fullscreen_poll += delta
	if _fullscreen_poll >= 0.25:
		_fullscreen_poll = 0.0
		refresh_desktop_visibility()

func _on_native_action(action: int) -> void:
	# A native notification is received inside WndProc. Defer UI changes and
	# quitting until the callback unwinds and Windows is out of that stack.
	call_deferred("_emit_tray_action", action)

func _emit_tray_action(action: int) -> void:
	if not ready_for_desktop:
		return
	var names := ["", "toggle_visibility", "toggle_interactive", "open_seed_shop", "open_animal_shop", "quit"]
	if action > 0 and action < names.size():
		tray_action.emit(names[action])

func register_auxiliary_window(window: Window) -> void:
	if is_instance_valid(window) and not _auxiliary_windows.has(window):
		_auxiliary_windows.append(window)
	if ready_for_desktop:
		_apply_desktop_visibility()

func is_desktop_visible() -> bool:
	return not user_hidden and not fullscreen_suppressed

func set_user_hidden(hidden: bool) -> void:
	if hidden and ready_for_desktop and not tray_available and not hotkey_available:
		status_changed.emit("托盘和快捷键均不可用，为避免无法返回，暂不能隐藏整个农场。")
		return
	user_hidden = hidden
	_apply_desktop_visibility()

func toggle_user_hidden() -> void:
	set_user_hidden(not user_hidden)

func refresh_desktop_visibility() -> void:
	if not ready_for_desktop or native == null:
		return
	fullscreen_suppressed = bool(native.call("foreground_is_fullscreen"))
	_apply_desktop_visibility()

func _apply_desktop_visibility() -> void:
	if not ready_for_desktop or native == null:
		return
	var visible := is_desktop_visible()
	var scene_visible := visible and not collapsed
	if not bool(native.call("set_visible", scene_visible)):
		status_changed.emit("更新桌面显示状态失败。")
	if _viewport_active != scene_visible:
		RenderingServer.viewport_set_active(scene_window.get_viewport_rid(), scene_visible)
		_viewport_active = scene_visible
	if is_instance_valid(toolbar_window):
		var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, toolbar_window.get_window_id())
		native.call("show_window" if visible else "hide_window", handle)
		_set_window_viewport_active(toolbar_window, visible)
	for window in _auxiliary_windows:
		if not is_instance_valid(window):
			continue
		if window.get_window_id() < 0:
			var key := window.get_instance_id()
			_window_viewport_active[key] = false
			_window_logical_visible[key] = window.visible
			_window_native_id[key] = -1
			continue
		var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window.get_window_id())
		# Native hiding keeps Window.visible as the user's desired state. An
		# unopened/closed popup therefore stays closed after fullscreen ends.
		var should_show := visible and window.visible
		native.call("show_window" if should_show else "hide_window", handle)
		_set_window_viewport_active(window, should_show)
	var flags := (1 if interactive else 0) | (2 if user_hidden else 0) | (4 if fullscreen_suppressed else 0) | (8 if collapsed else 0)
	native.call("set_shell_state", flags)
	var reason := "user_hidden" if user_hidden else ("fullscreen" if fullscreen_suppressed else "visible")
	if visible != _last_desktop_visible or reason != _last_visibility_reason:
		_last_desktop_visible = visible
		_last_visibility_reason = reason
		desktop_visibility_changed.emit(visible, reason)

func _set_window_viewport_active(window: Window, active: bool) -> void:
	var key := window.get_instance_id()
	var logical_visible := window.visible
	var native_id := window.get_window_id()
	# Window.show()/hide() itself changes viewport activity. Detect a logical
	# visibility transition before deciding whether the native suppression
	# layer needs a rendering change, avoiding duplicate set_active(true).
	if not _window_viewport_active.has(key) or _window_logical_visible.get(key) != logical_visible or _window_native_id.get(key) != native_id:
		_window_viewport_active[key] = logical_visible
		_window_logical_visible[key] = logical_visible
		_window_native_id[key] = native_id
	if bool(_window_viewport_active[key]) != active:
		RenderingServer.viewport_set_active(window.get_viewport_rid(), active)
		_window_viewport_active[key] = active

func _on_native_suspend() -> void:
	_clock_anchor = int(native.call("elapsed_awake_msec"))
	_last_suspend_epoch = int(native.call("suspend_epoch"))
	suspend_requested.emit()

func consume_elapsed_msec() -> int:
	if not ready_for_desktop:
		return 0
	var now := int(native.call("elapsed_awake_msec"))
	var elapsed := maxi(0, now - _clock_anchor)
	_clock_anchor = now
	if _clock_paused or bool(native.call("is_suspended")):
		return 0
	return elapsed

func reset_clock_anchor() -> void:
	_clock_anchor = int(native.call("elapsed_awake_msec")) if native != null else 0

func set_clock_paused(paused: bool) -> void:
	_clock_paused = paused
	reset_clock_anchor()

func set_interactive(enabled: bool) -> void:
	interactive = enabled
	if native != null and not bool(native.call("set_interactive", enabled)):
		status_changed.emit("切换桌面输入模式失败。")
	_apply_desktop_visibility()

func set_topmost(_enabled: bool) -> void:
	# Keep the legacy setting/API compatible without restoring permanent topmost.
	topmost = false
	if is_instance_valid(scene_window) and scene_window.always_on_top:
		scene_window.always_on_top = false
	if is_instance_valid(toolbar_window) and toolbar_window.always_on_top:
		toolbar_window.always_on_top = false

func set_collapsed(enabled: bool) -> void:
	collapsed = enabled
	if is_instance_valid(toolbar_window):
		if not toolbar_window.visible:
			toolbar_window.visible = true
		_layout_windows()
	_apply_desktop_visibility()

func set_power_saving(enabled: bool) -> void:
	power_saving = enabled
	Engine.max_fps = 15 if enabled else 30

func get_work_area() -> Rect2i:
	return _work_area

static func visible_area_for_point(point: Vector2i, areas: Array[Rect2i]) -> Rect2i:
	for area in areas:
		if area.has_point(point):
			return area
	return Rect2i()

static func scenery_size_for_area(area: Rect2i, scale: float) -> Vector2i:
	return Vector2i(area.size.x, mini(area.size.y, maxi(1, int(round(SCENE_HEIGHT * scale)))))

static func clamped_position(position: Vector2i, size: Vector2i, area: Rect2i) -> Vector2i:
	var high := area.end - size
	return Vector2i(clampi(position.x, area.position.x, maxi(area.position.x, high.x)),
		clampi(position.y, area.position.y, maxi(area.position.y, high.y)))

func set_position_clamped(position: Vector2i) -> void:
	if not is_instance_valid(scene_window):
		return
	_manual_position = true
	var clamped := clamped_position(position, scene_window.size, _work_area)
	if scene_window.position != clamped:
		scene_window.position = clamped
	_align_toolbar()

func _layout_windows() -> void:
	if not is_instance_valid(scene_window) or _work_area.size.x <= 0:
		return
	var size := scenery_size_for_area(_work_area, dpi_scale)
	var height := size.y
	if scene_window.size != size:
		scene_window.size = size
	if _manual_position:
		set_position_clamped(scene_window.position)
	else:
		var position := Vector2i(_work_area.position.x, _work_area.end.y - height)
		if scene_window.position != position:
			scene_window.position = position
	_align_toolbar()

func _align_toolbar() -> void:
	if not is_instance_valid(toolbar_window) or not is_instance_valid(scene_window):
		return
	var size := Vector2i(scene_window.size.x, maxi(32, int(round(TOOLBAR_HEIGHT * dpi_scale))))
	var position := scene_window.position
	if collapsed:
		position.y = _work_area.end.y - size.y
	# Avoid native move/show work when a settings refresh changes no geometry.
	if toolbar_window.size != size:
		toolbar_window.size = size
	if toolbar_window.position != position:
		toolbar_window.position = position

func export_settings() -> Dictionary:
	var position := scene_window.position if is_instance_valid(scene_window) else Vector2i.ZERO
	return {"topmost": topmost, "interactive": interactive, "collapsed": collapsed,
		"power_saving": power_saving, "window_position": [position.x, position.y]}

func diagnostics() -> Dictionary:
	return {"native_ready": ready_for_desktop, "status_bits": int(native.call("native_status")) if native else 0,
		"work_area": _work_area, "dpi_scale": dpi_scale, "interactive": interactive,
		"single_instance": native != null and (int(native.call("native_status")) & 128) != 0,
		"scene_window_visible": bool(native.call("is_visible")) if native else false,
		"tray_available": tray_available, "hotkey_available": hotkey_available,
		"user_hidden": user_hidden, "fullscreen_suppressed": fullscreen_suppressed,
		"desktop_visible": is_desktop_visible(), "test_instance": test_instance,
		"clock_source": "QueryUnbiasedInterruptTime" if native else "unavailable"}

func shutdown() -> void:
	ready_for_desktop = false
	tray_available = false
	hotkey_available = false
	if native != null:
		native.call("release")
		native = null

func _exit_tree() -> void:
	shutdown()
