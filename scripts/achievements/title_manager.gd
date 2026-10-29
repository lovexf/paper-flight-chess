# ============================================================================
#  称号判定（纯逻辑，不做 UI 绘制）
#
#  移植自 feixinqi-web/frontend/js/titleManager.js：
#    calculateTitles / currentTitles / collectLiveTitles / _topLevel /
#    _collectPlayerTitles / _computeUniqueWinners / _findTiebreakWinner /
#    _findComebackWinner / _prepareStats / _adjustTitleForHappyMode。
#  原项目：https://github.com/ZTMYO/MinimalistAeroplaneChess（AGPL-3.0）
#
#  【两类称号】
#    流程内（家族）：只看本机统计，达成即定论 -> collect_live_titles 当场播报；
#    结算（UNIQUE / FINAL）：要等全场收官 -> calculate_titles 一次性算。
#
#  【称号项】Dictionary {id, name, desc, tier, note?}，happy_disabled 只在结算
#  称号上出现；返回给调用方的一律是副本，避免改到 TitleDefs 的 const 表。
# ============================================================================
class_name TitleManager
extends RefCounted

const Defs = preload("res://scripts/achievements/title_defs.gd")
const Stats = preload("res://scripts/achievements/title_stats.gd")

# ---------------------------------------------------------------- 对外入口
## 结算：返回 {player: [称号项...]}
## stats 可以是 TitleStats 实例，也可以是 TitleStats.state 形状的字典。
static func calculate_titles(stats, rankings: Array, active_players: Array, is_happy: bool) -> Dictionary:
	var out := {}
	if active_players.is_empty():
		return out
	var st := _stats_dict(stats)
	var prepared := _prepare_stats(st, active_players, rankings)
	var winners := _compute_unique_winners(prepared, rankings, active_players)
	for p in active_players:
		var pid := int(p)
		out[pid] = _collect_player_titles(pid, st, prepared, rankings, winners, is_happy)
	return out

## 流程内播报：只播「比已播过的更高一级」，一次升多档也只出一条。
## announced 由调用方持有（键 "玩家-家族" -> 已播到的档位下标），本函数会写它。
static func collect_live_titles(stats, announced: Dictionary, player: int, is_happy: bool) -> Array:
	var st := _stats_dict(stats)
	var earned := []
	for family in Defs.FAMILIES:
		var top := _top_level(family, st, player, is_happy)
		if top.is_empty():
			continue
		var key := "%d-%s" % [player, str(family.get("key", ""))]
		var index := int(top.get("index", -1))
		if announced.has(key) and int(announced[key]) >= index:
			continue
		announced[key] = index
		earned.append((top.get("level", {}) as Dictionary).duplicate(true))
	return _sort_by_announce(earned)

## 此刻已达成（只读，不碰播报记录）：每族取最高一级，厉害的排前面
static func current_titles(stats, player: int, is_happy: bool) -> Array:
	var st := _stats_dict(stats)
	var earned := []
	for family in Defs.FAMILIES:
		var top := _top_level(family, st, player, is_happy)
		if top.is_empty():
			continue
		earned.append((top.get("level", {}) as Dictionary).duplicate(true))
	return _sort_by_tier(earned)

# ---------------------------------------------------------------- 单族判定
## 家族里当前达成的最高一级；一个都没达到（或欢乐模式禁用）返回空字典
static func _top_level(family: Dictionary, stats, player: int, is_happy: bool) -> Dictionary:
	if is_happy and bool(family.get("happy_disabled", false)):
		return {}
	var st := _stats_dict(stats)
	var value := Defs.family_value(family, st, player)
	var levels: Array = family.get("levels", [])
	var index := -1
	for i in levels.size():
		if value >= int((levels[i] as Dictionary).get("min", 0)):
			index = i
	if index < 0:
		return {}
	return {"level": levels[index], "index": index}

# ---------------------------------------------------------------- 结算收口
## 该玩家的全部称号（家族最高级 + 整局型 + 比较型 + 默认兜底）
static func _collect_player_titles(player: int, stats: Dictionary, prepared: Dictionary,
		rankings: Array, winners: Dictionary, is_happy: bool) -> Array:
	var titles := []
	# 1. 家族：同一件事只发最高一级，一次够到多档也不会刷屏
	for family in Defs.FAMILIES:
		var top := _top_level(family, stats, player, is_happy)
		if not top.is_empty():
			titles.append((top.get("level", {}) as Dictionary).duplicate(true))
	# 2. 整局型：只在正常收官时算数
	var normal := bool(prepared.get("is_normal_game_end", false))
	var been_defeated := int((prepared.get("been_defeated_counts", {}) as Dictionary).get(player, 0))
	var defeat_others := int((prepared.get("defeat_others_counts", {}) as Dictionary).get(player, 0))
	var bounce := int((prepared.get("bounce_steps", {}) as Dictionary).get(player, 0))
	var ranking := _ranking_of(rankings, player)
	if normal and been_defeated == 0:
		titles.append((Defs.FINAL_TITLES["INVISIBLE"] as Dictionary).duplicate(true))
	if normal and defeat_others == 0:
		titles.append((Defs.FINAL_TITLES["PEACE_MAKER"] as Dictionary).duplicate(true))
	if normal and bounce == 0 and not ranking.is_empty() and int(ranking.get("position", 0)) == 1:
		titles.append((Defs.FINAL_TITLES["TAILWIND_WALKER"] as Dictionary).duplicate(true))
	# 3. 跨玩家比较型
	if int(winners.get("marathon", -1)) == player and int((prepared.get("total_distances", {}) as Dictionary).get(player, 0)) > 0:
		titles.append((Defs.UNIQUE_TITLES["MARATHON"] as Dictionary).duplicate(true))
	if int(winners.get("killer", -1)) == player and defeat_others > 0:
		titles.append((Defs.UNIQUE_TITLES["KILLER"] as Dictionary).duplicate(true))
	if int(winners.get("six_master", -1)) == player and int((prepared.get("dice_six_counts", {}) as Dictionary).get(player, 0)) > 0:
		titles.append((Defs.UNIQUE_TITLES["SIX_MASTER"] as Dictionary).duplicate(true))
	if int(winners.get("home_visitor", -1)) == player and been_defeated > 0:
		titles.append((Defs.UNIQUE_TITLES["HOME_VISITOR"] as Dictionary).duplicate(true))
	if int(winners.get("steady_dog", -1)) == player and been_defeated > 0:
		titles.append((Defs.UNIQUE_TITLES["STEADY_DOG"] as Dictionary).duplicate(true))
	if int(winners.get("comeback", -1)) == player:
		titles.append((Defs.UNIQUE_TITLES["COMEBACK"] as Dictionary).duplicate(true))
	if int(winners.get("chess_king", -1)) == player:
		titles.append((Defs.UNIQUE_TITLES["CHESS_KING"] as Dictionary).duplicate(true))
	# 欢乐模式先滤掉不适配的，再兜底「平凡棋手」；反过来的话
	# 一个只拿到被禁称号的玩家会被筛成「没有任何称号」
	var kept := []
	for t in titles:
		if is_happy and Defs.is_happy_disabled(t):
			continue
		kept.append(t)
	if kept.is_empty():
		kept.append(Defs.DEFAULT_TITLE.duplicate(true))
	var out := []
	for t2 in kept:
		out.append(_adjust_title_for_happy_mode(t2, is_happy))
	return out

## 欢乐模式把「击败」替换成「碰撞」
static func _adjust_title_for_happy_mode(title: Dictionary, is_happy: bool) -> Dictionary:
	if not is_happy:
		return title
	var out := title.duplicate(true)
	out["name"] = str(out.get("name", "")).replace("击败", "碰撞")
	out["desc"] = str(out.get("desc", "")).replace("击败", "碰撞")
	return out

# ---------------------------------------------------------------- 唯一得主
## 预计算每项比较型称号的唯一得主；-1 = 没有合格者
static func _compute_unique_winners(prepared: Dictionary, rankings: Array, active_players: Array) -> Dictionary:
	var winners := {}
	var distances: Dictionary = prepared.get("total_distances", {})
	var defeats: Dictionary = prepared.get("defeat_others_counts", {})
	var sixes: Dictionary = prepared.get("dice_six_counts", {})
	var been: Dictionary = prepared.get("been_defeated_counts", {})
	winners["marathon"] = _find_tiebreak_winner(active_players, distances, "max", 1)
	winners["killer"] = _find_tiebreak_winner(active_players, defeats, "max", 1)
	winners["six_master"] = _find_tiebreak_winner(active_players, sixes, "max", 1)
	winners["home_visitor"] = _find_tiebreak_winner(active_players, been, "max", 1)
	winners["steady_dog"] = _find_tiebreak_winner(active_players, been, "min", 1)
	# 棋王：第一名，且完成度必须严格高于第二名（并列不授予）
	winners["chess_king"] = -1
	if not rankings.is_empty():
		var first := _ranking_at(rankings, 1)
		var second := _ranking_at(rankings, 2)
		if not first.is_empty():
			var sole := second.is_empty() or float(first.get("progress", 0)) > float(second.get("progress", 0))
			if sole:
				winners["chess_king"] = int(first.get("player", -1))
	# 逆风翻盘要翻整局进度历史，单独算
	winners["comeback"] = _find_comeback_winner(prepared.get("progress_history", []), rankings)
	return winners

## 指定维度胜者（确定性平局：编号最小者胜）。stats_map: {player: value}
static func _find_tiebreak_winner(players: Array, stats_map: Dictionary, mode: String, min_value: int) -> int:
	var valid := []
	for p in players:
		var pid := int(p)
		if not stats_map.has(pid):
			continue
		if int(stats_map[pid]) >= min_value:
			valid.append(pid)
	if valid.is_empty():
		return -1
	var best := int(stats_map[valid[0]])
	for pid2 in valid:
		var v := int(stats_map[pid2])
		if mode == "max":
			best = maxi(best, v)
		else:
			best = mini(best, v)
	var tied := []
	for pid3 in valid:
		if int(stats_map[pid3]) == best:
			tied.append(pid3)
	if tied.is_empty():
		return -1
	tied.sort()
	return int(tied[0])

## 逆风翻盘：冠军在至少 60% 的快照里都处于垫底
static func _find_comeback_winner(history: Array, rankings: Array) -> int:
	if history.size() < 5:
		return -1
	var champion := _ranking_at(rankings, 1)
	if champion.is_empty():
		return -1
	var player := int(champion.get("player", -1))
	if player < 0:
		return -1
	var behind := 0
	for snap in history:
		if not (snap is Dictionary):
			continue
		var players: Dictionary = snap.get("players", {})
		if players.is_empty():
			continue
		var mine := float(players.get(player, 0))
		var lowest := INF
		for v in players.values():
			lowest = minf(lowest, float(v))
		if mine <= lowest:
			behind += 1
	if float(behind) / float(history.size()) >= 0.6:
		return player
	return -1

# ---------------------------------------------------------------- 预计算统计
## 结算用的派生统计（总里程 / 6 点 / 击败与被击败 / 反弹 / 正常收官）
static func _prepare_stats(stats, active_players: Array, rankings: Array) -> Dictionary:
	var st := _stats_dict(stats)
	var counts: Dictionary = st.get("defeat_counts", {})
	var out := {
		"total_distances": {},
		"dice_six_counts": {},
		"defeat_others_counts": {},
		"been_defeated_counts": {},
		"bounce_steps": {},
		"is_normal_game_end": Stats.has_normal_game_end(st),
		"progress_history": st.get("progress_history", []),
	}
	for p in active_players:
		var pid := int(p)
		out["total_distances"][pid] = _raw(st, "total_distance", pid)
		out["dice_six_counts"][pid] = _raw(st, "dice_six_counts", pid)
		out["bounce_steps"][pid] = _raw(st, "bounce_steps", pid)
		var others := 0
		var row: Dictionary = counts.get(pid, {})
		for target in row.keys():
			if int(target) != pid:
				others += int(row[target])
		out["defeat_others_counts"][pid] = others
		var been := 0
		for other in active_players:
			if int(other) == pid:
				continue
			var orow: Dictionary = counts.get(int(other), {})
			been += int(orow.get(pid, 0))
		out["been_defeated_counts"][pid] = been
	return out

# ---------------------------------------------------------------- 小工具
## stats 既可以是 TitleStats 实例，也可以是它的 state 字典
static func _stats_dict(stats) -> Dictionary:
	if stats is Dictionary:
		return stats
	if stats == null:
		return {}
	var nested = stats.get("state")
	if nested is Dictionary:
		return nested
	return {}

static func _raw(stats: Dictionary, field: String, player: int) -> int:
	var v = Defs.field_value(stats, field, player)
	return int(v) if v != null else 0

static func _ranking_of(rankings: Array, player: int) -> Dictionary:
	for r in rankings:
		if r is Dictionary and int(r.get("player", -1)) == player:
			return r
	return {}

static func _ranking_at(rankings: Array, position: int) -> Dictionary:
	for r in rankings:
		if r is Dictionary and int(r.get("position", -1)) == position:
			return r
	return {}

## 展示排序：先按稀有度（mythic 最前），同级保持家族顺序（稳定排序）
static func _sort_by_tier(items: Array) -> Array:
	var decorated := []
	for i in items.size():
		var t: Dictionary = items[i]
		decorated.append({"item": t, "rank": Defs.tier_rank(str(t.get("tier", ""))), "i": i})
	decorated.sort_custom(func(a, b):
		if int(a["rank"]) != int(b["rank"]):
			return int(a["rank"]) < int(b["rank"])
		return int(a["i"]) < int(b["i"])
	)
	var out := []
	for d in decorated:
		out.append(d["item"])
	return out

## 播报排序：ANNOUNCE_ORDER 靠前的先播，其余保持家族顺序（稳定排序）
static func _sort_by_announce(items: Array) -> Array:
	var order: Array = Defs.ANNOUNCE_ORDER
	var decorated := []
	for i in items.size():
		var t: Dictionary = items[i]
		var at := order.find(str(t.get("id", "")))
		decorated.append({"item": t, "rank": order.size() if at < 0 else at, "i": i})
	decorated.sort_custom(func(a, b):
		if int(a["rank"]) != int(b["rank"]):
			return int(a["rank"]) < int(b["rank"])
		return int(a["i"]) < int(b["i"])
	)
	var out := []
	for d in decorated:
		out.append(d["item"])
	return out
