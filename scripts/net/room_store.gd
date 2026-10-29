# ============================================================================
#  房间持久化（M5）：房主进程被杀后「恢复房间」的基础
#
#  【为什么用二进制 var 而不是 JSON】JSON 往返会把 int 变成 float（动作里的
#  value/chessIndex/seq 全靠 int），并丢 int 键 —— 恢复后状态 hash 必然对不上。
#  var_to_bytes/store_var 保留类型与键，这也是联机协议不用裸 JSON 的原因。
#
#  布局：user://rooms/<roomId>/
#    meta.bin      房间元数据（座位/配置/token/开局载荷）
#    actions.bin   权威动作（一条一个 store_var 记录，append + flush）
#    snapshot.bin  状态快照（可选，加速恢复）
#    result.bin    终局/结束原因
# ============================================================================
class_name FxqRoomStore
extends RefCounted

const ROOT := "user://rooms"
const UNFINISHED_WINDOW_MS := 10 * 60 * 1000     # 恢复窗口 10 分钟

func room_dir(room_id: String) -> String:
	return "%s/%s" % [ROOT, room_id]

func _ensure_dir(room_id: String) -> bool:
	return DirAccess.make_dir_recursive_absolute(room_dir(room_id)) == OK

static func _write_var(path: String, v) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null: return false
	f.store_var(v)
	f.close()
	return true

static func _read_var(path: String):
	if not FileAccess.file_exists(path): return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return null
	if f.get_length() <= 0:
		f.close()
		return null
	var v = f.get_var()
	f.close()
	return v

func save_meta(room_id: String, meta: Dictionary) -> bool:
	if not _ensure_dir(room_id): return false
	var m: Dictionary = meta.duplicate(true)
	m["roomId"] = room_id
	m["savedAt"] = int(Time.get_unix_time_from_system())
	return _write_var(room_dir(room_id) + "/meta.bin", m)

func load_meta(room_id: String) -> Dictionary:
	var v = _read_var(room_dir(room_id) + "/meta.bin")
	return v if v is Dictionary else {}

## 列出未完成的房间（meta 存在、phase != closed、savedAt 在窗口内）
func list_unfinished(now_unix: int = 0) -> Array:
	var now := now_unix if now_unix > 0 else int(Time.get_unix_time_from_system())
	var out := []
	var dir := DirAccess.open(ROOT)
	if dir == null: return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and not name.begins_with("."):
			var meta := load_meta(name)
			if not meta.is_empty() and str(meta.get("phase", "")) != "closed":
				var age: int = (now - int(meta.get("savedAt", 0))) * 1000
				if age <= UNFINISHED_WINDOW_MS:
					meta["roomId"] = name
					meta["ageMs"] = age
					out.append(meta)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort_custom(func(a, b): return int(a.get("savedAt", 0)) > int(b.get("savedAt", 0)))
	return out

## 追加一条权威动作（append + flush：强杀最多丢最后一条不完整记录）
func append_action(room_id: String, rec: Dictionary) -> bool:
	if not _ensure_dir(room_id): return false
	var path: String = room_dir(room_id) + "/actions.bin"
	var f: FileAccess = null
	if FileAccess.file_exists(path):
		f = FileAccess.open(path, FileAccess.READ_WRITE)
		if f != null: f.seek_end()
	else:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null: return false
	f.store_var(rec)
	f.flush()
	f.close()
	return true

## 读取动作日志。末尾不完整记录（写入被强杀截断）会被丢弃
func load_actions(room_id: String) -> Array:
	var out := []
	var path: String = room_dir(room_id) + "/actions.bin"
	if not FileAccess.file_exists(path): return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return out
	var total := f.get_length()
	while f.get_position() < total:
		var v = f.get_var()
		if v is Dictionary:
			out.append(v)
		else:
			break              # 半条记录：丢弃剩余
	f.close()
	return out

func save_snapshot(room_id: String, snap: Dictionary) -> bool:
	if not _ensure_dir(room_id): return false
	return _write_var(room_dir(room_id) + "/snapshot.bin", snap)

func load_snapshot(room_id: String) -> Dictionary:
	var v = _read_var(room_dir(room_id) + "/snapshot.bin")
	return v if v is Dictionary else {}

func save_result(room_id: String, res: Dictionary) -> bool:
	if not _ensure_dir(room_id): return false
	var r: Dictionary = res.duplicate(true)
	r["savedAt"] = int(Time.get_unix_time_from_system())
	return _write_var(room_dir(room_id) + "/result.bin", r)

func mark_closed(room_id: String) -> void:
	var meta := load_meta(room_id)
	if meta.is_empty(): return
	meta["phase"] = "closed"
	save_meta(room_id, meta)

func reset_room(room_id: String) -> void:
	for f in ["/meta.bin", "/actions.bin", "/snapshot.bin", "/result.bin",
			"/meta.json", "/actions.jsonl", "/snapshot.json", "/result.json"]:
		var p: String = room_dir(room_id) + str(f)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

## 清理：只保留最近 keep 个房间目录
func cleanup(keep: int = 5) -> void:
	var dir := DirAccess.open(ROOT)
	if dir == null: return
	var names := []
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if dir.current_is_dir() and not n.begins_with("."): names.append(n)
		n = dir.get_next()
	dir.list_dir_end()
	if names.size() <= keep: return
	names.sort()
	for i in range(0, names.size() - keep):
		var sub := DirAccess.open(room_dir(names[i]))
		if sub != null:
			sub.list_dir_begin()
			var f := sub.get_next()
			while f != "":
				if not sub.current_is_dir(): DirAccess.remove_absolute(room_dir(names[i]) + "/" + f)
				f = sub.get_next()
			sub.list_dir_end()
		DirAccess.remove_absolute(room_dir(names[i]))
