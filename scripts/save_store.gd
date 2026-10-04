class_name FarmSaveStore
extends RefCounted

## Injectable file path makes persistence independently testable.
## Keep the main file untouched until a fully flushed replacement exists.
var path := "user://desktop-farm-save.json"
var last_error := ""
var recovered_from_backup := false
var config: Dictionary = {}

func _init(save_path: String = "user://desktop-farm-save.json", values: Dictionary = {}) -> void:
	path = ProjectSettings.globalize_path(save_path)
	config = values.duplicate(true)

func save(data: Dictionary) -> Dictionary:
	if FileAccess.file_exists(path):
		var existing := _read(path)
		if existing.ok and _unsupported_version(existing.data.get("version")):
			return _failure("现有存档版本不受支持，拒绝用旧版本覆盖")
	if not config.is_empty():
		var checker := FarmState.new(config)
		var checked := checker._validate(data)
		if not checked.ok: return _failure("拒绝保存无效状态：" + str(checked.message))
	var directory := path.get_base_dir()
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK:
		return _failure("无法创建存档目录：%s" % error_string(error))
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _failure("无法写入临时存档：%s" % error_string(FileAccess.get_open_error()))
	# Preserve sub-pixel actor coordinates and timers exactly across a restart.
	file.store_string(JSON.stringify(data, "", true, true))
	file.flush()
	error = file.get_error()
	file.close()
	if error != OK:
		return _failure("刷新临时存档失败：%s" % error_string(error))
	var verified := _read(temporary)
	if not verified.ok:
		return _failure("临时存档校验失败")
	# A damaged main file must never replace the last valid backup. Keep that
	# backup intact until the recovered state has atomically repaired the main.
	if FileAccess.file_exists(path) and not recovered_from_backup:
		var backup_temp := path + ".bak.tmp"
		error = DirAccess.copy_absolute(path, backup_temp)
		if error != OK:
			return _failure("写入备份失败：%s" % error_string(error))
		error = DirAccess.rename_absolute(backup_temp, path + ".bak")
		if error != OK:
			return _failure("替换备份失败：%s" % error_string(error))
	error = DirAccess.rename_absolute(temporary, path)
	if error != OK:
		return _failure("原子替换存档失败：%s" % error_string(error))
	last_error = ""
	recovered_from_backup = false
	return {"ok": true, "message": "已保存"}

func load_save() -> Dictionary:
	if not FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".bak"):
		return {"ok": false, "missing": true, "message": "没有存档"}
	var raw := _read(path)
	# An unknown future schema is not a corrupt current save. Do not replace it
	# with an older backup merely because this executable cannot understand it.
	if raw.ok and _unsupported_version(raw.data.get("version")):
		return _failure("不支持的存档版本：%s，请使用对应版本打开" % raw.data.version)
	var result := _prepare_load(raw, path, false)
	if result.ok:
		return result
	# Valid current progress must not silently roll back to an older backup
	# merely because preserving or writing the upgraded file was unavailable.
	if result.get("migration_write_failed", false): return result
	var backup := _prepare_load(_read(path + ".bak"), path + ".bak", true)
	if backup.ok:
		recovered_from_backup = not bool(backup.get("migrated", false))
		backup.from_backup = true
		backup.message = "主存档损坏，已恢复上一完整备份" + ("并升级为新版本" if backup.get("migrated", false) else "")
		return backup
	return _failure("主存档和备份均无法恢复；请保留文件后重试。" + str(result.message))

func load_backup() -> Dictionary:
	var result := _prepare_load(_read(path + ".bak"), path + ".bak", true)
	if result.ok:
		recovered_from_backup = not bool(result.get("migrated", false))
		return result
	return result

func _read(source: String) -> Dictionary:
	var file := FileAccess.open(source, FileAccess.READ)
	if file == null:
		return {"ok": false, "message": "无法打开存档"}
	var content := file.get_as_text()
	file.close()
	var parser := JSON.new()
	if parser.parse(content) != OK or not parser.data is Dictionary:
		return {"ok": false, "message": "存档JSON损坏"}
	if not parser.data.has("version"):
		return {"ok": false, "message": "存档缺少版本"}
	return {"ok": true, "data": parser.data, "message": "存档已读取"}

func _prepare_load(result: Dictionary, source: String, from_backup: bool) -> Dictionary:
	if not result.ok:
		return result
	var version := int(result.data.get("version", -1))
	if version == FarmState.SAVE_VERSION:
		if not config.is_empty():
			var checker := FarmState.new(config)
			var checked := checker.restore(result.data)
			if not checked.ok: return checked
			result.data = checker.snapshot()
		return result
	if version not in [1, 2, 3, 4] or config.is_empty():
		return {"ok": false, "message": "不支持的存档版本：%s" % version}
	var model := FarmState.new(config)
	var migration: Dictionary
	match version:
		1: migration = model.migrate_v1(result.data)
		2: migration = model.migrate_v2(result.data)
		3: migration = model.migrate_v3(result.data)
		4: migration = model.migrate_v4(result.data)
	if not migration.ok:
		return migration
	var checked := model.restore(migration.data)
	if not checked.ok:
		return checked
	# Preserve the exact legacy file before writing v5. Every migration backup
	# has a unique name; no subsequent save or recovery can overwrite it.
	var stamp := str(int(Time.get_unix_time_from_system())) + "-" + str(Time.get_ticks_usec())
	var legacy_backup := path + ".version-v%d-" % version + stamp + ".json"
	while FileAccess.file_exists(legacy_backup):
		legacy_backup = path + ".version-v%d-" % version + stamp + "-" + str(randi()) + ".json"
	var copied := DirAccess.copy_absolute(source, legacy_backup)
	if copied != OK:
		return _migration_failure("无法保留旧版存档备份：" + error_string(copied))
	if FileAccess.get_sha256(source) != FileAccess.get_sha256(legacy_backup):
		return _migration_failure("旧版存档备份校验失败，未执行升级")
	recovered_from_backup = from_backup
	var upgraded := model.snapshot()
	var saved := save(upgraded)
	if not saved.ok:
		return _migration_failure(str(saved.message))
	return {"ok": true, "data": upgraded, "migrated": true, "migration_backup": legacy_backup,
		"message": "存档已升级，原版备份已保留"}

func _migration_failure(message: String) -> Dictionary:
	var result := _failure(message)
	result.migration_write_failed = true
	return result

func _failure(message: String) -> Dictionary:
	last_error = message
	return {"ok": false, "message": message}

func _unsupported_version(version: Variant) -> bool:
	return not (version is int or version is float) or not is_finite(float(version)) or float(version) != floorf(float(version)) or int(version) not in [1, 2, 3, 4, FarmState.SAVE_VERSION]
