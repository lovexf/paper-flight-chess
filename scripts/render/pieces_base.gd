extends "res://scripts/ui/item_bar_base.gd"
## ============================================================
## 渲染基类（方案 1 · 批次 3）：棋子 / 坐标换算 / 起飞点 / 朝向
##   继承链：screens_base ← render_base ← item_bar_base ← pieces_base ← game_main
## ============================================================

var headings := {}            # 棋子朝向（度，目标值）
var headings_vis := {}        # M5: 视觉朝向
var head_from := {}           # M5: 本次转向的起点角
var head_t := {}              # M5: 本次转向已用时间
var head_tgt := {}            # M5: 上次记录的目标角（用来检测"目标变了"）
var last_land := {}
var land_seq := 0             # lastLandPos 递增序号（参考 generateUniqueLastLandPos）
var last_mover := {"p": 0, "i": -1}   # 这一手在动的是谁（参考 enginePlayback.js:32-34）
var last_walk_to := {}        # H2: 每颗棋子最后一次走到的格子（collide 起点用）        # 骰子抖动剩余时间（项目 diceShake 0.5s ±3px）          # "pid_i" -> 最后落点（项目 chess.lastLandPos，用于叠子排序）
var track_rot: Array = []     # 每个位置的轨道朝向（项目 calculateTrackRotations）
## 座位 pl 在位置 pos 的棋子朝向（度）
func _heading(pl: int, pos: int) -> float:
	if pos < 0 or pos >= track_rot.size(): return float(seat_rot.get(pl, 0.0))
	return float(track_rot[pos]) + float(seat_rot.get(pl, 0.0))

## 每个座位在环上的起飞点（棋子起飞后落在这里）
func _draw_launch_points() -> void:
	if screen != Scr.PLAY or st.winner != null: return
	var pid := int(st.currentPlayer)
	var can := false
	for pc in st.players[pid].chesses:
		if int(pc.pos) == E.BASE: can = true; break
	if not can: return
	var s := board_scale
	var col: Color = cols[pid]
	var c := to_screen(board_pos(pid, 0))
	draw_arc(c, 4.0 * s, 0, TAU, 26, Color(col.r, col.g, col.b, 0.9), 1.6 * s)
	draw_arc(c, 2.4 * s, 0, TAU, 26, Color(col.r, col.g, col.b, 0.55), 1.2 * s)

func _draw_pieces() -> void:
	var order := [1, 2, 3, 4]
	var cur := int(st.currentPlayer)
	order.erase(cur); order.append(cur)
	# L4: 正在动的棋子跳过，最后单独画一遍置顶（参考 animation.js:479-490 bringToFront）
	var ak := "" if seq.is_empty() else str(seq[0].k)
	for pid in order:
		if not st.players.has(pid): continue
		for i in st.players[pid].chesses.size():
			if "%d_%d" % [pid, i] == ak: continue
			_draw_one_piece(pid, i)
	if ak != "":
		var ap := ak.split("_")
		if ap.size() == 2:
			var api := int(ap[0])
			var aci := int(ap[1])
			if st.players.has(api) and aci >= 0 and aci < st.players[api].chesses.size():
				_draw_one_piece(api, aci)

func _draw_one_piece(pid: int, i: int) -> void:
	var s := board_scale
	var cs: Array = st.players[pid].chesses
	var movable := _can_move_vis(pid, i)
	var palpha: float = float(tele_alpha.get("%d_%d" % [pid, i], 1.0))
	if palpha <= 0.02: return            # 传送门淡出到全透明那两帧：整颗不画（省掉一批绘制命令）
	var is_tele: bool = tele_key != "" and "%d_%d" % [pid, i] == tele_key

	var r := 5.61 * s   # 纹理可见圆占半宽 14/16.5，补偿后可见半径=4.76 棋盘单位（项目 #chess scale 0.34）
	var pos := _piece_pos(pid, i, cs)
	# ★ 到达终点：飞回停机坪后显示勾号（项目 animation.js:277 href='#checkmark'）
	# ★ 只有动画播完才显示勾号。状态是先行落地的（st = res.state），
	#   若不加这个判断，棋子在"开始走格"那一帧就变勾号了。
	if bool(cs[i].finished) and not _has_anim("%d_%d" % [pid, i]):
		# M7: 按 #checkmark 的 glyph 几何画（外环 r=14 宽 3 + 内盘 r=13 + 勾）
		#     r 是 16.5 单位的半径基数，用 r*(x/16.5) 换算
		var u := r / 16.5
		# ★ 原来是 draw_circle(pos, r*0.94)：零偏移且半径正好 = glyph 外缘 -> 被完全盖住，等于没画。
	#   参考 style.css 的 drop-shadow(0 1px 1px) 是【向下偏 1px】。
		draw_circle(pos + Vector2(0.0, 1.0), r * 0.94, Color(0, 0, 0, 0.14))
		draw_arc(pos, 14.0 * u, 0.0, TAU, 40, cols[pid], 3.0 * u)
		draw_circle(pos, 13.0 * u, cols[pid])
		var p1 := pos + Vector2(-7.5, 0.5) * u
		var p2 := pos + Vector2(-2.0, 6.0) * u
		var p3 := pos + Vector2(7.5, -5.5) * u
		var lw := maxf(2.0, 3.5 * u)
		var cc := Color(1, 1, 1, 0.6)
		draw_line(p1, p2, cc, lw)
		draw_line(p2, p3, cc, lw)
		draw_circle(p1, lw * 0.5, cc)
		draw_circle(p2, lw * 0.5, cc)
		draw_circle(p3, lw * 0.5, cc)
		return
	# L1: 棋子整体投影。参考是 drop-shadow(0 1px 1px) 被 JS 每帧换成
	#     drop-shadow(sinθ, cosθ, 0.5px, rgba(0,0,0,0.2))，永远朝屏幕下方。
	#     ★ 关键是【略微大于棋子轮廓 + 小偏移】才会露出干净的底缘；
	#       上一版用 r*0.94（=棋子本身大小）+ 下移 1.0 单位，露出一大块深色月牙。
	#     这里三层【同 alpha、半径递减】近似模糊（alpha 都是 0.10，别写成"递减 alpha"）。
	# ★ 原来每颗画 3 条同色圆（16 颗 = 48 条/帧），三层 alpha 全是 0.10、半径只差 5%，
	#   观感提升有限（audit 02-「可合并」）。并为 1 条后每帧省 32 条绘制命令。
	if not is_tele:
		draw_circle(pos + Vector2(0, 0.26 * s), r * 0.99, Color(0, 0, 0, 0.20 * palpha))
	var tex: Texture2D = (piece_tex_sel if movable else piece_tex).get(pid, null)
	if tex != null:
		var prot: float = deg_to_rad(float(headings_vis.get("%d_%d" % [pid, i], float(headings.get("%d_%d" % [pid, i], float(seat_rot.get(pid, 0.0)))))))
		var psc := Vector2.ONE
		if is_tele:
			# 传送中：额外旋转 + 缩放（收束缩小 / 重组弹入）
			prot += tele_spin
			psc = Vector2(tele_scale, tele_scale)
		draw_set_transform(pos, prot, psc)
		draw_texture_rect(tex, Rect2(Vector2(-r, -r), Vector2(r, r) * 2.0), false, Color(1, 1, 1, palpha))
		# ★ 必须先复位变换再画描边：原来复位在最后，draw_arc 是在"已平移+已旋转"
		#   的空间里画的，被二次偏移 -> 变成一个飘到棋盘别处的黑圈
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# L7: 叠子（同玩家同格 >=2）描边高亮（参考 .chess-stacked stroke 1.5px）
	# M8: 参考 animation.js:389-400 —— stackOffset!=0 且 位置!=0 且 不在终点通道(51..56, 除 53)
	var ps: int = _vis_cell(pid, i, cs)   # ★ 用视觉格，不用超前的逻辑 pos
	var in_stack_zone: bool = ps != E.BASE and ps != 0 and not (ps >= 51 and ps <= 56 and ps != 53)
	var stacked := false
	if in_stack_zone:
		for j2 in cs.size():
			if j2 != i and not bool(cs[j2].finished) and _vis_cell(pid, j2, cs) == ps:
				stacked = true; break
	if stacked:
		# 参考 .chess-stacked: stroke-width 1.5px 作用在 r=13 内盘上 -> 细环略深略粗
		draw_arc(pos, 13.0 * (r / 16.5), 0.0, TAU, 32, Color(0, 0, 0, 0.3 * palpha), 1.5 * (r / 16.5))


## 用【本批动画开始前】的位置快照，算某颗棋子当时到底画在哪（含叠子散开偏移），返回棋盘单位。
## ★ 供 collide / reset 这类「从当前位置起飞」的段当起点用：
##   参考 animation.js:131-132 / :259-260 取的是【元素实时坐标】，也就是散开后的落点，
##   不是格心。用格心当起点，一对叠子会从本批第 0 帧就叠合成一个点（散开效果被提前破坏）。
func _spread_pos(pid: int, i: int, snap: Dictionary, cs: Array) -> Vector2:
	var cell: int = int(snap.get("%d_%d" % [pid, i], int(cs[i].pos)))
	if cell < 0: return _base_slot(pid, i)          # 本来就在基地：用槽位
	if bool(cs[i].finished): return _base_slot(pid, i)
	# 同格分组口径与 _piece_pos 的叠子分支保持一致（只用快照里的格子号）
	var same: Array = []
	for j in cs.size():
		if bool(cs[j].finished): continue
		var cj: int = int(snap.get("%d_%d" % [pid, j], int(cs[j].pos)))
		if cj == cell: same.append({"i": j, "land": int(last_land.get("%d_%d" % [pid, j], 0))})
	if same.size() <= 1: return board_pos(pid, cell)
	same.sort_custom(func(a, b): return int(a.land) < int(b.land))
	var si := 0
	for k2 in same.size():
		if int(same[k2].i) == i: si = k2
	var cnt: int = same.size()
	var base: float = 2.5 if cnt == 2 else (2.0 if cnt == 3 else 1.5)
	var mult := 0.0
	if cnt == 2:
		mult = -0.5 if si == 0 else 0.5
	elif cnt == 3:
		mult = [-1.0, 0.0, 1.0][si]
	else:
		mult = -(1.5 - float(si) * 0.5) if si < 2 else (float(si) - 1.5) * 0.5
	# 与 _piece_pos 一致：方向恒为水平轴，再按座位角旋转
	var dir := Vector2(1, 0).rotated(deg_to_rad(float(seat_rot.get(pid, 0.0))))
	return board_pos(pid, cell) + dir * base * mult

## 座位 pl 在位置 pos 的棋盘坐标（项目权威做法：mainTrack 表 + 按座位旋转）
func board_pos(pl: int, pos: int) -> Vector2:
	if pos < 0 or pos >= main_track.size():
		# ★ 非法位置不再悄悄返回 Vector2.ZERO。原点 = 棋盘左上角，
		#   会让棋子"从左上角飞出来"，非常难查（已经因此出过两次：
		#   特殊格 ID 缺失 -> 飞到棋盘中心；基地棋子 -1 -> 飞到左上角）。
		#   改成返回一个明显异常的值 + 报错，越界会立刻暴露。
		push_error("board_pos: 非法位置 pos=%d (玩家 %d)" % [pos, pl])
		return Vector2(99999.0, 99999.0)
	var v := Vector2(float(main_track[pos][0]), float(main_track[pos][1]))
	var a: float = deg_to_rad(float(seat_rot.get(pl, 0.0)))
	return Vector2(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a))

func _piece_pos(pid: int, i: int, cs: Array) -> Vector2:
	var c: Dictionary = cs[i]
	var s := board_scale
	# ★ 移动动画：沿路径逐格插值，而不是瞬移
	var key_anim := "%d_%d" % [pid, i]
	var qs: Dictionary = _seq_find(key_anim)
	if not qs.is_empty():
		# 还没轮到这一段（串行队列里排在后面）-> 停在它的起点
		if not bool(qs.get("started", false)):
			return to_screen((qs.pts as Array)[0] as Vector2)
		else:
			var sg: Dictionary = qs
			var pts: Array = sg.pts
			var t: float = clampf(float(qs.t), 0.0, 1.0)
			# 传送门：前半段留在原地淡出，后半段直接出现在落点淡入（不做位移插值）
			if str(sg.get("mode", "glide")) == "tele":
				return to_screen((pts[0] if t < 0.5 else pts[pts.size() - 1]) as Vector2)
			if pts.size() >= 2:
				var wp: Vector2
				# 走子：重叠过渡（对齐项目 CSS transition 0.3s + 每 190ms 换目标格）
				if str(sg.get("mode", "glide")) == "steps" and sg.has("vis"):
					return to_screen(qs["vis"] as Vector2)
				# 兜底：没有 vis 状态时按整段线性推进
				if str(sg.get("mode", "glide")) == "steps":
					var seg: float = t * float(pts.size() - 1)
					var k: int = mini(int(seg), pts.size() - 2)
					var f: float = seg - float(k)
					var fe: float = f * f * (3.0 - 2.0 * f)
					wp = (pts[k] as Vector2).lerp(pts[k + 1] as Vector2, fe)
				else:
					# L5: 500ms 回基地/进终点这类直线位移，参考用 ease-out（1-(1-p)^3）；
					#     跳子/飞棋（dur≈0.31）仍是 ease-in-out，与 CSS chess-transition 一致
					var e: float
					if float(sg.dur) >= 0.45:
						e = 1.0 - pow(1.0 - t, 3.0)
					else:
						e = t * t * (3.0 - 2.0 * t)
					wp = (pts[0] as Vector2).lerp(pts[pts.size() - 1] as Vector2, e)
				return to_screen(wp)
			return to_screen(pts[pts.size() - 1] as Vector2)
	if int(c.pos) == E.BASE:
		# ★ 必须和 _base_slot() 用同一套坐标（它按座位角旋转了槽位）。
		#   否则动画飞到"旋转后的正确槽位"，动画结束这里又瞬移回"未旋转的槽位"，
		#   表现为"先回同一个格子再跳过去"，而且被击败的棋子会压到完成棋子上。
		return to_screen(_base_slot(pid, i))
	if bool(c.finished):
		# 完成的棋子停在【自己的停机坪机位】（项目 moveChessToFinish 的落点）
		return to_screen(_base_slot(pid, i))
	var pos: int = int(c.pos)
	# 同格偏移：用"全体共用的格子号"判断谁和谁同格，但坐标走 mainTrack
	# ★ 叠子散开，逐行对齐项目 animation.js:495-569 calculateStackOffset：
	#   只统计【同一玩家】同位置的棋子，按 lastLandPos 升序定 stackIndex，
	#   沿【单轴】线性偏移，幅度 = baseOffset(2.5/2.0/1.5) × offsetMultiplier
	var same: Array = []
	for j in cs.size():
		var cj: Dictionary = cs[j]
		if bool(cj.finished) or int(cj.pos) == E.BASE: continue
		if _vis_cell(pid, j, cs) == pos:   # ★ 同上
			same.append({"i": j, "land": int(last_land.get("%d_%d" % [pid, j], 0))})
	if same.size() <= 1:
		return to_screen(board_pos(pid, pos))
	same.sort_custom(func(a, b): return int(a.land) < int(b.land))
	var si := 0
	for k2 in same.size():
		if int(same[k2].i) == i: si = k2
	var cnt: int = same.size()
	var base: float = 2.5 if cnt == 2 else (2.0 if cnt == 3 else 1.5)
	var mult := 0.0
	if cnt == 2:
		mult = -0.5 if si == 0 else 0.5
	elif cnt == 3:
		mult = [-1.0, 0.0, 1.0][si]
	else:
		mult = -(1.5 - float(si) * 0.5) if si < 2 else (float(si) - 1.5) * 0.5
	# 项目把 player 当 position 传给了 getChessRotationAtPosition，导致方向只随座位变：
	#   玩家1 -> -90 -> 水平轴；其余 -> 0 -> 垂直轴。这里照实复刻。
	# 参考 animation.js:537 把 player 当 position 传进 getChessRotationAtPosition，1..4 全部返回 -90
	# -> 判定为"水平轴"，随后整体被 rotate(baseRotation) 转到座位坐标系。所以 = (1,0) 按座位角旋转。
	var dir := Vector2(1, 0).rotated(deg_to_rad(float(seat_rot.get(pid, 0.0))))
	return to_screen(board_pos(pid, pos)) + dir * base * mult * s

## L12: 高亮用 —— 参考 uiUpdater.js:354-388 按当前玩家高亮，不区分人机
## 视觉所在格：正在播动画的棋子返回它【正在进入/要去】的格子，
## 而不是 state 里已落地的终态 pos。
## ★ st 是在 _apply 里一次性落到【整批事件的终态】的（st = res.state），
##   而动画队列要到 _build_anim 才建 —— 逻辑位置在整段动画期间都领先于画面。
##   叠子判定若读 cs[].pos，就会出现「棋子还没走到就变成叠子样式」，
##   而且【留在原地那颗】会被瞬移推离 + 提前描边（它没有动画段，更扎眼）。
func _vis_cell(pid: int, i: int, cs: Array) -> int:
	var key := "%d_%d" % [pid, i]
	# 找该棋子排在队首方向的那一段（不是 _seq_find：这里需要【序号】才能回看前一段）
	var idx := -1
	for n in seq.size():
		if str(seq[n].get("k", "")) == key:
			idx = n
			break
	if idx >= 0:
		var sg: Dictionary = seq[idx]
		var started: bool = bool(sg.get("started", false))
		# ★ 还没轮到这一段（串行队列里排在后面）：棋子仍然站在【起点格】——
		#   既不是 end_pos（目标格），也不是 cs[i].pos（整批终态）。
		#   撞叠子时受害棋子的 pos 已经是 -1，缺这一条就会在整段停顿里被判成「已回基地」
		#   -> in_stack_zone=false -> 叠子描边全程消失。
		if not started:
			var fp: int = int(sg.get("from_pos", -999))
			if fp != -999: return fp
		var rl: Array = sg.get("rels", [])
		if not rl.is_empty():
			# 走子段：还没开播 -> 停在【起点格】；开播了 -> 正在进入的那一格
			if not started: return int(rl[0])
			return int(rl[clampi(int(sg.get("stepIdx", 1)), 0, rl.size() - 1)])
		if started:
			var ep: int = int(sg.get("end_pos", -999))   # 跳/飞=to、起飞=0、完赛=56、回家=-1(BASE)、hold=站着的那格
			if ep != -999: return ep
	# 兜底：这一段没记起点格时，回看同键前一段的终点
	for m in range(idx - 1, -1, -1):
		if str(seq[m].get("k", "")) == key:
			var ep0: int = int(seq[m].get("end_pos", -999))
			if ep0 != -999: return ep0
			break
	return int(cs[i].pos)                           # 完全没有动画段：退回逻辑 pos


func _base_slot(pl: int, ci: int) -> Vector2:
	var bp: Array = D.bases[str(pl)]
	var offs: Array = [Vector2(-5.8, -5.8), Vector2(5.8, -5.8), Vector2(-5.8, 5.8), Vector2(5.8, 5.8)]
	# L3: 参考是 R(baseRotation)·startPositions[i]（animation.js:38-48），所以槽位也要随座位角旋转，
	#     否则"第 i 号棋子回哪个角"与参考不同（起始 4 颗都在家看不出，被踩回家/完成后就看得出了）
	var a: float = deg_to_rad(float(seat_rot.get(pl, 0.0)))
	return Vector2(float(bp[0]), float(bp[1])) + (offs[ci] as Vector2).rotated(a)

## 按引擎事件生成动画（移植自项目 enginePlayback.js 的 playWalk / playJumpLike）
## 返回：已经挂了战报、由段开播时再写的事件下标（其余事件由 _apply 立即写）


# ---- 棋子可动判定 / 动画中判定（棋子绘制依赖）----
func _can_move_vis(pid: int, i: int) -> bool:
	if screen != Scr.PLAY: return false
	# ★ 正在动的那颗棋子：参考在整个走子期间都保留 .chess-movable
	#   （uiUpdater.js:363-368 清别人不清它 + chessPiece.js:387-393 走完才摘）——
	#   参考那边这条是【由选中态驱动】的，根本没有 winner 门。
	var key := "%d_%d" % [pid, i]
	#   ★ 必须排在 winner 门【之前】：制胜那一手的 st.winner 在 _apply 里就落地了，
	#     排在后面的话，那颗棋子整段飞行都会掉回 0.5 的飞机图案。
	#   ★ 也不能只看 seq[0]：回基地的旁路组（bg）会排在同一颗棋子跳子/飞棋段的前面，
	#     只看队首会让连招中途闪一下普通贴图。
	for s in seq:
		if str(s.get("k", "")) != key: continue
		if bool(s.get("started", false)): return true
	# 刚入队、还没开播的那一帧（started 尚未置位）也要算"正在移动"
	if not seq.is_empty() and str(seq[0].get("k", "")) == key: return true
	if st.winner != null: return false
	if int(st.currentPlayer) != pid or st.phase != "selecting": return false
	return _movable_now(pid).has(i)

## （原 _can_move 已删除：全项目只有定义、没有任何调用点，与 _can_move_vis 重复）



## 道具栏：底部栏【上方】的一条横排（只在道具模式显示）

# ================================================================ 停机坪侧边积分条
# 移植自参考 energyDisplay.js + style.css:513-624
#   容器 10x60px、2px 玩家色描边、圆角；填充从底部升起，transition: height 0.5s ease


func _movable_now(pid: int) -> Array:
	if movable_ver != st_ver:
		movable_cache.clear()
		movable_order.clear()
		movable_ver = st_ver
	var k := "%d|%d|%s" % [pid, int(st.get("dice", 0)), str(st.get("phase", ""))]
	if movable_cache.has(k): return movable_cache[k]
	var arr: Array = E.movable_chess(st, pid, int(st.get("dice", 0)))
	_cache_put(movable_cache, movable_order, k, arr, 32)
	return arr
var show_result := false
var trans_t := 0.0             # #3 界面过渡剩余时间
var trans_next := -1           # #3 过渡到哪个界面（-1 = 无）
const TRANS_DUR := 0.42
var solo_timer := 0.0         # 唯一可动棋子的自动走子延时
var solo_key := ""            # 防重复触发
var _last_press_ms := 0       # 输入去重时间戳
# 玩家名用色（项目 theme.css:22-25 --player-N-border）
const BORDER_COLS := {1: "#93c8b2", 2: "#e9b489", 3: "#a3bfdc", 4: "#dd9793"}
## 结算名次徽章：1 金 / 2 银 / 3 铜 / 4 白（参考 style.css:4324-4343）
const ACT := {
	"launch": {"t": "[起飞]", "c": Color("#87d687")},
	"move":   {"t": "[移动]", "c": Color("#7890d4")},
	"jump":   {"t": "[跳子]", "c": Color("#7fc5db")},
	"fly":    {"t": "[飞棋]", "c": Color("#de8bef")},
}

## #3 带淡入淡出的界面切换（原来是一瞬间硬切，没有过渡感）
var main_track: Array = []
var movable_ver := -1
var movable_cache := {}
var movable_order: Array = []

# ---- 动画中判定 / 段查找 / 座位朝向（pieces 层需要）----
func _has_anim(k: String) -> bool:
	return not _seq_find(k).is_empty()

func _seq_find(k: String) -> Dictionary:
	for s in seq:
		if str(s.k) == k: return s
	return {}

## from_pos: 这一段【开播之前】棋子站在哪一格。
## ★ 串行队列里"还没轮到的段"必须知道棋子此刻站在哪 —— 既不是 end_pos（目标格），
##   也不是 cs[i].pos（整批终态）。撞叠子/被击败/三连6复位这些段都是"最后才播"的，
##   缺了它，受害棋子在别人走子的整段时间里会被当成已经回基地。
## bg: 旁路段。参考里 playBeat / playCollide 的【回基地位移没有 await】——
##     后面的事件不等它飞完（enginePlayback.js:231-251、:257-280）。
##     阻塞组会挡住后面的组，旁路组不会：队首轮到它就开播，同时后面的事件继续走。
## snap: 这一段起播瞬间就把朝向切到位（参考里带 no-transition 的那些段）。
## log_ev: {"e": 事件, "at": "start"|"end"} —— 战报跟着段走：参考是逐事件 await，
##         走子那条在【走完之后】才写，其余在各自段开播时写。

var seat_rot := {}
var screen := Scr.MODE
var piece_tex_sel := {}    # 可动状态：飞机图案不透明（项目 .chess-movable）