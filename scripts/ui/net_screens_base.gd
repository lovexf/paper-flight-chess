# ============================================================================
#  联机界面（M4）：NET 页（创建/发现/加入）+ 房间页 + 对局顶部联机 HUD
#
#  继承链插入点：screens_base ← 【net_screens_base】 ← render_base ← ...（只加方法，不改旧逻辑）
#  - 只追加 Scr.NET，单机 SETUP 完全不动（实现取设计文档 D1 的「方案 B：独立 NET/ROOM 页」）
#  - 手工 hit-test：net_hits() 是唯一布局真相，_draw_net 与 _click_net 都从它取矩形
# ============================================================================
extends "res://scripts/ui/screens_base.gd"

const NET_PORT_BASE := 7788
const NET_PORT_TRIES := 5

# ---- 会话 / 房间 ----
var net_session: FxqSession = null
var net_lobby: FxqLobby = null
var net_bridge: FxqNetGame = null
var net_disc: FxqDiscovery = null
var net_role := ""              # "" | "host" | "client"
var net_page := "connect"       # connect | room
var net_nickname := ""
var net_local_seat := 0
var net_host_seat := 1
var net_port := 0
var net_room_id := ""
var net_status := ""
var net_status_t := 0.0
var net_overlay := ""           # "" | "connecting" | "error" | "disconnected"
var net_overlay_msg := ""
var net_rooms: Array = []
var net_store: FxqRoomStore = null
var net_pending_restore: Array = []
var net_manual_ip := ""
var net_kb_open := false
var net_nick_open := false        # 修改昵称弹窗
var net_avatar := 1               # 本机头像编号 1..8（user://net_avatar.txt 持久化）
var net_avatar_picker_open := false # 房间页头像选择弹窗
var _net_avatar_loaded := false
var _net_avatar_tex := {}         # 头像纹理缓存 1..8
var net_cfg_expand := false       # 房主「对局设置」手风琴是否展开（房间页内联，无弹窗）
var net_cfg_anim := 0.0             # 手风琴动画进度 0(收起)..1(展开)
var net_ready_anim := 0.0           # 房间主按钮（开始/准备）状态过渡
var net_sw_anim := {"happy": 0.0, "item": 0.0}   # 设置面板开关滑块过渡
var _net_nick_edit: LineEdit = null
var net_resume_t := 0.0
var net_was_paused := false
var _net_turn_key := ""
var _net_turn_start_ms := 0
var _net_turn_over_s := 0
var net_in_game := false         # 是否处于一局对局中（用于「再来一局」回房间）
var net_energy_drag := false     # 房间页初始积分滑条拖动中
var net_turn_limit_s := 60.0     # 60 s 无操作 -> 全桌暂停（timeout）
var net_rtt_ms := 0
var net_await_text := ""
var net_ui_active := false      # 联机对局 HUD 开关（net_role 变化时同步；hud_base 读它）
## 切屏回调（screen/goto 定义在子类 pieces_base/flow_base，基类不能直接调；由 game_main 注入）
var net_nav: Callable = Callable()
var net_host_ip := ""           # 客人：房主 IP（手动/发现加入时记录，房间页展示）
var net_search_t := 0.0         # 大厅「搜索中」空态倒计时（>0 显示扫描中，归零显示无房间）

func net_switch(s: int) -> void:
	if net_nav.is_valid(): net_nav.call(s)

const NET_CANVAS := Vector2(720.0, 1280.0)   # NET/房间/键盘/overlay 共用的设计画布
const NET_COLOR_NAMES := {1: "绿", 2: "橙", 3: "蓝", 4: "红"}

## ---- Figma A 方案设计令牌（720x1280；见 _incoming/figma-ai/DESIGN_SPEC.md）----
const NT_BG := Color("#F5F2ED")
const NT_CARD := Color("#FFFFFF")
const NT_SUB := Color("#FAF8F5")
const NT_LINE := Color("#E2DDD6")
const NT_SOFT := Color("#EFECE7")
const NT_GREEN_SOFT := Color("#EBF4ED")
const NT_INK := Color("#3B332D")
const NT_AUX := Color("#8B98AD")
const NT_WEAK := Color("#B5B3AE")
const NT_GREEN := Color("#2F7D4F")
const NT_WARN := Color("#C0453C")
const NT_WARM_BG := Color("#FFF4E0")
const NT_WARM_LINE := Color("#E0B25A")
const NT_DIM := Color(0.231, 0.2, 0.176, 0.4)
## 设计稿玩家色（头像底/席位描边/信息卡；棋盘棋子仍用 cols）
const NET_PLAYER_COLS := {1: Color("#8FD0A0"), 2: Color("#F3B98C"),
	3: Color("#9CC3E8"), 4: Color("#F0A3A3")}
const NET_SIDE := {1: "绿方", 2: "橙方", 3: "蓝方", 4: "红方"}

## 720x1280 设计画布 -> 当前控件尺寸的等比缩放与居中偏移。
## NET 页所有绘制先 draw_set_transform，命中用 _net_map_hits 映射回控件坐标，
## 保证窗口不是 9:16（桌面窗口被拖大/缩小）时排版仍然居中、不变形。
func _net_canvas_xform() -> Dictionary:
	var s: float = minf(size.x / NET_CANVAS.x, size.y / NET_CANVAS.y)
	if s <= 0.0: s = 1.0
	# 只做水平居中，不再给 720x1280 设计稿叠加垂直偏移（高屏按真实高度重排）
	return {"scale": s, "offset": Vector2((size.x - NET_CANVAS.x * s) * 0.5, 0.0)}

## 当前控件高度换算到 NET 设计坐标（720 宽）后的可用高度
func _net_geo_h() -> float:
	return size.y / maxf(0.001, float(_net_canvas_xform().scale))

func _net_map_hits(hits: Array) -> Array:
	var cv := _net_canvas_xform()
	var s: float = cv.scale
	var off: Vector2 = cv.offset
	var out: Array = []
	for h in hits:
		var nh: Dictionary = (h as Dictionary).duplicate()
		nh["r"] = Rect2(off + (h.r as Rect2).position * s, (h.r as Rect2).size * s)
		out.append(nh)
	return out

## 本机局域网 IPv4（房主在房间页展示，方便客人手动连接）
func _net_local_ip() -> String:
	var cands: Array = IP.get_local_addresses()
	for a in cands:
		var s := str(a)
		if s.begins_with("192.168.") or s.begins_with("10."): return s
	for a in cands:
		var s := str(a)
		if s.begins_with("172."):
			var parts := s.split(".")
			if parts.size() == 4:
				var p2 := int(parts[1])
				if p2 >= 16 and p2 <= 31: return s
	return ""

## 按像素宽度折行（弹层文案；比按字符数切更不容易把 Wi-Fi 之类的词拆得难看）
func _net_wrap_text(font: Font, text: String, max_w: float, fs: int) -> Array:
	var out: Array = []
	var cur := ""
	for ch in text:
		var nxt := cur + ch
		if cur != "" and font.get_string_size(nxt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
			out.append(cur); cur = ch
		else:
			cur = nxt
	if cur != "": out.append(cur)
	return out


# ---------------------------------------------------------------- 工具
func net_random_nickname() -> String:
	return "飞行员·%04X" % (randi() & 0xFFFF)

# ---- 昵称本地持久化：改一次后下次启动沿用（user://net_nickname.txt）----
const NET_NICK_FILE := "user://net_nickname.txt"

## ---------------------------------------------------------------- 头像（1..8，持久化）
const NET_AVATAR_COUNT := 20
const NET_AVATAR_FILE := "user://net_avatar.txt"

func _net_avatar_texture(a: int) -> Texture2D:
	var id := clampi(a, 1, NET_AVATAR_COUNT)
	if _net_avatar_tex.has(id): return _net_avatar_tex[id]
	var path := "res://assets/avatars/avatar_%d.svg" % id
	var tex: Texture2D = null
	if ResourceLoader.exists(path): tex = load(path)
	_net_avatar_tex[id] = tex
	return tex

func _net_seat_avatar(pid: int) -> int:
	var a := 1
	if net_lobby != null and net_lobby.seats.has(pid):
		a = int(net_lobby.seats[pid].get("avatar", 1))
	return clampi(a, 1, NET_AVATAR_COUNT)

func _net_load_avatar() -> void:
	net_avatar = 1
	if FileAccess.file_exists(NET_AVATAR_FILE):
		var f := FileAccess.open(NET_AVATAR_FILE, FileAccess.READ)
		if f != null:
			var v := int(f.get_as_text().strip_edges())
			if v >= 1 and v <= NET_AVATAR_COUNT: net_avatar = v

func _net_save_avatar() -> void:
	var f := FileAccess.open(NET_AVATAR_FILE, FileAccess.WRITE)
	if f != null: f.store_string(str(net_avatar))

func _net_set_avatar(a: int) -> void:
	net_avatar = clampi(a, 1, NET_AVATAR_COUNT)
	_net_save_avatar()
	if net_session != null and net_session.has_method("set_local_avatar"):
		net_session.call("set_local_avatar", net_avatar)
	queue_redraw()

## 圆形底 + 白色表情图标（web 版 emoji SVG 为纯白，需要按玩家色/底色衬底）
func _net_draw_avatar(center: Vector2, radius: float, avatar_id: int, ring: Color, active := false) -> void:
	# 白色线条表情需要稍深的玩家色底才看得清（web 版本身用较饱和的玩家色）
	draw_circle(center, radius, ring.darkened(0.24))
	var tex := _net_avatar_texture(avatar_id)
	if tex != null:
		var ir := radius * 0.82
		draw_texture_rect(tex, Rect2(center - Vector2(ir, ir), Vector2(ir, ir) * 2.0), false)
	draw_arc(center, radius, 0.0, TAU, 36, ring.darkened(0.45), 3.5 if active else 2.0)

func _net_avatar_bg(a: int) -> Color:
	return cols.get(((int(a) - 1) % 4) + 1, Color("#8b98ad"))

func _net_load_nickname() -> String:
	var f := FileAccess.open(NET_NICK_FILE, FileAccess.READ)
	if f == null: return ""
	var s := f.get_as_text().strip_edges()
	f.close()
	if s.length() < 1 or s.length() > 12: return ""
	return s

func _net_save_nickname() -> void:
	var f := FileAccess.open(NET_NICK_FILE, FileAccess.WRITE)
	if f != null:
		f.store_string(net_nickname)
		f.close()

func net_ensure() -> void:
	if not _net_avatar_loaded:
		_net_load_avatar()
		_net_avatar_loaded = true
	if net_nickname == "":
		net_nickname = _net_load_nickname()
		if net_nickname == "":
			net_nickname = net_random_nickname()
			_net_save_nickname()
	if net_session == null:
		net_session = FxqSession.new()
		net_session.set_nickname(net_nickname)
		net_session.set("local_avatar", net_avatar)
		net_session.room_changed.connect(_net_on_room_changed)
		net_session.game_started.connect(_net_on_game_started)
		net_session.join_ok.connect(_net_on_join_ok)
		net_session.join_rejected.connect(_net_on_join_rejected)
		net_session.disconnected.connect(_net_on_disconnected)
		net_session.connection_failed.connect(_net_on_connection_failed)
		net_session.reject_received.connect(_net_on_reject)
		if net_session.has_signal("host_left_received"):
			net_session.connect("host_left_received", Callable(self, "_net_on_host_left"))
	if net_disc == null:
		net_disc = FxqDiscovery.new()
	if net_store == null:
		net_store = FxqRoomStore.new()

func net_set_status(msg: String, secs: float = 3.0) -> void:
	net_status = msg
	net_status_t = secs
	queue_redraw()

# ---------------------------------------------------------------- 进入 / 离开
func net_enter() -> void:
	net_ensure()
	net_page = "connect"
	net_overlay = ""
	net_search_t = 6.0
	if net_store != null: net_pending_restore = net_store.list_unfinished()
	if net_disc != null and not net_disc.is_listening():
		net_disc.start_listen(FxqProtocol.DISCOVERY_PORT)
	queue_redraw()

func net_create_room() -> bool:
	net_ensure()
	if net_session != null: net_session.set("local_avatar", net_avatar)
	net_status = ""
	var err: int = FAILED
	for i in NET_PORT_TRIES:
		var p: int = NET_PORT_BASE + i
		err = int(net_session.host(p))
		if err == OK:
			net_port = p
			break
	if err != OK:
		net_overlay = "error"
		net_overlay_msg = "无法监听端口（%d–%d 都被占用或防火墙拦截）" % [NET_PORT_BASE, NET_PORT_BASE + NET_PORT_TRIES - 1]
		queue_redraw()
		return false
	net_role = "host"
	net_ui_active = true
	net_lobby = FxqLobby.new()
	net_session.host_attach_lobby(net_lobby)
	net_local_seat = int(net_session.local_seat)
	net_host_seat = net_local_seat
	net_room_id = net_session.room_id
	net_bridge = FxqNetGame.new()
	net_bridge.bind_host(net_session, self)
	if net_disc != null:
		net_disc.close_listen()
		_net_update_advertise()
	net_page = "room"
	net_set_status("房间已创建，等朋友加入", 4.0)
	queue_redraw()
	return true

func net_join_ip(ip: String, port: int = 0) -> bool:
	net_ensure()
	if net_session != null: net_session.set("local_avatar", net_avatar)
	net_host_ip = ip.strip_edges()
	if ip.strip_edges() == "": return false
	net_overlay = "connecting"
	net_overlay_msg = "正在连接 %s …" % ip
	net_role = "client"
	var p: int = port if port > 0 else NET_PORT_BASE
	net_port = p
	var err := int(net_session.join(ip, p, net_nickname))
	if err != OK:
		net_overlay = "error"
		net_overlay_msg = "连接调用失败（错误码 %d）" % err
		queue_redraw()
		return false
	queue_redraw()
	return true

func net_join_room(room: Dictionary) -> bool:
	return net_join_ip(str(room.get("ip", "")), int(room.get("port", NET_PORT_BASE)))

## 重置回合计时（切局/回房间/恢复后必须重置，否则上一局的起点会让新局/恢复后立刻被判 60s 超时）
func net_reset_turn_timer() -> void:
	_net_turn_key = ""
	_net_turn_start_ms = Time.get_ticks_msec()
	_net_turn_over_s = 0
	net_resume_t = 0.0
	net_was_paused = false

## 「再来一局」：房间保留，回到 NET 房间页等全员重新准备
func net_after_return_lobby() -> void:
	net_in_game = false
	net_page = "room"
	net_ui_active = false
	net_cfg_expand = false
	net_cfg_anim = 0.0
	set("show_result", false)
	net_reset_turn_timer()
	net_switch(Scr.NET)
	queue_redraw()

func net_leave() -> void:
	if net_nick_open: _net_close_nick_edit()
	net_cfg_expand = false
	net_cfg_anim = 0.0
	net_avatar_picker_open = false
	more_info_open = false
	net_energy_drag = false
	net_in_game = false
	net_reset_turn_timer()
	# 房主主动离开/结算离开：先广播 HOST_LEFT，客户端显示「房主已离开」并退回
	if net_session != null and net_role == "host" and net_session.has_method("host_close_room"):
		net_session.call("host_close_room", "房主离开")
	if net_session != null: net_session.close()
	if net_disc != null: net_disc.close()
	net_session = null
	net_bridge = null
	net_lobby = null
	net_role = ""
	net_ui_active = false
	net_page = "connect"
	net_local_seat = 0
	net_host_ip = ""
	net_search_t = 0.0
	net_overlay = ""
	net_rooms = []
	net_switch(Scr.MODE)

# ---------------------------------------------------------------- 会话回调
func _net_on_room_changed() -> void:
	if net_session != null and net_session.lobby != null:
		net_lobby = net_session.lobby
		# 对局设置阶段可能换颜色/换座位：同步本机座位与房主座位（客户端由 SEAT_ASSIGNED 更新 session.local_seat）
		if int(net_session.local_seat) > 0: net_local_seat = int(net_session.local_seat)
		net_host_seat = int(net_lobby.host_seat)
		var ph2 := str(net_lobby.phase)
		if ph2 == "lobby":
			net_reset_turn_timer()
			# 房主「再来一局」：对局中的客户端收到 phase=lobby → 回房间页（房间保留）
			if net_in_game and net_role == "client":
				net_after_return_lobby()
	if net_role == "host":
		_net_update_advertise()
	queue_redraw()

func _net_on_game_started(_payload: Dictionary) -> void:
	# 桥已经按 payload 建好局；直接切到对局（联机开局不做过渡动画，避免吞输入）
	net_overlay = ""
	net_page = "room"
	net_in_game = true
	net_cfg_expand = false
	net_cfg_anim = 0.0
	net_reset_turn_timer()
	net_switch(Scr.PLAY)
	queue_redraw()

func _net_on_join_ok(seat: int) -> void:
	net_local_seat = seat
	net_role = "client"
	net_ui_active = true
	net_overlay = ""
	net_page = "room"
	if net_session != null and net_session.lobby != null:
		net_lobby = net_session.lobby
	if net_bridge == null:
		net_bridge = FxqNetGame.new()
		net_bridge.bind_client(net_session, self)
	net_set_status("已加入房间，座位 %d" % seat, 4.0)

func _net_on_join_rejected(code: String, reason: String) -> void:
	net_overlay = "error"
	net_overlay_msg = "无法加入：%s" % reason
	net_role = ""
	queue_redraw()

func _net_on_disconnected() -> void:
	# 房主主动离开时，客户端会先收到 HOST_LEFT（net 层置 host_left），不再弹重连提示
	if net_session != null:
		var hl = net_session.get("host_left")
		if hl != null and bool(hl):
			return
	net_overlay = "disconnected"
	net_overlay_msg = "与房主的连接已断开，正在尝试重连…"
	queue_redraw()

## 房主离开/解散：提示其他玩家，允许返回
func _net_on_host_left(reason: String) -> void:
	net_overlay = "host_left"
	var by := ""
	if net_session != null:
		var bv = net_session.get("host_left_by")
		if bv != null: by = str(bv)
	net_overlay_msg = "房主已离开，本局结束（%s）" % (by if by != "" else reason)
	net_bridge = null
	net_role = ""
	net_page = "connect"
	net_ui_active = false
	# 若正在 PLAY（对局中房主离开），切回 NET 页才能看到提示并退出；否则会卡在对局画面
	net_switch(Scr.NET)
	queue_redraw()

func _net_on_connection_failed() -> void:
	net_overlay = "error"
	net_overlay_msg = "连接失败：请确认房主已创建房间且在同一 Wi-Fi"
	queue_redraw()

func _net_on_reject(_seq: int, code: String, reason: String) -> void:
	net_set_status("请求被拒：%s（%s）" % [reason, code], 2.5)

## M5：手动 IP 连接（默认端口 7788；键盘只输 IP，避免小屏幕输端口）
func _net_manual_connect() -> void:
	net_kb_open = false
	var ip := net_manual_ip.strip_edges()
	if ip == "":
		net_set_status("请输入房主的 IP 地址", 2.5)
		return
	net_join_ip(ip, NET_PORT_BASE)


## ---------------------------------------------------------------- 几何（唯一布局真相 · 720x1280 设计坐标）
## 手动连接键盘（设计稿 04：白卡数字键盘 + IP 显示 + 取消/连接）
func _net_kb_geo() -> Dictionary:
	var kw := 173.333
	var kh := 76.0
	var gap := 12.0
	var card := Rect2(56.0, (_net_geo_h() - 738.0) * 0.5, 608.0, 738.0)
	var px := card.position.x + 32.0
	var py := card.position.y + 227.0
	var keys: Array = []
	for i in 9:
		keys.append({"r": Rect2(px + float(i % 3) * (kw + gap), py + float(i / 3) * (kh + gap), kw, kh),
			"a": "kb_%d" % (i + 1)})
	var ry := py + 3.0 * (kh + gap)
	keys.append({"r": Rect2(px, ry, kw, kh), "a": "kb_dot"})
	keys.append({"r": Rect2(px + kw + gap, ry, kw, kh), "a": "kb_0"})
	keys.append({"r": Rect2(px + (kw + gap) * 2.0, ry, kw, kh), "a": "kb_del"})
	return {
		"card": card,
		"title_y": card.position.y + 62.0, "desc_y": card.position.y + 95.0,
		"input": Rect2(card.position.x + 32.0, card.position.y + 123.0, 544.0, 80.0),
		"keys": keys,
		"cancel": Rect2(card.position.x + 32.0, card.position.y + 591.0, 265.0, 72.0),
		"ok": Rect2(card.position.x + 313.0, card.position.y + 591.0, 263.0, 72.0),
		"note_y": card.position.y + 703.0,
	}

# ---------------------------------------------------------------- 昵称编辑（可改昵称）
func _net_nick_geo() -> Dictionary:
	# 卡高贴合内容：标题/说明/输入框/按钮行 + 上下留白，约 270
	var card := Rect2(80.0, (_net_geo_h() - 270.0) * 0.5, 560.0, 270.0)
	return {
		"card": card,
		"title_y": card.position.y + 46.0,
		"desc_y": card.position.y + 76.0,
		"input": Rect2(card.position.x + 24.0, card.position.y + 92.0, 512.0, 64.0),
		"random": Rect2(card.position.x + 24.0, card.position.y + 176.0, 150.0, 56.0),
		"cancel": Rect2(card.position.x + 192.0, card.position.y + 176.0, 150.0, 56.0),
		"save": Rect2(card.position.x + 358.0, card.position.y + 176.0, 150.0, 56.0),
	}

func _net_nick_ensure_edit() -> void:
	if _net_nick_edit != null: return
	_net_nick_edit = LineEdit.new()
	_net_nick_edit.max_length = 12
	_net_nick_edit.placeholder_text = "输入昵称（1-12 个字符）"
	_net_nick_edit.add_theme_font_size_override("font_size", 22)
	_net_nick_edit.add_theme_color_override("font_color", NT_INK)
	_net_nick_edit.add_theme_color_override("font_placeholder_color", NT_AUX)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#FAF8F5")
	sb.border_color = C_LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(16)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	_net_nick_edit.add_theme_stylebox_override("normal", sb)
	# 聚焦样式与普通态完全一致，避免 Godot 默认 focus 边框叠加出「双线」
	_net_nick_edit.add_theme_stylebox_override("focus", sb.duplicate())
	_net_nick_edit.visible = false
	_net_nick_edit.text_submitted.connect(_net_nick_submitted)
	add_child(_net_nick_edit)

func _net_nick_submitted(_t: String) -> void:
	_net_nick_save()

func _net_place_nick_edit() -> void:
	if _net_nick_edit == null: return
	var kgeo := _net_nick_geo()
	var cv := _net_canvas_xform()
	var s: float = cv.scale
	var input: Rect2 = kgeo["input"]
	_net_nick_edit.position = cv.offset + input.position * s
	_net_nick_edit.size = input.size * s
	var fs: int = int(round(22.0 * maxf(s, 0.5)))
	_net_nick_edit.add_theme_font_size_override("font_size", fs)
	_net_nick_edit.add_theme_constant_override("minimum_character_width", 0)
	_net_nick_edit.visible = net_nick_open

func _net_open_nick_edit() -> void:
	_net_nick_ensure_edit()
	net_nick_open = true
	_net_nick_edit.text = net_nickname
	_net_place_nick_edit()
	_net_nick_edit.visible = true
	_net_nick_edit.grab_focus()
	_net_nick_edit.select_all()
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_show(net_nickname)
	queue_redraw()

func _net_close_nick_edit() -> void:
	net_nick_open = false
	if _net_nick_edit != null:
		_net_nick_edit.release_focus()
		_net_nick_edit.visible = false
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_hide()
	queue_redraw()

func _net_nick_save() -> void:
	var txt := ""
	if _net_nick_edit != null: txt = _net_nick_edit.text.strip_edges()
	if txt.length() > 12: txt = txt.substr(0, 12)
	if txt == "": txt = net_random_nickname()
	net_nickname = txt
	if net_session != null: net_session.set_nickname(net_nickname)
	_net_save_nickname()
	_net_close_nick_edit()
	net_set_status("昵称已改为「%s」" % net_nickname, 2.5)
	queue_redraw()

# ---------------------------------------------------------------- 头像选择弹窗（设计稿 07：4x5 头像网格）
func _net_avatar_picker_geo() -> Dictionary:
	var card := Rect2(56.0, (_net_geo_h() - 994.0) * 0.5, 608.0, 994.0)
	var cells: Array = []
	for i in 20:
		var col := i % 4
		var row := i / 4
		var cx := card.position.x + 32.0 + float(col) * 140.0 + 62.0
		var cy := card.position.y + 167.0 + float(row) * 142.0
		cells.append({"c": Vector2(cx, cy), "r": 45.0, "id": i + 1})
	return {"card": card, "cells": cells,
		"close": Rect2(card.position.x + 32.0, card.position.y + 890.0, 544.0, 72.0)}

## 圆形玩家色底 + 白色表情图标（设计稿：底=玩家色，图标白色）
func _net_avatar_ui(center: Vector2, radius: float, avatar_id: int, bg: Color,
		ring_col: Color = Color.WHITE, ring_w: float = 2.0) -> void:
	draw_circle(center, radius, bg)
	var tex := _net_avatar_texture(avatar_id)
	if tex != null:
		var ir: float = radius * 0.78
		draw_texture_rect(tex, Rect2(center - Vector2(ir, ir), Vector2(ir, ir) * 2.0), false)
	if ring_w > 0.0:
		draw_arc(center, maxf(1.0, radius - ring_w * 0.5), 0.0, TAU, 48, ring_col, ring_w)

func _net_avatar_pal(a: int) -> Color:
	return NET_PLAYER_COLS.get(((int(a) - 1) % 4) + 1, NT_AUX)

func _net_avatar_hits() -> Array:
	var g := _net_avatar_picker_geo()
	var hits: Array = []
	for cell in g["cells"]:
		var c: Vector2 = cell["c"]
		hits.append({"r": Rect2(c - Vector2(50, 50), Vector2(100, 100)),
			"a": "avatar_pick_%d" % int(cell["id"])})
	hits.append({"r": g["close"], "a": "avatar_close"})
	return hits

# ---------------------------------------------------------------- 通用绘制小工具
func _nt_str(font: Font, x: float, y: float, txt: String, fs: int, col: Color,
		w: float = -1.0, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string(font, Vector2(x, y), txt, align, w, fs, col)

func _nt_box(r: Rect2, bg: Color, radius: int, bw: int = 0, bc: Color = Color(0, 0, 0, 0)) -> void:
	draw_style_box(_sb(bg, radius, bw, bc), r)

func _nt_text_w(font: Font, txt: String, fs: int) -> float:
	return font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x

## 设计稿里的 chevron-left（7x14，允许按 s 放大）
func _nt_icon_back(c: Vector2, col: Color, s: float = 1.0) -> void:
	draw_polyline(PackedVector2Array([c + Vector2(3.5, -7.0) * s, c + Vector2(-3.5, 0.0) * s,
		c + Vector2(3.5, 7.0) * s]), col, 2.0 * s)

func _nt_icon_chevron(c: Vector2, col: Color, up: bool, s: float = 1.0) -> void:
	var dy := -1.0 if up else 1.0
	draw_polyline(PackedVector2Array([c + Vector2(-6.0, -3.0 * dy) * s, c + Vector2(0.0, 3.0 * dy) * s,
		c + Vector2(6.0, -3.0 * dy) * s]), col, 2.0 * s)

func _nt_icon_refresh(c: Vector2, col: Color, s: float = 1.0) -> void:
	draw_arc(c, 8.0 * s, deg_to_rad(35.0), deg_to_rad(300.0), 22, col, 2.0 * s)
	var tip := c + Vector2(cos(deg_to_rad(35.0)), sin(deg_to_rad(35.0))) * 8.0 * s
	draw_polyline(PackedVector2Array([tip + Vector2(-3.5, -1.0) * s, tip + Vector2(1.5, -3.5) * s,
		tip + Vector2(3.0, 3.0) * s]), col, 2.0 * s)

func _nt_icon_wifi(c: Vector2, col: Color, s: float = 1.0, off: bool = false) -> void:
	var base := c + Vector2(0.0, 7.0) * s
	draw_circle(base, 2.4 * s, col)
	draw_arc(base, 6.0 * s, PI * 1.18, PI * 1.82, 12, col, 2.0 * s)
	draw_arc(base, 11.0 * s, PI * 1.15, PI * 1.85, 16, col, 2.0 * s)
	if off:
		# 03c 设计稿：wifi 断开斜杠从左上斜穿到右下、压在弧线之上
		draw_line(c + Vector2(-11.0, -12.0) * s, c + Vector2(11.0, 12.0) * s, col, 2.2 * s)

func _nt_icon_search(c: Vector2, col: Color, s: float = 1.0) -> void:
	draw_arc(c + Vector2(-1.5, -1.5) * s, 8.5 * s, 0.0, TAU, 26, col, 2.0 * s)
	draw_line(c + Vector2(5.0, 5.0) * s, c + Vector2(12.0, 12.0) * s, col, 2.0 * s)

func _nt_icon_radar(c: Vector2, col: Color, s: float = 1.0) -> void:
	draw_arc(c, 12.0 * s, 0.0, TAU, 28, col, 2.0 * s)
	draw_arc(c, 7.0 * s, 0.0, TAU, 22, col, 2.0 * s)
	draw_circle(c, 2.2 * s, col)
	draw_line(c, c + Vector2(8.5, -8.5) * s, col, 2.0 * s)

func _nt_icon_plus(c: Vector2, col: Color, s: float = 1.0) -> void:
	draw_line(c + Vector2(-7.0, 0.0) * s, c + Vector2(7.0, 0.0) * s, col, 2.4 * s)
	draw_line(c + Vector2(0.0, -7.0) * s, c + Vector2(0.0, 7.0) * s, col, 2.4 * s)

func _nt_icon_copy(c: Vector2, col: Color, s: float = 1.0) -> void:
	draw_rect(Rect2(c + Vector2(-9.0, -10.0) * s, Vector2(13.0, 15.0) * s), col, false, 2.0 * s)
	draw_rect(Rect2(c + Vector2(-3.0, -4.0) * s, Vector2(13.0, 15.0) * s), col, false, 2.0 * s)

func _nt_icon_clock(c: Vector2, col: Color, s: float = 1.0) -> void:
	draw_arc(c, 9.5 * s, 0.0, TAU, 26, col, 2.0 * s)
	draw_line(c, c + Vector2(0.0, -5.5) * s, col, 2.0 * s)
	draw_line(c, c + Vector2(4.5, 1.5) * s, col, 2.0 * s)

func _nt_icon_pencil(c: Vector2, col: Color, s: float = 1.0) -> void:
	draw_line(c + Vector2(-8.0, 8.0) * s, c + Vector2(6.0, -6.0) * s, col, 2.2 * s)
	draw_line(c + Vector2(6.0, -6.0) * s, c + Vector2(9.0, -9.0) * s, col, 2.2 * s)
	draw_line(c + Vector2(-8.0, 8.0) * s, c + Vector2(-5.0, 9.0) * s, col, 2.2 * s)

func _nt_icon_check(c: Vector2, col: Color, s: float = 1.0) -> void:
	draw_polyline(PackedVector2Array([c + Vector2(-5.5, 0.0) * s, c + Vector2(-1.5, 4.5) * s,
		c + Vector2(6.0, -4.5) * s]), col, 2.4 * s)

func _nt_icon_sliders(c: Vector2, col: Color, s: float = 1.0) -> void:
	for i in 3:
		var y := c.y + (float(i) - 1.0) * 6.0 * s
		draw_line(Vector2(c.x - 9.0 * s, y), Vector2(c.x + 9.0 * s, y), col, 2.0 * s)
		var kx := c.x + (4.0 if i == 0 else (-4.0 if i == 1 else 1.0)) * s
		draw_circle(Vector2(kx, y), 2.6 * s, col)

func _nt_icon_pause(c: Vector2, col: Color, s: float = 1.0) -> void:
	draw_rect(Rect2(c + Vector2(-8.0, -10.0) * s, Vector2(6.0, 20.0) * s), col)
	draw_rect(Rect2(c + Vector2(2.0, -10.0) * s, Vector2(6.0, 20.0) * s), col)

func _nt_icon_door(c: Vector2, col: Color, s: float = 1.0) -> void:
	draw_rect(Rect2(c + Vector2(-9.0, -12.0) * s, Vector2(18.0, 24.0) * s), col, false, 2.0 * s)
	draw_circle(c + Vector2(4.0, 0.0) * s, 2.2 * s, col)

## 设计稿开关：64x36 胶囊轨道 + 28 白色滑块
func _nt_switch(track: Rect2, on: float, accent: Color = NT_GREEN) -> void:
	var t: float = clampf(on, 0.0, 1.0)
	var e: float = t * t * (3.0 - 2.0 * t)
	_nt_box(track, Color("#D5DBE6").lerp(accent, e), int(track.size.y * 0.5))
	var kx := lerpf(track.position.x + track.size.y * 0.5, track.end.x - track.size.y * 0.5, e)
	draw_circle(Vector2(kx, track.position.y + track.size.y * 0.5),
		track.size.y * 0.5 - 4.0, Color.WHITE)

## 房间主按钮（开始/准备）：颜色 + 文字色按状态过渡（房主禁用=浅底灰字，访客已准备=白底描边）
func _nt_main_button_anim(r: Rect2, label: String, primary: bool, enabled: bool, a: float, fs: int = 24) -> void:
	var p := clampf(a, 0.0, 1.0)
	var bg := NT_GREEN
	var fg := Color.WHITE
	var bw := 0
	var bc := Color(0, 0, 0, 0)
	if net_role == "host":
		bg = NT_SOFT.lerp(NT_GREEN, p)
		fg = NT_AUX.lerp(Color.WHITE, p)
	else:
		bg = NT_GREEN.lerp(NT_CARD, p)
		fg = Color.WHITE.lerp(NT_INK, p)
		bw = int(round(p))
		bc = NT_LINE
	_nt_box(r, bg, 16, bw, bc)
	draw_string(ThemeDB.fallback_font, Vector2(r.position.x, r.position.y + r.size.y * 0.5 + float(fs) * 0.36),
		label, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs, fg)

## 主/次按钮（设计稿：r16，主=森林绿白字，次=白底描边深字，禁用=浅底灰字）
func _nt_button(r: Rect2, label: String, primary: bool, enabled: bool = true,
		fs: int = 24, icon: String = "") -> void:
	var bg := NT_GREEN if primary else NT_CARD
	var fg := Color.WHITE if primary else NT_INK
	var bw := 0
	var bc := Color(0, 0, 0, 0)
	if primary and not enabled:
		bg = NT_SOFT
		fg = NT_AUX
	elif not primary:
		bw = 1
		bc = NT_LINE
	_nt_box(r, bg, 16, bw, bc)
	var tw := _nt_text_w(ThemeDB.fallback_font, label, fs)
	var text_x := r.position.x + (r.size.x - tw) * 0.5
	if icon == "plus":
		_nt_icon_plus(Vector2(text_x - 22.0, r.position.y + r.size.y * 0.5),
			fg, 1.15)
	draw_string(ThemeDB.fallback_font, Vector2(r.position.x, r.position.y + r.size.y * 0.5 + float(fs) * 0.36),
		label, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs, fg)

# ---------------------------------------------------------------- 局域网大厅几何（设计稿 03/03a/03b/03c）
func _net_connect_geo() -> Dictionary:
	var dh := _net_geo_h()
	var create := Rect2(40.0, dh - 235.0, 640.0, 72.0)
	var manual := Rect2(40.0, dh - 147.0, 640.0, 72.0)
	var restore := Rect2(40.0, create.position.y - 93.0, 640.0, 72.0)
	return {
		"back": Rect2(40.0, 36.0, 48.0, 48.0),
		"profile": Rect2(40.0, 128.0, 640.0, 124.0),
		"avatar_c": Vector2(102.0, 190.0),
		"avatar_r": 38.0,
		"nick": Rect2(596.0, 150.0, 84.0, 80.0),
		"refresh": Rect2(576.0, 324.0, 104.0, 56.0),
		"list": Rect2(40.0, 404.0, 640.0, maxf(300.0, restore.position.y - 24.0 - 404.0)),
		"restore": restore,
		"create": create,
		"manual": manual,
	}

## 房间列表行：<=3 用设计稿 154 高，4 行时压缩到 112 保证不滚动
func _net_room_rows() -> Array:
	var n: int = mini(net_rooms.size(), 4)
	var rows: Array = []
	var top := 404.0
	var h := 154.0
	var gap := 16.0
	if n >= 4:
		h = 112.0
		gap = 12.0
	for i in n:
		rows.append(Rect2(40.0, top + float(i) * (h + gap), 640.0, h))
	return rows

## 大厅列表的三种空态：searching / empty / error
func _net_lobby_state() -> String:
	if net_disc == null or not net_disc.is_listening():
		return "error"
	if net_search_t > 0.0:
		return "searching"
	return "empty"

## 设计稿 2×2 席位排列顺序：左上=座位4(红) 右上=座位1(绿) 左下=座位3(蓝) 右下=座位2(橙)
const NET_SEAT_GRID := [4, 1, 3, 2]

# ---------------------------------------------------------------- 房间页几何（设计稿 05/05a/06/06a/08）
func _net_room_geo() -> Dictionary:
	var host := net_role == "host"
	var p := _net_cfg_p()
	# 设计稿 2×2 席位：左上=4 右上=1 左下=3 右下=2
	# 收起 y=351/高 180；展开（08）y=259/高 144 —— 中间态线性插值
	var seat_y: float = lerpf(351.0, 259.0, p)
	var seat_h: float = lerpf(180.0, 144.0, p)
	var seats: Array = [
		Rect2(40.0, seat_y, 312.0, seat_h),
		Rect2(368.0, seat_y, 312.0, seat_h),
		Rect2(40.0, seat_y + seat_h + 16.0, 312.0, seat_h),
		Rect2(368.0, seat_y + seat_h + 16.0, 312.0, seat_h),
	]
	var sb: float = seat_y + seat_h * 2.0 + 16.0
	var leave_y: float = _net_geo_h() - 112.0
	var g := {
		"back": Rect2(40.0, 36.0, 48.0, 48.0),
		# 08 展开态：房间号卡压到 104 高（隐藏“我的资料/更换头像”行）
		"room_card": Rect2(40.0, 128.0, 640.0, lerpf(199.0, 104.0, p)),
		"copy": Rect2(604.0, 153.0, 56.0, 56.0),
		"avatar_c": Vector2(94.0, 273.0),
		"avatar_r": 30.0,
		"avatar_open": Rect2(552.0, 243.0, 128.0, 60.0),
		"seat_order": NET_SEAT_GRID,
		"seat_h": seat_h,
		"seats": seats,
		"seats_bottom": sb,
		"cfg_p": p,
		"status_y": lerpf(leave_y - 104.0, leave_y - 32.0, p),
		"main": Rect2(lerpf(40.0, 256.0, p), lerpf(leave_y - 86.0, leave_y, p), lerpf(640.0, 424.0, p), 72.0),
		"leave": Rect2(40.0, leave_y, lerpf(640.0, 200.0, p), 72.0),
	}
	if host:
		# 07/08 设计稿：席位底 -> 设置面板 间距展开 28 / 收起 24
		g["cfg"] = _net_cfg_geo(sb + lerpf(24.0, 28.0, p))
	else:
		g["play_card"] = Rect2(40.0, sb + 24.0, 640.0, 139.0)
	return g

## 手风琴进度（仅房主房间页有设置面板；访客恒 0）
func _net_cfg_p() -> float:
	if net_role != "host": return 0.0
	return clampf(net_cfg_anim, 0.0, 1.0)

## 房间底部按钮（房间页内联手风琴，不再占底部按钮位）
func _net_room_btn_layout() -> Dictionary:
	var g := _net_room_geo()
	return {"main": g["main"], "leave": g["leave"], "status_y": g["status_y"]}

# ---------------------------------------------------------------- 房主「对局设置」手风琴几何
func _net_cfg_geo(y_in: float = -1.0) -> Dictionary:
	var p := _net_cfg_p()
	var item_on := bool(_net_cfg_cfg().get("item", false))
	var y := y_in
	if y < 0.0:
		var seat_y: float = lerpf(351.0, 259.0, p)
		var seat_h: float = lerpf(180.0, 144.0, p)
		y = seat_y + seat_h * 2.0 + 16.0 + lerpf(24.0, 28.0, p)
	var h_full: float = 66.0 + (289.0 if item_on else 203.0) + 24.0
	var h: float = lerpf(76.0, h_full, p)
	var note_y := y + 265.0
	if item_on: note_y = y + 351.0
	return {
		"p": p, "h_full": h_full,
		"header": Rect2(40.0, y, 640.0, 76.0),
		"panel": Rect2(40.0, y, 640.0, h),
		"info": Rect2(164.0, y + 21.0, 28.0, 28.0),
		"toggle": Rect2(40.0, y, 640.0, 76.0),
		"happy": Rect2(64.0, y + 66.0, 592.0, 52.0),
		"happy_sw": Rect2(586.0, y + 74.0, 64.0, 36.0),
		"item": Rect2(64.0, y + 126.0, 592.0, 52.0),
		"item_sw": Rect2(586.0, y + 134.0, 64.0, 36.0),
		"launch": Rect2(64.0, y + 186.0, 592.0, 56.0),
		"chips": [Rect2(404.0, y + 190.0, 77.0, 48.0), Rect2(491.0, y + 190.0, 77.0, 48.0),
			Rect2(578.0, y + 190.0, 78.0, 48.0)],
		"energy": Rect2(64.0, y + 250.0, 592.0, 78.0),
		"track": Rect2(64.0, y + 303.0, 592.0, 6.0),
		"note_y": note_y,
	}

func _net_cfg_cfg() -> Dictionary:
	var lobby := _net_lobby_ref()
	return lobby.config if lobby != null else {}

func _net_cfg_summary() -> String:
	var cfg := _net_cfg_cfg()
	var happy := bool(cfg.get("happy", false))
	var item_on := bool(cfg.get("item", false))
	var mode := "经典"
	if happy and item_on: mode = "欢乐＋道具"
	elif happy: mode = "欢乐"
	elif item_on: mode = "道具"
	var lvs: Array = cfg.get("launchValues", [2, 4, 6])
	var lvs_txt: Array = []
	for lv in lvs: lvs_txt.append(str(int(lv)))
	var txt := "%s · %s点起飞" % [mode, "/".join(lvs_txt)]
	if item_on: txt += " · 初始能量 %d" % int(cfg.get("initEnergy", 0))
	return txt

func _net_cfg_hits() -> Array:
	var g := _net_cfg_geo()
	var hits: Array = []
	hits.append({"r": g["info"], "a": "cfg_info"})
	var hr: Rect2 = g["header"]
	hits.append({"r": hr, "a": "cfg_toggle"})
	# 展开/收起动画期间命中用插值后的几何，逻辑态仍是 net_cfg_expand
	if not net_cfg_expand: return hits
	hits.append({"r": g["happy"], "a": "cfg_happy"})
	hits.append({"r": g["item"], "a": "cfg_item"})
	var lv := [2, 4, 6]
	var chips: Array = g["chips"]
	for i in 3:
		hits.append({"r": chips[i], "a": "cfg_launch_%d" % lv[i], "lv": lv[i]})
	if bool(_net_cfg_cfg().get("item", false)):
		var er: Rect2 = g["energy"]
		hits.append({"r": Rect2(er.position.x, er.position.y + 22.0, er.size.x, 56.0),
			"a": "cfg_energy", "track": g["track"]})
	return hits

func _net_cfg_action(a: String) -> void:
	var lobby := _net_lobby_ref()
	if lobby == null: return
	var cfg: Dictionary = lobby.config
	match a:
		"cfg_happy":
			_net_session_call("host_set_config", [{"happy": not bool(cfg.get("happy", false))}])
		"cfg_item":
			_net_session_call("host_set_config", [{"item": not bool(cfg.get("item", false))}])
		_:
			if a.begins_with("cfg_launch_"):
				var lv := int(a.substr(11))
				var vals: Array = (cfg.get("launchValues", [2, 4, 6]) as Array).duplicate()
				if vals.has(lv): vals.erase(lv)
				else: vals.append(lv)
				if vals.is_empty(): vals = [lv]
				_net_session_call("host_set_config", [{"launchValues": vals}])

func _net_cfg_energy(pos: Vector2) -> void:
	var g := _net_cfg_geo()
	var track: Rect2 = g["track"]
	if track.size.x <= 1.0: return
	var cv := _net_canvas_xform()
	var s: float = maxf(float(cv.scale), 0.001)
	var p: Vector2 = (pos - Vector2(cv.offset)) / s
	var t: float = clampf((p.x - track.position.x) / track.size.x, 0.0, 1.0)
	_net_session_call("host_set_config", [{"initEnergy": int(round(t * 20.0)) * 5}])

# ---------------------------------------------------------------- 会话 / 房间逻辑（原逻辑保留）
func _net_session_call(fn: String, args: Array = []) -> Variant:
	if net_session != null and net_session.has_method(fn):
		return net_session.callv(fn, args)
	return null

func _net_lobby_ref() -> FxqLobby:
	var l: FxqLobby = net_lobby
	if l == null and net_session != null: l = net_session.lobby
	return l

func _net_player_col(pid: int) -> Color:
	return NET_PLAYER_COLS.get(pid, NT_AUX)

func _net_seat_nick(pid: int) -> String:
	var lobby := _net_lobby_ref()
	if lobby != null and lobby.seats.has(pid):
		return str(lobby.seats[pid].nickname)
	return "玩家%d" % pid

func _net_seat_kind(pid: int) -> String:
	var lobby := _net_lobby_ref()
	if lobby != null and lobby.seats.has(pid):
		return str(lobby.seats[pid].kind)
	return "idle"

func _net_seat_ready(pid: int) -> bool:
	var lobby := _net_lobby_ref()
	if lobby != null and lobby.seats.has(pid):
		return bool(lobby.seats[pid].ready)
	return false

func _net_seat_online(pid: int) -> bool:
	var lobby := _net_lobby_ref()
	if lobby != null and lobby.seats.has(pid):
		return bool(lobby.seats[pid].get("online", true))
	return true

## 某座位已完成棋子数 / 总数（联机 HUD 的完成度）
func _net_player_fin(pid: int) -> Dictionary:
	var tot := 4
	var fin := 0
	if st.has("players") and st.players.has(pid):
		var cs: Array = st.players[pid].chesses
		tot = cs.size()
		for c in cs:
			if bool(c.get("finished", false)): fin += 1
	return {"fin": fin, "tot": tot}

func _net_room_id_text() -> String:
	var rid := net_room_id
	if rid == "" and net_session != null: rid = net_session.room_id
	return rid.to_upper() if rid != "" else "------"

func _net_copy_room_id() -> void:
	var rid := _net_room_id_text()
	if rid == "------": return
	DisplayServer.clipboard_set(rid)
	net_set_status("房间号已复制：%s" % rid, 2.0)

func _net_main_button() -> void:
	if net_lobby == null: return
	if net_role == "host":
		if net_lobby.can_start():
			if not bool(_net_session_call("host_begin_game", [])):
				net_set_status("无法开始对局", 2.5)
		else:
			net_set_status("至少 2 人且所有真人已准备才能开始", 2.5)
	else:
		var seat := net_local_seat
		var cur := false
		if net_lobby.seats.has(seat): cur = bool(net_lobby.seats[seat].ready)
		net_session.set_ready(not cur)
		net_set_status("已准备" if not cur else "已取消准备", 1.5)

# ---------------------------------------------------------------- 恢复 / 暂停 / 房间广播（原逻辑保留）
func net_restore_latest() -> bool:
	net_ensure()
	if net_store == null: return false
	var list := net_store.list_unfinished()
	if list.is_empty():
		net_set_status("没有可恢复的对局", 2.0)
		return false
	var meta: Dictionary = list[0]
	var rid := str(meta.get("roomId", ""))
	if rid == "": return false
	net_overlay = "connecting"
	net_overlay_msg = "正在恢复房间…"
	var base_port := int(meta.get("port", NET_PORT_BASE))
	var err: int = FAILED
	var used := 0
	for i in NET_PORT_TRIES:
		var p: int = base_port + i
		err = int(net_session.host(p))
		if err == OK:
			used = p
			break
	if err != OK:
		net_overlay = "error"
		net_overlay_msg = "恢复失败：端口被占用"
		return false
	net_role = "host"
	net_ui_active = true
	net_room_id = rid
	net_port = used
	net_session.store = net_store
	net_bridge = FxqNetGame.new()
	if not net_bridge.restore_host(net_session, self, net_store, rid):
		net_overlay = "error"
		net_overlay_msg = "恢复失败：日志损坏"
		return false
	net_lobby = net_session.lobby
	net_local_seat = int(net_session.local_seat)
	net_host_seat = net_local_seat
	net_page = "room"
	net_overlay = ""
	_net_update_advertise()
	net_set_status("已恢复房间，等待玩家重连", 4.0)
	queue_redraw()
	return true

## 联机暂停/重连时挡住会改对局的输入（PLAY 页在 _click_play 里调用）
func net_pause_block() -> bool:
	if not net_ui_active or net_session == null: return false
	if bool(net_session.paused) and str(net_session.pause_reason) == "timeout" \
			and (net_session.waiting_seats as Array).has(int(net_local_seat)):
		if net_role == "host":
			net_session.host_resume()
		net_resume_t = 0.0
		queue_redraw()
		return false
	return bool(net_session.paused) or bool(net_session.reconnecting) or net_resume_t > 0.0

## 暂停按钮已移到右下按钮区，此接口保留为空以兼容旧调用
func net_play_hit(_pos: Vector2) -> bool:
	return false

func _net_update_advertise() -> void:
	if net_role != "host" or net_disc == null or net_session == null: return
	var lobby: FxqLobby = net_session.lobby
	var n := 0
	if lobby != null: n = lobby.order().size()
	var cfl: Dictionary = lobby.config if lobby != null else {}
	var mtxt := "经典"
	if bool(cfl.get("happy", false)) and bool(cfl.get("item", false)): mtxt = "欢乐＋道具"
	elif bool(cfl.get("happy", false)): mtxt = "欢乐"
	elif bool(cfl.get("item", false)): mtxt = "道具"
	var info := {
		"roomId": net_room_id,
		"name": "朋友局",
		"hostNick": net_nickname,
		"hostAvatar": net_avatar,
		"players": n,
		"maxPlayers": 4,
		"mode": mtxt,
		"port": net_port,
	}
	if net_disc.is_advertising():
		net_disc.update_advertise(info)
	else:
		net_disc.start_advertise(info)

# ---------------------------------------------------------------- 每帧推进（game_main._process 调）
func _tick_net(delta: float) -> void:
	if net_nick_open:
		_net_place_nick_edit()
	if net_session != null:
		net_session.poll()
		net_session.tick(delta)
	if net_disc != null:
		if net_role == "host":
			net_disc.tick(delta)
		elif net_disc.is_listening():
			net_disc.tick(delta)
			net_rooms = net_disc.rooms()
	if net_bridge != null and not net_bridge.is_host:
		net_bridge.pump_client()
	# 房间页手风琴 / 主按钮 / 开关的平滑动画
	var cfg_p_t: float = 1.0 if (net_role == "host" and net_cfg_expand) else 0.0
	net_cfg_anim = move_toward(net_cfg_anim, cfg_p_t, delta / 0.26)
	var cfg_now := _net_cfg_cfg()
	net_sw_anim["happy"] = move_toward(float(net_sw_anim.get("happy", 0.0)),
		1.0 if bool(cfg_now.get("happy", false)) else 0.0, delta / 0.18)
	net_sw_anim["item"] = move_toward(float(net_sw_anim.get("item", 0.0)),
		1.0 if bool(cfg_now.get("item", false)) else 0.0, delta / 0.18)
	var ready_t := 0.0
	if net_role == "host":
		var lb0 := _net_lobby_ref()
		if lb0 != null and lb0.can_start(): ready_t = 1.0
	elif _net_seat_ready(net_local_seat):
		ready_t = 1.0
	net_ready_anim = move_toward(net_ready_anim, ready_t, delta / 0.2)
	if net_search_t > 0.0:
		net_search_t = maxf(0.0, net_search_t - delta)
	if net_status_t > 0.0:
		net_status_t = maxf(0.0, net_status_t - delta)
	if net_session != null:
		if net_was_paused and not net_session.paused:
			net_resume_t = 3.0
			_net_turn_key = ""
			_net_turn_start_ms = Time.get_ticks_msec()
			_net_turn_over_s = 0
		net_was_paused = net_session.paused
		if net_resume_t > 0.0: net_resume_t = maxf(0.0, net_resume_t - delta)
	if net_role == "host" and net_session != null and net_session.lobby != null \
			and str(net_session.lobby.phase) == "playing" and not net_session.paused:
		var cur := int(st.get("currentPlayer", 0))
		var key := "%d_%d" % [int(st.get("turn", 0)), cur]
		if key != _net_turn_key:
			_net_turn_key = key
			_net_turn_start_ms = Time.get_ticks_msec()
			_net_turn_over_s = 0
		var ai_seat := false
		if net_session.lobby.seats.has(cur):
			ai_seat = str(net_session.lobby.seats[cur].kind) == "ai"
		if not ai_seat:
			var over_ms := Time.get_ticks_msec() - _net_turn_start_ms
			_net_turn_over_s = over_ms / 1000
			if over_ms >= int(net_turn_limit_s * 1000.0):
				net_session.host_pause("timeout", [cur])
				_net_turn_over_s = 0
	if net_role == "client" and net_ui_active and net_session != null and net_session.lobby != null \
			and str(net_session.lobby.phase) == "playing" and not net_session.paused:
		var cur2 := int(st.get("currentPlayer", 0))
		var key2 := "%d_%d" % [int(st.get("turn", 0)), cur2]
		if key2 != _net_turn_key:
			_net_turn_key = key2
			_net_turn_start_ms = Time.get_ticks_msec()
			_net_turn_over_s = 0
		_net_turn_over_s = int((Time.get_ticks_msec() - _net_turn_start_ms) / 1000)
	if net_ui_active or net_overlay != "" or net_page != "" or net_kb_open:
		queue_redraw()

# ---------------------------------------------------------------- 命中区域（唯一布局真相）
func net_hits() -> Array:
	return _net_map_hits(_net_hits_design())

func _net_hits_design() -> Array:
	var hits: Array = []
	if more_info_open:
		return hits
	if net_overlay != "":
		hits.append({"r": _net_overlay_geo()["btn"], "a": "overlay_close"})
		return hits
	if net_nick_open:
		var ngeo := _net_nick_geo()
		hits.append({"r": ngeo["random"], "a": "nick_random"})
		hits.append({"r": ngeo["cancel"], "a": "nick_cancel"})
		hits.append({"r": ngeo["save"], "a": "nick_save"})
		return hits
	if net_avatar_picker_open:
		return _net_avatar_hits()
	if net_kb_open:
		var kgeo := _net_kb_geo()
		for k in kgeo["keys"]: hits.append(k)
		hits.append({"r": kgeo["cancel"], "a": "kb_cancel"})
		hits.append({"r": kgeo["ok"], "a": "kb_ok"})
		return hits
	if net_page == "connect":
		var g := _net_connect_geo()
		hits.append({"r": g["back"], "a": "back"})
		hits.append({"r": g["nick"], "a": "nick"})
		hits.append({"r": g["refresh"], "a": "refresh"})
		var rows := _net_room_rows()
		for i in rows.size():
			hits.append({"r": rows[i], "a": "join_%d" % i})
		if rows.is_empty():
			var lst: Rect2 = g["list"]
			if _net_lobby_state() != "searching":
				var vo2: float = maxf(0.0, (lst.size.y - 494.0) * 0.5)
				hits.append({"r": Rect2(lst.position.x + 200.0, lst.position.y + 325.0 + vo2, 240.0, 72.0),
					"a": "refresh"})
		hits.append({"r": g["manual"], "a": "manual"})
		if net_pending_restore.size() > 0:
			hits.append({"r": g["restore"], "a": "restore"})
		hits.append({"r": g["create"], "a": "create"})
		return hits
	# 房间页（2×2 席位按设计稿顺序 4/1/3/2）
	var rg := _net_room_geo()
	var cfg_p := float(rg.get("cfg_p", 0.0))
	hits.append({"r": rg["back"], "a": "leave"})
	hits.append({"r": rg["copy"], "a": "copy_id"})
	if cfg_p < 0.5:
		hits.append({"r": rg["avatar_open"], "a": "avatar_open"})
	var seats: Array = rg["seats"]
	var order: Array = rg["seat_order"]
	var seat_h: float = rg["seat_h"]
	for i in 4:
		var seat := int(order[i])
		var r: Rect2 = seats[i]
		if net_role == "host":
			var kind := _net_seat_kind(seat)
			if kind == "idle" or kind == "ai":
				var ar := _net_ai_pill_rect(r, float(rg.get("cfg_p", 0.0)))
				hits.append({"r": ar, "a": "ai_%d" % seat, "seat": seat})
				if kind == "idle":
					hits.append({"r": ar, "a": "set_ai_%d" % seat, "seat": seat})
				else:
					hits.append({"r": ar, "a": "clear_ai_%d" % seat, "seat": seat})
		hits.append({"r": r, "a": "color_%d" % seat, "seat": seat})
	if net_role == "host":
		hits.append_array(_net_cfg_hits())
	hits.append({"r": rg["main"], "a": "main"})
	if cfg_p > 0.92 or cfg_p < 0.02:
		hits.append({"r": rg["leave"], "a": "leave"})
	return hits

func _net_room_seat_action(a: String) -> void:
	var lobby := _net_lobby_ref()
	if lobby == null: return
	if a.begins_with("color_"):
		var seat_c := int(a.substr(6))
		if not lobby.seats.has(seat_c) or seat_c == net_local_seat: return
		var kc := str(lobby.seats[seat_c].kind)
		if kc == "idle":
			if net_role == "host": _net_session_call("host_claim_seat", [seat_c])
			else: _net_session_call("request_claim_seat", [seat_c])
		elif kc == "ai":
			if net_role == "host": _net_session_call("host_set_seat", [seat_c, "idle"])
			else: net_set_status("该颜色已被选择", 1.8)
		else:
			net_set_status("该颜色已被选择", 1.8)
		return
	if net_role != "host": return
	if a.begins_with("set_ai_"):
		_net_session_call("host_set_seat", [int(a.substr(7)), "ai"])
		return
	if a.begins_with("clear_ai_"):
		_net_session_call("host_set_seat", [int(a.substr(9)), "idle"])
		return
	if a.begins_with("ai_"):
		var seat_ai := int(a.substr(3))
		if lobby.seats.has(seat_ai):
			var kk := str(lobby.seats[seat_ai].kind)
			_net_session_call("host_set_seat", [seat_ai, "idle" if kk == "ai" else "ai"])

func _click_net(pos: Vector2) -> void:
	net_ensure()
	for h in net_hits():
		if not (h.r as Rect2).has_point(pos): continue
		var a := str(h.a)
		match a:
			"back":
				net_leave()
			"leave":
				net_leave()
			"copy_id":
				_net_copy_room_id()
			"cfg_toggle":
				if net_role == "host": net_cfg_expand = not net_cfg_expand
			"cfg_info":
				if net_role == "host": more_info_open = true
			"cfg_energy":
				net_energy_drag = true
				_net_cfg_energy(pos)
			"nick":
				_net_open_nick_edit()
			"nick_random":
				if _net_nick_edit != null: _net_nick_edit.text = net_random_nickname()
			"nick_cancel":
				_net_close_nick_edit()
			"nick_save":
				_net_nick_save()
			"avatar_open":
				net_avatar_picker_open = true
				queue_redraw()
			"avatar_close":
				net_avatar_picker_open = false
				queue_redraw()
			"create":
				net_create_room()
			"refresh":
				if net_disc != null and not net_disc.is_listening():
					net_disc.start_listen(FxqProtocol.DISCOVERY_PORT)
				net_rooms = []
				net_search_t = 6.0
				net_set_status("正在搜索附近的房间…", 2.0)
			"manual":
				net_kb_open = true
				net_manual_ip = ""
				queue_redraw()
			"restore":
				net_restore_latest()
			"main":
				_net_main_button()
			"overlay_close":
				if net_overlay == "host_left":
					net_leave()
				else:
					net_overlay = ""
					net_overlay_msg = ""
			"kb_cancel":
				net_kb_open = false
			"kb_del":
				if net_manual_ip.length() > 0:
					net_manual_ip = net_manual_ip.substr(0, net_manual_ip.length() - 1)
			"kb_dot":
				if net_manual_ip.count(".") < 3 and net_manual_ip != "":
					net_manual_ip += "."
			"kb_ok":
				_net_manual_connect()
			_:
				if a.begins_with("avatar_pick_"):
					_net_set_avatar(int(a.substr(12)))
				elif a.begins_with("cfg_"):
					_net_cfg_action(a)
				elif a.begins_with("color_") or a.begins_with("ai_") \
						or a.begins_with("set_ai_") or a.begins_with("clear_ai_"):
					_net_room_seat_action(a)
				elif a.begins_with("kb_"):
					var dg := a.substr(3)
					if dg.is_valid_int() and net_manual_ip.length() < 21:
						net_manual_ip += dg
				elif a.begins_with("join_"):
					var idx := int(a.substr(5))
					if idx >= 0 and idx < net_rooms.size():
						net_join_room(net_rooms[idx])
		queue_redraw()
		return

# ---------------------------------------------------------------- 绘制：NET 页入口
func _draw_net() -> void:
	var font := ThemeDB.fallback_font
	var cv := _net_canvas_xform()
	var s: float = cv.scale
	var off: Vector2 = cv.offset
	draw_rect(Rect2(Vector2.ZERO, size), NT_BG)
	draw_set_transform(off, 0.0, Vector2(s, s))
	if net_page == "connect":
		_draw_net_connect(font)
	else:
		_draw_net_room(font)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var modal := net_kb_open or net_overlay != "" or net_nick_open or net_avatar_picker_open or more_info_open
	if modal:
		draw_rect(Rect2(Vector2.ZERO, size), NT_DIM)
		draw_set_transform(off, 0.0, Vector2(s, s))
		if net_kb_open: _draw_net_kb(font)
		if net_nick_open: _draw_net_nick(font)
		if net_avatar_picker_open: _draw_net_avatar_picker(font)
		if more_info_open: _draw_net_cfg_info(font)
		if net_overlay != "": _draw_net_overlay(font)
	if net_status != "":
		draw_set_transform(off, 0.0, Vector2(s, s))
		_draw_net_status(font)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## 顶部标题栏（局域网大厅 / 房间共用）：返回圆钮 + 大标题 + 右侧身份
func _draw_net_titlebar(font: Font, title: String, side: String) -> void:
	_nt_box(Rect2(40.0, 32.0, 48.0, 48.0), Color(1, 1, 1, 0.0), 24)
	_nt_icon_back(Vector2(64.0, 58.0), NT_INK, 1.7)
	_nt_str(font, 108.0, 69.0, title, 34, NT_INK)
	if side != "":
		_nt_str(font, 500.0, 66.0, side, 18, NT_AUX, 180.0, HORIZONTAL_ALIGNMENT_RIGHT)

# ---------------------------------------------------------------- 局域网大厅（设计稿 03/03a/03b/03c）
func _draw_net_connect(font: Font) -> void:
	var g := _net_connect_geo()
	_draw_net_titlebar(font, "局域网大厅", "")
	# 资料卡：头像 / 我的昵称 / 昵称 / 编辑
	_nt_box(g["profile"], NT_CARD, 24, 1, NT_LINE)
	_net_avatar_ui(g["avatar_c"], float(g["avatar_r"]), net_avatar,
		_net_avatar_pal(net_avatar), Color.WHITE, 2.0)
	_nt_str(font, 160.0, 178.0, "我的昵称", 17, NT_AUX)
	_nt_str(font, 160.0, 214.0, net_nickname, 26, NT_INK)
	_nt_icon_pencil(Vector2(632.0, 190.0), NT_AUX, 1.2)
	# 网络提示（设计稿：图标 (48,276) 24x24，文字基线≈292）
	_nt_icon_wifi(Vector2(60.0, 288.0), NT_GREEN, 1.0)
	_nt_str(font, 84.0, 292.0, "连接同一 Wi-Fi 或热点，即可发现房间", 19, NT_AUX)
	# 房间列表标题 + 刷新
	if net_rooms.is_empty():
		_nt_str(font, 40.0, 359.0, "附近的房间", 25, NT_INK)
	else:
		_nt_str(font, 40.0, 359.0, "附近的房间 · %d" % net_rooms.size(), 25, NT_INK)
	# 刷新/搜索中：设计稿 03 图标中心 (619,352)+文字 x=640 基线≈358；03a 图标 (599,352)+文字右对齐到 680
	var searching: bool = net_rooms.is_empty() and _net_lobby_state() == "searching"
	if searching:
		_nt_icon_refresh(Vector2(599.0, 352.0), NT_GREEN, 1.0)
		_nt_str(font, 560.0, 358.0, "搜索中", 20, NT_GREEN, 120.0, HORIZONTAL_ALIGNMENT_RIGHT)
	else:
		_nt_icon_refresh(Vector2(619.0, 352.0), NT_GREEN, 1.0)
		_nt_str(font, 640.0, 358.0, "刷新", 20, NT_GREEN)
	var rows := _net_room_rows()
	if rows.is_empty():
		_draw_net_lobby_empty(font, g)
	else:
		for i in rows.size():
			_draw_net_room_row(font, rows[i], net_rooms[i])
	# 手动连接提示
	_nt_str(font, 40.0, float(g["restore"].position.y) - 8.0,
		"找不到朋友的房间？试试手动输入房主的 IP。", 18, NT_AUX)
	# 可恢复房间（房主进程被杀后的存档）
	if net_pending_restore.size() > 0:
		var meta: Dictionary = net_pending_restore[0]
		var age_min := int(meta.get("ageMs", 0)) / 60000
		var rr: Rect2 = g["restore"]
		_nt_box(rr, NT_CARD, 16, 2, NT_GREEN)
		_nt_str(font, rr.position.x + 24.0, rr.position.y + 30.0,
			"恢复未完成的对局（%d 分钟前）" % age_min, 19, NT_INK)
		_nt_str(font, rr.position.x + 24.0, rr.position.y + 56.0,
			"房间 %s · 点右侧按钮恢复" % str(meta.get("roomId", "")).to_upper(), 15, NT_AUX)
		_nt_box(Rect2(rr.end.x - 104.0, rr.position.y + 16.0, 80.0, 40.0), NT_GREEN, 20)
		_nt_str(font, rr.end.x - 104.0, rr.position.y + 43.0, "恢复", 19,
			Color.WHITE, 80.0, HORIZONTAL_ALIGNMENT_CENTER)
	# 底部：创建房间（主）+ 手动连接 IP（次）+ 本机连接信息
	_nt_button(g["create"], "创建房间", true, true, 24, "plus")
	_nt_button(g["manual"], "手动连接 IP", false)
	var lip := _net_local_ip()
	var ip_y: float = float(g["manual"].end.y) + 33.0
	if lip == "":
		_nt_str(font, 40.0, ip_y, "本机 IP 未连接 · 端口 %d" % NET_PORT_BASE, 16, NT_AUX,
			640.0, HORIZONTAL_ALIGNMENT_CENTER)
	else:
		_nt_str(font, 40.0, ip_y, "本机 IP %s · 端口 %d" % [lip, NET_PORT_BASE], 16, NT_AUX,
			640.0, HORIZONTAL_ALIGNMENT_CENTER)

func _draw_net_room_row(font: Font, rr: Rect2, rm: Dictionary) -> void:
	var compact: bool = rr.size.y < 130.0
	_nt_box(rr, NT_CARD, 22, 1, NT_LINE)
	var ar := 24.0 if compact else 32.0
	var ac := Vector2(rr.position.x + 24.0 + ar, rr.position.y + rr.size.y * 0.5)
	var av := int(rm.get("hostAvatar", 1))
	_net_avatar_ui(ac, ar, av, _net_avatar_pal(av), Color.WHITE, 2.0)
	var host_nick := str(rm.get("hostNick", "玩家"))
	var tx := ac.x + ar + 18.0
	var title := str(rm.get("roomName", ""))
	if title == "": title = "%s的棋桌" % host_nick
	# 设计稿第二行：房主昵称 · 模式（“小林 · 经典模式”/“阿宁 · 欢乐＋道具”）
	var mode_raw := str(rm.get("mode", "经典"))
	var mode_txt := mode_raw if mode_raw.contains("＋") else (mode_raw + "模式")
	var detail := "%s · %s" % [host_nick, mode_txt]
	var rid := str(rm.get("roomId", "")).to_upper()
	if compact:
		_nt_str(font, tx, rr.position.y + 42.0, title, 22, NT_INK)
		_nt_str(font, tx, rr.position.y + 68.0, detail, 15, NT_AUX)
		_nt_str(font, tx, rr.position.y + 92.0, rid, 13, NT_AUX)
	else:
		_nt_str(font, tx, rr.position.y + 48.0, title, 24, NT_INK)
		_nt_str(font, tx, rr.position.y + 78.0, detail, 17, NT_AUX)
		_nt_str(font, tx, rr.position.y + 106.0, rid, 15, NT_AUX)
	# 右侧：人数标签 + 加入
	var cy := rr.position.y + rr.size.y * 0.5
	var chip := Rect2(rr.end.x - 112.0, cy - 41.5, 66.0, 28.0)
	_nt_box(chip, Color("#EBF4ED"), 14)
	_nt_str(font, chip.position.x, chip.position.y + 20.0,
		"%d / %d" % [int(rm.get("players", 0)), int(rm.get("maxPlayers", 4))],
		16, NT_GREEN, chip.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	var join_y := cy + 24.0 if compact else cy + 30.0
	_nt_str(font, rr.end.x - 112.0, join_y, "加入", 20, NT_GREEN, 60.0, HORIZONTAL_ALIGNMENT_RIGHT)
	draw_polyline(PackedVector2Array([Vector2(rr.end.x - 42.0, join_y - 15.0),
		Vector2(rr.end.x - 36.0, join_y - 8.0), Vector2(rr.end.x - 42.0, join_y - 1.0)]),
		NT_GREEN, 2.0)

func _draw_net_lobby_empty(font: Font, g: Dictionary) -> void:
	var lst: Rect2 = g["list"]
	_nt_box(lst, NT_CARD, 24, 1, NT_LINE)
	var state := _net_lobby_state()
	var searching := state == "searching"
	var vo: float = maxf(0.0, (lst.size.y - 494.0) * 0.5)
	var base := Rect2(lst.position.x + 276.0, lst.position.y + (145.0 if searching else 97.0) + vo, 88.0, 88.0)
	_nt_box(base, Color("#FAF8F5"), 24)
	var ic := base.position + base.size * 0.5
	var title := "正在寻找附近的房间"
	var desc := "请稍等，正在扫描同一网络中的棋桌。"
	var btn_txt := ""
	if state == "empty":
		title = "还没有发现房间"
		desc = "确认朋友已创建房间，或自己开一桌。"
		btn_txt = "再次刷新"
		_nt_icon_search(ic, NT_AUX, 1.0)
	elif state == "error":
		title = "暂时无法连接局域网"
		desc = "请检查 Wi-Fi 连接与本地网络权限。"
		btn_txt = "重新搜索"
		_nt_icon_wifi(ic, NT_AUX, 1.15, true)
	else:
		_nt_icon_radar(ic, NT_AUX, 1.0)
	var title_dy := (283.0 if searching else 232.0) + vo
	_nt_str(font, lst.position.x, lst.position.y + title_dy, title, 28, NT_INK,
		lst.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	_nt_str(font, lst.position.x, lst.position.y + title_dy + 53.0, desc, 21, NT_AUX,
		lst.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	if btn_txt != "":
		_nt_button(Rect2(lst.position.x + 200.0, lst.position.y + 325.0 + vo, 240.0, 72.0),
			btn_txt, false)

# ---------------------------------------------------------------- 房间页（设计稿 05/05a/06/06a/08）
func _draw_net_room(font: Font) -> void:
	var host := net_role == "host"
	var p := _net_cfg_p()
	var g := _net_room_geo()
	_draw_net_titlebar(font, "房间", "房主" if host else "访客")
	# 房间号卡（可复制）；08 展开态压到 104 高，隐藏“我的资料/更换头像”行
	_nt_box(g["room_card"], NT_CARD, 24, 1, NT_LINE)
	_nt_str(font, 64.0, 171.0, "房间号 · 同一网络可加入", 16, NT_AUX)
	_nt_str(font, 64.0, 210.0, _net_room_id_text(), 29, NT_INK)
	_nt_icon_copy(Vector2(632.0, 181.0), NT_AUX, 1.1)
	if p < 0.12:
		draw_line(Vector2(64.0, 226.0), Vector2(656.0, 226.0), NT_LINE, 1.0)
		var me := net_local_seat
		_net_avatar_ui(g["avatar_c"], float(g["avatar_r"]), net_avatar, _net_avatar_pal(net_avatar),
			Color.WHITE, 2.0)
		_nt_str(font, 140.0, 271.0, net_nickname, 23, NT_INK)
		# 设计稿：身份在前、颜色在后（“房主 · 绿方”/“访客 · 蓝方”）
		var my_side := "%s · %s" % [("房主" if host else "访客"), str(NET_SIDE.get(me, "绿方"))]
		_nt_str(font, 140.0, 296.0, my_side, 16, NT_AUX)
		_nt_str(font, 540.0, 286.0, "更换头像", 20, NT_GREEN, 132.0, HORIZONTAL_ALIGNMENT_RIGHT)
	# 2x2 玩家席位（设计顺序 4/1/3/2：左上红/右上绿/左下蓝/右下橙）
	var seats: Array = g["seats"]
	var order: Array = g["seat_order"]
	for i in 4:
		_draw_net_seat_card(font, seats[i], int(order[i]), p)
	# 房主设置 / 访客玩法说明
	if host:
		_draw_net_cfg_panel(font, g)
	else:
		_draw_net_guest_play_card(font, g)
	# 状态行 + 底部按钮
	_draw_net_room_status(font, g)
	var can := false
	var main_text := "准备"
	var main_primary := true
	if host:
		var lobby := _net_lobby_ref()
		can = lobby != null and lobby.can_start()
		main_text = "开始游戏"
	else:
		if _net_seat_ready(net_local_seat):
			main_text = "取消准备"
			main_primary = false
	_nt_main_button_anim(g["main"], main_text, main_primary, can if host else true, net_ready_anim, 24)
	if p > 0.92 or p < 0.02:
		_nt_button(g["leave"], "离开房间", false)

func _draw_net_room_status(font: Font, g: Dictionary) -> void:
	var host := net_role == "host"
	var msg := ""
	var msg_col := NT_AUX
	if host:
		var lobby := _net_lobby_ref()
		if lobby != null and lobby.can_start():
			msg = "全员已准备，可以出发了"
			msg_col = NT_GREEN
		else:
			var waiting: Array = []
			if lobby != null:
				for s in lobby.order():
					var k := str(lobby.seats[s].kind)
					if (k == "local" or k == "remote") and not bool(lobby.seats[s].ready):
						waiting.append(str(lobby.seats[s].nickname))
			if waiting.is_empty():
				msg = "至少 2 人才能开始"
			else:
				msg = "等待%s准备，空位不影响开始" % "、".join(waiting)
	else:
		# 06 设计稿无准备状态行；06a 为“已准备 · 等待房主开始”
		if _net_seat_ready(net_local_seat):
			msg = "已准备 · 等待房主开始"
	var y: float = g["status_y"]
	if msg != "":
		_nt_str(font, 40.0, y, msg, 18, msg_col, 640.0, HORIZONTAL_ALIGNMENT_CENTER)
	# 连接信息（设计稿 05/08：房主 IP · 端口）
	var host_ip := _net_local_ip() if host else net_host_ip
	var conn_y := y + 22.0
	if host:
		conn_y = float(g["cfg"]["panel"].end.y) + lerpf(70.0, 22.0, _net_cfg_p())
	if host and host_ip != "":
		_nt_str(font, 40.0, conn_y, "房主 IP %s · 端口 %d" % [host_ip, net_port], 16, NT_AUX)

func _draw_net_seat_card(font: Font, r: Rect2, seat: int, compact_p: float = 0.0) -> void:
	var kind := _net_seat_kind(seat)
	var nick := _net_seat_nick(seat)
	var ready := _net_seat_ready(seat)
	var online := _net_seat_online(seat)
	var mine := seat == net_local_seat
	var lobby := _net_lobby_ref()
	var host_seat := int(lobby.host_seat) if lobby != null else net_host_seat
	var ccol := _net_player_col(seat)
	var bg := NT_CARD
	var ridle := kind == "idle"
	if not online and not ridle: bg = Color("#FAF8F5")
	_nt_box(r, bg, 24, 1, NT_LINE)
	# 头像（空位=虚线加号圆；离线=灰底）
	var ac := Vector2(r.position.x + 48.0, r.position.y + 48.0)
	if ridle:
		for k in 12:
			var a0 := TAU * float(k) / 12.0 + 0.12
			draw_arc(ac, 28.0, a0, a0 + 0.32, 6, NT_LINE, 1.6)
		_nt_icon_plus(ac, NT_AUX, 1.1)
	else:
		var av := _net_seat_avatar(seat)
		var abg := _net_avatar_pal(av)
		if not online: abg = Color("#D8D5D0")
		_net_avatar_ui(ac, 28.0, av, abg, Color.WHITE, 2.0)
		if seat == host_seat:
			draw_arc(ac, 30.5, 0.0, TAU, 40, ccol, 2.0)
	# 昵称 / 角色
	var nick_col := NT_INK
	if not online and not ridle: nick_col = NT_AUX
	_nt_str(font, r.position.x + 88.0, r.position.y + 44.0,
		"等待加入" if ridle else nick, 23, nick_col)
	var tag := "空位"
	if kind == "ai": tag = "电脑"
	elif kind == "idle": tag = "空位"
	elif seat == host_seat: tag = "房主"
	else: tag = "玩家"
	var role := "%s · %s" % [str(NET_SIDE.get(seat, "?")), tag]
	if mine and not ridle: role += " · 我"
	_nt_str(font, r.position.x + 88.0, r.position.y + 70.0, role, 16, NT_AUX)
	# 准备状态行：色点 + 文案（收起态 y=116 / 展开态 y=106，随动画插值）
	var st_txt := ""
	var st_col := NT_AUX
	if ridle:
		st_txt = "可邀请朋友"
		st_col = NT_AUX
	elif not online:
		st_txt = "已离线"
	elif kind == "ai":
		st_txt = "自动准备"
		st_col = NT_GREEN
	elif ready:
		st_txt = "已就绪" if seat == host_seat else "已准备"
		st_col = NT_GREEN
	else:
		st_txt = "未准备" if mine else "等待准备"
	var sy := r.position.y + lerpf(116.0, 106.0, clampf(compact_p, 0.0, 1.0))
	_nt_icon_dot(Vector2(r.position.x + 37.0, sy - 4.0),
		ccol if (ridle or not (ready or kind == "ai")) else NT_GREEN,
		Color("#B5B3AE") if (not online and not ridle) else Color(0, 0, 0, 0))
	_nt_str(font, r.position.x + 50.0, sy, st_txt, 18, st_col)
	# 房主：空位/AI 的「设 AI / 清空」小胶囊（设计稿未画，弱化为浅底灰字）
	if net_role == "host" and (ridle or kind == "ai"):
		var ab := _net_ai_pill_rect(r, compact_p)
		_nt_box(ab, Color("#F5F2ED"), 13, 1, NT_LINE)
		_nt_str(font, ab.position.x, ab.position.y + 18.0, "清空" if kind == "ai" else "设 AI",
			13, NT_AUX, ab.size.x, HORIZONTAL_ALIGNMENT_CENTER)

## 「设 AI / 清空」小胶囊矩形（绘制与命中共用；设计稿无此控件，尽量弱化）
func _net_ai_pill_rect(r: Rect2, compact_p: float = 0.0) -> Rect2:
	return Rect2(r.end.x - 84.0, r.end.y - lerpf(56.0, 46.0, clampf(compact_p, 0.0, 1.0)), 64.0, 26.0)

## 色点（虚线空位/离线用灰点）
func _nt_icon_dot(c: Vector2, col: Color, alt: Color = Color(0, 0, 0, 0)) -> void:
	if alt.a > 0.01:
		draw_circle(c, 4.5, alt)
	else:
		draw_circle(c, 4.5, col)

func _draw_net_guest_play_card(font: Font, g: Dictionary) -> void:
	var pc: Rect2 = g["play_card"]
	_nt_box(pc, NT_CARD, 24, 1, NT_LINE)
	_nt_icon_sliders(Vector2(pc.position.x + 35.0, pc.position.y + 36.0), NT_AUX, 1.0)
	_nt_str(font, pc.position.x + 58.0, pc.position.y + 44.0, "本局玩法 · 由房主设置", 21, NT_INK)
	_nt_str(font, pc.position.x + 24.0, pc.position.y + 84.0, _net_cfg_summary(), 19, NT_INK)
	var host_ip := net_host_ip
	if host_ip != "":
		_nt_str(font, pc.position.x + 24.0, pc.position.y + 114.0,
			"房主 IP %s · 端口 %d" % [host_ip, net_port], 16, NT_AUX)
	var hint := "确认玩法后点击准备。离线玩家重连后可继续加入。"
	_nt_str(font, 40.0, _net_geo_h() - 346.0, hint, 18, NT_AUX)

func _draw_net_cfg_panel(font: Font, g: Dictionary) -> void:
	var cg: Dictionary = g["cfg"]
	var panel: Rect2 = cg["panel"]
	var p := float(cg.get("p", 1.0 if net_cfg_expand else 0.0))
	var h_full: float = float(cg.get("h_full", panel.size.y))
	_nt_box(panel, NT_CARD, 24, 1, NT_LINE)
	var y := panel.position.y
	# 标题 / 问号 / 「仅房主可改」/ chevron：统一垂直基线（文字基线 y+41/40，图标中心 y+35）
	_nt_str(font, 64.0, y + 41.0, "房主设置", 22, NT_INK)
	var inf: Rect2 = cg["info"]
	draw_circle(inf.position + inf.size * 0.5, 14.0, Color("#EFECE7"))
	_nt_str(font, inf.position.x, inf.position.y + 21.0, "?", 16, Color("#6C7A90"),
		inf.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	_nt_str(font, 520.0, y + 40.0, "仅房主可改", 16, NT_AUX,
		100.0, HORIZONTAL_ALIGNMENT_RIGHT)
	_nt_icon_chevron(Vector2(644.0, y + 35.0), NT_AUX, net_cfg_expand, 1.0)
	# 收起态：只有 76 高标题行 + 下方摘要
	if p < 0.02:
		_nt_str(font, 40.0, panel.end.y + 43.0, _net_cfg_summary(), 19, NT_INK)
		return
	# 展开过程中先只让面板高度插值；内容在 90% 后淡入（避免中间态文字溢出面板）
	if p < 0.9:
		return
	var cfg := _net_cfg_cfg()
	var happy := float(net_sw_anim.get("happy", 1.0 if bool(cfg.get("happy", false)) else 0.0))
	var item_on := bool(cfg.get("item", false))
	var item_anim := float(net_sw_anim.get("item", 1.0 if item_on else 0.0))
	# 欢乐 / 道具 开关行（滑块用动画值）
	_nt_str(font, 64.0, y + 66.0 + 34.0, "欢乐模式", 22, NT_INK)
	_nt_switch(cg["happy_sw"], happy, NT_GREEN)
	_nt_str(font, 64.0, y + 126.0 + 34.0, "道具模式", 22, NT_INK)
	_nt_switch(cg["item_sw"], item_anim, NT_GREEN)
	# 起飞点数（多选）
	_nt_str(font, 64.0, y + 186.0 + 36.0, "起飞点数", 21, NT_INK)
	var lv := [2, 4, 6]
	var lvs: Array = cfg.get("launchValues", [2, 4, 6])
	var chips: Array = cg["chips"]
	for i in 3:
		var rr: Rect2 = chips[i]
		var on: bool = lvs.has(lv[i])
		if on:
			_nt_box(rr, Color("#EBF4ED"), 16, 1, NT_GREEN)
		else:
			_nt_box(rr, Color("#FAF8F5"), 16, 1, NT_LINE)
		_nt_str(font, rr.position.x, rr.position.y + 32.0, "%d点" % lv[i], 21,
			NT_GREEN if on else NT_INK, rr.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	# 初始能量（仅道具模式）
	if item_on:
		var er: Rect2 = cg["energy"]
		var ie := int(cfg.get("initEnergy", 0))
		_nt_str(font, 64.0, er.position.y + 26.0, "初始能量", 21, NT_INK)
		_nt_str(font, 560.0, er.position.y + 26.0, str(ie), 22, NT_GREEN,
			96.0, HORIZONTAL_ALIGNMENT_RIGHT)
		var track: Rect2 = cg["track"]
		_nt_box(track, Color("#EFECE7"), 3)
		var t: float = clampf(float(ie) / 100.0, 0.0, 1.0)
		if t > 0.002:
			_nt_box(Rect2(track.position.x, track.position.y, maxf(track.size.y, track.size.x * t),
				track.size.y), NT_GREEN, 3)
		var kn := Vector2(track.position.x + track.size.x * t, track.position.y + track.size.y * 0.5)
		draw_circle(kn, 15.0, Color.WHITE)
		draw_arc(kn, 13.5, 0.0, TAU, 30, NT_GREEN, 3.0)
	_nt_str(font, 64.0, float(cg["note_y"]), "设置将同步给房间内的所有玩家", 16, NT_AUX)
	# 内容淡入/淡出：p=0.9 全白（不可见）→ p=1 完全可见；同时裁掉超出面板的少量溢出
	var fade: float = clampf((1.0 - p) / 0.1, 0.0, 1.0)
	if fade > 0.002:
		var full_bottom: float = panel.position.y + h_full
		if full_bottom > panel.end.y:
			draw_rect(Rect2(panel.position.x + 1.0, panel.end.y, panel.size.x - 2.0,
				full_bottom - panel.end.y), NT_BG)
		draw_rect(Rect2(panel.position.x + 1.0, panel.position.y + 76.0,
			panel.size.x - 2.0, h_full - 76.0), Color(1, 1, 1, fade))

# ---------------------------------------------------------------- 手动 IP / 昵称弹窗
func _draw_net_kb(font: Font) -> void:
	var kgeo := _net_kb_geo()
	var card: Rect2 = kgeo["card"]
	_nt_box(card, NT_CARD, 24, 1, NT_LINE)
	_nt_str(font, 88.0, float(kgeo["title_y"]), "手动连接 IP", 30, NT_INK)
	_nt_str(font, 88.0, float(kgeo["desc_y"]), "输入房主的局域网 IP，端口固定为 7788。", 19, NT_AUX)
	var box: Rect2 = kgeo["input"]
	_nt_box(box, Color("#FAF8F5"), 16, 2, NT_GREEN)
	if net_manual_ip != "":
		_nt_str(font, box.position.x + 24.0, box.position.y + 51.0, net_manual_ip, 32, NT_INK)
	else:
		_nt_str(font, box.position.x + 24.0, box.position.y + 51.0, "例如 192.0.2.10", 32, NT_AUX)
	for k in kgeo["keys"]:
		var rr: Rect2 = k["r"]
		_nt_box(rr, Color("#FAF8F5"), 16, 1, NT_LINE)
		var lbl := str(k["a"]).substr(3)
		if lbl == "dot": lbl = "."
		elif lbl == "del":
			# 退格图标：圆角框 + 叉
			var c := rr.position + rr.size * 0.5
			_nt_box(Rect2(c - Vector2(14.0, 10.0), Vector2(28.0, 20.0)), Color(1, 1, 1, 0.0), 4, 2, NT_INK)
			draw_line(c + Vector2(-6.0, -4.0), c + Vector2(6.0, 4.0), NT_INK, 2.0)
			draw_line(c + Vector2(-6.0, 4.0), c + Vector2(6.0, -4.0), NT_INK, 2.0)
			continue
		_nt_str(font, rr.position.x, rr.position.y + 51.0, lbl, 30, NT_INK,
			rr.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	var cc: Rect2 = kgeo["cancel"]
	_nt_button(cc, "取消", false)
	var ok: Rect2 = kgeo["ok"]
	_nt_button(ok, "连接", true)
	_nt_str(font, 56.0, float(kgeo["note_y"]), "请确保双方连接同一 Wi-Fi 或热点", 16, NT_AUX,
		608.0, HORIZONTAL_ALIGNMENT_CENTER)

func _draw_net_nick(font: Font) -> void:
	var kgeo := _net_nick_geo()
	var card: Rect2 = kgeo["card"]
	_nt_box(card, NT_CARD, 24, 1, NT_LINE)
	_nt_str(font, card.position.x, float(kgeo["title_y"]), "修改昵称", 30, NT_INK,
		card.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	_nt_str(font, card.position.x, float(kgeo["desc_y"]),
		"1–12 个字符；中文用系统输入法，回车保存", 16, NT_AUX,
		card.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	var rb: Rect2 = kgeo["random"]
	_nt_button(rb, "随机一个", false, true, 20)
	var cb: Rect2 = kgeo["cancel"]
	_nt_button(cb, "取消", false, true, 20)
	var sb: Rect2 = kgeo["save"]
	_nt_button(sb, "保存", true, true, 20)

func _draw_net_avatar_picker(font: Font) -> void:
	var g := _net_avatar_picker_geo()
	var card: Rect2 = g["card"]
	_nt_box(card, NT_CARD, 24, 1, NT_LINE)
	_nt_str(font, card.position.x + 32.0, card.position.y + 61.0, "选一个你的样子", 30, NT_INK)
	_nt_str(font, card.position.x + 32.0, card.position.y + 96.0,
		"20 款头像 · 当前选择 %02d" % net_avatar, 18, NT_AUX)
	for cell in g["cells"]:
		var c: Vector2 = cell["c"]
		var rr: float = cell["r"]
		var aid: int = int(cell["id"])
		var sel: bool = aid == net_avatar
		if sel:
			draw_circle(c, rr + 2.0, Color("#EBF4ED"))
			_net_avatar_ui(c, rr, aid, _net_avatar_pal(aid), Color.WHITE, 0.0)
			draw_arc(c, rr - 1.5, 0.0, TAU, 48, NT_GREEN, 3.0)
		else:
			draw_circle(c, rr + 2.0, Color.WHITE)
			draw_arc(c, rr + 1.0, 0.0, TAU, 48, Color("#E2DDD6"), 2.0)
			_net_avatar_ui(c, rr, aid, _net_avatar_pal(aid), Color.WHITE, 2.0)
		if sel:
			var ck := c + Vector2(28.0, 30.0)
			draw_circle(ck, 14.0, NT_GREEN)
			_nt_icon_check(ck, Color.WHITE, 1.0)
		_nt_str(font, c.x - 62.0, c.y + 66.0, ("已选 %02d" % aid) if sel else ("素材 %02d" % aid),
			16, NT_GREEN if sel else NT_AUX, 124.0, HORIZONTAL_ALIGNMENT_CENTER)
	_nt_str(font, card.position.x + 32.0, card.position.y + 854.0, "头像会记住，下次进房自动使用", 16, NT_AUX,
		544.0, HORIZONTAL_ALIGNMENT_CENTER)
	_nt_button(g["close"], "完成", true)

# ---------------------------------------------------------------- 状态条 / 覆盖层 / 设置说明
func _draw_net_status(font: Font) -> void:
	var alpha: float = clampf(net_status_t, 0.0, 1.0)
	if net_status == "" or alpha <= 0.0: return
	var tw := _nt_text_w(font, net_status, 17)
	var pw: float = minf(640.0, tw + 64.0)
	var x: float = (NET_CANVAS.x - pw) * 0.5
	_nt_box(Rect2(x, 982.0, pw, 44.0), Color(0.23, 0.2, 0.176, 0.9 * alpha), 22)
	_nt_str(font, x, 1010.0, net_status, 17, Color(1, 1, 1, alpha), pw,
		HORIZONTAL_ALIGNMENT_CENTER)

func _net_overlay_geo() -> Dictionary:
	var card := Rect2(72.0, (_net_geo_h() - 401.0) * 0.5, 576.0, 401.0)
	return {"card": card,
		"icon": Rect2(card.position.x + 252.0, card.position.y + 40.0, 72.0, 72.0),
		"btn": Rect2(card.position.x + 40.0, card.position.y + 289.0, 496.0, 72.0)}

func _draw_net_overlay(font: Font) -> void:
	var g := _net_overlay_geo()
	var card: Rect2 = g["card"]
	_nt_box(card, NT_CARD, 24, 1, NT_LINE)
	var tint := Color("#FAF8F5")
	if net_overlay == "connecting": tint = Color("#EBF4ED")
	_nt_box(g["icon"], tint, 24)
	var ic: Vector2 = (g["icon"] as Rect2).position + (g["icon"] as Rect2).size * 0.5
	if net_overlay == "connecting":
		var tsec: float = Time.get_ticks_msec() / 1000.0
		for k in 3:
			var a0: float = tsec * 3.0 + float(k) * TAU / 3.0
			draw_arc(ic, 13.0 - float(k) * 2.5, a0, a0 + 1.5, 12, NT_GREEN, 2.4)
	elif net_overlay == "host_left":
		_nt_icon_door(ic, NT_AUX, 1.1)
	else:
		_nt_icon_wifi(ic, NT_AUX if net_overlay != "error" else NT_WARN, 1.2, true)
	var title: String = str({"connecting": "正在连接…", "error": "出错了", "disconnected": "连接已断开",
		"host_left": "房主已离开"}.get(net_overlay, ""))
	_nt_str(font, card.position.x, card.position.y + 180.0, title, 34, NT_INK,
		card.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	var lines: Array = []
	if net_overlay == "host_left":
		lines = ["房间已关闭。回到大厅，", "重新加入或创建一间房间吧。"]
	else:
		lines = _net_wrap_text(font, net_overlay_msg, card.size.x - 96.0, 21)
	for i in mini(lines.size(), 2):
		_nt_str(font, card.position.x, card.position.y + 224.0 + float(i) * 32.0,
			str(lines[i]), 21, NT_AUX, card.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	var btn: Rect2 = g["btn"]
	var btn_txt := "返回大厅" if net_overlay == "host_left" else "返回"
	_nt_button(btn, btn_txt, true)

## 对局设置「?」说明（点任意处关闭，复用 more_info_open 的关闭逻辑）
func _draw_net_cfg_info(font: Font) -> void:
	var card := Rect2(60.0, (_net_geo_h() - 760.0) * 0.5, 600.0, 760.0)
	_nt_box(card, NT_CARD, 24, 1, NT_LINE)
	_nt_str(font, card.position.x + 32.0, card.position.y + 56.0, "对局设置说明", 30, NT_INK)
	draw_line(Vector2(card.position.x + 32.0, card.position.y + 76.0),
		Vector2(card.end.x - 32.0, card.position.y + 76.0), NT_LINE, 1.0)
	var y: float = card.position.y + 120.0
	var blocks := [
		["欢乐模式", NT_GREEN, [
			"撞到对方棋子时不再撞回基地，而是给自己加分；",
			"多颗棋子叠在同一格也不会被清空。"]],
		["道具模式", Color("#4777C5"), [
			"击败/碰撞攒积分，可在底部道具栏购买：",
			"遥控骰子、多面骰子、传送门、盲盒。",
			"开局前用「初始能量」滑条设定起始积分。"]],
		["起飞点数（可多选）", Color("#B7791F"), [
			"只有掷出勾选的点数才能让棋子起飞；",
			"可同时勾选 2 / 4 / 6 点。"]],
	]
	for blk in blocks:
		draw_circle(Vector2(card.position.x + 42.0, y - 7.0), 5.0, blk[1])
		_nt_str(font, card.position.x + 56.0, y, str(blk[0]), 22, blk[1])
		y += 36.0
		for ln in (blk[2] as Array):
			_nt_str(font, card.position.x + 42.0, y, str(ln), 18, Color("#4A5568"))
			y += 30.0
		y += 18.0
	_nt_str(font, card.position.x, card.end.y - 34.0, "点任意处关闭", 16, NT_AUX,
		card.size.x, HORIZONTAL_ALIGNMENT_CENTER)
# ---------------------------------------------------------------- 对局 HUD（联机附加层）：暂停弹层 / 倒计时 / 超时
const PAUSE_CARD_W := 576.0
const PAUSE_CARD_H := 401.0

func _pause_modal_rect() -> Rect2:
	return Rect2((size.x - PAUSE_CARD_W) * 0.5, (size.y - PAUSE_CARD_H) * 0.5, PAUSE_CARD_W, PAUSE_CARD_H)

## 11 号暂停弹层的「继续游戏」按钮矩形：hud_base.pause_rect() 在暂停时把它并进命中区
func _pause_continue_rect() -> Rect2:
	var card := _pause_modal_rect()
	return Rect2(card.position.x + 40.0, card.position.y + 289.0, card.size.x - 80.0, 72.0)

## 暂停原因（联机：谁暂停了 / 等谁重连 / 等谁操作）
func _net_pause_reason_text() -> String:
	if net_session == null: return ""
	var by := ""
	var by_v = net_session.get("pause_by_nick")
	if by_v != null: by = str(by_v)
	var names: Array = []
	for s in net_session.waiting_seats:
		names.append(_net_seat_nick(int(s)))
	var who := "、".join(names)
	match str(net_session.pause_reason):
		"offline":
			if who != "": return "等待%s重连后继续。" % who
		"timeout":
			if who != "": return "等待%s操作后继续。" % who
		_:
			if by != "": return "由%s暂停了本局。" % by
	return ""

## 11 号暂停弹层（联机暂停/等待重连时盖在 HUD 上；按钮命中见 hud_base.pause_rect）
func _draw_pause_modal(font: Font) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.231, 0.2, 0.176, 0.4))
	var card := _pause_modal_rect()
	_fig_card(card, F_CARD, 24, true, true)
	var icon := Rect2(card.position.x + 252.0, card.position.y + 40.0, 72.0, 72.0)
	draw_style_box(_sb(F_GREEN_TINT, 24, 0, Color(0, 0, 0, 0)), icon)
	var ic: Vector2 = icon.position + icon.size * 0.5
	# 设计稿：18.7x24 细线双竖条（stroke 1.8），不要实心大绿块
	draw_line(Vector2(ic.x - 4.5, ic.y - 12.0), Vector2(ic.x - 4.5, ic.y + 12.0), F_GREEN, 3.2)
	draw_line(Vector2(ic.x + 4.5, ic.y - 12.0), Vector2(ic.x + 4.5, ic.y + 12.0), F_GREEN, 3.2)
	# 标题基线按设计 card.y+169；fw700 用 0.7px 双绘模拟
	var ty: float = card.position.y + 169.0
	_fig_text("游戏已暂停", card.position.x, ty, 34, F_INK, HORIZONTAL_ALIGNMENT_CENTER, card.size.x)
	_fig_text("游戏已暂停", card.position.x + 0.7, ty, 34, F_INK, HORIZONTAL_ALIGNMENT_CENTER, card.size.x)
	# 设计稿两行固定文案
	_fig_text("休息一下，棋盘会留在这里。", card.position.x, card.position.y + 210.0, 21, F_SUB,
		HORIZONTAL_ALIGNMENT_CENTER, card.size.x)
	_fig_text("当前回合与进度均已保留。", card.position.x, card.position.y + 242.0, 21, F_SUB,
		HORIZONTAL_ALIGNMENT_CENTER, card.size.x)
	# 第 3 行小字：暂停原因（谁暂停 / 等谁重连），没有具体原因时不显示
	var extra := _net_pause_reason_text()
	if extra != "":
		_fig_text(extra, card.position.x, card.position.y + 270.0, 17, F_SUB,
			HORIZONTAL_ALIGNMENT_CENTER, card.size.x)
	var br := _pause_continue_rect()
	_fig_card(br, F_GREEN, 16, false, true)
	var by: float = br.position.y + br.size.y * 0.5 + 8.0
	_fig_text("继续游戏", br.position.x, by, 24, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, br.size.x)
	_fig_text("继续游戏", br.position.x + 0.7, by, 24, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, br.size.x)

## 联机对局附加层：暂停弹层 / 恢复倒计时 / 超时提醒。
## 标题、回合条（含网络倒计时）、四角玩家卡、日志条、骰子行与底部按钮
## 已由 hud_base 的统一 HUD 按 09/10 布局画好，这里只补联机状态层（A 方案已去掉贴基地迷你头像）。
func _draw_net_hud() -> void:
	if net_role == "": return
	var font := ThemeDB.fallback_font
	# 暂停弹层由 hud_base 统一画（11 号弹层，联机/本地共用），这里只出恢复倒计时/超时提示
	if net_session != null and bool(net_session.paused): return
	if bool(get("local_paused")): return
	var msg := ""
	if net_resume_t > 0.0:
		msg = "%d 秒后继续…" % int(ceil(net_resume_t))
	elif int(_net_turn_over_s) >= 30:
		msg = "已超时 %d s · %d s 后自动暂停" % [int(_net_turn_over_s), int(net_turn_limit_s - _net_turn_over_s)]
	if msg == "": return
	var tw: float = font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x + 40.0
	var r := Rect2((size.x - tw) * 0.5, 164.0, tw, 30.0)
	draw_style_box(_sb(NT_WARM_BG, 15, 1, NT_WARM_LINE), r)
	draw_string(font, Vector2(r.position.x, r.position.y + 20.0), msg,
		HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 16, Color("#7a5a1f"))

# ================================================================
# 设置页里的昵称 / 头像编辑（复用联机大厅的昵称输入与 20 款头像弹窗）
#   覆盖 settings_hits / _click_settings / _draw_settings / close_settings：
#   弹层打开时命中优先给弹层，设置页保持打开，保存后资料卡即时刷新。
# ================================================================
func settings_hits() -> Array:
	if not settings_open: return []
	if net_nick_open:
		var ngeo := _net_nick_geo()
		return [
			{"r": ngeo["random"], "a": "nick_random"},
			{"r": ngeo["cancel"], "a": "nick_cancel"},
			{"r": ngeo["save"], "a": "nick_save"},
		]
	if net_avatar_picker_open:
		return _net_avatar_hits()
	var hits: Array = super.settings_hits()
	# 资料卡的头像/昵称入口优先（不在子页/确认弹窗时）
	if settings_sub == "" and settings_confirm == "":
		var geo := _settings_geo(Rect2(120.0, 0.0, 600.0, size.y) if settings_drawer else Rect2(0.0, 0.0, 720.0, size.y))
		var extra: Array = [
			{"r": geo["avatar_edit"], "a": "settings_avatar"},
			{"r": geo["nick_edit"], "a": "settings_nick"},
		]
		hits = extra + hits
	return hits

func _click_settings(pos: Vector2) -> void:
	if not settings_open: return
	# 昵称 / 头像弹层打开时，点击只作用于弹层
	if net_nick_open or net_avatar_picker_open:
		for h in settings_hits():
			if not (h.r as Rect2).has_point(pos): continue
			var a := str(h.a)
			match a:
				"nick_random":
					if _net_nick_edit != null:
						_net_nick_edit.text = net_random_nickname()
						_net_nick_edit.select_all()
				"nick_cancel":
					_net_close_nick_edit()
				"nick_save":
					_net_nick_save()
				"avatar_close":
					net_avatar_picker_open = false
				_:
					if a.begins_with("avatar_pick_"):
						_net_set_avatar(int(a.substr(12)))
			queue_redraw()
			return
		return
	# 资料卡入口：打开弹层但不关闭设置页
	for h in settings_hits():
		if not (h.r as Rect2).has_point(pos): continue
		var a2 := str(h.a)
		if a2 == "settings_avatar":
			net_avatar_picker_open = true
			queue_redraw()
			return
		if a2 == "settings_nick":
			_net_open_nick_edit()
			return
	super._click_settings(pos)

func _draw_settings() -> void:
	super._draw_settings()
	if not settings_open: return
	if net_avatar_picker_open or net_nick_open:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
		if net_avatar_picker_open:
			_draw_net_avatar_picker(_fig_font())
		if net_nick_open:
			_draw_net_nick(_fig_font())

func close_settings() -> void:
	if net_nick_open: _net_close_nick_edit()
	net_avatar_picker_open = false
	super.close_settings()

