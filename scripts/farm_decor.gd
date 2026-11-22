extends RefCounted

const ITEMS := {
	"flower_box": {"name": "木制花箱", "unlock_plots": 28, "max_size": Vector2(87, 55),
		"spots": [Vector2(221, 256), Vector2(1331, 397)], "spot_names": ["小屋旁", "东南田埂"]},
	"scarecrow": {"name": "草帽稻草人", "unlock_plots": 36, "max_size": Vector2(56, 88),
		"spots": [Vector2(317, 205), Vector2(1292, 242)], "spot_names": ["西侧田埂", "东侧田埂"]},
	"stone_well": {"name": "石砌水井", "unlock_plots": 48, "max_size": Vector2(98, 98),
		"spots": [Vector2(145, 358), Vector2(1416, 298)], "spot_names": ["西南草坪", "东侧林边"]},
	"garden_lantern": {"name": "暖光路灯", "unlock_plots": 64, "max_size": Vector2(62, 112),
		"spots": [Vector2(304, 409), Vector2(1491, 383)], "spot_names": ["西南小路", "东南林边"]},
}

static func opened_plots(state: Dictionary) -> int:
	var count := 0
	for plot in state.get("plots", []):
		if plot.open: count += 1
	return count

static func placement(state: Dictionary, id: String) -> int:
	return int(state.get("decorations", {}).get(id, 0))
