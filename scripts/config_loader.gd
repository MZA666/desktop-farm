class_name FarmConfigLoader
extends RefCounted

## Keep the imported v0.5 workbook intact; explicit gameplay changes live in
## a separate versioned file and are shared by the app and regression tests.
static func load_values() -> Dictionary:
	var original: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/production.json"))
	var changes: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/gameplay-v0.8.json"))
	if not original is Dictionary or not changes is Dictionary:
		push_error("Farm gameplay configuration is invalid")
		return {}
	var values: Dictionary = original.duplicate(true)
	values["base_version"] = str(values.get("version", "0.5"))
	values["version"] = str(changes.version)
	for section in ["parameters", "upgrades"]:
		for key in changes.get(section, {}):
			values[section][key] = changes[section][key].duplicate(true) if changes[section][key] is Array or changes[section][key] is Dictionary else changes[section][key]
	return values
