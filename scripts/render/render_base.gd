extends "res://scripts/ui/net_screens_base.gd"
## ============================================================
## 渲染基类（方案 1 · 批次 2）：停机坪积分条
##   从 game_main 整体外移的「积分条」模块：尺寸计算/绘制/缓动/满格脉冲。
##   继承链：screens_base ← render_base ← game_main
## ============================================================

## 底部面板/道具栏【显示用】的当前玩家与回合：参考是 play(events) 播完之后才 updateUI，
## 所以动画期间面板显示的仍是上一手的状态。st 是随终态一起落地的，直接读它会领先一整批。
var hud_cur := 1
var hud_round := 1
var energy_shown := {}         # pid -> 当前显示的高度比例（0..1），做 0.5s 缓动
var energy_text := {}          # 显示用的积分数值（与条同刻更新，见 _tick_energy）
var energy_sb := {}            # StyleBoxFlat 缓存（键=玩家/边框宽/圆角/颜色），避免每帧 new
var energy_fill_sb := {}       # 填充的圆角 StyleBox 缓存（键=玩家/内圆角）
var energy_sb_order: Array = []
var energy_fill_order: Array = []
func energy_bar_rect(pid: int) -> Rect2:
	var bp: Array = D.bases[str(pid)]
	var c := Vector2(float(bp[0]), float(bp[1]))
	var out := c.normalized()                 # 从棋盘中心指向该座位 = 朝外
	var scr := to_screen(c)
	var unit: Vector2 = to_screen(Vector2(ENERGY_BAR_W, ENERGY_BAR_H)) - to_screen(Vector2.ZERO)
	var cx: float = to_screen(c + out * 27.0).x
	# 纵向：上半屏的两个座位把积分条【底边】贴到停机坪底线；
	#       下半屏的两个把【顶边】贴到停机坪顶线（用户要求）
	var bscale: float = unit.y / ENERGY_BAR_H
	var half_px: float = 12.0 * bscale        # 停机坪半高（棋盘单位 24，让数值落在底线上）
	# 四个座位【用同一个公式】：条的【底边】落在数值上方 gap_px 处 ——
	# 这样四个颜色的"条 -> 数字"间距完全一致（之前下半屏用顶线算，间距不一样）。
	var gap_px: float = 20.0
	var down_px: float = 14.0
	var number_y: float = scr.y + half_px          # 数值所在的停机坪底线
	var cy: float = number_y - gap_px - unit.y * 0.5 + down_px
	return Rect2(cx - unit.x * 0.5, cy - unit.y * 0.5, unit.x, unit.y)

## 缓动（在 _process 里推进）。参考是 height 的 0.5s ease 过渡

# ---------------------------------------------------------------- 积分粒子 / 满格闪烁
# 移植自参考 energyDisplay.js:193-300 的 playEnergyParticles
#   第一阶段：从起点向外随机散开 20-60px（300-500ms，cubic-bezier(0.25,1,0.5,1)）
#   第二阶段：沿二次贝塞尔弧线飞向该玩家的积分条（500-800ms）
var eparts: Array = []          # 每个粒子的状态（由 ParticleLayer 读取绘制）
var particle_layer: ParticleLayer = null   # 独立的粒子画布层
var energy_hold := {}           # pid -> true：粒子的分还没飞到，积分条先【不涨】
var energy_hold_t := {}         # pid -> 已按住秒数（保险丝，防粒子异常没清导致永久冻住）
								#   （参考 energyManager.js:109-117 把 updateEnergyBar 放在粒子回调里）
var _eflash := 0.0              # 满格闪烁相位

## 生成粒子。amount 决定数量：clamp(amount/2 + rand(0..3), 6, 25)
## 参考 enginePlayback.js:183-186 的 beatDisplayEnergy：
## 【按规则该得的分演出】，不扣积分上限的溢出；老事件没有 reward 时退回实际入账值。
## ★ 原来直接用 energy（grant_energy 封顶后的差值）—— 玩家接近 100 分时粒子会明显变少。
func _display_energy(e: Dictionary) -> int:
	if e.has("reward"): return int(e.get("reward", 0))
	return int(e.get("energy", 0))

## cubic-bezier(x1,y1,x2,y2) 在给定 x 处求 y：按 x 二分反解参数 t，再算 y。
## 参考 energyDisplay.js:274 的散开缓动就是 cubic-bezier(0.25, 1, 0.5, 1)。
## 满格闪烁的强度（0..1）。参考只写了 class 没有 CSS，这里按语义实现成脉冲
func _energy_full_pulse(pid: int) -> float:
	if int(st.energy.get(pid, 0)) < int(E.ENERGY_MAX): return 0.0
	return 0.5 + 0.5 * sin(_eflash * 6.0)

## 某个座位停机坪【底线】的屏幕 y（积分数值要对齐到这条线）
func energy_value_y(pid: int) -> float:
	var bp: Array = D.bases[str(pid)]
	var c := Vector2(float(bp[0]), float(bp[1]))
	var unit: Vector2 = to_screen(Vector2(ENERGY_BAR_W, ENERGY_BAR_H)) - to_screen(Vector2.ZERO)
	var half_px: float = 12.0 * unit.y / ENERGY_BAR_H
	return to_screen(c).y + half_px + NUM_DOWN_PX

func _tick_energy(delta: float) -> void:
	for pid in st.order:
		var tgt: float = clampf(float(int(st.energy.get(pid, 0))) / float(E.ENERGY_MAX), 0.0, 1.0)
		var cur: float = float(energy_shown.get(pid, tgt))
		# 保险丝：按住超过 4 秒就放行（粒子异常没清也不能永久冻住积分条）
		if bool(energy_hold.get(pid, false)):
			energy_hold_t[pid] = float(energy_hold_t.get(pid, 0.0)) + delta
			if float(energy_hold_t[pid]) > 4.0:
				energy_hold.erase(pid)
				energy_hold_t.erase(pid)
		# 粒子的分还在飞 -> 先不涨（降不受影响，买道具要立刻反馈）
		if bool(energy_hold.get(pid, false)) and tgt > cur:
			continue
		# ★ 数值与条【同一刻】更新：参考 updateEnergyBar 里 fill.height 与 .energy-value 是一起写的，
		#   而且是在粒子回调里调用的。原来数值直接读终态 st.energy -> 比条早 0.3~0.9s。
		energy_text[pid] = int(st.energy.get(pid, 0))
		if absf(cur - tgt) < 0.002:
			energy_shown[pid] = tgt
		else:
			# ★ 变了就必须请求重绘：否则没有动画在跑时 _draw 不被触发，
			#   升高时恰好有粒子在刷帧所以平滑，降低时就是"跳变"
			energy_shown[pid] = move_toward(cur, tgt, delta / ENERGY_EASE)
			queue_redraw()

func _draw_energy_bars() -> void:
	if not bool(st.get("skillMode", false)): return
	var font := ThemeDB.fallback_font
	for pid in st.order:
		_draw_one_energy_bar(int(pid), font)

## 画单个座位的停机坪积分条（容器/满格柔光/底部填充/数值）
func _draw_one_energy_bar(pid_i: int, font: Font) -> void:
	var r := energy_bar_rect(pid_i)
	var col: Color = cols.get(pid_i, Color.WHITE)
	var lw: float = maxf(1.5, r.size.x * 0.16)          # 参考的 2px 描边
	# 容器：透明底 + 玩家色描边 + 圆角
	# >= 100 时闪烁：边框加粗 + 外发光（参考只加了 class 没写 CSS，这里按语义补上）
	var pulse: float = _energy_full_pulse(pid_i)
	# ★ 满格柔光：原来是 draw_rect 画的【硬边矩形】，看着是一圈生硬的线。
	#   改用 StyleBoxFlat 的 shadow 做真正的外发光（由内向外衰减），
	#   再用两层递减 alpha 的圆角框叠出柔和的过渡。
	if pulse > 0.02:
		var gr: int = int(round(r.size.x * 0.55 * (0.5 + 0.5 * pulse)))
		draw_style_box(_sb(col, int(round(r.size.x * 0.32)), 0, Color(0, 0, 0, 0),
			Color(col.r, col.g, col.b, 0.55 * pulse), gr), r)

	# ★ StyleBoxFlat 缓存：原来每帧每个玩家都 new 一个（4 次/帧的对象分配 + 样式重算），
	#   满格闪烁时每帧参数都在变，分配更频繁 —— 这是踩子瞬间掉帧的主要嫌疑。
	#   现在只在"边框宽/颜色/圆角"真的变化时才重建。
	var bw: int = int(round(lw + lw * 0.8 * pulse))
	var bc: Color = col.lerp(Color.WHITE, 0.45 * pulse)
	var cr: int = int(round(r.size.x * 0.32))
	var ck := "%d_%d_%d_%d" % [pid_i, bw, cr, int(bc.to_rgba32())]
	var sb: StyleBoxFlat = energy_sb.get(ck)
	if sb == null:
		sb = StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, 0.55)
		sb.set_border_width_all(bw)
		sb.border_color = bc
		sb.set_corner_radius_all(cr)
		# 只有 4 个玩家 × 少量 pulse 档位，缓存不会膨胀
		_cache_put(energy_sb, energy_sb_order, ck, sb, 64)   # 满格 pulse 每帧新键 -> 靠淘汰保命
	draw_style_box(sb, r)
	# 填充：从底部升起（参考 .energy-bar-fill bottom:0 + height:N%）
	var frac: float = clampf(float(energy_shown.get(pid_i, 0.0)), 0.0, 1.0)
	if frac > 0.001:
		var inner := r.grow(-lw)
		var fh: float = inner.size.y * frac
		var fr := Rect2(inner.position.x, inner.end.y - fh, inner.size.x, fh)
		# ★ 填充也要圆角：参考里填充是容器内的一个 div，容器 overflow:hidden，
		#   所以填充四角被裁成同样的圆角。原来 draw_rect 是硬边直角，
		#   涨到满格时四个直角会"戳出"圆角容器，看着很脏。
		var icr: int = maxi(0, cr - bw)
		var fk := "%d_%d" % [pid_i, icr]
		var fsb: StyleBoxFlat = energy_fill_sb.get(fk)
		if fsb == null:
			fsb = StyleBoxFlat.new()
			fsb.bg_color = col
			fsb.set_corner_radius_all(icr)
			_cache_put(energy_fill_sb, energy_fill_order, fk, fsb, 32)
		draw_style_box(fsb, fr)
	# 数值（参考 .energy-value：10px 粗体居中）
	# 数值对齐到停机坪【底线】（基线就落在这条线上）
	draw_string(font, Vector2(r.position.x - 14.0, energy_value_y(pid_i)),
		str(int(energy_text.get(pid_i, int(st.energy.get(pid_i, 0))))),
		HORIZONTAL_ALIGNMENT_CENTER, r.size.x + 28.0, 14, C_INK)


# ---- 粒子层（绘图用）；从 game_main 外移 ----
class ParticleLayer extends Control:
	var host: Node = null

	## 散开缓动的查表：cubic-bezier(0.25,1,0.5,1) 只依赖 x，预计算 33 个点，运行时线性插值。
	## ★ 原来每颗粒子每帧都做一次「10 轮二分反解 + 跨对象调用」——50 颗时粒子层要 6ms/帧。
	var ease_lut := PackedFloat32Array()
	## 粒子用一个预制的圆形贴图来画：draw_circle 每颗都是一次独立的多边形绘制（50 颗 = 50 次 draw call），
	## 同一张贴图的 draw_texture_rect 能被 GL 兼容渲染器合批。
	var dot_tex: Texture2D = null

	func _dot() -> Texture2D:
		if dot_tex != null: return dot_tex
		var sz := 32
		var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
		img.fill(Color(1, 1, 1, 0))
		var r := float(sz) * 0.5
		for y in sz:
			for x in sz:
				var dx: float = float(x) + 0.5 - r
				var dy: float = float(y) + 0.5 - r
				var d: float = sqrt(dx * dx + dy * dy)
				if d <= r - 1.0:
					img.set_pixel(x, y, Color(1, 1, 1, 1))
				elif d < r:
					img.set_pixel(x, y, Color(1, 1, 1, 1.0 - (d - (r - 1.0))))
		dot_tex = ImageTexture.create_from_image(img)
		return dot_tex

	static func _cubic_y(x: float, x1: float, y1: float, x2: float, y2: float) -> float:
		var lo := 0.0
		var hi := 1.0
		var t := x
		for _i in 12:
			t = (lo + hi) * 0.5
			var xt: float = 3.0 * (1.0 - t) * (1.0 - t) * t * x1 + 3.0 * (1.0 - t) * t * t * x2 + t * t * t
			if xt < x: lo = t
			else: hi = t
		return 3.0 * (1.0 - t) * (1.0 - t) * t * y1 + 3.0 * (1.0 - t) * t * t * y2 + t * t * t

	func _build_ease_lut() -> PackedFloat32Array:
		var out := PackedFloat32Array()
		for i in 33:
			out.append(_cubic_y(float(i) / 32.0, 0.25, 1.0, 0.5, 1.0))
		return out

	func _draw() -> void:
		if host == null or host.eparts.is_empty(): return
		if ease_lut.is_empty(): ease_lut = _build_ease_lut()
		for p in host.eparts:
			# ★ 每帧只取一次字段：原来每个字段都要走 Dictionary 查找（含 .get 默认值）
			var t: float = float(p.t)
			var sd: float = float(p.sd)
			var dl: float = float(p.get("dl", 0.0))
			var fd: float = float(p.fd)
			var sx: float = float(p.sx)
			var sy: float = float(p.sy)
			var cx: float = float(p.cx)
			var cy: float = float(p.cy)
			var tx: float = float(p.tx)
			var ty: float = float(p.ty)
			var pos: Vector2
			var alpha := 1.0
			var rad := 3.0
			if t < sd:
				# 第一阶段：散开，scale 0 -> 1（30% 处到 1）
				# ★ 参考 energyDisplay.js:274 用 cubic-bezier(0.25,1,0.5,1)：查表 + 一次线性插值
				var kk: float = t / sd * 32.0
				var i0: int = clampi(int(kk), 0, 31)
				var k: float = ease_lut[i0] + (ease_lut[i0 + 1] - ease_lut[i0]) * (kk - float(i0))
				pos = Vector2(float(p.x0), float(p.y0)).lerp(Vector2(sx, sy), k)
				var sc: float = clampf(k / 0.3, 0.0, 1.0)
				rad = 3.0 * sc
				alpha = minf(1.0, k / 0.3)
			elif t < sd + dl:
				# ★ 参考 energyDisplay.js:315：散开结束后再随机等 0~200ms 才起飞（错峰）
				pos = Vector2(sx, sy)
			elif not bool(p.get("fly", true)):
				# ★ 非道具模式（没有积分条可飞）：原地散开后直接淡出
				var kf: float = clampf((t - sd - dl) / fd, 0.0, 1.0)
				pos = Vector2(sx, sy)
				rad = 3.0 * (1.0 - kf * 0.6)
				alpha = 1.0 - kf
			else:
				# 第二阶段：贝塞尔飞向积分条
				var k2: float = (t - sd - dl) / fd
				# ★ P0 必须是【第一阶段结束的位置 sx/sy】，不是原始起点 x0/y0（参考 energyDisplay.js:281-293）。
				#   ★ 二次贝塞尔【内联】展开，不再每帧两次跨对象调用 host._bezier()。
				var u: float = 1.0 - k2
				var w0: float = u * u
				var w1: float = 2.0 * k2 * u
				var w2: float = k2 * k2
				pos = Vector2(w0 * sx + w1 * cx + w2 * tx, w0 * sy + w1 * cy + w2 * ty)
				# ★ 参考 energyDisplay.js:296 的 scale(1 - t*0.5)：飞行途中要缩小
				rad = 3.0 * (1.0 - k2 * 0.5)
				alpha = 1.0 - k2 * 0.3
			if rad > 0.2:
				draw_texture_rect(_dot(), Rect2(pos - Vector2(rad, rad), Vector2(rad, rad) * 2.0), false,
					Color(p.c, alpha))

# 亮色主题（取自项目 theme.css）
const ENERGY_EASE := 0.5       # 参考的 transition 时长
const NUM_DOWN_PX := 14.0      # 四个数值统一下移量（微调用）

# ---- 战报行生成（动画段的 log 回调要用）----
## 联机下这个事件是否来自「别的座位」（本地玩家/主机自己不算）
func _is_remote_net_seat(p: int) -> bool:
	var nm = get("net_mode")
	if nm == null or not bool(nm): return false
	var my = get("net_local_seat")
	if my == null: return false
	return int(p) != int(my)

func _log_event(e: Dictionary) -> void:
	# 文案与配色逐条对齐项目 gameInfo.js（原文案我改写过多处）
	var p := int(e.get("player", 0))
	match str(e.type):
		"dice":
			log_lines.append({"p": p, "t": " 摇到了 %d 点" % e.value, "k": "", "v": int(e.value)})
		"launch":
			log_lines.append({"p": p, "t": " 的棋子%d 出发了" % (int(e.get("chess", 0)) + 1), "k": "launch"})
		"walk":
			log_lines.append({"p": p, "t": " 选择了棋子%d " % (int(e.get("chess", 0)) + 1), "ks": ["move"], "ci": int(e.get("chess", 0))})
			# L9: 被叠子挡住时参考会补一条叠子战报（enginePlayback.js:132-150）
			if bool(e.get("bounced", false)) and str(e.get("bounceReason", "")) == "stack":
				log_lines.append({"p": p, "t": " 被 ", "k": "", "t2": "[叠子]", "t3": " 挡住了去路"})
		"jump":
			_chain_move(p, int(e.get("chess", 0)), "jump")
		"fly":
			_chain_move(p, int(e.get("chess", 0)), "fly")
		"beat":
			log_lines.append({"p": p, "t": " 击败 玩家%d！" % int(e.get("targetPlayer", 0)), "k": "beat"})
		"collide":
			log_lines.append({"p": p, "t": " 发生碰撞，双方碰撞的棋子返回起点", "k": ""})
		"finish":
			log_lines.append({"p": p, "t": " 的棋子%d 到达终点！" % (int(e.get("chess", 0)) + 1), "k": "finish"})
		"reset":
			dice_penalty = 1.2     # L1: 惩罚那一掷的骰面锁红（style.css dice-penalty-warning）
			board_toast_col = cols.get(p, Color.WHITE)
			board_toast = "玩家%d 连续摇出 3 次 6 点：全部棋子返回起点" % p
			board_toast_t = 2.8
			log_lines.append({"p": p, "t": " 连续摇到3次 6 点，所有棋子返回起点！", "k": "dice6"})
		"reroll":
			log_lines.append({"p": p, "t": " 获得 ", "k": "dice6", "t2": "[连投奖励]"})
		"collision_bonus":
			# ★ 参考 gameInfo.js:455 的文案与配色（--collision-bonus #efa0c0 即 style.css 的粉字）。
			#   原来这里是【两条同名分支】：match 只命中第一条，第二条永远不可达（死代码）；
			#   而第一条的 k:"collision" 在 ACT 里没有对应项 -> 粉色 [碰撞奖励] 从来没画出来过。
			log_lines.append({"p": p, "t": " 撞到 %d 颗，奖励前进 %d 步" % [int(e.enemyCount), int(e.steps)],
				"t2": "[碰撞奖励]", "kc": "#efa0c0"})
		"mystery_box":
			log_lines.append({"p": p, "t": " 打开盲盒，获得 %d 分" % int(e.amount), "k": ""})
		"item_activate":
			log_lines.append({"p": p, "t": " 购买了 %s（%d 分）" % [str(ACT_ITEM.get(str(e.item), str(e.item))), int(e.cost)], "k": ""})
		"item_cancel":
			log_lines.append({"p": p, "t": " 取消道具，退回 %d 分" % int(e.refund), "k": ""})
		"teleport":
			log_lines.append({"p": p, "t": " 的棋子%d 传送到了第 %d 格" % [int(e.chess) + 1, int(e.to)], "k": ""})
		"skip":
			# 项目：无法移动时骰子抖动并播 shake.wav（enginePlayback.js:503-509、534-545）
			# 联机：他人摇骰已经播过摇骰动画，这里不再叠一次抖动（否则看起来像“摇了两次”）
			if not _is_remote_net_seat(p):
				dice_shake = 0.5
				shake_sfx_t = 0.3     # L2: 参考在抖动开始 300ms 后才播 shake 音
			log_lines.append({"p": p, "t": " 无法移动任何棋子", "k": ""})
		"pass":
			if not _is_remote_net_seat(p):
				dice_shake = 0.5
				shake_sfx_t = 0.3     # L2: 参考在抖动开始 300ms 后才播 shake 音
			log_lines.append({"p": p, "t": " 无法移动任何棋子", "k": ""})
		"end":
			log_lines.append({"p": p, "t": " 获得胜利！", "k": "finish"})
		"stack":
			log_lines.append({"p": p, "t": " 的 ", "k": "", "t2": "[叠子]", "t3": " 形成了"})
		"blocked":
			log_lines.append({"p": p, "t": " 被 ", "k": "", "t2": "[叠子]", "t3": " 挡住了去路"})
		# ★ 原来这里还有第二条 "collision_bonus"：同一个 match 里重复的分支，
		#   永远不可达（死代码），而且那条的配色 k:"dice6" 也是错的 —— 已删除。
	if log_lines.size() > 40: log_lines = log_lines.slice(log_lines.size() - 40)

## 把一条战报拆成 [(文字, 颜色)] 片段
var log_lines: Array = []

# ---- 能量粒子生成（动画段开播时触发）----
func _spawn_energy_particles(from: Vector2, to_player: int, amount: int) -> void:
	if settings_reduce_motion:
		return
	var bar := energy_bar_rect(to_player)
	var tgt := bar.position + bar.size * 0.5
	var n: int = clampi(int(amount / 2) + randi_range(0, 3), 6, 25)
	# ★ 只有道具模式才"飞向积分条"；其它模式粒子只做打击特效，原地散开后淡出
	var fly: bool = bool(st.get("skillMode", false))
	if fly:
		energy_hold[to_player] = true      # 分先记着，等粒子飞到再涨条
	# 上限保护：连续踩子时粒子会叠加，超过 200 个就丢掉最早的，避免越积越多拖慢帧率
	if eparts.size() > 200: eparts = eparts.slice(eparts.size() - 200)
	var base: Color = cols.get(to_player, Color.WHITE)
	for _i in n:
		var ang := randf() * TAU
		var dist := randf() * 40.0 + 20.0
		var sx := from.x + cos(ang) * dist
		var sy := from.y + sin(ang) * dist
		eparts.append({
			"x0": from.x, "y0": from.y,
			"sx": sx, "sy": sy,
			# ★ 控制点必须以【散开点 sx/sy】为基准：P0 已经是 sx/sy（见 ParticleLayer._draw），
			#   参考 energyDisplay.js:281-282 也是从 scatterX/scatterY 起算的。
			#   用 from 会让 P0 与控制点不同源，轨迹在散开点处拐一下。
			"cx": sx + (tgt.x - sx) * 0.5 + randf_range(-100.0, 100.0),
			"cy": sy + (tgt.y - sy) * 0.5 - 100.0 - randf() * 100.0,
			"tx": tgt.x, "ty": tgt.y,
			"t": 0.0,
			"sd": randf_range(0.30, 0.50),
			"fd": randf_range(0.50, 0.80),
			"dl": randf() * 0.2,        # 起飞错峰 0~200ms（参考 energyDisplay.js:315）
			"c": base,
			"p": to_player,
			"fly": fly,
		})

const CRASH_ENERGY_DELAY := 0.12
var epar_wait: Array = []     # 待发粒子束：[{t, from, player, amount}]（epar 带 delay 时先入这里）

# ---- 战报/骰子抖动状态（_log_event 依赖）----
func _chain_move(p: int, ci2: int, mt: String) -> void:
	if not log_lines.is_empty():
		var last: Dictionary = log_lines[log_lines.size() - 1]
		if last.has("ks") and int(last.get("p", -1)) == p and int(last.get("ci", -1)) == ci2:
			(last["ks"] as Array).append(mt)
			last.erase("_cache")      # 片段变了，测量缓存作废
			return
	log_lines.append({"p": p, "t": " 选择了棋子%d " % (ci2 + 1), "ks": [mt], "ci": ci2})

var dice_shake := 0.0        # 骰子抖动剩余时间（项目 diceShake 0.5s ±3px）
var shake_sfx_t := 0.0        # L2: shake 音延迟（参考 300ms）
var dice_penalty := 0.0       # L1: 三次6惩罚时骰面锁红
## 棋盘上的字幕提示（三连6 惩罚等）：文本/剩余时间/玩家色
var board_toast := ""
var board_toast_t := 0.0
## 棋子顶部的称号浮字：{text, tier, pos, t}
var title_floats: Array = []
const TITLE_FLOAT_DUR := 1.6
var board_toast_col := Color.WHITE
const ACT_ITEM := {"remote-dice": "遥控骰子", "polyhedral-dice": "多面骰子",
	"teleport": "传送门", "mysteryBox": "盲盒"}