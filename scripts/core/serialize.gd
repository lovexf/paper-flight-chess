# ============================================================================
#  状态规范化 / 状态哈希 / 整状态快照（M0 动作回放的序列化层）
#
#  【职责】把对局状态压成【与 Dictionary 键序无关】的数组，供状态哈希与
#          回放/联机时的状态校验使用；以及整状态的二进制快照往返。
#          只读 state，不修改任何字段，不引入规则语义。
# ============================================================================
class_name FxqSerialize
extends RefCounted

# ---------------------------------------------------------------- 规范化
## 规范化状态：按 st.order 的顺序把玩家/能量展开成数组。
## players / energy 是 int 键的 Dictionary —— 直接 JSON 化会依赖键迭代顺序，
## 且 JSON 会把 int 键写成字符串；这里统一转数组，哈希只由玩家顺序决定。
static func canonical(st: Dictionary) -> Array:
	var out := []
	out.append(int(st.get("currentPlayer", 0)))
	out.append(int(st.get("currentIndex", 0)))
	out.append(str(st.get("phase", "")))
	out.append(st.get("dice", null))            # null 或 1..maxDice
	out.append(st.get("diceItem", false))       # false / true / 道具名字符串
	out.append(int(st.get("consecutiveSixes", 0)))
	out.append(int(st.get("turn", 0)))
	out.append(int(st.get("round", 1)))
	out.append(st.get("winner", null))          # null 或玩家号
	out.append(_ints(st.get("finishOrder", [])))
	out.append(bool(st.get("happy", false)))
	out.append(bool(st.get("skillMode", false)))
	out.append(_ints(st.get("launchValues", [2, 4, 6])))
	out.append(_pending(st.get("pendingItem", null)))
	out.append(_players(st))
	return out

## 玩家数组：严格按 st.order 展开（order 本身由此隐含在序列化结果里）
static func _players(st: Dictionary) -> Array:
	var out := []
	var order: Array = st.get("order", [])
	var players: Dictionary = st.get("players", {})
	var energy: Dictionary = st.get("energy", {})
	for pid_v in order:
		var pid: int = int(pid_v)
		if not players.has(pid):
			# 非法状态兜底：保留玩家号占位，避免不同缺口被压成同一个数组
			out.append([pid])
			continue
		var p: Dictionary = players[pid]
		var chesses := []
		for c in p.get("chesses", []):
			# 每颗棋子只认 pos/finished 两个影响规则与显示的量
			chesses.append([int(c.get("pos", -1)), bool(c.get("finished", false))])
		out.append([
			pid,
			chesses,
			int(p.get("totalDistance", 0)),
			int(p.get("defeats", 0)),
			int(energy.get(pid, 0)),
		])
	return out

## 待落地道具压成定长数组（Dictionary 键序不参与哈希）
static func _pending(p) -> Variant:
	if p == null: return null
	if typeof(p) != TYPE_DICTIONARY:
		return str(p)
	return [int(p.get("player", 0)), str(p.get("item", "")), int(p.get("cost", 0))]

## 整数数组：JSON 里统一成 int，避免 float/int 混写导致同值不同串
static func _ints(src) -> Array:
	var out := []
	for v in src:
		out.append(int(v))
	return out

# ---------------------------------------------------------------- 哈希
## 状态哈希：规范化数组 -> JSON -> sha256 前 16 位（64bit 截断，够回放校验/日志索引）
static func state_hash(st: Dictionary) -> String:
	return JSON.stringify(canonical(st)).sha256_text().substr(0, 16)

# ---------------------------------------------------------------- 快照
## 整状态二进制快照。用 var_to_bytes 而不是 JSON 的原因：
##   1) 无损保留 int 键（JSON 会把 Dictionary 的 int 键强制转成字符串，
##      往返后 players.has(1) 会变成 players.has("1")）；
##   2) 保留 bool / null / int 的类型，不做数字到 float 的隐式转换；
##   3) 嵌套 Dictionary 的键序原样保留，走子日志的块结构不用额外归一。
static func snapshot_to_bytes(st: Dictionary) -> PackedByteArray:
	return var_to_bytes(st)

## 快照还原。bytes 非法/截断时 bytes_to_var 会报错并返回 null，这里兜底为空字典。
static func snapshot_from_bytes(bytes: PackedByteArray) -> Dictionary:
	var v = bytes_to_var(bytes)
	if typeof(v) != TYPE_DICTIONARY:
		return {}
	return v
