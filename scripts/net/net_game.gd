# ============================================================================
#  联机对局桥（M3）：把 FxqSession 的动作流接到 Main（flow_base）上
#
#  主机：intent -> 校验 -> _apply_authority（唯一权威）-> action_recorded -> 广播 APPLY
#  客户端：本地输入 -> intent；收到 APPLY -> _apply_remote（复算）-> 动画队列
#  单机完全不经过本文件（flow.net_mode 默认 false）。
# ============================================================================
class_name FxqNetGame
extends RefCounted

const LAG_FAST := 2                 # 积压 >= 2 批开始 2 倍速播放
const LAG_SKIP := 4                 # 积压 >= 4 批 -> 静默快进到最新
const FAST_FORWARD_AGE_MS := 2500   # 最旧批超过 2.5s -> 快进

var session: FxqSession = null
var flow: Control = null
var is_host := false
var local_seat := 0

# --- 客户端状态 ---
var awaiting_ack := false
var last_client_seq := 0
var last_reject := {}
var pending: Array = []          # 已收未应用的权威动作
var pending_ts: Array = []       # 与 pending 对齐的入队时间（ms）
var auto_pump := true            # 测试可关掉以模拟积压
var applied := 0                 # 已应用动作数
var fast_forwarded := 0          # 快进次数（诊断）
var errors: Array = []           # 复算/校验错误
var start_payload := {}

# ---------------------------------------------------------------- 绑定
func bind_host(s: FxqSession, f: Control) -> void:
	is_host = true
	session = s
	flow = f
	local_seat = int(session.local_seat)
	if local_seat <= 0: local_seat = 1
	flow.net_mode = true
	flow.net_is_host = true
	session.game_started.connect(_on_game_started)
	session.intent_received.connect(_on_intent)
	flow.action_recorded.connect(_on_action_recorded)

func bind_client(s: FxqSession, f: Control) -> void:
	is_host = false
	session = s
	flow = f
	local_seat = int(session.local_seat)
	flow.net_mode = true
	flow.net_is_host = false
	flow.intent_sender = Callable(self, "_on_local_intent")
	session.game_started.connect(_on_game_started)
	session.apply_received.connect(_on_apply)
	session.reject_received.connect(_on_reject)
	session.disconnected.connect(_on_disconnected)
	session.sync_received.connect(_on_sync)

# ---------------------------------------------------------------- 开局
func _on_game_started(payload: Dictionary) -> void:
	start_payload = payload
	apply_start_payload(payload)

## 把 GAME_START 载荷落到 Main 的配置字段并开一局。两端同一 config -> 同一初始 state_hash。
func apply_start_payload(payload: Dictionary) -> bool:
	if flow == null: return false
	var cfg: Dictionary = (payload.get("config", {}) as Dictionary)
	var order: Array = payload.get("order", [])
	var sm := {1: "none", 2: "none", 3: "none", 4: "none"}
	var remote: Array = []
	for e in payload.get("seats", []):
		if not (e is Dictionary): continue
		var s := int(e.get("seat", 0))
		if not sm.has(s): continue
		if not order.has(s):
			sm[s] = "none"
			continue
		var kind := str(e.get("kind", "idle"))
		if kind == "ai":
			sm[s] = "ai"
		else:
			sm[s] = "player"
			if int(s) != int(local_seat): remote.append(s)
	flow.seat_mode = sm
	flow.net_remote_seats = remote
	flow.happy_mode = bool(cfg.get("happy", false))
	flow.item_mode = bool(cfg.get("item", false))
	flow.launch_values = cfg.get("launchValues", [2, 4, 6])
	flow.init_energy = int(cfg.get("initEnergy", 0))
	flow.difficulty = "hard"
	# 本机只操控自己的座位（主机侧远端人类座位等 intent，见 _tick_turn）
	var my: Array = []
	if int(local_seat) > 0 and str(sm.get(int(local_seat), "none")) == "player":
		my = [int(local_seat)]
	flow.start_game()
	# ★ start_game() 会按 seat_mode 重算 humans（本机+远端都算 player）。
	#   联机语义是「本机只操控自己的座位」，所以开完局再收敛一次。
	flow.humans = my
	return true

# ---------------------------------------------------------------- 主机
func _on_action_recorded(record: Dictionary) -> void:
	if is_host and session != null:
		session.broadcast_apply(record)

func _on_intent(peer_id: int, client_seq: int, actor: int, action: Dictionary) -> void:
	if not is_host or flow == null: return
	# 0) 暂停门：暂停期间拒绝一切意图；唯一例外 —— 超时暂停中被等的人回来了，
	#    先解除暂停再处理他的动作（设计 §6.11 规则 4）
	if session != null and session.paused:
		var is_waited: bool = str(session.pause_reason) == "timeout" and (session.waiting_seats as Array).has(int(actor))
		if not is_waited:
			session.send_reject(peer_id, client_seq, "PAUSED", "本局已暂停")
			return
		session.host_resume()
	# 1) 座位归属（房主大厅存在时）
	if session.lobby != null and int(session.lobby.seat_of_peer(peer_id)) != int(actor):
		session.send_reject(peer_id, client_seq, "NOT_YOUR_SEAT", "座位不匹配")
		return
	# 2) 回合归属
	if int(flow.st.currentPlayer) != int(actor):
		session.send_reject(peer_id, client_seq, "NOT_YOUR_TURN", "还没轮到你")
		return
	# 3) 引擎裁决（阶段/合法性）；成功时 action_recorded 会自动广播
	var res: Dictionary = flow._apply_authority(int(actor), action)
	if not bool(res.get("ok", false)):
		session.send_reject(peer_id, client_seq, "ILLEGAL_ACTION", str(res.get("error", "")))

# ---------------------------------------------------------------- 客户端
func _on_local_intent(action: Dictionary) -> void:
	if flow == null or session == null: return
	if session.paused:
		# 唯一例外：timeout 暂停时，被等的人可以用一次操作把局面拉回来（主机那边先 resume 再处理）
		var me := int(session.local_seat)
		var waited: bool = str(session.pause_reason) == "timeout" and (session.waiting_seats as Array).has(me)
		if not waited: return
	awaiting_ack = true
	last_client_seq = session.send_intent(int(flow.st.currentPlayer), action)

func _on_apply(rec: Dictionary) -> void:
	pending.append(rec)
	pending_ts.append(Time.get_ticks_msec())
	if auto_pump: pump_client()

## M5：重连补包 —— 把主机日志里本地还缺的动作静默复算补齐
func _on_sync(from_seq: int, actions: Array) -> void:
	if is_host or flow == null: return
	for rec in actions:
		if not (rec is Dictionary): continue
		var rseq := int(rec.get("seq", 0))
		if rseq <= int(session.net_seq): continue
		var res: Dictionary = flow._apply_remote(rec, true)
		if bool(res.get("ok", false)):
			session.net_seq = rseq
			applied += 1
		else:
			errors.append(str(res.get("error", "")))
			break

func _on_reject(client_seq: int, code: String, reason: String) -> void:
	awaiting_ack = false
	last_reject = {"clientSeq": client_seq, "code": code, "reason": reason}

func _on_disconnected() -> void:
	awaiting_ack = false

## 客户端：按序应用已收动作；有积压则倍速播放或静默快进（主机从不等待客户端）
func pump_client() -> void:
	if is_host or flow == null: return
	if pending.is_empty():
		flow.anim_speed = 1.0
		return
	var now := Time.get_ticks_msec()
	if pending.size() >= LAG_SKIP or (now - int(pending_ts[0])) > FAST_FORWARD_AGE_MS:
		for rec in pending:
			flow._apply_remote(rec, true)
			applied += 1
		fast_forwarded += 1
		pending.clear()
		pending_ts.clear()
		flow.seq = []              # 丢弃积压动画，直接对齐到最新状态
		flow.anim_speed = 1.0
		return
	flow.anim_speed = 2.0 if pending.size() >= LAG_FAST else 1.0
	while not pending.is_empty() and flow.seq.is_empty():
		var rec: Dictionary = pending.pop_front()
		pending_ts.pop_front()
		var res: Dictionary = flow._apply_remote(rec, false)
		if bool(res.get("ok", false)):
			applied += 1
			awaiting_ack = false
		else:
			errors.append(str(res.get("error", "")))
			pending.clear()
			pending_ts.clear()
			break

## 让动画队列跑完（测试/无头环境用；真机由 _process 每帧推进）
func drain_anim(max_iters: int = 600) -> void:
	if flow == null: return
	var i := 0
	while not flow.seq.is_empty() and i < max_iters:
		flow._anim_step(0.6)
		i += 1

func is_synced(host_action_count: int) -> bool:
	return pending.is_empty() and applied >= host_action_count

# ---------------------------------------------------------------- M5：房主恢复
## 房主进程被杀后重启：加载 meta + actions，重建大厅与对局状态。
## 调用前提：session 已 host() 成功；flow 是新建的 Main（空白）。
func restore_host(sess: FxqSession, f: Control, store: FxqRoomStore, rid: String) -> bool:
	if sess == null or f == null or store == null: return false
	var meta := store.load_meta(rid)
	if meta.is_empty(): return false
	var actions := store.load_actions(rid)
	var room_state: Dictionary = meta.get("roomState", {})
	var lobby := FxqLobby.new()
	if not room_state.is_empty(): lobby.apply_state(room_state)
	lobby.phase = "playing"
	sess.lobby = lobby
	sess.room_id = rid
	sess.store = store
	sess.net_seq = 0
	var toks = meta.get("seatTokens", {})
	if toks is Dictionary:
		for k in toks.keys(): sess.seat_tokens[int(k)] = str(toks[k])
	session = sess
	flow = f
	is_host = true
	local_seat = int(lobby.host_seat)
	if local_seat <= 0: local_seat = 1
	flow.net_mode = true
	flow.net_is_host = true
	sess.game_started.connect(_on_game_started)
	sess.intent_received.connect(_on_intent)
	flow.action_recorded.connect(_on_action_recorded)
	var payload: Dictionary = meta.get("startPayload", {})
	if payload.is_empty(): return false
	apply_start_payload(payload)
	# 逐条静默复算到最后一个动作
	for rec in actions:
		if not (rec is Dictionary): continue
		var res: Dictionary = flow._apply_remote(rec, true)
		if not bool(res.get("ok", false)): return false
		sess.net_seq = int(rec.get("seq", sess.net_seq))
	sess.host_actions = actions.duplicate(true)
	sess.paused = true
	sess.pause_reason = "offline"
	return true