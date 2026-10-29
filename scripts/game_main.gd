# ============================================================================
#  飞行棋 —— 本地多人 / 人机对战（Godot 4.7）
#  资源与规则移植自 ZTMYO/MinimalistAeroplaneChess（AGPL-3.0）
# ============================================================================
extends "res://scripts/game/flow_base.gd"
# ---------------------------------------------------------------- 粒子独立层
# ★ 性能：粒子原来画在根 HUD 的同一个 canvas item 里 —— 每帧 queue_redraw() 会把
#   整个棋盘(704x704 贴图) + 16 颗棋子 + 底栏 + 积分条 + 战报【全部重录】一遍
#   （静态计数约 135 条 canvas 命令 + 30 次 draw_string + 50 次中文寻形）。
#   粒子寿命 0.8~1.3s，60fps 下就是 48~78 帧全量重绘 —— 这就是「踩子卡一下」。
#   参考项目用的是独立 DOM 层 .energy-particle-layer（style.css:636-641），
#   这里等价地用一个独立 Control 子节点：重绘只重录 6~25 条 draw_circle。
const C_BG      := Color("#f5f2ed")   # 项目 style.css:12 --bg-light-1
const BASE_H    := 1280.0             # 设计画布高度；高屏上下居中，避免所有 UI 贴在顶部
var _screen_oy  := 0.0

const BOARD_JSON := "res://data/board_classic_52.json"


## 初始积分（道具模式的起始能量，0~100 拖动条，只在道具模式下显示这一行）
## 「更多模式」折叠面板（参考 iOS 开关 + 手风琴）：
##   标题行常显（左上角「更多模式」+ 右侧「?」帮助），点标题行展开/收起；
##   展开后里面是模式开关（轨道灰↔绿、滑块 ease 滑动 ~0.2s）与初始积分拖动条。

var cell_pos := {}
var cell_shape := {}
var cell_color := {}

## 撞叠子时每颗被撞棋子的积分粒子依次飞，别全挤在同一帧（参考 enginePlayback.js:25）
## 「+N」飘字：参考 skillManager.js:836 showEnergyGainAnimation —— 在【骰子位置】浮出，
## 显示期间把骰子藏起来，1s 内 energyGainFloat：0%→20% 放大浮入、之后上浮淡出。
# ---- 临时性能探针（真机测帧耗时用；上线前删）----


## 本帧该玩家的可动棋子（参考 engineAdapter.movableFor）。
## ★ 原来 _can_move_vis 每颗棋子每帧都调一次 E.movable_chess（16 颗 = 16 次，每次重建一个
##   Array）。同一个 st 版本内结果只取决于 (玩家, 点数, 阶段)，按 st_ver 缓存即可。
func _ready() -> void:
	rng.randomize()
	# M4：把切屏回调注入联机 UI 基类（基类看不到子类的 goto/screen）
	net_nav = Callable(self, "goto")
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var f := FileAccess.open(BOARD_JSON, FileAccess.READ)
	D = JSON.parse_string(f.get_as_text())
	f.close()
	for pid in D.colors.keys():
		cols[int(pid)] = Color(D.colors[pid].hex)
	main_track = D.get("mainTrack", [])
	for k in D.get("seatRotationDeg", {}).keys():
		seat_rot[int(k)] = float(D.seatRotationDeg[k])
	# ★ 朝向改用项目 utils.js:getChessRotationAtPosition 的权威累积表。
	#   之前我用"相邻格切线吸附"自己推，57 个位置里有 14 个偏了 ±90°。
	var SPECIFIC_ROT := {1: -90.0, 5: -90.0, 8: 90.0, 14: 90.0, 19: -90.0, 21: 90.0,
		27: 90.0, 30: -90.0, 34: 90.0, 40: 90.0, 44: -90.0, 47: 90.0, 50: 90.0}
	track_rot = []
	var acc := 0.0
	for pos in main_track.size():
		if SPECIFIC_ROT.has(pos): acc += float(SPECIFIC_ROT[pos])
		track_rot.append(acc)
	# 音效
	for nm in ["move", "fly", "finish", "beat", "rolling", "shake", "gameover", "skill"]:
		var ap := AudioStreamPlayer.new()
		var stm = load("res://assets/from_project/audio/%s.wav" % nm)
		if stm != null:
			ap.stream = stm
			add_child(ap)
			sfx[nm] = ap
	# 配色对齐 theme.css（PALETTE.blue 原为自创的 #a8c9e8，项目是 --player-3-color #afccea）
	# 骰子专用高饱和色（项目 theme.css:26-29 --player-N-dice，与棋子用的 --player-N-color 是两套）
	DICE_COLS = {1: Color("#35ae61"), 2: Color("#dd7022"), 3: Color("#4777c5"), 4: Color("#fc6666")}
	PASTEL = {"blue": Color("#afccea"), "pink": Color("#f7a099"),
		"green": Color("#a6d8b7"), "orange": Color("#ecbd99")}
	for c in D.ring:
		cell_pos[int(c.cpos)] = Vector2(float(c.x), float(c.y))
		cell_shape[int(c.cpos)] = str(c.shape)
		cell_color[int(c.cpos)] = int(c.color)
	for pid in D.homeStretch.keys():
		var lane: Array = D.homeStretch[pid]
		for i in lane.size():
			var cid: int = 100 + (int(pid) - 1) * 10 + (i + 1)
			cell_pos[cid] = Vector2(float(lane[i][0]), float(lane[i][1]))
			cell_shape[cid] = "hr2" if absf(float(lane[0][0]) - float(lane[1][0])) > 0.5 else "vr2"
			cell_color[cid] = int(pid)
	for pid in D.bases.keys():
		var bp: Array = D.bases[pid]
		cell_pos[-100 - int(pid)] = Vector2(float(bp[0]), float(bp[1]))
	for pid in [1, 2, 3, 4]:
		var lane2: Array = D.homeStretch[str(pid)]
		var xid: int = 900 + (0 if (pid == 1 or pid == 3) else 1)
		cell_pos[xid] = Vector2(float(lane2[2][0]), float(lane2[2][1]))
		cell_shape[xid] = cell_shape[100 + (pid - 1) * 10 + 3]
		cell_color[xid] = pid
	cell_pos[999] = Vector2.ZERO
	board_tex = load("res://assets/from_project/board.png")
	for pid in tex_seat.keys():
		var pt: Texture2D = load("res://assets/from_project/piece_%s.png" % tex_seat[pid])
		if pt != null: piece_tex[pid] = pt
		var ps: Texture2D = load("res://assets/from_project/piece_%s_sel.png" % tex_seat[pid])
		if ps != null: piece_tex_sel[pid] = ps
	# 无人值守自测：四家全 AI，跑完整局自动退出
	if OS.get_environment("FXQ_AUTOTEST") == "1":
		seat_mode = {1: "ai", 2: "ai", 3: "ai", 4: "ai"}
		difficulty = "hard"
		start_game()
		ai_timer = 0.0
	var sp := OS.get_environment("FXQ_SHOT")
	if sp != "":
		_shot_t = float(OS.get_environment("FXQ_SHOT_DELAY")) if OS.get_environment("FXQ_SHOT_DELAY") != "" else 1.2
		if OS.get_environment("FXQ_SHOT_PLAY") == "1":
			seat_mode = {1: "ai", 2: "ai", 3: "ai", 4: "ai"}; start_game(); ai_timer = 0.0
		elif OS.get_environment("FXQ_SHOT_SETUP") == "1":
			mode = "ai"; seat_mode = {1: "player", 2: "ai", 3: "ai", 4: "none"}
			goto(Scr.SETUP)
	if OS.get_environment("FXQ_SHOT_AUTO") == "1":
		seat_mode = {1: "ai", 2: "ai", 3: "ai", 4: "ai"}; difficulty = "hard"; start_game(); ai_timer = 0.0
		if OS.get_environment("FXQ_SHOT_RESULT") == "1":
			show_result = true
		if OS.get_environment("FXQ_SHOT_RULES") == "1":
			rules_open = true
	# ★ 运行时强制关掉 touch->mouse 模拟。
	#   project.godot 里写了 pointing/emulate_mouse_from_touch=false，但实测运行时仍是 true
	#   （get_setting 返回 true），说明该键没被读取。这里直接调 API 兜底。
	if Input.has_method("set_emulate_mouse_from_touch"):
		Input.call("set_emulate_mouse_from_touch", false)
	print("[INPUT] emulate_mouse_from_touch = ", Input.is_emulating_mouse_from_touch() if Input.has_method("is_emulating_mouse_from_touch") else "?")
	# #3a 规则排版很贵（逐字量宽度），提前到启动时算好，
	#     否则首次点「游戏规则」要等约 2 秒才弹出来
	call_deferred("_rules_build")
	set_process(true)

## 自测/自动截图模式：四家全 AI，不强制塞一个人类座位
	# ★ 粒子独立层：放在最后添加，盖在棋盘和 HUD 之上；鼠标穿透，不参与输入。
	particle_layer = ParticleLayer.new()
	particle_layer.host = self
	particle_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	particle_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(particle_layer)
	_adapt_screen()

## 高屏（如 20:9）动态适配：保持 720×1280 设计构图，整体上下居中。
## 根 Control 下移 oy 后，绘制自动平移；输入事件在最外层统一回移。
func _adapt_screen() -> void:
	# 高屏适配改为各界面按真实高度排布，根节点不再整体下移。
	if _screen_oy != 0.0 or position != Vector2.ZERO:
		_screen_oy = 0.0
		position = Vector2.ZERO
		queue_redraw()

func _input(event: InputEvent) -> void:
	if _screen_oy != 0.0 and (event is InputEventScreenTouch or event is InputEventScreenDrag
			or event is InputEventMouseButton or event is InputEventMouseMotion):
		event.position -= Vector2(0.0, _screen_oy)
	super._input(event)

func _draw() -> void:
	# 根节点整体下移后，补齐上下 margin 的底色
	var oy: float = _screen_oy
	draw_rect(Rect2(0.0, -oy, size.x, size.y + oy * 2.0), C_BG)
	if screen == Scr.MODE: _draw_mode()
	elif screen == Scr.SETUP: _draw_setup()
	elif screen == Scr.NET: _draw_net()
	else: _draw_play()
	# #3 过渡遮罩：必须画在【顶层 _draw 里、所有界面内容之后】。
	#    之前放在 _draw_hud 里 -> 而 _draw_hud 只在 PLAY 界面才调用，
	#    菜单<->设置 这些切换根本不画它 -> 完全看不到过渡。
	if trans_t > 0.0:
		var pp: float = 1.0 - trans_t / TRANS_DUR
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.96, 0.95, 0.93, 1.0 - absf(2.0 * pp - 1.0)))

func _dice_pips(v: int) -> Array:
	match v:
		1: return [Vector2(0.5, 0.5)]
		2: return [Vector2(0.26, 0.26), Vector2(0.74, 0.74)]
		3: return [Vector2(0.24, 0.24), Vector2(0.5, 0.5), Vector2(0.76, 0.76)]
		4: return [Vector2(0.26, 0.26), Vector2(0.74, 0.26), Vector2(0.26, 0.74), Vector2(0.74, 0.74)]
		5: return [Vector2(0.26, 0.26), Vector2(0.74, 0.26), Vector2(0.5, 0.5),
			Vector2(0.26, 0.74), Vector2(0.74, 0.74)]
		_: return [Vector2(0.26, 0.22), Vector2(0.26, 0.5), Vector2(0.26, 0.78),
			Vector2(0.74, 0.22), Vector2(0.74, 0.5), Vector2(0.74, 0.78)]
func _bezier_ease(x: float, x1: float, y1: float, x2: float, y2: float) -> float:
	if x <= 0.0: return 0.0
	if x >= 1.0: return 1.0
	var lo := 0.0
	var hi := 1.0
	var t := x
	for _i in 10:
		t = (lo + hi) * 0.5
		var xt: float = 3.0 * (1.0 - t) * (1.0 - t) * t * x1 + 3.0 * (1.0 - t) * t * t * x2 + t * t * t
		if xt < x: lo = t
		else: hi = t
	return 3.0 * (1.0 - t) * (1.0 - t) * t * y1 + 3.0 * (1.0 - t) * t * t * y2 + t * t * t

## 二次贝塞尔：(1-t)^2*P0 + 2t(1-t)*P1 + t^2*P2
func _bezier(p0: float, p1: float, p2: float, t: float) -> float:
	return pow(1.0 - t, 2.0) * p0 + 2.0 * t * (1.0 - t) * p1 + t * t * p2


func _process(delta: float) -> void:
	_adapt_screen()
	# ★ 解耦第 2 步：原来 206 行的 _process 拆成 10 个 _tick_* 子系统更新（纯搬移，逻辑不变）。
	#   顺序与原来完全一致：截图调试 -> 骰子 -> 朝向缓动 -> 屏幕过渡 -> 设置页动画 -> 动画/反馈计时
	#   -> 面板同步 -> 粒子 -> 道具长按 -> 回合调度。
		# 首页标题有持续动画（参考 .rainbow-title 的 titleJump），需要每帧重绘
	if screen == Scr.MODE: queue_redraw()
	if _tick_shot(delta): return
	_tick_net(delta)          # M4：联机会话/发现/客户端收包（单机时内部全为 no-op）
	_tick_dice_anim(delta)
	_tick_headings(delta)
	_tick_transition(delta)
	_tick_setup_screen(delta)
	_tick_anim_fx(delta)
	_tick_hud_sync()
	_tick_particles_fx(delta)
	_tick_item_hold(delta)
	_tick_dice_fx(delta)
	_tick_title_floats(delta)
	# ★ 不在对局中就什么都不做（st 还是空字典），或动画没播完 -> AI 和输入都等（H2）
	# ★ 结算弹窗打开时暂停整局（否则后面的 AI 还在继续走）
	if screen != Scr.PLAY or show_result or rules_open or local_paused or not seq.is_empty(): return
	_tick_turn(delta)

## 截图调试（FXQ_SHOT）：返回 true 表示已经退出（调用方直接 return）