extends "res://scripts/ui/hud_base.gd"
const TitleStatsRef := preload("res://scripts/achievements/title_stats.gd")
const TitleManagerRef := preload("res://scripts/achievements/title_manager.gd")
## M0：状态规范化哈希（动作日志 / 回放一致性校验用；见 scripts/core/serialize.gd）
const SER := preload("res://scripts/core/serialize.gd")

## 称号/成就系统（独立模块 scripts/achievements/，本文件只做挂钩，不含判定逻辑）
var title_stats: RefCounted = null    # TitleStats 实例（per-game 统计快照）
var title_announced := {}             # "玩家-家族" -> 已播档位下标
## 稀有度文字色（照搬参考 style.css .title-earned-title.tier-*）
const TITLE_TIER_COL := {"common": "#4b8a63", "rare": "#3f7fb5", "epic": "#8455b8",
	"legendary": "#b7791f", "mythic": "#c0453c"}

## ============================================================
## 流程基类（方案 1 · 批次 6）：游戏流程 / AI / 输入处理 / tickers
##   继承链：screens_base ← render_base ← item_bar_base ← pieces_base ← anim_base ← hud_base ← flow_base ← game_main
##   game_main 最终只留：_ready（组装）/ _draw（绘制入口）/ _process（ticker 调度）/ 极少数工具函数。
## ============================================================


func goto(scr: int) -> void:
	if trans_t > 0.0: return
	trans_next = scr
	trans_t = TRANS_DUR
	queue_redraw()

func start_game() -> void:
	var ss := seats()
	humans = humans_of(ss)
	# ★ 不再兜底强制一个人类。用户在"对局设置"里把全部座位设成 AI，就是要观战模式；
	#   之前这里会把座位1 偷偷改回"玩家"，导致"我全设 AI 了但绿色还是我在操作"。
	# 初始积分只在道具模式下有意义（经典模式没有积分条），免得往无关模式里塞状态
	st = E.create_state(ss, 4, happy_mode, item_mode, launch_values, init_energy if item_mode else 0)
	log_lines = []
	# M0：动作日志（权威动作记录）——跨局必须清空，否则下一局会带着上一局的记录
	action_log = []
	action_log_events = []
	# ★ 跨局状态必须【全部清空】—— 之前只清了 st/log_lines/ai_timer，
	#   导致"对局中返回主菜单再开新局"时棋子继承上一局的朝向（用户反馈）。
	tele_alpha = {}
	tele_key = ""
	tele_fx = ""
	tele_fx_t = 0.0
	tele_scale = 1.0
	tele_spin = 0.0
	hud_cur = int(st.currentPlayer)
	hud_round = int(st.get("round", 1))
	defeat_matrix = E.empty_defeat_matrix(st.order)
	# 称号统计：本局座位 + 每方 4 颗棋子（参考 gameState.titleStats）
	title_stats = TitleStatsRef.new(st.order, 4)
	title_announced = {}
	result_titles = {}
	st_ver += 1
	headings = {}
	headings_vis = {}
	head_tgt = {}
	head_from = {}
	head_t = {}
	energy_shown = {}
	energy_text = {}
	sb_cache = {}
	eparts = []
	epar_wait = []
	gain_texts = []
	gain_pending = {}
	energy_hold = {}
	energy_hold_t = {}
	seq = []
	cur_grp = 0
	last_land = {}
	last_mover = {"p": 0, "i": -1}
	last_walk_to = {}
	land_seq = 0
	last_dice = 0
	last_dice_owner = 0
	sel_anim = {}
	item_hold_id = ""
	item_hold_t = 0.0
	item_hold_fired = false
	item_fx = {}
	item_pulse_t = 0.0
	round_toast = ""
	round_toast_t = 0.0
	item_tip_id = ""
	pick_dice_kind = ""
	pending_poly = false
	pending_poly_owner = 0
	pick_rects = []
	show_result = false
	rules_open = false
	more_info_open = false
	dice_anim = 0.0
	dice_shake = 0.0
	board_toast = ""
	board_toast_t = 0.0
	title_floats = []
	dice_penalty = 0.0
	# ★ 这三项也必须清：solo_key/solo_timer 是「唯一可动棋子自动走」的记忆，
	#   不清会让新局该自动走的时候不走；trans_t 不清则下面 goto 会被「过渡中直接 return」吞掉，
	#   结果状态开了新局但界面停在设置页。
	solo_key = ""
	solo_timer = 0.0
	trans_t = 0.0
	goto(Scr.PLAY)   # #3 设置->对局 也走过渡
	ai_timer = 0.7
	queue_redraw()

func _release_item(pos: Vector2) -> void:
	if item_tip_id != "":
		item_tip_id = ""
		item_hold_id = ""
		queue_redraw()
		return
	if item_hold_id == "":
		return
	var iid := item_hold_id
	item_hold_id = ""
	# ★ 长按期间可能已经交回合 / 开播了动画：松手这一刻必须再校验一次归属与动画门
	if not seq.is_empty(): return
	if st.winner != null: return
	if not humans.has(int(st.currentPlayer)): return
	# ★ 多面骰：【不在这里激活】。引擎是在掷骰那一刻才扣费并随机摇 1-12（engine.gd:145-152），
	#   参考 skillManager.js:542 传 null 点数 + engine.mjs:717-718 rollDie(rng,12)。
	#   之前这里调用 item_activate 会立刻扣 50 分，再弹「自选点数」面板 —— 50 分道具强于 70 分，且与自述矛盾。
	if item_hold_fired: return          # 长按看过说明：松手只关说明，不买
	if _item_bar_hit(pos) != iid: return
	if not item_affordable(iid) or not item_usable_now(iid):
		item_fx[iid] = {"kind": "deny", "t": 0.0}   # 买不起 / 阶段不对：抖动 + 红框
		queue_redraw()
		return
	# 第二批：先弹购买确认，确认后走 _buy_item_now
	if _hud_item_purchase_begin(iid): return

func _buy_item_now(iid: String) -> void:
	item_fx[iid] = {"kind": "buy", "t": 0.0}
	if iid == "polyhedral-dice":
		pending_poly = true
		pending_poly_owner = int(st.currentPlayer)
	elif iid == "remote-dice":
		_apply({"type": "item_activate", "item": iid})
		if st.get("pendingItem", null) != null:
			_open_dice_picker(iid)
	else:
		_apply({"type": "item_activate", "item": iid})

func _click_item_bar(pos: Vector2) -> bool:
	if not bool(st.get("skillMode", false)): return false
	# ★ 只能操作【自己回合】的道具栏（参考 skillManager.js:169-174 直接拦截「请等待你的回合！」）。
	#   这个判断必须在 for 之前：_click_play 把道具栏排在 seq 门与 humans.has 校验【之前】，
	#   否则人类能替 AI 买道具、花 AI 的积分、替 AI 完成传送选子。
	var cur_ib: int = int(st.currentPlayer)
	if not humans.has(cur_ib): return false
	if not seq.is_empty(): return false
	for b in item_btns():
		if not (b.r as Rect2).has_point(pos): continue
		# 长按 = 看说明（买不起也能看），短按（松手时）= 购买
		var bid_p := str(b.id)
		# ★ 阶段不可用（摇完骰子后的遥控骰子/多面骰子）：【不可选中】—— 不进入按下/长按/购买流程，
		#   只给一次拒绝反馈（抖动 + 红框），按钮本身已是灰色。
		if not item_usable_now(bid_p):
			item_fx[bid_p] = {"kind": "deny", "t": 0.0}
			queue_redraw()
			return true
		item_hold_id = bid_p
		item_hold_t = 0.0
		item_hold_fired = false
		# 买不起仍可长按看说明，只给个拒绝反馈
		if not item_affordable(bid_p):
			item_fx[bid_p] = {"kind": "deny", "t": 0.0}
		queue_redraw()
		return true
	return false



func _open_dice_picker(kind: String) -> void:
	pick_dice_kind = kind
	pick_rects = []
	var mx: int = 12 if kind == "polyhedral-dice" else 6
	var cols: int = 6
	var w := 74.0
	var h := 62.0
	var gap := 10.0
	var rows: int = int(ceil(float(mx) / float(cols)))
	var tot_w: float = float(cols) * w + float(cols - 1) * gap
	var tot_h: float = float(rows) * h + float(rows - 1) * gap
	var x0: float = (size.x - tot_w) * 0.5
	var y0: float = (size.y - tot_h) * 0.5
	for i in mx:
		var cx: int = i % cols
		var cy: int = i / cols
		pick_rects.append({"r": Rect2(x0 + float(cx) * (w + gap), y0 + float(cy) * (h + gap), w, h),
			"v": i + 1})
	queue_redraw()

func _click_dice_picker(pos: Vector2) -> void:
	if _hud_pick_click(pos): return
	for p in pick_rects:
		if (p.r as Rect2).has_point(pos):
			var v: int = int(p.v)
			var kind := pick_dice_kind
			pick_dice_kind = ""
			pick_rects = []
			_apply({"type": "roll", "value": v,
				"item": kind, "maxDice": 6,   # 面板只服务遥控骰子（1-6）；多面骰由引擎随机摇
				"noBonus": true})
			return
	# 取消 = 把预扣的积分退回来（否则点了道具又取消，分就白扣了）
	pick_dice_kind = ""
	pick_rects = []
	_apply({"type": "item_cancel"})
	queue_redraw()

## 传送门：点自己的一颗棋子即传送（落点由引擎加权随机）
func _is_teleport_pending() -> bool:
	if not bool(st.get("skillMode", false)): return false
	var pend = st.get("pendingItem", null)
	return pend != null and str(pend.item) == "teleport"

func _click_teleport(pos: Vector2) -> void:
	var cur: int = int(st.currentPlayer)
	var cs: Array = st.players[cur].chesses
	var best := -1
	var bd := 1e9
	for i in cs.size():
		var c: Dictionary = cs[i]
		if bool(c.finished) or int(c.pos) == E.BASE: continue
		var dd: float = _piece_pos(cur, i, cs).distance_to(pos)
		if dd < bd: bd = dd; best = i
	if best >= 0 and bd < 52.0:
		_apply({"type": "teleport", "chessIndex": best})
		return
	# 点空白 = 取消（积分退回）
	_apply({"type": "item_cancel"})

func _input(event: InputEvent) -> void:
	# iOS 没有系统返回键（也没有 Android 的返回通知），自己做「左缘右滑」返回手势。
	# Android 由 NOTIFICATION_WM_GO_BACK_REQUEST 处理，这里只在 iOS 上启用，避免重复触发两次。
	if OS.get_name() == "iOS" and _ios_edge_swipe(event):
		return
	var pos := Vector2.ZERO
	var hit := false
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position; hit = true
	elif event is InputEventScreenTouch and event.pressed:
		pos = event.position; hit = true
	# #1a 规则弹窗：触摸拖动滚动（手机没有滚轮）
	# 返回确认弹窗优先：任意点击都只作用于弹窗
	if back_dialog != "":
		if hit:
			_click_back_dialog(pos)
		return
	if titles_open and event is InputEventScreenDrag:
		titles_scroll += event.relative.y
		queue_redraw()
		return
	if titles_open and event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		titles_scroll += event.relative.y
		queue_redraw()
		return
	if titles_open and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN: titles_scroll -= 60.0; queue_redraw(); return
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: titles_scroll += 60.0; queue_redraw(); return
	if rules_open and event is InputEventScreenDrag:
		# #2 手指上滑 relative.y 是负数，内容要跟着上移 -> rules_scroll 减小
		rules_scroll += event.relative.y
		queue_redraw()
		return
	# #1a 规则弹窗：鼠标左键按住也能拖（桌面触控板/鼠标拖动）
	if rules_open and event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		rules_scroll += event.relative.y
		queue_redraw()
		return
	# 规则弹窗滚轮
	if rules_open and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN: rules_scroll -= 60.0; queue_redraw(); return
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: rules_scroll += 60.0; queue_redraw(); return
	# 第二批设置页覆盖层（设置/确认/关于子页）；称号/规则覆盖在设置上时优先给上层
	if settings_open:
		if titles_open:
			if hit: _click_titles(pos)
			return
		if rules_open:
			if hit: _click_rules(pos)
			return
		var s_drag: bool = event is InputEventScreenDrag \
			or (event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0)
		if s_drag:
			_settings_drag(event.position)
			queue_redraw()
			return
		if hit:
			_click_settings(pos)
		return
	# 松手：先看是不是在道具按钮上（长按弹过说明就只关说明，否则购买）
	if event is InputEventScreenTouch and not event.pressed:
		energy_drag = false
		net_energy_drag = false
		_release_item(event.position); return
	if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		energy_drag = false
		net_energy_drag = false
		_release_item(event.position); return
	# ★ 初始积分拖动条（设置页）：按下/拖动都直接改值。放在 250ms 去重【之前】，
	#   否则快速点击第一下会被吞、拖不起来。
	if screen == Scr.SETUP and item_mode:
		var drag_ev: bool = (event is InputEventScreenDrag) 			or (event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0)
		if drag_ev and energy_drag:
			init_energy = _energy_from_x(event.position.x)
			queue_redraw(); return
		if hit:
			var sh := _energy_slider_hit()
			if not sh.is_empty() and (sh.r as Rect2).has_point(pos):
				energy_drag = true
				init_energy = _energy_from_x(pos.x)
				queue_redraw(); return
	# 联机房间：初始积分滑条拖动（触摸/鼠标拖动都实时改值）
	if screen == Scr.NET and net_energy_drag:
		var drag_ev2: bool = (event is InputEventScreenDrag) 			or (event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0)
		if drag_ev2:
			_net_cfg_energy(event.position)
			queue_redraw(); return
	# 「扩展规则介绍」弹窗：点任意处关闭
	if more_info_open:
		if hit: more_info_open = false; queue_redraw()
		return
	if not hit: return
	# 道具模式第二批 HUD 弹层（购买/使用确认、结果/开箱、错误框）优先消费点击
	if hud_modal_active():
		_click_hud_modal(pos)
		return
	# ★ 一次触摸可能产生两个事件（ScreenTouch + 合成的 MouseButton）。
	#   第二个会落到"刚刚切过去的新界面"上造成误触（点"人机对战"直接开始游戏就是这个原因）。
	#   这里做 250ms 去重，任何来源都拦得住。
	var now_ms := Time.get_ticks_msec()
	if now_ms - _last_press_ms < 250: return
	_last_press_ms = now_ms
	if titles_open:
		_click_titles(pos); return
	if rules_open:
		_click_rules(pos); return
	if show_result:
		_click_result(pos); return
	if screen == Scr.MODE: _click_mode(pos)
	elif screen == Scr.SETUP: _click_setup(pos)
	elif screen == Scr.NET: _click_net(pos)
	else: _click_play(pos)

func _click_mode(pos: Vector2) -> void:
	if about_open:
		for h in about_hits():
			if not (h.r as Rect2).has_point(pos): continue
			match str(h.a):
				"about_titles":
					about_open = false
					titles_open = true
					titles_closing = false
					titles_anim = 0.0
					titles_scroll = 0.0
				"about_close":
					about_open = false
			queue_redraw()
			return
		return
	for h in mode_hits():
		if not (h.r as Rect2).has_point(pos): continue
		if bool(h.get("dis", false)): return
		match str(h.a):
			"settings_open":
				settings_open = true
				settings_drawer = false
				settings_sub = ""
				settings_confirm = ""
				queue_redraw()
				return
			"titles":
				titles_open = true
				titles_closing = false
				titles_anim = 0.0
				titles_scroll = 0.0
				queue_redraw()
				return
			"m_online":
				mode = "online"
				net_enter()
				goto(Scr.NET)
				queue_redraw()
				return
			"m_local":
				mode = "local"
				# 默认 1 人 + 3 台电脑，进设置页可改
				seat_mode = {1: "player", 2: "ai", 3: "ai", 4: "ai"}
				goto(Scr.SETUP)
				queue_redraw()
				return
			"m_ai":
				mode = "local"
				seat_mode = {1: "player", 2: "ai", 3: "ai", 4: "ai"}
				happy_mode = false
				item_mode = false
				goto(Scr.SETUP)
				queue_redraw()
				return
			"rules":
				rules_open = true
				rules_scroll = 0.0
				queue_redraw()
				return
			"about":
				about_open = true
				queue_redraw()
				return

func _click_setup(pos: Vector2) -> void:
	for h in setup_hits():
		if not (h.r as Rect2).has_point(pos): continue
		var a := str(h.a)
		if a == "start": start_game(); return
		if a == "back": goto(Scr.MODE); return
		if a == "more_toggle": more_open = not more_open; queue_redraw(); return
		if a == "more_info": more_info_open = true; queue_redraw(); return
		if a.begins_with("set_"):
			var parts := a.split("_")
			seat_mode[int(parts[1])] = str(parts[2])
		elif a.begins_with("launch_"):
			var lv := int(a.substr(7))
			if launch_values.has(lv): launch_values.erase(lv)
			else: launch_values.append(lv)
			if launch_values.is_empty(): launch_values = [6]      # 至少留一个
		elif a == "mode_classic":
			happy_mode = false
			item_mode = false
		elif a == "mode_both":
			happy_mode = true
			item_mode = true
		elif a == "mode_happy" or a == "mode_happy_sw":
			happy_mode = not happy_mode
		elif a == "mode_item" or a == "mode_item_sw":
			item_mode = not item_mode
		queue_redraw(); return

func _click_play(pos: Vector2) -> void:
	# 只读入口（规则 / 结算）不受动画影响：它们只会把动画冻住，不会改对局
	if rules_rect().has_point(pos):
		rules_open = true; rules_scroll = 0.0; queue_redraw(); return
	if settle_rect().has_point(pos):
		show_result = true; queue_redraw(); return
	# 暂停态：只响应「继续」；其余输入全部阻断（本地/联机共用同一个 11 号弹层）
	if _hud_pause_active():
		if pause_rect().size.x > 0.0 and pause_rect().has_point(pos):
			if net_ui_active: _net_toggle_pause()
			else: _hud_toggle_local_pause()
		return
	# 右下第三按钮「暂停/继续」所有玩家可用；暂停/重连中阻断其它会改对局的输入
	if pause_rect().size.x > 0.0 and pause_rect().has_point(pos):
		if net_ui_active: _net_toggle_pause()
		else: _hud_toggle_local_pause()
		return
	if net_ui_active:
		if net_pause_block(): return
	# ★ 上一手动画没播完，【会改变对局】的入口一律不接受（否则会再进一次 _apply：
	#   音效重叠、状态被插队）。原来这条门在选点面板/传送/道具栏之后 -> 挡不住它们。
	if not seq.is_empty(): return
	# 选点数面板（模态，优先于一切）
	if pick_dice_kind != "":
		_click_dice_picker(pos); return
	# 传送门待选点：点自己的棋子传送，点空白取消
	# ★ 和道具栏一样必须限定【自己回合】：否则 AI 买下传送门后的那 0.5s 窗口里，
	#   人类可以替 AI 选落点，或点空白把 AI 的道具 cancel 掉（退分给它）。
	if _is_teleport_pending():
		if humans.has(int(st.currentPlayer)): _click_teleport(pos)
		return
	# 道具栏（在底部栏上方，必须先于棋盘摇骰判定）
	if _click_item_bar(pos): return
	if st.winner != null:
		show_result = true; queue_redraw(); return
	var cur := int(st.currentPlayer)
	if not humans.has(cur): return
	if st.phase == "rolling":
		# 点骰子 / 点棋盘任意处 / 点底部「掷骰子」按钮 都摇骰
		if roll_button_rect().has_point(pos) or dice_rect().grow(24.0).has_point(pos) or pos.y < bar_top():
			_begin_roll()
		return
	if st.phase == "selecting":
		var movable := E.movable_chess(st, cur, int(st.dice))
		var cs: Array = st.players[cur].chesses
		var best := -1
		var bd := 1e9
		for i in cs.size():
			var pp := _piece_pos(cur, i, cs)
			var dd := pp.distance_to(pos)
			if dd < bd: bd = dd; best = i
		if best >= 0 and bd < 52.0 and movable.has(best):
			_apply({"type": "move", "chessIndex": best})

## 任意玩家：暂停/继续（主机直接执行；客户端发请求给主机）
func _net_toggle_pause() -> void:
	if net_session == null: return
	if bool(net_session.paused):
		if net_is_host:
			net_session.host_resume()
		else:
			net_session.call("request_resume") if net_session.has_method("request_resume") else null
	else:
		if net_is_host:
			net_session.host_pause("manual", [], int(net_local_seat))
		else:
			net_session.call("request_pause") if net_session.has_method("request_pause") else null
	queue_redraw()

## 掷骰：先播滚动动画，动画结束再真正结算
func _begin_roll() -> void:
	if dice_anim > 0.0: return
	if not seq.is_empty(): return          # 等上一手走完再摇，避免音效重叠
	remote_dice_anim = false
	dice_anim = 0.5                     # 项目 dice.js: 闪烁 500ms、每 100ms 换一个骰面
	dice_face_t = DICE_FACE_STEP
	dice_shown = randi_range(1, 6)
	_sfx("rolling")                      # 项目 playRollAnimation 进来就播音，不等动画结束

## 远端玩家的摇骰：状态已由 APPLY 提交，但本机骰子仍先闪烁 0.5s 再揭示结果
func _remote_dice_start() -> void:
	if dice_anim > 0.0: return
	remote_dice_anim = true
	dice_anim = 0.5
	dice_face_t = DICE_FACE_STEP
	dice_shown = randi_range(1, 6)
	_sfx("rolling")
	if OS.is_debug_build():
		print("[DICE] remote-roll animation start")

## 每个大回合结束（所有在场玩家各动一次）发给每个在场玩家的积分。
## ★ 参考项目【没有】这条（积分只来自击败 / 碰撞 / 盲盒）；这是按"摇不出起飞点数的玩家会越来越弱"
##   补的平衡项，数值可在这里一处调整。
## ---------------------------------------------------------------- M0：动作入口三段化
## 旧调用点（全部 UI / AI）继续走 _apply(action)：等价于「当前玩家发起权威动作」。
## 返回 res（含 ok/state/events/error）；旧调用方忽略返回值即可，行为不变。
func _apply(action: Dictionary) -> Dictionary:
	# M3：联机客户端不本地改状态，只发意图（等主机 APPLY 回来再复算）
	if net_mode and not net_is_host:
		if intent_sender.is_valid():
			intent_sender.call(action)
		return {}
	return _apply_authority(int(st.currentPlayer), action)

## ① 权威路径（单机 / 联机主机）：引擎计算 → 提交（唯一写口）→ 表现。
##    actor 显式传入（联机时来自动作记录；单机 = 当前玩家），不再隐式读 st.currentPlayer。
func _apply_authority(actor: int, action: Dictionary, present := true) -> Dictionary:
	var pid := actor
	# 房主视角看其他玩家（含 AI）摇骰：同样先摇 0.5s 再出点数，不能直接跳结果
	if present and net_mode and net_is_host and int(actor) != int(net_local_seat) 			and str(action.get("type", "")) == "roll":
		_remote_dice_start()
	var round_before := int(st.get("round", 1))
	# 记录移动前的棋子位置，用来生成移动动画
	var before := _apply_capture_before()
	var res: Dictionary = E.apply(st, pid, action, rng)
	if not res.ok:
		log_lines.append({"p": pid, "kind": "", "t": str(res.error)}); queue_redraw()
		return res
	_commit_state(res.state, round_before, res.events)
	_record_action(pid, action, res.events)
	if present:
		_present(res.events, before, pid)
		_update_title_stats(res.events, st)
	return res

## ② 状态提交：主客共用的【唯一】写 st 入口（M0 收口；联机客户端复算也走这里）
##    · st_ver：可动棋子缓存等依赖它
##    · defeat_matrix：逐对手击败矩阵（参考 countBeats：beat +1、欢乐碰撞 +敌方颗数、撞叠子双方各计）
##    · 回合积分：原来在 _apply 之外直写 st.energy，现收进这里（否则联机回放两端会差 10 分/回合）
func _commit_state(new_state: Dictionary, round_before: int, events: Array) -> void:
	st = new_state
	st_ver += 1
	defeat_matrix = E.count_beats(defeat_matrix, events)
	_apply_round_energy(round_before)

## ③ 表现：音效 / 朝向 / 动画段 / 战报。
##    silent=true：只重建动画缓存（静默回放/快进用），不演出、不写战报、不发称号。
func _present(events: Array, before: Dictionary, actor: int, silent := false) -> void:
	if silent:
		_update_anim_caches(events)
		return
	_apply_event_side_effects(events, actor)
	# ★ 战报跟着动画段走：有段的事件在段开播（走子在走完）那一刻才写 —— 参考是逐事件 await
	#   （enginePlayback.js:143-150 走子那条在循环之后、:124/:164/:177/:246 在各自段开头）。
	#   没有动画段的事件（dice/skip/pass/end/道具/盲盒/叠子提示…）仍然立即写。
	var handled: Array = _build_anim(events, before)
	for ei in events.size():
		if handled.has(ei): continue
		_log_event(events[ei])

## ---------------------------------------------------------------- M0：动作日志与回放
## 记录一条【权威动作】。关键：把规则随机结果显式写进 action，回放时不需要 RNG：
##   roll -> value；mysteryBox -> amount；teleport -> to。
## 单机也记录（免费得到可回放的录像 / 回归基准）；跨局在 start_game 清空。
func _record_action(actor: int, action: Dictionary, events: Array) -> void:
	var rec_action: Dictionary = action.duplicate(true)
	var ty := str(rec_action.get("type", ""))
	if ty == "roll" and not rec_action.has("value"):
		for e in events:
			if str(e.get("type", "")) == "dice":
				rec_action["value"] = int(e.get("value", 0))
				break
	elif ty == "item_activate" and str(rec_action.get("item", "")) == "mysteryBox" and not rec_action.has("amount"):
		for e in events:
			if str(e.get("type", "")) == "mystery_box":
				rec_action["amount"] = int(e.get("amount", 0))
				break
	elif ty == "teleport" and not rec_action.has("to"):
		for e in events:
			if str(e.get("type", "")) == "teleport":
				rec_action["to"] = int(e.get("to", 0))
				break
	action_log.append({
		"seq": action_log.size() + 1,
		"actor": actor,
		"action": rec_action,
		"hash": SER.state_hash(st),
	})
	# 联机调试：debug 包在 logcat 打印每条权威动作的 seq/hash，供双机对拍（发布包不打印）
	if net_mode and OS.is_debug_build():
		print("[SYNC] host seq=%d actor=%d type=%s hash=%s" % [
			int(action_log.size()), int(actor), str(rec_action.get("type", "")),
			str(action_log[action_log.size() - 1].hash)])
	if OS.get_environment("FXQ_SYNC_DEBUG") == "1":
		action_log_events.append(events.duplicate(true))
	# M3：主机据此广播（单机无监听者，零影响）
	action_recorded.emit(action_log[action_log.size() - 1])

## ④ 远端动作（联机客户端 / M0 回放测试）：按动作记录复算 → 提交 → 校验 hash → 表现。
##    注意：rng 必须传 null —— 动作里已带显式随机结果，复算不能消耗本机随机流。
func _apply_remote(rec: Dictionary, silent := false) -> Dictionary:
	var actor := int(rec.get("actor", int(st.currentPlayer)))
	var action: Dictionary = (rec.get("action", {}) as Dictionary).duplicate(true)
	var round_before := int(st.get("round", 1))
	var before := _apply_capture_before()
	var res: Dictionary = E.apply(st, actor, action, null)
	if not bool(res.ok):
		return {"ok": false, "error": str(res.get("error", "apply failed")), "events": res.events, "state": st}
	_commit_state(res.state, round_before, res.events)
	var want := str(rec.get("hash", ""))
	if want != "" and SER.state_hash(st) != want:
		return {"ok": false, "error": "hash mismatch @%d" % int(rec.get("seq", 0)), "events": res.events, "state": st}
	# 远端（其他玩家）摇骰：本机骰子也要先播 0.5s 摇骰动画再显示结果，不能直接跳点数
	if not silent and net_mode and not net_is_host and str(action.get("type", "")) == "roll":
		_remote_dice_start()
	_present(res.events, before, actor, silent)
	if not silent:
		_update_title_stats(res.events, st)
	action_log.append(rec)
	# 联机调试：客户端复算出的 hash 与主机广播一致时打印，供双机对拍
	if net_mode and OS.is_debug_build():
		print("[SYNC] client seq=%d actor=%d type=%s hash=%s" % [
			int(rec.get("seq", 0)), int(actor), str(action.get("type", "")),
			SER.state_hash(st)])
	return res
## 记录移动前的棋子位置（用来生成移动动画）
## 称号统计与播报（参考 enginePlayback.js:60-79 的 flushMoveDistances + announceLiveTitles）
##   · 每批事件后送进 TitleStats（事件驱动统计），并用引擎 totalDistance 覆盖精确里程；
##   · 对全部在场玩家判定「实时称号」，新达成的写进战报（按稀有度着色）；
##   · 一旦决出胜负，预先算好每位玩家的结算称号（_draw_result 直接用）。
## 称号图鉴只记录“本机玩家”的称号：联机=自己的座位，本地=第一个真人座位；
## AI / 其他玩家只播报，不写进本机 TitleStore（用户反馈）。
func _title_store_local_pid() -> int:
	if net_mode:
		return int(net_local_seat) if int(net_local_seat) > 0 else 0
	if humans.is_empty():
		return 0
	return int(humans[0])

func _update_title_stats(events: Array, state: Dictionary) -> void:
	if title_stats == null: return
	var local_pid := _title_store_local_pid()
	TitleStatsRef.update_from_events(events, title_stats.state)
	TitleStatsRef.sync_engine_state(title_stats.state, state)
	for pid in st.order:
		var got: Array = TitleManagerRef.collect_live_titles(
			title_stats.state, title_announced, int(pid), happy_mode)
		var new_ids: Array = []
		for t in got:
			var tier := str(t.get("tier", "common"))
			var col: String = TITLE_TIER_COL.get(tier, "#4b8a63")
			log_lines.append({"p": int(pid), "t": " 获得称号 ", "t2": "「%s」" % str(t.get("name", "")),
				"kc": col, "t3": "（%s）" % TitleDefsRef.tier_name(tier), "kc3": col})
			# 棋子顶部浮字（上浮淡出）——只记棋子身份，坐标在 tick 里按当前布局算
			title_floats.append({"text": str(t.get("name", "")), "tier": tier,
				"pid": int(pid), "ci": _title_piece_ci(int(pid), events), "t": 0.0,
				"pos": Vector2.ZERO})
			new_ids.append(str(t.get("id", "")))
		# 只有本机玩家才计入称号图鉴；AI/其他玩家仅播报
		if int(pid) == local_pid and not new_ids.is_empty(): TitleStoreRef.bump(new_ids)
	if st.get("winner") != null and result_titles.is_empty():
		result_titles = TitleManagerRef.calculate_titles(
			title_stats.state, _rankings(), st.order, happy_mode)
		# 唯一/终局称号只在结算时出现，补记触发次数（家族称号上面已记过，不重复记）
		var special_ids: Array = []
		if local_pid > 0 and result_titles.has(local_pid):
			for t2 in (result_titles[local_pid] as Array):
				var sid := str(t2.get("id", ""))
				if _is_settle_title(sid): special_ids.append(sid)
		if not special_ids.is_empty(): TitleStoreRef.bump(special_ids)
	queue_redraw()

## 称号浮字的计时推进
func _tick_title_floats(delta: float) -> void:
	if title_floats.is_empty(): return
	# 布局必须已就绪（_process 可能跑在第一次 _draw 之前）
	layout()
	var keep: Array = []
	for fl in title_floats:
		fl["pos"] = _float_pos(int(fl.pid), int(fl.ci))
		fl["t"] = float(fl.t) + delta
		if float(fl.t) < TITLE_FLOAT_DUR: keep.append(fl)
	title_floats = keep
	queue_redraw()

## 找触发称号的那颗棋子（本批事件里该玩家最后一个带 chess 的事件；否则退回最近移动的棋子）
func _title_piece_ci(pid: int, events: Array) -> int:
	for k in range(events.size() - 1, -1, -1):
		var e: Dictionary = events[k]
		if int(e.get("player", 0)) == pid and e.has("chess"):
			var ci2 := int(e.get("chess", -1))
			if ci2 >= 0: return ci2
	if int(last_mover.get("p", 0)) == pid:
		return int(last_mover.get("i", -1))
	return -1

## 浮字锚点（每帧按当前棋子位置算，棋子走动时浮字会跟着平滑移动）
func _float_pos(pid: int, ci: int) -> Vector2:
	if not st.has("players") or not st.players.has(pid): return Vector2.ZERO
	var cs: Array = st.players[pid].chesses
	if cs.is_empty(): return Vector2.ZERO
	# _piece_pos 对「在基地/未上跑道」的棋子也返回屏幕坐标；ci=-1 时退回第 0 颗
	var idx := ci if (ci >= 0 and ci < cs.size()) else 0
	return _piece_pos(pid, idx, cs) + Vector2(0, -30.0)

## 是否是「唯一/终局」称号 id（图鉴里结算称号那一组）
func _is_settle_title(id: String) -> bool:
	for k in TitleDefsRef.UNIQUE_TITLES:
		if str((TitleDefsRef.UNIQUE_TITLES[k] as Dictionary).get("id", "")) == id: return true
	for k in TitleDefsRef.FINAL_TITLES:
		if str((TitleDefsRef.FINAL_TITLES[k] as Dictionary).get("id", "")) == id: return true
	return false


func _apply_capture_before() -> Dictionary:
	var before := {}
	for pl in st.order:
		var cs0: Array = st.players[pl].chesses
		for i in cs0.size(): before["%d_%d" % [pl, i]] = int(cs0[i].pos)
	return before

## 每大回合结算：所有在场玩家 +ROUND_ENERGY 积分（仅道具模式）
func _apply_round_energy(round_before: int) -> void:
	if bool(st.get("skillMode", false)) and int(st.get("round", 1)) > round_before:
		var gained := false
		for pid_r in st.order:
			var alive := false
			for pc_r in st.players[int(pid_r)].chesses:
				if not bool(pc_r.finished): alive = true; break
			if not alive: continue
			if E.grant_energy(st, int(pid_r), ROUND_ENERGY) > 0: gained = true
		if gained:
			round_toast = "回合结算：在场玩家 +%d 积分" % ROUND_ENERGY
			round_toast_t = 2.2

## 事件副作用：传送朝向、音效、结束音、骰子记录
func _apply_event_side_effects(events: Array, pid: int) -> void:
	for e in events:
		# 传送门：棋子换了格子，朝向必须跟着更新（否则停在原来的角度）
		# 注：粒子触发已全部移到 _build_anim（beat / collision_bonus 各挂 epar）。
		#     盲盒在参考里走 addEnergyLine（enginePlayback.js:496，只补文字不发光粒子），这里不发。
		# ★ 有积分进账就【立刻按住】积分条：st 在这一刻已经是整批终态，
		#   而粒子要等对应动画段开播才发 —— 不在这里按住，就是「条先涨、粒子后到」。
		# ★ 只有道具模式才有积分条：非道具模式别按条、也别弹 +N（粒子照发，只是不飞）
		if bool(st.get("skillMode", false)):
			var eg_h := int(e.get("energy", 0))
			var ed_h := _display_energy(e)
			if ed_h > 0:
				# 飘字用【规则该得的分】(reward)，与粒子/参考同口径；落地那一刻才弹（见 _tick_particles）
				var gp_h := int(e.get("player", pid))
				gain_pending[gp_h] = int(gain_pending.get(gp_h, 0)) + ed_h
			if eg_h > 0:
				var ep_h := int(e.get("player", pid))
				energy_hold[ep_h] = true
				energy_hold_t[ep_h] = 0.0
		# 粒子的触发全部移到了 _build_anim（beat / collision_bonus 分支各自带 epar）
		if str(e.get("type", "")) == "teleport":
			var tk := "%d_%d" % [int(e.get("player", pid)), int(e.get("chess", -1))]
			headings[tk] = _heading(int(e.get("player", pid)), int(e.get("to", 0)))
		# ★ 道具音效统一在【事件流】里播（参考 enginePlayback.js:489/630 就是这么做的）：
		#   这样 AI 买道具也响；而在 _release_item 里播会让人类自己买时响两次。
		if str(e.get("type", "")) == "item_activate" or str(e.get("type", "")) == "mystery_box": _sfx("skill")
		if str(e.get("type", "")) == "end": _sfx("gameover")   # gameover.wav 之前加载了却从没播过
		if str(e.get("type", "")) == "dice":
			last_dice = int(e.get("value", 0))
			last_dice_owner = int(e.get("player", pid))
func _tick_shot(delta: float) -> bool:
	if _shot_t <= 0.0: return false
	_shot_t -= delta
	if _shot_t > 0.0: return false
	# headless 下没有渲染上下文，取不到视口纹理
	var vtex := get_viewport().get_texture()
	var img: Image = vtex.get_image() if vtex != null else null
	if img != null:
		img.save_png(OS.get_environment("FXQ_SHOT"))
		print("SHOT -> ", OS.get_environment("FXQ_SHOT"))
	else:
		print("SHOT skipped (headless)")
	get_tree().quit(0)
	return true

## 底栏骰子滚动动画 + 动画结束真正掷骰
func _tick_dice_anim(delta: float) -> void:
	if dice_anim > 0.0:
		dice_anim -= delta
		dice_face_t -= delta
		if dice_anim <= 0.0:
			dice_anim = 0.0
			if remote_dice_anim:
				# ★ 远端摇骰动画只是本地演出：状态已由 APPLY 提交，绝不能在这里再本地掷一次
				remote_dice_anim = false
			else:
				var pid0 := int(st.currentPlayer)
				# M7: 人和 AI 到点都真正掷（AI 现在也走 _begin_roll）
				if st.phase == "rolling":
					# ★ 跨回合残留：买下多面骰后、还没掷就把回合交出去（超时/AI 接手/取消道具），
					#   下一家会被强行用掉这颗骰子并白扣 50 分。换人即作废。
					if pending_poly and int(st.currentPlayer) != pending_poly_owner:
						pending_poly = false
						pending_poly_owner = 0
					if pending_poly:
						# 多面骰：引擎按 1-12 随机摇，并在此刻扣 50 分（engine.gd:145-152）
						_apply({"type": "roll", "item": "polyhedral-dice", "maxDice": 12, "noBonus": true})
						pending_poly = false
						pending_poly_owner = 0
					else:
						_apply({"type": "roll"})       # 动画播完才真正掷
		elif dice_face_t <= 0.0:
			# ★ 参考 dice.js 是【每 100ms 换一个骰面】，不是每帧换。
			#   60fps 下每帧换 = 一秒换 60 次，点数糊成一片噪声，看不出在"摇"。
			dice_face_t = DICE_FACE_STEP
			dice_shown = randi_range(1, 6)
		queue_redraw()

## 棋子朝向的重叠过渡（0.3s ease-in-out，不累积误差）
func _tick_headings(delta: float) -> void:
	#   目标角一变，就从【当前视觉角】重新开始一段 0.3s 的 ease-in-out。
	#   ★ 之前用"恒定角速度 300°/s"是错的：走子每 190ms 换一次目标角，
	#     而 90° 要 300ms 才转完 -> 每次都来不及，误差累积，到目标格才补齐，
	#     表现为"卡顿一下然后才朝向正确"。重叠过渡不会累积。
	var head_dirty := false
	for hk in headings.keys():
		var ht: float = float(headings[hk])
		if float(head_tgt.get(hk, 1e9)) != ht:
			head_tgt[hk] = ht
			head_from[hk] = float(headings_vis.get(hk, ht))
			head_t[hk] = 0.0
		var tt: float = float(head_t.get(hk, 0.0)) + delta
		head_t[hk] = tt
		var u: float = clampf(tt / 0.3, 0.0, 1.0)
		var ue: float = u * u * (3.0 - 2.0 * u)
		var hf: float = float(head_from.get(hk, ht))
		headings_vis[hk] = hf + wrapf(ht - hf, -180.0, 180.0) * ue
		if u < 1.0: head_dirty = true
	# ★ 转向过渡也必须请求重绘：这段循环只改 headings_vis，而 _anim_step 在队列空时
	#   直接 return。人类回合靠每帧重绘盖过去了，AI 回合里"只改朝向、没有动画段"的动作
	#   （典型：传送门）会让棋子停在中间角度，直到下一次重绘（最多 ai_timer 0.6s）。
	if head_dirty: queue_redraw()

## 界面切换过渡（到一半时真正切 screen）
func _tick_transition(delta: float) -> void:
	# #3 过渡：到一半时真正切界面
	if trans_t > 0.0:
		var prev_t: float = trans_t
		trans_t = maxf(0.0, trans_t - delta)
		if prev_t > TRANS_DUR * 0.5 and trans_t <= TRANS_DUR * 0.5 and trans_next >= 0:
			screen = trans_next
			trans_next = -1
		queue_redraw()

	# 称号图鉴整页的滑入/滑出（0.32s，缓动在绘制端做）
	if titles_open:
		var tgt: float = 0.0 if titles_closing else 1.0
		titles_anim = move_toward(titles_anim, tgt, delta / 0.32)
		if titles_closing and titles_anim <= 0.0:
			titles_open = false
			titles_closing = false
			titles_scroll = 0.0
		queue_redraw()

## 开局设置页的动画：选中高亮"拉伸-收缩"、更多模式折叠、iOS 开关滑块
func _tick_setup_screen(delta: float) -> void:
	if screen != Scr.SETUP: return
	# #1 选中高亮：Material Design「拉伸-收缩」切换
	#   前 40% 一端不动、另一端拉伸到覆盖新旧两处；后 60% 另一端追上来落在新位置。
	#   比「排空-填充」自然得多，且带 ease-out 缓动。
	if screen == Scr.SETUP:
		for rowA in ["set_1", "set_2", "set_3", "set_4", "diff"]:
			var tgtA := _sel_target(rowA)
			if tgtA.size.x <= 0.0: continue
			var anA: Dictionary = sel_anim.get(rowA, {})
			if anA.is_empty():
				sel_anim[rowA] = {"x": tgtA.position.x, "w": tgtA.size.x, "y": tgtA.position.y, "h": tgtA.size.y, "tx": tgtA.position.x, "tw": tgtA.size.x, "t": 1.0}
				continue
			var oTx: float = float(anA.get("tx", -99999.0))
			var oTw: float = float(anA.get("tw", -99999.0))
			if absf(oTx - tgtA.position.x) > 0.5 or absf(oTw - tgtA.size.x) > 0.5:
				anA["fx"] = float(anA.x)
				anA["fw"] = float(anA.w)
				anA["tx"] = tgtA.position.x
				anA["tw"] = tgtA.size.x
				anA["t"] = 0.0
			var tt: float = minf(1.0, float(anA.get("t", 1.0)) + delta * 5.5)
			anA["t"] = tt
			var fx: float = float(anA.get("fx", tgtA.position.x))
			var fw: float = float(anA.get("fw", tgtA.size.x))
			var tx: float = float(anA.get("tx", tgtA.position.x))
			var tw: float = float(anA.get("tw", tgtA.size.x))
			var fl: float = fx
			var fr: float = fx + fw
			var tl: float = tx
			var tr: float = tx + tw
			if absf(tl - fl) < 0.5:
				anA["x"] = tx
				anA["w"] = tw
				anA["t"] = 1.0
			else:
				var stretch: float = 0.4
				if tt < stretch:
					# 拉伸：固定远端，近端伸到覆盖新旧两处
					var k1: float = tt / stretch
					k1 = 1.0 - pow(1.0 - k1, 3.0)          # ease-out cubic
					if tl > fl:
						anA["x"] = fl
						anA["w"] = lerpf(fw, tr - fl, k1)
					else:
						# 向左：右端不动，左端伸过去
						anA["x"] = lerpf(fl, tl, k1)
						anA["w"] = fr - float(anA.x)
				else:
					# 收缩：另一端追上来，正好落在新位置
					var k2: float = (tt - stretch) / (1.0 - stretch)
					k2 = 1.0 - pow(1.0 - k2, 3.0)
					if tl > fl:
						anA["x"] = lerpf(fl, tl, k2)
						anA["w"] = tr - float(anA.x)
					else:
						anA["x"] = tl
						anA["w"] = lerpf(fr - tl, tw, k2)
			anA["y"] = tgtA.position.y
			anA["h"] = tgtA.size.y
			sel_anim[rowA] = anA
		# 「更多模式」折叠动画 + 开关滑块（iOS 开关：轨道灰↔绿、滑块 smoothstep 滑动）
		more_anim = move_toward(more_anim, 1.0 if more_open else 0.0, delta * 6.0)
		for k in ["happy", "item"]:
			var tv: float = 1.0 if (happy_mode if k == "happy" else item_mode) else 0.0
			sw_anim[k] = move_toward(float(sw_anim.get(k, tv)), tv, delta * 7.0)
		queue_redraw()

## 动画段的推进 + 积分条缓动 + 道具栏反馈/回合横幅计时（弹窗打开时整体冻结）
func _tick_anim_fx(delta: float) -> void:
	# #3b 弹窗打开时立刻冻结动画（原来 _anim_step 在门之前，导致点按钮后棋子还在动）
	if not (rules_open or show_result or local_paused):
		_anim_step(delta * anim_speed)   # ★ 必须在冻结门【之内】：M3 联机追赶用倍速（默认 1.0）
		if screen == Scr.PLAY: _tick_energy(delta)
		# 道具栏反馈动画：成功 0.62s（闪白+对勾+飘字）、失败 0.30s（抖动）
		item_pulse_t += delta
		if round_toast_t > 0.0: round_toast_t = maxf(0.0, round_toast_t - delta)
		# ★ delta 上限：启动/卡顿那一帧可能是 0.5s，会把 0.6s 的反馈动画一帧跳完
		var fdt: float = minf(delta, 0.05)
		if not item_fx.is_empty():
			for kf in item_fx.keys().duplicate():
				var fxv: Dictionary = item_fx[kf]
				fxv["t"] = float(fxv.t) + fdt
				var lim: float = 0.62 if str(fxv.get("kind", "")) == "buy" else 0.30
				if float(fxv.t) >= lim: item_fx.erase(kf)

## 动画播完才把面板推进到新状态（参考 updateUI 在 play 之后）
func _tick_hud_sync() -> void:
	# ★ 动画播完才把面板推进到新状态（参考 updateUI 在 play 之后）
	if seq.is_empty():
		hud_cur = int(st.get("currentPlayer", hud_cur))
		hud_round = int(st.get("round", hud_round))

## 能量闪白 + 粒子系统
func _tick_particles_fx(delta: float) -> void:
	_eflash += delta
	_tick_particles(delta)

## 长按道具 0.5s 弹出说明（松手时若没弹过说明才真的购买）
func _tick_item_hold(delta: float) -> void:
	# 长按道具：超过 0.5 秒弹出说明；松手时若没弹过说明才真的购买
	if item_hold_id != "":
		item_hold_t += delta
		if item_hold_t >= 0.5 and not item_hold_fired:
			item_hold_fired = true
			item_tip_id = item_hold_id
			queue_redraw()

## 回合调度：人类回合等操作（唯一可动棋子自动走）；AI 回合按节奏出招
func _tick_turn(delta: float) -> void:
	# ★ M3：联机客户端不推进任何回合（AI/自动走子都由主机权威驱动，客户端只收 APPLY）
	if net_mode and not net_is_host: return
	# ★ 结算弹窗打开时暂停整局（否则后面的 AI 还在继续走）
	if screen != Scr.PLAY or show_result or rules_open or local_paused or not seq.is_empty(): return
	var cur := int(st.currentPlayer)
	# ★ M3：主机侧「远端人类座位」不自动走子，等客户端 intent（联机时 humans 只含本机座位）
	if net_mode and net_is_host and net_remote_seats.has(cur):
		return
	# ★ 人类玩家的回合必须等他操作 —— AI 不能替他摇骰/走子
	#   （H1 改串行队列时，替换范围把这段吃掉了，导致"你"也被自动操作）
	if humans.has(cur):
		# 只有一颗可动棋子时自动走，不用玩家点（0.55s 让人看清骰子）
		if st.phase == "selecting" and seq.is_empty():
			var mv2 := E.movable_chess(st, cur, int(st.dice))
			var key2 := "%d_%d_%d" % [cur, st.turn, int(st.dice)]
			if mv2.size() == 1 and solo_key != key2:
				solo_timer += delta
				if solo_timer >= 0.55:
					solo_key = key2
					solo_timer = 0.0
					_apply({"type": "move", "chessIndex": int(mv2[0])})
			else:
				solo_timer = 0.0
		queue_redraw()
		return
	ai_timer -= delta
	if ai_timer > 0: return
	# 道具模式下先问 AI 要不要用道具（参考 bot.mjs:136-161）
	var act: Dictionary = B.choose_item_action(st, cur, difficulty)
	if act.is_empty():
		act = B.choose_action(st, cur, difficulty, rng)
	# M7: AI 掷骰也走人类的 _begin_roll（闪烁 500ms + rolling 音），不再瞬间跳变
	if str(act.get("type", "")) == "roll":
		_begin_roll()
		ai_timer = 0.6
		return
	if act.is_empty():
		# M0：不再绕过动作层（原来直接 E.apply + 换 st：无 st_ver / 无战报 / 无动画 / 不进动作日志）
		_apply_authority(cur, {"type": "skip"})
	else:
		_apply(act)
	ai_timer = 0.5
	if OS.get_environment("FXQ_AUTOTEST") == "1": ai_timer = 0.0
	queue_redraw()


## 结算弹窗输入（要调 start_game/goto，留在 game_main）
func _click_result(pos: Vector2) -> void:
	for h in result_hits():
		if not (h.r as Rect2).has_point(pos): continue
		var a := str(h.a)
		show_result = false
		if net_mode:
			# 联机结算：再来一局 = 保留房间回房间页；返回主菜单 = 离开/解散
			if a == "again":
				if net_session != null:
					if net_is_host:
						if net_session.host_return_lobby():
							net_after_return_lobby()
					else:
						net_session.request_return_lobby()
						net_set_status("已请求房主再来一局…", 2.0)
				show_result = false
			elif a == "menu":
				net_leave()
			queue_redraw()
			return
		if a == "again":
			start_game()
		elif a == "menu":
			goto(Scr.MODE)
		queue_redraw()
		return



# ---- 流程状态（批次 6 上移）----
## M0：权威动作日志（联机同步/重连/录像的基础）。元素 {seq, actor, action, hash}
var action_log: Array = []
## M0：调试用。FXQ_SYNC_DEBUG=1 时与 action_log 对齐记录 events（回放测试比对 events 用）
var action_log_events: Array = []

# ---- M3：联机挂钩（默认关闭；net_mode=false 时单机行为与之前完全一致）----
## 每条权威动作记录后发出（主机用它广播；单机无监听者）
signal action_recorded(record: Dictionary)
var net_mode := false           # 是否处于联机对局
var net_is_host := false        # 本机是否权威端（客户端只发意图）
var intent_sender: Callable = Callable()   # 客户端：把本地动作变成 intent 的回调
var anim_speed := 1.0           # 客户端追赶倍速（_tick_anim_fx 用）
var net_remote_seats: Array = []  # 主机：远端人类座位（等 intent，不自动走子）
var ai_timer := 0.0
var energy_drag := false        # 正在拖初始积分滑块
var mode := "ai"                                   # local | ai
var dice_face_t := 0.0        # 距离下一次换骰面还有多久（参考 100ms 一换）
var rng := RandomNumberGenerator.new()
const ROUND_ENERGY := 10
var _shot_t := -1.0

## 骰子抖动 / 三连6 红面 / 抖动音 / 棋盘字幕 的计时推进
## ★ 这些递减原来在 _process 里，重构拆分时丢失 —— 导致三连6 后骰子一直停在红色。
func _tick_dice_fx(delta: float) -> void:
	if dice_penalty > 0.0: dice_penalty = maxf(0.0, dice_penalty - delta)
	if dice_shake > 0.0: dice_shake = maxf(0.0, dice_shake - delta)
	if shake_sfx_t > 0.0:
		shake_sfx_t -= delta
		if shake_sfx_t <= 0.0: _sfx("shake")
	if board_toast_t > 0.0:
		board_toast_t = maxf(0.0, board_toast_t - delta)
		queue_redraw()

## Android 返回键（侧滑返回）：先关弹窗/图鉴/规则，再按所处界面给确认弹窗
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back_pressed()

func _on_back_pressed() -> void:
	# 1) 确认弹窗：先取消
	if back_dialog != "":
		back_dialog = ""
		back_dialog_action = ""
		queue_redraw()
		return
	# 1.5) 设置页里打开的昵称/头像弹层优先关闭
	if net_nick_open:
		_net_close_nick_edit()
		return
	if net_avatar_picker_open:
		net_avatar_picker_open = false
		queue_redraw()
		return
	# 2) 设置页的二级/三级状态：逐层返回
	if settings_confirm != "":
		settings_confirm = ""
		queue_redraw()
		return
	if titles_open:
		# 称号详情弹层优先关闭，再关图鉴；图鉴作为设置页上层时返回设置页
		if title_detail_id != "":
			title_detail_id = ""
			queue_redraw()
			return
		if not titles_closing:
			titles_closing = true
			queue_redraw()
		return
	if settings_open:
		if settings_sub != "":
			settings_sub = ""
			queue_redraw()
			return
		settings_open = false
		settings_drawer = false
		queue_redraw()
		return
	# 3) 规则书 / 关于 / 更多信息弹窗：关闭
	if rules_open:
		rules_open = false
		queue_redraw()
		return
	if about_open:
		about_open = false
		queue_redraw()
		return
	if more_info_open:
		more_info_open = false
		queue_redraw()
		return
	# 4) 联机页：先关内层弹窗，再返回上一层（房间→主界面）
	if screen == Scr.NET:
		if net_kb_open:
			net_kb_open = false
			queue_redraw()
			return
		if net_nick_open:
			_net_close_nick_edit()
			return
		if net_avatar_picker_open:
			net_avatar_picker_open = false
			queue_redraw()
			return
		if net_overlay != "":
			if net_overlay == "host_left":
				net_leave()
			else:
				net_overlay = ""
				net_overlay_msg = ""
				queue_redraw()
			return
		net_leave()
		return
	# 5) 对局设置：直接返回主界面（不再弹退出对局/退出游戏）
	if screen == Scr.SETUP:
		goto(Scr.MODE)
		return
	# 6) 对局中（含结算页）：确认退出对局
	if screen == Scr.PLAY:
		_show_back_dialog("确定退出当前对局吗？", "exit_match")
		return
	# 7) 主界面：确认退出游戏
	_show_back_dialog("确定退出游戏吗？", "quit")

func _show_back_dialog(text: String, action: String) -> void:
	back_dialog = text
	back_dialog_action = action
	queue_redraw()

func _click_back_dialog(pos: Vector2) -> void:
	var hits := back_hits()
	if (hits[0].r as Rect2).has_point(pos):
		back_dialog = ""
		back_dialog_action = ""
		queue_redraw()
		return
	if (hits[1].r as Rect2).has_point(pos):
		var act := back_dialog_action
		back_dialog = ""
		back_dialog_action = ""
		match act:
			"quit":
				get_tree().quit()
			"exit_match":
				if net_mode: net_leave()
				else: goto(Scr.MODE)       # 结束对局回主菜单
			"to_menu":
				if net_mode: net_leave()
				else: goto(Scr.MODE)
		queue_redraw()

## iOS 左缘右滑返回手势：左边缘 30px 起手、水平向右拖 80px 触发（期间吞掉事件防止误触）
func _ios_edge_swipe(event: InputEvent) -> bool:
	if event is InputEventScreenTouch and event.pressed:
		if event.position.x <= 30.0:
			_swipe_arm = true
			_swipe_x0 = event.position.x
			_swipe_y0 = event.position.y
			return true
		return false
	if event is InputEventScreenTouch and not event.pressed:
		_swipe_arm = false
		return false
	if _swipe_arm and event is InputEventScreenDrag:
		var dx: float = event.position.x - _swipe_x0
		var dy: float = event.position.y - _swipe_y0
		if dx >= 80.0 and absf(dy) <= 70.0:
			_swipe_arm = false
			_on_back_pressed()
		return true
	return false