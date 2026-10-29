# ============================================================================
#  局域网协议：消息类型 / 版本 / 编解码（M1）
#
#  【纪律】这一层只做「常量 + 打包/解包」，不含任何规则与房间语义。
#  载荷用 var_to_bytes(Dictionary)：保留 int 键与类型（JSON 会把 players/energy
#  的 int 键变成 String，状态往返即坏——见设计文档 §7.2）。
# ============================================================================
class_name FxqProtocol
extends RefCounted

## 协议结构版本：消息表/字段语义变化时 +1（同版本内只加字段、不删字段）
const VERSION := 1

## 端口：游戏会话（ENet/UDP）与局域网发现（UDP 广播）
const PORT := 7788
const DISCOVERY_PORT := 7789
const MAGIC := "FXQLAN"

## v1 最小消息集（设计文档 §7.1）
enum Msg {
	JOIN = 1,          # C->S 加入/重连（M2）
	JOIN_OK = 2,       # S->C 分配座位（M2）
	ROOM_STATE = 3,    # S->C 房间变化（M2）
	GAME_START = 4,    # S->C 开局（M2）
	INTENT = 5,        # C->S 意图
	APPLY = 6,         # S->C 权威动作 {seq, actor, action, hash}
	REJECT = 7,        # S->C 拒绝意图
	RESYNC = 8,        # C->S 请求补包 {lastSeq}
	SYNC = 9,          # S->C 补包 {fromSeq, actions[]}
	SEAT_STATE = 10,   # S->C 在线状态（M5）
	PING = 11,
	PONG = 12,
	GAME_OVER = 13,    # S->C 终局
	HOST_LEFT = 14,    # S->C 房主主动解散
	KICKED = 15,
	LEAVE = 16,
	PAUSE = 17,        # S->C 全桌暂停（M4/M5）
	RESUME = 18,       # S->C 恢复
	# ---- M2：房间与开局 ----
	SET_READY = 19,    # C->S 准备/取消
	SET_CONFIG = 20,   # C->S 请求改配置（仅房主本机生效，客户端会被拒）
	SET_SEAT = 21,     # C->S 请求改座位类型（同上）
	START_GAME = 22,   # C->S 请求开局（仅房主本机会真正触发；客户端被拒）
	# ---- 对局设置 / 任意玩家暂停（只追加，不删不改已有值）----
	PAUSE_REQ = 23,    # C->S 请求全桌暂停（任意玩家）
	RESUME_REQ = 24,   # C->S 请求恢复（任意玩家）
	SEAT_ASSIGNED = 25, # S->C 通知本人换座成功（setup 颜色认领；更新 local_seat）
	RESTART_REQ = 26,   # C->S 请求「再来一局」返回房间（主机裁决，并非解散）
	SET_AVATAR = 27,    # C->S 请求改头像编号（1..8；主机校验后广播 ROOM_STATE）
}

## 打包：{"v":VERSION, "k":kind, ...payload}
static func pack(kind: int, payload: Dictionary = {}) -> PackedByteArray:
	var m := {"v": VERSION, "k": kind}
	m.merge(payload, true)
	return var_to_bytes(m)

## 解包：返回 {} 表示非法/版本不符（调用方丢弃并记录，不 crash）
static func unpack(bytes: PackedByteArray) -> Dictionary:
	var v = bytes_to_var(bytes)
	if not (v is Dictionary): return {}
	var m: Dictionary = v
	if int(m.get("v", -1)) != VERSION: return {}
	if not m.has("k"): return {}
	return m

## 动作记录（主机广播 / 客户端回放）的基本校验。返回 "" 表示合法
static func check_action_record(rec: Dictionary) -> String:
	if not rec.has("seq") or not rec.has("actor") or not (rec.get("action", null) is Dictionary):
		return "动作记录缺字段"
	if int(rec.get("seq", 0)) <= 0: return "seq 非法"
	if int(rec.get("actor", 0)) <= 0: return "actor 非法"
	return ""