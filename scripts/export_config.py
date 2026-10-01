"""Export the accepted v0.5 workbook snapshot into deterministic runtime data.

Read data/source/workbook-v0.5.json, which contains the original workbook's formula
expressions and cached values. Runtime code only consumes the fixed outputs;
it never recalculates the design's economic formulas.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# These identifiers are deliberately explicit: renaming or reordering a row in
# the design must not change a saved game's identifiers.
CROP_IDS = {
    "蓝爵花": "blue_jazz", "胡萝卜": "carrot", "花椰菜": "cauliflower",
    "咖啡豆": "coffee_bean", "大蒜": "garlic", "青豆": "green_bean",
    "羽衣甘蓝": "kale", "防风草": "parsnip", "土豆": "potato",
    "大黄": "rhubarb", "草莓": "strawberry", "郁金香": "tulip",
    "未碾米": "unmilled_rice", "蓝莓": "blueberry", "玉米": "corn",
    "啤酒花": "hops", "辣椒": "hot_pepper", "甜瓜": "melon",
    "虞美人": "poppy", "萝卜": "radish", "红叶卷心菜": "red_cabbage",
    "杨桃": "starfruit", "夏季亮片": "summer_spangle", "西葫芦": "summer_squash",
    "向日葵": "sunflower", "番茄": "tomato", "小麦": "wheat",
    "苋菜": "amaranth", "洋蓟": "artichoke", "甜菜": "beet",
    "小白菜": "bok_choy", "西蓝花": "broccoli", "蔓越莓": "cranberry",
    "茄子": "eggplant", "玫瑰仙子": "fairy_rose", "葡萄": "grape",
    "南瓜": "pumpkin", "山药": "yam", "霜瓜": "powdermelon",
    "远古果实": "ancient_fruit", "仙人掌果子": "cactus_fruit", "纤维": "fiber",
    "菠萝": "pineapple", "齐瓜": "qi_fruit", "宝石甜莓": "sweet_gem_berry",
    "芋头": "taro_root", "茶叶": "tea_leaves", "春季种子": "spring_seeds",
    "夏季种子": "summer_seeds", "秋季种子": "fall_seeds", "冬季种子": "winter_seeds",
    "混合种子": "mixed_seeds", "混合花卉种子": "mixed_flower_seeds",
}
ANIMAL_IDS = {
    "鸡": "chicken", "鸭": "duck", "兔": "rabbit", "牛": "cow", "山羊": "goat",
    "绵羊": "sheep", "猪": "pig", "虚空鸡": "void_chicken", "金鸡": "golden_chicken",
    "恐龙": "dinosaur", "鸵鸟": "ostrich",
}
BARN_IDS = {
    "鸡窝": "chicken_coop", "鸭窝": "duck_coop", "兔舍": "rabbit_hutch",
    "牛棚": "cow_barn", "山羊棚": "goat_barn", "羊圈": "sheep_pen", "猪圈": "pig_pen",
}
PRODUCT_IDS = {
    "鸡蛋": "egg", "鸭蛋": "duck_egg", "羊毛": "wool", "牛奶": "milk",
    "羊奶": "goat_milk", "松露": "truffle", "虚空蛋": "void_egg", "金蛋": "golden_egg",
    "恐龙蛋": "dinosaur_egg", "鸵鸟蛋": "ostrich_egg", "大米": "rice",
    "野山葵": "wild_horseradish", "黄水仙": "daffodil", "韭葱": "leek", "蒲公英": "dandelion",
    "香味浆果": "spice_berry", "甜豌豆": "sweet_pea", "普通蘑菇": "common_mushroom",
    "野梅": "wild_plum", "榛子": "hazelnut", "黑莓": "blackberry", "冬根": "winter_root",
    "水晶果": "crystal_fruit", "雪山药": "snow_yam", "番红花": "crocus",
    "小银鱼": "silver_fish", "青背鱼": "blueback_fish", "金纹鱼": "goldstripe_fish",
    **CROP_IDS,
}
MECHANISMS = {"单次": "single", "连收": "regrow", "返种": "return_seed",
              "加工": "processing", "材料": "material", "混合": "mixed"}
POOLS = {
    "春季种子": [("野山葵", 50), ("黄水仙", 30), ("韭葱", 60), ("蒲公英", 40)],
    "夏季种子": [("香味浆果", 80), ("葡萄", 80), ("甜豌豆", 50)],
    "秋季种子": [("普通蘑菇", 40), ("野梅", 80), ("榛子", 90), ("黑莓", 20)],
    "冬季种子": [("冬根", 70), ("水晶果", 150), ("雪山药", 100), ("番红花", 60)],
    "混合种子": [("花椰菜", 175), ("防风草", 35), ("土豆", 80)],
    "混合花卉种子": [("郁金香", 30), ("蓝爵花", 50)],
}


class Workbook:
    def __init__(self, path: Path):
        self.raw = path.read_bytes()
        self.sheets = {}
        for sheet in json.loads(self.raw.decode("utf-8-sig")):
            self.sheets[sheet["sheet"]] = {
                c["cell"]: c["cached"] if c.get("type") == "f" else c["value"]
                for row in sheet["rows"] for c in row["cells"]
            }

    def value(self, sheet: str, column: str, row: int):
        return self.sheets[sheet].get(f"{column}{row}")

    def integer(self, sheet: str, column: str, row: int) -> int:
        value = self.value(sheet, column, row)
        if value is None or isinstance(value, bool) or int(value) != value:
            raise ValueError(f"Expected integer at {sheet}!{column}{row}: {value}")
        return int(value)

    def seconds(self, sheet: str, column: str, row: int) -> int:
        seconds = self.value(sheet, column, row) * 60
        if int(seconds) != seconds:
            raise ValueError(f"Non-integer runtime seconds: {sheet}!{column}{row}")
        return int(seconds)


def build_config(workbook: Workbook) -> dict:
    w = workbook
    products = {}

    def product(name: str, price: int, category: str, source: str) -> str:
        identifier = PRODUCT_IDS[name]
        entry = {"id": identifier, "name": name, "category": category,
                 "sale_price": price, "sell_price": price, "source": source}
        if identifier in products:
            old = products[identifier]
            if old["sale_price"] != price:
                raise ValueError(f"Conflicting sell price for product {identifier}")
        else:
            products[identifier] = entry
        return identifier

    crops = []
    for row in range(5, 58):
        sheet = "作物生产"
        v = lambda column: w.value(sheet, column, row)
        i = lambda column: w.integer(sheet, column, row)
        name = v("A")
        mechanism = MECHANISMS[v("C")]
        pool = []
        price = 0 if mechanism == "mixed" else i("E")
        product_id = ""
        raw_product_id = ""
        if mechanism == "mixed":
            values = POOLS[name]
            for pool_name, pool_price in values:
                item_id = product(pool_name, pool_price, "crop", f"{sheet}!X{row}")
                pool.append({"item_id": item_id, "product_id": item_id, "name": pool_name,
                             "sale_price": pool_price, "sell_price": pool_price,
                             "weight": 1 / len(values)})
        elif mechanism == "processing":
            raw_product_id = product(name, i("O"), "crop", f"{sheet}!O{row}")
            product_id = product("大米", price, "crop", f"{sheet}!E{row}")
        else:
            product_id = product(name, price, "crop", f"{sheet}!E{row}")
        crop = {"id": CROP_IDS[name], "name": name, "season": v("B"),
                "seed_cost": i("D"), "sale_price": price,
                "grow_seconds": w.seconds(sheet, "F", row),
                "regrow_seconds": w.seconds(sheet, "G", row), "mechanism": mechanism,
                "unlock_cost": i("I"), "initial_unlocked": bool(i("AA")),
                "product_id": product_id, "raw_product_id": raw_product_id,
                "process_seconds": w.seconds(sheet, "Q", row), "yield": i("H"),
                "replant_cost": i("P"), "pool": pool,
                "expected_sale_price": v("E"), "notes": v("X"),
                "source": {"sheet": sheet, "row": row, "seed": v("Y"), "product": v("Z")}}
        # Readable aliases keep the simulation API convenient; the canonical
        # fields above match the developer-facing schema.
        crop.update(seed_price=crop["seed_cost"], sell_price=crop["sale_price"],
                    first_seconds=crop["grow_seconds"], repeat_seconds=crop["regrow_seconds"],
                    unlock_price=crop["unlock_cost"], processing_seconds=crop["process_seconds"],
                    regrow=mechanism == "regrow", return_seed=mechanism == "return_seed")
        crops.append(crop)

    barns = []
    for row in range(100, 107):
        sheet = "参数与费用"
        name = w.value(sheet, "A", row)
        costs = [w.integer(sheet, column, row) for column in ("C", "E", "G")]
        capacities = [w.integer(sheet, column, row) for column in ("B", "D", "F")]
        initial = w.integer(sheet, "H", row)
        barns.append({"id": BARN_IDS[name], "name": name, "costs": costs,
                      "capacities": capacities, "initial_level": initial,
                      "levels": [{"level": index + 1, "capacity": capacity, "cost": cost}
                                 for index, (capacity, cost) in enumerate(zip(capacities, costs))],
                      "source": f"{sheet}!A{row}:I{row}"})

    animals = []
    for row in range(6, 17):
        sheet = "动物生产"
        v = lambda column: w.value(sheet, column, row)
        i = lambda column: w.integer(sheet, column, row)
        barn_name, level = re.fullmatch(r"(.+)([1-3])级", v("B")).groups()
        product_id = product(v("E"), i("F"), "animal", f"{sheet}!F{row}")
        animal = {"id": ANIMAL_IDS[v("A")], "name": v("A"), "barn_id": BARN_IDS[barn_name],
                  "min_level": int(level), "cost": i("C"),
                  "mature_seconds": w.seconds(sheet, "D", row), "product_id": product_id,
                  "sale_price": i("F"), "interval_seconds": w.seconds(sheet, "G", row),
                  "grass_per_meal": i("H"), "yield": i("R"), "initial_count": i("T"),
                  "basic_full_count": i("U"), "source": {"sheet": sheet, "row": row,
                                                           "animal": v("P"), "product": v("Q")}}
        animal.update(shelter_id=animal["barn_id"], price=animal["cost"],
                      adult_seconds=animal["mature_seconds"], produce_seconds=animal["interval_seconds"],
                      food_grass=animal["grass_per_meal"], sell_price=animal["sale_price"])
        animals.append(animal)

    fish = []
    for row in range(5, 8):
        sheet = "鱼塘"
        name = w.value(sheet, "A", row)
        price = w.integer(sheet, "C", row)
        item_id = product(name, price, "fish", f"{sheet}!C{row}")
        weight = w.value(sheet, "B", row)
        fish.append({"id": PRODUCT_IDS[name], "name": name, "product_id": item_id,
                     "sale_price": price, "sell_price": price, "probability": weight,
                     "weight": weight, "unlock_cost": w.integer(sheet, "F", row),
                     "source": f"{sheet}!A{row}:G{row}"})

    sheet = "参数与费用"
    p = lambda row: w.value(sheet, "B", row)
    parameters = {
        "max_crop_regions": p(9), "max_plots_per_region": p(10), "yield_per_harvest": p(11),
        "max_grass_plots": p(23), "max_farmers_per_scene": p(18),
        "farmer_energy": p(15), "rest_energy_per_second": p(16), "support_energy": p(17),
        "action_seconds": p(34), "walk_seconds": p(35), "support_seconds": p(48),
        "task_energy": {"sow": 2, "water": 1, "harvest": 1, "cut_grass": 1,
                        "add_hay": 1, "sow_grass": 2, "collect_product": 1},
        "grass_growth_seconds": int(p(27) * 60), "grass_max_clumps": p(26),
        "grass_growth_min": p(55), "grass_growth_max": p(56),
        "grass_extra_probability": p(28), "grass_extra_min": p(57), "grass_extra_max": p(58),
        "grass_spread_probability": p(29), "grass_seed_cost": p(30),
        "meal_seconds": int(p(31) * 60), "hay_transfer_max": p(36),
        "fish_capacity": p(41), "fish_spawn_seconds": int(p(42) * 60),
        "net_cooldown_seconds": p(43), "autosave_seconds": p(49), "logic_seconds": p(52),
        "normal_fps": p(50), "power_saving_fps": p(51), "animal_refund_ratio": 0.5,
        "auto_register_crop_products": True, "auto_register_animal_products": True,
        "pending_crop_reserve": True, "allow_cancel_crop_switch": True,
        "offline_progress": False, "mother_grass_plots": p(25),
        "source": "参数与费用!A5:E60; desktop-farm-design-v0-5.docx table 61; confirmed user decisions",
    }
    upgrades = {
        "plot_costs": [w.integer(sheet, "B", row) for row in range(74, 90)],
        "region_costs": [0, 0, 0, 0, w.integer(sheet, "B", 94), w.integer(sheet, "B", 95)],
        "grass_plot_costs": [0] * 6 + [w.integer(sheet, "C", row) for row in range(118, 133) for _ in range(6)],
        "farmer_costs": [w.integer(sheet, "B", row) for row in range(138, 144)],
        "hay_storage": [{"capacity": w.integer(sheet, "A", row), "cost": w.integer(sheet, "B", row)}
                        for row in range(111, 115)],
        "source": "参数与费用!A73:J143",
    }
    initial = {"coins": p(5), "crop_id": "parsnip", "crop_regions": p(7),
               "plots_per_region": p(8), "seeds": {"parsnip": p(6)},
               "grass_plots": p(24), "grass_clumps": p(26), "mother_grass_plots": p(25),
               "trough_hay": p(33), "warehouse_hay": 0, "hay_capacity": p(37),
               "barn_levels": {barn["id"]: barn["initial_level"] for barn in barns},
               "animals": [{"id": a["id"], "count": a["initial_count"]} for a in animals if a["initial_count"]],
               "farmers_per_scene": p(19), "fish_count": p(40),
               "source": "参数与费用!A5:E43"}
    return {"schema_version": 1, "version": "0.5", "crops": crops,
            "items": list(products.values()), "products": products,
            "animals": animals, "barns": barns, "shelters": barns, "fish": fish,
            "parameters": parameters, "upgrades": upgrades, "initial": initial,
            "source": {"workbook": "C:/Users/Administrator/Downloads/production-values-v0-5.xlsx",
                       "design": "C:/Users/Administrator/Downloads/desktop-farm-design-v0-5.docx",
                       "snapshot": "data/source/workbook-v0.5.json", "snapshot_sha256": hashlib.sha256(w.raw).hexdigest(),
                       "formula_policy": "Use cached v0.5 values; runtime never recalculates workbook formulas.",
                       "decision_overrides": ["Animal sale refunds 50% of standard purchase price, including gifted animals.",
                                              "Crop and animal products auto-register then sell; fish remains a player choice.",
                                              "Pending crop-switch seed budget remains reserved and can be cancelled."]}}


def export(source: Path, output: Path):
    config = build_config(Workbook(source))
    output.parent.mkdir(parents=True, exist_ok=True)
    # Keep exports byte-stable across Windows and Unix checkouts.
    with output.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "data/source/workbook-v0.5.json")
    parser.add_argument("--output", type=Path, default=ROOT / "data/production.json")
    args = parser.parse_args()
    config = export(args.source, args.output)
    print(f"Exported {len(config['crops'])} crops, {len(config['animals'])} animals, "
          f"{len(config['barns'])} barns, {len(config['fish'])} fish and {len(config['items'])} products to {args.output}")


if __name__ == "__main__":
    main()
