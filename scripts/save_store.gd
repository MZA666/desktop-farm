class_name FarmSaveStore
extends RefCounted

## Injectable file path makes persistence independently testable.
## Keep the main file untouched until a fully flushed replacement exists.
var path := "user://desktop-farm-save.json"
var last_error := ""
var recovered_from_backup := false

func _init(save_path: String = "user://desktop-farm-save.json") -> void:
	path = ProjectSettings.globalize_path(save_path)

func save(data: Dictionary) -> Dictionary:
	var directory := path.get_base_dir()
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK:
		return _failure("无法创建存档目录：%s" % error_string(error))
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _failure("无法写入临时存档：%s" % error_string(FileAccess.get_open_error()))
	file.store_string(JSON.stringify(data))
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
	var result := _read(path)
	if result.ok:
		return _migrate(result)
	var backup := _read(path + ".bak")
	if backup.ok:
		var migrated := _migrate(backup)
		if migrated.ok:
			recovered_from_backup = true
			migrated.from_backup = true
			migrated.message = "主存档损坏，已读取上一完整备份"
		return migrated
	return _failure("主存档和备份均无法读取；请保留文件后重试")

func load_backup() -> Dictionary:
	var result := _read(path + ".bak")
	if result.ok:
		var migrated := _migrate(result)
		if migrated.ok: recovered_from_backup = true
		return migrated
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

func _migrate(result: Dictionary) -> Dictionary:
	# v1 is the first released schema. Future migrations must be explicit and
	# must copy the original file to a versioned backup before changing fields.
	if int(result.data.version) != FarmState.SAVE_VERSION:
		return {"ok": false, "message": "不支持的存档版本：%s" % result.data.version}
	return result

func _failure(message: String) -> Dictionary:
	last_error = message
	return {"ok": false, "message": message}
