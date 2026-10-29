extends Control
## ============================================================
## 屏幕基类（game_main 解耦 · 第 1 步）
##
## 从 game_main.gd 搬出来的「独立屏幕 + 通用 UI 工具 + 屏幕相关状态」：
##   · 菜单（极简飞行棋标题/模式选择）
##   · 开局设置（座位/初始积分/更多模式面板/扩展规则介绍）
##   · 规则书弹窗
##   · 通用 UI：StyleBox 缓存 _sb、胶囊 _pill、图标 _icon、底栏布局矩形
##
## 用【脚本继承】实现：Main.tscn 仍挂 game_main.gd，而 game_main.gd 改成
##   extends "res://scripts/ui/screens_base.gd"
## 所以绘制依然发生在同一个 CanvasItem 上（渲染路径零改动），只是代码文件被切开了。
## ============================================================

const C_SURFACE := Color("#ffffff")
const C_INK     := Color("#2d241f")
const C_GRAY    := Color("#5c534e")
const C_LINE    := Color(0.18, 0.15, 0.12, 0.14)
const COL_GAP := 14.0            # 底部栏三栏的间距
## 高屏适配：按控件真实高度排布（720x1280 为设计基准，多余高度 extra_h()）
func vh() -> float:
	return size.y

func extra_h() -> float:
	return maxf(0.0, size.y - 1280.0)

## 对局画面：棋盘+上下玩家头像条带整体在「回合条下方~底部 HUD 上方」之间居中
func play_dy() -> float:
	return extra_h() * 0.5

func _bottom_y(off: float) -> float:
	return size.y - off

func _center_card_y(h: float) -> float:
	return maxf(24.0, (size.y - h) * 0.5)

const BAR_H_RATIO := 0.153        # 720x1280 设计尺寸下 = 196px
const BAR_H_MIN := 150.0
const BAR_H_MAX := 300.0

var difficulty := "hard"                           # easy | normal | hard
var launch_values := [2, 4, 6]                      # ★ 只有这些点数能起飞
var init_energy := 0
var more_open := false
var more_info_open := false     # 「扩展规则介绍」弹窗
var about_open := false         # 首页「关于游戏」弹窗
var more_anim := 0.0            # 0=收起 1=展开（驱动面板高度与内容淡入）
var sw_anim := {}               # "happy"/"item" -> 0..1 开关滑块进度
var happy_mode := false                                 # 欢乐模式（碰撞奖励）
var item_mode := false                                  # 道具模式（积分 + 4 种道具）
var seat_mode := {1: "player", 2: "ai", 3: "none", 4: "none"}
var PASTEL := {}
var cols := {}
var piece_tex := {}
var sel_anim := {}             # #1 设置页选择：滑动高亮的当前 rect（座位/难度共用）
var rules_open := false        # 游戏规则弹窗
var rules_scroll := 0.0        # 规则内容滚动量

## ---------------- 称号图鉴（成就系统 UI；数据/判定在 scripts/achievements/） ----------------
const TitleDefsRef := preload("res://scripts/achievements/title_defs.gd")
const TitlesViewRef := preload("res://scripts/achievements/titles_view.gd")
const TitleStoreRef := preload("res://scripts/achievements/title_store.gd")
var titles_open := false
var titles_scroll := 0.0
var titles_items: Array = []
var titles_total := 0.0
var titles_cache_w := -1.0
## 图鉴整页的过渡动画：0=完全收起，1=完全展开；closing=true 时反向
## 返回键确认弹窗：空串=不显示；action: quit / exit_match / to_menu
## iOS 左缘右滑返回手势状态（iOS 没有系统返回键）
var _swipe_arm := false
var _swipe_x0 := 0.0
var _swipe_y0 := 0.0
var back_dialog := ""
var back_dialog_action := ""
var titles_anim := 0.0
var titles_closing := false
var rules_data: Array = []     # data/rules.json 的条目（标题/段落）      # 结算弹窗是否显示
var sb_cache := {}
var sb_order: Array = []      # 插入顺序（用于淘汰最旧的一半）
var rules_lines: Array = []      # 排好版的行：[{y, chars:[[ch,Color]...], size}]
var rules_total := 0.0
var rules_cache_w := -1.0

# ---------------------------------------------------------------- 屏幕绘制/命中测试
## 有上限的缓存写入：满了先淘汰最旧的一半。
## ★ 原来是「size >= cap 就 cache.clear()」—— 连静态的十几个按钮框也一起丢，
##   下一帧全部重建；满格脉冲那种"每帧新键"的场景会周期性把整个缓存清空重建。
func _cache_put(cache: Dictionary, order: Array, k: String, v, cap: int) -> void:
	if not cache.has(k) and cache.size() >= cap and not order.is_empty():
		var drop: int = maxi(1, order.size() / 2)
		for di in drop: cache.erase(order[di])
		order.assign(order.slice(drop))
	cache[k] = v
	order.append(k)

func _sb(bg: Color, cr: int, bw: int = 0, bc: Color = Color(0, 0, 0, 0),
		sh: Color = Color(0, 0, 0, 0), sh_size: int = 0) -> StyleBoxFlat:
	var k := "%d_%d_%d_%d_%d_%d" % [bg.to_rgba32(), cr, bw, bc.to_rgba32(), sh.to_rgba32(), sh_size]
	var s: StyleBoxFlat = sb_cache.get(k)
	if s == null:
		s = StyleBoxFlat.new()
		s.bg_color = bg
		s.set_corner_radius_all(cr)
		if bw > 0:
			s.set_border_width_all(bw)
			s.border_color = bc
		if sh_size > 0:
			s.shadow_color = sh
			s.shadow_size = sh_size
			s.shadow_offset = Vector2.ZERO
		# ★ 键里含【连续变化的颜色】（骰面 alpha、满格 pulse 的边框/发光色），会不断产生新键。
		#   原来是「满了就不再加」—— 结果 4~5 次掷骰后缓存写满，此后每帧所有键都重新 new，优化静默失效。
		#   改成满了整体清空重建：宁可偶尔重建一次，也不要永久退化成每帧 new。
		_cache_put(sb_cache, sb_order, k, s, 256)
	return s

func _pill(r: Rect2, bg: Color) -> void:
	draw_style_box(_sb(bg, int(r.size.y * 0.5), 0, Color(0, 0, 0, 0)), r)

func _icon(kind: String, c: Vector2, r: float, col: Color) -> void:
	match kind:
		"blue":                                  # 信号
			for i in 3:
				draw_arc(c + Vector2(0, r * 0.55), r * (0.35 + 0.28 * i), PI * 1.22, PI * 1.78, 16, col, 3.0)
			draw_circle(c + Vector2(0, r * 0.55), 2.6, col)
		"pink":                                  # 机器人
			draw_rect(Rect2(c + Vector2(-r * 0.7, -r * 0.45), Vector2(r * 1.4, r * 1.15)), col, false, 3.0)
			draw_circle(c + Vector2(-r * 0.28, r * 0.08), 2.6, col)
			draw_circle(c + Vector2(r * 0.28, r * 0.08), 2.6, col)
			draw_line(c + Vector2(0, -r * 0.45), c + Vector2(0, -r * 0.8), col, 3.0)
		_:                                       # 两个人
			draw_circle(c + Vector2(-r * 0.34, -r * 0.28), r * 0.3, col)
			draw_circle(c + Vector2(r * 0.38, -r * 0.16), r * 0.24, col)
			draw_arc(c + Vector2(-r * 0.34, r * 0.5), r * 0.5, PI, TAU, 16, col, 3.0)
			draw_arc(c + Vector2(r * 0.38, r * 0.55), r * 0.4, PI, TAU, 16, col, 3.0)

# ============================== 座位配置（图四布局） ==============================

func bar_h() -> float:
	return maxf(1.0, size.y - bar_top())

func bar_top() -> float:
	# Figma A 方案：棋盘下方从 972 开始是日志/HUD 区；高屏按真实高度下移
	return 972.0 + extra_h()

## 游戏信息面板：占底部栏左侧

## 游戏信息面板：占底部栏左侧
func panel_rect() -> Rect2:
	# Figma A 方案：底部日志条（左侧图标 + 一行战报）
	return Rect2(40.0, 972.0 + extra_h(), 640.0, 56.0)

## 骰子：底部栏右侧

## 骰子：底部栏右侧
func dice_center() -> Vector2:
	var r := dice_rect()
	return r.position + r.size * 0.5

func _item_hud_mode() -> bool:
	return not st.is_empty() and bool(st.get("skillMode", false))

func dice_rect() -> Rect2:
	if _item_hud_mode(): return Rect2(40.0, 1089.0 + extra_h(), 78.0, 78.0)
	return Rect2(40.0, 1044.0 + extra_h(), 96.0, 96.0)

func roll_button_rect() -> Rect2:
	# Figma A 方案：底部骰子行右侧的大号「掷骰子」按钮
	if _item_hud_mode(): return Rect2(492.0, 1093.0 + extra_h(), 186.0, 70.0)
	return Rect2(492.0, 1056.0 + extra_h(), 188.0, 72.0)

func btn_col_rect() -> Rect2:
	# Figma A 方案：底部横向 3 个按钮容器
	if _item_hud_mode(): return Rect2(40.0, 1181.0 + extra_h(), 640.0, 62.0)
	return Rect2(40.0, 1184.0 + extra_h(), 640.0, 64.0)

## 「游戏规则」按钮：按钮列最上面（结算按钮往下移）

func seats() -> Array:
	var out := []
	for pid in [1, 2, 3, 4]:
		if str(seat_mode.get(pid, "none")) != "none": out.append(pid)
	return out if not out.is_empty() else [1]

func humans_of(ss: Array) -> Array:
	var out := []
	for pid in ss:
		if str(seat_mode.get(pid, "none")) == "player": out.append(pid)
	return out

# ============================== 菜单（图三风格） ==============================
# ---- Figma redesign tokens & primitives (A方案) ----
const F_BG := Color("#F5F2ED")
const F_CARD := Color("#FFFFFF")
const F_CARD2 := Color("#FAF8F5")
const F_LINE := Color("#E2DDD6")
const F_INK := Color("#3B332D")
const F_SUB := Color("#8B98AD")
const F_MUTED := Color("#B5B3AE")
const F_GREEN := Color("#2F7D4F")
const F_GREEN_TINT := Color("#EBF4ED")
const F_WARM := Color("#FFF4E0")
const F_WARM_LINE := Color("#E0B25A")
var _fig_av_tex := {}

func _fig_font() -> Font:
	return ThemeDB.fallback_font

func _fig_shadow() -> Color:
	return Color(59.0 / 255.0, 51.0 / 255.0, 45.0 / 255.0, 0.08)

func _fig_card(r: Rect2, bg: Color = F_CARD, radius: int = 20, border: bool = true, shadow: bool = true) -> void:
	var bc: Color = F_LINE if border else Color(0, 0, 0, 0)
	var sh: Color = _fig_shadow() if shadow else Color(0, 0, 0, 0)
	draw_style_box(_sb(bg, radius, 1 if border else 0, bc, sh, 10 if shadow else 0), r)

func _fig_text(txt: String, x: float, baseline: float, fs: int, col: Color = F_INK,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, w: float = -1.0,
		font: Font = null) -> void:
	draw_string(font if font != null else _fig_font(), Vector2(x, baseline), txt, align, w, fs, col)

func _fig_chevron(c: Vector2, col: Color = F_SUB, dir: int = 1, sz: float = 7.0) -> void:
	var pts: PackedVector2Array
	if dir >= 0:
		pts = PackedVector2Array([c + Vector2(-sz, -sz), c + Vector2(0, 0), c + Vector2(-sz, sz)])
	else:
		pts = PackedVector2Array([c + Vector2(sz, -sz), c + Vector2(0, 0), c + Vector2(sz, sz)])
	draw_polyline(pts, col, 2.6, true)

func _fig_chevron_down(c: Vector2, col: Color = F_SUB, sz: float = 7.0) -> void:
	draw_polyline(PackedVector2Array([c + Vector2(-sz, -sz * 0.55), c + Vector2(0, sz * 0.55), c + Vector2(sz, -sz * 0.55)]), col, 2.6, true)

func _fig_icon(kind: String, c: Vector2, s: float, col: Color = F_SUB) -> void:
	var w := 2.4
	match kind:
		"settings":
			draw_circle(c, s * 0.28, col, false, w)
			for i in 8:
				var a := TAU * float(i) / 8.0
				draw_line(c + Vector2(cos(a), sin(a)) * s * 0.42,
					c + Vector2(cos(a), sin(a)) * s * 0.62, col, w, true)
		"bot":
			draw_style_box(_sb(Color(0, 0, 0, 0), 8, 2, col), Rect2(c - Vector2(s * 0.58, s * 0.38), Vector2(s * 1.16, s * 0.84)))
			draw_circle(c + Vector2(-s * 0.24, -s * 0.02), 2.2, col)
			draw_circle(c + Vector2(s * 0.24, -s * 0.02), 2.2, col)
			draw_line(c + Vector2(0, -s * 0.38), c + Vector2(0, -s * 0.68), col, w, true)
			draw_circle(c + Vector2(0, -s * 0.72), 2.4, col)
		"users":
			draw_circle(c + Vector2(-s * 0.30, -s * 0.28), s * 0.27, col)
			draw_circle(c + Vector2(s * 0.36, -s * 0.18), s * 0.22, col)
			draw_arc(c + Vector2(-s * 0.30, s * 0.42), s * 0.50, PI, TAU, 18, col, w, true)
			draw_arc(c + Vector2(s * 0.36, s * 0.48), s * 0.40, PI, TAU, 18, col, w, true)
		"wifi":
			for i in 3:
				draw_arc(c + Vector2(0, s * 0.42), s * (0.32 + 0.30 * i), PI * 1.20, PI * 1.80, 18, col, w, true)
			draw_circle(c + Vector2(0, s * 0.50), 2.5, col)
		"copy":
			draw_rect(Rect2(c + Vector2(-s * 0.42, -s * 0.48), Vector2(s * 0.62, s * 0.78)), col, false, w)
			draw_rect(Rect2(c + Vector2(-s * 0.18, -s * 0.28), Vector2(s * 0.62, s * 0.78)), col, false, w)
		"search":
			draw_circle(c + Vector2(-s * 0.10, -s * 0.10), s * 0.42, col, false, w)
			draw_line(c + Vector2(s * 0.22, s * 0.22), c + Vector2(s * 0.60, s * 0.60), col, w, true)
		"info":
			draw_circle(c, s * 0.52, col, false, w)
			draw_circle(c + Vector2(0, -s * 0.22), 2.0, col)
			draw_line(c + Vector2(0, -s * 0.04), c + Vector2(0, s * 0.30), col, w, true)
		"plus":
			draw_line(c + Vector2(-s * 0.45, 0), c + Vector2(s * 0.45, 0), col, w, true)
			draw_line(c + Vector2(0, -s * 0.45), c + Vector2(0, s * 0.45), col, w, true)
		"clock":
			draw_circle(c, s * 0.55, col, false, w)
			draw_line(c, c + Vector2(0, -s * 0.32), col, w, true)
			draw_line(c, c + Vector2(s * 0.26, 0), col, w, true)
		"pause":
			draw_rect(Rect2(c + Vector2(-s * 0.34, -s * 0.40), Vector2(s * 0.22, s * 0.80)), col)
			draw_rect(Rect2(c + Vector2(s * 0.12, -s * 0.40), Vector2(s * 0.22, s * 0.80)), col)
		"sliders":
			draw_line(c + Vector2(-s, -s * 0.36), c + Vector2(s, -s * 0.36), col, w, true)
			draw_line(c + Vector2(-s, s * 0.36), c + Vector2(s, s * 0.36), col, w, true)
			draw_circle(c + Vector2(-s * 0.28, -s * 0.36), 2.8, col)
			draw_circle(c + Vector2(s * 0.30, s * 0.36), 2.8, col)
		_:
			draw_circle(c, s * 0.45, col, false, w)

func _fig_avatar_tex(a: int) -> Texture2D:
	var id: int = clampi(a, 1, 20)
	if _fig_av_tex.has(id):
		return _fig_av_tex[id]
	var path := "res://assets/avatars/avatar_%d.svg" % id
	var t: Texture2D = null
	if ResourceLoader.exists(path):
		t = load(path) as Texture2D
	_fig_av_tex[id] = t
	return t

func _fig_avatar(c: Vector2, radius: float, pid: int, aid: int = 0, active: bool = false) -> void:
	var col: Color = cols.get(pid, PASTEL.get("green", F_GREEN))
	var av: int = aid if aid > 0 else ((pid - 1) % 20) + 1
	draw_circle(c, radius, col)
	var tex := _fig_avatar_tex(av)
	if tex != null:
		var ir := radius * 0.80
		draw_texture_rect(tex, Rect2(c - Vector2(ir, ir), Vector2(ir, ir) * 2.0), false)
	draw_arc(c, radius, 0.0, TAU, 36, col.darkened(0.22) if not active else F_GREEN, 3.0 if active else 2.0, true)

func _fig_btn(r: Rect2, txt: String, primary: bool = true, enabled: bool = true, fs: int = 24, radius: int = -1) -> void:
	var bg: Color = F_GREEN if primary else F_CARD
	if not enabled:
		bg = Color("#EFECE7")
	var bc: Color = Color(0, 0, 0, 0) if primary else F_LINE
	var rr: int = radius if radius >= 0 else int(r.size.y * 0.5)
	_fig_card(r, bg, rr, not primary or not enabled, false)
	if primary or not enabled:
		draw_style_box(_sb(bg, rr, 0, Color(0, 0, 0, 0)), r)
	var tc: Color = Color.WHITE if primary and enabled else (F_MUTED if not enabled else F_INK)
	_fig_text(txt, r.position.x, r.position.y + r.size.y * 0.5 + float(fs) * 0.34, fs, tc,
		HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

func mode_hits() -> Array:
	var x := 48.0
	var w := 624.0
	var h := 164.0
	var y0 := 432.0 + extra_h() * 0.5
	var gap := 20.0 + extra_h() * 0.10
	return [
		{"r": Rect2(x, y0, w, h), "a": "m_ai", "t": "人机对战",
			"desc": "一个人，也能轻松开一局", "tag": "随时出发", "icon": "bot",
			"tint": Color("#8FD0A0"), "accent": Color("#2F7D4F")},
		{"r": Rect2(x, y0 + h + gap, w, h), "a": "m_local", "t": "本地多人",
			"desc": "同一台设备，轮流掷骰子", "tag": "2–4 人", "icon": "users",
			"tint": Color("#F3B98C"), "accent": Color("#B86A2E")},
		{"r": Rect2(x, y0 + (h + gap) * 2.0, w, h), "a": "m_online", "t": "局域网联机",
			"desc": "连接同一网络，和朋友一起玩", "tag": "无需互联网", "icon": "wifi",
			"tint": Color("#9CC3E8"), "accent": Color("#4777C5")},
		{"r": Rect2(215.5, _bottom_y(140.0), 120.0, 48.0), "a": "rules", "t": "游戏规则", "mini": true},
		{"r": Rect2(384.5, _bottom_y(140.0), 120.0, 48.0), "a": "titles", "t": "称号图鉴", "mini": true},
		{"r": Rect2(624.0, 56.0, 48.0, 48.0), "a": "settings_open", "t": "设置", "mini": true},
	]

func titles_button_rect() -> Rect2:
	return Rect2(400.0, _bottom_y(188.0), 140.0, 44.0)

## 复刻 feixinqi-web 的 .rainbow-title：逐字四色 + titleJump（1s steps(1,end)，±3°，origin center bottom，delay 0/.2/.4/.5/.8）
func _draw_home_title() -> void:
	var font := _fig_font()
	var chars := ["极", "简", "飞", "行", "棋"]
	var colors := [Color("#a6d8b7"), Color("#ecbd99"), Color("#afccea"), Color("#f7a099"), Color("#a6d8b7")]
	var delays := [0.0, 0.2, 0.4, 0.5, 0.8]
	var fs := 52
	var tsec: float = Time.get_ticks_msec() / 1000.0
	var x := 48.0
	var baseline := 266.0
	for i in 5:
		var ch: String = chars[i]
		var cw: float = font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var phase: float = fmod(tsec - float(delays[i]) + 1000.0, 1.0)
		var ang: float = deg_to_rad(-3.0 if phase < 0.5 else 3.0)
		var cx: float = x + cw * 0.5
		# 阴影：text-shadow 0 1px 1px rgba(0,0,0,0.3)
		draw_set_transform(Vector2(cx, baseline + 1.0), ang, Vector2.ONE)
		draw_string(font, Vector2(-cw * 0.5, 0.0), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.30))
		draw_set_transform(Vector2(cx, baseline), ang, Vector2.ONE)
		# 网页标题是 bold；系统回退字体没有字重轴，用 3 次 0.45px 横向偏移模拟加粗
		for dx in [-0.45, 0.0, 0.45]:
			draw_string(font, Vector2(-cw * 0.5 + float(dx), 0.0), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, colors[i])
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		x += cw + 6.0   # letter-spacing 2px + flex gap 4px

func _draw_mode() -> void:
	var sz := size
	var font := _fig_font()
	draw_rect(Rect2(Vector2.ZERO, sz), F_BG)
	# 顶部眉题 + 设置图标
	_fig_text("把快乐，留在桌面", 48.0, 86.0, 18, F_SUB)
	_fig_icon("sliders", Vector2(648.0, 80.0), 12.0, F_SUB)
	# 四色小方块
	var dcx := 48.0
	var dot_cols := [Color("#F0A3A3"), Color("#8FD0A0"), Color("#9CC3E8"), Color("#F3B98C")]
	for c in dot_cols:
		draw_style_box(_sb(c, 8, 0, Color(0, 0, 0, 0)), Rect2(dcx, 172.0, 24.0, 24.0))
		dcx += 34.0
	# 标题与副标题
	_draw_home_title()
	_fig_text("不用赶路，掷出一点好时光。", 48.0, 331.0, 23, F_SUB)
	_fig_text("选一种方式，开始今天的小小旅程。", 48.0, 370.0, 23, F_SUB)
	# 三张入口卡
	for h in mode_hits():
		if bool(h.get("mini", false)):
			continue
		var r: Rect2 = h.r
		_fig_card(r)
		var tint: Color = h.tint
		draw_style_box(_sb(tint, 20, 0, Color(0, 0, 0, 0)), Rect2(r.position + Vector2(28, 48), Vector2(68, 68)))
		_fig_icon(str(h.icon), Vector2(r.position.x + 62.0, r.position.y + 82.0), 28.0, tint.darkened(0.55))
		_fig_text(str(h.t), r.position.x + 120.0, r.position.y + 61.0, 29, F_INK)
		_fig_text(str(h.desc), r.position.x + 120.0, r.position.y + 95.0, 19, F_SUB)
		_fig_text(str(h.tag), r.position.x + 120.0, r.position.y + 124.0, 16, h.accent)
		_fig_chevron(Vector2(r.end.x - 40.0, r.position.y + 82.0), F_SUB, 1, 6.0)
	# 页脚
	_fig_text("游戏规则", 215.5, _bottom_y(104.0), 20, F_INK, HORIZONTAL_ALIGNMENT_CENTER, 120.0)
	_fig_text("称号图鉴", 384.5, _bottom_y(104.0), 20, F_INK, HORIZONTAL_ALIGNMENT_CENTER, 120.0)
	draw_line(Vector2(359.5, _bottom_y(122.0)), Vector2(359.5, _bottom_y(102.0)), Color("#D8D2CA"), 1.0)
	_fig_text("纯粹的棋盘时光 · v1.0", 0.0, _bottom_y(58.0), 16, F_SUB, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
	if not rules_open:
		_rules_was_open = false
	if settings_open:
		_draw_settings()
	if titles_open:
		_draw_titles_page()
	if rules_open:
		_draw_rules()
	if about_open:
		_draw_about()
	_draw_global_toasts()
	if back_dialog != "":
		_draw_back_dialog()

func about_hits() -> Array:
	var card := Rect2(60.0, _center_card_y(620.0), 600.0, 620.0)
	return [
		{"r": Rect2(card.position.x + 32.0, card.end.y - 164.0, 240.0, 72.0), "a": "about_titles", "t": "称号图鉴"},
		{"r": Rect2(card.end.x - 272.0, card.end.y - 164.0, 240.0, 72.0), "a": "about_close", "t": "关闭"},
		{"r": Rect2(card.end.x - 58.0, card.position.y + 16.0, 48.0, 48.0), "a": "about_close", "t": "×"},
	]

func _draw_about() -> void:
	var card := Rect2(60.0, _center_card_y(620.0), 600.0, 620.0)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	_fig_card(card, F_CARD, 24)
	_fig_text("关于游戏", card.position.x + 32.0, card.position.y + 62.0, 30, F_INK)
	_draw_batch2_icon("close", Vector2(card.end.x - 34.0, card.position.y + 40.0), 11.0, F_SUB)
	var dot_x := card.position.x + 32.0
	for c in [Color("#F0A3A3"), Color("#8FD0A0"), Color("#9CC3E8"), Color("#F3B98C")]:
		_fig_card(Rect2(dot_x, card.position.y + 92.0, 24.0, 24.0), c, 8, false, false)
		dot_x += 34.0
	_fig_text("极简飞行棋", card.position.x + 32.0, card.position.y + 162.0, 30, F_INK)
	_fig_text("不用赶路，掷出一点好时光。", card.position.x + 32.0, card.position.y + 200.0, 21, F_SUB)
	_fig_text("版本 v1.0", card.position.x + 32.0, card.position.y + 240.0, 16, F_SUB)
	draw_line(Vector2(card.position.x + 32.0, card.position.y + 268.0),
		Vector2(card.end.x - 32.0, card.position.y + 268.0), F_LINE, 1.0)
	_fig_text("玩法简介", card.position.x + 32.0, card.position.y + 312.0, 24, F_INK)
	_fig_text("在同一张棋盘上，轮流掷骰、移动棋子。", card.position.x + 32.0, card.position.y + 350.0, 19, F_INK)
	_fig_text("支持 2–4 人本地 / 局域网联机 / 人机对战。", card.position.x + 32.0, card.position.y + 382.0, 19, F_SUB)
	_fig_text("隐私与素材许可", card.position.x + 32.0, card.position.y + 424.0, 24, F_INK)
	_fig_text("棋盘、棋子与表情头像沿用原有素材，", card.position.x + 32.0, card.position.y + 458.0, 17, F_SUB)
	_fig_text("素材许可需以原仓库许可核对。", card.position.x + 32.0, card.position.y + 486.0, 17, F_SUB)
	for h in about_hits():
		var r: Rect2 = h.r
		if str(h.a) == "about_close" and str(h.t) == "×": continue
		var prim: bool = str(h.a) == "about_titles"
		_fig_card(r, F_GREEN if prim else F_CARD, 16, not prim, false)
		_fig_text(str(h.t), r.position.x, r.position.y + r.size.y * 0.5 + 9.0, 24,
			Color.WHITE if prim else F_INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
## 对局玩法卡高度动画：0=道具关（无初始能量/无空白），1=道具开（展开出现初始能量）
var setup_card_anim := 0.0
var _setup_card_active := false
var _setup_card_target := 0.0
var _setup_card_from := 0.0
var _setup_card_t0 := 0

func _setup_card_anim_advance() -> void:
	var tgt := 1.0 if item_mode else 0.0
	if absf(setup_card_anim - tgt) < 0.001:
		setup_card_anim = tgt
		_setup_card_active = false
		_setup_card_target = tgt
		return
	if not _setup_card_active:
		_setup_card_active = true
		_setup_card_target = tgt
		_setup_card_from = setup_card_anim
		_setup_card_t0 = Time.get_ticks_msec()
	elif absf(_setup_card_target - tgt) > 0.001:
		_setup_card_active = true
		_setup_card_target = tgt
		_setup_card_from = setup_card_anim
		_setup_card_t0 = Time.get_ticks_msec()
	var p: float = clampf(float(Time.get_ticks_msec() - _setup_card_t0) / 260.0, 0.0, 1.0)
	var e: float = p * p * (3.0 - 2.0 * p)
	setup_card_anim = lerpf(_setup_card_from, _setup_card_target, e)
	if p >= 1.0:
		setup_card_anim = _setup_card_target
		_setup_card_active = false
	queue_redraw()

func _setup_geo() -> Dictionary:
	_setup_card_anim_advance()
	var seat_y: Array = []
	for i in 4:
		seat_y.append(128.0 + float(i) * 112.0)     # 4 x 100 卡 + 12 间距 -> 结束时 588
	var start := Rect2(40.0, _bottom_y(112.0), 640.0, 72.0)
	# 卡高：收起 352（正好容纳 3 行 + 标题 + 提示），展开 456（多出初始能量行）
	var card_h: float = 352.0 + 104.0 * clampf(setup_card_anim, 0.0, 1.0)
	var card_y := 612.0      # 紧贴玩家卡下方（收起/展开只改高度，不上下漂移）
	var rows := {
		"happy": Rect2(64.0, card_y + 84.0, 592.0, 68.0),
		"item": Rect2(64.0, card_y + 160.0, 592.0, 68.0),
		"launch": Rect2(64.0, card_y + 232.0, 592.0, 68.0),
		"energy": Rect2(64.0, card_y + 304.0, 592.0, 104.0),
	}
	return {"x": 40.0, "w": 640.0, "seat_y": seat_y, "seat_h": 100.0,
		"card_y": card_y, "card_h": card_h, "card_anim": setup_card_anim, "rows": rows,
		"launch_chips": [Rect2(404.0, card_y + 242.0, 77.0, 48.0),
			Rect2(491.0, card_y + 242.0, 77.0, 48.0),
			Rect2(578.0, card_y + 242.0, 78.0, 48.0)],
		"energy_track": Rect2(64.0, card_y + 390.0, 592.0, 6.0),
		"start": start, "back": Rect2(40.0, 36.0, 64.0, 48.0)}

func setup_hits() -> Array:
	var g := _setup_geo()
	var hits: Array = []
	for i in 4:
		var pid := i + 1
		var sy: float = g.seat_y[i]
		for k in 3:
			var key: String = ["player", "ai", "none"][k]
			var lbl: String = ["玩家", "电脑", "无"][k]
			hits.append({"r": Rect2(242.0 + float(k) * 137.0, sy + 28.0, 135.0, 44.0),
				"a": "set_%d_%s" % [pid, key], "t": lbl, "pid": pid, "k": key})
	var rows: Dictionary = g.rows
	# 玩法开关（动作沿用 flow 已有的 mode_happy / mode_item）
	hits.append({"r": rows["happy"], "a": "mode_happy", "t": "欢乐模式", "on": happy_mode})
	hits.append({"r": rows["item"], "a": "mode_item", "t": "道具模式", "on": item_mode})
	# 起飞点数
	for k3 in 3:
		var lv: int = [2, 4, 6][k3]
		hits.append({"r": g.launch_chips[k3], "a": "launch_%d" % lv, "t": "%d点" % lv, "lv": lv})
	# 初始能量（道具模式开启且展开动画完成后才可点）
	if item_mode and setup_card_anim >= 0.999:
		hits.append({"r": rows["energy"], "a": "energy_slider", "track": g.energy_track})
	hits.append({"r": g.start, "a": "start", "t": "开始游戏", "primary": true})
	hits.append({"r": g.back, "a": "back", "t": "返回"})
	return hits

func _more_panel_rect() -> Rect2:
	return Rect2()

## iOS 风格开关：52×30 胶囊轨道（灰↔绿）+ 白色滑块（smoothstep 滑动）

## iOS 风格开关：52×30 胶囊轨道（灰↔绿）+ 白色滑块（smoothstep 滑动）
func _draw_switch(r: Rect2, on: float, accent: Color) -> void:
	var sw_w := 52.0
	var sw_h := 30.0
	var track := Rect2(r.end.x - 24.0 - sw_w, r.position.y + (r.size.y - sw_h) * 0.5, sw_w, sw_h)
	var t: float = clampf(on, 0.0, 1.0)
	var e: float = t * t * (3.0 - 2.0 * t)
	_pill(track, Color("#d5dbe6").lerp(accent, e))
	var kx: float = lerpf(track.position.x + sw_h * 0.5, track.end.x - sw_h * 0.5, e)
	draw_circle(Vector2(kx, track.position.y + sw_h * 0.5), sw_h * 0.5 - 3.5, Color.WHITE)

## 初始积分拖动条（设置页，仅道具模式）：取命中项 / 由 x 反算分值（0~100，5 分一档）

## 初始积分拖动条（设置页，仅道具模式）：取命中项 / 由 x 反算分值（0~100，5 分一档）
func _energy_slider_hit() -> Dictionary:
	for h in setup_hits():
		if str(h.a) == "energy_slider": return h
	return {}

func _energy_from_x(px: float) -> int:
	var h := _energy_slider_hit()
	if h.is_empty(): return init_energy
	var track: Rect2 = h.track
	if track.size.x <= 1.0: return init_energy
	var t: float = clampf((px - track.position.x) / track.size.x, 0.0, 1.0)
	return int(round(t * 20.0)) * 5

## 某一行当前选中项的目标 rect（滑动高亮的终点）

## 某一行当前选中项的目标 rect（滑动高亮的终点）
func _sel_target(row: String) -> Rect2:
	var want := ""
	if row.begins_with("set_"):
		var pidS := int(row.substr(4))
		want = "set_%d_%s" % [pidS, str(seat_mode.get(pidS, "none"))]
	else:
		want = "diff_" + difficulty
	for h in setup_hits():
		if str(h.a) == want: return h.r
	return Rect2()

## 某个玩家那一行选项按钮的矩形（取该行任一命中项即可，三列 y 相同）

## 某个玩家那一行选项按钮的矩形（取该行任一命中项即可，三列 y 相同）
func _sel_row_rect(pid: int) -> Rect2:
	var pre := "set_%d_" % pid
	for h in setup_hits():
		if str(h.a).begins_with(pre): return h.r
	return Rect2()

## 「扩展规则介绍」弹窗（点「更多模式」右边的 ? 打开）

## 「扩展规则介绍」弹窗（点「更多模式」右边的 ? 打开）
func more_info_rect() -> Rect2:
	var w: float = minf(size.x - 80.0, 560.0)
	var h: float = minf(430.0, size.y - 80.0)
	return Rect2((size.x - w) * 0.5, _center_card_y(h), w, h)

func _draw_more_info() -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.45))
	var p := more_info_rect()
	draw_style_box(_sb(C_SURFACE, 18, 0, Color(0, 0, 0, 0)), p)
	draw_string(font, Vector2(p.position.x + 26, p.position.y + 48), "扩展规则介绍",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 28, C_INK)
	draw_line(Vector2(p.position.x + 20, p.position.y + 64), Vector2(p.end.x - 20, p.position.y + 64), C_LINE, 1.0)
	draw_string(font, Vector2(p.end.x - 48.0, p.position.y + 46.0), "×",
		HORIZONTAL_ALIGNMENT_CENTER, 34.0, 26, C_GRAY)
	var y: float = p.position.y + 98.0
	var blocks := [
		["欢乐模式", Color("#35ae61"), [
			"撞到对方棋子时不再把对方撞回基地，",
			"而是按对方棋子的前进点数给自己加分；",
			"多颗棋子叠在同一格也不会被清空。"]],
		["道具模式", Color("#4777c5"), [
			"击败对手 / 撞到对方棋子会攒积分；",
			"积分可在底部道具栏购买：遥控骰子、",
			"多面骰子、传送门、盲盒，买完点道具栏使用。",
			"遥控骰子/多面骰子只能在本回合摇骰前使用，",
			"传送门/盲盒摇骰前后都能用（用完交回合）。",
			"开局前用「初始积分」拖动条设定起始积分。"]],
	]
	for blk in blocks:
		draw_string(font, Vector2(p.position.x + 26.0, y), str(blk[0]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 21, blk[1])
		y += 30.0
		for ln in (blk[2] as Array):
			draw_string(font, Vector2(p.position.x + 26.0, y), str(ln),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("#4a5568"))
			y += 26.0
		y += 16.0
	draw_string(font, Vector2(p.position.x, p.end.y - 22.0), "点任意处关闭",
		HORIZONTAL_ALIGNMENT_CENTER, p.size.x, 15, Color("#9fb0cc"))

func _draw_setup() -> void:
	var sz := size
	var font := _fig_font()
	var g := _setup_geo()
	draw_rect(Rect2(Vector2.ZERO, sz), F_BG)
	# 顶栏
	_fig_chevron(Vector2(64.0, 60.0), F_INK, -1, 9.0)
	_fig_text("本地对局设置", 108.0, 70.0, 34, F_INK)
	_fig_text("2–4 人", 0.0, 65.0, 18, F_SUB, HORIZONTAL_ALIGNMENT_RIGHT, 680.0)
	# 4 张玩家卡
	for i in 4:
		var pid := i + 1
		var sy: float = g.seat_y[i]
		var card := Rect2(40.0, sy, 640.0, 100.0)
		_fig_card(card, F_CARD, 16)
		_fig_avatar(Vector2(88.0, sy + 50.0), 30.0, pid, pid, false)
		_fig_text(["绿方", "橙方", "蓝方", "红方"][i], 134.0, sy + 56.0, 22, F_INK)
		var seg := Rect2(238.0, sy + 24.0, 424.0, 52.0)
		draw_style_box(_sb(F_CARD2, 14, 0, Color(0, 0, 0, 0)), seg)
		var cur := str(seat_mode.get(pid, "none"))
		for k in 3:
			var key: String = ["player", "ai", "none"][k]
			var r := Rect2(242.0 + float(k) * 137.0, sy + 28.0, 135.0, 44.0)
			var on := cur == key
			if on:
				draw_style_box(_sb(F_GREEN_TINT, 10, 1, F_GREEN), r)
			_fig_text(["玩家", "电脑", "无"][k], r.position.x, r.position.y + 29.0, 20,
				F_GREEN if on else F_SUB, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
	# 对局玩法卡
	var card2 := Rect2(40.0, g.card_y, 640.0, g.card_h)
	_fig_card(card2, F_CARD, 24)
	_fig_text("对局玩法", 64.0, g.card_y + 44.0, 24, F_INK)
	var rows: Dictionary = g.rows
	# 欢乐模式开关
	var rh: Rect2 = rows["happy"]
	_fig_text("欢乐模式", rh.position.x, rh.position.y + 38.0, 22, F_INK)
	_fig_text("碰撞改为加分，叠子不会被清空", rh.position.x, rh.position.y + 62.0, 16, F_SUB)
	_draw_switch(rh, float(sw_anim.get("happy", 1.0 if happy_mode else 0.0)), F_GREEN)
	# 道具模式开关
	var ri: Rect2 = rows["item"]
	_fig_text("道具模式", ri.position.x, ri.position.y + 38.0, 22, F_INK)
	_fig_text("用积分购买遥控骰/多面骰/传送门/盲盒", ri.position.x, ri.position.y + 62.0, 16, F_SUB)
	_draw_switch(ri, float(sw_anim.get("item", 1.0 if item_mode else 0.0)), F_GREEN)
	# 起飞点数
	var rl: Rect2 = rows["launch"]
	_fig_text("起飞点数", rl.position.x, rl.position.y + 38.0, 22, F_INK)
	_fig_text("选中的点数才能让棋子起飞（可多选）", rl.position.x, rl.position.y + 62.0, 16, F_SUB)
	for k3 in 3:
		var lv: int = [2, 4, 6][k3]
		var lr: Rect2 = g.launch_chips[k3]
		var on3: bool = launch_values.has(lv)
		draw_style_box(_sb(F_GREEN_TINT if on3 else F_CARD2, 16, 1, F_GREEN if on3 else F_LINE), lr)
		_fig_text("%d点" % lv, lr.position.x, lr.position.y + 31.0, 22,
			F_GREEN if on3 else F_INK, HORIZONTAL_ALIGNMENT_CENTER, lr.size.x)
	# 初始能量（道具模式开启时随卡高生长淡入）
	var ea: float = clampf((setup_card_anim - 0.45) / 0.4, 0.0, 1.0)
	if item_mode and ea > 0.01:
		var re: Rect2 = rows["energy"]
		var ink_a := Color(F_INK.r, F_INK.g, F_INK.b, ea)
		var sub_a := Color(F_SUB.r, F_SUB.g, F_SUB.b, ea)
		var grn_a := Color(F_GREEN.r, F_GREEN.g, F_GREEN.b, ea)
		_fig_text("初始能量", re.position.x, re.position.y + 36.0, 22, ink_a)
		_fig_text("开局前用滑条设定起始积分（0–100，5 分一档）", re.position.x, re.position.y + 60.0, 16, sub_a)
		_fig_text(str(init_energy), 0.0, re.position.y + 36.0, 24, grn_a,
			HORIZONTAL_ALIGNMENT_RIGHT, 656.0)
		var track: Rect2 = g.energy_track
		draw_style_box(_sb(Color(0.937, 0.925, 0.906, ea), 3, 0, Color(0, 0, 0, 0)), track)
		var tt: float = clampf(float(init_energy) / 100.0, 0.0, 1.0)
		if tt > 0.002:
			draw_style_box(_sb(grn_a, 3, 0, Color(0, 0, 0, 0)),
				Rect2(track.position, Vector2(maxf(6.0, track.size.x * tt), track.size.y)))
		var kn := Vector2(track.position.x + track.size.x * tt, track.position.y + 3.0)
		draw_circle(kn, 15.0, Color(1, 1, 1, ea))
		draw_arc(kn, 14.0, 0.0, TAU, 32, grn_a, 3.0, true)
	# 卡底提示（动画过程中隐藏，避免和生长中的能量行叠字）
	if setup_card_anim < 0.05 or setup_card_anim > 0.95:
		var hint := "道具模式：击败 / 碰撞攒积分，积分可在对局底部道具栏购买道具" if item_mode 			else "起飞点数决定哪些点数可以起飞；点击开始后进入对局"
		_fig_text(hint, 64.0, g.card_y + g.card_h - 30.0, 16, F_SUB)
	# 开始按钮
	_fig_btn(g.start, "开始游戏", true, true, 24, 16)
	if more_info_open:
		_draw_more_info()
	if back_dialog != "":
		_draw_back_dialog()

func rules_rect() -> Rect2:
	var c := btn_col_rect()
	# #3 两个按钮平分按钮列高度（原来固定 58px，下面空一大截）
	var hh: float = (c.size.y - COL_GAP) * 0.5
	return Rect2(c.position.x, c.position.y, c.size.x, hh)

func rules_panel() -> Rect2:
	var h: float = clampf(size.y - 160.0 - 120.0, 952.0, 1400.0)
	return Rect2(40.0, 160.0, 640.0, h)

func rules_content_rect() -> Rect2:
	var p := rules_panel()
	return Rect2(232.0, 300.0, 424.0, maxf(420.0, p.end.y - 150.0 - 300.0))

func rules_hits() -> Array:
	var p := rules_panel()
	var hits: Array = [
		{"r": Rect2(p.end.x - 68.0, p.position.y + 18.0, 48.0, 48.0), "a": "close"},
		{"r": _rules_bottom_btn(), "a": "close"},
	]
	for i in RULE_NAV_DEFS.size():
		hits.append({"r": _rules_nav_rect(i), "a": "rule_nav_%s" % str(RULE_NAV_DEFS[i][0])})
	return hits

## 规则高亮配色（照搬项目 style.css 的 .move-type-* / .dice-special 等）
const RULE_COL := {
	"move-type-launch": "#87d687", "move-type-move": "#7890d4",
	"move-type-jump": "#7fc5db", "move-type-fly": "#de8bef",
	"move-type-bonus": "#efa0c0", "dice-special": "#65bb9e",
	"consecutive-bonus": "#65bb9e", "collision-bonus": "#efa0c0",
	"finish-text": "#85c594", "beat-text": "#f26969", "stack-text": "#fbb87a",
}

## 逐字排版：中文没有空格，按【字符】贪心折行，行高用字体实际高度 -> 不会重叠也不会留空

## ---------------- 游戏规则 ----------------
func _load_rules() -> void:
	if not rules_data.is_empty(): return
	if not FileAccess.file_exists("res://data/rules.json"): return
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/rules.json"))
	if j is Array: rules_data = j

## 逐字排版：中文没有空格，按【字符】贪心折行，行高用字体实际高度 -> 不会重叠也不会留空
func _rules_build() -> void:
	_load_rules()
	var c := rules_content_rect()
	if absf(rules_cache_w - c.size.x) < 1.0 and not rules_lines.is_empty(): return
	rules_cache_w = c.size.x
	rules_lines = []
	var font := ThemeDB.fallback_font
	var y := 0.0
	for it in rules_data:
		var kind := str(it.get("k", "p"))
		var runs: Array = it.get("runs", [])
		var fs: int = 22 if kind == "h4" else (18 if kind == "h5" else 16)
		var base: Color = C_GRAY if kind == "p" else C_INK
		if kind == "h4": y += 18.0
		elif kind == "h5": y += 8.0
		var lh: float = float(fs) * 1.5
		var line: Array = []
		var acc := ""                       # 当前行的纯文本，用来量真实宽度
		var limit: float = c.size.x - 4.0   # 留 4px 余量
		for run in runs:
			var txt := str(run[0])
			var rk := str(run[1])
			var col: Color = base
			if rk == "strong": col = C_INK
			elif RULE_COL.has(rk): col = Color(str(RULE_COL[rk]))
			for ci in txt.length():
				var ch := txt[ci]
				if ch == " " and line.is_empty(): continue
				# 用【整串真实宽度】判断换行：逐字 get_char_size 累加和整串绘制有误差 -> 会溢出框外
				var w2: float = font.get_string_size(acc + ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				if w2 > limit and not line.is_empty():
					rules_lines.append({"y": y, "chars": line, "size": fs})
					y += lh
					line = []
					acc = ""
				line.append([ch, col])
				acc += ch
		if not line.is_empty():
			rules_lines.append({"y": y, "chars": line, "size": fs})
			y += lh
		if kind == "p": y += 8.0
	rules_total = y

## 把「单字段」并入相邻段。
## 原因：安卓上单字符的 draw_string 会因 CJK 字体回退失败而画成方块/乱码（规则书里的孤立「。」就是这种）。
func _merge_single_char_segs(segs: Array) -> Array:
	var merged: Array = []
	for seg in segs:
		var txt := str(seg[0])
		if txt == "":
			continue
		if txt.length() == 1 and not merged.is_empty():
			merged[merged.size() - 1][0] = str(merged[merged.size() - 1][0]) + txt
		else:
			merged.append([txt, seg[1]])
	if merged.size() > 1 and str(merged[0][0]).length() == 1:
		merged[1][0] = str(merged[0][0]) + str(merged[1][0])
		merged.remove_at(0)
	return merged

func _draw_rules() -> void:
	_rules_laid_build()
	var font := _fig_font()
	var p := rules_panel()
	var c := rules_content_rect()
	if not _rules_was_open:
		_rules_was_open = true
		_rules_active_key = "win"
		rules_scroll = 0.0
		_rules_scroll_target = 0.0
	# 滚动范围：内容底与可视区底对齐，禁止尾部滚出空白
	var maxs: float = minf(0.0, c.size.y - _rules_laid_total)
	rules_scroll = clampf(rules_scroll, maxs, 0.0)
	# 目录高亮：点击后保持点中的项；手动拖动时按滚动位置反推
	var cur_key := _rules_active_key
	if absf(rules_scroll - _rules_scroll_target) > 1.0:
		cur_key = _rules_current_key()
		_rules_active_key = cur_key
	# 背景 + 卡片
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	_fig_card(p, F_CARD, 24)
	_fig_text("游戏规则", p.position.x + 32.0, p.position.y + 70.0, 34, F_INK)
	_draw_batch2_icon("close", Vector2(p.end.x - 44.0, p.position.y + 42.0), 11.0, F_SUB)
	if rules_scroll < -2.0:
		_fig_text("游戏规则 · %s" % _rules_nav_context(cur_key), p.position.x + 32.0,
			p.position.y + 120.0, 16, F_SUB)
	else:
		_fig_text("从出发到归巢，慢慢熟悉每一步。", p.position.x + 32.0, p.position.y + 120.0, 16, F_SUB)
	# 左侧目录
	for i in RULE_NAV_DEFS.size():
		var key := str(RULE_NAV_DEFS[i][0])
		var chip := _rules_nav_rect(i)
		var on: bool = key == cur_key
		_fig_card(chip, F_GREEN_TINT if on else F_CARD2, 14, false, false)
		_fig_text(str(RULE_NAV_DEFS[i][1]), chip.position.x, chip.position.y + chip.size.y * 0.5 + 6.0, 17,
			F_GREEN if on else F_SUB, HORIZONTAL_ALIGNMENT_CENTER, chip.size.x)
	# 右侧内容（裁剪：只画落在内容框内的行）
	for it in _rules_laid:
		var kind := str(it["kind"])
		var ly: float = c.position.y + float(it["y"]) + rules_scroll
		if ly < c.position.y + 10.0 or ly > c.end.y - 2.0: continue
		if kind == "h4":
			_fig_text(str(it["text"]), c.position.x, ly, 22, F_GREEN)
		elif kind == "h5":
			_fig_text(str(it["text"]), c.position.x, ly, 19, F_GREEN)
		else:
			_fig_text(str(it["text"]), c.position.x, ly, 17, F_INK)
	# 底部说明/主按钮区域遮挡带（正文不做逐行裁剪，靠这层白底挡住溢出）
	draw_rect(Rect2(p.position.x + 16.0, p.end.y - 176.0, p.size.x - 32.0, 176.0), F_CARD)
	# 滚动条
	if _rules_laid_total > c.size.y:
		var track := Rect2(670.0, c.position.y, 4.0, c.size.y)
		_fig_card(track, Color("#EFECE7"), 2, false, false)
		var bh: float = maxf(48.0, c.size.y * minf(float(c.size.y) / _rules_laid_total, 1.0))
		var span: float = maxf(1.0, _rules_laid_total - c.size.y)
		var by: float = c.position.y + (c.size.y - bh) * clampf(-rules_scroll / span, 0.0, 1.0)
		_fig_card(Rect2(670.0, by, 4.0, bh), Color("#AFC2D6"), 2, false, false)
	# 底部说明 + 主按钮
	var at_bottom: bool = rules_scroll <= maxs + 3.0
	var helper := "已阅读至后段 · 可向上查看前文" if at_bottom else "向下阅读更多规则"
	_fig_text(helper, p.position.x + 32.0, p.end.y - 129.0, 16, F_SUB)
	var btn := _rules_bottom_btn()
	_fig_card(btn, F_GREEN, 16, false, false)
	_fig_text("知道了，回到棋盘", btn.position.x, btn.position.y + btn.size.y * 0.5 + 9.0, 24,
		Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, btn.size.x)

## 中文折行：行首不留收尾标点、行尾不留开括号（规则正文排版更自然）
const _WRAP_NO_START := "），。；：、！？,.;:!?%”』》】…）"
const _WRAP_NO_END := "（「『《【("

func _titles_wrap(font: Font, text: String, fs: int, max_w: float) -> Array:
	var lines: Array = []
	var acc := ""
	for i in text.length():
		var ch := text[i]
		var over: bool = font.get_string_size(acc + ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w
		if over and acc != "" and not _WRAP_NO_START.contains(ch):
			# 若行尾是开括号，把开括号带到下一行
			var carry := ""
			while acc.length() > 1 and _WRAP_NO_END.contains(acc[acc.length() - 1]):
				carry = acc[acc.length() - 1] + carry
				acc = acc.substr(0, acc.length() - 1)
			lines.append(acc)
			acc = carry
		acc += ch
	if acc != "": lines.append(acc)
	return lines

## ---------------- 称号图鉴（整页；卡片式排版） ----------------
const TITLE_PAGE_BG := Color("#f5f2ed")   # 与 C_BG 同色（C_BG 定义在最底层 game_main，基类看不到）
const TITLE_CARD_BG := Color("#ffffff")
const TITLE_CARD_BORDER := Color("#e2d8c8")
const TITLE_MUTED := Color("#9a918a")
const TITLE_TEXT := Color("#4a423c")

func titles_content_rect() -> Rect2:
	return Rect2(40.0, 325.0, 624.0, maxf(400.0, size.y - 445.0))

func titles_back_rect() -> Rect2:
	return Rect2(40.0, 36.0, 48.0, 48.0)

## tap vs drag：按下只挂起，松手时用位移阈值（<12px 且列表未滚动）判断是否打开详情
## 拖动取消：手指从卡片按下后如果列表滚动了，就取消这次点击（不再有 140ms 自动打开）
## 松手提交：按下到松手位移 <12px 且列表没有滚动过，才算 tap、打开详情
func _titles_on_release(pos: Vector2) -> void:
	if _title_pending_id == "": return
	var moved := pos.distance_to(_title_press_pos)
	var scrolled := absf(titles_scroll - _title_pending_scroll)
	if moved < 12.0 and scrolled < 0.5:
		title_detail_id = _title_pending_id
	_title_pending_id = ""

## flow 的松手分支处理完道具栏会直接 return，用未处理输入兜住称号列表的 release
func _unhandled_input(event: InputEvent) -> void:
	if not titles_open or titles_closing or title_detail_id != "": return
	var pos := Vector2.ZERO
	var is_rel := false
	if event is InputEventScreenTouch and not (event as InputEventScreenTouch).pressed:
		pos = (event as InputEventScreenTouch).position
		is_rel = true
	elif event is InputEventMouseButton and not (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		pos = (event as InputEventMouseButton).position
		is_rel = true
	if is_rel:
		_titles_on_release(pos)

func _titles_cancel_if_dragged() -> void:
	if _title_pending_id == "": return
	if absf(titles_scroll - _title_pending_scroll) > 0.5:
		_title_pending_id = ""

func titles_hits() -> Array:
	_titles_cancel_if_dragged()
	var hits: Array = []
	hits.append({"r": titles_back_rect(), "a": "back"})
	if title_detail_id != "":
		var dc := _center_card_y(682.0)
		hits.append({"r": Rect2(596.0, dc + 30.0, 64.0, 64.0), "a": "title_detail_close"})
		hits.append({"r": Rect2(72.0, dc + 578.0, 576.0, 72.0), "a": "title_detail_close"})
		return hits
	for f in TITLES_FILTERS:
		hits.append({"r": _titles_filter_chip(str(f[0])), "a": "rarity_%s" % str(f[0])})
	var laid_v := _titles_laid_build()
	var vis := titles_content_rect()
	var laid: Array = laid_v[0]
	if laid.is_empty():
		var eo2: float = (vis.size.y - 835.0) * 0.35
		hits.append({"r": Rect2(241.0, vis.position.y + 269.0 + eo2 + 155.0, 238.0, 54.0), "a": "titles_clear_filter"})
		return hits
	for it in laid:
		if str(it["kind"]) != "card": continue
		var r: Rect2 = it["rect"]
		r.position.y += titles_scroll
		if r.end.y < vis.position.y or r.position.y > vis.end.y: continue
		var rr := r.intersection(vis)
		if rr.size.x <= 0.0 or rr.size.y <= 0.0: continue
		hits.append({"r": rr, "a": "title_card_%s" % str((it["item"] as Dictionary).get("id", ""))})
	return hits


## 排版缓存：图例 + 三个组（卡片）+ 默认称号说明

func _draw_titles_page() -> void:
	var font := _fig_font()
	# 过渡：0→1 从右侧滑入；1→0 滑出（沿用旧语义）
	var ea: float = clampf(titles_anim, 0.0, 1.0)
	if not titles_closing: ea = 1.0 - pow(1.0 - ea, 3.0)
	else: ea = 1.0 - pow(1.0 - ea, 2.0)
	var off_x: float = (1.0 - ea) * size.x
	draw_set_transform(Vector2(off_x, 0), 0.0, Vector2.ONE)
	draw_rect(Rect2(Vector2.ZERO, size), F_BG)
	if off_x > 1.0:
		draw_rect(Rect2(-8.0, 0, 8.0, size.y), Color(0, 0, 0, 0.10))
	var laid_v := _titles_laid_build()
	var laid: Array = laid_v[0]
	var total: float = float(laid_v[1])
	var c := titles_content_rect()
	var maxs: float = minf(0.0, c.size.y - total)
	titles_scroll = clampf(titles_scroll, maxs if total > c.size.y else 0.0, 0.0)
	_titles_cancel_if_dragged()
	# ---- 滚动内容（先画，后面用页头遮住） ----
	for it in laid:
		if str(it["kind"]) == "head":
			var ly: float = c.position.y + float(it["y"]) + titles_scroll
			if ly < c.position.y - 80.0 or ly > c.end.y + 80.0: continue
			_fig_text(str(it["text"]), c.position.x, ly, 24, F_INK)
			if it.has("count") and titles_filter != "":
				var nw2: float = font.get_string_size(str(it["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x
				_fig_text("%d 个" % int(it["count"]), c.position.x + nw2 + 12.0, ly - 2.0, 14, F_SUB)
		elif str(it["kind"]) == "card":
			var r: Rect2 = it["rect"]
			r.position.y += titles_scroll
			if r.end.y < c.position.y - 10.0 or r.position.y > c.end.y + 10.0: continue
			_draw_title_card(it["item"], r)
	# 空筛选态（按内容可视区中心排布）
	if laid.is_empty():
		var eo: float = (c.size.y - 835.0) * 0.35
		var ic := Vector2(360.0, c.position.y + 269.0 + eo)
		_draw_batch2_icon("search", ic, 27.0, F_SUB)
		_fig_text("暂无已获得的%s称号" % _titles_tier_name(titles_filter), 40.0, ic.y + 78.0, 24, F_INK,
			HORIZONTAL_ALIGNMENT_CENTER, 640.0)
		_fig_text("试试其他稀有度，继续收集旅程。", 40.0, ic.y + 127.0, 16, F_SUB,
			HORIZONTAL_ALIGNMENT_CENTER, 640.0)
		var cr := Rect2(241.0, ic.y + 155.0, 238.0, 54.0)
		_fig_card(cr, F_CARD, 16, true, true)
		_fig_text("清除筛选", cr.position.x, cr.position.y + cr.size.y * 0.5 + 7.0, 20,
			Color("#5D6A82"), HORIZONTAL_ALIGNMENT_CENTER, cr.size.x)
	# ---- 页头遮挡带 + 固定头 ----
	draw_rect(Rect2(0, 0, size.x, c.position.y), F_BG)
	draw_rect(Rect2(0, c.end.y, size.x, size.y - c.end.y), F_BG)
	_fig_chevron(Vector2(62.0, 60.0), F_INK, -1, 7.0)
	_fig_text("称号图鉴", 108.0, 74.0, 34, F_INK)
	# 进度卡
	var pc := Rect2(40.0, 128.0, 640.0, 106.0)
	_fig_card(pc)
	var tot_n := _titles_all_ids().size()
	var col_n := _titles_collected_n()
	_fig_text("每一程，都值得纪念", pc.position.x + 24.0, pc.position.y + 54.0, 21, F_INK)
	_fig_text("%d / %d" % [col_n, tot_n], pc.end.x - 224.0, pc.position.y + 60.0, 34, F_GREEN,
		HORIZONTAL_ALIGNMENT_RIGHT, 200.0)
	var bar := Rect2(pc.position.x + 24.0, pc.position.y + 75.0, pc.size.x - 48.0, 8.0)
	_fig_card(bar, Color("#EFECE7"), 4, false, false)
	if tot_n > 0 and col_n > 0:
		_fig_card(Rect2(bar.position.x, bar.position.y, maxf(8.0, bar.size.x * float(col_n) / float(tot_n)), 8.0),
			F_GREEN, 4, false, false)
	# 稀有度筛选 chips
	for f in TITLES_FILTERS:
		var tier := str(f[0])
		var chip := _titles_filter_chip(tier)
		var on: bool = titles_filter == tier
		_fig_card(chip, F_GREEN_TINT if on else F_CARD, 16, true, true)
		if on:
			draw_style_box(_sb(Color(0, 0, 0, 0), 16, 2, F_GREEN), chip)
		_fig_text(str(f[1]), chip.position.x, chip.position.y + 34.0, 21,
			_titles_tier_col(tier), HORIZONTAL_ALIGNMENT_CENTER, chip.size.x)
	# 底部提示
	var hint := ""
	if titles_filter != "":
		hint = "%s · 仅看已获得" % _titles_tier_name(titles_filter)
	elif laid.is_empty():
		hint = "共 %d 个称号 · 对局中达成即得" % tot_n
	else:
		hint = "向下查看其他称号 · 共 %d 个" % tot_n
	_fig_text(hint, 40.0, c.end.y + 40.0, 16, F_SUB)
	# 滚动条
	if total > c.size.y:
		var track := Rect2(676.0, c.position.y, 4.0, c.size.y)
		_fig_card(track, Color("#EFECE7"), 2, false, false)
		var bh: float = maxf(48.0, c.size.y * c.size.y / total)
		var by: float = c.position.y + (c.size.y - bh) * clampf(-titles_scroll / maxf(1.0, total - c.size.y), 0.0, 1.0)
		_fig_card(Rect2(676.0, by, 4.0, bh), Color("#AFC2D6"), 2, false, false)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 详情弹层（画在页面坐标系，不受滑入位移影响）
	if title_detail_id != "":
		_draw_title_detail(title_detail_id)

## 返回确认弹窗（Android 侧滑返回 / 返回键触发）
func back_dialog_rect() -> Rect2:
	return Rect2(40.0, _center_card_y(320.0), 640.0, 320.0)

func back_hits() -> Array:
	var p := back_dialog_rect()
	return [
		{"r": Rect2(72.0, p.end.y - 102.0, 280.0, 72.0), "a": "cancel", "t": "取消"},
		{"r": Rect2(368.0, p.end.y - 102.0, 280.0, 72.0), "a": "ok", "t": "确定"},
		{"r": Rect2(p.end.x - 66.0, p.position.y + 18.0, 48.0, 48.0), "a": "cancel", "t": "×"},
	]

func _draw_back_dialog() -> void:
	var p := back_dialog_rect()
	var cp := _back_dialog_copy()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	_fig_card(p, F_CARD, 24)
	_fig_text(str(cp["title"]), p.position.x + 32.0, p.position.y + 70.0, 30, F_INK)
	_draw_batch2_icon("close", Vector2(p.end.x - 44.0, p.position.y + 42.0), 11.0, F_SUB)
	if str(cp["desc"]) != "":
		# 行首图标：出口括号 + 向右箭头
		var ic := Vector2(p.position.x + 40.0, p.position.y + 122.0)
		draw_line(ic + Vector2(-9.0, -9.0), ic + Vector2(-9.0, 9.0), F_GREEN, 2.2, true)
		draw_line(ic + Vector2(-9.0, -9.0), ic + Vector2(-3.0, -9.0), F_GREEN, 2.2, true)
		draw_line(ic + Vector2(-9.0, 9.0), ic + Vector2(-3.0, 9.0), F_GREEN, 2.2, true)
		draw_line(ic + Vector2(-2.0, 0.0), ic + Vector2(11.0, 0.0), F_GREEN, 2.2, true)
		draw_polyline(PackedVector2Array([ic + Vector2(5.0, -6.0), ic + Vector2(11.0, 0.0),
			ic + Vector2(5.0, 6.0)]), F_GREEN, 2.2, true)
		_fig_text(str(cp["desc"]), p.position.x + 64.0, p.position.y + 130.0, 21, F_INK)
	if str(cp["note"]) != "":
		_fig_text(str(cp["note"]), p.position.x + 32.0, p.position.y + 186.0, 16, F_SUB)
	var hits := back_hits()
	for i in 2:
		var r: Rect2 = hits[i].r
		var prim: bool = i == 1
		if prim:
			_fig_card(r, Color("#C0453C"), 16, false, false)
			_fig_text(str(cp["ok"]), r.position.x, r.position.y + r.size.y * 0.5 + 9.0, 24,
				Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
		else:
			_fig_card(r, F_CARD, 16, true, false)
			_fig_text(str(cp["cancel"]), r.position.x, r.position.y + r.size.y * 0.5 + 9.0, 24,
				F_INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

func _click_titles(pos: Vector2) -> void:
	if titles_closing: return
	_titles_cancel_if_dragged()
	if title_detail_id != "":
		for h in titles_hits():
			if (h.r as Rect2).has_point(pos) and str(h.a) == "title_detail_close":
				title_detail_id = ""
				queue_redraw()
				return
		title_detail_id = ""
		queue_redraw()
		return
	for h in titles_hits():
		if not (h.r as Rect2).has_point(pos): continue
		var a := str(h.a)
		if a == "back":
			titles_closing = true
			_title_pending_id = ""
			queue_redraw()
			return
		if a.begins_with("rarity_"):
			var tier := a.substr(7)
			titles_filter = "" if titles_filter == tier else tier
			titles_scroll = 0.0
			_title_pending_id = ""
		elif a == "titles_clear_filter":
			titles_filter = ""
			titles_scroll = 0.0
			_title_pending_id = ""
		elif a.begins_with("title_card_"):
			# tap vs drag：按下只记录，等 release 时按位移判断（>12px 或列表滚动过都算拖动）
			_title_pending_id = a.substr(11)
			_title_pending_scroll = titles_scroll
			_title_press_pos = pos
		queue_redraw()
		return

func _click_rules(pos: Vector2) -> void:
	if not rules_open: return
	if not rules_panel().has_point(pos):
		rules_open = false
		queue_redraw()
		return
	_rules_laid_build()
	for h in rules_hits():
		if not (h.r as Rect2).has_point(pos): continue
		var a := str(h.a)
		if a == "close":
			rules_open = false
		elif a.begins_with("rule_nav_"):
			var key := a.substr(9)
			_rules_active_key = key
			# 跳转 clamp：最远只到内容底（最后几节无法顶到顶部时不产生尾部空白）
			var c := rules_content_rect()
			var maxs: float = minf(0.0, c.size.y - _rules_laid_total)
			rules_scroll = clampf(-float(_rules_section_y.get(key, 0.0)), maxs, 0.0)
			_rules_scroll_target = rules_scroll
		queue_redraw()
		return

# ---------------------------------------------------------------- 道具栏（解耦第 4 步）
# ================================================================ 道具栏（道具模式）
const ITEM_IDS := ["remote-dice", "polyhedral-dice", "teleport", "mysteryBox"]
## 道具说明（照搬参考 game.html 的 skill-desc / skill-cost）
## 道具说明（长按道具栏弹出）：第二行起写清"使用时机"，否则玩家不知道摇完骰子为什么点不动
const ITEM_DESC := {
	"mysteryBox": ["积分<40时可用", "获得最多40积分", "摇骰前后都能用，开盒后直接交出回合"],
	"teleport": ["传送指定棋子到随机位置", "摇骰前后都能用，传送后直接交出回合"],
	"polyhedral-dice": ["投掷 1-12 的随机点数", "只能在本回合摇骰前使用", "摇完骰子后变灰不可选"],
	"remote-dice": ["选择指定的骰子点数", "只能在本回合摇骰前使用", "摇完骰子后变灰不可选"],
}
const ITEM_ICONS := {"remote-dice": "res://assets/icons/item_remote_dice.png",
	"polyhedral-dice": "res://assets/icons/item_polyhedral_dice.png",
	"teleport": "res://assets/icons/item_teleport.png",
	"mysteryBox": "res://assets/icons/item_mysteryBox.png"}

const ITEM_NAMES := {"remote-dice": "遥控骰子", "polyhedral-dice": "多面骰子",
	"teleport": "传送门", "mysteryBox": "盲盒"}

func item_bar_rect() -> Rect2:
	# 道具模式：按设计 02 的 142 高道具栏，替代日志条
	if _item_hud_mode(): return Rect2(40.0, 952.0 + extra_h(), 640.0, 112.0)
	return Rect2(40.0, 972.0 + extra_h(), 640.0, 88.0)

func item_btns() -> Array:
	var out: Array = []
	var r := item_bar_rect()
	var n: int = ITEM_IDS.size()
	var w: float = (r.size.x - float(n - 1) * 10.0) / float(n)
	for i in n:
		out.append({"r": Rect2(r.position.x + float(i) * (w + 10.0), r.position.y, w, r.size.y),
			"id": ITEM_IDS[i], "t": str(ITEM_NAMES[ITEM_IDS[i]])})
	return out

## 这个道具现在能不能【用】（除了积分，还要看阶段）：
## ★ 遥控骰子 / 多面骰子的作用就是"决定这次骰子"，摇完再用毫无意义（遥控骰子还会白扣分、
##   多面骰会滞留下回合），所以只允许在【rolling 且还没摇】时用；
## ★ 传送门是"走子替代"（买下即传送并交出回合）、盲盒当场结算也交回合，
##   这两个阶段都能用（与参考 engine.mjs:803/810 的 requireTurnIn(['rolling','selecting']) 一致）。


# ================================================================ 核心状态 + 棋盘坐标换算（整模块外移 · 第 1 批）
# 所有绘制模块都要用 to_screen/board_scale，所以放在继承链最浅层（screens_base）。
const BOARD_UNITS := 190.0

var st: Dictionary = {}

var board_scale := 1.0
var board_origin := Vector2.ZERO

# ★ 棋盘中央的 3D 骰子已按反馈整体移除（SubViewport 方案观感仍不自然）。
#   现在只有底栏那颗常驻骰子：颜色跟随当前回合玩家（hud_cur）。
				# 棋子移动动画: "pid_i" -> {pts, t, dur}
var tele_alpha := {}          # 传送门淡出/淡入的当前透明度（"pid_i" -> 0..1），段结束复位 1.0
## 传送门特效（v18.7 重做）：不再整盘"聚光冲淡"，改成【收束 + 重组】的本地环形能量场。
## 参考业界常见做法（Dissolve & Teleport / Energy Ring Portal / Magic Ring）：
##   起点：双光环反向旋转 + 粒子向内收束 + 消失瞬间闪光，棋子同时缩小旋转淡出；
##   落点：柔光 + 两道扩散冲击环 + 星光外散，棋子 overshoot 弹入。整段 0.9s（原来 1.75s）。
var tele_key := ""            # 正在传送的棋子键
var tele_fx := ""             # "" | "out"(收束) | "in"(重组)
var tele_fx_t := 0.0          # 当前段进度 0..1
var tele_from := Vector2.ZERO # 起点（棋盘单位）
var tele_to := Vector2.ZERO   # 落点（棋盘单位）
var tele_scale := 1.0         # 传送中棋子的缩放
var tele_spin := 0.0          # 传送中棋子的额外旋转（弧度）

## 逐对手击败矩阵：defeat_matrix[攻击者][被击败者] = 颗数（参考 defeatCountDisplay.js + engine.mjs:875）
var defeat_matrix := {}
## st 的版本号：_apply / start_game 时 +1，用来让"依赖 st 的每帧查询"缓存失效
var st_ver := 0

func to_screen(bp: Vector2) -> Vector2:
	return board_origin + (bp + Vector2(95, 95)) * board_scale

const ROW_H := 22.0

# 底部栏高度：按视口高度比例缩放，否则在长屏手机上骰子和信息面板会显得过小、跟棋盘割裂

func layout() -> void:
	# Figma A 方案：640x640 棋盘，水平居中，顶部 240，底部留出 880~1280 的 HUD 区
	var sz := size
	var side: float = minf(sz.x - 80.0, 640.0)
	board_scale = side / BOARD_UNITS
	board_origin = Vector2((sz.x - side) * 0.5, 240.0 + play_dy())

# ---------------------------------------------------------------- 绘图小工具
## StyleBoxFlat 缓存。
## ★ 性能：Godot 的 _draw() 每帧都跑，里面 new StyleBoxFlat() 是纯浪费 ——
##   道具栏 4 个按钮 + 信息面板 + 若干按钮，一帧能 new 十几个，
##   在踩子这种"动画 + 粒子同时刷帧"的时刻就会掉帧。
##   实测把这条路径的分配干掉后，踩子瞬间不再顿一下。


func _draw_tele_fx() -> void:
	if tele_fx == "" or tele_key == "": return
	var s := board_scale
	var parts := tele_key.split("_")
	var pid: int = int(parts[0]) if parts.size() > 0 else 0
	var col: Color = cols.get(pid, Color.WHITE)
	# 提亮一档：浅色玩家色直接画在米色盘面上对比度太低
	var hot := Color(minf(1.0, col.r * 0.5 + 0.5), minf(1.0, col.g * 0.5 + 0.5), minf(1.0, col.b * 0.5 + 0.5), 1.0)
	var t: float = clampf(tele_fx_t, 0.0, 1.0)
	var fade_in: float = clampf(t / 0.12, 0.0, 1.0)       # 整体淡入，避免"啪"一下冒出来
	# ── 起落两格的标记：只比棋子大一圈（原来半径 20~25 单位 ≈ 两个格子，太大）──
	for cc in [tele_from, tele_to]:
		var cp: Vector2 = to_screen(cc)
		draw_circle(cp, 8.0 * s, Color(hot.r, hot.g, hot.b, 0.16 * fade_in))
		draw_arc(cp, 10.5 * s, 0.0, TAU, 26, Color(hot.r, hot.g, hot.b, 0.55 * fade_in), 1.8 * s)
		draw_arc(cp, 13.0 * s, 0.0, TAU, 26, Color(hot.r, hot.g, hot.b, 0.20 * fade_in), 1.2 * s)
	var p: Vector2 = to_screen(tele_from if tele_fx == "out" else tele_to)
	if tele_fx == "out":
		# ── 收束：脉动亮核 + 三层反向旋转光环 + 向内收束粒子 + 消失闪光 ──
		var pulse: float = 1.0 + 0.12 * sin(t * TAU * 2.2)     # 蓄力脉动
		var core_a: float = (0.25 + 0.45 * t) * fade_in * (1.0 - smoothstep(0.85, 1.0, t))
		draw_circle(p, 7.5 * s * pulse, Color(hot.r, hot.g, hot.b, core_a * 0.7))
		draw_circle(p, 3.2 * s * pulse, Color(1, 1, 1, minf(1.0, core_a + 0.25)))
		var a1: float = fade_in * (1.0 - smoothstep(0.80, 1.0, t))
		for k2 in 3:
			var f2: float = float(k2)
			var rr: float = (8.5 + 2.6 * f2) * s * (1.0 - 0.22 * t) * (1.0 + 0.02 * sin(t * 9.0 + f2))
			var lw: float = (2.9 - 0.55 * f2) * s
			var dir: float = 1.0 if k2 != 1 else -1.0
			var a0: float = t * (7.0 + 1.6 * f2) * dir + f2 * 2.1
			var arc_len: float = PI * (1.15 + 0.35 * t)    # 弧越转越长
			draw_arc(p, rr, a0, a0 + arc_len, 20, Color(hot.r, hot.g, hot.b, (0.85 - 0.12 * f2) * a1), lw)
			draw_arc(p, rr, a0 + PI, a0 + PI + arc_len * 0.6, 16, Color(1, 1, 1, 0.55 * a1), lw * 0.55)
		# 向内收束：半径用 ease-in，越收越快
		for i in 10:
			var ang: float = TAU * float(i) / 10.0 + t * 2.6
			var rad: float = lerpf(21.0, 2.6, t * t) * s
			var sz2: float = maxf(0.9, 2.6 * s * (0.4 + 0.6 * t))
			draw_circle(p + Vector2(cos(ang), sin(ang)) * rad, sz2, Color(1, 1, 1, 0.55 + 0.4 * t))
		# 消失瞬间：紧凑的白色闪光环 + 亮核
		if t > 0.76:
			var u: float = (t - 0.76) / 0.24
			draw_circle(p, lerpf(4.5, 1.2, u) * s, Color(1, 1, 1, 0.95 * (1.0 - u * 0.4)))
			draw_arc(p, lerpf(3.0, 26.0, u) * s, 0.0, TAU, 30, Color(1, 1, 1, 0.95 * (1.0 - u)), 3.2 * s * (1.0 - 0.55 * u))
			draw_arc(p, lerpf(2.0, 18.0, u) * s, 0.0, TAU, 26, Color(hot.r, hot.g, hot.b, 0.8 * (1.0 - u)), 2.4 * s * (1.0 - 0.5 * u))
	else:
		# ── 重组：亮核闪现 + 两道紧凑冲击环 + 星光外散 + 柔光收尾 ──
		var flash: float = clampf((0.30 - t) / 0.30, 0.0, 1.0)
		var glow_a: float = (0.22 * (1.0 - 0.5 * t)) * clampf(t / 0.1, 0.0, 1.0)
		draw_circle(p, (9.0 + 4.0 * t) * s, Color(hot.r, hot.g, hot.b, glow_a))
		draw_circle(p, (2.5 + 8.0 * flash) * s, Color(1, 1, 1, 0.9 * flash))
		for k3 in 2:
			var u2: float = clampf((t - 0.09 * float(k3)) / 0.72, 0.0, 1.0)
			if u2 <= 0.0: continue
			var c3: Color = Color(1, 1, 1, 0.85 * (1.0 - u2)) if k3 == 0 else Color(hot.r, hot.g, hot.b, 0.75 * (1.0 - u2))
			draw_arc(p, lerpf(3.0, 20.0 + 6.0 * float(k3), u2) * s, 0.0, TAU, 30, c3,
				maxf(1.0, (3.0 - 0.8 * float(k3)) * s * (1.0 - 0.55 * u2)))
		for i in 10:
			var ang2: float = TAU * float(i) / 10.0 + 0.35
			var rad2: float = lerpf(2.5, 17.0, t) * s
			draw_circle(p + Vector2(cos(ang2), sin(ang2)) * rad2,
				maxf(0.8, 2.2 * s * (1.0 - 0.7 * t)), Color(1, 1, 1, 0.85 * (1.0 - t)))
		# 落定后一圈很淡的"余韵"（只在最后 40% 出现）
		if t > 0.6:
			var u3: float = (t - 0.6) / 0.4
			draw_arc(p, (11.0 + 3.0 * u3) * s, 0.0, TAU, 28, Color(hot.r, hot.g, hot.b, 0.22 * (1.0 - u3)), 1.4 * s)
## 骰子点数在面内的布局（u,v ∈ 0..1）——底栏小骰子用不到 3D 面，但保留给可能的美术资源

## 逐对手击败矩阵（参考 game.html 的 .defeat-counts + defeatCountDisplay.js）：
## 每个座位在积分数值下方画一排 3 个数字，颜色 =【被击败方】的玩家色。
func _draw_defeat_matrix() -> void:
	if st.is_empty() or defeat_matrix.is_empty(): return
	# 进对局就显示（不再等"有人被击败"才出现；开局四排都是 0 也照画）
	var font := ThemeDB.fallback_font
	var unit_h: float = (to_screen(Vector2(0, ENERGY_BAR_H)) - to_screen(Vector2.ZERO)).y
	var base_half: float = 12.0 * unit_h / ENERGY_BAR_H     # 停机坪半高（与 energy_bar_rect 同口径）
	for pid in st.order:
		var pid_i := int(pid)
		var opps: Array = []
		for o in st.order:
			if int(o) != pid_i: opps.append(int(o))
		if opps.is_empty(): continue
		var cw := 26.0
		var row_w: float = cw * float(opps.size())
		# ★ 水平基准 = 【停机坪卡片中心】。以前用的是积分条的中点，而积分条是挂在卡片【外侧】的
		#   （外侧方向 27 单位），所以四个角天然就偏，只能靠手调偏移硬凑 —— 怎么调都居中不了。
		var bp: Array = D.bases[str(pid_i)]
		var bc: Vector2 = to_screen(Vector2(float(bp[0]), float(bp[1])))
		var x0: float = bc.x - row_w * 0.5
		# 垂直：上半屏（绿=1、红=4）在停机坪【顶部线】上；下半屏（黄=2、蓝=3）在【底部线】下方
		var y: float = (bc.y - base_half) if bc.y < size.y * 0.5 else (bc.y + base_half + 9.0)
		# 垂直微调（按编辑器观感调的，高度已确认没问题；水平已由卡片中心对齐，不再需要偏移）
		match pid_i:
			1: y -= 24.0
			2: y += 12.0
			3: y += 12.0
			4: y -= 24.0
		# 垫一层浅底，免得压在棋盘格上看不清（y 是这一排的垂直中心）
		draw_style_box(_sb(Color(1, 1, 1, 0.85), 8, 1.2, C_LINE),
			Rect2(x0 - 6.0, y - 12.0, row_w + 12.0, 24.0))
		for j in opps.size():
			var opp := int(opps[j])
			var n := 0
			if defeat_matrix.has(pid_i) and (defeat_matrix[pid_i] as Dictionary).has(opp):
				n = int((defeat_matrix[pid_i] as Dictionary)[opp])
			draw_string(font, Vector2(x0 + float(j) * cw, y + 6.5), str(n),
				HORIZONTAL_ALIGNMENT_CENTER, cw, 17, cols.get(opp, C_GRAY))

## 某个座位停机坪外侧的积分条屏幕矩形


# 基础常量 / 数据表（整模块外移第 1 批：layout 与绘制模块都要用）
var D: Dictionary
const ENERGY_BAR_W := 3.8      # 棋盘单位（对应参考的 10px）
const ENERGY_BAR_H := 22.5     # 棋盘单位（对应参考的 60px）

const E := preload("res://scripts/engine.gd")

# ---- 场景枚举 / 动画队列（全链共享的基础状态）----
enum Scr { MODE, SETUP, PLAY, NET }  # NET 只追加在最后（tests/test_anim.gd 里 screen=2 仍是 PLAY）
var seq: Array = []           # 动画段队列（同组并行、组间串行）
var cur_grp := 0              # 当前动画组号

# ---- 音效（全链共享）----
func _sfx(nm: String) -> void:
	if sfx.has(nm):
		var p: AudioStreamPlayer = sfx[nm]
		p.play()

var sfx := {}
const B := preload("res://scripts/bot.gd")

# ================================================================
# Figma 第二批（missing-screens）：设置页 / 称号图鉴 / 游戏规则 / 退出确认
#   · 全部为 MODE 屏内覆盖层（不新增 Scr 枚举）；动作 ID 集中在本段。
#   · flow_base 只需接线：settings_open 入口 + _input 分发 _click_settings(pos)
# ================================================================

## 设置页动作 ID（集中定义；settings_hits() 返回的 a 全部来自这里）
const SETTINGS_ACTIONS := [
	"settings_open", "settings_back", "settings_titles", "about_game", "privacy",
	"restore_default", "clear_cache", "set_sound", "set_music", "set_vibrate",
	"set_anim_speed", "set_reduce_motion", "set_hints",
	"confirm_ok", "confirm_cancel", "settings_avatar", "settings_nick",
	"nick_random", "nick_cancel", "nick_save", "avatar_close", "avatar_pick_*",
]

const SETTINGS_PATH := "user://settings.json"
const SETTINGS_CACHE_ROW := 12.8      # 设计稿展示的缓存占用（MB）

var settings_open := false
var settings_drawer := false          # 01f：右侧抽屉版（默认全屏页）
var settings_sub := ""                # "" | "about"
var settings_confirm := ""            # "" | "restore" | "clear_cache"
var settings_sound := true
var settings_music := 70              # 0..100
var settings_vibrate := 2             # 0关 1弱 2中 3强
var settings_anim := 1               # 0=0.5x 1=1x 2=1.5x
var settings_reduce_motion := false
var settings_hints := true
var settings_cache_mb := SETTINGS_CACHE_ROW
var settings_toast := ""
var settings_toast_sub := ""
var settings_toast_ms := 0
var _settings_loaded := false
var _settings_drag_track := Rect2()

const SETTINGS_SEG_VIBRATE := ["关", "弱", "中", "强"]
const SETTINGS_SEG_ANIM := ["0.5x", "1x", "1.5x"]

func open_settings(drawer: bool = false) -> void:
	_settings_load()
	settings_open = true
	settings_drawer = drawer
	settings_sub = ""
	settings_confirm = ""
	settings_toast = ""
	queue_redraw()

func close_settings() -> void:
	settings_open = false
	settings_drawer = false
	settings_sub = ""
	settings_confirm = ""
	settings_toast = ""
	queue_redraw()

func _settings_load() -> void:
	if _settings_loaded: return
	_settings_loaded = true
	if not FileAccess.file_exists(SETTINGS_PATH): return
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if not (j is Dictionary): return
	var d: Dictionary = j
	settings_sound = bool(d.get("sound", settings_sound))
	settings_music = clampi(int(d.get("music", settings_music)), 0, 100)
	settings_vibrate = clampi(int(d.get("vibrate", settings_vibrate)), 0, 3)
	settings_anim = clampi(int(d.get("anim", settings_anim)), 0, 2)
	settings_reduce_motion = bool(d.get("reduce_motion", settings_reduce_motion))
	settings_hints = bool(d.get("hints", settings_hints))
	settings_cache_mb = float(d.get("cache_mb", settings_cache_mb))

func _settings_save() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f == null: return
	f.store_string(JSON.stringify({
		"sound": settings_sound, "music": settings_music, "vibrate": settings_vibrate,
		"anim": settings_anim, "reduce_motion": settings_reduce_motion,
		"hints": settings_hints, "cache_mb": settings_cache_mb,
	}))
	f.close()

func _settings_reset_default() -> void:
	settings_sound = true
	settings_music = 70
	settings_vibrate = 2
	settings_anim = 1
	settings_reduce_motion = false
	settings_hints = true
	_settings_save()

func _settings_toast_show(title: String, sub: String) -> void:
	settings_toast = title
	settings_toast_sub = sub
	settings_toast_ms = Time.get_ticks_msec()

## 设置页几何：panel 为整页 (0,0,720,1280) 或抽屉 (120,0,600,1280)
func _settings_geo(panel: Rect2 = Rect2(0, 0, 720, 0)) -> Dictionary:
	if panel.size.y <= 1.0: panel.size.y = size.y
	var drawer: bool = panel.position.x > 1.0
	var mx := 24.0 if drawer else 40.0
	var title_x := panel.position.x + (84.0 if drawer else 108.0)
	var back := Rect2(panel.position.x + mx, 36.0, 48.0, 48.0)
	var card_x := panel.position.x + mx
	var card_w: float = panel.size.x - mx * 2.0
	var profile := Rect2(card_x, 128.0, card_w, 106.0)
	var group1 := Rect2(card_x, 301.0, card_w, 463.0)
	var group2 := Rect2(card_x, 832.0, card_w, 318.0)
	var rows1: Array = []
	for i in 6:
		rows1.append(Rect2(card_x, group1.position.y + 16.0 + 72.0 * float(i), card_w, 72.0))
	var rows2: Array = []
	for i in 4:
		rows2.append(Rect2(card_x, group2.position.y + 14.0 + 72.0 * float(i), card_w, 72.0))
	var ctrl_right: float = card_x + card_w - (24.0 if not drawer else 24.0)
	var sw_w := 64.0
	var sw_x: float = ctrl_right - 6.0 - sw_w
	var slider_w: float = 210.0 if drawer else 260.0
	var g := {
		"drawer": drawer,
		"panel": panel,
		"back": back,
		"title_x": title_x,
		"profile": profile,
		"avatar_c": Vector2(profile.position.x + 24.0 + 28.0, profile.position.y + 53.0),
		"titles_entry": Rect2(profile.end.x - 232.0, profile.position.y + 14.0, 208.0, 78.0),
		"avatar_edit": Rect2(profile.position.x + 20.0, profile.position.y + 21.0, 64.0, 64.0),
		"nick_edit": Rect2(profile.position.x + 86.0, profile.position.y + 20.0, 250.0, 60.0),
		"group1": group1,
		"group2": group2,
		"rows1": rows1,
		"rows2": rows2,
		"sw_w": sw_w, "sw_x": sw_x,
		"ctrl_right": ctrl_right,
		"slider_w": slider_w,
		"seg_vib": Rect2(ctrl_right - 228.0, 0.0, 228.0, 52.0),
		"seg_anim": Rect2(ctrl_right - 172.0, 0.0, 172.0, 52.0),
		"sec1_y": 275.0,
		"sec2_y": 805.0,
		"footer_y": panel.position.y + panel.size.y - 43.0,
	}
	# 分段控件按行中心定位
	g["seg_vib"] = Rect2(ctrl_right - 228.0, rows1[2].position.y + 10.0, 228.0, 52.0)
	g["seg_anim"] = Rect2(ctrl_right - 172.0, rows1[3].position.y + 10.0, 172.0, 52.0)
	# 音乐滑条：标签 0/当前/100 + 轨道
	var r2: Rect2 = rows1[1]
	g["music_labels_y"] = r2.position.y + 13.0
	g["music_track"] = Rect2(ctrl_right - slider_w, r2.position.y + 46.0, slider_w, 8.0)
	return g

## 行中心（用于标题/说明/控件垂直对齐）
func _settings_row_center(r: Rect2) -> float:
	return r.position.y + 36.0

func _settings_hit_rows(geo: Dictionary) -> Array:
	var hits: Array = []
	var rows1: Array = geo["rows1"]
	var rows2: Array = geo["rows2"]
	# 音效 / 减少动态 / 操作提示：整行可点（开关在行尾）
	hits.append({"r": rows1[0], "a": "set_sound"})
	hits.append({"r": rows1[4], "a": "set_reduce_motion"})
	hits.append({"r": rows1[5], "a": "set_hints"})
	# 音乐滑条（整行可点，x 决定值）
	var mr: Rect2 = rows1[1]
	hits.append({"r": Rect2(geo["music_track"].position.x - 36.0, mr.position.y, geo["music_track"].size.x + 72.0, 72.0),
		"a": "set_music", "track": geo["music_track"]})
	# 震动 / 动画分段：每段一个命中
	var sv: Rect2 = geo["seg_vib"]
	for i in 4:
		hits.append({"r": Rect2(sv.position.x + float(i) * 56.0, sv.position.y, 56.0, 56.0),
			"a": "set_vibrate", "v": i})
	var sa: Rect2 = geo["seg_anim"]
	for i in 3:
		hits.append({"r": Rect2(sa.position.x + float(i) * 56.0, sa.position.y, 56.0, 56.0),
			"a": "set_anim_speed", "v": i})
	# 数据与关于
	hits.append({"r": rows2[0], "a": "clear_cache"})
	hits.append({"r": rows2[1], "a": "privacy"})
	hits.append({"r": rows2[3], "a": "restore_default"})
	return hits

func settings_hits() -> Array:
	var hits: Array = []
	if not settings_open: return hits
	if settings_confirm != "":
		var cg := _settings_confirm_geo()
		hits.append({"r": cg["cancel"], "a": "confirm_cancel"})
		hits.append({"r": cg["ok"], "a": "confirm_ok"})
		hits.append({"r": cg["close"], "a": "confirm_cancel"})
		return hits
	var geo := _settings_geo(Rect2(120.0, 0.0, 600.0, size.y) if settings_drawer else Rect2(0.0, 0.0, 720.0, size.y))
	hits.append({"r": geo["back"], "a": "settings_back"})
	if settings_sub == "about":
		return hits
	hits.append({"r": geo["titles_entry"], "a": "settings_titles"})
	# 资料卡：点头像/昵称修改（设置页保持打开，保存后即时刷新）
	hits.append({"r": geo["avatar_edit"], "a": "settings_avatar"})
	hits.append({"r": geo["nick_edit"], "a": "settings_nick"})
	hits.append_array(_settings_hit_rows(geo))
	return hits

func _settings_confirm_geo() -> Dictionary:
	var card := Rect2(40.0, _center_card_y(306.0), 640.0, 306.0)
	return {
		"card": card,
		"close": Rect2(card.end.x - 66.0, card.position.y + 18.0, 48.0, 48.0),
		"cancel": Rect2(72.0, card.end.y - 102.0, 280.0, 72.0),
		"ok": Rect2(368.0, card.end.y - 102.0, 280.0, 72.0),
	}

func _click_settings(pos: Vector2) -> void:
	if not settings_open: return
	for h in settings_hits():
		if not (h.r as Rect2).has_point(pos): continue
		match str(h.a):
			"settings_back":
				if settings_sub == "":
					close_settings()
				else:
					settings_sub = ""
			"settings_titles":
				# 设置页保持打开；称号图鉴作为上层覆盖层，关闭后回到设置页
				titles_open = true
				titles_closing = false
				titles_anim = 0.0
				titles_scroll = 0.0
				titles_filter = ""
				title_detail_id = ""
				_title_pending_id = ""
			"about_game", "privacy":
				settings_sub = "about"
			"restore_default":
				settings_confirm = "restore"
			"clear_cache":
				settings_confirm = "clear_cache"
			"set_sound":
				settings_sound = not settings_sound
				_settings_save()
			"set_reduce_motion":
				settings_reduce_motion = not settings_reduce_motion
				_settings_save()
			"set_hints":
				settings_hints = not settings_hints
				_settings_save()
			"set_music":
				_settings_apply_music(pos)
			"set_vibrate":
				settings_vibrate = clampi(int(h.get("v", 2)), 0, 3)
				_settings_save()
			"set_anim_speed":
				settings_anim = clampi(int(h.get("v", 1)), 0, 2)
				_settings_save()
			"confirm_ok":
				if settings_confirm == "restore":
					_settings_reset_default()
					_settings_toast_show("已恢复默认设置", "声音与体验已回到默认值")
				else:
					var released := settings_cache_mb
					settings_cache_mb = 0.0
					_settings_save()
					_settings_toast_show("缓存已清理", "已释放 %.1f MB · 当前占用 0 MB" % released)
				settings_confirm = ""
			"confirm_cancel":
				settings_confirm = ""
		queue_redraw()
		return

## 音乐滑条：点击/拖动轨道设值（flow_base 在 drag 分支调用，可选）
func _settings_drag(pos: Vector2) -> void:
	if not settings_open or settings_sub != "" or settings_confirm != "": return
	_settings_apply_music(pos)

func _settings_apply_music(pos: Vector2) -> void:
	var geo := _settings_geo(Rect2(120.0, 0.0, 600.0, size.y) if settings_drawer else Rect2(0.0, 0.0, 720.0, size.y))
	var tr: Rect2 = geo["music_track"]
	if tr.size.x <= 1.0: return
	var t: float = clampf((pos.x - tr.position.x) / tr.size.x, 0.0, 1.0)
	var nv := int(round(t * 100.0))
	if nv != settings_music:
		settings_music = nv
		_settings_save()
		queue_redraw()
# ---------------------------------------------------------------- 设置页绘制
func _draw_batch2_icon(kind: String, c: Vector2, s: float, col: Color) -> void:
	var w := 2.4
	match kind:
		"close":
			draw_line(c + Vector2(-s * 0.5, -s * 0.5), c + Vector2(s * 0.5, s * 0.5), col, w, true)
			draw_line(c + Vector2(-s * 0.5, s * 0.5), c + Vector2(s * 0.5, -s * 0.5), col, w, true)
		"reset":
			draw_arc(c, s * 0.62, deg_to_rad(-40.0), deg_to_rad(260.0), 22, col, w, true)
			var tip := c + Vector2(cos(deg_to_rad(-40.0)), sin(deg_to_rad(-40.0))) * s * 0.62
			draw_line(tip + Vector2(-s * 0.28, -s * 0.04), tip + Vector2(s * 0.10, -s * 0.30), col, w, true)
			draw_line(tip + Vector2(-s * 0.28, -s * 0.04), tip + Vector2(s * 0.22, s * 0.14), col, w, true)
		"lock":
			draw_rect(Rect2(c + Vector2(-s * 0.42, -s * 0.10), Vector2(s * 0.84, s * 0.62)), col, false, w)
			draw_arc(c + Vector2(0.0, -s * 0.10), s * 0.30, PI, TAU, 12, col, w, true)
		"check":
			draw_polyline(PackedVector2Array([c + Vector2(-s * 0.42, 0.0), c + Vector2(-s * 0.10, s * 0.32),
				c + Vector2(s * 0.46, -s * 0.34)]), col, w, true)
		"info":
			draw_circle(c, s * 0.62, col, false, w)
			draw_circle(c + Vector2(0.0, -s * 0.28), s * 0.08, col)
			draw_line(c + Vector2(0.0, -s * 0.08), c + Vector2(0.0, s * 0.34), col, w, true)
		"search":
			draw_circle(c + Vector2(-s * 0.12, -s * 0.12), s * 0.48, col, false, w)
			draw_line(c + Vector2(s * 0.24, s * 0.24), c + Vector2(s * 0.68, s * 0.68), col, w, true)
		"trophy":
			draw_rect(Rect2(c + Vector2(-s * 0.42, -s * 0.46), Vector2(s * 0.84, s * 0.56)), col, false, w)
			draw_line(c + Vector2(0.0, s * 0.10), c + Vector2(0.0, s * 0.38), col, w, true)
			draw_line(c + Vector2(-s * 0.34, s * 0.46), c + Vector2(s * 0.34, s * 0.46), col, w, true)
			draw_arc(c + Vector2(-s * 0.42, -s * 0.24), s * 0.22, PI * 0.4, PI * 1.5, 10, col, w, true)
			draw_arc(c + Vector2(s * 0.42, -s * 0.24), s * 0.22, PI * 1.5, PI * 2.6, 10, col, w, true)
		_:
			draw_circle(c, s * 0.5, col, false, w)

## 设计稿开关：64x36 胶囊轨道 + 28 白色滑块（关闭=#EFECE7 轨道）
func _settings_switch(track: Rect2, on: bool) -> void:
	_fig_card(track, F_GREEN if on else Color("#EFECE7"), int(track.size.y * 0.5), false, false)
	var kx := track.end.x - track.size.y * 0.5 if on else track.position.x + track.size.y * 0.5
	draw_circle(Vector2(kx, track.position.y + track.size.y * 0.5), track.size.y * 0.5 - 4.0, Color.WHITE)

## 分段控件：浅底胶囊 + 内嵌选中绿块
func _settings_segmented(bg: Rect2, labels: Array, sel_idx: int, fs: int = 18) -> void:
	_fig_card(bg, F_CARD2, 16, false, false)
	var seg_w: float = (bg.size.x - 8.0 - 12.0) / float(labels.size())
	for i in labels.size():
		var r := Rect2(bg.position.x + 4.0 + float(i) * (seg_w + 4.0), bg.position.y + 4.0, seg_w, bg.size.y - 8.0)
		var on: bool = i == sel_idx
		if on: _fig_card(r, F_GREEN, 14, false, false)
		_fig_text(str(labels[i]), r.position.x, r.position.y + r.size.y * 0.5 + float(fs) * 0.36, fs,
			Color.WHITE if on else Color("#5C534E"), HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

## 滑条：0/当前/100 三个标签 + 轨道 + 白色滑块
func _settings_slider(track: Rect2, labels_y: float, value: int) -> void:
	var t: float = clampf(float(value) / 100.0, 0.0, 1.0)
	_fig_text("0", track.position.x - 2.0, labels_y, 16, F_SUB)
	_fig_text("100", track.end.x - 28.0, labels_y, 16, F_SUB)
	_fig_text(str(value), track.position.x, labels_y, 16, F_SUB, HORIZONTAL_ALIGNMENT_CENTER, track.size.x)
	_fig_card(track, Color("#EFECE7"), int(track.size.y * 0.5), false, false)
	if t > 0.002:
		_fig_card(Rect2(track.position.x, track.position.y, maxf(track.size.y, track.size.x * t), track.size.y),
			F_GREEN, int(track.size.y * 0.5), false, false)
	var kn := Vector2(track.position.x + track.size.x * t, track.position.y + track.size.y * 0.5)
	draw_circle(kn, 10.0, Color.WHITE)
	draw_arc(kn, 9.0, 0.0, TAU, 24, F_GREEN, 2.0, true)

func _settings_local_nick() -> String:
	var v = get("net_nickname")
	var s := "" if v == null else str(v)
	return s if s != "" else "玩家"

func _settings_local_avatar() -> int:
	var v = get("net_avatar")
	var a := 1 if v == null else int(v)
	return clampi(a, 1, 20)

func _settings_titles_collected() -> Array:
	var total := _titles_all_ids().size()
	var n := 0
	for id in _titles_all_ids():
		if TitleStoreRef.count(str(id)) > 0: n += 1
	return [n, total]

func _titles_all_ids() -> Array:
	if not _titles_ids_cache.is_empty(): return _titles_ids_cache
	for f in TitleDefsRef.FAMILIES:
		for lv in (f["levels"] as Array):
			_titles_ids_cache.append(str(lv.get("id", "")))
	for k in TitleDefsRef.UNIQUE_TITLES:
		_titles_ids_cache.append(str((TitleDefsRef.UNIQUE_TITLES[k] as Dictionary).get("id", "")))
	for k2 in TitleDefsRef.FINAL_TITLES:
		_titles_ids_cache.append(str((TitleDefsRef.FINAL_TITLES[k2] as Dictionary).get("id", "")))
	return _titles_ids_cache

var _titles_ids_cache: Array = []

func _draw_settings() -> void:
	_settings_load()
	var drawer := settings_drawer
	var panel := Rect2(120.0, 0.0, 600.0, size.y) if drawer else Rect2(0.0, 0.0, 720.0, size.y)
	if drawer:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
		draw_rect(panel, F_BG)
		draw_rect(Rect2(panel.position.x - 2.0, 0.0, 2.0, size.y), Color(0, 0, 0, 0.10))
	else:
		draw_rect(Rect2(Vector2.ZERO, size), F_BG)
	var geo := _settings_geo(panel)
	# 标题栏
	_fig_chevron(Vector2(geo["back"].position.x + 22.0, 60.0), F_INK, -1, 7.0)
	_fig_text("关于游戏" if settings_sub == "about" else "设置", float(geo["title_x"]), 69.0, 34, F_INK)
	if settings_sub == "about":
		_draw_settings_about(panel)
	else:
		_draw_settings_body(geo)
	if settings_confirm != "":
		_draw_settings_confirm()
	if settings_toast != "":
		_draw_global_toasts()

func _draw_settings_body(geo: Dictionary) -> void:
	var font := _fig_font()
	var prof: Rect2 = geo["profile"]
	_fig_card(prof)
	# 资料卡：头像 + 昵称 + 副题 + 称号图鉴入口（头像/昵称可点修改）
	var av_c: Vector2 = geo["avatar_c"]
	_fig_avatar(av_c, 28.0, 1, _settings_local_avatar(), false)
	# 相机徽标（提示“可修改头像”）
	var cam := av_c + Vector2(21.0, 21.0)
	draw_circle(cam, 12.0, F_CARD)
	draw_arc(cam, 11.0, 0.0, TAU, 24, F_LINE, 1.5, true)
	draw_rect(Rect2(cam + Vector2(-6.0, -3.5), Vector2(12.0, 8.5)), F_SUB, false, 1.6)
	draw_circle(cam + Vector2(0.0, 0.75), 2.0, F_SUB)
	var nick_x: float = prof.position.x + 24.0 + 56.0 + 12.0
	var nick_txt := _settings_local_nick()
	_fig_text(nick_txt, nick_x, prof.position.y + 50.0, 23, F_INK)
	# 铅笔（提示“可修改昵称”，本类内绘制避免引用子类函数）
	var nw: float = _fig_font().get_string_size(nick_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 23).x
	var pen_c := Vector2(nick_x + nw + 15.0, prof.position.y + 43.0)
	var pdir := Vector2(0.7071, -0.7071)      # 笔身朝右上
	var pnrm := Vector2(0.7071, 0.7071)
	var pbase := pen_c + pdir * -8.0
	var pw := 3.2
	var pp1 := pbase + pnrm * pw
	var pp2 := pbase - pnrm * pw
	var pp3 := pbase + pdir * 13.0 + pnrm * pw
	var pp4 := pbase + pdir * 13.0 - pnrm * pw
	draw_colored_polygon(PackedVector2Array([pp1, pp2, pp4, pp3]), F_SUB)
	draw_colored_polygon(PackedVector2Array([pp3, pp4, pbase + pdir * 19.0]), F_SUB)
	_fig_text("把快乐，留在桌面", nick_x, prof.position.y + 77.0, 16, F_SUB)
	var col_t := _settings_titles_collected()
	var right_x: float = prof.end.x - 44.0
	_fig_text("称号图鉴", right_x - 120.0, prof.position.y + 51.0, 20, F_GREEN,
		HORIZONTAL_ALIGNMENT_RIGHT, 120.0)
	_fig_chevron(Vector2(prof.end.x - 26.0, prof.position.y + 40.0), F_GREEN, 1, 6.0)
	_fig_text("已收集 %d / %d" % [int(col_t[0]), int(col_t[1])], right_x - 200.0,
		prof.position.y + 78.0, 16, F_SUB, HORIZONTAL_ALIGNMENT_RIGHT, 200.0)
	# 分组标题
	_fig_text("声音与体验", prof.position.x, geo["sec1_y"], 16, F_SUB)
	_fig_text("数据与关于", prof.position.x, geo["sec2_y"], 16, F_SUB)
	# 声音与体验卡
	var g1: Rect2 = geo["group1"]
	_fig_card(g1)
	var rows1: Array = geo["rows1"]
	var titles1 := ["音效", "音乐", "震动", "动画速度", "减少动态效果", "操作提示"]
	var subs1 := ["掷骰、移动等操作声音", "背景音乐音量 · 0–100", "调整操作反馈强度",
		"棋子移动与掷骰速度", "减少非必要的动态呈现", "显示掷骰与棋子选择提示"]
	for i in 6:
		var r: Rect2 = rows1[i]
		_fig_text(titles1[i], r.position.x + 24.0, r.position.y + 32.0, 22, F_INK)
		_fig_text(subs1[i], r.position.x + 24.0, r.position.y + 57.0, 16, F_SUB)
	var sw_w: float = geo["sw_w"]
	var sw_x: float = geo["sw_x"]
	_settings_switch(Rect2(sw_x, _settings_row_center(rows1[0]) - 18.0, sw_w, 36.0), settings_sound)
	_settings_slider(geo["music_track"], float(geo["music_labels_y"]), settings_music)
	_settings_segmented(geo["seg_vib"], SETTINGS_SEG_VIBRATE, settings_vibrate, 18)
	_settings_segmented(geo["seg_anim"], SETTINGS_SEG_ANIM, settings_anim, 18)
	_settings_switch(Rect2(sw_x, _settings_row_center(rows1[4]) - 18.0, sw_w, 36.0), settings_reduce_motion)
	_settings_switch(Rect2(sw_x, _settings_row_center(rows1[5]) - 18.0, sw_w, 36.0), settings_hints)
	# 数据与关于卡
	var g2: Rect2 = geo["group2"]
	_fig_card(g2)
	var rows2: Array = geo["rows2"]
	# 清理缓存
	var r0: Rect2 = rows2[0]
	var cache_sub := "当前占用 0 MB" if settings_cache_mb <= 0.01 else "当前占用 %.1f MB · 不影响设置" % settings_cache_mb
	_fig_text("清理缓存", r0.position.x + 24.0, r0.position.y + 32.0, 22, F_INK)
	_fig_text(cache_sub, r0.position.x + 24.0, r0.position.y + 57.0, 16, F_SUB)
	_fig_chevron(Vector2(r0.end.x - 34.0, r0.position.y + 36.0), F_MUTED, 1, 6.0)
	# 隐私与许可
	var r1: Rect2 = rows2[1]
	_fig_text("隐私与许可", r1.position.x + 24.0, r1.position.y + 32.0, 22, F_INK)
	_fig_text("查看关于游戏与素材许可说明", r1.position.x + 24.0, r1.position.y + 57.0, 16, F_SUB)
	_fig_chevron(Vector2(r1.end.x - 34.0, r1.position.y + 36.0), F_MUTED, 1, 6.0)
	# 版本号
	var r2b: Rect2 = rows2[2]
	_fig_text("版本号", r2b.position.x + 24.0, r2b.position.y + 32.0, 22, F_INK)
	_fig_text("当前安装版本", r2b.position.x + 24.0, r2b.position.y + 57.0, 16, F_SUB)
	_fig_text("v1.0", r2b.end.x - 24.0 - 120.0, r2b.position.y + 40.0, 20, F_SUB,
		HORIZONTAL_ALIGNMENT_RIGHT, 120.0)
	# 恢复默认（危险操作）
	var r3: Rect2 = rows2[3]
	_fig_text("恢复默认", r3.position.x + 24.0, r3.position.y + 32.0, 22, Color("#C0453C"))
	_fig_text("将声音与体验设置恢复为默认值", r3.position.x + 24.0, r3.position.y + 57.0, 16, F_SUB)
	_draw_batch2_icon("reset", Vector2(r3.end.x - 34.0, r3.position.y + 36.0), 11.0, F_MUTED)
	# 页脚版本
	_fig_text("极简飞行棋 · v1.0", geo["panel"].position.x, float(geo["footer_y"]), 16, F_SUB,
		HORIZONTAL_ALIGNMENT_CENTER, geo["panel"].size.x)

## 设置页：关于游戏子页（01e）
func _draw_settings_about(panel: Rect2) -> void:
	var font := _fig_font()
	var mx := 24.0 if panel.position.x > 1.0 else 40.0
	var x := panel.position.x + mx
	var w: float = panel.size.x - mx * 2.0
	# 卡 1：品牌
	var c1 := Rect2(x, 152.0, w, 208.0)
	_fig_card(c1)
	var dot_x: float = c1.position.x + 24.0
	var dot_cols := [Color("#F0A3A3"), Color("#8FD0A0"), Color("#9CC3E8"), Color("#F3B98C")]
	for c in dot_cols:
		_fig_card(Rect2(dot_x, c1.position.y + 24.0, 24.0, 24.0), c, 8, false, false)
		dot_x += 34.0
	_fig_text("极简飞行棋", c1.position.x + 24.0, c1.position.y + 90.0, 30, F_INK)
	_fig_text("不用赶路，掷出一点好时光。", c1.position.x + 24.0, c1.position.y + 135.0, 21, F_SUB)
	_fig_text("版本 v1.0", c1.position.x + 24.0, c1.position.y + 179.0, 16, F_SUB)
	# 卡 2：玩法简介
	var c2 := Rect2(x, 385.0, w, 168.0)
	_fig_card(c2)
	_fig_text("玩法简介", c2.position.x + 24.0, c2.position.y + 50.0, 24, F_INK)
	_fig_text("在同一张棋盘上，轮流掷骰、移动棋子，享受轻松的桌游时光。",
		c2.position.x + 24.0, c2.position.y + 96.0, 21, F_INK)
	_fig_text("具体玩法请查看「游戏规则」。", c2.position.x + 24.0, c2.position.y + 139.0, 16, F_SUB)
	# 卡 3：隐私与素材许可
	var c3 := Rect2(x, 578.0, w, 176.0)
	_fig_card(c3)
	_fig_text("隐私与素材许可", c3.position.x + 24.0, c3.position.y + 50.0, 24, F_INK)
	_fig_text("棋盘、棋子与表情头像沿用原有素材。", c3.position.x + 24.0, c3.position.y + 96.0, 21, F_INK)
	_fig_text("素材许可需以原仓库许可核对。本页不预设或声明 MIT 等许可。",
		c3.position.x + 24.0, c3.position.y + 145.0, 16, F_SUB)
	# 页脚
	_fig_text("纯粹的棋盘时光 · v1.0", panel.position.x, panel.position.y + panel.size.y - 63.0, 16, F_SUB,
		HORIZONTAL_ALIGNMENT_CENTER, panel.size.x)

## 二次确认弹窗（01b / 01c）
func _draw_settings_confirm() -> void:
	var cg := _settings_confirm_geo()
	var card: Rect2 = cg["card"]
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	_fig_card(card, F_CARD, 24)
	var restore: bool = settings_confirm == "restore"
	_fig_text("恢复默认设置?" if restore else "清理缓存?", card.position.x + 32.0, card.position.y + 70.0, 30, F_INK)
	_draw_batch2_icon("close", Vector2(cg["close"].position.x + 24.0, cg["close"].position.y + 24.0), 11.0, F_SUB)
	if restore:
		_fig_text("声音与体验设置将恢复为默认值，当前调整将被覆盖。", card.position.x + 32.0,
			card.position.y + 127.0, 21, F_INK)
		_fig_text("音效开 · 音乐70 · 震动中 · 动画1x · 减少动态效果关 · 操作提示开",
			card.position.x + 32.0, card.position.y + 174.0, 16, F_SUB)
	else:
		_fig_text("将清理 %.1f MB 临时缓存。不会改变当前设置。" % maxf(settings_cache_mb, 0.0),
			card.position.x + 32.0, card.position.y + 127.0, 21, F_INK)
		_fig_text("清理后，下次使用时将重新加载所需内容。", card.position.x + 32.0,
			card.position.y + 174.0, 16, F_SUB)
	# 取消（白底描边）+ 危险确认（红底）
	var cancel_r: Rect2 = cg["cancel"]
	_fig_card(cancel_r, F_CARD, 16, true, false)
	_fig_text("取消", cancel_r.position.x, cancel_r.position.y + cancel_r.size.y * 0.5 + 9.0, 24,
		F_INK, HORIZONTAL_ALIGNMENT_CENTER, cancel_r.size.x)
	var ok_r: Rect2 = cg["ok"]
	_fig_card(ok_r, Color("#C0453C"), 16, false, false)
	_fig_text("恢复默认" if restore else "确认清理", ok_r.position.x, ok_r.position.y + ok_r.size.y * 0.5 + 9.0,
		24, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, ok_r.size.x)

## 全局 toast（设置清理成功 01d 在底部 / 称号获得 03e 在顶部）
func _draw_global_toasts() -> void:
	var now := Time.get_ticks_msec()
	if titles_toast != "" and now - titles_toast_ms < 2800:
		_draw_batch2_toast(titles_toast, titles_toast_sub, 80.0,
			1.0 - clampf(float(now - titles_toast_ms) / 2800.0, 0.0, 1.0))
	if settings_toast != "" and now - settings_toast_ms < 2800:
		if settings_open:
			_draw_batch2_toast(settings_toast, settings_toast_sub, _bottom_y(180.0),
				1.0 - clampf(float(now - settings_toast_ms) / 2800.0, 0.0, 1.0))

func _draw_batch2_toast(title: String, sub: String, y: float, fade: float) -> void:
	# fade = 剩余时间比例（1=刚出现，0=即将消失）
	var a: float = clampf(fade * 4.0, 0.0, 1.0)
	var r := Rect2(56.0, y, 608.0, 100.0)
	draw_style_box(_sb(Color(1, 1, 1, 0.98 * a), 20, 1, Color(0.88, 0.86, 0.83, a),
		_fig_shadow(), 12), r)
	_draw_batch2_icon("info", Vector2(r.position.x + 30.0, r.position.y + 50.0), 11.0,
		Color(F_GREEN.r, F_GREEN.g, F_GREEN.b, a))
	_fig_text(title, r.position.x + 54.0, r.position.y + 48.0, 22, Color(F_INK.r, F_INK.g, F_INK.b, a))
	_fig_text(sub, r.position.x + 54.0, r.position.y + 76.0, 16, Color(F_SUB.r, F_SUB.g, F_SUB.b, a))
# ---------------------------------------------------------------- 称号图鉴（03 / 03a / 03b / 03c / 03d / 03e）
const TITLES_FILTERS := [["mythic", "神话"], ["legendary", "传说"], ["epic", "史诗"],
	["rare", "稀有"], ["common", "普通"]]
## 第二批设计稿的稀有度配色（与结算页 TitlesViewRef 的旧配色不同）
const TITLES_TIER := {
	"mythic": {"fg": "#E0B25A", "bg": "#FBF3E1", "bd": "#E0B25A"},
	"legendary": {"fg": "#A78BFA", "bg": "#F1ECFE", "bd": "#A78BFA"},
	"epic": {"fg": "#4777C5", "bg": "#E8EFF9", "bd": "#4777C5"},
	"rare": {"fg": "#2F7D4F", "bg": "#EBF4ED", "bd": "#2F7D4F"},
	"common": {"fg": "#8B98AD", "bg": "#F0EFED", "bd": "#C9C5C0"},
}
var titles_filter := ""            # "" = 全部；否则只显示该稀有度“已获得”
var title_detail_id := ""
var titles_toast := ""
var titles_toast_sub := ""
var titles_toast_tier := "common"
var titles_toast_ms := 0
var titles_new_id := ""
var _title_pending_id := ""
var _title_pending_scroll := 0.0
var _title_press_pos := Vector2.ZERO
var _titles_laid: Array = []
var _titles_laid_total := 0.0
var _titles_laid_sig := ""

func show_title_toast(name: String, desc: String, tier: String = "common") -> void:
	titles_toast = "新称号 · %s" % name
	titles_toast_sub = "%s · 已加入称号图鉴" % desc
	titles_toast_tier = tier
	titles_toast_ms = Time.get_ticks_msec()
	titles_new_id = ""
	queue_redraw()


func _titles_filter_chip(tier: String) -> Rect2:
	for i in TITLES_FILTERS.size():
		if str(TITLES_FILTERS[i][0]) == tier:
			return Rect2(40.0 + float(i) * 130.0, 259.0, 120.0, 52.0)
	return Rect2()

func _titles_card_rect(x: float, y: float) -> Rect2:
	return Rect2(x, y, 304.0, 208.0)

## 家族聚合卡片：1 张卡代表 1 个家族。分组按数据语义：
##   进阶 = 多级且无模式限制的 FAMILIES；特殊 = 单级 / 仅欢乐 / 仅道具 / 欢乐中禁用；
##   隐藏 = UNIQUE_TITLES + FINAL_TITLES（整局结算型）。
func _titles_entries() -> Dictionary:
	var adv: Array = []
	var special: Array = []
	var order_i := 0
	for f in TitleDefsRef.FAMILIES:
		var levels: Array = f["levels"]
		var owned_n := 0
		var best_i := 0
		for i in levels.size():
			if TitleStoreRef.count(str((levels[i] as Dictionary).get("id", ""))) > 0:
				owned_n += 1
				best_i = i
		var best: Dictionary = levels[best_i]
		var owned_any: bool = owned_n > 0
		var all_owned: bool = owned_n == levels.size()
		var next_i: int = best_i + 1 if owned_any else 0
		if next_i >= levels.size(): next_i = levels.size() - 1
		var next_lv: Dictionary = levels[next_i]
		var focus: Dictionary = best if owned_any else (levels[0] as Dictionary)
		var detail_id := str(focus.get("id", ""))
		if owned_any and not all_owned:
			detail_id = str((levels[best_i + 1] as Dictionary).get("id", detail_id))
		var card := {
			"kind": "family", "family": str(f.get("key", "")), "icon": str(f.get("key", "")),
			"id": detail_id, "name": str(focus.get("name", "")), "desc": str(focus.get("desc", "")),
			"tier": str(focus.get("tier", "common")),
			"levels": levels, "n_levels": levels.size(), "n_owned": owned_n,
			"owned": owned_any, "all_owned": all_owned,
			"count": TitleStoreRef.count(str(focus.get("id", ""))),
			"next": (levels[best_i + 1] as Dictionary) if (owned_any and best_i + 1 < levels.size()) else {},
			"focus": focus,
		}
		# 语义分组：多级且无模式限制 -> 进阶；其余（单级/仅欢乐/仅道具/欢乐禁用）-> 特殊
		var flags: Array = []
		for fk in ["happy_only", "item_only", "happy_disabled"]:
			if bool(f.get(fk, false)): flags.append(fk)
		if levels.size() > 1 and flags.is_empty():
			adv.append(card)
		else:
			var prank := 3
			if flags.has("item_only"): prank = 0
			elif flags.has("happy_only"): prank = 1
			elif flags.has("happy_disabled"): prank = 2
			card["special_rank"] = prank
			card["special_tier"] = TitleDefsRef.tier_rank(str(focus.get("tier", "common")))
			card["order"] = order_i
			special.append(card)
		order_i += 1
	# 特殊组排序：仅道具（锦鲤附体类）> 仅欢乐 > 欢乐禁用 > 单级；同权重内弱的排前
	special.sort_custom(func(a, b):
		if int(a["special_rank"]) != int(b["special_rank"]):
			return int(a["special_rank"]) < int(b["special_rank"])
		if int(a["special_tier"]) != int(b["special_tier"]):
			return int(a["special_tier"]) > int(b["special_tier"])
		return int(a["order"]) < int(b["order"]))
	var hidden: Array = []
	for k in TitleDefsRef.UNIQUE_TITLES.keys():
		var t: Dictionary = TitleDefsRef.UNIQUE_TITLES[k]
		hidden.append(_titles_solo_card(t, "unique"))
	for k2 in TitleDefsRef.FINAL_TITLES.keys():
		var t2: Dictionary = TitleDefsRef.FINAL_TITLES[k2]
		hidden.append(_titles_solo_card(t2, "final"))
	return {"adv": adv, "special": special, "hidden": hidden}

func _titles_solo_card(t: Dictionary, icon: String) -> Dictionary:
	var id := str(t.get("id", ""))
	var n := TitleStoreRef.count(id)
	return {"kind": "solo", "family": "", "icon": icon, "id": id,
		"name": str(t.get("name", "")), "desc": str(t.get("desc", "")),
		"tier": str(t.get("tier", "common")), "levels": [t], "n_levels": 1,
		"n_owned": 1 if n > 0 else 0, "owned": n > 0, "all_owned": n > 0,
		"count": n, "next": {}, "focus": t}

func _titles_items_of_group(group: Array) -> Array:
	return group

func _titles_collected_n() -> int:
	var n := 0
	for id in _titles_all_ids():
		if TitleStoreRef.count(str(id)) > 0: n += 1
	return n


## 排版：分组标题 + 2 列卡片（304x208，gap16）；返回 [items, total]
## 排版：首屏按设计稿 [进阶2卡][特殊2卡][隐藏2卡]，其余卡片按组续排（滚动）
func _titles_laid_build() -> Array:
	var counts_sum := 0
	for id in _titles_all_ids():
		counts_sum += TitleStoreRef.count(str(id))
	var sig := "%d|%s|%d" % [int(titles_content_rect().size.x), titles_filter, counts_sum]
	if _titles_laid_sig == sig and not _titles_laid.is_empty():
		return [_titles_laid, _titles_laid_total]
	_titles_laid_sig = sig
	var grouped: Dictionary = _titles_entries()
	var adv: Array = grouped["adv"]
	var special: Array = grouped["special"]
	var hidden: Array = grouped["hidden"]
	var laid: Array = []
	var y := 0.0
	# 空筛选态
	if titles_filter != "":
		var fl: Array = []
		for grp in [adv, special, hidden]:
			for it in grp:
				if str(it.tier) == titles_filter and bool(it.owned): fl.append(it)
		if fl.is_empty():
			_titles_laid = []
			_titles_laid_total = 0.0
			return [laid, 0.0]
		laid.append({"kind": "head", "y": y + 36.0,
			"text": "%s · 已获得 %d 个" % [_titles_tier_name(titles_filter), fl.size()]})
		_titles_place_cards(laid, fl, y + 52.0)
		var rows_f: int = (fl.size() + 1) / 2
		_titles_laid_total = y + 52.0 + float(rows_f) * 224.0 - 16.0 + 14.0
		_titles_laid = laid
		return [laid, _titles_laid_total]
	# 首屏：3 组各 2 张
	var groups := [["进阶称号", adv], ["特殊称号", special], ["隐藏称号", hidden]]
	for grp in groups:
		var list: Array = grp[1]
		if list.is_empty(): continue
		laid.append({"kind": "head", "y": y + 36.0, "text": str(grp[0])})
		_titles_place_cards(laid, list.slice(0, 2), y + 52.0)
		var rows_n: int = (mini(list.size(), 2) + 1) / 2
		y += 52.0 + float(rows_n) * 224.0 - 16.0 + 14.0
	# 其余卡片：按组续排
	for grp2 in groups:
		var rest: Array = (grp2[1] as Array).slice(2)
		if rest.is_empty(): continue
		laid.append({"kind": "head", "y": y + 36.0, "text": "%s · 更多" % str(grp2[0])})
		_titles_place_cards(laid, rest, y + 52.0)
		var rows2: int = (rest.size() + 1) / 2
		y += 52.0 + float(rows2) * 224.0 - 16.0 + 14.0
	_titles_laid = laid
	_titles_laid_total = maxf(0.0, y)
	return [laid, _titles_laid_total]

func _titles_place_cards(laid: Array, list: Array, y0: float) -> void:
	for i in list.size():
		var col := i % 2
		var row := i / 2
		var rect := _titles_card_rect(40.0 + float(col) * 320.0, titles_content_rect().position.y + y0 + float(row) * 224.0)
		laid.append({"kind": "card", "rect": rect, "item": list[i]})

func _titles_tier_name(tier: String) -> String:
	return TitleDefsRef.tier_name(tier)


func _draw_title_icon(kind: String, c: Vector2, s: float, col: Color) -> void:
	var w := 2.0
	match kind:
		"ones":
			draw_arc(c + Vector2(0.0, -s * 0.12), s * 0.62, PI, TAU, 16, col, w, true)
			draw_line(c + Vector2(-s * 0.68, s * 0.10), c + Vector2(s * 0.68, s * 0.10), col, w, true)
			for i in 3:
				var dx := (float(i) - 1.0) * s * 0.42
				draw_line(c + Vector2(dx, s * 0.34), c + Vector2(dx - s * 0.10, s * 0.66), col, w, true)
		"no_takeoff":
			draw_circle(c, s * 0.66, col, false, w)
			draw_line(c, c + Vector2(0.0, -s * 0.40), col, w, true)
			draw_line(c, c + Vector2(s * 0.32, 0.0), col, w, true)
		"sixes":
			draw_polyline(PackedVector2Array([c + Vector2(-s * 0.62, s * 0.30), c + Vector2(-s * 0.62, -s * 0.30),
				c + Vector2(s * 0.62, -s * 0.30), c + Vector2(s * 0.62, s * 0.30), c + Vector2(-s * 0.62, s * 0.30)]),
				col, w, true)
			draw_circle(c + Vector2(-s * 0.30, -s * 0.02), s * 0.10, col)
			draw_circle(c + Vector2(s * 0.30, -s * 0.02), s * 0.10, col)
		"move_distance":
			draw_polyline(PackedVector2Array([c + Vector2(-s * 0.50, s * 0.52), c + Vector2(-s * 0.20, s * 0.10),
				c + Vector2(s * 0.10, s * 0.30), c + Vector2(s * 0.52, -s * 0.52)]), col, w, true)
			draw_circle(c + Vector2(s * 0.52, -s * 0.52), s * 0.16, col)
		"bounce":
			draw_line(c + Vector2(-s * 0.60, s * 0.40), c + Vector2(s * 0.10, s * 0.40), col, w, true)
			draw_line(c + Vector2(s * 0.10, s * 0.40), c + Vector2(s * 0.52, -s * 0.40), col, w, true)
			draw_line(c + Vector2(s * 0.10, s * 0.40), c + Vector2(-s * 0.20, -s * 0.40), col, w, true)
		"multi_kill", "first_blood":
			draw_line(c + Vector2(-s * 0.52, -s * 0.52), c + Vector2(s * 0.52, s * 0.52), col, w, true)
			draw_line(c + Vector2(s * 0.52, -s * 0.52), c + Vector2(-s * 0.52, s * 0.52), col, w, true)
		"collide_move":
			draw_circle(c + Vector2(-s * 0.34, 0.0), s * 0.30, col, false, w)
			draw_circle(c + Vector2(s * 0.34, 0.0), s * 0.30, col, false, w)
		"teleport", "petty_teleport":
			draw_arc(c, s * 0.62, 0.0, TAU, 22, col, w, true)
			draw_arc(c, s * 0.34, 0.0, TAU, 18, col, w, true)
			draw_circle(c, s * 0.10, col)
		"mystery_box", "box_zero":
			draw_rect(Rect2(c + Vector2(-s * 0.52, -s * 0.42), Vector2(s * 1.04, s * 0.84)), col, false, w)
			draw_line(c + Vector2(-s * 0.52, -s * 0.10), c + Vector2(s * 0.52, -s * 0.10), col, w, true)
			draw_line(c, c + Vector2(0.0, -s * 0.10), col, w, true)
		"skill_count":
			draw_rect(Rect2(c + Vector2(-s * 0.44, -s * 0.20), Vector2(s * 0.88, s * 0.66)), col, false, w)
			draw_arc(c + Vector2(0.0, -s * 0.20), s * 0.26, PI, TAU, 12, col, w, true)
		"block":
			draw_polyline(PackedVector2Array([c + Vector2(-s * 0.50, -s * 0.52), c + Vector2(s * 0.50, -s * 0.52),
				c + Vector2(s * 0.50, s * 0.10), c + Vector2(0.0, s * 0.56), c + Vector2(-s * 0.50, s * 0.10),
				c + Vector2(-s * 0.50, -s * 0.52)]), col, w, true)
		"poly_high", "poly_low":
			draw_rect(Rect2(c + Vector2(-s * 0.44, -s * 0.44), Vector2(s * 0.88, s * 0.88)), col, false, w)
			draw_circle(c, s * 0.10, col)
		"first_finish", "runway_kill":
			draw_line(c + Vector2(-s * 0.40, s * 0.52), c + Vector2(-s * 0.40, -s * 0.52), col, w, true)
			draw_polyline(PackedVector2Array([c + Vector2(-s * 0.40, -s * 0.52), c + Vector2(s * 0.52, -s * 0.16),
				c + Vector2(-s * 0.40, s * 0.18)]), col, w, true)
		"airport_rekt":
			draw_polyline(PackedVector2Array([c + Vector2(-s * 0.52, -s * 0.10), c + Vector2(s * 0.52, -s * 0.10),
				c + Vector2(s * 0.10, s * 0.52), c + Vector2(-s * 0.52, -s * 0.10)]), col, w, true)
		"oriole_kill":
			draw_arc(c, s * 0.58, 0.0, TAU, 22, col, w, true)
			draw_circle(c, s * 0.16, col)
		"revenge_kill":
			draw_line(c + Vector2(-s * 0.52, 0.0), c + Vector2(s * 0.52, 0.0), col, w, true)
			draw_polyline(PackedVector2Array([c + Vector2(s * 0.26, -s * 0.26), c + Vector2(s * 0.52, 0.0),
				c + Vector2(s * 0.26, s * 0.26)]), col, w, true)
		"unique":
			draw_polyline(PackedVector2Array([c + Vector2(0.0, -s * 0.56), c + Vector2(s * 0.16, -s * 0.18),
				c + Vector2(s * 0.56, -s * 0.16), c + Vector2(s * 0.24, s * 0.10), c + Vector2(s * 0.34, s * 0.52),
				c + Vector2(0.0, s * 0.28), c + Vector2(-s * 0.34, s * 0.52), c + Vector2(-s * 0.24, s * 0.10),
				c + Vector2(-s * 0.56, -s * 0.16), c + Vector2(-s * 0.16, -s * 0.18), c + Vector2(0.0, -s * 0.56)]),
				col, w, true)
		_:
			draw_circle(c, s * 0.52, col, false, w)
			draw_circle(c, s * 0.10, col)

func _titles_tier_col(tier: String) -> Color:
	return Color(str((TITLES_TIER.get(tier, TITLES_TIER["common"]) as Dictionary)["fg"]))

func _titles_tier_bg(tier: String) -> Color:
	return Color(str((TITLES_TIER.get(tier, TITLES_TIER["common"]) as Dictionary)["bg"]))

func _draw_title_tier_chip(r: Rect2, tier: String) -> void:
	var st: Dictionary = TITLES_TIER.get(tier, TITLES_TIER["common"])
	draw_style_box(_sb(Color(str(st.bg)), int(r.size.y * 0.5), 1, Color(str(st.bd))), r)
	_fig_text(TitleDefsRef.tier_name(tier), r.position.x, r.position.y + r.size.y * 0.72, 13,
		Color(str(st.fg)), HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

func _draw_title_card(item: Dictionary, rect: Rect2) -> void:
	var owned: bool = bool(item.get("owned", false))
	var all_owned: bool = bool(item.get("all_owned", owned))
	var n_owned := int(item.get("n_owned", 1 if owned else 0))
	var n_levels := int(item.get("n_levels", 1))
	var tier := str(item.get("tier", "common"))
	var tcol: Color = _titles_tier_col(tier)
	var is_new: bool = owned and str(item.get("id", "")) == titles_new_id
	var bg: Color = Color("#F4FAF5") if is_new else F_CARD
	_fig_card(rect, bg, 20, true, true)
	if is_new:
		draw_style_box(_sb(Color(0, 0, 0, 0), 20, 2, F_GREEN), rect)
	# 图标块
	var ib := Rect2(rect.position.x + 16.0, rect.position.y + 15.0, 42.0, 42.0)
	_fig_card(ib, F_CARD2, 12, false, false)
	_draw_title_icon(str(item.get("icon", "")), ib.position + ib.size * 0.5, 13.0,
		tcol if owned else F_MUTED)
	# 名称（设计稿：标题一律墨色）+ 稀有度
	_fig_text(str(item.get("name", "")), rect.position.x + 70.0, rect.position.y + 45.0, 22, F_INK)
	_draw_title_tier_chip(Rect2(rect.end.x - 60.0, rect.position.y + 24.0, 44.0, 23.0), tier)
	# 条件
	_fig_text(str(item.get("desc", "")), rect.position.x + 16.0, rect.position.y + 88.0, 16, F_INK)
	# 进度条：家族卡按已达成档位占比
	var frac: float = clampf(float(n_owned) / float(maxi(n_levels, 1)), 0.0, 1.0)
	var bar := Rect2(rect.position.x + 16.0, rect.position.y + 103.0, rect.size.x - 32.0, 6.0)
	_fig_card(bar, Color("#EFECE7"), 3, false, false)
	if frac > 0.002:
		_fig_card(Rect2(bar.position.x, bar.position.y, bar.size.x * frac, bar.size.y), tcol, 3, false, false)
	# 状态行
	var st_y := rect.position.y + 137.0
	var left_txt := "未达成"
	if n_levels > 1:
		left_txt = "%d / %d 阶" % [n_owned, n_levels]
	elif owned:
		left_txt = "已达成 · ×%d" % int(item.get("count", 0))
	_fig_text(left_txt, rect.position.x + 16.0, st_y, 16,
		F_SUB if not owned else Color("#5D554D"))
	if owned:
		var right_txt := "已集齐" if (all_owned and n_levels > 1) else "已获得"
		if is_new: right_txt = "新获得"
		_fig_text(right_txt, rect.end.x - 92.0, st_y, 16, F_GREEN,
			HORIZONTAL_ALIGNMENT_RIGHT, 60.0)
		_draw_batch2_icon("check", Vector2(rect.end.x - 100.0, st_y - 6.0), 8.0, F_GREEN)
	else:
		_fig_text("锁定", rect.end.x - 92.0, st_y, 16, F_SUB, HORIZONTAL_ALIGNMENT_RIGHT, 44.0)
		_draw_batch2_icon("lock", Vector2(rect.end.x - 100.0, st_y - 6.0), 8.0, F_SUB)
func _draw_title_detail(tid: String) -> void:
	var item: Dictionary = TitleDefsRef.level_by_id(tid)
	if item.is_empty(): return
	var owned := TitleStoreRef.count(tid) > 0
	var tier := str(item.get("tier", "common"))
	var tcol: Color = _titles_tier_col(tier)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	var card := Rect2(40.0, _center_card_y(682.0), 640.0, 682.0)
	_fig_card(card, F_CARD, 24)
	_fig_text("称号详情", card.position.x + 32.0, card.position.y + 70.0, 30, F_INK)
	_draw_batch2_icon("close", Vector2(640.0, card.position.y + 62.0), 11.0, F_SUB)
	# 大图标块
	var ib := Rect2(304.0, card.position.y + 100.0, 112.0, 112.0)
	_fig_card(ib, F_GREEN_TINT if owned else Color("#EFECE7"), 24, false, false)
	_draw_title_icon(_titles_icon_of(tid, item), ib.position + ib.size * 0.5, 30.0, tcol if owned else F_SUB)
	# 名称 + 稀有度
	var nm := str(item.get("name", ""))
	var nw: float = _fig_font().get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 28).x
	var name_col: Color = F_GREEN if owned else F_SUB
	_fig_text(nm, card.position.x, card.position.y + 269.0, 28, name_col, HORIZONTAL_ALIGNMENT_CENTER, card.size.x)
	_draw_title_tier_chip(Rect2(360.0 - 22.0, card.position.y + 293.0, 44.0, 23.0), tier)
	# 达成条件
	_fig_text("达成条件", card.position.x + 32.0, card.position.y + 362.0, 22, F_INK)
	_fig_text(str(item.get("desc", "")), card.position.x + 32.0, card.position.y + 411.0, 19, F_INK)
	# 进度信息块
	_fig_card(Rect2(72.0, card.position.y + 439.0, 576.0, 116.0), F_CARD2, 16, false, false)
	if owned:
		var cn := TitleStoreRef.count(tid)
		_fig_text("已达成 · ×%d 次获得" % cn, 104.0, card.position.y + 489.0, 22, F_INK)
		_fig_text("达成日期：已收录在称号图鉴中", 104.0, card.position.y + 525.0, 16, F_SUB)
	else:
		_fig_text("尚未达成", 104.0, card.position.y + 489.0, 22, F_INK)
		_fig_text("继续你的旅程，达成后即可获得此称号。", 104.0, card.position.y + 525.0, 16, F_SUB)
	# 关闭按钮
	var btn := Rect2(72.0, card.position.y + 578.0, 576.0, 72.0)
	_fig_card(btn, F_GREEN, 16, false, false)
	_fig_text("关闭", btn.position.x, btn.position.y + btn.size.y * 0.5 + 9.0, 24, Color.WHITE,
		HORIZONTAL_ALIGNMENT_CENTER, btn.size.x)

func _titles_icon_of(tid: String, _item: Dictionary) -> String:
	for f in TitleDefsRef.FAMILIES:
		for lv in (f["levels"] as Array):
			if str(lv.get("id", "")) == tid: return str(f.get("key", ""))
	for k in TitleDefsRef.UNIQUE_TITLES:
		if str((TitleDefsRef.UNIQUE_TITLES[k] as Dictionary).get("id", "")) == tid: return "unique"
	for k2 in TitleDefsRef.FINAL_TITLES:
		if str((TitleDefsRef.FINAL_TITLES[k2] as Dictionary).get("id", "")) == tid: return "final"
	return "unique"

# ---------------------------------------------------------------- 游戏规则（04 / 04a）
## 规则目录（语义 12 项；每一项跳到 rules.json 里对应的 h4/h5 标题位置）
const RULE_NAV_DEFS := [
	["win", "胜利条件", "胜利条件"],
	["core", "核心机制", "核心机制"],
	["takeoff", "起飞", "起飞"],
	["move", "移动", "移动"],
	["bonus", "连投奖励", "连投奖励"],
	["jump", "跳跃", "跳子"],
	["fly", "飞棋", "飞棋"],
	["stack", "叠子", "叠子"],
	["crash", "撞机", "撞机"],
	["finish", "到达终点", "到达终点"],
	["item", "道具", "道具模式"],
	["happy", "欢乐模式", "欢乐模式"],
]

var _rules_stream: Array = []
var _rules_loaded := false
var _rules_active_key := "win"
var _rules_scroll_target := 0.0
var _rules_was_open := false

func _rules_strip(txt: String) -> String:
	var t := txt.replace("
", "").replace("
", "")
	t = t.replace(" ", "").replace("　", "")
	t = t.replace("[", "").replace("]", "")
	return t.strip_edges()

func _rules_load_stream() -> void:
	if _rules_loaded: return
	_rules_loaded = true
	if not FileAccess.file_exists("res://data/rules.json"): return
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/rules.json"))
	if not (j is Array): return
	for it in (j as Array):
		var k := str(it.get("k", "p"))
		var txt := ""
		for run in (it.get("runs", []) as Array):
			txt += str((run as Array)[0])
		txt = _rules_strip(txt)
		if txt == "": continue
		_rules_stream.append({"kind": k, "text": txt})

func _rules_heading_short(txt: String) -> String:
	var t := txt
	for pre in ["一、", "二、", "三、", "四、", "五、", "六、", "1、", "2、", "3、", "4、"]:
		if t.begins_with(pre):
			t = t.substr(pre.length())
			break
	return t

func _rules_register_nav(txt: String, y: float) -> void:
	for d in RULE_NAV_DEFS:
		var key := str(d[0])
		if _rules_section_y.has(key): continue
		if txt.contains(str(d[2])):
			_rules_section_y[key] = maxf(0.0, y - 30.0)
			return

var _rules_laid: Array = []
var _rules_laid_total := 0.0
var _rules_section_y := {}
var _rules_cache_w := -1.0
var _rules_nav_key := ""


func _rules_nav_rect(i: int) -> Rect2:
	var n: int = RULE_NAV_DEFS.size()
	var p := rules_panel()
	var top := 306.0
	var bottom: float = p.end.y - 170.0
	var spacing: float = minf(64.0, (bottom - top) / float(maxi(n, 1)))
	var h: float = minf(56.0, spacing - 6.0)
	return Rect2(72.0, top + float(i) * spacing, 144.0, h)

func _rules_bottom_btn() -> Rect2:
	var p := rules_panel()
	return Rect2(72.0, p.end.y - 124.0, 576.0, 72.0)

func _rules_laid_build() -> void:
	_rules_load_stream()
	var c := rules_content_rect()
	# 排版只与内容宽度有关：按宽度缓存，滚动/高亮/点击不再每帧重排（修卡顿）
	if not _rules_laid.is_empty() and absf(c.size.x - _rules_cache_w) < 0.5:
		return
	_rules_cache_w = c.size.x
	var font := _fig_font()
	_rules_laid = []
	_rules_section_y = {}
	var y := 30.0
	var prev_kind := ""
	for blk in _rules_stream:
		var kind := str(blk.get("kind", "p"))
		var text := str(blk.get("text", ""))
		if kind == "h4":
			if prev_kind == "p" or prev_kind == "h5": y += 20.0
			var disp := _rules_heading_short(text)
			_rules_laid.append({"kind": "h4", "y": y, "text": disp})
			_rules_register_nav(text, y)
			y += 48.0
		elif kind == "h5":
			if prev_kind == "p": y += 12.0
			elif prev_kind == "h5": y += 4.0
			_rules_laid.append({"kind": "h5", "y": y, "text": text})
			_rules_register_nav(text, y)
			y += 40.0
		else:
			if prev_kind == "": y += 6.0
			var lines := _titles_wrap(font, text, 17, c.size.x - 4.0)
			for ln in lines:
				_rules_laid.append({"kind": "p", "y": y, "text": str(ln)})
				y += 30.0
			y += 6.0
		prev_kind = kind
	_rules_laid_total = y + 10.0
	if _rules_active_key == "":
		_rules_active_key = "win"

func _rules_current_key() -> String:
	var top := -rules_scroll + 8.0
	var cur := "win"
	for d in RULE_NAV_DEFS:
		var key := str(d[0])
		if float(_rules_section_y.get(key, 0.0)) <= top: cur = key
	return cur

func _rules_section_name(key: String) -> String:
	for d in RULE_NAV_DEFS:
		if str(d[0]) == key: return str(d[1])
	return ""

func _rules_nav_context(key: String) -> String:
	var idx := 0
	for i in RULE_NAV_DEFS.size():
		if str(RULE_NAV_DEFS[i][0]) == key: idx = i
	var names: Array = []
	for i in range(idx, mini(idx + 3, RULE_NAV_DEFS.size())):
		names.append(str(RULE_NAV_DEFS[i][1]))
	return " / ".join(names)

# ---------------------------------------------------------------- 退出对局确认（05）

func _back_dialog_copy() -> Dictionary:
	match str(back_dialog_action):
		"exit_match":
			return {"title": "退出本局游戏?", "desc": "退出后将离开当前对局，返回主菜单。",
				"note": "当前对局将中断。若只想休息一下，可以取消并选择暂停。",
				"cancel": "继续游戏", "ok": "退出对局"}
		"to_menu":
			return {"title": "返回主菜单?", "desc": "返回后将离开当前对局，回到主菜单。",
				"note": "当前对局将中断。", "cancel": "继续游戏", "ok": "返回主菜单"}
		"quit":
			return {"title": "退出游戏?", "desc": "退出后将关闭游戏，下次再继续。",
				"note": "", "cancel": "继续游戏", "ok": "退出游戏"}
		_:
			return {"title": str(back_dialog), "desc": "", "note": "",
				"cancel": "取消", "ok": "确定"}


# ---------------------------------------------------------------- 首页「关于游戏」弹窗（沿用动作 about_titles / about_close）

