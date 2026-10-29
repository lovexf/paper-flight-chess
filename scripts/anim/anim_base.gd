extends "res://scripts/render/pieces_base.gd"
## ============================================================
## 动画基类（方案 1 · 批次 4）：动画队列 / 段推进 / 事件 builder
##   继承链：screens_base ← render_base ← item_bar_base ← pieces_base ← anim_base ← game_main
##   分段逻辑：_build_anim(调度链) + 9 个 _anim_ev_* builder；_step_one* 每帧推进；_anim_* 队列操作。
## ============================================================



# ---- 动画段查找 / 可动棋子判定 ----
func _anim_push(k: String, pts: Array, dur: float, mode: String, heading: float = INF, sfx_s: String = "", end_pos: int = -999, sfx_end: String = "", rels: Array = [], pl: int = 0, epar: Dictionary = {}, from_pos: int = -999, bg: bool = false, snap: bool = false, log_ev: Dictionary = {}) -> void:
	if pts.size() < 2: return
	var segd := {"k": k, "pts": pts, "dur": dur, "mode": mode, "t": 0.0,
		"sfx": sfx_s, "fired": false, "sfxEnd": sfx_end, "ended": false, "bg": bg, "snap": snap,
		"end_pos": end_pos, "from_pos": from_pos, "started": false, "grp": cur_grp}
	# 积分粒子：挂在这一段【开始播】时才触发（参考是 await 到那一刻才播）
	# 粒子的传播由 _build_anim 直接给对应动画段带 epar，不再走 pending 中转
	if not epar.is_empty(): segd["epar"] = epar
	if not log_ev.is_empty(): segd["log"] = log_ev
	# M5: 朝向存进段里，等这段真正开播时才写 headings，免得被后续事件覆盖
	if heading != INF: segd["heading"] = heading
	# 逐格转向：把每一格的位置号存进段里，走到哪一格就用哪一格的角度
	if not rels.is_empty():
		segd["rels"] = rels
		segd["pl"] = pl
	if mode == "steps":
		segd["vis"] = pts[0]
		segd["from"] = pts[0]
		segd["stepIdx"] = 1
		segd["stepT"] = 0.0
		segd["segT"] = 0.0
	seq.append(segd)

## 动画段推进（同组并行、跨组串行；★ 与 _step_one 配套）
func _anim_step(delta: float) -> void:
	if seq.is_empty(): return
	if OS.get_environment("FXQ_AUTOTEST") == "1": delta *= 200.0
	var fins: Array = []
	var i := 0
	while i < seq.size():
		var g: int = int(seq[i].get("grp", 0))
		var all_bg := true
		var j := i
		while j < seq.size() and int(seq[j].get("grp", 0)) == g:
			_step_one(seq[j], delta)
			if float(seq[j].t) >= 1.0: fins.append(j)
			if not bool(seq[j].get("bg", false)): all_bg = false
			j += 1
		if not all_bg: break          # 阻塞组：后面的组这一帧不动
		i = j                          # 旁路组：同一帧继续推进下一组
	for i2 in range(fins.size() - 1, -1, -1):
		seq.remove_at(fins[i2])
	queue_redraw()

## 停顿段：不位移，所以"站着的那一格"既是起点格也是终点格（cell）。
func _anim_hold(k: String, pos: Vector2, dur: float, cell: int, log_ev: Dictionary = {}) -> void:
	_anim_push(k, [pos, pos], dur, "hold", INF, "", cell, "", [], 0, {}, cell, false, false, log_ev)

## 动画段推进（每个段一帧调一次）。★ 解耦第 3 步：98 行的巨型函数按【阶段】拆开：
## 开播帧 / 走子 / 传送收束 / 传送重组 / 结束帧。逻辑与顺序完全不变。
func _step_one(sg: Dictionary, delta: float) -> void:
	var k := str(sg.k)
	_step_one_start(sg, k)
	sg["t"] = float(sg.t) + delta / maxf(0.01, float(sg.dur))
	match str(sg.mode):
		"steps": _step_one_move(sg, k, delta)
		"tpx": _step_one_tpx(sg, k)
		"tpy": _step_one_tpy(sg, k)
	_step_one_end(sg)

## 段开播那一帧：初始化朝向 / 音效 / 战报 / 积分粒子（错峰入队）
func _step_one_start(sg: Dictionary, k: String) -> void:
	if not bool(sg.get("started", false)):
		sg["started"] = true
		var h0: float = float(sg.get("heading", INF))
		if h0 != INF:
			headings[k] = h0
			# ★ 参考里「回基地 / 被击败 / 撞叠子 / 三连6复位 / 完赛」这些段都带 no-transition
			#   （animation.js:140/267），起播那一刻就是座位基础角。不加这条会"一边飞一边转"。
			if bool(sg.get("snap", false)):
				headings_vis[k] = h0
				head_tgt[k] = h0
				head_from[k] = h0
				head_t[k] = 1.0
		# ★ 走子段的朝向要用【正在进入的那一格】= rels[stepIdx]（起始 stepIdx=1），
		#   不是起点格 rels[0]。参考的 stepTo 是把位置设到目标格，再用新位置算朝向。
		#   原来用 rels[0] 且只在"换格"时更新，而走 1 格时 pn=2 -> 换格条件
		#   (stepIdx < pn-1) 永远不成立 -> 朝向一直停在起飞点，就是"走一格不转向"。
		var rl0: Array = sg.get("rels", [])
		if not rl0.is_empty():
			var ii: int = mini(int(sg.get("stepIdx", 1)), rl0.size() - 1)
			headings[k] = _heading(int(sg.get("pl", 0)), int(rl0[ii]))
		var sn := str(sg.get("sfx", ""))
		if sn != "": _sfx(sn)
		if str(sg.mode) == "steps": _sfx("move")
		# ★ 战报跟着段走（参考逐事件 await）：绝大多数在段【开播】时写
		if sg.has("log"):
			var lg0: Dictionary = sg["log"]
			if str(lg0.get("at", "start")) == "start":
				_log_event(lg0.get("e", {}))
		# 积分粒子：参考 energyManager.js:107-117 —— 起点是【被击败的棋子】，
		# 而且要在动画播到这一刻才触发（不是事件解析时就播）
		if sg.has("epar"):
			var ep2: Dictionary = sg.epar
			var edly: float = float(ep2.get("delay", 0.0))
			if edly > 0.0:
				# 错峰：先入待发队列，由 _tick_particles 到点再发（参考 playCollide 逐颗 CRASH_ENERGY_DELAY）
				epar_wait.append({"t": edly, "from": ep2.get("from", Vector2.ZERO),
					"player": int(ep2.get("player", 0)), "amount": int(ep2.get("amount", 0))})
			else:
				_spawn_energy_particles(ep2.get("from", Vector2.ZERO), int(ep2.get("player", 0)), int(ep2.get("amount", 0)))

## steps 模式：按 0.19s/格 逐格推进（朝向随"正在进入的格子"更新）
func _step_one_move(sg: Dictionary, k: String, delta: float) -> void:
	if str(sg.mode) == "steps":
		var pn: int = (sg.pts as Array).size()
		sg["stepT"] = float(sg.stepT) + delta
		if float(sg.stepT) >= 0.19 and int(sg.stepIdx) < pn - 1 and float(sg.t) < 1.0:
			sg["stepT"] = 0.0
			sg["from"] = sg.vis
			sg["segT"] = 0.0
			sg["stepIdx"] = int(sg.stepIdx) + 1
			var rl: Array = sg.get("rels", [])
			if not rl.is_empty():
				headings[k] = _heading(int(sg.get("pl", 0)), int(rl[mini(int(sg.stepIdx), rl.size() - 1)]))
			_sfx("move")
		var st2: float = float(sg.segT) + delta
		sg["segT"] = st2
		var u2: float = clampf(st2 / 0.3, 0.0, 1.0)
		var ue2: float = u2 * u2 * (3.0 - 2.0 * u2)
		var ti: int = mini(int(sg.stepIdx), pn - 1)
		sg["vis"] = (sg["from"] as Vector2).lerp((sg.pts as Array)[ti] as Vector2, ue2)

## 传送门·收束：棋子缩小 + 旋转 + 淡出
func _step_one_tpx(sg: Dictionary, k: String) -> void:
	if str(sg.mode) == "tpx":
		# 收束：棋子缩小 + 旋转 + 淡出（特效由 _draw_tele_fx 按 tele_fx_t 画）
		var t2: float = clampf(float(sg.t), 0.0, 1.0)
		tele_fx = "out"
		tele_fx_t = t2
		var k2: float = clampf(t2 / 0.7, 0.0, 1.0)
		tele_scale = lerpf(1.0, 0.12, k2 * k2)
		tele_spin = t2 * PI * 0.7        # 收束时转 126°（原来 270° 太急）
		tele_alpha[k] = 1.0 if t2 < 0.72 else clampf(1.0 - (t2 - 0.72) / 0.28, 0.0, 1.0)
		if t2 >= 1.0: tele_alpha[k] = 0.0

## 传送门·重组：overshoot 弹入（0.12 → 1.12 → 1.0）
func _step_one_tpy(sg: Dictionary, k: String) -> void:
	if str(sg.mode) == "tpy":
		# 重组：overshoot 弹入（0.12 → 1.18 → 1.0），透明度前 20% 拉满
		var t3: float = clampf(float(sg.t), 0.0, 1.0)
		tele_fx = "in"
		tele_fx_t = t3
		if t3 < 0.55:
			tele_scale = lerpf(0.12, 1.12, 1.0 - pow(1.0 - t3 / 0.55, 3.0))
		else:
			tele_scale = lerpf(1.12, 1.0, clampf((t3 - 0.55) / 0.45, 0.0, 1.0))
		tele_spin = (1.0 - t3) * PI * 0.35
		tele_alpha[k] = clampf(t3 / 0.2, 0.0, 1.0)
		if t3 >= 1.0:
			tele_alpha[k] = 1.0
			tele_scale = 1.0
			tele_spin = 0.0
			tele_fx = ""
			tele_key = ""

## 段结束那一帧：结束音效 + "走完后"才写的战报
func _step_one_end(sg: Dictionary) -> void:
	if float(sg.t) >= 1.0 and not bool(sg.get("ended", false)):
		sg["ended"] = true
		var se := str(sg.get("sfxEnd", ""))
		if se != "": _sfx(se)
		# ★ 走子那条战报在【走完之后】才写（参考 enginePlayback.js:143-150）
		if sg.has("log"):
			var lg1: Dictionary = sg["log"]
			if str(lg1.get("at", "")) == "end":
				_log_event(lg1.get("e", {}))
## 动画缓存（落点序号 / 最近移动者）：从 _build_anim 抽出，供「静默回放 / 快进」复用（M0）
##   · lastLandPos：叠子按它排序（后落地的排后面）
##   · last_walk_to：collide 起点要用
##   · last_mover：collide 事件没有 chess 字段，靠它找回撞人方
func _update_anim_caches(events: Array) -> void:
	for e in events:
		var t := str(e.get("type", ""))
		var pl := int(e.get("player", 0))
		var ci := int(e.get("chess", -1))
		var k := "%d_%d" % [pl, ci]
		if t == "walk" or t == "jump" or t == "fly" or t == "launch":
			land_seq += 1
			last_land[k] = land_seq
			last_walk_to[k] = int(e.get("to", 0))     # H2: collide 起点要用这个
			if ci >= 0: last_mover = {"p": pl, "i": ci}   # 参考 enginePlayback.js:32-34 的 lastMover

func _build_anim(events: Array, before: Dictionary) -> Array:
	var got: Array = []
	var fast: bool = OS.get_environment("FXQ_AUTOTEST") == "1"
	var GLIDE: float = 0.02 if fast else 0.31      # 跳子/飞棋：STEP_DELAY+120
	var BACK: float = 0.02 if fast else 0.5        # 回基地/到终点：animation.js duration=500
	_update_anim_caches(events)
	for ei in events.size():
		var e: Dictionary = events[ei]
		cur_grp += 1                       # 每个事件一个新组
		var t := str(e.get("type", ""))
		var pl := int(e.get("player", 0))
		var ci := int(e.get("chess", -1))
		var k := "%d_%d" % [pl, ci]
		# 事件上下文：各 builder 都从这只字典取局部量（避免把一堆参数列在签名里）
		var c := {"e": e, "pl": pl, "ci": ci, "k": k, "t": t, "got": got,
			"GLIDE": GLIDE, "BACK": BACK, "before": before, "fast": fast, "ei": ei}
		if t == "walk":
			_anim_ev_walk(c)
		elif t == "launch":
			_anim_ev_launch(c)
		elif t == "jump" or t == "fly":
			_anim_ev_jump_fly(c)
		elif t == "finish":
			_anim_ev_finish(c)
		elif t == "beat":
			_anim_ev_beat(c)
		elif t == "collision_bonus":
			_anim_ev_collision_bonus(c)
		elif t == "collide":
			_anim_ev_collide(c)
		elif t == "teleport":
			_anim_ev_teleport(c)
		elif t == "reset":
			_anim_ev_reset(c)
	return got

## 参考 gameInfo.js:791-799 —— 跳子/飞棋是同一颗棋子的后续动作，
## 并进上一条战报（"选择了棋子N [移动]→[跳子]"），而不是新开一行

## 事件 builder：walk
func _anim_ev_walk(c: Dictionary) -> void:
	var e: Dictionary = c["e"]
	var pl: int = int(c["pl"])
	var ci: int = int(c["ci"])
	var k: String = str(c["k"])
	var t: String = str(c["t"])
	var got: Array = c["got"]
	var GLIDE: float = float(c["GLIDE"])
	var BACK: float = float(c["BACK"])
	var before: Dictionary = c["before"]
	var fast: bool = bool(c["fast"])
	var ei: int = int(c["ei"])
	if pl <= 0 or ci < 0: return
	var pts: Array = []
	var rels: Array = [int(e.get("from", 0))]
	for step in e.path:
		pts.append(board_pos(pl, int(step.rel)))
		rels.append(int(step.rel))
	if pts.is_empty(): return
	pts.push_front(board_pos(pl, int(e.get("from", 0))))
	_anim_push(k, pts, (0.02 if fast else 0.19 * float(pts.size() - 2) + 0.3), "steps", INF, "", int(e.get("to", 0)), "", rels, pl, {}, int(e.get("from", 0)), false, false, {"e": e, "at": "end"})
	got.append(ei)

## 事件 builder：launch
func _anim_ev_launch(c: Dictionary) -> void:
	var e: Dictionary = c["e"]
	var pl: int = int(c["pl"])
	var ci: int = int(c["ci"])
	var k: String = str(c["k"])
	var t: String = str(c["t"])
	var got: Array = c["got"]
	var GLIDE: float = float(c["GLIDE"])
	var BACK: float = float(c["BACK"])
	var before: Dictionary = c["before"]
	var fast: bool = bool(c["fast"])
	var ei: int = int(c["ei"])
	if pl <= 0 or ci < 0: return
	# L10: 参考是 stepTo(300ms 过渡) + sleep(190ms) 重叠 -> 位移时长取 0.3，不是 0.19
	_anim_push(k, [_base_slot(pl, ci), board_pos(pl, 0)], 0.02 if fast else 0.3, "glide", _heading(pl, 0), "fly", 0, "", [], 0, {}, E.BASE, false, false, {"e": e})
	got.append(ei)

## 事件 builder：jump / fly
func _anim_ev_jump_fly(c: Dictionary) -> void:
	var e: Dictionary = c["e"]
	var pl: int = int(c["pl"])
	var ci: int = int(c["ci"])
	var k: String = str(c["k"])
	var t: String = str(c["t"])
	var got: Array = c["got"]
	var GLIDE: float = float(c["GLIDE"])
	var BACK: float = float(c["BACK"])
	var before: Dictionary = c["before"]
	var fast: bool = bool(c["fast"])
	var ei: int = int(c["ei"])
	if pl <= 0 or ci < 0: return
	_anim_push(k, [board_pos(pl, int(e.get("from", 0))), board_pos(pl, int(e.get("to", 0)))],
		GLIDE, "glide", _heading(pl, int(e.get("to", 0))), "fly", int(e.get("to", 0)), "", [], 0, {}, int(e.get("from", 0)), false, false, {"e": e})
	got.append(ei)

## 事件 builder：finish
func _anim_ev_finish(c: Dictionary) -> void:
	var e: Dictionary = c["e"]
	var pl: int = int(c["pl"])
	var ci: int = int(c["ci"])
	var k: String = str(c["k"])
	var t: String = str(c["t"])
	var got: Array = c["got"]
	var GLIDE: float = float(c["GLIDE"])
	var BACK: float = float(c["BACK"])
	var before: Dictionary = c["before"]
	var fast: bool = bool(c["fast"])
	var ei: int = int(c["ei"])
	# 项目 playFinish：500ms 直线到终点槽 -> 切勾号 -> 停 FINISH_DELAY=500
	if pl <= 0 or ci < 0: return
	# ★ 项目 moveChessToFinish（animation.js:246-306）：
	#   起点 = 棋子【当前】位置（此时 walk 已把它带到终点格 56），
	#   终点 = 自己的停机坪机位 startPositions[player][chessIndex]。
	#   我原来用 before（走格前的位置）当起点是错的。
	# 项目 moveChessToFinish 开头 audioManager.playFlySound()（:269），落地才 playFinishSound（:299）
	# M6: 参考滑行期间 chess.position 仍是 56 -> positionRotation=270，落地才切正朝上的勾号
	_anim_push(k, [board_pos(pl, 56), _base_slot(pl, ci)], BACK, "glide", _heading(pl, 56), "fly", 56, "finish", [], 0, {}, 56, false, true, {"e": e})
	got.append(ei)
	# M1: 参考里 sleep(FINISH_DELAY) 与 500ms 位移重叠，不额外加停顿

## 事件 builder：beat
func _anim_ev_beat(c: Dictionary) -> void:
	var e: Dictionary = c["e"]
	var pl: int = int(c["pl"])
	var ci: int = int(c["ci"])
	var k: String = str(c["k"])
	var t: String = str(c["t"])
	var got: Array = c["got"]
	var GLIDE: float = float(c["GLIDE"])
	var BACK: float = float(c["BACK"])
	var before: Dictionary = c["before"]
	var fast: bool = bool(c["fast"])
	var ei: int = int(c["ei"])
	# 项目 playBeat：被害棋子 500ms 直线回自己基地（起点用移动前的快照）
	var tp := int(e.get("targetPlayer", 0))
	var tc := int(e.get("chess", -1))
	if tp <= 0 or tc < 0: return
	var kk := "%d_%d" % [tp, tc]
	var from_pos: int = int(before.get(kk, -1))
	if from_pos < 0: return        # 取不到起点就跳过，别从起飞格飞回来
	# 积分粒子：参考 energyManager.js:107-117 —— 起点是【被击败的棋子所在格】，
	# 拿分的是【攻击方 pl】。挂在这一段上，等它开播才触发（不是事件解析时）。
	var epar: Dictionary = {}
	var eg2: int = _display_energy(e)
	# ★ 所有模式都发粒子（打击特效）；只有道具模式下这些粒子才会飞向积分条
	if eg2 > 0:
		epar = {"from": to_screen(board_pos(tp, from_pos)), "player": pl, "amount": eg2}
	# ★ bg=true：参考 playBeat 全程没有 await，被害棋子飞回家的 500ms 与后续事件并行。
	_anim_push(kk, [board_pos(tp, from_pos), _base_slot(tp, tc)], BACK, "glide", float(seat_rot.get(tp, 0.0)), "beat", -1, "", [], 0, epar, from_pos, true, true, {"e": e})
	got.append(ei)
# 欢乐碰撞的积分粒子：在【本事件这一帧】压一个极短 hold 段并显式带 epar。
# ★ 不能用 pending_epar（登记在解析阶段、_build_anim 在其后，同批先发的 walk 会把它抢走；
#   而且 pending 以玩家为键，一次连锁多条会互相覆盖）。放在事件链里，队列顺序天然正确。
# 起点用【被撞的棋子】（参考 energyManager.js:139-142），不是走子者的出发格。

## 事件 builder：collision_bonus
func _anim_ev_collision_bonus(c: Dictionary) -> void:
	var e: Dictionary = c["e"]
	var pl: int = int(c["pl"])
	var ci: int = int(c["ci"])
	var k: String = str(c["k"])
	var t: String = str(c["t"])
	var got: Array = c["got"]
	var GLIDE: float = float(c["GLIDE"])
	var BACK: float = float(c["BACK"])
	var before: Dictionary = c["before"]
	var fast: bool = bool(c["fast"])
	var ei: int = int(c["ei"])
	# 参考 playCollisionBonus(enginePlayback.js:204-222)：先 playBeatSound【无条件】，
	# 再补战报/粒子，最后 await COLLISION_BONUS_DELAY(200ms) 停顿。
	# 原来只有"有分且道具模式"时才压一个 0.02s 占位段 —— 没音效、也没那 200ms 停顿。
	var eg5 := _display_energy(e)
	var vp5 := int(e.get("targetPlayer", 0))
	var vc5 := int(e.get("targetChess", -1))
	var vq5: int = int(before.get("%d_%d" % [vp5, vc5], -1))
	var p5: Vector2 = to_screen(board_pos(vp5, vq5)) if (vp5 > 0 and vc5 >= 0 and vq5 >= 0) else dice_center()
	var epar5 := {}
	if eg5 > 0:
		epar5 = {"from": p5, "player": int(e.get("player", 0)), "amount": eg5}
	cur_grp += 1
	_anim_push("epar_%d" % cur_grp, [p5, p5], 0.02 if fast else 0.2, "hold", INF, "beat", -999, "", [], 0, epar5, -999, false, false, {"e": e})
	got.append(ei)

## 事件 builder：collide
func _anim_ev_collide(c: Dictionary) -> void:
	var e: Dictionary = c["e"]
	var pl: int = int(c["pl"])
	var ci: int = int(c["ci"])
	var k: String = str(c["k"])
	var t: String = str(c["t"])
	var got: Array = c["got"]
	var GLIDE: float = float(c["GLIDE"])
	var BACK: float = float(c["BACK"])
	var before: Dictionary = c["before"]
	var fast: bool = bool(c["fast"])
	var ei: int = int(c["ei"])
	# 项目 playCollide：先停 CRASH_DELAY=200，再双方各自 500ms 回基地
	if pl <= 0: return
	# ★ collide 事件没有 chess 字段（engine.gd:367），得用 last_mover 找回撞人方。
	#   我原来用 ci=-1 拼出 "P_-1" 这个键，_draw_pieces 永远取不到 -> 撞人方瞬移。
	var cp: int = int(last_mover.get("p", pl))
	var cci: int = int(last_mover.get("i", -1))
	if cp <= 0 or cci < 0: return
	var ck := "%d_%d" % [cp, cci]
	# ★ 参考 animation.js:130-135 取的是元素【当前】坐标 = 撞到叠子的那一格。
	#   用 before（走子前）会让棋子在停顿里先跳回旧格再飞回家。
	# ★★ 起点还必须带上【叠子散开偏移】：受害的一对叠子本来是散开的，
	#    参考取元素实时坐标 -> 撞人方走子的整段时间里它们保持散开；
	#    用格心当起点，它们会在本批第 0 帧就叠合成一个点（散开被提前破坏）。
	var snap_c: Dictionary = before.duplicate()
	snap_c[ck] = int(last_walk_to.get(ck, before.get(ck, 0)))
	var ccell: int = int(snap_c[ck])
	var start_p: Vector2 = _spread_pos(cp, cci, snap_c, st.players[cp].chesses)
	_anim_hold(ck, start_p, 0.02 if fast else 0.2, ccell, {"e": e})
	got.append(ei)
	# ★ 停顿必须和飞行【分成两组】：_anim_step 是「同组并行、跨组串行」，
	#   原来 hold 与 glide 共用 cur_grp，0.2s 后 hold 被移除时 glide 已经跑到 t=0.4
	#   （ease-out = 78%）-> 棋子瞬移 78% 再飞完。
	for v0 in e.get("chesses", []):
		var vp0 := int(v0.player); var vi0 := int(v0.index)
		var vk0 := "%d_%d" % [vp0, vi0]
		_anim_hold(vk0, _spread_pos(vp0, vi0, before, st.players[vp0].chesses), 0.02 if fast else 0.2,
			int(before.get(vk0, 0)))
	cur_grp += 1                       # 停顿结束，换下一组：双方各自飞回家
	# 参考 playCollide 全程不播音效（对比 playBeat 才有 playBeatSound）
	# 两边回基地也都是旁路段（参考 playCollide 的 moveChessToStart 没有 await），
	# 只有前面那 200ms 的 CRASH_DELAY 停顿是阻塞的。
	_anim_push(ck, [start_p, _base_slot(cp, cci)], BACK, "glide", float(seat_rot.get(cp, 0.0)), "", -1,
		"", [], 0, {}, ccell, true, true)
	# ★ 道具模式下撞叠子【也要发积分粒子】（参考 playCollide:274-279）：
	#   积分按叠子上的颗数逐颗均分，每颗的粒子从【被撞的那颗棋子】飞出来，
	#   并用 CRASH_ENERGY_DELAY(120ms) 依次错开。原来这条分支一个 epar 都没挂
	#   -> 积分条直接跳涨、一颗粒子都没有（audit 03-缺陷2）。
	var c_en: int = _display_energy(e)
	var c_vs: Array = e.get("chesses", [])
	var c_n: int = c_vs.size()
	var c_share: int = int(c_en / c_n) if c_n > 0 else 0
	var c_i := 0
	for v in c_vs:
		var vp := int(v.player); var vi := int(v.index)
		var vk := "%d_%d" % [vp, vi]
		var vcell: int = int(before.get(vk, 0))
		var vstart: Vector2 = _spread_pos(vp, vi, before, st.players[vp].chesses)
		var vep := {}
		if c_en > 0:        # 所有模式都发粒子；只有道具模式才会飞向积分条
			var amt: int = c_en - c_share * c_i if c_i == c_n - 1 else c_share
			if amt > 0:
				vep = {"from": to_screen(vstart), "player": cp, "amount": amt,
					"delay": float(c_i) * CRASH_ENERGY_DELAY}
		_anim_push(vk, [vstart, _base_slot(vp, vi)], BACK, "glide",
			float(seat_rot.get(vp, 0.0)), "", -1, "", [], 0, vep, vcell, true, true)
		c_i += 1

## 事件 builder：teleport
func _anim_ev_teleport(c: Dictionary) -> void:
	var e: Dictionary = c["e"]
	var pl: int = int(c["pl"])
	var ci: int = int(c["ci"])
	var k: String = str(c["k"])
	var t: String = str(c["t"])
	var got: Array = c["got"]
	var GLIDE: float = float(c["GLIDE"])
	var BACK: float = float(c["BACK"])
	var before: Dictionary = c["before"]
	var fast: bool = bool(c["fast"])
	var ei: int = int(c["ei"])
	# 传送门重做（v18.7）：不再整盘聚光冲淡，改成【收束 + 重组】的本地环形能量场，全局 0.9s。
	# 参考业界常见做法：Dissolve & Teleport / Energy Ring Portal / Magic Ring。
	if pl <= 0 or ci < 0: return
	var tf: int = int(e.get("from", 0))
	var tt: int = int(e.get("to", 0))
	tele_from = board_pos(pl, tf)
	tele_to = board_pos(pl, tt)
	tele_key = k
	tele_fx = ""
	tele_fx_t = 0.0
	tele_scale = 1.0
	tele_spin = 0.0
	# ① 收束（0.45s）：fly 音在起点响，棋子缩小旋转淡出
	_anim_push(k, [tele_from, tele_from], 0.02 if fast else 0.45, "tpx",
		INF, "fly", tf, "", [], 0, {}, tf, false, false, {"e": e})
	got.append(ei)
	# ★ 同一事件里 push 的段是【并行】的（同 cur_grp），收束与重组必须换组才串行
	cur_grp += 1
	# ② 重组（0.45s）：棋子从落点中心弹出
	_anim_push(k, [tele_to, tele_to], 0.02 if fast else 0.45, "tpy",
		INF, "", tt, "", [], 0, {}, tt)

## 事件 builder：reset
func _anim_ev_reset(c: Dictionary) -> void:
	var e: Dictionary = c["e"]
	var pl: int = int(c["pl"])
	var ci: int = int(c["ci"])
	var k: String = str(c["k"])
	var t: String = str(c["t"])
	var got: Array = c["got"]
	var GLIDE: float = float(c["GLIDE"])
	var BACK: float = float(c["BACK"])
	var before: Dictionary = c["before"]
	var fast: bool = bool(c["fast"])
	var ei: int = int(c["ei"])
	# 项目 playReset：event.pieces 逐颗 500ms 回基地（我原来只取 e.chess，是死代码）
	if pl <= 0: return
	# ★ 事件里的 pieces 含所有【未完成】棋子，**包含本来就在基地的**：
	#   engine.mjs 里 sendHome 对基地棋子是空操作，但编号照样 push 进 pieces。
	#   参考的 moveChessToStart 是从【元素当前坐标】飞到自己的槽位 -> 基地棋子原地不动。
	#   我原来用 board_pos(pl, before)，而基地棋子的 before 是 -1 -> board_pos 越界返回
	#   Vector2.ZERO -> 变成「从棋盘左上角飞回来」。这里直接跳过基地棋子。
	var rl2: Array = e.get("pieces", [])
	var first_moved := true
	for idx in rl2:
		var ri := int(idx)
		var rk := "%d_%d" % [pl, ri]
		var bpos2: int = int(before.get(rk, -1))
		if bpos2 < 0: return        # 本来就在停机坪 -> 不做动画
		# 参考 playReset:298 整段只播一次 beat 音（不是每颗一次）
		# ★ 起点同样取「此刻真正画在哪」：三连6 复位时几颗棋子可能正叠在一格上，
		#   用格心当起点会让它们在起飞前先叠合成一个点。
		_anim_push(rk, [_spread_pos(pl, ri, before, st.players[pl].chesses), _base_slot(pl, ri)], BACK, "glide",
			float(seat_rot.get(pl, 0.0)), "beat" if first_moved else "", -1, "", [], 0, {}, bpos2, false, true,
			{"e": e} if first_moved else {})
		if first_moved: got.append(ei)
		first_moved = false
		# 项目 playReset 结尾 await sleep(FINISH_DELAY=500)
		# M1: 参考的 sleep(FINISH_DELAY) 与 500ms 位移重叠，不额外加停顿