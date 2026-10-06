extends SceneTree

const Pond = preload("res://scripts/pond_rules.gd")
var failures: Array[String] = []
var assertions := 0
var config := {"fish": [
	{"id": "silver_kind", "product_id": "silver_product", "name": "小银鱼", "sell_price": 30},
	{"id": "gold_kind", "product_id": "gold_product", "name": "金纹鱼", "sell_price": 70},
]}

func _init() -> void:
	_test_first_and_repeat_capture()
	_test_cooldown_miss_and_replay()
	_test_legacy_pending_once()
	_test_upgrade_budget_and_timers()
	_test_config_and_rejections()
	_test_area_geometry_and_selection()
	_test_multi_fish_atomic_settlement()
	_test_water_cast_validation()
	_test_area_upgrade_budget_and_independence()
	if assertions == 0: failures.append("No pond assertions ran")
	if failures.is_empty():
		print("POND_RULES_PASS: %d capture/upgrade/idempotency/timer assertions" % assertions)
		quit(0)
	else:
		for failure in failures: printerr("FAIL: " + failure)
		quit(1)

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition: failures.append(message)

func fresh() -> Dictionary:
	return {"coins": 1000, "elapsed": 123.0, "transaction_id": 7,
		"pond": {"net_level": 0, "capacity_level": 0}, "catalog": {}, "pending_fish": {},
		"net_remaining": 0.0, "fish_remaining": 87.0,
		"fish": [{"id": "fish_1", "type_id": "silver_kind"},
			{"id": "fish_2", "type_id": "silver_kind"}, {"id": "fish_3", "type_id": "gold_kind"}]}

func _test_first_and_repeat_capture() -> void:
	var state := fresh()
	var first := Pond.command(state, config, "cast_net", {"fish_id": "fish_1"})
	check(first.ok and first.settlement == "catalog" and first.sale_value == 0, "First unseen product consumes the fish for catalog only")
	check(state.coins == 1000 and state.fish.size() == 2 and state.pending_fish.is_empty(), "Catch and settlement leave no intermediate pending fish")
	check(state.catalog.has("silver_product") and not state.catalog.has("silver_kind"), "Discovery uses stable product ID rather than fish type ID")
	check(state.catalog.silver_product.count == 1 and state.catalog.silver_product.first_obtained == 123.0 and state.catalog.silver_product.sources == ["fish"], "First discovery creates the normal catalog record")
	check(state.net_remaining == 20.0 and state.fish_remaining == 87.0 and state.transaction_id == 7, "Helper changes net cooldown once and leaves outer transaction sequence and spawn timer alone")
	var original_catalog := JSON.stringify(state.catalog)
	state.net_remaining = 0.0
	var sale := Pond.command(state, config, "cast_net", {"fish_id": "fish_2"})
	check(sale.ok and sale.settlement == "sell" and sale.sale_value == 30 and state.coins == 1030, "A known product sells at its actual integer price")
	check(JSON.stringify(state.catalog) == original_catalog, "Known fish sale does not alter catalog count, date, source, or appearance")
	check(state.fish.size() == 1 and state.pending_fish.is_empty(), "Sold fish is removed once without a pending choice")
	state.net_remaining = 0.0
	check(Pond.command(state, config, "cast_net", {"fish_id": "fish_3"}).ok and state.coins == 1030 and state.catalog.has("gold_product"), "A different first species still registers instead of selling")

func _test_cooldown_miss_and_replay() -> void:
	var state := fresh()
	Pond.command(state, config, "cast_net", {"fish_id": "fish_1"})
	state.net_remaining = 15.0
	var before := JSON.stringify(state)
	check(not Pond.command(state, config, "cast_net", {"fish_id": "fish_1"}).ok, "Repeated input during cooldown is rejected")
	check(JSON.stringify(state) == before, "Rejected repeat does not resell, remove another fish, or reset the timer")
	var restored: Dictionary = JSON.parse_string(before)
	check(not Pond.command(restored, config, "cast_net", {"fish_id": "fish_2"}).ok and restored.coins == state.coins and restored.net_remaining == 15.0, "Serialized catch reload preserves both settlement and cooldown")
	state.net_remaining = 0.0
	var fish_count: int = state.fish.size()
	var catalog_before := JSON.stringify(state.catalog)
	check(Pond.command(state, config, "cast_net", {"fish_id": "fish_1"}).ok, "An expired cast aimed at an already removed fish becomes a miss")
	check(state.coins == 1000 and state.fish.size() == fish_count and JSON.stringify(state.catalog) == catalog_before and state.net_remaining == 20.0, "A stale fish ID cannot pay twice; a miss consumes only the net cooldown")
	var missed := JSON.stringify(state)
	check(not Pond.command(state, config, "cast_net", {}).ok and JSON.stringify(state) == missed, "Rapid repeated misses do not restart the cooldown")

func _test_legacy_pending_once() -> void:
	for known in [false, true]:
		var state := fresh()
		state.pending_fish = state.fish.pop_front()
		state.net_remaining = 7.0
		if known:
			state.catalog.silver_product = {"id": "silver_product", "count": 4, "first_obtained": 1.0, "sources": ["fish"], "sell_price": 30, "name": "小银鱼"}
		var existing_catalog := JSON.stringify(state.catalog)
		var result := Pond.command(state, config, "resolve_pending_fish")
		check(result.ok and result.settlement == ("sell" if known else "catalog"), "Legacy pending uses the same known/unseen policy")
		check(state.coins == (1030 if known else 1000) and state.pending_fish.is_empty() and state.fish.size() == 2, "Legacy settlement consumes only the pending object, with no second pond removal")
		check(state.net_remaining == 7.0 and state.fish_remaining == 87.0, "Legacy settlement preserves remaining net and spawn timers")
		if known: check(JSON.stringify(state.catalog) == existing_catalog, "Legacy known sale leaves the complete existing catalog untouched")
		var completed := JSON.stringify(state)
		check(not Pond.command(state, config, "resolve_pending_fish").ok and JSON.stringify(state) == completed, "Repeated compatibility settlement is a no-op failure")
		var reloaded: Dictionary = JSON.parse_string(completed)
		check(not Pond.command(reloaded, config, "resolve_pending_fish").ok and reloaded.coins == state.coins and reloaded.net_remaining == 7.0, "A second startup cannot replay a persisted compatibility settlement")
	var blocked := fresh()
	blocked.pending_fish = blocked.fish.pop_front()
	var original := JSON.stringify(blocked)
	check(not Pond.command(blocked, config, "cast_net", {"fish_id": "fish_2"}).ok and JSON.stringify(blocked) == original, "Unsettled legacy fish blocks another cast without changing state")

func _test_upgrade_budget_and_timers() -> void:
	var state := fresh()
	state.net_remaining = 17.0
	state.coins = 680
	check(Pond.command(state, config, "upgrade_net", {}, 480).ok and state.coins == 480 and state.pond.net_level == 1, "Net upgrade permits exactly sufficient protected cash")
	check(Pond.cooldown(state) == 15.0 and Pond.capacity(state) == 12, "Net level affects later casts independently of pond capacity")
	check(state.net_remaining == 17.0 and state.fish_remaining == 87.0, "Upgrading a faster net does not shorten or restart the active cast timer")
	var before := JSON.stringify(state)
	check(not Pond.command(state, config, "upgrade_pond", {}, 480).ok and JSON.stringify(state) == before, "A pond upgrade cannot spend protected seed money")
	state.coins = 10000
	check(Pond.command(state, config, "upgrade_net").ok and state.coins == 9600 and Pond.cooldown(state) == 10.0, "Second net upgrade charges 400 for ten-second future casts")
	check(Pond.command(state, config, "upgrade_net").ok and state.coins == 8800 and Pond.cooldown(state) == 5.0, "Third net upgrade charges 800 for five-second future casts")
	check(Pond.command(state, config, "upgrade_pond").ok and state.coins == 8500 and Pond.capacity(state) == 18, "First capacity upgrade costs 300 for eighteen fish")
	check(Pond.command(state, config, "upgrade_pond").ok and state.coins == 7900 and Pond.capacity(state) == 24, "Second capacity upgrade costs 600 for twenty-four fish")
	check(Pond.command(state, config, "upgrade_pond").ok and state.coins == 6100 and Pond.capacity(state) == 36, "Third capacity upgrade costs 1800 for thirty-six fish")
	before = JSON.stringify(state)
	check(not Pond.command(state, config, "upgrade_net").ok and not Pond.command(state, config, "upgrade_pond").ok and JSON.stringify(state) == before, "Max-level upgrades cannot charge again")
	check(state.net_remaining == 17.0 and state.fish_remaining == 87.0, "All upgrades preserve both active timers")
	state.net_remaining = 0.0
	Pond.command(state, config, "cast_net", {})
	check(state.net_remaining == 5.0, "The next cast uses the new level after the old cooldown expires")

func _test_config_and_rejections() -> void:
	var state := fresh()
	var configured := config.duplicate(true)
	configured.upgrades = {"net_levels": Pond.NET_LEVELS.duplicate(true), "pond_capacity_levels": Pond.CAPACITY_LEVELS.duplicate(true)}
	state.coins = 680
	check(Pond.command(state, configured, "upgrade_net", {}, 480).ok and Pond.cooldown(state, configured) == 15.0, "Exported upgrade tables use the same contract as the fallback")
	var indexed := config.duplicate(true)
	indexed.fish = {"silver_kind": config.fish[0], "gold_kind": config.fish[1]}
	state.net_remaining = 0.0
	check(Pond.command(state, indexed, "cast_net", {"fish_id": "fish_1"}).ok and state.catalog.has("silver_product"), "Fish definitions may be keyed or exported as an array")
	var malformed := fresh()
	malformed.fish[0].type_id = "missing"
	var original := JSON.stringify(malformed)
	check(not Pond.command(malformed, config, "cast_net", {"fish_id": "fish_1"}).ok and JSON.stringify(malformed) == original, "Invalid fish configuration rejects before removing fish or starting cooldown")
	malformed.pending_fish = malformed.fish.pop_front()
	original = JSON.stringify(malformed)
	check(not Pond.command(malformed, config, "resolve_pending_fish").ok and JSON.stringify(malformed) == original, "Invalid legacy pending fish is preserved for recovery")
	check(not Pond.command(malformed, config, "unknown").ok and JSON.stringify(malformed) == original, "Unknown actions have no side effects")

func positioned(id: String, point: Vector2, kind := "silver_kind") -> Dictionary:
	return {"id": id, "type_id": kind, "x": point.x, "y": point.y}

func area_state(level := 0) -> Dictionary:
	var state := fresh()
	state.pond.net_area_level = level
	state.fish = []
	return state

func center_payload(point := Vector2(800, 240)) -> Dictionary:
	return {"center_x": point.x, "center_y": point.y}

func _test_area_geometry_and_selection() -> void:
	var radii := [20.0, 29.0, 35.0, 40.0]
	for level in range(4):
		var state := area_state(level)
		check(Pond.net_radius(state) == radii[level], "Area level uses the accepted physical radius")
		check(is_equal_approx(Pond.net_area(state), PI * radii[level] * radii[level]), "Net area follows the displayed circular footprint")
		check(Pond.net_catch_limit(state) == level + 1, "Actual circle area allows one through four simultaneous catches")
		for i in range(6): state.fish.append(positioned("fish_%d" % i, Vector2(800 + i, 240)))
		var result := Pond.command(state, config, "cast_net", center_payload())
		check(result.ok and result.count == level + 1 and state.fish.size() == 5 - level, "Every area tier limits a crowded cast rather than granting unlimited nearby fish")
		check(state.net_remaining == 20.0 and state.fish_remaining == 87.0, "A many-fish cast spends one cooldown and leaves the spawn cycle intact")
	var thresholds := config.duplicate(true)
	thresholds.upgrades = {"net_area_levels": Pond.NET_AREA_LEVELS.duplicate(true)}
	thresholds.upgrades.net_area_levels[1].radius = 20.0 * sqrt(2.0) - 0.001
	thresholds.upgrades.net_area_levels[2].radius = 20.0 * sqrt(3.0)
	check(Pond.net_catch_limit(area_state(1), thresholds) == 1, "Capacity does not round a circle below two base areas upward")
	check(Pond.net_catch_limit(area_state(2), thresholds) == 3, "Exact area threshold survives floating-point representation")
	var underfilled := area_state(3)
	underfilled.fish = [positioned("inside", Vector2(839.9, 240)), positioned("outside", Vector2(840.1, 240))]
	var result := Pond.command(underfilled, config, "cast_net", center_payload())
	check(result.count == 1 and result.caught_ids == ["inside"] and underfilled.fish[0].id == "outside", "A large but underfilled net catches only physically enclosed fish")
	var crowded := area_state(3)
	crowded.fish = [positioned("far", Vector2(839, 240)), positioned("outside", Vector2(841, 240)),
		positioned("tie_b", Vector2(810, 240)), positioned("tie_a", Vector2(790, 240)),
		positioned("center", Vector2(800, 240)), positioned("next", Vector2(820, 240))]
	result = Pond.command(crowded, config, "cast_net", center_payload())
	check(result.caught_ids == ["center", "tie_a", "tie_b", "next"], "Selection prefers nearest fish with stable IDs breaking equal-distance ties")
	check(crowded.fish.size() == 2 and crowded.fish[0].id == "far" and crowded.fish[1].id == "outside", "Unselected fish retain their order, position, and presence")
	var boundary := area_state()
	boundary.fish = [positioned("edge", Vector2(820, 240)), positioned("over", Vector2(820.01, 240))]
	result = Pond.command(boundary, config, "cast_net", center_payload())
	check(result.caught_ids == ["edge"] and boundary.fish[0].id == "over", "Fish centers on the exact circle edge are inside; centers just beyond it are outside")
	var authoritative := area_state()
	authoritative.fish = [positioned("inside", Vector2(801, 240)), positioned("far", Vector2(1000, 240))]
	var forced := center_payload()
	forced.merge({"fish_ids": ["far"], "radius": 9999, "limit": 9999, "net_area_level": 3})
	result = Pond.command(authoritative, config, "cast_net", forced)
	check(result.caught_ids == ["inside"] and result.radius == 20.0 and result.limit == 1, "Client lists, area levels, radii, and limits cannot override actual net upgrades or geometry")
	var legacy := area_state(1)
	legacy.fish = [positioned("target", Vector2(800, 240)), positioned("near", Vector2(820, 240)), positioned("far", Vector2(835, 240))]
	result = Pond.command(legacy, config, "cast_net", {"fish_id": "target"})
	check(result.caught_ids == ["target", "near"] and legacy.fish.size() == 1, "Legacy positioned fish targeting obeys the same area capture rule")

func _test_multi_fish_atomic_settlement() -> void:
	var state := area_state(3)
	state.fish = [positioned("one", Vector2(800, 240)), positioned("two", Vector2(801, 240)),
		positioned("three", Vector2(802, 240)), positioned("gold", Vector2(803, 240), "gold_kind")]
	var result := Pond.command(state, config, "cast_net", center_payload())
	check(result.ok and result.count == 4 and result.sold_count == 2 and result.discovered_count == 2 and result.sale_value == 60, "One unseen fish per species is consumed; later same-species fish in the batch sell immediately")
	check(state.coins == 1060 and state.fish.is_empty() and state.pending_fish.is_empty(), "All removals, sales, and discoveries finish in the same cast with no popup state")
	check(state.catalog.silver_product.count == 1 and state.catalog.gold_product.count == 1, "A batch does not inflate catalog counts with known fish sales")
	check(state.net_remaining == 20.0 and state.fish_remaining == 87.0 and state.transaction_id == 7, "Batch settlement leaves spawn and outer transaction ownership intact")
	state.fish = [positioned("repeat_one", Vector2(800, 240)), positioned("repeat_two", Vector2(801, 240)), positioned("repeat_gold", Vector2(802, 240), "gold_kind")]
	state.net_remaining = 0.0
	var catalog_before := JSON.stringify(state.catalog)
	result = Pond.command(state, config, "cast_net", center_payload())
	check(result.sold_count == 3 and result.discovered_count == 0 and result.sale_value == 130 and state.coins == 1190, "Already cataloged mixed species all sell in a later batch")
	check(JSON.stringify(state.catalog) == catalog_before, "Known batch sales preserve all existing catalog metadata")
	var saved := JSON.stringify(state)
	var restored: Dictionary = JSON.parse_string(saved)
	var restored_before := JSON.stringify(restored)
	check(not Pond.command(restored, config, "cast_net", center_payload()).ok and JSON.stringify(restored) == restored_before, "Reloading a completed batch keeps the single cooldown and prevents another payout")
	for known in [false, true]:
		var malformed := area_state(2)
		if known: malformed.catalog.silver_product = {"id": "silver_product", "count": 4, "name": "小银鱼", "sell_price": 30, "sources": ["fish"], "first_obtained": 1.0}
		malformed.fish = [positioned("valid", Vector2(800, 240)), positioned("invalid", Vector2(801, 240), "missing")]
		var before := JSON.stringify(malformed)
		check(not Pond.command(malformed, config, "cast_net", center_payload()).ok and JSON.stringify(malformed) == before, "An invalid second species rolls back both a first discovery and a first sale without removing fish or starting cooldown")
	var bad_price := config.duplicate(true)
	bad_price.fish[1].sell_price = 7.5
	var malformed := area_state(1)
	malformed.fish = [positioned("silver", Vector2(800, 240)), positioned("gold", Vector2(801, 240), "gold_kind")]
	var before := JSON.stringify(malformed)
	check(not Pond.command(malformed, bad_price, "cast_net", center_payload()).ok and JSON.stringify(malformed) == before, "Fractional invalid batch prices cannot truncate money or partly publish earlier discoveries")
	var bad_kind := config.duplicate(true)
	bad_kind.fish = {"silver_kind": config.fish[0], "gold_kind": "malformed_record"}
	check(not Pond.command(malformed, bad_kind, "cast_net", center_payload()).ok and JSON.stringify(malformed) == before, "A malformed keyed second fish definition rejects the whole cast without a script type failure")

func _test_water_cast_validation() -> void:
	for payload in [center_payload(Vector2(100, 100)), center_payload(Vector2(376.5, 258)),
		center_payload(Vector2(-1, 240)), {"center_x": NAN, "center_y": 240.0},
		{"center_x": INF, "center_y": 240.0}, {"center_x": 800.0},
		{"center_x": "800", "center_y": 240.0}, {"center_x": true, "center_y": 240.0}]:
		var state := area_state(3)
		state.fish = [positioned("fish", Vector2(800, 240))]
		var before := JSON.stringify(state)
		check(not Pond.command(state, config, "cast_net", payload).ok and JSON.stringify(state) == before, "Land, pier, outside, and non-finite/non-numeric cast centers leave every state field untouched")
	var empty := area_state(3)
	var result := Pond.command(empty, config, "cast_net", center_payload())
	check(result.ok and result.count == 0 and result.sale_value == 0 and result.caught_ids.is_empty(), "An empty but valid water circle is a normal miss")
	check(empty.net_remaining == 20.0 and empty.fish_remaining == 87.0 and empty.coins == 1000, "A valid empty-water cast consumes only one cooldown")
	var malformed := area_state(2)
	malformed.fish = [positioned("valid", Vector2(800, 240)), {"id": "invalid", "type_id": "silver_kind", "x": "not_a_number", "y": 240.0}]
	var before := JSON.stringify(malformed)
	check(not Pond.command(malformed, config, "cast_net", center_payload()).ok and JSON.stringify(malformed) == before, "Invalid model positions fail before publishing any catch")

func _test_area_upgrade_budget_and_independence() -> void:
	var state := area_state()
	state.net_remaining = 17.0
	state.coins = 779
	var before := JSON.stringify(state)
	check(not Pond.command(state, config, "upgrade_net_area", {}, 480).ok and JSON.stringify(state) == before, "An area upgrade rejects even a one-coin seed-budget deficit")
	state.coins = 780
	check(Pond.command(state, config, "upgrade_net_area", {}, 480).ok and state.coins == 480 and state.pond.net_area_level == 1, "First area upgrade charges exactly 300 while retaining the protected seed budget")
	check(Pond.net_radius(state) == 29.0 and Pond.net_catch_limit(state) == 2 and Pond.cooldown(state) == 20.0 and Pond.capacity(state) == 12, "Area size and batch capacity are independent of cooldown and pond population upgrades")
	check(state.net_remaining == 17.0 and state.fish_remaining == 87.0, "Area upgrades do not restart or shorten active cast/spawn timers")
	state.coins = 10000
	check(Pond.command(state, config, "upgrade_net_area").ok and state.coins == 9300 and Pond.net_catch_limit(state) == 3, "Second area upgrade costs 700 for three area-limited catches")
	check(Pond.command(state, config, "upgrade_net_area").ok and state.coins == 7800 and Pond.net_catch_limit(state) == 4, "Third area upgrade costs 1500 for four area-limited catches")
	before = JSON.stringify(state)
	check(not Pond.command(state, config, "upgrade_net_area").ok and JSON.stringify(state) == before, "Max area level cannot charge again")
	check(Pond.command(state, config, "upgrade_net").ok and Pond.command(state, config, "upgrade_pond").ok and Pond.net_radius(state) == 40.0 and Pond.cooldown(state) == 15.0 and Pond.capacity(state) == 18, "Purchasing each other upgrade leaves the purchased net area intact")
	var configured := config.duplicate(true)
	configured.upgrades = {"net_area_levels": Pond.NET_AREA_LEVELS.duplicate(true)}
	check(Pond.net_radius(state, configured) == 40.0 and Pond.net_catch_limit(state, configured) == 4, "Runtime exported area tables match fallback geometric behavior")
	var restored: Dictionary = JSON.parse_string(JSON.stringify(state))
	check(Pond.net_radius(restored, configured) == 40.0 and restored.net_remaining == 17.0 and restored.fish_remaining == 87.0, "Serialized independent area level and live timers retain their actual values")
