# ============================================================================
#  房间大厅（M2）：座位 / 昵称 / ready / 配置 / 房主 / 开局条件
#
#  【职责边界】纯数据 + 规则判定（谁能开局、座位如何分配、配置合法性）。
#  不碰网络、不碰对局状态；网络消息由 session.gd 路由进来/出去。
# ============================================================================
class_name FxqLobby
extends RefCounted

const SEATS := [1, 2, 3, 4]
const KINDS := ["local", "remote", "ai", "idle"]
## 玩家头像编号范围（1..20；来自 web 版 emojis.js 的 20 个表情头像）
const AVATAR_MIN := 1
const AVATAR_MAX := 20
const AVATAR_DEFAULT := 1

var seats := {}          # seat -> {kind, peer_id, nickname, ready, online}
var config := {}
var phase := "lobby"     # lobby | setup | playing | result
var host_seat := 0

func _init() -> void:
	reset()

func reset() -> void:
	seats = {}
	for s in SEATS:
		seats[s] = _idle_seat(s)
	config = {"happy": false, "item": false, "launchValues": [2, 4, 6], "initEnergy": 0, "pieces": 4}
	phase = "lobby"
	host_seat = 0

func _idle_seat(s: int) -> Dictionary:
	return {"kind": "idle", "peer_id": 0, "nickname": "玩家%d" % s, "ready": false, "online": false,
		"avatar": AVATAR_DEFAULT}

# ---------------------------------------------------------------- 座位
## 房主占座（本机玩家）。peer_id 默认 1（ENet 服务端 id）；avatar 1..8（越界收敛）
func host_take_seat(seat: int, nickname: String, peer_id: int = 1, avatar: int = AVATAR_DEFAULT) -> void:
	host_seat = seat
	seats[seat] = {"kind": "local", "peer_id": peer_id, "nickname": nickname, "ready": true, "online": true,
		"avatar": clamp_avatar(avatar)}

func seat_of_peer(peer_id: int) -> int:
	for s in SEATS:
		if int(seats[s].peer_id) == peer_id and str(seats[s].kind) != "idle":
			return s
	return 0

func free_seat(preferred: int = 0) -> int:
	if int(preferred) in SEATS and str(seats[int(preferred)].kind) == "idle":
		return int(preferred)
	for s in SEATS:
		if str(seats[s].kind) == "idle":
			return s
	return 0

## 客户端加入：返回分配的座位号；0 = 房满/不可加入。avatar 1..8（越界收敛）
func apply_join(peer_id: int, nickname: String, preferred: int = 0, avatar: int = AVATAR_DEFAULT) -> int:
	if phase != "lobby": return 0
	var av := clamp_avatar(avatar)
	var existing := seat_of_peer(peer_id)
	if existing > 0:
		seats[existing]["online"] = true
		seats[existing]["nickname"] = nickname
		seats[existing]["avatar"] = av
		return existing
	var s := free_seat(preferred)
	if s == 0: return 0
	seats[s] = {"kind": "remote", "peer_id": peer_id, "nickname": nickname, "ready": false, "online": true,
		"avatar": av}
	return s

## 客户端离开 / 掉线
func leave_peer(peer_id: int) -> void:
	var s := seat_of_peer(peer_id)
	if s == 0: return
	if phase == "lobby" or phase == "setup":
		seats[s] = _idle_seat(s)
	else:
		seats[s]["online"] = false
		seats[s]["ready"] = false

## 房主改座位类型（ai / idle）。remote 只能由加入/离开产生；local 只有房主。
func set_kind(seat: int, kind: String) -> bool:
	if not (phase in ["lobby", "setup"]): return false
	if not (kind in KINDS): return false
	if int(seat) == int(host_seat): return false
	if kind == "local" or kind == "remote": return false
	if kind == "idle":
		seats[seat] = _idle_seat(seat)     # 空闲位头像重置为默认 1
	else:
		# AI 头像按座位号区分（1..4），避免多个 AI 顶同一张脸
		seats[seat] = {"kind": "ai", "peer_id": 0, "nickname": "电脑", "ready": true, "online": true,
			"avatar": clamp_avatar(seat)}
	return true

## M5：客户端断线重连后把原座位重新绑到新 peer_id（保留昵称/ready）
func rebind_peer(seat: int, peer_id: int, nickname: String = "") -> bool:
	if not seats.has(seat): return false
	if str(seats[seat].kind) != "remote": return false
	seats[seat]["peer_id"] = peer_id
	seats[seat]["online"] = true
	seats[seat]["ready"] = true          # 重连不打断准备状态
	if nickname != "": seats[seat]["nickname"] = nickname
	# 头像不随重连重置：保留原座位选好的头像（旧存档缺字段时补默认值）
	if not seats[seat].has("avatar"): seats[seat]["avatar"] = AVATAR_DEFAULT
	return true

func set_ready(peer_id: int, ready: bool) -> bool:
	if not (phase in ["lobby", "setup"]): return false
	var s := seat_of_peer(peer_id)
	if s == 0: return false
	seats[s]["ready"] = ready
	return true

## 房主改配置。只接受已知字段并做合法性收敛（客户端不能改，见 session）
func set_config(cfg: Dictionary) -> bool:
	if not (phase in ["lobby", "setup"]): return false
	if not (cfg is Dictionary): return false
	if cfg.has("happy"): config["happy"] = bool(cfg["happy"])
	if cfg.has("item"): config["item"] = bool(cfg["item"])
	if cfg.has("launchValues"):
		var lv := []
		for v in cfg["launchValues"]:
			var n := int(v)
			if n >= 1 and n <= 6 and not lv.has(n): lv.append(n)
		if lv.is_empty(): lv = [6]
		lv.sort()
		config["launchValues"] = lv
	if cfg.has("initEnergy"): config["initEnergy"] = clampi(int(cfg["initEnergy"]), 0, 100)
	if cfg.has("pieces"): config["pieces"] = clampi(int(cfg["pieces"]), 2, 4)
	return true

# ---------------------------------------------------------------- 对局设置（setup）
## 进入「对局设置」阶段：至少 2 个座位才允许（否则房主点开始无意义）
func begin_setup() -> bool:
	if phase != "lobby": return false
	if order().size() < 2: return false
	phase = "setup"
	return true

## 取消设置，回到大厅（准备/配置都保留）
func cancel_setup() -> bool:
	if phase != "setup": return false
	phase = "lobby"
	return true

## setup 阶段换颜色（颜色 = 座位 1..4）：from 必须是玩家座位（local/remote），
## to 必须是空闲座位。玩家数据整体搬到 to，from 变回 idle。
## 房主换座时同步 host_seat（座位号同时是引擎 order 里的 seat）。
func move_player(from_seat: int, to_seat: int) -> bool:
	if phase != "setup" and phase != "lobby": return false
	var f := int(from_seat)
	var t := int(to_seat)
	if not seats.has(f) or not seats.has(t): return false
	if f == t: return false
	var k := str(seats[f]["kind"])
	if k != "local" and k != "remote": return false
	if str(seats[t]["kind"]) != "idle": return false
	seats[t] = {
		"kind": k,
		"peer_id": int(seats[f]["peer_id"]),
		"nickname": str(seats[f]["nickname"]),
		"ready": bool(seats[f]["ready"]),
		"online": bool(seats[f]["online"]),
		"avatar": clamp_avatar(int(seats[f].get("avatar", AVATAR_DEFAULT))),
	}
	seats[f] = _idle_seat(f)
	if f == int(host_seat): host_seat = t
	return true

## 座位昵称（UI 显示用；无效座位返回 ""）
func seat_nickname(seat: int) -> String:
	if not seats.has(int(seat)): return ""
	return str(seats[int(seat)]["nickname"])

# ---------------------------------------------------------------- 头像
## 头像编号收敛到 1..8
static func clamp_avatar(a: int) -> int:
	return clampi(int(a), AVATAR_MIN, AVATAR_MAX)

## 座位当前头像（无效座位返回默认值 1）
func seat_avatar(seat: int) -> int:
	if not seats.has(int(seat)): return AVATAR_DEFAULT
	return clamp_avatar(int(seats[int(seat)].get("avatar", AVATAR_DEFAULT)))

## 主机：设置某座位头像（1..8 收敛）。座位不存在/空闲 -> false
func set_avatar(seat: int, avatar: int) -> bool:
	var s := int(seat)
	if not seats.has(s): return false
	if str(seats[s].kind) == "idle": return false
	seats[s]["avatar"] = clamp_avatar(avatar)
	return true

# ---------------------------------------------------------------- 开局
## 参与本局的座位（升序；= 引擎 st.order）
func order() -> Array:
	var out := []
	for s in SEATS:
		if str(seats[s]["kind"]) != "idle": out.append(s)
	return out

## 能开局：≥2 个座位，且所有真人座位（local/remote）已准备
func can_start() -> bool:
	var ord := order()
	if ord.size() < 2: return false
	for s in ord:
		var k := str(seats[s]["kind"])
		if (k == "local" or k == "remote") and not bool(seats[s]["ready"]):
			return false
	return true

func human_seats() -> Array:
	var out := []
	for s in SEATS:
		var k := str(seats[s]["kind"])
		if k == "local" or k == "remote": out.append(s)
	return out

## 发给网络/显示层的座位快照（不含 peer_id —— peer id 是主机侧连接概念）
func seats_payload() -> Array:
	var out := []
	for s in SEATS:
		out.append({
			"seat": s,
			"kind": str(seats[s]["kind"]),
			"nickname": str(seats[s]["nickname"]),
			"ready": bool(seats[s]["ready"]),
			"online": bool(seats[s]["online"]),
			"avatar": clamp_avatar(int(seats[s].get("avatar", AVATAR_DEFAULT))),
		})
	return out

func to_state() -> Dictionary:
	return {"seats": seats_payload(), "config": config.duplicate(true),
		"phase": phase, "hostSeat": host_seat}

## 客户端用主机下发的 room_state 覆盖本地视图
func apply_state(d: Dictionary) -> void:
	if d.get("seats", null) is Array:
		for e in d["seats"]:
			if not (e is Dictionary): continue
			var s := int(e.get("seat", 0))
			if not seats.has(s): continue
			seats[s] = {
				"kind": str(e.get("kind", "idle")),
				"peer_id": 0,
				"nickname": str(e.get("nickname", "玩家%d" % s)),
				"ready": bool(e.get("ready", false)),
				"online": bool(e.get("online", false)),
				"avatar": clamp_avatar(int(e.get("avatar", AVATAR_DEFAULT))),
			}
	if d.get("config", null) is Dictionary:
		config = (d["config"] as Dictionary).duplicate(true)
	phase = str(d.get("phase", phase))
	host_seat = int(d.get("hostSeat", host_seat))

## 开局消息载荷（主机 -> 全员）。客户端据此建初始状态（order/配置必须一致）
func game_start_payload() -> Dictionary:
	return {
		"config": config.duplicate(true),
		"order": order(),
		"seats": seats_payload(),
		"phase": "playing",
		"hostSeat": host_seat,
		"startSeq": 0,
	}
