"""Verify the runtime export against all accepted workbook prices and timers.

Run: python tests/validate_config.py
The source snapshot is independent of the runtime JSON. Tests inspect workbook
cells directly, check every row, and reproduce published aggregate totals.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / "data/production.json").read_text(encoding="utf-8"))
SOURCE_BYTES = (ROOT / "data/source/workbook-v0.5.json").read_bytes()
WORKBOOK = {
    s["sheet"]: {c["cell"]: c["cached"] if c.get("type") == "f" else c["value"]
                 for r in s["rows"] for c in r["cells"]}
    for s in json.loads(SOURCE_BYTES.decode("utf-8-sig"))
}


class ConfigValidation(unittest.TestCase):
    def setUp(self):
        self.crops = {c["id"]: c for c in CONFIG["crops"]}
        self.animals = {a["id"]: a for a in CONFIG["animals"]}
        self.barns = {b["id"]: b for b in CONFIG["barns"]}
        self.items = {item["id"]: item for item in CONFIG["items"]}

    def test_counts_and_unique_stable_ids(self):
        for key, expected in (("crops", 53), ("animals", 11), ("barns", 7), ("fish", 3), ("items", 75)):
            records = CONFIG[key]
            self.assertEqual(len(records), expected, key)
            self.assertEqual(len({record["id"] for record in records}), expected, key)
            for record in records:
                self.assertRegex(record["id"], r"^[a-z][a-z0-9_]*$")
        self.assertEqual(CONFIG["products"], self.items)
        self.assertEqual(CONFIG["shelters"], CONFIG["barns"])
        self.assertEqual(len([c for c in self.crops.values() if c["mechanism"] == "mixed"]), 6)
        self.assertEqual(sum(a["basic_full_count"] > 0 for a in self.animals.values()), 7)

    def test_every_crop_price_timer_and_unlock_matches_source(self):
        sheet = WORKBOOK["作物生产"]
        by_name = {crop["name"]: crop for crop in self.crops.values()}
        mechanisms = {"单次": "single", "连收": "regrow", "返种": "return_seed",
                      "加工": "processing", "材料": "material", "混合": "mixed"}
        for row in range(5, 58):
            with self.subTest(row=row, name=sheet[f"A{row}"]):
                crop = by_name[sheet[f"A{row}"]]
                self.assertEqual(crop["seed_cost"], sheet[f"D{row}"])
                self.assertEqual(crop["grow_seconds"], sheet[f"F{row}"] * 60)
                self.assertEqual(crop["regrow_seconds"], sheet[f"G{row}"] * 60)
                self.assertEqual(crop["process_seconds"], sheet[f"Q{row}"] * 60)
                self.assertEqual(crop["unlock_cost"], sheet[f"I{row}"])
                self.assertEqual(crop["initial_unlocked"], bool(sheet[f"AA{row}"]))
                self.assertEqual(crop["mechanism"], mechanisms[sheet[f"C{row}"]])
                self.assertEqual(crop["replant_cost"], sheet[f"P{row}"])
                self.assertEqual(crop["yield"], 1)
                self.assertEqual(crop["expected_sale_price"], sheet[f"E{row}"])
                if crop["mechanism"] == "mixed":
                    self.assertEqual(crop["sale_price"], 0)
                    self.assertEqual(crop["product_id"], "")
                else:
                    self.assertEqual(crop["sale_price"], sheet[f"E{row}"])
                    self.assertEqual(self.items[crop["product_id"]]["sale_price"], crop["sale_price"])

    def test_all_mixed_pools_use_real_prices_and_sum_to_one(self):
        expected_names = {
            "spring_seeds": {"野山葵": 50, "黄水仙": 30, "韭葱": 60, "蒲公英": 40},
            "summer_seeds": {"香味浆果": 80, "葡萄": 80, "甜豌豆": 50},
            "fall_seeds": {"普通蘑菇": 40, "野梅": 80, "榛子": 90, "黑莓": 20},
            "winter_seeds": {"冬根": 70, "水晶果": 150, "雪山药": 100, "番红花": 60},
            "mixed_seeds": {"花椰菜": 175, "防风草": 35, "土豆": 80},
            "mixed_flower_seeds": {"郁金香": 30, "蓝爵花": 50},
        }
        for identifier, prices in expected_names.items():
            with self.subTest(crop=identifier):
                crop = self.crops[identifier]
                pool = crop["pool"]
                self.assertEqual({p["name"]: p["sale_price"] for p in pool}, prices)
                self.assertTrue(math.isclose(sum(p["weight"] for p in pool), 1))
                self.assertTrue(all(math.isclose(p["weight"], 1 / len(pool)) for p in pool))
                self.assertTrue(math.isclose(sum(p["weight"] * p["sale_price"] for p in pool), crop["expected_sale_price"]))
                for item in pool:
                    self.assertEqual(self.items[item["item_id"]]["sale_price"], item["sale_price"])
                    self.assertEqual(item["product_id"], item["item_id"])
        self.assertEqual(self.crops["mixed_seeds"]["grow_seconds"], 3240)
        self.assertEqual(self.crops["mixed_flower_seeds"]["grow_seconds"], 1260)

    def test_all_transaction_prices_and_runtime_times_are_integers(self):
        for crop in self.crops.values():
            for field in ("seed_cost", "sale_price", "unlock_cost", "grow_seconds",
                          "regrow_seconds", "process_seconds", "replant_cost"):
                with self.subTest(crop=crop["id"], field=field):
                    self.assertIs(type(crop[field]), int)
                    self.assertGreaterEqual(crop[field], 0)
        for item in self.items.values():
            self.assertIs(type(item["sale_price"]), int)
            self.assertGreater(item["sale_price"], 0)
        for animal in self.animals.values():
            for field in ("cost", "sale_price", "mature_seconds", "interval_seconds", "grass_per_meal"):
                self.assertIs(type(animal[field]), int)
                self.assertGreater(animal[field], 0)

    def test_regrow_rice_and_sunflower_rules(self):
        for crop in self.crops.values():
            if crop["mechanism"] == "regrow":
                self.assertEqual(crop["regrow_seconds"] * 3, crop["grow_seconds"])
                self.assertEqual(crop["replant_cost"], 0)
            else:
                self.assertEqual(crop["regrow_seconds"], 0)
        rice = self.crops["unmilled_rice"]
        self.assertEqual((rice["grow_seconds"], rice["process_seconds"], rice["seed_cost"]), (1620, 180, 40))
        self.assertEqual(rice["product_id"], "rice")
        self.assertEqual(self.items["rice"]["sale_price"], 100)
        self.assertEqual(self.items[rice["raw_product_id"]]["sale_price"], 30)
        sunflower = self.crops["sunflower"]
        self.assertEqual((sunflower["grow_seconds"], sunflower["seed_cost"], sunflower["sale_price"]), (2520, 200, 80))
        self.assertTrue(sunflower["return_seed"])
        self.assertFalse(sunflower["regrow"])
        self.assertEqual(sunflower["replant_cost"], 0)

    def test_every_animal_matches_source_and_has_valid_barn_product(self):
        sheet = WORKBOOK["动物生产"]
        by_name = {animal["name"]: animal for animal in self.animals.values()}
        for row in range(6, 17):
            animal = by_name[sheet[f"A{row}"]]
            with self.subTest(animal=animal["id"]):
                self.assertEqual(animal["cost"], sheet[f"C{row}"])
                self.assertEqual(animal["mature_seconds"], sheet[f"D{row}"] * 60)
                self.assertEqual(animal["sale_price"], sheet[f"F{row}"])
                self.assertEqual(animal["interval_seconds"], sheet[f"G{row}"] * 60)
                self.assertEqual(animal["grass_per_meal"], sheet[f"H{row}"])
                self.assertEqual(animal["initial_count"], sheet[f"T{row}"])
                self.assertEqual(animal["basic_full_count"], sheet[f"U{row}"])
                self.assertEqual(animal["yield"], 1)
                barn = self.barns[animal["barn_id"]]
                self.assertEqual(f"{barn['name']}{animal['min_level']}级", sheet[f"B{row}"])
                self.assertEqual(self.items[animal["product_id"]]["name"], sheet[f"E{row}"])
                self.assertEqual(self.items[animal["product_id"]]["sale_price"], animal["sale_price"])
                self.assertEqual(animal["cost"] // 2, animal["cost"] * CONFIG["parameters"]["animal_refund_ratio"])

    def test_all_barn_levels_costs_and_initial_gift(self):
        sheet = WORKBOOK["参数与费用"]
        by_name = {barn["name"]: barn for barn in self.barns.values()}
        for row in range(100, 107):
            barn = by_name[sheet[f"A{row}"]]
            self.assertEqual(barn["costs"], [sheet[f"{c}{row}"] for c in ("C", "E", "G")])
            self.assertEqual(barn["capacities"], [4, 8, 12])
            self.assertEqual(barn["initial_level"], sheet[f"H{row}"])
            paid = sum(barn["costs"][barn["initial_level"]:])
            self.assertEqual(paid, sheet[f"I{row}"])
        self.assertEqual(sum(barn["capacities"][-1] for barn in self.barns.values()), 84)
        self.assertEqual(sum(barn["initial_level"] for barn in self.barns.values()), 1)

    def test_fish_prices_probabilities_and_expected_income(self):
        sheet = WORKBOOK["鱼塘"]
        by_name = {fish["name"]: fish for fish in CONFIG["fish"]}
        for row in range(5, 8):
            fish = by_name[sheet[f"A{row}"]]
            self.assertEqual(fish["sale_price"], sheet[f"C{row}"])
            self.assertEqual(fish["weight"], sheet[f"B{row}"])
            self.assertEqual(fish["unlock_cost"], 0)
        self.assertEqual(sum(fish["weight"] for fish in CONFIG["fish"]), 1)
        average = sum(fish["weight"] * fish["sale_price"] for fish in CONFIG["fish"])
        self.assertEqual(average, 50)
        self.assertEqual(average * 3600 / CONFIG["parameters"]["fish_spawn_seconds"], 1000)
        self.assertEqual(average * CONFIG["initial"]["fish_count"], 600)

    def test_individual_upgrade_costs(self):
        upgrades = CONFIG["upgrades"]
        sheet = WORKBOOK["参数与费用"]
        self.assertEqual(upgrades["plot_costs"], [sheet[f"B{row}"] for row in range(74, 90)])
        self.assertEqual(upgrades["plot_costs"], [0] * 6 + list(range(350, 3501, 350)))
        self.assertEqual(upgrades["region_costs"], [0, 0, 0, 0, 10000, 20000])
        self.assertEqual(upgrades["grass_plot_costs"], [0] * 6 + [50 * (1 + (n - 7) // 6) for n in range(7, 97)])
        self.assertEqual(upgrades["farmer_costs"], [1000 * 2 ** n for n in range(6)])
        self.assertEqual(upgrades["hay_storage"], [{"capacity": sheet[f"A{row}"], "cost": sheet[f"B{row}"]}
                                                        for row in range(111, 115)])

    def test_all_expansion_costs_match_published_878725_total(self):
        upgrades = CONFIG["upgrades"]
        sheet = WORKBOOK["参数与费用"]
        totals = {
            148: sum(upgrades["plot_costs"]) * 6,
            149: sum(upgrades["region_costs"]),
            150: sum(upgrades["grass_plot_costs"]),
            151: sum(sum(b["costs"][b["initial_level"]:]) for b in self.barns.values()),
            152: sum(t["cost"] for t in upgrades["hay_storage"]),
            153: sum(upgrades["farmer_costs"]),
            154: sum(a["cost"] * (a["basic_full_count"] - a["initial_count"])
                     for a in self.animals.values() if a["basic_full_count"]),
            155: sum(c["unlock_cost"] for c in self.crops.values()),
        }
        for row, total in totals.items():
            self.assertEqual(total, sheet[f"B{row}"], sheet[f"A{row}"])
        self.assertEqual(sum(totals.values()), 878725)
        self.assertEqual(sum(totals.values()), sheet["B156"])

    def test_initial_assets_and_investment_budget(self):
        initial = CONFIG["initial"]
        self.assertEqual(initial["coins"], 1000)
        self.assertEqual(initial["crop_regions"] * initial["plots_per_region"], 24)
        self.assertEqual(initial["seeds"], {"parsnip": 24})
        self.assertEqual(initial["animals"], [{"id": "chicken", "count": 4}])
        self.assertEqual(initial["trough_hay"], 8)
        self.assertEqual(initial["warehouse_hay"], 0)
        self.assertEqual(initial["fish_count"], 12)
        self.assertEqual(initial["grass_plots"], 6)
        self.assertEqual(initial["mother_grass_plots"], 2)
        reserve = 24 * self.crops["parsnip"]["seed_cost"]
        self.assertEqual(reserve, 480)
        self.assertEqual(initial["coins"] - reserve, 520)
        self.assertEqual(initial["coins"] - reserve - 300, 220)
        self.assertEqual(4 * self.animals["chicken"]["cost"] * CONFIG["parameters"]["animal_refund_ratio"], 1600)

    def test_every_workbook_parameter_is_mapped_correctly(self):
        params = CONFIG["parameters"]
        sheet = WORKBOOK["参数与费用"]
        rows = {"max_crop_regions": 9, "max_plots_per_region": 10, "yield_per_harvest": 11,
                "max_grass_plots": 23, "max_farmers_per_scene": 18, "farmer_energy": 15,
                "rest_energy_per_second": 16, "support_energy": 17, "action_seconds": 34,
                "walk_seconds": 35, "support_seconds": 48, "grass_max_clumps": 26,
                "grass_growth_min": 55, "grass_growth_max": 56, "grass_extra_probability": 28,
                "grass_extra_min": 57, "grass_extra_max": 58, "grass_spread_probability": 29,
                "grass_seed_cost": 30, "hay_transfer_max": 36, "fish_capacity": 41,
                "net_cooldown_seconds": 43, "autosave_seconds": 49, "logic_seconds": 52,
                "normal_fps": 50, "power_saving_fps": 51, "mother_grass_plots": 25}
        for key, row in rows.items():
            self.assertEqual(params[key], sheet[f"B{row}"], key)
        for key, row in (("grass_growth_seconds", 27), ("meal_seconds", 31), ("fish_spawn_seconds", 42)):
            self.assertEqual(params[key], sheet[f"B{row}"] * 60)
        self.assertEqual(params["task_energy"], {"sow": 2, "water": 1, "harvest": 1,
                                                 "cut_grass": 1, "add_hay": 1, "sow_grass": 2,
                                                 "collect_product": 1})
        self.assertFalse(params["offline_progress"])
        self.assertTrue(params["pending_crop_reserve"])
        self.assertTrue(params["allow_cancel_crop_switch"])
        self.assertTrue(params["auto_register_crop_products"])
        self.assertTrue(params["auto_register_animal_products"])

    def test_source_provenance_matches_current_snapshot(self):
        self.assertEqual(CONFIG["schema_version"], 1)
        self.assertEqual(CONFIG["version"], "0.5")
        self.assertEqual(CONFIG["source"]["snapshot"], "data/source/workbook-v0.5.json")
        self.assertEqual(CONFIG["source"]["snapshot_sha256"], hashlib.sha256(SOURCE_BYTES).hexdigest())
        self.assertTrue(CONFIG["source"]["workbook"].endswith("production-values-v0-5.xlsx"))
        self.assertTrue(CONFIG["source"]["design"].endswith("desktop-farm-design-v0-5.docx"))
        self.assertEqual(len(CONFIG["source"]["decision_overrides"]), 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
