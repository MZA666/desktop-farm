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
