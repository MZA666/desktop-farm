extends SceneTree

## Source-only launcher. The production main can call the same packed runner
## through its fixture-only normal entry; release templates ignore --script.
const RUNNER = preload("res://scripts/shop_performance.gd")
var app: Node

func _initialize() -> void:
	if not OS.get_cmdline_user_args().has("--benchmark-fixture") or OS.get_name() != "Windows" or DisplayServer.get_name() == "headless":
		printerr("Shop-performance launcher requires Windows GUI and --benchmark-fixture; refusing player data.")
		quit(2)
		return
	_run.call_deferred()

func _run() -> void:
	var scene := load("res://scenes/main.tscn") as PackedScene
	if scene == null:
		printerr("Packed main scene was unavailable.")
		quit(2)
		return
	app = scene.instantiate()
	# Prevent the normal entry from launching a second benchmark when this
	# source wrapper already owns execution. Older main scripts ignore it.
	app.set_meta("external_shop_performance", true)
	root.add_child(app)
	var runner: RefCounted = RUNNER.new()
	var exit_code: int = await runner.run(app, self)
	quit(exit_code)
