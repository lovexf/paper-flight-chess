extends RefCounted
## 称号触发次数持久化（成就系统）
##   · 每局都可以重新触发（局内去重由 TitleManager.collect_live_titles 负责）；
##   · 每次触发往 user://titles.json 里对应称号 id 的次数 +1，图鉴据此显示「×N」；
##   · 首次访问时懒加载，不依赖 game_main 的初始化。

const PATH := "user://titles.json"
static var _counts: Dictionary = {}
static var _loaded := false

static func _ensure() -> void:
	if _loaded: return
	_loaded = true
	if FileAccess.file_exists(PATH):
		var txt := FileAccess.get_file_as_string(PATH)
		var j: Variant = JSON.parse_string(txt)
		if j is Dictionary:
			for k in (j as Dictionary):
				_counts[str(k)] = int((j as Dictionary)[k])

static func _save() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null: return
	f.store_string(JSON.stringify(_counts))
	f.close()

static func count(id: String) -> int:
	_ensure()
	return int(_counts.get(str(id), 0))

static func counts() -> Dictionary:
	_ensure()
	return _counts

## 触发一批称号（同一次触发只 +1；幂等性由调用方保证只传新达成的称号 id）
static func bump(ids: Array) -> void:
	_ensure()
	var changed := false
	for id in ids:
		var sid := str(id)
		if sid == "": continue
		_counts[sid] = int(_counts.get(sid, 0)) + 1
		changed = true
	if changed: _save()

## 测试用：清空存档（不删文件，直接覆盖为空表）
static func reset() -> void:
	_loaded = true
	_counts = {}
	_save()
