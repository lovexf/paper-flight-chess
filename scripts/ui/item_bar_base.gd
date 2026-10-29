extends "res://scripts/render/render_base.gd"
## ============================================================
## UI 基类（方案 1 · 批次 2b）：道具栏（绘制/可用性判定/命中测试）
##   输入与购买动作（_release_item/_click_item_bar/_open_dice_picker）仍留在 game_main，
##   因为要调 _apply/_sfx/_begin_roll；本层只放绘制与纯判定。
##   继承链：screens_base ← render_base ← item_bar_base ← game_main
## ============================================================

var item_tex := {}
func item_usable_now(id: String) -> bool:
	var ph := str(st.get("phase", "rolling"))
	if ph == "ended": return false
	if id == "remote-dice" or id == "polyhedral-dice":
		return ph == "rolling" and st.get("dice", null) == null
	return true

## 这个道具现在能不能买（积分够 + 盲盒的额外限制）
func item_affordable(id: String) -> bool:
	if not bool(st.get("skillMode", false)): return false
	# ★ 用显示用的 hud_cur：动画期间道具栏的着色也不该提前变成下一家的积分
	#   （点击路径有 seq 门兜着，那时 hud_cur == st.currentPlayer，不会误判）
	var en: int = int(st.energy.get(hud_cur, 0))
	var cost: int = int(E.ITEM_COSTS.get(id, 9999))
	if en < cost: return false
	if id == "mysteryBox" and en >= E.MYSTERY_BOX_MAX: return false
	return true

## 松手：短按则购买，长按过则只关掉说明
func _draw_item_tip() -> void:
	if item_tip_id == "": return
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	var w: float = minf(size.x - 90.0, 460.0)
	var lines: Array = ITEM_DESC.get(item_tip_id, [])
	var h: float = 158.0 + float(lines.size()) * 30.0
	var r := Rect2((size.x - w) * 0.5, (size.y - h) * 0.5, w, h)
	draw_style_box(_sb(C_SURFACE, 14, 0, Color(0, 0, 0, 0)), r)
	var tid := str(item_tip_id)
	# 图标 + 名称
	var tex: Texture2D = item_tex.get(tid, null)
	var tx: float = r.position.x + 26.0
	if tex != null:
		draw_texture_rect(tex, Rect2(Vector2(tx, r.position.y + 22.0), Vector2(44, 44)), false, C_INK)
		tx += 60.0
	draw_string(font, Vector2(tx, r.position.y + 54.0), str(ITEM_NAMES.get(tid, tid)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 26, C_INK)
	var yy: float = r.position.y + 104.0
	for ln in lines:
		draw_string(font, Vector2(r.position.x + 26.0, yy), str(ln),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 19, C_GRAY)
		yy += 30.0
	draw_string(font, Vector2(r.position.x + 26.0, yy + 14.0),
		"消耗: %d 积分" % int(E.ITEM_COSTS.get(tid, 0)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 20, C_INK)
	draw_string(font, Vector2(r.position.x + 26.0, r.end.y - 18.0),
		"松手关闭 · 短按购买", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, C_GRAY)

func _draw_item_bar() -> void:
	if not bool(st.get("skillMode", false)): return
	for b in item_btns():
		_draw_one_item_button(b)

## 画单个道具按钮：底框/图标/名称/价格/按压缩放/拒绝抖动/购买闪白+对勾/待选脉动边框
func _draw_one_item_button(b: Dictionary) -> void:
	var font := ThemeDB.fallback_font
	var accent: Color = cols.get(hud_cur, Color.WHITE)   # 待选脉动用当前玩家色
	var bid := str(b.id)
	var cost: int = int(E.ITEM_COSTS.get(bid, 0))
	# 阶段不允许（比如摇完骰子后的遥控骰子）也画成不可用态
	var ok: bool = item_affordable(bid) and item_usable_now(bid)
	var r0: Rect2 = b.r
	var fx: Dictionary = item_fx.get(bid, {})
	var kind := str(fx.get("kind", ""))
	var ft: float = float(fx.get("t", 0.0))
	# ① 按下：整体缩到 0.95（Material 状态层的"压下去"），松手弹回
	var pressed: bool = (item_hold_id == bid)
	var sc: float = 0.95 if pressed else 1.0
	# ② 买不起被点：左右抖动 0.30s
	var shake_x := 0.0
	if kind == "deny":
		shake_x = sin(ft * 62.0) * 5.0 * (1.0 - ft / 0.30)
	var r := Rect2(r0.position + Vector2(shake_x, 0.0) + r0.size * (1.0 - sc) * 0.5, r0.size * sc)
	# 底色：可用 = 当前回合玩家色；不可用 = 灰（浅底深字，两态对比度都够）
	var cur_bg: Color = PASTEL.get(str(tex_seat.get(hud_cur, "green")), PASTEL["green"])
	draw_style_box(_sb(cur_bg if ok else Color(0.85, 0.86, 0.89), 10), r)
	var col := C_INK if ok else Color(0.40, 0.44, 0.50)
	# 图标 + 名称/消耗
	var tid := bid
	if not item_tex.has(tid):
		item_tex[tid] = load(str(ITEM_ICONS.get(tid, ""))) if ResourceLoader.exists(str(ITEM_ICONS.get(tid, ""))) else null
	var tex: Texture2D = item_tex.get(tid, null)
	if tex != null:
		var isz: float = r.size.y * 0.52
		var pad: float = r.size.x * 0.08
		draw_texture_rect(tex, Rect2(Vector2(r.position.x + pad, r.position.y + r.size.y * 0.5 - isz * 0.5),
			Vector2(isz, isz)), false, col)
		var tx: float = r.position.x + pad + isz + r.size.x * 0.06
		var tw: float = r.end.x - tx - pad
		draw_string(font, Vector2(tx, r.position.y + r.size.y * 0.44), str(b.t),
			HORIZONTAL_ALIGNMENT_LEFT, tw, 17, col)
		draw_string(font, Vector2(tx, r.position.y + r.size.y * 0.78), "%d 分" % cost,
			HORIZONTAL_ALIGNMENT_LEFT, tw, 15, col)
	else:
		draw_string(font, Vector2(r.position.x, r.position.y + 24.0), str(b.t),
			HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 17, col)
		draw_string(font, Vector2(r.position.x, r.position.y + 50.0), "%d 分" % cost,
			HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 16, col)
	# ③ 需要二次选择（遥控骰子选点 / 多面骰待掷）：按钮脉动描边，告诉玩家"这个已经选中了"
	var armed: bool = (bid == "remote-dice" and pick_dice_kind == "remote-dice") 			or (bid == "polyhedral-dice" and pending_poly and pending_poly_owner == int(st.currentPlayer))
	if kind == "deny":
		# 买不起：红框闪一下（配合抖动）
		var da: float = (1.0 - ft / 0.30) * 0.9
		draw_style_box(_sb(Color(0, 0, 0, 0), 10, 2.5, Color(0.86, 0.30, 0.28, da)), r)
	if armed:
		var pu: float = 0.55 + 0.45 * sin(item_pulse_t * 6.5)
		draw_style_box(_sb(Color(0, 0, 0, 0), 10, 3.0, Color(accent.r, accent.g, accent.b, pu)), r)
		# 右上角小圆点标记
		draw_circle(Vector2(r.end.x - 9.0, r.position.y + 9.0), 4.0 + 1.2 * pu,
			Color(accent.r, accent.g, accent.b, 0.9))
	# ④ 购买成功：闪白 + 弹对勾 + 扣分飘字
	if kind == "buy":
		var k: float = ft / 0.62
		draw_style_box(_sb(Color(1, 1, 1, 0.55 * (1.0 - k)), 10), r)
		# 右上角"已购买"徽章：白圆底 + 绿对勾（前 0.18s 弹出缩放，后 0.3s 淡出）
		var ks: float = 1.0 + 0.6 * (1.0 - clampf(ft / 0.18, 0.0, 1.0))
		var ka: float = clampf((0.62 - ft) / 0.30, 0.0, 1.0)
		var bcnt := Vector2(r.end.x - 17.0, r.position.y + 15.0)
		var br2: float = 11.0 * ks
		draw_circle(bcnt, br2 + 1.5, Color(0.10, 0.25, 0.17, 0.25 * ka))
		draw_circle(bcnt, br2, Color(1, 1, 1, ka))
		var ccol := Color(0.11, 0.45, 0.26, ka)
		var lw2: float = maxf(2.0, 2.8 * ks)
		draw_line(bcnt + Vector2(-4.6, 0.2) * ks, bcnt + Vector2(-1.2, 3.6) * ks, ccol, lw2)
		draw_line(bcnt + Vector2(-1.2, 3.6) * ks, bcnt + Vector2(4.8, -3.4) * ks, ccol, lw2)
		# 扣分飘字：从按钮往上飘
		var fy: float = r.position.y - 6.0 - 26.0 * k
		draw_string(font, Vector2(r.position.x, fy), "-%d" % cost,
			HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 20,
			Color(0.11, 0.42, 0.24, clampf((0.62 - ft) / 0.35, 0.0, 1.0)))
# ---------------------------------------------------------------- 道具交互
## 遥控骰子 / 多面骰子：等待玩家点一个点数
var item_hold_id := ""            # 正在被长按的道具
var item_hold_t := 0.0
var item_hold_fired := false      # 已经弹出过说明
## 道具栏的选择/购买反馈（Material 状态层 + 游戏 UI 的"按下缩放 / 成功对勾 / 失败抖动"）
## 即时绘制环境没有控件，所以按状态机画：按下缩小、成功闪白+对勾+扣分飘字、买不起抖动+红框、
## 需要二次选择时（遥控骰子选点 / 多面骰待掷）按钮脉动描边。
var item_fx := {}                 # 道具 id -> {"kind": "buy"|"deny", "t": 0..}
var item_pulse_t := 0.0           # 待二次选择时的脉动相位
## 回合结算提示（顶部横幅，2.2s 淡出）
var round_toast := ""
var round_toast_t := 0.0
var item_tip_id := ""             # 当前显示说明的道具
var pick_dice_kind := ""          # "" | "remote-dice"（多面骰不再走面板）
var pending_poly := false         # 已购买多面骰，等下一次掷骰时由引擎摇 1-12 并扣费
var pending_poly_owner := 0       # ★ 买主。换人还没掷就作废，避免"上一家的道具强加给下一家"
func _draw_dice_picker() -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.45))
	draw_string(font, Vector2(0, size.y * 0.30), "选择点数",
		HORIZONTAL_ALIGNMENT_CENTER, size.x, 26, Color.WHITE)
	for p in pick_rects:
		var r: Rect2 = p.r
		_pill(r, PASTEL.green)
		draw_string(font, r.position + Vector2(0, r.size.y * 0.68), str(p.v),
			HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 26, Color.WHITE)
	draw_string(font, Vector2(0, size.y * 0.72), "点击格子外面取消",
		HORIZONTAL_ALIGNMENT_CENTER, size.x, 18, Color(1, 1, 1, 0.7))

## 道具栏命中测试（依赖 item_usable_now/item_affordable，留在 game_main）
## 某个坐标落在哪个道具按钮上（空串 = 没落在任何按钮）
func _item_bar_hit(pos: Vector2) -> String:
	if not bool(st.get("skillMode", false)): return ""
	for b in item_btns():
		if (b.r as Rect2).has_point(pos): return str(b.id)
	return ""

## 长按弹出的道具说明（参考 skill-item 的 名称/说明/消耗）


# ---- 骰子选点 / 座位贴图（道具栏相关）----
var tex_seat := {1: "green", 2: "orange", 3: "blue", 4: "pink"}
var pick_rects: Array = []