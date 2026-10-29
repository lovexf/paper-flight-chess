# ============================================================================
#  会话层（M1 传输 + M2 房间/开局）
#
#  【职责边界】排序、收发、序号、补包、房间消息路由；
#  不引用 FxqEngine、不读 st 的规则字段。规则永远只跑在 engine.gd。
# ============================================================================
class_name FxqSession
extends RefCounted

enum Role { OFFLINE, HOST, CLIENT }

# ---- 连接 / 传输 ----
signal connected()                                   # 客户端连上房主
signal disconnected()                                # 客户端与房主断开
signal connection_failed()                           # 客户端连接失败
signal peer_joined(net_id: int)
signal peer_left(net_id: int)
# ---- 对局动作流 ----
signal intent_received(peer_id: int, client_seq: int, actor: int, action: Dictionary)
signal apply_received(record: Dictionary)            # 客户端：收到一条权威动作
signal resync_requested(peer_id: int, from_seq: int) # 主机：某客户端请求补包
signal sync_received(from_seq: int, actions: Array)  # 客户端：收到补包
# ---- 房间（M2）----
signal join_ok(seat: int)                            # 客户端：已分配到座位
signal join_rejected(code: String, reason: String)
signal room_changed()
signal game_started(payload: Dictionary)             # 两端：开局（主机本机也发）
signal reject_received(client_seq: int, code: String, reason: String)
# ---- M5：暂停 / 断线 / 重连 ----
signal paused_changed()                              # 全桌暂停状态变化（UI 用）
signal peer_online_changed(seat: int, online: bool)  # 某座位在线状态变化
signal reconnect_progress(attempt: int)              # 客户端：正在重连（第 n 次）
signal host_left_received(reason: String)            # 客户端：房主解散房间（HOST_LEFT）

var transport: FxqTransportENet = null
var role := Role.OFFLINE
var local_seat := 0
var local_nickname := "玩家"
var local_avatar := 1        # 本机头像编号 1..8（房间页选头像；不随 _reset 清掉，重连/换房间沿用）
var requested_seat := 0

var net_seq := 0            # 客户端：已收到的最后 seq；主机：已广播的最后一个 seq
var host_actions: Array = []   # 主机：整局动作记录（补包/录像用）
var pending: Array = []        # 客户端：已收未提交的动作记录（M3 接帧队列）
var client_seq := 0            # 客户端：本地意图序号

# ---- 房间（M2）----
var lobby: FxqLobby = null
var room_id := ""
var last_game_start := {}

# ---- M5：心跳 / 暂停 / 重连 / 持久化 ----
var paused := false
var pause_reason := ""            # offline | timeout | manual
var pause_by := 0                 # 发起暂停的座位（0 = 系统/房主本机未指定）
var pause_by_nick := ""           # 发起暂停者昵称（UI 显示用）
var waiting_seats: Array = []     # 暂停时在等谁
var session_token := ""           # 本机座位 token（重连回原座位）
var join_last_seq := 0            # 客户端重连时上报的已应用 seq
var heartbeat_interval := 3.0
var timeout_s := 15.0
var retry_interval := 2.0
var reconnect_window_s := 600.0
var store: FxqRoomStore = null    # 主机：动作日志持久化（可空）
var match_seed := 0
var seat_tokens := {}             # 主机：seat -> token（重连认领座位）
var peer_last_seen := {}          # 主机：peer_id -> 最后收到 ping 的 ms
var peer_seat_of := {}            # 主机：peer_id -> seat
var reconnecting := false
var reconnect_attempts := 0
# ---- 房主解散房间（客户端状态）----
var host_left := false            # 收到 HOST_LEFT：本房间已不复存在
var host_left_reason := ""
var host_left_by := ""            # 解散者昵称（HOST_LEFT.by，UI 提示用）
var _hb_t := 0.0
var _retry_t := 0.0
var _disc_t := 0.0
var _last_ip := ""
var _last_port := 0
var _join_room_id := ""
var _join_token := ""
var _join_last_seq := 0
var _host_alive := true
var host_port := 0
var _closing_transport: FxqTransportENet = null   # host_close_room 宽限期内待真正关闭的传输

# ---------------------------------------------------------------- 生命周期
func host(port: int = FxqProtocol.PORT) -> Error:
	_reset()
	var tr := FxqTransportENet.new()
	tr.peer_joined.connect(func(id: int) -> void: peer_joined.emit(id))
	tr.peer_left.connect(_on_peer_left)
	tr.message_received.connect(_on_message)
	transport = tr
	var err := tr.host(port)
	if err != OK:
		transport = null
		return err
	role = Role.HOST
	host_port = port
	return OK

func join(ip: String, port: int = FxqProtocol.PORT, nickname: String = "玩家", seat: int = 0,
		room_id_in: String = "", token_in: String = "", last_seq_in: int = 0) -> Error:
	_reset()
	local_nickname = nickname
	requested_seat = seat
	_join_room_id = room_id_in
	_join_token = token_in
	_join_last_seq = last_seq_in
	_last_ip = ip
	_last_port = port
	_host_alive = true
	var tr := FxqTransportENet.new()
	tr.connected_to_host.connect(_on_connected)
	tr.connection_failed.connect(func() -> void: connection_failed.emit())
	tr.host_disconnected.connect(func() -> void: disconnected.emit())
	tr.message_received.connect(_on_message)
	transport = tr
	var err := tr.join(ip, port)
	if err != OK:
		transport = null
		return err
	role = Role.CLIENT
	return OK

func poll() -> void:
	if transport != null: transport.poll()

func is_host() -> bool: return role == Role.HOST
func is_client() -> bool: return role == Role.CLIENT

func close() -> void:
	reconnecting = false
	if _closing_transport != null and transport == _closing_transport:
		# 房主解散房间的宽限期还没结束（HOST_LEFT 可能还没到对端）：
		# 只做逻辑关闭，真正的传输关闭交给 host_close_room 里的定时器。
		role = Role.OFFLINE
		return
	if transport != null: transport.close()
	transport = null
	role = Role.OFFLINE

func _reset() -> void:
	role = Role.OFFLINE
	net_seq = 0
	local_seat = 0
	requested_seat = 0
	client_seq = 0
	host_actions = []
	pending = []
	lobby = null
	room_id = ""
	last_game_start = {}
	host_left = false
	host_left_reason = ""
	host_left_by = ""
	pause_by = 0
	pause_by_nick = ""
	_closing_transport = null

func set_nickname(n: String) -> void:
	if n.strip_edges() != "": local_nickname = n.strip_edges()

## 设置本机头像编号（自动收敛 1..8）。
## HOST：更新自己座位并广播 ROOM_STATE；CLIENT：发 SET_AVATAR 请求（由主机裁决后广播）
func set_local_avatar(a: int) -> void:
	local_avatar = FxqLobby.clamp_avatar(a)
	if role == Role.HOST:
		if lobby == null: return
		var s := int(local_seat)
		if s <= 0: s = int(lobby.host_seat)
		if s <= 0: return
		local_seat = s
		if not lobby.set_avatar(s, local_avatar): return
		host_broadcast_room()
		room_changed.emit()
	elif role == Role.CLIENT:
		if transport == null: return
		transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.SET_AVATAR,
			{"avatar": local_avatar})

# ---------------------------------------------------------------- M5：心跳 / 暂停 / 重连
## 每帧调用（由 UI 的 _tick_net / 测试驱动）；负责心跳、超时判定、重连尝试
func tick(delta: float) -> void:
	if role == Role.OFFLINE: return
	if role == Role.HOST:
		_tick_host_timeouts()
		return
	# ---- 客户端：心跳 + 无响应判定 + 重连 ----
	_hb_t += delta
	if _hb_t >= heartbeat_interval:
		_hb_t = 0.0
		if transport != null and transport.is_connected_to_host():
			transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.PING,
				{"t": Time.get_ticks_msec(), "lastSeq": net_seq})
		elif transport == null and _host_alive:
			_host_alive = false
			disconnected.emit()
			_begin_reconnect()
	if _host_alive and _hb_t > timeout_s:
		_host_alive = false
		disconnected.emit()
		_begin_reconnect()
	if reconnecting:
		_retry_t += delta
		if _retry_t >= retry_interval:
			_retry_t = 0.0
			_attempt_reconnect()

func _tick_host_timeouts() -> void:
	# 超时判定：某 peer 超过 timeout_s 没 ping -> 标离线 + 全桌暂停
	var now := Time.get_ticks_msec()
	for pid in peer_last_seen.keys().duplicate():
		if now - int(peer_last_seen[pid]) <= int(timeout_s * 1000.0): continue
		peer_last_seen.erase(pid)
		var seat := int(peer_seat_of.get(pid, 0))
		if seat > 0 and lobby != null and lobby.seats.has(seat) and bool(lobby.seats[seat].online):
			lobby.seats[seat]["online"] = false
			peer_online_changed.emit(seat, false)
			host_broadcast_room()
			host_pause("offline", [seat])

## 主机：全桌暂停。reason: offline / timeout / manual；by_seat = 发起者座位（0=系统）
func host_pause(reason: String, waits: Array = [], by_seat: int = 0) -> void:
	if role != Role.HOST: return
	if paused:
		for s in waits:
			if not waiting_seats.has(int(s)): waiting_seats.append(int(s))
		return
	paused = true
	pause_reason = reason
	pause_by = int(by_seat)
	pause_by_nick = lobby.seat_nickname(pause_by) if lobby != null else ""
	waiting_seats = []
	for s in waits: waiting_seats.append(int(s))
	if transport != null:
		transport.broadcast(FxqProtocol.Msg.PAUSE, {
			"reason": pause_reason, "waitingSeats": waiting_seats,
			"by": pause_by, "byNick": pause_by_nick,
			"sinceMs": Time.get_ticks_msec()})
	paused_changed.emit()

## 主机：恢复全桌
func host_resume() -> void:
	if role != Role.HOST or not paused: return
	paused = false
	pause_reason = ""
	pause_by = 0
	pause_by_nick = ""
	waiting_seats = []
	if transport != null:
		transport.broadcast(FxqProtocol.Msg.RESUME, {"countdownMs": 3000})
	paused_changed.emit()

## 主机：oiifline 暂停在全员回来后自动恢复
func _check_auto_resume() -> void:
	if role != Role.HOST or lobby == null or not paused: return
	if pause_reason != "offline": return
	for s in lobby.order():
		var k := str(lobby.seats[s].kind)
		if (k == "local" or k == "remote") and not bool(lobby.seats[s].online):
			return
	host_resume()

func _seat_of_token(tok: String) -> int:
	if tok == "": return 0
	for s in seat_tokens.keys():
		if str(seat_tokens[s]) == tok: return int(s)
	return 0

func _begin_reconnect() -> void:
	if role != Role.CLIENT or _join_room_id == "": return
	if reconnecting: return
	reconnecting = true
	reconnect_attempts = 0
	_retry_t = 0.0
	reconnect_progress.emit(0)

func _attempt_reconnect() -> void:
	if transport != null:
		transport.close()
		transport = null
	var tr := FxqTransportENet.new()
	tr.connected_to_host.connect(_on_connected)
	tr.message_received.connect(_on_message)
	transport = tr
	_join_last_seq = net_seq
	if int(tr.join(_last_ip, _last_port)) != OK:
		transport = null

# ---------------------------------------------------------------- 主机侧：房间
func host_attach_lobby(l: FxqLobby) -> void:
	lobby = l
	if room_id == "":
		room_id = "%08x" % (randi() & 0xFFFFFFFF)
	if int(lobby.host_seat) == 0:
		lobby.host_take_seat(1, local_nickname, 1, local_avatar)
	else:
		# 重新挂接已有大厅：头像以大厅里房主座位为准回填本机字段
		local_avatar = lobby.seat_avatar(int(lobby.host_seat))
	# 主机自己的座位也要写回 local_seat（否则房间页会显示「座位 0」、桥接层 fallback）
	local_seat = int(lobby.host_seat)

func host_broadcast_room() -> void:
	if role != Role.HOST or lobby == null or transport == null: return
	transport.broadcast(FxqProtocol.Msg.ROOM_STATE, lobby.to_state())

func host_set_config(cfg: Dictionary) -> bool:
	if role != Role.HOST or lobby == null: return false
	if not lobby.set_config(cfg): return false
	host_broadcast_room()
	room_changed.emit()
	return true

func host_set_seat(seat: int, kind: String) -> bool:
	if role != Role.HOST or lobby == null: return false
	if not lobby.set_kind(seat, kind): return false
	host_broadcast_room()
	room_changed.emit()
	return true

# ---------------------------------------------------------------- 对局设置（setup）
## 房主：进入对局设置（至少 2 个座位；UI 的「开始」按钮先走这里）
func host_begin_setup() -> bool:
	if role != Role.HOST or lobby == null: return false
	if not lobby.begin_setup(): return false
	host_broadcast_room()
	room_changed.emit()
	return true

## 房主：取消对局设置，回到大厅
func host_cancel_setup() -> bool:
	if role != Role.HOST or lobby == null: return false
	if not lobby.cancel_setup(): return false
	host_broadcast_room()
	room_changed.emit()
	return true

## 房主：把自己的颜色从当前座位换到目标空闲座位（仅 setup 阶段）
func host_claim_seat(seat: int) -> bool:
	if role != Role.HOST or lobby == null: return false
	var from_seat := int(lobby.host_seat)
	if not lobby.move_player(from_seat, int(seat)): return false
	local_seat = int(lobby.host_seat)
	host_broadcast_room()
	room_changed.emit()
	return true

## 房主本机开局：校验通过后广播 GAME_START，并给本机发同样的信号
## 允许 lobby / setup 两个阶段（setup 里点「开始对局」直接开局）
func host_begin_game() -> bool:
	if role != Role.HOST or lobby == null or transport == null: return false
	if not (lobby.phase in ["lobby", "setup"]) or not lobby.can_start(): return false
	var payload: Dictionary = lobby.game_start_payload()
	payload["roomId"] = room_id
	payload["matchSeed"] = randi() & 0x7FFFFFFF
	lobby.phase = "playing"
	last_game_start = payload
	if store != null:
		store.save_meta(room_id, {
			"phase": "playing", "hostSeat": lobby.host_seat,
			"config": lobby.config.duplicate(true),
			"roomState": lobby.to_state(),
			"startPayload": payload,
			"protoVer": FxqProtocol.VERSION, "engineVer": 1, "boardHash": "",
			"matchSeed": payload.get("matchSeed", 0),
			"port": host_port,
			"seatTokens": seat_tokens.duplicate(),
		})
	transport.broadcast(FxqProtocol.Msg.GAME_START, payload)
	host_broadcast_room()
	game_started.emit(payload)
	return true

func host_kick(seat: int, reason: String = "被房主移出") -> void:
	if role != Role.HOST or lobby == null or transport == null: return
	var peer_id := 0
	for s in FxqLobby.SEATS:
		if int(s) == int(seat): peer_id = int(lobby.seats[s].peer_id)
	if peer_id <= 0: return
	transport.send_to(peer_id, FxqProtocol.Msg.KICKED, {"reason": reason})
	lobby.leave_peer(peer_id)
	host_broadcast_room()
	room_changed.emit()

## 房主解散房间：先广播 HOST_LEFT（带上解散原因/房主昵称），再关闭会话。
## ★ 不能「广播完立刻断 ENet」：对端在还没 poll 到可靠包时先收到断开事件，
##   HOST_LEFT 会被丢掉（本地回环实测必现）。所以逻辑角色立即置 OFFLINE，
##   传输层推迟 ~0.35s 再真正关闭，保证提示消息先送达客户端。
## 房主：本局结束/点「再来一局」→ 回房间大厅（房间保留，不广播 HOST_LEFT）
func host_return_lobby() -> bool:
	if role != Role.HOST or lobby == null: return false
	if str(lobby.phase) != "playing" and str(lobby.phase) != "result": return false
	paused = false
	pause_reason = ""
	pause_by = 0
	pause_by_nick = ""
	waiting_seats = []
	reconnecting = false
	lobby.phase = "lobby"
	# 客户端重新准备；房主保持已准备（房主没有「准备」按钮，否则会卡住无法再开局）
	for s in lobby.seats.keys():
		var k := str(lobby.seats[s].kind)
		if k == "remote":
			lobby.seats[s]["ready"] = false
	host_broadcast_room()
	paused_changed.emit()
	room_changed.emit()
	return true

## 客户端：请求「再来一局」回房间（由 host_return_lobby 裁决）
func request_return_lobby() -> void:
	if role != Role.CLIENT or transport == null: return
	transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.RESTART_REQ, {})

func host_close_room(reason: String = "closed") -> void:
	if role != Role.HOST: return
	var tr := transport
	if tr == null:
		close()
		return
	tr.broadcast(FxqProtocol.Msg.HOST_LEFT, {"reason": reason, "by": local_nickname})
	tr.poll()
	role = Role.OFFLINE
	host_port = 0
	_closing_transport = tr
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var tmr: SceneTreeTimer = (loop as SceneTree).create_timer(0.35, true)
		tmr.timeout.connect(func() -> void:
			tr.close()                       # 宽限期结束：真正断开（幂等）
			if transport == tr: transport = null
			if _closing_transport == tr: _closing_transport = null)
	else:
		tr.close()
		transport = null
		_closing_transport = null

# ---------------------------------------------------------------- 客户端侧：房间
func set_ready(v: bool) -> void:
	if role != Role.CLIENT or transport == null: return
	transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.SET_READY, {"ready": v})

func request_config(cfg: Dictionary) -> void:
	if role != Role.CLIENT or transport == null: return
	transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.SET_CONFIG, {"config": cfg})

func request_seat(seat: int, kind: String) -> void:
	if role != Role.CLIENT or transport == null: return
	transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.SET_SEAT,
		{"seat": seat, "kind": kind})

## 客户端：请求换颜色（颜色=座位号；仅 setup 阶段主机接受）
func request_claim_seat(seat: int) -> void:
	if role != Role.CLIENT or transport == null: return
	transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.SET_SEAT,
		{"seat": int(seat), "kind": "claim"})

func request_start() -> void:
	if role != Role.CLIENT or transport == null: return
	transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.START_GAME, {})

## 客户端：请求暂停 / 恢复（任意玩家都能发起，主机裁决）
func request_pause() -> void:
	if role != Role.CLIENT or transport == null: return
	transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.PAUSE_REQ, {})

func request_resume() -> void:
	if role != Role.CLIENT or transport == null: return
	transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.RESUME_REQ, {})

# ---------------------------------------------------------------- 主机侧：动作流
func broadcast_apply(record: Dictionary) -> void:
	if role != Role.HOST: return
	host_actions.append(record)
	net_seq = int(record.get("seq", net_seq))
	if store != null:
		store.append_action(room_id, record)
	if transport != null:
		transport.broadcast(FxqProtocol.Msg.APPLY, record)

func serve_resync(peer_id: int, from_seq: int) -> void:
	if role != Role.HOST or transport == null: return
	var out: Array = []
	for rec in host_actions:
		if int(rec.get("seq", 0)) >= from_seq: out.append(rec)
	transport.send_to(peer_id, FxqProtocol.Msg.SYNC, {"fromSeq": from_seq, "actions": out})

func send_reject(peer_id: int, seq: int, code: String, reason: String) -> void:
	if transport != null:
		transport.send_to(peer_id, FxqProtocol.Msg.REJECT,
			{"clientSeq": seq, "code": code, "reason": reason})

# ---------------------------------------------------------------- 客户端侧：动作流
func send_intent(actor: int, action: Dictionary) -> int:
	if role != Role.CLIENT or transport == null: return 0
	client_seq += 1
	transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.INTENT,
		{"clientSeq": client_seq, "actor": actor, "action": action})
	return client_seq

func request_resync() -> void:
	if role != Role.CLIENT or transport == null: return
	transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.RESYNC, {"lastSeq": net_seq})

func take_pending() -> Dictionary:
	if pending.is_empty(): return {}
	return pending.pop_front()

# ---------------------------------------------------------------- 内部回调
## 客户端：用主机下发的座位数据回填本机头像（重连/换座后保持一致；自己的座位空闲则不动）
func _sync_local_avatar_from_lobby() -> void:
	if lobby == null or int(local_seat) <= 0: return
	if not lobby.seats.has(int(local_seat)): return
	if str(lobby.seats[int(local_seat)]["kind"]) == "idle": return
	local_avatar = lobby.seat_avatar(int(local_seat))

func _on_connected() -> void:
	connected.emit()
	if transport != null:
		transport.send_to(MultiplayerPeer.TARGET_PEER_SERVER, FxqProtocol.Msg.JOIN,
			{"nickname": local_nickname, "avatar": local_avatar,
			"protoVer": FxqProtocol.VERSION,
			"requestedSeat": requested_seat, "roomId": _join_room_id,
			"sessionToken": _join_token, "lastSeq": _join_last_seq})

func _on_peer_left(net_id: int) -> void:
	peer_left.emit(net_id)
	if role != Role.HOST or lobby == null: return
	var seat := int(peer_seat_of.get(net_id, lobby.seat_of_peer(net_id)))
	peer_seat_of.erase(net_id)
	peer_last_seen.erase(net_id)
	if lobby.phase == "playing":
		# 对局中：不踢座位（保留 token 供重连），标离线并触发全桌暂停
		if seat > 0 and lobby.seats.has(seat):
			lobby.seats[seat]["online"] = false
			peer_online_changed.emit(seat, false)
			host_pause("offline", [seat])
		host_broadcast_room()
		room_changed.emit()
	else:
		lobby.leave_peer(net_id)
		host_broadcast_room()
		room_changed.emit()

func _on_message(net_id: int, msg: Dictionary) -> void:
	var kind := int(msg.get("k", 0))
	match kind:
		# ---------------------------------------------------- 房间（M2）
		FxqProtocol.Msg.JOIN:
			if role != Role.HOST: return
			if int(msg.get("protoVer", -1)) != FxqProtocol.VERSION:
				transport.send_to(net_id, FxqProtocol.Msg.JOIN_OK,
					{"ok": false, "code": "VERSION_MISMATCH", "reason": "版本不一致"})
				return
			var nick := str(msg.get("nickname", "玩家"))
			if lobby == null:
				# raw 模式（M1 兼容：未挂大厅，仅回座位 0）
				transport.send_to(net_id, FxqProtocol.Msg.JOIN_OK, {"ok": true, "seat": 0})
				return
			# M5：带 sessionToken 的重连 -> 认领原座位（不重新分配）
			var tok := str(msg.get("sessionToken", ""))
			var resumed := false
			var seat := _seat_of_token(tok)
			if seat > 0:
				resumed = true
				lobby.rebind_peer(seat, net_id, nick)
				peer_seat_of[net_id] = seat
				peer_last_seen[net_id] = Time.get_ticks_msec()
				peer_online_changed.emit(seat, true)
				_check_auto_resume()
			else:
				seat = lobby.apply_join(net_id, nick, int(msg.get("requestedSeat", 0)),
					int(msg.get("avatar", FxqLobby.AVATAR_DEFAULT)))
				if seat == 0:
					transport.send_to(net_id, FxqProtocol.Msg.JOIN_OK,
						{"ok": false, "code": "ROOM_FULL", "reason": "房间已满"})
					return
				tok = "%08x" % (randi() & 0xFFFFFFFF)
				seat_tokens[seat] = tok
				peer_seat_of[net_id] = seat
				peer_last_seen[net_id] = Time.get_ticks_msec()
			transport.send_to(net_id, FxqProtocol.Msg.JOIN_OK, {
				"ok": true, "seat": seat, "avatar": lobby.seat_avatar(seat),
				"roomId": room_id, "token": tok,
				"hostSeat": lobby.host_seat, "roomState": lobby.to_state(),
				"resumed": resumed, "lastSeq": net_seq,
				"paused": paused, "pauseReason": pause_reason,
				"pauseBy": pause_by, "pauseByNick": pause_by_nick,
				"waitingSeats": waiting_seats})
			host_broadcast_room()
			room_changed.emit()
		FxqProtocol.Msg.JOIN_OK:
			if role != Role.CLIENT: return
			if not bool(msg.get("ok", false)):
				join_rejected.emit(str(msg.get("code", "")), str(msg.get("reason", "")))
				return
			local_seat = int(msg.get("seat", 0))
			room_id = str(msg.get("roomId", room_id))
			session_token = str(msg.get("token", session_token))
			reconnecting = false
			reconnect_attempts = 0
			_host_alive = true
			paused = bool(msg.get("paused", false))
			pause_reason = str(msg.get("pauseReason", ""))
			pause_by = int(msg.get("pauseBy", 0))
			pause_by_nick = str(msg.get("pauseByNick", ""))
			waiting_seats = msg.get("waitingSeats", [])
			if msg.get("roomState", null) is Dictionary:
				if lobby == null: lobby = FxqLobby.new()
				lobby.apply_state(msg["roomState"])
				_sync_local_avatar_from_lobby()
			join_ok.emit(local_seat)
			room_changed.emit()
			paused_changed.emit()
			# 主机在断线期间可能又推进了动作：按 own net_seq 补包
			if int(msg.get("lastSeq", 0)) > net_seq:
				request_resync()
		FxqProtocol.Msg.ROOM_STATE:
			if role != Role.CLIENT: return
			if lobby == null: lobby = FxqLobby.new()
			lobby.apply_state({
				"seats": msg.get("seats", []), "config": msg.get("config", lobby.config),
				"phase": msg.get("phase", lobby.phase),
				"hostSeat": msg.get("hostSeat", lobby.host_seat)})
			_sync_local_avatar_from_lobby()
			room_changed.emit()
		FxqProtocol.Msg.SEAT_ASSIGNED:
			if role != Role.CLIENT: return
			local_seat = int(msg.get("seat", local_seat))
			if lobby == null: lobby = FxqLobby.new()
			if msg.get("roomState", null) is Dictionary:
				lobby.apply_state(msg["roomState"])
				_sync_local_avatar_from_lobby()
			room_changed.emit()
		FxqProtocol.Msg.SET_READY:
			if role != Role.HOST or lobby == null: return
			lobby.set_ready(net_id, bool(msg.get("ready", false)))
			host_broadcast_room()
			room_changed.emit()
		FxqProtocol.Msg.SET_SEAT:
			if role != Role.HOST or lobby == null: return
			# 房间（准备界面）/ setup 阶段：客户端认领空闲颜色（颜色=座位号）。复用 SET_SEAT 消息，kind="claim"。
			if (str(lobby.phase) == "setup" or str(lobby.phase) == "lobby") and str(msg.get("kind", "")) == "claim":
				var target := int(msg.get("seat", 0))
				var requester := int(lobby.seat_of_peer(net_id))
				if requester <= 0:
					send_reject(net_id, 0, "NO_SEAT", "你还没有座位")
					return
				if not (target in FxqLobby.SEATS) or str(lobby.seats[target]["kind"]) != "idle":
					send_reject(net_id, 0, "SEAT_TAKEN", "该颜色已被选择")
					return
				if not lobby.move_player(requester, target):
					send_reject(net_id, 0, "SEAT_TAKEN", "该颜色已被选择")
					return
				peer_seat_of[net_id] = target
				# 座位 token 跟着人走，断线重连才能回到新颜色
				var tok := ""
				if seat_tokens.has(requester):
					tok = str(seat_tokens[requester])
					seat_tokens.erase(requester)
				if tok == "": tok = "%08x" % (randi() & 0xFFFFFFFF)
				seat_tokens[target] = tok
				# 通知本人新座位（客户端 local_seat / UI 的「我的颜色」都靠它更新；
				# 不复用 JOIN_OK，避免 UI 误以为重新加入而重绑 bridge）
				transport.send_to(net_id, FxqProtocol.Msg.SEAT_ASSIGNED, {
					"seat": target, "roomId": room_id,
					"hostSeat": lobby.host_seat, "roomState": lobby.to_state()})
				host_broadcast_room()
				room_changed.emit()
				return
			send_reject(net_id, 0, "HOST_ONLY", "只有房主可以修改设置/开始游戏")
		FxqProtocol.Msg.SET_AVATAR:
			if role != Role.HOST or lobby == null: return
			var pseat := int(lobby.seat_of_peer(net_id))
			if pseat <= 0:
				send_reject(net_id, 0, "NO_SEAT", "你还没有座位")
				return
			var av := int(msg.get("avatar", 0))
			if av < FxqLobby.AVATAR_MIN or av > FxqLobby.AVATAR_MAX:
				send_reject(net_id, 0, "BAD_AVATAR", "头像编号必须是 %d..%d" % [FxqLobby.AVATAR_MIN, FxqLobby.AVATAR_MAX])
				return
			if int(lobby.seats[pseat].get("avatar", 0)) == av: return
			lobby.set_avatar(pseat, av)
			host_broadcast_room()
			room_changed.emit()
		FxqProtocol.Msg.SET_CONFIG, FxqProtocol.Msg.START_GAME:
			if role != Role.HOST: return
			send_reject(net_id, 0, "HOST_ONLY", "只有房主可以修改设置/开始游戏")
		FxqProtocol.Msg.GAME_START:
			if role != Role.CLIENT: return
			var payload: Dictionary = msg.duplicate(true)
			payload.erase("v")
			payload.erase("k")
			last_game_start = payload
			if lobby == null: lobby = FxqLobby.new()
			lobby.apply_state({
				"seats": payload.get("seats", []), "config": payload.get("config", lobby.config),
				"phase": "playing", "hostSeat": payload.get("hostSeat", lobby.host_seat)})
			_sync_local_avatar_from_lobby()
			game_started.emit(payload)
			room_changed.emit()
		FxqProtocol.Msg.REJECT:
			if role != Role.CLIENT: return
			reject_received.emit(int(msg.get("clientSeq", 0)),
				str(msg.get("code", "")), str(msg.get("reason", "")))
		# ---------------------------------------------------- M5：心跳 / 暂停
		FxqProtocol.Msg.PING:
			if role != Role.HOST: return
			peer_last_seen[net_id] = Time.get_ticks_msec()
			var pseat := int(peer_seat_of.get(net_id, 0))
			if pseat > 0 and lobby != null and lobby.seats.has(pseat) 					and not bool(lobby.seats[pseat].online):
				lobby.seats[pseat]["online"] = true
				peer_online_changed.emit(pseat, true)
				host_broadcast_room()
				_check_auto_resume()
			transport.send_to(net_id, FxqProtocol.Msg.PONG, {
				"t": msg.get("t", 0), "lastSeq": net_seq, "paused": paused})
		FxqProtocol.Msg.PONG:
			if role != Role.CLIENT: return
			_hb_t = 0.0
			_host_alive = true
			if reconnecting:
				reconnecting = false
				reconnect_attempts = 0
			var hp := bool(msg.get("paused", false))
			if hp != paused:
				paused = hp
				paused_changed.emit()
		FxqProtocol.Msg.PAUSE:
			if role != Role.CLIENT: return
			paused = true
			pause_reason = str(msg.get("reason", "offline"))
			pause_by = int(msg.get("by", 0))
			pause_by_nick = str(msg.get("byNick", ""))
			waiting_seats = msg.get("waitingSeats", [])
			paused_changed.emit()
		FxqProtocol.Msg.RESUME:
			if role != Role.CLIENT: return
			paused = false
			pause_reason = ""
			pause_by = 0
			pause_by_nick = ""
			waiting_seats = []
			paused_changed.emit()
		# ---- 任意玩家请求暂停/恢复（主机裁决）----
		FxqProtocol.Msg.PAUSE_REQ:
			if role != Role.HOST or lobby == null: return
			if str(lobby.phase) != "playing" or paused: return
			host_pause("manual", [], int(peer_seat_of.get(net_id, lobby.seat_of_peer(net_id))))
		FxqProtocol.Msg.RESUME_REQ:
			if role != Role.HOST: return
			if paused: host_resume()
		# ---- 任意玩家请求「再来一局」回房间（房间保留）----
		FxqProtocol.Msg.RESTART_REQ:
			if role != Role.HOST: return
			host_return_lobby()
		# ---- 房主解散房间 ----
		FxqProtocol.Msg.HOST_LEFT:
			if role != Role.CLIENT: return
			var left_reason := str(msg.get("reason", "closed"))
			host_left = true
			host_left_reason = left_reason
			host_left_by = str(msg.get("by", ""))
			paused = false
			reconnecting = false
			_host_alive = false
			if transport != null:
				transport.close()
				transport = null
			host_left_received.emit(left_reason)
			paused_changed.emit()
		FxqProtocol.Msg.SEAT_STATE:
			if role != Role.CLIENT: return
			var ss := int(msg.get("seat", 0))
			if lobby != null and lobby.seats.has(ss):
				lobby.seats[ss]["online"] = bool(msg.get("online", true))
			peer_online_changed.emit(ss, bool(msg.get("online", true)))
		# ---------------------------------------------------- 动作流（M1）
		FxqProtocol.Msg.APPLY:
			if role != Role.CLIENT: return
			var rec := msg.duplicate(true)
			rec.erase("v")
			rec.erase("k")
			var chk := FxqProtocol.check_action_record(rec)
			if chk != "":
				request_resync()
				return
			net_seq = int(rec.get("seq", net_seq))
			pending.append(rec)
			apply_received.emit(rec)
		FxqProtocol.Msg.INTENT:
			if role != Role.HOST: return
			intent_received.emit(net_id, int(msg.get("clientSeq", 0)),
				int(msg.get("actor", 0)), (msg.get("action", {}) as Dictionary))
		FxqProtocol.Msg.RESYNC:
			if role != Role.HOST: return
			resync_requested.emit(net_id, int(msg.get("lastSeq", 0)))
		FxqProtocol.Msg.SYNC:
			if role != Role.CLIENT: return
			sync_received.emit(int(msg.get("fromSeq", 0)), msg.get("actions", []))
		FxqProtocol.Msg.KICKED:
			if role != Role.CLIENT: return
			disconnected.emit()
		_:
			pass
