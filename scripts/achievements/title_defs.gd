# ============================================================================
#  称号定义表（纯数据 + 只读查询）
#
#  移植自 feixinqi-web/frontend/js/titleManager.js：
#    FAMILIES（21 个家族）/ UNIQUE_TITLES / FINAL_TITLES / DEFAULT_TITLE /
#    TIER_NAMES / TIER_RANK / ANNOUNCE_ORDER。
#  原项目：https://github.com/ZTMYO/MinimalistAeroplaneChess（AGPL-3.0）
#
#  【本文件只放数据，不做任何判定】
#  JS 里每个家族有一段 value(s, p) 闭包；GDScript 的 const 表放不下 Callable，
#  所以改写成「field（统计字段名）+ derive（派生规则）」：
#    raw       —— 直接取值（默认）
#    is_player —— 字段存的是玩家号，等于本人记 1（首个完成 / 首个击败）
#    ge        —— 字段 >= threshold 记 1（多面骰摇到 12）
#    eq        —— 字段 == threshold 记 1（多面骰摇到 1 / 盲盒开出 0）
#  统计字段名与 title_stats.gd 的 state 键一一对应（snake_case）。
# ============================================================================
class_name TitleDefs
extends RefCounted

# ---------------------------------------------------------------- 几何常量
# 与 core/board.gd 的 RUNWAY_BASE / CROSS_BASE 一致。这里留一份副本，
# 称号模块不依赖规则引擎也能单独跑测试（「飞来横祸」判定要用）。
const RUNWAY_BASE := 100
const RUNWAY_LEN := 40
const CROSS_BASE := 900
const CROSS_LEN := 2
const TRACK_END := 56

# ---------------------------------------------------------------- 21 个家族
## 顺序 = 展示与播报的家族顺序（不要随意调整）
const FAMILIES := [
	{
		"key": "ones",
		"field": "max_consecutive_ones",
		"levels": [
			{"id": "bad_luck", "name": "倒霉熊", "desc": "连着三回合都摇到 1 点", "min": 3, "tier": "rare"},
			{"id": "reverse_lucky", "name": "反向欧皇", "desc": "连着五回合都摇到 1 点", "min": 5, "tier": "legendary"},
		],
	},
	{
		"key": "no_takeoff",
		"field": "max_consecutive_no_takeoff",
		"levels": [
			{"id": "unlucky_takeoff", "name": "航班延误", "desc": "连着四回合无法起飞", "min": 4, "tier": "rare"},
			{"id": "super_unlucky", "name": "航班取消", "desc": "连着六回合无法起飞", "min": 6, "tier": "epic"},
			{"id": "forsaken", "name": "天弃之子", "desc": "连着十回合无法起飞", "min": 10, "tier": "mythic"},
		],
	},
	{
		"key": "sixes",
		"field": "max_consecutive_sixes",
		"levels": [
			{"id": "lucky_king", "name": "欧皇", "desc": "连投三次 6", "min": 3, "tier": "rare"},
			{"id": "six_streak", "name": "六六大顺", "desc": "连投四次 6", "min": 4, "tier": "epic"},
			{"id": "dice_god", "name": "鸿运当头", "desc": "连投六次 6", "min": 6, "tier": "mythic"},
		],
	},
	{
		"key": "move_distance",
		"field": "max_move_distance",
		"levels": [
			{"id": "soaring", "name": "一飞冲天", "desc": "单次移动达到 25 格", "min": 25, "tier": "epic"},
			{"id": "sky_high", "name": "九霄凌云", "desc": "单次移动达到 35 格", "min": 35, "tier": "mythic"},
		],
	},
	{
		"key": "bounce",
		"field": "bounce_steps",
		"happy_disabled": true,
		"levels": [
			{"id": "bounce_master", "name": "硬碰硬", "desc": "反弹总格数达到 20 格", "min": 20, "tier": "epic"},
			{"id": "wind_walker", "name": "逆风行者", "desc": "反弹总格数达到 35 格", "min": 35, "tier": "legendary"},
			{"id": "against_sky", "name": "逆势天行", "desc": "反弹总格数达到 50 格", "min": 50, "tier": "mythic"},
		],
	},
	{
		"key": "multi_kill",
		"field": "max_beats_in_move",
		"happy_disabled": true,
		"levels": [
			{"id": "double_kill", "name": "一箭双雕", "desc": "单次移动击败 2 颗棋子", "note": "撞叠子不算", "min": 2, "tier": "epic"},
			{"id": "triple_kill", "name": "三连绝世", "desc": "单次移动击败 3 颗棋子", "note": "撞叠子不算", "min": 3, "tier": "legendary"},
			{"id": "quad_kill", "name": "横扫千军", "desc": "单次移动击败 4 颗棋子", "note": "撞叠子不算", "min": 4, "tier": "mythic"},
		],
	},
	{
		"key": "collide_move",
		"field": "max_collide_in_move",
		"happy_only": true,
		"levels": [
			{"id": "bumper_car", "name": "碰碰车", "desc": "单次移动碰撞 2 颗棋子", "min": 2, "tier": "rare"},
			{"id": "chain_crash", "name": "连环碰撞", "desc": "单次移动碰撞 4 颗棋子", "min": 4, "tier": "legendary"},
			{"id": "rampage", "name": "所向披靡", "desc": "单次移动碰撞 6 颗棋子", "min": 6, "tier": "mythic"},
		],
	},
	{
		"key": "teleport",
		"field": "max_teleport_distance",
		"item_only": true,
		"levels": [
			{"id": "dimension_traveler", "name": "次元旅人", "desc": "单次传送达到 35 格", "min": 35, "tier": "rare"},
			{"id": "void_walker", "name": "虚空行者", "desc": "单次传送达到 40 格", "min": 40, "tier": "epic"},
			{"id": "void_overlord", "name": "虚空主宰", "desc": "单次传送达到 50 格", "min": 50, "tier": "mythic"},
		],
	},
	{
		"key": "mystery_box",
		"field": "mystery_box_max",
		"item_only": true,
		"levels": [
			{"id": "koi_fish", "name": "锦鲤附体", "desc": "盲盒开出达到 35 点积分", "min": 35, "tier": "common"},
			{"id": "lucky_burst", "name": "欧气爆棚", "desc": "盲盒开出满分 40 点积分", "min": 40, "tier": "rare"},
		],
	},
	{
		"key": "skill_count",
		"field": "skill_use_count",
		"item_only": true,
		"levels": [
			{"id": "skill_mania", "name": "有啥用啥", "desc": "使用道具达到 10 次", "min": 10, "tier": "common"},
			{"id": "skill_master", "name": "道具狂人", "desc": "使用道具达到 20 次", "min": 20, "tier": "rare"},
			{"id": "skill_grandmaster", "name": "百宝奇兵", "desc": "使用道具达到 40 次", "min": 40, "tier": "legendary"},
		],
	},
	{
		"key": "block",
		"field": "block_count",
		"happy_disabled": true,
		"levels": [
			{"id": "gate_keeper", "name": "一夫当关", "desc": "用叠子阻挡对手 3 次", "min": 3, "tier": "epic"},
			{"id": "impregnable", "name": "万夫莫开", "desc": "用叠子阻挡对手 6 次", "min": 6, "tier": "legendary"},
		],
	},
	{
		"key": "poly_high",
		"field": "polyhedral_max",
		"derive": "ge",
		"threshold": 12,
		"item_only": true,
		"levels": [
			{"id": "destiny_child", "name": "天命之子", "desc": "多面骰子摇到 12 点", "min": 1, "tier": "mythic"},
		],
	},
	{
		"key": "poly_low",
		"field": "polyhedral_min",
		"derive": "eq",
		"threshold": 1,
		"item_only": true,
		"levels": [
			{"id": "unlucky_bear", "name": "厄运降临", "desc": "多面骰子摇到 1 点", "min": 1, "tier": "mythic"},
		],
	},
	{
		"key": "box_zero",
		"field": "mystery_box_min",
		"derive": "eq",
		"threshold": 0,
		"item_only": true,
		"levels": [
			{"id": "philanthropist", "name": "慈善家", "desc": "盲盒开出 0 点积分", "min": 1, "tier": "rare"},
		],
	},
	{
		"key": "first_finish",
		"field": "first_finished_player",
		"derive": "is_player",
		"levels": [
			{"id": "speed_legend", "name": "最速传说", "desc": "首个使棋子抵达终点", "min": 1, "tier": "common"},
		],
	},
	{
		"key": "first_blood",
		"field": "first_beater_player",
		"derive": "is_player",
		"levels": [
			{"id": "first_blood", "name": "第一滴血", "desc": "本局第一个击败对手", "min": 1, "tier": "common"},
		],
	},
	{
		"key": "runway_kill",
		"field": "runway_kills",
		"happy_disabled": true,
		"levels": [
			{"id": "runway_killer", "name": "飞来横祸", "desc": "击败终点通道上的对手", "min": 1, "tier": "rare"},
		],
	},
	{
		"key": "airport_rekt",
		"field": "airport_rekt",
		"happy_disabled": true,
		"levels": [
			{"id": "airport_rekt", "name": "出师未捷", "desc": "刚离开起飞点就被踩回基地", "min": 1, "tier": "rare"},
		],
	},
	{
		"key": "oriole_kill",
		"field": "oriole_kills",
		"happy_disabled": true,
		"levels": [
			{"id": "oriole_kill", "name": "黄雀在后", "desc": "一回合内击败刚击败别人的那颗棋子", "min": 1, "tier": "rare"},
		],
	},
	{
		"key": "revenge_kill",
		"field": "revenge_kills",
		"happy_disabled": true,
		"levels": [
			{"id": "revenge_kill", "name": "以牙还牙", "desc": "一回合内击败刚刚击败你的那颗棋子", "min": 1, "tier": "epic"},
		],
	},
	{
		"key": "petty_teleport",
		"field": "petty_teleports",
		"item_only": true,
		"levels": [
			{"id": "petty_teleport", "name": "寸步千金", "desc": "单次传送前进了 1 格", "min": 1, "tier": "epic"},
		],
	},
]

# ---------------------------------------------------------------- 结算称号
## 比较型：要等所有人收官才能定论
const UNIQUE_TITLES := {
	"MARATHON": {"id": "marathon", "name": "长跑冠军", "desc": "移动格数全场最多", "tier": "common"},
	"SIX_MASTER": {"id": "six_master", "name": "六点狂魔", "desc": "摇到 6 的次数全场最多", "tier": "common"},
	"KILLER": {"id": "killer", "name": "猎杀号", "desc": "击败对手次数最多", "tier": "common"},
	"HOME_VISITOR": {"id": "home_visitor", "name": "回家常客", "desc": "被对手击败次数最多", "tier": "common", "happy_disabled": true},
	"STEADY_DOG": {"id": "steady_dog", "name": "幸存者", "desc": "被击败次数全场最少", "tier": "common"},
	"CHESS_KING": {"id": "chess_king", "name": "棋王", "desc": "本局第一名", "tier": "common"},
	"COMEBACK": {"id": "comeback", "name": "逆风翻盘", "desc": "整局 60% 时间处于垫底，最后反败为胜", "tier": "mythic"},
}

## 整局型：只在正常收官时才算数
const FINAL_TITLES := {
	"INVISIBLE": {"id": "invisible", "name": "不灭之躯", "desc": "整局未被击败过", "tier": "mythic", "happy_disabled": true},
	"PEACE_MAKER": {"id": "peace_maker", "name": "和平使者", "desc": "未击败任何对手", "tier": "epic"},
	"TAILWIND_WALKER": {"id": "tailwind_walker", "name": "顺风行者", "desc": "在整局未发生过反弹的情况下获胜", "tier": "epic", "happy_disabled": true},
}

const DEFAULT_TITLE := {"id": "default", "name": "平凡棋手", "desc": "平平淡淡才是真", "tier": "common"}

## 同一批同时达成多个称号时的播报顺序（靠前先播）：里程碑型先于数量级
const ANNOUNCE_ORDER := ["first_blood", "speed_legend"]

# ---------------------------------------------------------------- 分级
## 只决定配色，不参与任何判定
const TIER_NAMES := {"common": "普通", "rare": "稀有", "epic": "史诗", "legendary": "传说", "mythic": "神话"}
## 越靠前越厉害，展示时按这个顺序把强称号排在前面
const TIER_RANK := {"mythic": 0, "legendary": 1, "epic": 2, "rare": 3, "common": 4}

## 这些字段的「还没发生过」初值是 99（不是 0），取最小值时才不会把 0 当成默认
const MIN_FIELD_DEFAULTS := {"mystery_box_min": 99, "polyhedral_min": 99}

# ---------------------------------------------------------------- 字段取值
## 字段在「还没发生过」时的默认值
static func field_default(field: String) -> int:
	return int(MIN_FIELD_DEFAULTS.get(field, 0))

## 从统计字典里取一个字段值：字典字段按玩家号取，标量字段直接返回。
## 字段整个缺失时返回默认值（-min 类字段是 99，其余 0）。
static func field_value(stats: Dictionary, field: String, player: int) -> Variant:
	var table = stats.get(field, null)
	if table == null:
		return field_default(field)
	if table is Dictionary:
		var row: Dictionary = table
		if row.has(player):
			return row[player]
		return field_default(field)
	return table

## 家族当前数值：等价于 JS FAMILIES[i].value(stats, player)
static func family_value(family: Dictionary, stats: Dictionary, player: int) -> int:
	var v = field_value(stats, str(family.get("field", "")), player)
	match str(family.get("derive", "raw")):
		"is_player":
			if v == null:
				return 0
			return 1 if int(v) == player else 0
		"ge":
			if v == null:
				return 0
			return 1 if int(v) >= int(family.get("threshold", 0)) else 0
		"eq":
			if v == null:
				return 0
			return 1 if int(v) == int(family.get("threshold", 0)) else 0
		_:
			return int(v) if v != null else 0

# ---------------------------------------------------------------- 只读查询
static func families() -> Array:
	return FAMILIES

static func family_keys() -> Array:
	var out := []
	for f in FAMILIES:
		out.append(str(f.get("key", "")))
	return out

## 按 key 找家族；找不到返回空字典
static func family(key: String) -> Dictionary:
	for f in FAMILIES:
		if str(f.get("key", "")) == key:
			return f
	return {}

## 家族里共有几个等级档位
static func level_count() -> int:
	var n := 0
	for f in FAMILIES:
		n += (f.get("levels", []) as Array).size()
	return n

## 全表按 id 找等级（家族等级 + 结算称号 + 默认称号）；找不到返回空字典
static func level_by_id(id: String) -> Dictionary:
	for f in FAMILIES:
		for lv in f.get("levels", []):
			if str(lv.get("id", "")) == id:
				return lv
	for key in UNIQUE_TITLES.keys():
		var t: Dictionary = UNIQUE_TITLES[key]
		if str(t.get("id", "")) == id:
			return t
	for key2 in FINAL_TITLES.keys():
		var t2: Dictionary = FINAL_TITLES[key2]
		if str(t2.get("id", "")) == id:
			return t2
	if str(DEFAULT_TITLE.get("id", "")) == id:
		return DEFAULT_TITLE
	return {}

## 分级排序权重：越强越小；未知分级排最后
static func tier_rank(tier: String) -> int:
	return int(TIER_RANK.get(tier, 99))

static func tier_name(tier: String) -> String:
	return str(TIER_NAMES.get(tier, tier))

## 该称号是否在欢乐模式里不授予
static func is_happy_disabled(title: Dictionary) -> bool:
	return bool(title.get("happy_disabled", false))

## 终点通道格：各家跑道 100..139 与两条交叉格 900..901
static func is_runway_cell(cell) -> bool:
	if cell == null:
		return false
	if typeof(cell) != TYPE_INT and typeof(cell) != TYPE_FLOAT:
		return false
	var c := int(cell)
	if c >= RUNWAY_BASE and c < RUNWAY_BASE + RUNWAY_LEN:
		return true
	return c >= CROSS_BASE and c < CROSS_BASE + CROSS_LEN
