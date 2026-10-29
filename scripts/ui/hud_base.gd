extends "res://scripts/anim/anim_base.gd"
## 结算称号：flow 层算好后放这里，_draw_result 直接画（本模块不依赖 flow）
var result_titles := {}
## ============================================================
## HUD 基类（方案 1 · 批次 5）：底栏/信息面板/战报/结算弹窗/骰子绘制/粒子推进
##   继承链：screens_base ← render_base ← item_bar_base ← pieces_base ← anim_base ← hud_base ← game_main
## ============================================================


func _draw_play() -> void:
	layout()
	if board_tex != null:
		draw_texture_rect(board_tex, Rect2(board_origin, Vector2(BOARD_UNITS, BOARD_UNITS) * board_scale), false)
	_draw_tele_fx()
	_draw_launch_points()
	_draw_pieces()
	_draw_title_floats()
	_draw_board_toast()
	_draw_hud()
	if back_dialog != "":
		_draw_back_dialog()

func _tick_particles(delta: float) -> void:
	if eparts.is_empty() and energy_hold.is_empty() and epar_wait.is_empty() 			and gain_texts.is_empty() and gain_pending.is_empty(): return
	if screen != Scr.PLAY: return   # 弹窗/菜单期间不要强制重绘
	# ★ 弹窗/过渡遮罩期间隐藏粒子层：子 CanvasItem 画在父 _draw 之后，否则粒子会盖在弹窗上面
	if particle_layer != null:
		# ★ 这两块也是全屏浮层，同样要挡住粒子层：道具长按说明（_draw_item_tip）
		#   与选点数面板（_draw_dice_picker）—— 原来只挡了结算/规则/过渡。
		var hide_pl: bool = show_result or rules_open or trans_t > 0.0 or item_tip_id != "" or pick_dice_kind != ""
		if particle_layer.visible == hide_pl: particle_layer.visible = not hide_pl
	# ★ 原地压缩，避免每帧新建数组（25 个粒子 × 每帧一次分配会在踩子时造成 GC 抖动）
	var was_full: bool = not eparts.is_empty()   # 压缩前是否有粒子（D3）
	var w := 0
	for i in eparts.size():
		var p: Dictionary = eparts[i]
		p["t"] = float(p.t) + delta
		if float(p.t) < float(p.sd) + float(p.get("dl", 0.0)) + float(p.fd):
			if w != i: eparts[w] = p
			w += 1
	if w != eparts.size(): eparts.resize(w)
	# 粒子在飞就必须持续重绘，否则动画播完后会冻住
	# ★ 变空的那一帧也要重绘一次：ParticleLayer 是保留模式 CanvasItem，不重绘就永远定格
	var had_parts: bool = not eparts.is_empty()
	if (had_parts or was_full) and particle_layer != null: particle_layer.queue_redraw()
	# 错峰待发的粒子束（撞叠子逐颗 CRASH_ENERGY_DELAY）
	if not epar_wait.is_empty():
		var keep: Array = []
		for wq in epar_wait:
			wq["t"] = float(wq.t) - delta
			if float(wq.t) <= 0.0:
				_spawn_energy_particles(wq.from, int(wq.player), int(wq.amount))
			else:
				keep.append(wq)
		epar_wait = keep
	# ★「+N」飘字：该玩家的粒子/待发束都清干净了才弹（参考是 updateEnergyBar 的回调里弹）
	if not gain_pending.is_empty():
		var busy := {}
		for p in eparts: busy[int(p.get("p", 0))] = true
		for sg in seq:
			if sg.has("epar"): busy[int((sg["epar"] as Dictionary).get("player", 0))] = true
		for wq in epar_wait: busy[int(wq.get("player", 0))] = true
		for gp in gain_pending.keys():
			if busy.has(int(gp)): continue
			gain_texts.append({"t": 0.0, "amount": int(gain_pending[gp]), "player": int(gp)})
			gain_pending.erase(gp)
	if not gain_texts.is_empty():
		var gkeep: Array = []
		for gt in gain_texts:
			gt["t"] = float(gt.t) + delta
			if float(gt.t) < 1.0: gkeep.append(gt)
		gain_texts = gkeep
		if particle_layer != null: particle_layer.queue_redraw()
	# 某个玩家的粒子全部落地了 -> 解除 hold，积分条这才开始涨（参考的 updateEnergyBar 回调）
	if not energy_hold.is_empty():
		var still := {}
		for p in eparts:
			still[int(p.get("p", 0))] = true
		# ★ 还要看【还没开播】的粒子段：epar 要等对应动画段开播才发粒子，
		#   在那之前 eparts 是空的 —— 只看 eparts，解析期按下的 hold 会在【下一帧】就被解掉，
		#   而粒子要等 0.3~0.9s 后才生成 -> 积分条先涨，正是这段 hold 要防的「条先涨、粒子后到」。
		for sg in seq:
			if sg.has("epar"):
				still[int((sg["epar"] as Dictionary).get("player", 0))] = true
		for wq in epar_wait:
			still[int(wq.get("player", 0))] = true
		for pid_h in energy_hold.keys():
			if not still.has(int(pid_h)):
				energy_hold.erase(pid_h)
				queue_redraw()

# ============================================================
# Figma A 方案 · 局内 HUD（联机 + 本地共用一套 720x1280 布局）
#   顶部标题 / 回合条 / 四角玩家卡（红左上·绿右上·蓝左下·橙右下）
#   底部日志条（道具模式换成道具栏）/ 骰子行 / 掷骰按钮 / 横向菜单按钮
#   数据源：联机读 net_lobby（昵称/头像/完成度），本地读 st + humans。
#   几何契约见 _incoming/figma-ai/HUD_GEOMETRY.md（screens_base 已固定，不改）。
# ============================================================
const HUD_SIDE := {1: "绿方", 2: "橙方", 3: "蓝方", 4: "红方"}
## 设计稿玩家色（头像底/高亮；棋盘棋子仍用 cols）
const HUD_PC := {1: Color("#8FD0A0"), 2: Color("#F3B98C"), 3: Color("#9CC3E8"), 4: Color("#F0A3A3")}
## 深色版玩家色（回合条文字/当前玩家描边）
const HUD_DEEP := {1: Color("#2F7D4F"), 2: Color("#B7791F"), 3: Color("#4777C5"), 4: Color("#C0453C")}
var hud_game_start_ms := 0     # 本局开始时刻（结算「用时」；start_game 不在本文件，懒初始化）
var hud_time_offset_ms := 0    # 结算「用时」的额外偏移（调试/截图用；正常对局恒为 0）
var local_paused := false      # 本地对局暂停（联机用 net_session.paused；本地单机用这个）

## 当前是否处于暂停态（联机暂停 / 本地暂停）
func _hud_pause_active() -> bool:
	if net_ui_active: return net_session != null and bool(net_session.paused)
	return local_paused

## 本地暂停/继续（flow_base 的暂停按钮点击分支调用；联机走 _net_toggle_pause）
func _hud_toggle_local_pause() -> void:
	local_paused = not local_paused
	queue_redraw()

func _draw_hud() -> void:
	var font := _fig_font()
	_hud_mark_game_start()
	_hd_observe()          # 第二批：道具弹层/多面骰结果/盲盒/传送门自动触发 + 状态清理
	# 用户反馈 B：局内不再显示顶部「极简飞行棋」标题与右上模式标签
	_draw_hud_turn_bar(font)
	_draw_hud_player_cards(font)
	# 底部信息条：道具模式用道具栏，否则画日志条
	if bool(st.get("skillMode", false)):
		_draw_item_bar()
	else:
		_draw_hud_log_strip(font)
	# 骰子行：传送门选格时改用「取消选择/确认目标格」两按钮（设计 02g）
	if _hd_teleport_pending():
		_draw_hd_teleport_overlay(font)
	else:
		_draw_hud_dice_row(font)
	_draw_hud_bottom_buttons(font)
	if bool(st.get("skillMode", false)):
		_draw_hd_balance_pill(font)
	# 浮层/反馈
	_draw_hud_gain_texts(font)
	_draw_hud_round_toast(font)
	# 第二批：全局 toast（03e 称号获得等）—— 在 HUD 之上、弹层之下；持续淡出
	if titles_toast != "" and Time.get_ticks_msec() - titles_toast_ms < 2800:
		queue_redraw()
	_draw_global_toasts()
	# 顶部 toast / 联机倒计时提示：画在弹层遮罩【之下】，避免弹窗打开时顶部出现「遮罩漏光」
	if net_ui_active: _draw_net_hud()      # 联机：恢复倒计时 / 超时提醒
	_draw_hd_toasts(font)                  # 第二批顶部 toast（自动消失）
	_draw_item_tip()
	if pick_dice_kind != "": _draw_dice_picker()
	_draw_hd_item_dialogs(font)   # 购买确认 / 使用确认 / 多面骰结果 / 盲盒开箱 / 通用错误框
	if _hud_pause_active(): _draw_pause_modal(font)   # 11 号暂停弹层（联机暂停 / 本地暂停共用）
	if show_result: _draw_result()
	if rules_open: _draw_rules()
	# 胜利横幅（结算页打开前；等动画排空再出，别盖住最后一段飞行；弹层期间不画）
	if st.winner != null and not show_result and not rules_open and not _hud_pause_active() and seq.is_empty():
		var sz := size
		var w := int(st.winner)
		# 1280 保持设计稿 34% 位置；高屏按真实高度居中
		var by: float = sz.y * 0.34 if sz.y <= 1280.0 else (sz.y - 180.0) * 0.5
		draw_rect(Rect2(0, by, sz.x, 180), Color(0, 0, 0, 0.84))
		draw_string(font, Vector2(0, by + 72), "%s 获胜！" % _hud_player_name(w),
			HORIZONTAL_ALIGNMENT_CENTER, sz.x, 52, cols.get(w, Color.WHITE))
		draw_string(font, Vector2(0, by + 132), "点击任意处查看结算",
			HORIZONTAL_ALIGNMENT_CENTER, sz.x, 26, Color("#9fb0cc"))

## 统一文本绘制：bold 用 0.7px 重绘模拟粗体（Godot 回退字体没有粗体字重）
func _hud_str(txt: String, x: float, baseline: float, fs: int, col: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, w: float = -1.0,
		bold := false) -> void:
	var f := _fig_font()
	draw_string(f, Vector2(x, baseline), txt, align, w, fs, col)
	if bold:
		draw_string(f, Vector2(x + 0.7, baseline), txt, align, w, fs, col)

## 单行超宽截断（补 …）：Figma 卡片宽度固定，长昵称/战报不能压到相邻元素
func _hud_fit(txt: String, fs: int, max_w: float) -> String:
	var f := _fig_font()
	if f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w: return txt
	var out := txt
	while out.length() > 1 and f.get_string_size(out + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
		out = out.substr(0, out.length() - 1)
	return out + "…"

func _hud_elapsed_text() -> String:
	if hud_game_start_ms <= 0: return "--:--"
	var secs: int = maxi(0, (Time.get_ticks_msec() - hud_game_start_ms + hud_time_offset_ms) / 1000)
	return "%d:%02d" % [secs / 60, secs % 60]

## 本局开始时刻：start_game 在 flow 层（不在本次改动范围），这里在对局首帧懒初始化；
## 新局（第 1 回合、还没掷过骰子）时重置。
func _hud_mark_game_start() -> void:
	if st.is_empty(): return
	if hud_game_start_ms <= 0 or (hud_round <= 1 and int(st.get("turn", 0)) <= 1 and last_dice == 0):
		hud_game_start_ms = Time.get_ticks_msec()

func _hud_mode_name() -> String:
	if happy_mode and item_mode: return "欢乐＋道具"
	if happy_mode: return "欢乐"
	if item_mode: return "道具"
	return "经典"

func _hud_seat_count() -> int:
	var n: int = (st.get("order", []) as Array).size()
	return n if n > 0 else seats().size()

func _hud_mode_label() -> String:
	var n := _hud_seat_count()
	var who := "四人"
	if n == 2: who = "双人"
	elif n == 3: who = "三人"
	return "%s对局 · %s" % [who, _hud_mode_name()]

func _hud_mode_summary() -> String:
	var n := _hud_seat_count()
	var who := "四人"
	if n == 2: who = "双人"
	elif n == 3: who = "三人"
	return "%s · %s" % [who, _hud_mode_name()]

# ---------------------------------------------------------------- 玩家数据（联机 / 本地两种来源）
func _hud_col(pid: int) -> Color:
	return HUD_PC.get(pid, cols.get(pid, Color("#8FD0A0")))

func _hud_deep(pid: int) -> Color:
	return HUD_DEEP.get(pid, F_GREEN)

func _hud_player_name(pid: int) -> String:
	if net_ui_active: return _net_seat_nick(pid)
	return "玩家%d" % pid

func _hud_player_avatar(pid: int) -> int:
	if net_ui_active: return _net_seat_avatar(pid)
	return ((pid - 1) % 20) + 1

## 本机玩家（本地：所有人类座位；联机：本地座位）
func _hud_is_local_player(pid: int) -> bool:
	if net_ui_active: return pid == int(net_local_seat)
	return humans.has(pid)

func _hud_fin(pid: int) -> Dictionary:
	var tot := 4
	var fin := 0
	if st.has("players") and st.players.has(pid):
		var cs: Array = st.players[pid].chesses
		tot = cs.size()
		for c in cs:
			if bool((c as Dictionary).get("finished", false)): fin += 1
	return {"fin": fin, "tot": tot}

func _hud_defeats(pid: int) -> int:
	if st.has("players") and st.players.has(pid):
		var pl: Dictionary = st.players[pid]
		return int(pl.get("defeats", 0))
	return 0

## 完成度前缀：联机「我/电脑/离线」、本地「我/本地/电脑」（对应 Figma 4P 卡的第三行）
func _hud_sub_prefix(pid: int) -> String:
	if net_ui_active:
		if pid == int(net_local_seat): return "我"
		if _net_seat_kind(pid) == "ai": return "电脑"
		if not _net_seat_online(pid): return "离线"
		return ""
	if humans.has(pid):
		return "我" if humans.size() <= 1 else "本地"
	return "电脑"

## 玩家卡第二行：完成度 + 击败数（A 方案不再在棋盘上画击败矩阵，数据压缩进卡片）
func _hud_sub_text(pid: int) -> String:
	var fin := _hud_fin(pid)
	var pre := _hud_sub_prefix(pid)
	var txt := ""
	if pre != "": txt = pre + " · "
	txt += "完成 %d / %d" % [int(fin.fin), int(fin.tot)]
	var df := _hud_defeats(pid)
	if df > 0: txt += " · 击败 %d" % df
	return txt

# ---------------------------------------------------------------- 四角玩家卡（按座位固定角：4 红左上 / 1 绿右上 / 3 蓝左下 / 2 橙右下）
func _hud_card_corner(pid: int) -> int:
	match pid:
		4: return 0
		1: return 1
		3: return 2
		2: return 3
	return 2

## 道具模式设计版式（item_bar 在 933、142 高）时，下排玩家卡上移让位
## 道具模式设计版式判定：只看道具栏高度，不依赖绝对 y（720x1600 下 item_bar 会随 extra 下移）
func _hd_item_layout() -> bool:
	return bool(st.get("skillMode", false)) and item_bar_rect().size.y >= 100.0

func _hud_avatar_center(pid: int) -> Vector2:
	var corner := _hud_card_corner(pid)
	var pd := play_dy()
	# 道具模式：上排卡下移、下排卡上移，四角向棋盘靠拢
	if _hd_item_layout():
		match corner:
			0: return Vector2(68.0, 206.0 + pd)
			1: return Vector2(652.0, 206.0 + pd)
			2: return Vector2(68.0, 888.0 + pd)
		return Vector2(652.0, 888.0 + pd)
	match corner:
		0: return Vector2(68.0, 194.0 + pd)
		1: return Vector2(652.0, 194.0 + pd)
		2: return Vector2(68.0, 926.0 + pd)
	return Vector2(652.0, 926.0 + pd)

## 头像半径：四角统一 28（上/下排一致；道具模式也保持同样大小）
func _hud_avatar_r(pid: int) -> float:
	return 28.0

## 画头像：设计稿浅色底 + 白色表情贴图 + 描边（白色=普通 / 深色=当前玩家 / 绿色=本机）
func _hud_avatar_at(c: Vector2, r: float, pid: int, ring: Color, ring_w: float,
		bg: Color = Color(0, 0, 0, 0)) -> void:
	var base: Color = _hud_col(pid) if bg.a <= 0.0 else bg
	draw_circle(c, r, base)
	var tex := _net_avatar_texture(_hud_player_avatar(pid))
	if tex != null:
		var ir: float = r * 0.82
		draw_texture_rect(tex, Rect2(c - Vector2(ir, ir), Vector2(ir, ir) * 2.0), false)
	draw_arc(c, r, 0.0, TAU, 40, ring, ring_w, true)

## 道具模式的积分小徽章（A 方案不再在棋盘上画积分条，数值收进玩家卡）
func _draw_hud_energy_badge(c: Vector2, val: int, col: Color) -> void:
	draw_circle(c + Vector2(0.0, 1.0), 15.0, Color(0, 0, 0, 0.10))
	draw_circle(c, 14.0, col)
	draw_arc(c, 14.0, 0.0, TAU, 28, Color(1, 1, 1, 0.9), 1.5, true)
	_hud_str(str(val), c.x - 14.0, c.y + 5.0, 13, Color.WHITE,
		HORIZONTAL_ALIGNMENT_CENTER, 28.0, true)

func _draw_hud_player_cards(font: Font) -> void:
	var order: Array = st.get("order", [])
	var cur := int(st.get("currentPlayer", hud_cur))
	for pv in order:
		_draw_hud_one_card(font, int(pv), int(pv) == cur)

func _draw_hud_one_card(font: Font, pid: int, is_cur: bool) -> void:
	var c := _hud_avatar_center(pid)
	var col := _hud_col(pid)
	var deep := _hud_deep(pid)
	var me := _hud_is_local_player(pid)
	var online := true
	if net_ui_active: online = _net_seat_online(pid)
	var r := _hud_avatar_r(pid)
	# 当前玩家：柔和外圈光晕（Figma 玩家卡高亮）
	if is_cur:
		draw_circle(c, r + 6.0, Color(col.r, col.g, col.b, 0.20))
	# 描边：本机绿 3px / 当前玩家深色 3px / 普通白色 2px / 离线灰
	var ring := Color(1, 1, 1, 0.95)
	var ring_w := 2.0
	var bg := Color(0, 0, 0, 0)
	if me:
		ring = F_GREEN
		ring_w = 3.0
	elif is_cur:
		ring = deep
		ring_w = 3.0
	if not online:
		ring = Color("#C9C9C9")
		ring_w = 2.0
		bg = col.lerp(Color("#C9C9C9"), 0.65)
	_hud_avatar_at(c, r, pid, ring, ring_w, bg)
	if bool(st.get("skillMode", false)) and online:
		_draw_hd_avatar_badges(c, r, pid, deep)
	var corner := _hud_card_corner(pid)
	var right_side: bool = corner == 1 or corner == 3
	var top_side: bool = corner <= 1
	var item_layout := _hd_item_layout()
	var compact: bool = (not top_side) and item_layout
	var pd := play_dy()
	var name_base := ((204.0 if item_layout else 192.0) if top_side else (886.0 if compact else 924.0)) + pd
	var sub_base := ((226.0 if item_layout else 214.0) if top_side else (908.0 if compact else 946.0)) + pd
	var tx := 392.0 if right_side else 108.0
	var tw := 220.0
	var align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_RIGHT if right_side else HORIZONTAL_ALIGNMENT_LEFT
	var nm := _hud_fit("%s · %s" % [_hud_player_name(pid), str(HUD_SIDE.get(pid, ""))], 21, tw)
	_hud_str(nm, tx, name_base, 21, deep if is_cur else F_INK, align, tw)
	_hud_str(_hud_fit(_hud_sub_text(pid), 16, tw), tx, sub_base, 16, F_SUB, align, tw)

# ---------------------------------------------------------------- 顶部标题 + 回合条
func _draw_hud_title(font: Font) -> void:
	_hud_str("极简飞行棋", 40.0, 64.0, 28, F_INK, HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
	_hud_str(_hud_fit(_hud_mode_label(), 18, 300.0), 380.0, 62.0, 18, F_SUB,
		HORIZONTAL_ALIGNMENT_RIGHT, 300.0)

func _hud_turn_right_text() -> String:
	var rt := "第 %d 回合" % int(st.get("round", hud_round))
	if st.get("winner") != null: return rt
	if _hud_pause_active(): return "已暂停"
	if not net_ui_active or net_session == null: return rt
	if net_resume_t > 0.0: return "%d 秒后继续…" % int(ceil(net_resume_t))
	if int(_net_turn_over_s) >= 30:
		return "超时 %d s" % int(_net_turn_over_s)
	var remain := maxf(0.0, net_turn_limit_s - maxf(0.0, float(_net_turn_over_s)))
	var secs := int(round(remain))
	return "第 %d 回合 · %d:%02d" % [int(st.get("round", hud_round)), secs / 60, secs % 60]

func _draw_hud_turn_bar(font: Font) -> void:
	var cur := int(st.get("currentPlayer", hud_cur))
	var ccol := _hud_col(cur)
	var deep := _hud_deep(cur)
	var bar := Rect2(40.0, 92.0, 640.0, 56.0)
	draw_style_box(_sb(ccol.lerp(Color.WHITE, 0.86), 16, 1, F_LINE), bar)
	draw_circle(Vector2(bar.position.x + 20.0, bar.position.y + 28.0), 6.0, ccol)
	var msg := ""
	var winner = st.get("winner")
	if winner != null:
		deep = _hud_deep(int(winner))
		msg = "本局已结束 · %s 获胜" % _hud_player_name(int(winner))
	elif _hud_is_local_player(cur):
		msg = "轮到你，%s" % _hud_player_name(cur)
	else:
		msg = "轮到 %s" % _hud_player_name(cur)
	if _hd_teleport_pending() and hd_tele_ready:
		msg = "传送门 · 请选择目标格"
		deep = F_GREEN
	var right := _hud_turn_right_text()
	var f := _fig_font()
	var rw: float = f.get_string_size(right, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x + 6.0
	var avail: float = maxf(80.0, bar.size.x - 42.0 - rw - 20.0)
	_hud_str(_hud_fit(msg, 23, avail), bar.position.x + 42.0, bar.position.y + 37.0, 23, deep,
		HORIZONTAL_ALIGNMENT_LEFT, avail)
	_hud_str(right, bar.end.x - 20.0 - rw, bar.position.y + 35.0, 17, deep,
		HORIZONTAL_ALIGNMENT_LEFT, rw)

# ---------------------------------------------------------------- 底部日志条（时钟图标 + 最新一条战报）
func _hud_latest_log_segs() -> Array:
	if log_lines.is_empty(): return []
	var e: Dictionary = log_lines[log_lines.size() - 1]
	var segs: Array = []
	var pid := int(e.get("p", 0))
	if pid > 0:
		segs.append(["%s（%s）" % [_hud_player_name(pid), str(HUD_SIDE.get(pid, ""))], _hud_deep(pid)])
	var body := ""
	if e.has("v"):
		# 设计稿措辞：阿宁（蓝方）掷出 3 点（底层文案是「摇到了 3 点」）
		body = "掷出 %d 点" % int(e.get("v", 0))
	elif e.has("ks"):
		for k2 in (e["ks"] as Array):
			var a2: Dictionary = ACT.get(str(k2), {})
			body += str(a2.get("t", str(k2)))
	else:
		for key in ["t", "t2", "t3"]:
			body += str(e.get(key, ""))
	var kk := str(e.get("k", ""))
	if kk != "" and ACT.has(kk):
		body += str((ACT[kk] as Dictionary).get("t", ""))
	if body == "": body = "……"
	segs.append([body, F_SUB])
	return segs

func _draw_hud_log_strip(font: Font) -> void:
	var r := panel_rect()
	_fig_card(r, F_CARD, 16, true, false)
	_fig_icon("clock", Vector2(r.position.x + 27.0, r.position.y + r.size.y * 0.5), 11.0, F_SUB)
	var x: float = r.position.x + 50.0
	var maxx: float = r.end.x - 20.0
	var base: float = r.position.y + 34.0
	var segs := _hud_latest_log_segs()
	if segs.is_empty():
		var cur0 := int(st.get("currentPlayer", 1))
		_hud_str(_hud_fit("对局开始，等待%s掷骰…" % _hud_player_name(cur0), 18, maxx - x),
			x, base, 18, F_SUB)
		return
	for sg in segs:
		var txt := str(sg[0])
		var col: Color = sg[1]
		if txt == "": continue
		var tw: float = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		if x + tw > maxx:
			var room: float = maxx - x
			if room > 12.0:
				_hud_str(_hud_fit(txt, 18, room), x, base, 18, col)
			break
		_hud_str(txt, x, base, 18, col)
		x += tw

# ---------------------------------------------------------------- 骰子行 + 大号「掷骰子」按钮
func _hud_dice_hint() -> String:
	if not settings_hints: return ""
	if st.get("winner") != null: return "本局已结束，点棋盘查看结算"
	if _hud_pause_active(): return "本局已暂停"
	if dice_anim > 0.0: return "摇骰中…"
	var cur := int(st.get("currentPlayer", hud_cur))
	if not humans.has(cur) or (net_ui_active and cur != int(net_local_seat)):
		return "等待 %s 行动…" % _hud_player_name(cur)
	if str(st.get("phase", "")) == "selecting": return "选择要移动的棋子"
	return "掷骰后选择可移动棋子"

func _hud_can_roll() -> bool:
	if st.is_empty() or st.get("winner") != null: return false
	if _hud_pause_active(): return false
	if net_ui_active and net_session != null and bool(net_session.reconnecting): return false
	if net_resume_t > 0.0: return false
	if dice_anim > 0.0 or not seq.is_empty(): return false
	if str(st.get("phase", "")) != "rolling": return false
	var cur := int(st.get("currentPlayer", 0))
	if not humans.has(cur): return false
	if net_ui_active and cur != int(net_local_seat): return false
	return true

func _hud_roll_button_text(enabled: bool) -> String:
	if enabled: return "掷骰子"
	if st.get("winner") != null: return "已结束"
	if _hud_pause_active(): return "已暂停"
	if dice_anim > 0.0: return "掷骰中…"
	var cur := int(st.get("currentPlayer", hud_cur))
	if not _hud_is_local_player(cur): return "等待…"
	return "掷骰子"

func _draw_hud_roll_button(font: Font) -> void:
	var rr := roll_button_rect()
	var enabled := _hud_can_roll()
	var bg: Color = F_GREEN if enabled else Color("#EFECE7")
	_fig_card(rr, bg, 16, false, enabled)
	var tc: Color = Color.WHITE if enabled else F_MUTED
	var fs_r: int = 24 if rr.size.y >= 66.0 else 22
	_hud_str(_hud_roll_button_text(enabled), rr.position.x,
		rr.position.y + rr.size.y * 0.5 + float(fs_r) * 0.34, fs_r, tc,
		HORIZONTAL_ALIGNMENT_CENTER, rr.size.x, true)

func _draw_hud_dice_row(font: Font) -> void:
	# 几何完全由 screens_base 提供（普通 / item-mode 两套分支）
	var dr := dice_rect()
	_fig_card(dr, F_CARD, 16, true, true)
	var d: int = dice_shown if dice_anim > 0.0 else last_dice
	var shake_off := Vector2(sin(dice_shake * TAU * 8.0), 0.0) * (3.0 if dice_shake > 0.0 else 0.0)
	var dow: int = hud_cur if hud_cur > 0 else int(st.get("currentPlayer", 1))
	var dcol: Color = DICE_COLS.get(dow, cols.get(dow, Color.WHITE))
	var pulse := 1.0
	if dice_anim > 0.0:
		var ph: float = fmod(dice_anim, 0.15) / 0.15
		pulse = 1.0 + 0.1 * (1.0 - absf(ph * 2.0 - 1.0))
		dcol.a = 0.7 + 0.3 * absf(ph * 2.0 - 1.0)
	if dice_penalty > 0.0:
		dcol = Color(242.0 / 255.0, 47.0 / 255.0, 47.0 / 255.0, 0.95)
	# 用户反馈 B：道具模式的骰子卡去掉留白，让骰子铺满卡片
	# 用户反馈 P1：所有对局 HUD 的骰子都要铺满卡片（96 卡 → 80px 骰子，保留 8px 边距）
	var drad: float = dr.size.x * (0.44 if bool(st.get("skillMode", false)) else 0.42)
	_draw_dice(dr.position + dr.size * 0.5 + shake_off, drad * pulse, d, dcol)
	# 文案：上次点数 + 操作提示（基线随卡片高度自适应 96 / 78）
	var tx: float = dr.end.x + 20.0
	var first := "尚未掷骰"
	if last_dice > 0: first = "上次点数 · %d" % last_dice
	_hud_str(first, tx, dr.position.y + dr.size.y * 0.43, 16, F_SUB)
	_hud_str(_hud_fit(_hud_dice_hint(), 20, 330.0), tx, dr.position.y + dr.size.y * 0.71, 20,
		F_INK, HORIZONTAL_ALIGNMENT_LEFT, 330.0, true)
	_draw_hud_roll_button(font)

# ---------------------------------------------------------------- 底部横向菜单按钮（规则 / 结算 / 暂停）
func _draw_hud_bottom_buttons(font: Font) -> void:
	var names: Array = ["游戏规则", "结算游戏", "继续" if _hud_pause_active() else "暂停"]
	var brs := _bottom_btn_rects()
	for i in names.size():
		var r: Rect2 = brs[i]
		if r.size.x <= 0.0: continue
		var is_pause: bool = i == 2
		_fig_card(r, F_CARD, 16, true, false)
		_hud_str(str(names[i]), r.position.x, r.position.y + r.size.y * 0.5 + 7.0, 21,
			F_GREEN if is_pause else F_INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

## A 方案：积分条不再画在棋盘上；能量粒子仍需要落点目标 —— 指向该玩家卡头像。
func energy_bar_rect(pid: int) -> Rect2:
	if bool(st.get("skillMode", false)):
		var c := _hud_avatar_center(pid)
		return Rect2(c - Vector2(4.0, 4.0), Vector2(8.0, 8.0))
	return super.energy_bar_rect(pid)

## HUD：积分「+N」飘字（A 方案不再画棋盘积分条，飘字浮在该玩家头像上方）
func _draw_hud_gain_texts(font: Font) -> void:
	if gain_texts.is_empty(): return
	var gt: Dictionary = gain_texts[0]
	var gt_t: float = clampf(float(gt.t), 0.0, 1.0)
	var g_alpha := 1.0
	var g_dy := 0.0
	var g_sc := 1.0
	if gt_t < 0.2:
		var gk: float = gt_t / 0.2
		g_alpha = gk
		g_dy = 20.0 * (1.0 - gk)
		g_sc = 0.5 + 0.7 * gk
	else:
		var gk2: float = (gt_t - 0.2) / 0.8
		g_alpha = 1.0 - gk2
		g_dy = -20.0 * gk2
		g_sc = 1.2
	var gp2 := int(gt.player)
	var c := _hud_avatar_center(gp2)
	var gcol: Color = _hud_deep(gp2)
	gcol.a = g_alpha
	var gtxt := "+%d" % int(gt.amount)
	var gfs: int = int(26.0 * g_sc)
	var gtw: float = font.get_string_size(gtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, gfs).x
	var gx: float = c.x - gtw * 0.5
	# 上排卡片往下飘（别顶到回合条），下排卡片往上飘（别压到日志条）
	var gy: float = (c.y + 64.0 if _hud_card_corner(gp2) <= 1 else c.y - 64.0) + g_dy + gfs * 0.35
	gx = clampf(gx, 6.0, size.x - gtw - 6.0)
	draw_style_box(_sb(Color(1, 1, 1, 0.95 * g_alpha), 9, 1.4,
		Color(gcol.r, gcol.g, gcol.b, 0.9 * g_alpha)),
		Rect2(gx - 7.0, gy - gfs + 2.0, gtw + 14.0, gfs + 6.0))
	var gtxt_col := gcol
	gtxt_col.a = clampf(g_alpha * 1.35, 0.0, 1.0)
	_hud_str(gtxt, gx, gy, gfs, gtxt_col)

## HUD：回合结算横幅（顶部居中，2.2s 淡出；放在回合条与棋盘之间的空白区）
func _draw_hud_round_toast(font: Font) -> void:
	if round_toast_t <= 0.0: return
	var ta: float = clampf(round_toast_t / 0.4, 0.0, 1.0)
	var tw2: float = minf(size.x - 80.0, 420.0)
	var tx2: float = (size.x - tw2) * 0.5
	draw_style_box(_sb(Color(0.13, 0.18, 0.23, 0.85 * ta), 17), Rect2(tx2, 248.0, tw2, 34.0))
	_hud_str(_hud_fit(round_toast, 16, tw2 - 28.0), tx2, 271.0, 16,
		Color(1, 1, 1, 0.96 * ta), HORIZONTAL_ALIGNMENT_CENTER, tw2)

## HUD 左下信息面板里的战报列表（旧版；A 方案改由 _draw_hud_log_strip 显示最新一条）

func _draw_hud_log(panel: Rect2, font: Font) -> void:
	var avail_h: float = panel.size.y - 56.0 - 8.0
	var yy := panel.position.y + 56.0
	var show_from: int = log_lines.size()
	var used_h := 0.0
	for i in range(log_lines.size() - 1, -1, -1):
		var hh1: float = float(_log_rows(log_lines[i])) * ROW_H
		if used_h + hh1 > avail_h: break
		used_h += hh1
		show_from = i
	for i in range(show_from, log_lines.size()):
		_draw_log(yy, log_lines[i])
		yy += float(_log_rows(log_lines[i])) * ROW_H
	# ★ 结算弹窗一出来，胜利横幅就收掉，否则一直遮着结算框（用户反馈）
	# ★ 等动画队列排空再显示横幅：st.winner 是【整批终态】，比动画早一整批，
	#   否则最后 0.5s 的制胜飞行会被 180px 高的黑带遮住（参考 end 事件在流末尾）。
func _draw_dice(c: Vector2, r: float, v: int, col: Color = Color("#f2f4f8")) -> void:
	var box := Rect2(c - Vector2(r, r), Vector2(r * 2, r * 2))
	draw_style_box(_sb(col, int(r * 0.35)), box)
	if v < 1:
		draw_string(ThemeDB.fallback_font, Vector2(c.x - 12, c.y + 16), "?",
			HORIZONTAL_ALIGNMENT_CENTER, 24, 48, Color(C_INK.r, C_INK.g, C_INK.b, 0.35))
		return
	# ★ 多面骰 7~12 点：参考用的是【数字牌】而不是点阵
	#   （skillManager.js:1044-1050 + style.css:1201-1259）。
	#   原来 `v < 1 or v > 6` 一律画「?」—— 玩家花 50 分买多面骰，掷出 7~12 时【看不到点数】。
	if v > 6:
		var fs_d := int(r * 1.15)
		draw_string(ThemeDB.fallback_font, Vector2(c.x - r, c.y + fs_d * 0.36), str(v),
			HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, fs_d, Color(0.10, 0.13, 0.19))
		return
	var pips := {
		1: [Vector2(0,0)], 2: [Vector2(-1,-1), Vector2(1,1)],
		3: [Vector2(-1,-1), Vector2(0,0), Vector2(1,1)],
		4: [Vector2(-1,-1), Vector2(1,-1), Vector2(-1,1), Vector2(1,1)],
		5: [Vector2(-1,-1), Vector2(1,-1), Vector2(0,0), Vector2(-1,1), Vector2(1,1)],
		6: [Vector2(-1,-1), Vector2(1,-1), Vector2(-1,0), Vector2(1,0), Vector2(-1,1), Vector2(1,1)],
	}
	for p in pips[v]:
		draw_circle(c + p * r * 0.52, r * 0.15, Color(0.10, 0.13, 0.19))

# ---------------------------------------------------------------- 输入
func _log_cache(e: Dictionary) -> Dictionary:
	var px := panel_rect()
	var w := px.size.x
	var c: Dictionary = e.get("_cache", {})
	if not c.is_empty() and absf(float(c.get("w", -1.0)) - w) < 0.5: return c
	var font := ThemeDB.fallback_font
	var fs := 16
	var maxx: float = px.end.x - 8.0
	var x: float = px.position.x + 6.0
	var segs2 := _merge_single_char_segs(_log_segs(e))
	var widths: Array = []
	var rows := 1
	for sg in segs2:
		var w2: float = font.get_string_size(str(sg[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		widths.append(w2)
		if x + w2 > maxx and x > px.position.x + 8.0:
			rows += 1
			x = px.position.x + 6.0
		x += w2
	c = {"w": w, "segs": segs2, "widths": widths, "rows": rows}
	e["_cache"] = c
	return c

## 这条战报会占几行（和 _draw_log 用完全相同的换行规则，否则对不上）
func _draw_log(y: float, e: Dictionary) -> void:
	# 玩家名用 --player-N-border，正文用 --text-primary（对齐项目 gameInfo.js 的取色）
	var font := ThemeDB.fallback_font
	var fs := 16
	var px := panel_rect()
	var maxx: float = px.end.x - 8.0
	var x: float = px.position.x + 6.0
	var c2 := _log_cache(e)
	var segs2: Array = c2.get("segs", [])
	var widths: Array = c2.get("widths", [])
	for i3 in segs2.size():
		var sg2: Array = segs2[i3]
		var txt2 := str(sg2[0])
		var col3: Color = sg2[1]
		var w2: float = float(widths[i3]) if i3 < widths.size() else font.get_string_size(txt2, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if x + w2 > maxx and x > px.position.x + 8.0:
			y += float(fs) + 4.0
			x = px.position.x + 6.0
		draw_string(font, Vector2(x, y), txt2, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col3)
		x += w2

## 底部菜单：Figma A 方案横排 3 等分（设计稿 205x64 gap 12：规则/结算/暂停）。
## 本地对局同样有第 3 个「暂停」按钮（11 号暂停弹层）。
func _bottom_btn_rects() -> Array:
	var c := btn_col_rect()
	var gap := 12.0
	var w: float = (c.size.x - gap * 2.0) / 3.0
	return [
		Rect2(c.position.x, c.position.y, w, c.size.y),
		Rect2(c.position.x + w + gap, c.position.y, w, c.size.y),
		Rect2(c.position.x + (w + gap) * 2.0, c.position.y, w, c.size.y),
	]

func rules_rect() -> Rect2:
	return _bottom_btn_rects()[0]

func settle_rect() -> Rect2:
	return _bottom_btn_rects()[1]

## 暂停/继续：联机走网络暂停、本地切 local_paused。
## 暂停中返回「11 号弹层大按钮 ∪ 底部继续按钮」的外接矩形，两个位置都能恢复。
func pause_rect() -> Rect2:
	var r: Rect2 = _bottom_btn_rects()[2]
	if _hud_pause_active():
		var m := _pause_continue_rect()
		if m.size.x > 0.0:
			var tl := Vector2(minf(r.position.x, m.position.x), minf(r.position.y, m.position.y))
			var br := Vector2(maxf(r.end.x, m.end.x), maxf(r.end.y, m.end.y))
			return Rect2(tl, br - tl)
	return r

## 结算页称号 chip 的字号（称号多时靠它控制行高）
const RESULT_TITLE_FS := 12
## 结算页每行高度：基础 88px（名次/头像/名字/数据）+ 称号 chip 行（每行 23px）
const RESULT_ROW_H := 96.0
const RESULT_ROW_GAP := 0.0

func result_row_h(titles: Array) -> float:
	var inner_w: float = result_panel_width() - 56.0 - 130.0
	var tl: int = TitlesViewRef.line_count(titles, inner_w, RESULT_TITLE_FS)
	if tl <= 0: return RESULT_ROW_H
	return maxf(RESULT_ROW_H, 70.0 + float(tl) * 23.0 + 6.0)

func result_panel_width() -> float:
	return minf(size.x - 40.0, 640.0)

## 面板需要的高度：顶部固定区 256 + 各行 + 底部固定区 174（说明/按钮/内边距）
func result_need_h() -> float:
	var rows := _rankings()
	var total: float = 432.0
	for i in rows.size():
		var pid := int(rows[i].pid)
		total += result_row_h(result_titles.get(pid, []))
		if i < rows.size() - 1: total += RESULT_ROW_GAP
	return total

func result_panel() -> Rect2:
	var w := result_panel_width()
	var h: float = minf(result_need_h(), size.y - 40.0)
	# 12 号设计稿：面板 (40,200,640,816) —— 纯居中再上移 32px 正好 y=200（h=816 时）
	var y: float = maxf(40.0, (size.y - h) * 0.5 - 32.0)
	return Rect2((size.x - w) * 0.5, y, w, h)

func result_hits() -> Array:
	var p := result_panel()
	var bw: float = (p.size.x - 56.0 - 16.0) * 0.5
	var by: float = p.end.y - 28.0 - 72.0
	return [
		{"r": Rect2(p.position.x + 28.0, by, bw, 72.0), "a": "again", "t": "再来一局"},
		{"r": Rect2(p.position.x + 28.0 + bw + 16.0, by, bw, 72.0), "a": "menu", "t": "返回主菜单"},
		{"r": Rect2(p.end.x - 44.0, p.position.y + 8.0, 34.0, 34.0), "a": "close", "t": "×"},
		]

## 结束原因（12 号设计稿：「小满率先全部归巢，本局结束。」）
func _result_sub_text() -> String:
	var w = st.get("winner")
	if w != null:
		return "%s率先全部归巢，本局结束。" % _hud_player_name(int(w))
	return "本局结束。"

## 结算弹窗（12 号设计稿重绘）：标题/概况/排行榜（完成度/归巢/击落）/按钮；动作 ID 不变
func _draw_result() -> void:
	var font := _fig_font()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.231, 0.2, 0.176, 0.4))
	var p := result_panel()
	_fig_card(p, F_CARD, 24, true, true)
	var px := p.position.x
	var py := p.position.y
	var row_w: float = p.size.x - 56.0
	# 标题 + 结束原因
	_hud_str("这一局，快乐归巢", px + 28.0, py + 62.0, 34, F_INK,
		HORIZONTAL_ALIGNMENT_LEFT, row_w, true)
	_hud_str(_hud_fit(_result_sub_text(), 19, row_w), px + 28.0, py + 96.0, 19, F_SUB,
		HORIZONTAL_ALIGNMENT_LEFT, row_w)
	# 对局概况：回合 / 用时 / 模式
	var sr := Rect2(px + 28.0, py + 124.0, row_w, 68.0)
	draw_style_box(_sb(F_CARD2, 16, 0, Color(0, 0, 0, 0)), sr)
	_hud_str("%d 回合" % int(st.get("round", 1)), sr.position.x + 20.0,
		sr.position.y + 41.0, 20, F_INK)
	_hud_str("用时 " + _hud_elapsed_text(), sr.position.x, sr.position.y + 41.0, 20, F_INK,
		HORIZONTAL_ALIGNMENT_CENTER, sr.size.x)
	_hud_str(_hud_mode_summary(), sr.position.x, sr.position.y + 41.0, 20, F_SUB,
		HORIZONTAL_ALIGNMENT_RIGHT, sr.size.x - 20.0)
	# 表头（三列统计：完成度 / 归巢 / 击落）
	var row_x: float = px + 28.0
	var head_y: float = py + 231.0
	_hud_str("排名 / 玩家", px + 40.0, head_y, 17, F_SUB)
	_hud_str("完成度", row_x + 373.0 - 35.0, head_y, 17, F_SUB, HORIZONTAL_ALIGNMENT_CENTER, 70.0)
	_hud_str("归巢", row_x + 455.0 - 35.0, head_y, 17, F_SUB, HORIZONTAL_ALIGNMENT_CENTER, 70.0)
	_hud_str("击落", row_x + 537.0 - 35.0, head_y, 17, F_SUB, HORIZONTAL_ALIGNMENT_CENTER, 70.0)
	# 排名行（金/银/铜徽章 → 设计稿改成绿色高亮首名，其余白卡）
	var rows := _rankings()
	var ry: float = py + 256.0
	for i in rows.size():
		var r: Dictionary = rows[i]
		var pid := int(r.pid)
		var titles: Array = result_titles.get(pid, [])
		var rh: float = result_row_h(titles)
		var rr := Rect2(row_x, ry, row_w, rh)
		if i == 0:
			draw_style_box(_sb(F_GREEN_TINT, 16, 0, Color(0, 0, 0, 0)), rr)
		else:
			# 设计稿 2-4 名：纯白卡、无描边（靠极淡阴影分层）
			_fig_card(rr, F_CARD, 16, false, true)
		_hud_str(str(i + 1), rr.position.x + 12.0, rr.position.y + 56.0, 24,
			F_GREEN if i == 0 else F_SUB, HORIZONTAL_ALIGNMENT_LEFT, 30.0, true)
		_hud_avatar_at(Vector2(rr.position.x + 72.0, rr.position.y + 48.0), 24.0, pid,
			Color(1, 1, 1, 0.95), 2.0)
		_hud_str(_hud_fit(_hud_player_name(pid), 21, 180.0), rr.position.x + 108.0,
			rr.position.y + 40.0, 21, F_INK, HORIZONTAL_ALIGNMENT_LEFT, -1.0)
		var role := str(HUD_SIDE.get(pid, ""))
		var who := _hud_sub_prefix(pid)
		if who != "": role += " · " + who
		_hud_str(role, rr.position.x + 108.0, rr.position.y + 66.0, 15, F_SUB)
		var fin := _hud_fin(pid)
		var stat_col: Color = F_GREEN if i == 0 else F_INK
		_hud_str("%.0f%%" % float(r.pct), rr.position.x + 373.0 - 35.0,
			rr.position.y + 56.0, 20, stat_col, HORIZONTAL_ALIGNMENT_CENTER, 70.0)
		_hud_str("%d / %d" % [int(r.fin), int(_hud_fin(pid).tot)], rr.position.x + 455.0 - 35.0,
			rr.position.y + 56.0, 20, stat_col, HORIZONTAL_ALIGNMENT_CENTER, 70.0)
		_hud_str(str(_hud_defeats(pid)), rr.position.x + 537.0 - 35.0,
			rr.position.y + 56.0, 20, stat_col, HORIZONTAL_ALIGNMENT_CENTER, 70.0)
		if not titles.is_empty():
			TitlesViewRef.draw_player_titles(self, Vector2(rr.position.x + 108.0, rr.position.y + 72.0),
				titles, row_w - 140.0, RESULT_TITLE_FS)
		ry += rh + RESULT_ROW_GAP
	# 统计说明 + 操作按钮
	_hud_str("完成度按归巢棋子数计算；其余玩家按归巢数排名。", row_x, ry + 26.0, 16, F_SUB,
		HORIZONTAL_ALIGNMENT_LEFT, row_w)
	for h in result_hits():
		var a := str(h.a)
		var hr: Rect2 = h.r
		if a == "close":
			_hud_str("×", hr.position.x, hr.position.y + 26.0, 26, F_MUTED,
				HORIZONTAL_ALIGNMENT_CENTER, hr.size.x)
			continue
		var prim: bool = a == "again"
		_fig_card(hr, F_GREEN if prim else F_CARD, 16, not prim, true)
		_hud_str(str(h.t), hr.position.x, hr.position.y + hr.size.y * 0.5 + 8.0, 24,
			Color.WHITE if prim else F_INK, HORIZONTAL_ALIGNMENT_CENTER, hr.size.x, true)

func _log_rows(e: Dictionary) -> int:
	return int(_log_cache(e).get("rows", 1))

func _log_segs(e: Dictionary) -> Array:
	var segs2: Array = []
	var p := int(e.get("p", 0))
	if p > 0 and BORDER_COLS.has(p):
		segs2.append(["玩家%d" % p, Color(BORDER_COLS[p])])
	if e.has("ks"):
		for i2 in (e["ks"] as Array).size():
			if i2 > 0: segs2.append(["→", C_INK])
			var kk0 := str((e["ks"] as Array)[i2])
			if ACT.has(kk0): segs2.append([str(ACT[kk0].t), ACT[kk0].c])
	else:
		for key in ["t", "t2", "t3"]:
			var s3 := str(e.get(key, ""))
			if s3 == "": continue
			# t2 可以用 kc 指定颜色（碰撞奖励的 --collision-bonus #efa0c0）
			var c3: Color = C_INK
			if key == "t2" and e.has("kc"): c3 = Color(str(e.get("kc")))
			elif key == "t3" and e.has("kc3"): c3 = Color(str(e.get("kc3")))
			segs2.append([s3, c3])
	var kk := str(e.get("k", ""))
	if kk != "" and ACT.has(kk): segs2.append([str(ACT[kk].t), ACT[kk].c])
	return segs2

## ★ 战报测量缓存：一条战报的【片段表 / 行数 / 每个片段的宽度】只算一次，存进条目自身。
##   原来同一帧要测 3 遍 —— 装填循环 1 遍（_log_rows）、绘制循环 1 遍（_log_rows）、
##   _draw_log 里每个片段 1 遍；8 条可见 × 2~3 片段 ≈ 75 次 get_string_size（CJK 塑形），
##   全压在同一个 CanvasItem 的 _draw 里，骰子抖动/积分条缓动每刷一帧就要重来一次。
##   框宽变了（旋转/拉伸窗口）才重算。
func _rankings() -> Array:
	var rows: Array = []
	for pid in st.order:
		var cs: Array = st.players[pid].chesses
		var fin := 0
		var prog := 0.0
		for c in cs:
			# ★ E.chess_progress 返回的是【百分比 0~100】，不是 0~56 的步数。
			#   我之前又除了个 (棋子数 x 56) 再乘 100 -> 结果能超过 100%（101.82% 就是这么来的）。
			if bool(c.finished):
				fin += 1
				prog += 100.0
			else:
				prog += float(E.chess_progress(int(c.pos)))
		rows.append({"pid": pid, "fin": fin, "prog": prog,
			"pct": clampf(prog / float(maxi(1, cs.size())), 0.0, 100.0)})
	# 名次：引擎的 finishOrder 优先（第 1 个完成的排第 1，最后一家自动垫底），
	# 没进 finishOrder 的按完成度排。
	var fo: Array = st.get("finishOrder", [])
	rows.sort_custom(func(r1, r2):
		var i1: int = fo.find(int(r1.pid))
		var i2: int = fo.find(int(r2.pid))
		if i1 >= 0 and i2 >= 0: return i1 < i2
		if i1 >= 0: return true
		if i2 >= 0: return false
		return float(r1.prog) > float(r2.prog))
	return rows

## 结算名次徽章：1 金 / 2 银 / 3 铜 / 4 白（参考 style.css:4324-4343）
const RANK_BADGE := [Color("#fee39d"), Color("#d9d9d9"), Color("#d4b896"), Color("#ffffff")]

var board_tex: Texture2D
var gain_texts: Array = []    # [{t, amount, player}]
var gain_pending := {}        # 玩家 -> 待弹的数值（粒子落地那一刻才弹）
var dice_anim := 0.0          # 骰子滚动动画剩余时间
var remote_dice_anim := false # 本次动画是否为「远端玩家摇骰」的纯演出（结束后不能再本地掷一次）
var dice_shown := 0           # 动画中显示的点数
var last_dice := 0            # 保留上一次点数，不要一交回合就变回 "?"
var last_dice_owner := 0      # 掷骰者（骰面按他上色，不是按新的当前玩家）
var DICE_COLS := {}
const DICE_FACE_STEP := 0.1
var humans := [1]

## 棋盘上的字幕提示（三连6 惩罚等）：白色胶囊 + 玩家色描边，2.8s 内淡入淡出
## 称号浮字：新解锁的称号从触发的棋子上方浮出，上浮 + 淡出（时长见 TITLE_FLOAT_DUR）
func _draw_title_floats() -> void:
	if title_floats.is_empty(): return
	var font := ThemeDB.fallback_font
	for f in title_floats:
		var k: float = clampf(float(f.t) / TITLE_FLOAT_DUR, 0.0, 1.0)
		var alpha := 1.0
		var sc := 1.0
		if k < 0.14:
			alpha = k / 0.14
			sc = 0.72 + 0.28 * (k / 0.14)
		elif k > 0.6:
			alpha = 1.0 - (k - 0.6) / 0.4
		var col: Color = TitlesViewRef.tier_col(str(f.tier))
		col.a = clampf(alpha, 0.0, 1.0)
		var txt := "「%s」" % str(f.text)
		var fs := int(20.0 * sc)
		var w: float = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		# ease-out 上浮：先快后慢，看起来顺
		var rise: float = 46.0 * (1.0 - pow(1.0 - k, 2.0))
		var pos: Vector2 = (f.pos as Vector2) + Vector2(-w * 0.5, -rise)
		# 纯文字（不要白底/边框）：只给一点极淡的投影，保证压在棋盘格上也看得清
		var shadow := Color(0, 0, 0, 0.22 * alpha)
		draw_string(font, pos + Vector2(1.2, 1.2), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, shadow)
		draw_string(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)

func _draw_board_toast() -> void:
	if board_toast_t <= 0.0 or board_toast == "": return
	var font := ThemeDB.fallback_font
	var a: float = 1.0
	if board_toast_t > 2.4: a = clampf((2.8 - board_toast_t) / 0.4, 0.0, 1.0)
	elif board_toast_t < 0.45: a = clampf(board_toast_t / 0.45, 0.0, 1.0)
	var bw: float = minf(size.x - 48.0, 620.0)
	var bh := 40.0
	var cx: float = board_origin.x + BOARD_UNITS * board_scale * 0.5
	var cy: float = board_origin.y + 24.0 * board_scale
	var r := Rect2(cx - bw * 0.5, cy - bh * 0.5, bw, bh)
	draw_style_box(_sb(Color(1, 1, 1, 0.93 * a), 12, 2.5,
		Color(board_toast_col.r, board_toast_col.g, board_toast_col.b, 0.95 * a)), r)
	draw_circle(Vector2(r.position.x + 18.0, r.position.y + bh * 0.5), 6.0,
		Color(board_toast_col.r, board_toast_col.g, board_toast_col.b, a))
	draw_string(font, Vector2(r.position.x + 30.0, r.position.y + bh * 0.68), board_toast,
		HORIZONTAL_ALIGNMENT_LEFT, bw - 42.0, 19, Color(C_INK.r, C_INK.g, C_INK.b, a))

# ============================================================
# 第二批（task-17）· 道具模式：HUD / 购买·使用确认 / 道具说明 / 遥控骰选点 /
#   多面骰结果 / 传送门选格 / 盲盒开箱 / 积分不足·时机 toast / 通用错误框。
#   本段只做绘制 + UI 状态；执行仍走 flow 的 _buy_item_now/_apply（Lead 接线 3 处）。
# ============================================================
const HD_ITEMS := ["remote-dice", "polyhedral-dice", "teleport", "mysteryBox"]
const HD_ITEM_DESC := {"remote-dice": "指定本次点数", "polyhedral-dice": "点数范围 1-12",
	"teleport": "自由选格", "mysteryBox": "随机奖励"}
const HD_BUY_SUB := {
	"remote-dice": "指定本次点数，让这次出发更从容。",
	"polyhedral-dice": "本次掷骰改为 1-12 点，摇完即可选择棋子。",
	"teleport": "把一颗棋子传送到随机位置，摇骰前后都能用。",
	"mysteryBox": "随机开出奖励积分，积分低于 40 分时可用。",
}
const HD_MODAL_W := 640.0
var hd_dialog := ""            # "" | "buy" | "use_teleport" | "poly" | "mystery"
var hd_dlg_item := ""
var hd_dlg_cur := 0
var hd_dice_sel := 0
var hd_poly_value := 0
var hd_mystery_amount := 0
var hd_mystery_before := 0
var hd_last_dice_seen := 0
var hd_log_seen := 0
var hd_tele_ready := false
var hd_deny_seen := {}
var hd_error_open := false
var hd_error_title := ""
var hd_error_sub := ""
var hd_error_retry := Callable()
var hd_toast_kind := ""
var hd_toast_title := ""
var hd_toast_sub := ""
var hd_toast_start := 0
var hd_toast_until := 0
var hd_was_playing := false

## 清掉第二批所有临时 UI 状态（新局 / 离开对局）
func _hd_reset() -> void:
	hd_dialog = ""
	hd_dlg_item = ""
	hd_dlg_cur = 0
	hd_dice_sel = 0
	hd_poly_value = 0
	hd_mystery_amount = 0
	hd_mystery_before = 0
	hd_tele_ready = false
	hd_deny_seen = {}
	hd_error_open = false
	hd_error_retry = Callable()
	_hd_toasts_clear()
	hd_last_dice_seen = 0
	hd_log_seen = log_lines.size()

func _hd_toasts_clear() -> void:
	hd_toast_kind = ""
	hd_toast_title = ""
	hd_toast_sub = ""
	hd_toast_start = 0
	hd_toast_until = 0

## 通用 toast（02i/02j 同款；Lead 后续可用它触发 06 类提示）
func hud_toast(kind: String, title: String, sub: String, dur := 2.8) -> void:
	hd_toast_kind = kind
	hd_toast_title = title
	hd_toast_sub = sub
	hd_toast_start = Time.get_ticks_msec()
	hd_toast_until = hd_toast_start + int(dur * 1000.0)
	queue_redraw()

## 通用错误框（06）：retry 传 Callable 时「重试」按钮会调用它
func hud_error_show(title: String, sub: String, retry := Callable()) -> void:
	hd_error_open = true
	hd_error_title = title
	hd_error_sub = sub
	hd_error_retry = retry
	queue_redraw()

## 传送门是否处于「选目标格」状态（读 st.pendingItem，不依赖 flow 函数）
func _hd_teleport_pending() -> bool:
	if not bool(st.get("skillMode", false)): return false
	var pend = st.get("pendingItem", null)
	return pend != null and str(pend.item) == "teleport"

## 是否有第二批弹层需要优先消费点击（给 flow_base._input 调用）
func hud_modal_active() -> bool:
	if rules_open or show_result or _hud_pause_active(): return false
	if hd_error_open or hd_dialog != "": return true
	if pick_dice_kind != "": return true
	if _hd_teleport_pending(): return true
	return false

## 购买确认入口：flow_base._release_item 在通过全部校验后调用（返回 true 表示已接管）
func _hud_item_purchase_begin(iid: String) -> bool:
	hd_dialog = "buy"
	hd_dlg_item = iid
	hd_dlg_cur = int(st.get("currentPlayer", 0))
	queue_redraw()
	return true

## 第二批弹层点击统一入口（给 flow_base._input 调用）
func _click_hud_modal(pos: Vector2) -> void:
	if hd_error_open:
		var eb := _hd_error_buttons()
		if (eb[0] as Rect2).has_point(pos):
			hd_error_open = false
		elif (eb[1] as Rect2).has_point(pos):
			var cb := hd_error_retry
			hd_error_open = false
			if cb.is_valid(): cb.call()
		queue_redraw()
		return
	if hd_dialog == "buy": _hd_click_buy(pos); return
	if hd_dialog == "use_teleport": _hd_click_use(pos); return
	if hd_dialog == "poly" or hd_dialog == "mystery": _hd_click_result(pos); return
	if pick_dice_kind != "":
		if not _hud_pick_click(pos):
			# 点选点面板外 = 取消（沿用原逻辑：退回预扣积分）
			hd_dice_sel = 0
			pick_dice_kind = ""
			pick_rects = []
			call("_apply", {"type": "item_cancel"})
			queue_redraw()
		return
	if _hd_teleport_pending():
		# 02g：取消 / 确认提示 / 其余交回原来的「点棋子传送」逻辑
		var cr: Rect2 = _hd_teleport_buttons()[0]
		var okr: Rect2 = _hd_teleport_buttons()[1]
		if (cr as Rect2).has_point(pos):
			hd_tele_ready = false
			call("_apply", {"type": "item_cancel"})
			queue_redraw()
			return
		if (okr as Rect2).has_point(pos):
			hud_toast("info", "请点击你的棋子", "点自己的棋子即可完成传送，点空白处取消。", 2.2)
			return
		if humans.has(int(st.get("currentPlayer", 0))) and has_method("_click_teleport"):
			call("_click_teleport", pos)
		return

## 遥控骰选点（给 flow_base._click_dice_picker 调用；返回 true 表示已消费）
func _hud_pick_click(pos: Vector2) -> bool:
	if pick_dice_kind == "": return false
	for g in _hd_pick_grid():
		if (g.r as Rect2).has_point(pos):
			hd_dice_sel = int(g.v)
			queue_redraw()
			return true
	var card := _hd_pick_rect()
	var btn := _hd_two_buttons(card, card.position.y + 412.0)
	var close := _hd_close_rect(card)
	if close.has_point(pos) or (btn[0] as Rect2).has_point(pos):
		hd_dice_sel = 0
		pick_dice_kind = ""
		pick_rects = []
		call("_apply", {"type": "item_cancel"})
		queue_redraw()
		return true
	if (btn[1] as Rect2).has_point(pos):
		if hd_dice_sel <= 0: return true
		var v := hd_dice_sel
		var kind := pick_dice_kind
		hd_dice_sel = 0
		pick_dice_kind = ""
		pick_rects = []
		call("_apply", {"type": "roll", "value": v, "item": kind, "maxDice": 6, "noBonus": true})
		queue_redraw()
		return true
	return false

## 每帧观察：弹层自动触发 / 过期关闭 / toast 触发（从 _draw_hud 调用）
func _hd_observe() -> void:
	if st.is_empty() or st.get("players", null) == null:
		if hd_was_playing:
			_hd_reset()
			hd_was_playing = false
		return
	hd_was_playing = true
	# 新局（第 1 回合、未掷骰、无弹层）→ 清空第二批状态
	if int(st.get("round", 1)) == 1 and int(st.get("turn", 0)) <= 1 and last_dice == 0 \
		and hd_dialog == "" and not hd_error_open:
		_hd_reset()
	if rules_open or show_result or _hud_pause_active():
		return
	# ① 遥控骰选点：清空 flow 旧网格，避免旧坐标误命中
	if pick_dice_kind != "" and not pick_rects.is_empty():
		pick_rects = []
	# ② 多面骰结果（last_dice 1-12，只有人类能买道具）
	if last_dice != hd_last_dice_seen:
		hd_last_dice_seen = last_dice
		if last_dice > 6 and (humans.has(last_dice_owner) or last_dice_owner == int(net_local_seat)):
			hd_poly_value = last_dice
			hd_dialog = "poly"
			queue_redraw()
	# ③ 盲盒开箱：从最新战报里解析「打开盲盒，获得 N 分」
	if log_lines.size() > hd_log_seen:
		for i in range(hd_log_seen, log_lines.size()):
			var e: Dictionary = log_lines[i]
			var txt := str(e.get("t", ""))
			var at: int = txt.find("打开盲盒，获得")
			if at < 0: continue
			var num := ""
			for ch in txt.substr(at + 7):
				if ch >= "0" and ch <= "9":
					num += ch
				elif num != "":
					break
			if num == "": continue
			var owner := int(e.get("p", int(st.get("currentPlayer", 1))))
			var reward := int(num)
			var after := int(st.energy.get(owner, 0))
			var cost := int(E.ITEM_COSTS.get("mysteryBox", 15))
			hd_mystery_amount = reward
			hd_mystery_before = maxi(0, after - reward + cost)
			hd_dlg_cur = owner
			hd_dialog = "mystery"
			queue_redraw()
		hd_log_seen = log_lines.size()
	# ④ 传送门：买完先弹 02c 使用确认，确认后进入 02g 选格
	if _hd_teleport_pending():
		if hd_dialog == "" and not hd_tele_ready:
			hd_dialog = "use_teleport"
			hd_dlg_item = "teleport"
			queue_redraw()
	elif hd_tele_ready:
		hd_tele_ready = false
	# ⑤ 积分不足 / 时机错误 toast：跟随 item_fx 的 deny 反馈
	for iid in hd_deny_seen.keys():
		if not item_fx.has(iid): hd_deny_seen.erase(iid)
	for iid in item_fx.keys():
		var fx: Dictionary = item_fx[iid]
		if str(fx.get("kind", "")) == "deny" and float(fx.get("t", 0.0)) < 0.06 \
			and not hd_deny_seen.has(iid):
			hd_deny_seen[iid] = true
			_hd_deny_toast(str(iid))
	# ⑥ 换人/结束时自动关掉确认类弹层
	if hd_dialog == "buy" and hd_dlg_cur != int(st.get("currentPlayer", -1)):
		hd_dialog = ""

## 积分不足 / 时机错误的 toast 文案
func _hd_deny_toast(iid: String) -> void:
	var cost := int(E.ITEM_COSTS.get(iid, 0))
	var en := int(st.energy.get(hud_cur, 0))
	var nm := str(ITEM_NAMES.get(iid, iid))
	if en < cost:
		hud_toast("info", "积分不足，暂时无法购买",
			"%s需%d分 · 余额%d分 · 还差%d分" % [nm, cost, en, cost - en])
	elif iid == "mysteryBox" and en >= int(E.MYSTERY_BOX_MAX):
		hud_toast("info", "当前积分较高，盲盒暂不可用",
			"积分达到 %d 分后盲盒会暂时锁定" % int(E.MYSTERY_BOX_MAX))
	else:
		hud_toast("info", "当前时机无法使用道具", "请等待可使用时机 · 本次未扣除积分")


# ---------------------------------------------------------------- 道具栏（设计 02 / 02a）
## 4 格道具卡：图标 / 名称 / 价格 / 状态（可用·不足·已装备）+ 锁 / 选中绿描边与圆点
func _draw_item_bar() -> void:
	if not bool(st.get("skillMode", false)): return
	var bar := item_bar_rect()
	var n: int = HD_ITEMS.size()
	var big: bool = bar.size.y >= 100.0
	var w: float = 152.0 if big else (bar.size.x - 30.0) / 4.0
	var gap: float = (bar.size.x - w * 4.0) / 3.0 if big else 10.0
	for i in n:
		var r := Rect2(bar.position.x + float(i) * (w + gap), bar.position.y, w, bar.size.y)
		_draw_hd_item_card(r, str(HD_ITEMS[i]))

## 道具是否处于「已装备」态（遥控骰选点中 / 多面骰待掷 / 传送门选格中）
func _hd_item_equipped(iid: String) -> bool:
	var cur := int(st.get("currentPlayer", hud_cur))
	if iid == "remote-dice": return pick_dice_kind == "remote-dice"
	if iid == "polyhedral-dice": return pending_poly and pending_poly_owner == cur
	if iid == "teleport": return _hd_teleport_pending()
	return false

func _hd_draw_lock(c: Vector2, col: Color) -> void:
	draw_rect(Rect2(c.x - 5.0, c.y - 1.0, 10.0, 8.0), col, false, 1.4)
	draw_arc(c + Vector2(0.0, -1.0), 4.0, PI, TAU, 10, col, 1.4, true)
	draw_circle(c + Vector2(0.0, 3.0), 1.3, col)

func _hd_item_card_status(iid: String, en: int, cost: int, affordable: bool, usable: bool, equipped: bool) -> Array:
	# 返回 [文案, 颜色]；横排卡右列宽度有限，文案尽量短
	if equipped: return ["已装备", F_GREEN]
	if not usable: return ["需掷骰前", F_SUB]
	if not affordable:
		if iid == "mysteryBox" and en >= int(E.MYSTERY_BOX_MAX): return ["暂不可用", F_SUB]
		return ["差%d分" % maxi(0, cost - en), F_SUB]
	return ["可用", F_GREEN]

func _draw_hd_item_card(r0: Rect2, iid: String) -> void:
	var cost := int(E.ITEM_COSTS.get(iid, 0))
	var en := int(st.energy.get(hud_cur, 0))
	var affordable := item_affordable(iid)
	var usable := item_usable_now(iid)
	var equipped := _hd_item_equipped(iid)
	var fx: Dictionary = item_fx.get(iid, {})
	var kind := str(fx.get("kind", ""))
	var ft: float = float(fx.get("t", 0.0))
	# 按下缩放 / 买不起抖动（保留原有反馈）
	var pressed: bool = item_hold_id == iid
	var sc: float = 0.95 if pressed else 1.0
	var shake_x := 0.0
	if kind == "deny": shake_x = sin(ft * 62.0) * 5.0 * (1.0 - ft / 0.30)
	var r := Rect2(r0.position + Vector2(shake_x, 0.0) + r0.size * (1.0 - sc) * 0.5, r0.size * sc)
	# 高卡（用户反馈 B：112 高横排）走横排版式；矮卡（旧 88）保留紧凑版式
	var hz: bool = r.size.y >= 100.0
	var bg: Color = F_CARD
	var border: Color = F_LINE
	var bw := 1
	if equipped:
		bg = F_GREEN_TINT
		border = F_GREEN
		bw = 2
	elif not affordable:
		bg = Color("#EFECE7")
	draw_style_box(_sb(bg, 16 if hz else 14, bw, border), r)
	if not item_tex.has(iid):
		item_tex[iid] = load(str(ITEM_ICONS.get(iid, ""))) if ResourceLoader.exists(str(ITEM_ICONS.get(iid, ""))) else null
	var tex: Texture2D = item_tex.get(iid, null)
	var icon_col: Color = F_GREEN if (affordable or equipped) else F_MUTED
	var name_col: Color = F_INK if (affordable or equipped) else F_MUTED
	var pcol: Color = F_GREEN if (affordable or equipped) else F_SUB
	var st_info := _hd_item_card_status(iid, en, cost, affordable, usable, equipped)
	var st_txt := str(st_info[0])
	var st_col: Color = st_info[1]
	if hz:
		# 横排：图标在左垂直居中，右侧三行（名称 / 价格 / 状态）
		var pad := 12.0
		var isz: float = clampf(r.size.y * 0.30, 26.0, 36.0)
		var iy: float = r.position.y + (r.size.y - isz) * 0.5
		if tex != null:
			draw_texture_rect(tex, Rect2(r.position.x + pad, iy, isz, isz), false, icon_col)
		var tx: float = r.position.x + pad + isz + 8.0
		var tw: float = r.end.x - tx - 10.0
		var name_fs: int = 19 if r.size.y >= 106.0 else 17
		_hud_str(_hud_fit(str(ITEM_NAMES.get(iid, iid)), name_fs, tw),
			tx, r.position.y + r.size.y * 0.36, name_fs, name_col,
			HORIZONTAL_ALIGNMENT_LEFT, tw, true)
		var pill_h: float = 22.0 if r.size.y >= 106.0 else 20.0
		var pill_y: float = r.position.y + r.size.y * 0.47
		var pill_w: float = minf(tw, 72.0)
		var pr := Rect2(tx, pill_y, pill_w, pill_h)
		draw_style_box(_sb(Color(1, 1, 1, 0.85) if equipped else Color("#FAF8F5"), int(pill_h * 0.5), 0, Color(0, 0, 0, 0)), pr)
		_hud_str("%d 分" % cost, pr.position.x, pr.position.y + pill_h * 0.72, 13, pcol,
			HORIZONTAL_ALIGNMENT_CENTER, pr.size.x)
		_hud_str(_hud_fit(st_txt, 12, tw), tx, r.position.y + r.size.y * 0.87, 12, st_col,
			HORIZONTAL_ALIGNMENT_LEFT, tw)
		if not affordable:
			_hd_draw_lock(Vector2(r.end.x - 16.0, r.position.y + 16.0), F_SUB)
		if equipped:
			draw_circle(Vector2(r.end.x - 15.0, r.position.y + 15.0), 4.5, F_GREEN)
	else:
		# 紧凑版式（旧固定 88 高）
		if tex != null:
			draw_texture_rect(tex, Rect2(r.position.x + 12.0, r.position.y + 8.0, 24.0, 24.0), false, icon_col)
		_hud_str(_hud_fit(str(ITEM_NAMES.get(iid, iid)), 18, r.size.x - 24.0),
			r.position.x + 12.0, r.position.y + 46.0, 18, name_col,
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 24.0, true)
		var pr2 := Rect2(r.position.x + 12.0, r.position.y + 52.0, 64.0, 20.0)
		draw_style_box(_sb(Color(1, 1, 1, 0.85) if equipped else Color("#FAF8F5"), 10, 0, Color(0, 0, 0, 0)), pr2)
		_hud_str("%d 分" % cost, pr2.position.x, pr2.position.y + 15.0, 13, pcol,
			HORIZONTAL_ALIGNMENT_CENTER, pr2.size.x)
		_hud_str(_hud_fit(st_txt, 12, r.size.x - 24.0), r.position.x + 12.0, r.position.y + 84.0,
			12, st_col, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 24.0)
		if not affordable:
			_hd_draw_lock(Vector2(r.end.x - 18.0, r.position.y + 18.0), F_SUB)
		if equipped:
			draw_circle(Vector2(r.end.x - 16.0, r.position.y + 16.0), 4.5, F_GREEN)
	# 拒绝红框 / 购买闪白+对勾（保留原有反馈）
	if kind == "deny":
		var da: float = (1.0 - ft / 0.30) * 0.9
		draw_style_box(_sb(Color(0, 0, 0, 0), 16 if hz else 14, 2.0, Color(0.86, 0.30, 0.28, da)), r)
	if kind == "buy":
		var k: float = ft / 0.62
		draw_style_box(_sb(Color(1, 1, 1, 0.55 * (1.0 - k)), 16 if hz else 14), r)
		if k < 1.0:
			var ka: float = clampf((0.62 - ft) / 0.30, 0.0, 1.0)
			draw_circle(Vector2(r.end.x - 17.0, r.position.y + 17.0), 9.0, Color(1, 1, 1, ka))

# ---------------------------------------------------------------- 玩家卡角标：积分 + 完成度（设计 02/02a）
func _draw_hd_avatar_badges(c: Vector2, r: float, pid: int, deep: Color) -> void:
	var f := _fig_font()
	# 积分角标（右上，白底 + 玩家色描边）
	var en := int(st.energy.get(pid, 0))
	var ptxt := str(en)
	var pw: float = maxf(32.0, f.get_string_size(ptxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 16.0)
	var px: float = clampf(c.x + r * 0.62 - pw * 0.5, 8.0, size.x - pw - 8.0)
	var pr := Rect2(px, c.y - r * 0.98, pw, 26.0)
	draw_style_box(_sb(Color.WHITE, 13, 1.5, deep), pr)
	_hud_str(ptxt, pr.position.x, pr.position.y + 18.0, 14, deep,
		HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, true)
	# 完成度角标（左下，白底）
	var fin := _hud_fin(pid)
	var ctxt := "%d/%d" % [int(fin.fin), int(fin.tot)]
	var cw: float = maxf(30.0, f.get_string_size(ctxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 12.0)
	var cx: float = clampf(c.x - r * 0.62 - cw * 0.5, 8.0, size.x - cw - 8.0)
	var cr := Rect2(cx, c.y + r * 0.60, cw, 18.0)
	draw_style_box(_sb(Color.WHITE, 9, 1, F_LINE), cr)
	_hud_str(ctxt, cr.position.x, cr.position.y + 13.0, 11, F_SUB,
		HORIZONTAL_ALIGNMENT_CENTER, cr.size.x)

## 「余额 N 分」药丸（设计 02；2 人局右下角空位才画，4 人局用头像角标）
func _draw_hd_balance_pill(font: Font) -> void:
	var order: Array = st.get("order", [])
	if order.has(2): return
	var cur := int(st.get("currentPlayer", hud_cur))
	var txt := "余额 %d 分" % int(st.energy.get(cur, 0))
	var f := _fig_font()
	var tw: float = f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x + 30.0
	# 跟随底部 HUD 动态几何：1280 下 = 952-68 = 884；720x1600 下随 item_bar/日志条一起下移
	var py: float = item_bar_rect().position.y - 68.0 if _hd_item_layout() else panel_rect().position.y - 88.0
	var r := Rect2(size.x - 40.0 - tw, py, tw, 32.0)
	draw_style_box(_sb(F_GREEN_TINT, 17, 0, Color(0, 0, 0, 0)), r)
	_hud_str(txt, r.position.x, r.position.y + 22.0, 18, F_GREEN,
		HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

# ---------------------------------------------------------------- 道具说明（设计 02d；长按道具弹出，松手关闭）
func _draw_item_tip() -> void:
	if item_tip_id == "": return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.231, 0.2, 0.176, 0.4))
	var h := 815.0
	var card := Rect2((size.x - HD_MODAL_W) * 0.5, _hd_card_y(240.0, h), HD_MODAL_W, h)
	_fig_card(card, F_CARD, 24, true, true)
	_hd_close(card)
	_hud_str("道具说明", card.position.x + 28.0, card.position.y + 64.0, 34, F_INK,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
	_hud_str("道具模式 · 使用积分购买", card.position.x + 28.0, card.position.y + 100.0,
		17, F_SUB)
	var ry := card.position.y + 146.0
	for iid in HD_ITEMS:
		var rr := Rect2(card.position.x + 32.0, ry, card.size.x - 64.0, 124.0)
		draw_style_box(_sb(F_CARD2, 16, 0, Color(0, 0, 0, 0)), rr)
		if not item_tex.has(iid):
			item_tex[iid] = load(str(ITEM_ICONS.get(iid, ""))) if ResourceLoader.exists(str(ITEM_ICONS.get(iid, ""))) else null
		var tex: Texture2D = item_tex.get(iid, null)
		if tex != null:
			draw_texture_rect(tex, Rect2(rr.position.x + 24.0, rr.position.y + 44.0, 36.0, 36.0), false, F_GREEN)
		_hud_str(str(ITEM_NAMES.get(iid, iid)), rr.position.x + 76.0, rr.position.y + 52.0,
			21, F_INK, HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
		_hud_str(str(HD_ITEM_DESC.get(iid, "")), rr.position.x + 76.0, rr.position.y + 90.0,
			19, F_SUB)
		_hud_str("%d 分" % int(E.ITEM_COSTS.get(iid, 0)), rr.position.x,
			rr.position.y + 52.0, 21, F_GREEN, HORIZONTAL_ALIGNMENT_RIGHT, rr.size.x - 24.0)
		ry += 130.0
	_hud_str("已装备道具使用时不重复扣费。", card.position.x + 28.0,
		card.position.y + 682.0, 17, F_SUB)
	var br := Rect2(card.position.x + 32.0, card.position.y + 712.0, card.size.x - 64.0, 72.0)
	_fig_card(br, F_GREEN, 16, false, true)
	_hud_str("知道了", br.position.x, br.position.y + 44.0, 24, Color.WHITE,
		HORIZONTAL_ALIGNMENT_CENTER, br.size.x, true)
	_hud_str("松手关闭", card.position.x, card.position.y + 806.0, 13, F_MUTED,
		HORIZONTAL_ALIGNMENT_CENTER, card.size.x)

# ---------------------------------------------------------------- 遥控骰选点（设计 02e；选中→确认）
func _hd_pick_rect() -> Rect2:
	return Rect2((size.x - HD_MODAL_W) * 0.5, _hd_card_y(370.0, 515.0), HD_MODAL_W, 515.0)

func _hd_pick_grid() -> Array:
	var card := _hd_pick_rect()
	var out: Array = []
	var gw := 170.0
	var gh := 84.0
	var gap := 20.0
	var x0: float = card.position.x + (card.size.x - (gw * 3.0 + gap * 2.0)) * 0.5
	var y0: float = card.position.y + 190.0
	for i in 6:
		var cx: int = i % 3
		var cy: int = i / 3
		out.append({"r": Rect2(x0 + float(cx) * (gw + gap), y0 + float(cy) * (gh + 20.0), gw, gh),
			"v": i + 1})
	return out

func _draw_dice_picker() -> void:
	var font := _fig_font()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.231, 0.2, 0.176, 0.4))
	var card := _hd_pick_rect()
	_fig_card(card, F_CARD, 24, true, true)
	_hd_close(card)
	_hud_str("遥控骰子选点", card.position.x + 28.0, card.position.y + 64.0, 34, F_INK,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
	_hud_str("指定本次点数", card.position.x + 28.0, card.position.y + 100.0, 21, F_INK)
	_hud_str("已装备 · 本次使用不再扣积分", card.position.x + 28.0,
		card.position.y + 130.0, 17, F_SUB)
	for g in _hd_pick_grid():
		var r: Rect2 = g.r
		var v := int(g.v)
		var sel: bool = v == hd_dice_sel
		# 设计 02e：选中格 = 浅绿底 + 细描边（不是整格实心绿/粗边）
		draw_style_box(_sb(F_GREEN_TINT if sel else F_CARD2, 16, 1 if sel else 0,
			F_GREEN if sel else Color(0, 0, 0, 0)), r)
		_hud_str(str(v), r.position.x, r.position.y + r.size.y * 0.5 + 12.0, 34,
			F_GREEN if sel else F_INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true)
		if sel:
			draw_circle(Vector2(r.end.x - 14.0, r.position.y + 14.0), 4.5, F_GREEN)
	var btn := _hd_two_buttons(card, card.position.y + 412.0)
	_hd_button(btn[0], "取消", false)
	var ok_txt := "请选择点数"
	if hd_dice_sel > 0: ok_txt = "确认 %d 点" % hd_dice_sel
	_hd_button(btn[1], ok_txt, true, hd_dice_sel > 0)


# ---------------------------------------------------------------- 第二批弹层：购买确认 / 使用确认 / 结果 / 开箱 / 错误框
func _draw_hd_item_dialogs(font: Font) -> void:
	if hd_error_open:
		_draw_hd_error(font)
		return
	match hd_dialog:
		"buy": _draw_hd_buy(font)
		"use_teleport": _draw_hd_use(font)
		"poly": _draw_hd_poly(font)
		"mystery": _draw_hd_mystery(font)

## 00b 购买确认（02b）：余额 / 价格 / 购买后余额 + 取消·购买
func _hd_buy_rect() -> Rect2:
	return Rect2((size.x - HD_MODAL_W) * 0.5, _hd_card_y(320.0, 550.0), HD_MODAL_W, 550.0)

func _draw_hd_buy(font: Font) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.231, 0.2, 0.176, 0.4))
	var card := _hd_buy_rect()
	_fig_card(card, F_CARD, 24, true, true)
	_hd_close(card)
	var iid := hd_dlg_item
	var nm := str(ITEM_NAMES.get(iid, iid))
	_hud_str("购买%s？" % nm, card.position.x + 28.0, card.position.y + 70.0, 34, F_INK,
		HORIZONTAL_ALIGNMENT_LEFT, card.size.x - 56.0, true)
	_hud_str(str(HD_BUY_SUB.get(iid, "")), card.position.x + 28.0,
		card.position.y + 126.0, 21, F_SUB, HORIZONTAL_ALIGNMENT_LEFT, card.size.x - 56.0)
	var en := int(st.energy.get(hd_dlg_cur if hd_dlg_cur > 0 else hud_cur, 0))
	var cost := int(E.ITEM_COSTS.get(iid, 0))
	var after := maxi(0, en - cost)
	var rw: float = card.size.x - 56.0
	_hd_row(Rect2(card.position.x + 28.0, card.position.y + 150.0, rw, 64.0),
		"当前余额", "%d 分" % en, F_GREEN)
	_hd_row(Rect2(card.position.x + 28.0, card.position.y + 231.0, rw, 64.0),
		"购买价格", "-%d 分" % cost, F_GREEN)
	_hd_row(Rect2(card.position.x + 28.0, card.position.y + 312.0, rw, 64.0),
		"购买后余额", "%d 分" % after, F_GREEN)
	_hud_str("确认后扣除 %d 分，装备%s。" % [cost, nm], card.position.x + 28.0,
		card.position.y + 420.0, 17, F_SUB)
	var btn := _hd_two_buttons(card, card.position.y + 447.0)
	_hd_button(btn[0], "取消", false)
	_hd_button(btn[1], "%d 分购买" % cost, true)

## 02c 使用确认（传送门）：已装备状态 + 取消·选择目标格
func _hd_use_rect() -> Rect2:
	return Rect2((size.x - HD_MODAL_W) * 0.5, _hd_card_y(400.0, 396.0), HD_MODAL_W, 396.0)

func _draw_hd_use(font: Font) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.231, 0.2, 0.176, 0.4))
	var card := _hd_use_rect()
	_fig_card(card, F_CARD, 24, true, true)
	_hd_close(card)
	_hud_str("使用传送门？", card.position.x + 28.0, card.position.y + 70.0, 34, F_INK,
		HORIZONTAL_ALIGNMENT_LEFT, card.size.x - 56.0, true)
	_hud_str("自由选择目标格。确认后进入选格状态。", card.position.x + 28.0,
		card.position.y + 126.0, 21, F_SUB, HORIZONTAL_ALIGNMENT_LEFT, card.size.x - 56.0)
	_hd_row(Rect2(card.position.x + 28.0, card.position.y + 150.0, card.size.x - 56.0, 64.0),
		"道具状态", "已装备", F_GREEN)
	var en := int(st.energy.get(hd_dlg_cur if hd_dlg_cur > 0 else hud_cur, 0))
	_hud_str("本次使用不再扣款，余额仍为 %d 分。" % en, card.position.x + 28.0,
		card.position.y + 250.0, 17, F_SUB)
	var btn := _hd_two_buttons(card, card.position.y + 293.0)
	_hd_button(btn[0], "取消", false)
	_hd_button(btn[1], "选择目标格", true)

## 02f 多面骰结果
func _hd_poly_rect() -> Rect2:
	return Rect2((size.x - HD_MODAL_W) * 0.5, _hd_card_y(370.0, 535.0), HD_MODAL_W, 535.0)

func _draw_hd_poly(font: Font) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.231, 0.2, 0.176, 0.4))
	var card := _hd_poly_rect()
	_fig_card(card, F_CARD, 24, true, true)
	_hd_close(card)
	_hud_str("多面骰子结果", card.position.x + 28.0, card.position.y + 70.0, 34, F_INK,
		HORIZONTAL_ALIGNMENT_LEFT, card.size.x - 56.0, true)
	_hud_str("点数范围 1-12", card.position.x + 28.0, card.position.y + 106.0, 21, F_SUB)
	var ar := Rect2(card.position.x + 32.0, card.position.y + 146.0, card.size.x - 64.0, 206.0)
	draw_style_box(_sb(F_GREEN_TINT, 20, 0, Color(0, 0, 0, 0)), ar)
	_hud_str(str(hd_poly_value), ar.position.x, ar.position.y + 122.0, 92, F_GREEN,
		HORIZONTAL_ALIGNMENT_CENTER, ar.size.x, true)
	_hud_str("本次掷出 %d 点" % hd_poly_value, ar.position.x, ar.position.y + 174.0, 21,
		F_GREEN, HORIZONTAL_ALIGNMENT_CENTER, ar.size.x)
	_hud_str("选择可移动的棋子，继续本回合。", card.position.x + 28.0,
		card.position.y + 390.0, 17, F_SUB)
	_hd_button2(Rect2(card.position.x + 32.0, card.position.y + 431.0, card.size.x - 64.0, 72.0),
		"继续", true)

## 02h 盲盒开箱
func _hd_mystery_rect() -> Rect2:
	return Rect2((size.x - HD_MODAL_W) * 0.5, _hd_card_y(310.0, 731.0), HD_MODAL_W, 731.0)

func _draw_hd_mystery(font: Font) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.231, 0.2, 0.176, 0.4))
	var card := _hd_mystery_rect()
	_fig_card(card, F_CARD, 24, true, true)
	_hd_close(card)
	_hud_str("盲盒开箱", card.position.x + 28.0, card.position.y + 64.0, 34, F_INK,
		HORIZONTAL_ALIGNMENT_LEFT, card.size.x - 56.0, true)
	var ar := Rect2(card.position.x + 32.0, card.position.y + 100.0, card.size.x - 64.0, 214.0)
	draw_style_box(_sb(F_GREEN_TINT, 20, 0, Color(0, 0, 0, 0)), ar)
	if not item_tex.has("mysteryBox"):
		item_tex["mysteryBox"] = load(str(ITEM_ICONS.get("mysteryBox", ""))) if ResourceLoader.exists(str(ITEM_ICONS.get("mysteryBox", ""))) else null
	var tex: Texture2D = item_tex.get("mysteryBox", null)
	if tex != null:
		draw_texture_rect(tex, Rect2(ar.position.x + ar.size.x * 0.5 - 18.0, ar.position.y + 38.0, 36.0, 36.0), false, F_GREEN)
	_hud_str("+%d 分" % hd_mystery_amount, ar.position.x, ar.position.y + 139.0, 44, F_GREEN,
		HORIZONTAL_ALIGNMENT_CENTER, ar.size.x, true)
	_hud_str("盲盒奖励已入账", ar.position.x, ar.position.y + 186.0, 19, F_GREEN,
		HORIZONTAL_ALIGNMENT_CENTER, ar.size.x)
	var cost := int(E.ITEM_COSTS.get("mysteryBox", 15))
	var after := int(st.energy.get(hd_dlg_cur if hd_dlg_cur > 0 else hud_cur, 0))
	var rw: float = card.size.x - 64.0
	_hd_row(Rect2(card.position.x + 32.0, card.position.y + 330.0, rw, 64.0),
		"开箱前余额", "%d 分" % hd_mystery_before, F_GREEN)
	_hd_row(Rect2(card.position.x + 32.0, card.position.y + 406.0, rw, 64.0),
		"盲盒价格 / 奖励", "-%d / +%d" % [cost, hd_mystery_amount], F_GREEN)
	_hd_row(Rect2(card.position.x + 32.0, card.position.y + 482.0, rw, 64.0),
		"当前余额", "%d 分" % after, F_GREEN)
	_hud_str("%d - %d + %d = %d" % [hd_mystery_before, cost, hd_mystery_amount, after],
		card.position.x + 32.0, card.position.y + 570.0, 16, F_MUTED)
	_hd_button2(Rect2(card.position.x + 32.0, card.position.y + 628.0, rw, 72.0),
		"收下奖励", true)

## 06 通用错误框
## 06 通用错误框：设计稿固定卡 (41,421,638x312)，按钮 y≈631（相对 +210，高 72）
func _hd_error_rect() -> Rect2:
	return Rect2((size.x - 638.0) * 0.5, _hd_card_y(421.0, 312.0), 638.0, 312.0)

func _hd_error_buttons() -> Array:
	var card := _hd_error_rect()
	return _hd_two_buttons(card, card.position.y + 210.0)

func _draw_hd_error(font: Font) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.231, 0.2, 0.176, 0.4))
	var card := _hd_error_rect()
	_fig_card(card, F_CARD, 24, true, true)
	# 06 设计稿的 × 偏下（相对卡顶 ~66）
	_hud_str("×", card.end.x - 52.0, card.position.y + 66.0, 28, F_SUB,
		HORIZONTAL_ALIGNMENT_CENTER, 44.0)
	_hud_str(hd_error_title, card.position.x + 28.0, card.position.y + 70.0, 34, F_INK,
		HORIZONTAL_ALIGNMENT_LEFT, card.size.x - 56.0, true)
	# 正文图标（圆圈 !，中心相对卡顶 ~119）
	var ic := Vector2(card.position.x + 51.0, card.position.y + 119.0)
	draw_circle(ic, 17.0, Color(F_GREEN.r, F_GREEN.g, F_GREEN.b, 0.06))
	draw_arc(ic, 17.0, 0.0, TAU, 32, F_GREEN, 1.8, true)
	_hud_str("!", ic.x - 17.0, ic.y + 7.0, 19, F_GREEN, HORIZONTAL_ALIGNMENT_CENTER, 34.0, true)
	_hud_str(_hud_fit(hd_error_sub, 21, card.size.x - 126.0), card.position.x + 88.0,
		card.position.y + 130.0, 21, F_INK, HORIZONTAL_ALIGNMENT_LEFT, card.size.x - 126.0)
	_hud_str("本次未扣除积分，当前对局进度保持不变。", card.position.x + 28.0,
		card.position.y + 180.0, 17, F_SUB)
	var btn := _hd_error_buttons()
	_hd_button(btn[0], "关闭", false)
	_hd_button(btn[1], "重试", true)

# ---------------------------------------------------------------- 传送门选格（设计 02g）
func _hd_teleport_buttons() -> Array:
	# 锚定底部三按钮动态几何：1280 下 = 1181-67 = 1114；720x1600 下随 screens_base 一起下移
	var y: float = btn_col_rect().position.y - 67.0
	return [Rect2(40.0, y, 314.0, 54.0), Rect2(366.0, y, 314.0, 54.0)]

## 选格态：用「取消选择 / 确认目标格」替换骰子行（不动固定命中几何）
func _draw_hd_teleport_overlay(font: Font) -> void:
	var btn := _hd_teleport_buttons()
	# 主文案贴按钮上方 12px（1280=1102），辅助小字贴按钮下方 12px（1280=1180），高屏随按钮移动
	_hud_str("传送门已装备 · 本次使用不扣积分", 40.0, (btn[0] as Rect2).position.y - 12.0, 16, F_SUB)
	_hd_button(btn[0], "取消选择", false)
	_hd_button(btn[1], "确认目标格", true)
	_hud_str("点击你的一颗棋子即可传送 · 点空白取消", 40.0, (btn[0] as Rect2).end.y + 12.0, 13, F_MUTED)

# ---------------------------------------------------------------- 第二批点击处理
func _hd_click_buy(pos: Vector2) -> void:
	var card := _hd_buy_rect()
	var btn := _hd_two_buttons(card, card.position.y + 447.0)
	if _hd_close_rect(card).has_point(pos) or (btn[0] as Rect2).has_point(pos):
		hd_dialog = ""
		queue_redraw()
		return
	if (btn[1] as Rect2).has_point(pos):
		var iid := hd_dlg_item
		hd_dialog = ""
		if has_method("_buy_item_now"):
			call("_buy_item_now", iid)
		if iid == "teleport":
			hd_dialog = "use_teleport"
			hd_tele_ready = false
		queue_redraw()

func _hd_click_use(pos: Vector2) -> void:
	var card := _hd_use_rect()
	var btn := _hd_two_buttons(card, card.position.y + 293.0)
	if _hd_close_rect(card).has_point(pos) or (btn[0] as Rect2).has_point(pos):
		hd_dialog = ""
		hd_tele_ready = false
		if _hd_teleport_pending(): call("_apply", {"type": "item_cancel"})
		queue_redraw()
		return
	if (btn[1] as Rect2).has_point(pos):
		hd_dialog = ""
		hd_tele_ready = true
		queue_redraw()

func _hd_click_result(pos: Vector2) -> void:
	var card := _hd_poly_rect() if hd_dialog == "poly" else _hd_mystery_rect()
	var by := card.position.y + 431.0 if hd_dialog == "poly" else card.position.y + 628.0
	var btn := Rect2(card.position.x + 32.0, by, card.size.x - 64.0, 72.0)
	if _hd_close_rect(card).has_point(pos) or btn.has_point(pos):
		hd_dialog = ""
		queue_redraw()

# ---------------------------------------------------------------- toast 绘制（02i/02j / 06 轻提示共用）
func _draw_hd_toasts(font: Font) -> void:
	if hd_toast_until <= 0: return
	var now := Time.get_ticks_msec()
	if now >= hd_toast_until:
		_hd_toasts_clear()
		return
	queue_redraw()   # 持续重绘：滑入 / 淡出 / 到期清除
	var k_in: float = clampf(float(now - hd_toast_start) / 220.0, 0.0, 1.0)
	var alpha: float = minf(k_in, clampf(float(hd_toast_until - now) / 260.0, 0.0, 1.0))
	# 设计稿 02i/02j：外框统一 (56,81,608x100)；只淡入淡出、不做位移
	var r := Rect2(56.0, 81.0, 608.0, 100.0)
	draw_style_box(_sb(Color(1, 1, 1, 0.98 * alpha), 20, 1,
		Color(0.88, 0.86, 0.83, alpha),
		Color(59.0 / 255.0, 51.0 / 255.0, 45.0 / 255.0, 0.10 * alpha), 12), r)
	var icol: Color = F_GREEN
	if hd_toast_kind == "warn": icol = Color("#B7791F")
	elif hd_toast_kind == "error": icol = Color("#C0453C")
	icol.a = alpha
	var ic := Vector2(r.position.x + 30.0, r.position.y + 50.0)
	_draw_batch2_icon("info", ic, 11.0, icol)
	_hud_str(_hud_fit(hd_toast_title, 22, r.size.x - 84.0), r.position.x + 54.0,
		r.position.y + 48.0, 22, Color(F_INK.r, F_INK.g, F_INK.b, alpha),
		HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 84.0, true)
	_hud_str(_hud_fit(hd_toast_sub, 16, r.size.x - 84.0), r.position.x + 54.0,
		r.position.y + 76.0, 16, Color(F_SUB.r, F_SUB.g, F_SUB.b, alpha),
		HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 84.0)

# ---------------------------------------------------------------- 第二批几何/绘制小工具
## 设计稿 y（1280 画布）→ 当前控件坐标。
## 720x1280：保持设计稿坐标；高屏（720x1600 等）：按真实高度垂直居中，
## 只保留设计稿 ±24px 的视觉偏移，避免大屏上弹窗偏上/偏下。
func _hd_card_y(design_y: float, h: float) -> float:
	var y: float = design_y
	if size.y > 1280.0:
		var bias: float = clampf(design_y - (1280.0 - h) * 0.5, -24.0, 24.0)
		y = (size.y - h) * 0.5 + bias
	return clampf(y, 12.0, maxf(12.0, size.y - h - 12.0))

func _hd_close_rect(card: Rect2) -> Rect2:
	return Rect2(card.end.x - 60.0, card.position.y + 16.0, 44.0, 44.0)

func _hd_close(card: Rect2) -> void:
	var cr := _hd_close_rect(card)
	_hud_str("×", cr.position.x, cr.position.y + 30.0, 28, F_SUB,
		HORIZONTAL_ALIGNMENT_CENTER, cr.size.x)

func _hd_two_buttons(card: Rect2, y: float) -> Array:
	var w: float = (card.size.x - 56.0 - 16.0) * 0.5
	return [Rect2(card.position.x + 28.0, y, w, 72.0),
		Rect2(card.position.x + 28.0 + w + 16.0, y, w, 72.0)]

func _hd_button(r: Rect2, txt: String, primary: bool, enabled := true) -> void:
	if primary:
		_fig_card(r, F_GREEN if enabled else Color("#EFECE7"), 16, false, enabled)
	else:
		_fig_card(r, F_CARD, 16, true, false)
	var tc: Color = Color.WHITE
	if not primary: tc = F_INK
	elif not enabled: tc = F_MUTED
	_hud_str(txt, r.position.x, r.position.y + r.size.y * 0.5 + 8.0, 24, tc,
		HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true)

## 泛型主按钮（宽版，非左右两枚）
func _hd_button2(r: Rect2, txt: String, primary: bool) -> void:
	_hd_button(r, txt, primary)

func _hd_row(r: Rect2, label: String, value: String, vcol: Color) -> void:
	draw_style_box(_sb(F_CARD2, 14, 0, Color(0, 0, 0, 0)), r)
	_hud_str(label, r.position.x + 24.0, r.position.y + r.size.y * 0.5 + 7.0, 21, F_SUB)
	_hud_str(value, r.position.x, r.position.y + r.size.y * 0.5 + 7.0, 21, vcol,
		HORIZONTAL_ALIGNMENT_RIGHT, r.size.x - 24.0, true)
