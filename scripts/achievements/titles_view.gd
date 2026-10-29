extends RefCounted
## 称号 UI（独立模块）：稀有度配色 chip、结算页称号行、称号图鉴弹窗。
## 全部 static func 接收 host（game_main 的 Control），绘制仍发生在同一个 CanvasItem 上。
## 颜色照搬参考 style.css .title-chip.tier-* / .title-earned-title.tier-*

## tier -> {fg 文字色, bg 底色, bd 描边色}
const TIERS := {
	"common": {"fg": "#4b8a63", "bg": "#e3f1e8", "bd": "#4B8A6366"},
	"rare": {"fg": "#3f7fb5", "bg": "#e0e8f0", "bd": "#3F7FB566"},
	"epic": {"fg": "#8455b8", "bg": "#ebe1ef", "bd": "#8455B873"},
	"legendary": {"fg": "#b7791f", "bg": "#f5e8d2", "bd": "#B7791F80"},
	"mythic": {"fg": "#c0453c", "bg": "#f9dedb", "bd": "#C0453C80"},
	"default": {"fg": "#7d7269", "bg": "#eae6e2", "bd": "#8C82785A"},
}

static func tier_col(tier: String) -> Color:
	var st: Dictionary = TIERS.get(tier, TIERS["common"])
	return Color(str(st.fg))

## 画一个称号 chip，返回宽度
static func draw_chip(host, pos: Vector2, text: String, tier: String, fs: int = 13) -> float:
	var font := ThemeDB.fallback_font
	var tw: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var w: float = tw + 16.0
	var h: float = float(fs) + 7.0
	var st: Dictionary = TIERS.get(tier, TIERS["common"])
	host.draw_style_box(host._sb(Color(str(st.bg)), int(h * 0.5), 1.0, Color(str(st.bd))),
		Rect2(pos, Vector2(w, h)))
	host.draw_string(font, pos + Vector2(8.0, h * 0.74), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
		Color(str(st.fg)))
	return w

## 测量一排称号需要几行（与 draw_titles_line 的换行规则一致）
static func line_count(titles: Array, max_w: float, fs: int = 12) -> int:
	if titles.is_empty(): return 0
	var font := ThemeDB.fallback_font
	var x: float = 0.0
	var rows: int = 1
	for t in titles:
		var name := str(t.get("name", ""))
		var tw: float = font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 16.0
		if x + tw > max_w and x > 1.0:
			rows += 1
			x = 0.0
		x += tw + 6.0
	return rows

## 画一排称号（超宽自动换行），返回占用高度
static func draw_titles_line(host, pos: Vector2, titles: Array, max_w: float,
		fs: int = 13, line_gap: float = 4.0) -> float:
	if titles.is_empty(): return 0.0
	var font := ThemeDB.fallback_font
	var x: float = pos.x
	var y: float = pos.y
	var h: float = float(fs) + 7.0
	var rows: int = 1
	for t in titles:
		var name := str(t.get("name", ""))
		var tw: float = font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 16.0
		if x + tw > pos.x + max_w and x > pos.x + 1.0:
			rows += 1
			x = pos.x
			y += h + line_gap
		x += draw_chip(host, Vector2(x, y), name, str(t.get("tier", "common")), fs) + 6.0
	return float(rows) * (h + line_gap)

## 结算页用：某玩家一行称号（行内 y 由调用方给）
static func draw_player_titles(host, pos: Vector2, titles: Array, max_w: float, fs: int = 13) -> float:
	if titles.is_empty():
		var font := ThemeDB.fallback_font
		host.draw_string(font, pos + Vector2(0, 14.0), "暂无称号", HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color("#9a918a"))
		return 20.0
	return draw_titles_line(host, pos, titles, max_w, fs)

## 图鉴分组：多级家族按档数/最高稀有度排序，单级家族按稀有度排序
static func gallery_groups(defs) -> Dictionary:
	var chains: Array = []
	var solos: Array = []
	for f in defs.families():
		if (f["levels"] as Array).size() > 1:
			chains.append(f)
		else:
			solos.append(f)
	chains.sort_custom(func(a, b): return (a["levels"] as Array).size() < (b["levels"] as Array).size())
	solos.sort_custom(func(a, b):
		return defs.tier_rank(str((a["levels"] as Array)[0].get("tier", "common"))) 			> defs.tier_rank(str((b["levels"] as Array)[0].get("tier", "common"))))
	return {"chains": chains, "solos": solos}
