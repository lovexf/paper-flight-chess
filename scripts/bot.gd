# ============================================================================
#  AI 决策 —— 移植自 ZTMYO/MinimalistAeroplaneChess 的 shared/bot.mjs
#  原项目授权：AGPL-3.0
#  评分完全读引擎 preview 的事件流（击败/跳子/飞棋/终点都在里面），
#  所以 AI 推演与真实规则不可能分叉。
# ============================================================================
class_name FxqBot
extends RefCounted

const E = preload("res://scripts/engine.gd")

const SCORE := {
	"winNow": 2000, "finish": 450, "beat": 500, "jump": 300, "fly": 300,
	"collision": 550, "takeoff": 200, "bounceWithBeat": 400, "bounce": 20,
	"stackCrash": -200, "normal": 50,
}
const BEHIND_GAP := 25.0
const FAR_BEHIND_GAP := 60.0

static func unfinished_count(state: Dictionary, player: int, exclude: int = -1) -> int:
	var n := 0
	var cs: Array = state.players[player].chesses
	for i in cs.size():
		if not cs[i].finished and i != exclude: n += 1
	return n

static func player_progress(state: Dictionary, player: int) -> float:
	var sum := 0.0
	for c in state.players[player].chesses:
		sum += E.chess_progress(int(c.pos), bool(c.finished))
	return sum

static func is_behind(state: Dictionary, player: int, gap: float = BEHIND_GAP) -> bool:
	var mine := player_progress(state, player)
	var best := -1.0
	for pid in state.order:
		if int(pid) == player: continue
		best = maxf(best, player_progress(state, int(pid)))
	return best - mine >= gap

## 被击败那格的对手推进到什么程度（越接近终点，打掉越值）
static func victim_progress_at(state: Dictionary, victim: int, cell) -> float:
	var best := 0.0
	for c in state.players[victim].chesses:
		if c.finished or int(c.pos) == E.BASE: continue
		if E.cell_of(victim, int(c.pos)) == cell:
			best = maxf(best, E.chess_progress(int(c.pos)))
	return best

static func _has(events: Array, type: String) -> bool:
	for e in events:
		if e.type == type: return true
	return false

static func _first_of(events: Array, type: String) -> Dictionary:
	for e in events:
		if e.type == type: return e
	return {}

## 一个候选走法值多少分（同分时取走得最远的）
static func score_move(state: Dictionary, player: int, chess_index: int, dice: int) -> Dictionary:
	var res := E.preview(state, player, {"type": "move", "chessIndex": chess_index}, dice)
	if not res.ok: return {}
	var events: Array = res.events
	var score := 0
	if _has(events, "finish"):
		score += int(SCORE.winNow) if unfinished_count(state, player, chess_index) == 0 else int(SCORE.finish)
	for e in events:
		match e.type:
			"beat":
				score += int(SCORE.beat) + int(victim_progress_at(state, int(e.targetPlayer), e.cell) * 3.0)
			"jump":
				score += int(SCORE.jump)
			"collision_bonus":
				# ★ 参考 bot.mjs:73-75：欢乐模式的碰撞奖励要给分，否则 AI【看不见欢乐模式的主机制】，
				#   踩人走法只拿 +50(normal) —— 实测会让 AI 在欢乐模式里完全不去撞人。
				score += int(SCORE.collision) + int(e.get("enemyCount", 1)) * 100 + int(e.get("steps", 0)) * 15
			"collide":
				score += int(SCORE.collision) if state.happy else int(SCORE.stackCrash)
	if not events.is_empty() and events[0].type == "launch":
		score += int(SCORE.takeoff)
	else:
		var walked := _first_of(events, "walk")
		if not walked.is_empty() and bool(walked.bounced):
			score += int(SCORE.bounceWithBeat) if _has(events, "beat") else int(SCORE.bounce)
		elif not (_has(events, "finish") or _has(events, "beat") or _has(events, "jump") or _has(events, "collide") or _has(events, "collision_bonus")):
			score += int(SCORE.normal)
	return {"score": score, "dice": dice}

static func best_move(state: Dictionary, player: int, dice: int, movable: Array) -> Dictionary:
	var best := {}
	for ci in movable:
		var sc := score_move(state, player, int(ci), dice)
		if sc.is_empty(): continue
		if best.is_empty() or int(sc.score) > int(best.score):
			best = {"score": sc.score, "dice": sc.dice, "chessIndex": int(ci)}
	return best

## 该玩家下一步做什么。返回空字典表示无可做动作（由引擎自行跳过）
static func choose_action(state: Dictionary, player: int, difficulty: String = "hard", rng = null) -> Dictionary:
	if state.phase == "ended" or int(state.currentPlayer) != player: return {}
	var hard := difficulty == "hard"
	if state.phase == "rolling": return {"type": "roll"}
	if state.phase == "selecting":
		var movable := E.movable_chess(state, player, int(state.dice))
		if movable.is_empty(): return {}
		# 三档：easy 全随机；normal 45% 随机 / 55% 最优；hard 恒取最优
		var rnd_pick := func() -> Dictionary:
			var i := int(floor((rng.randf() if rng != null else randf()) * movable.size()))
			return {"type": "move", "chessIndex": int(movable[mini(i, movable.size() - 1)])}
		if difficulty == "easy": return rnd_pick.call()
		if difficulty == "normal" and (rng.randf() if rng != null else randf()) < 0.45:
			return rnd_pick.call()
		var best := best_move(state, player, int(state.dice), movable)
		if not best.is_empty(): return {"type": "move", "chessIndex": int(best.chessIndex)}
	return {}

# ---------------------------------------------------------------- 道具决策
## 参考 shared/bot.mjs:115-161

## 传送门目标：跑道上最靠后的那颗（越靠后传送收益越大）
static func teleport_pick(state: Dictionary, player: int) -> Dictionary:
	var best := {}
	var best_pos := 999
	var cs: Array = state.players[player].chesses
	for i in cs.size():
		var c: Dictionary = cs[i]
		if bool(c.finished): continue
		var p: int = int(c.pos)
		if p < 0 or p >= 51: continue
		if p < best_pos:
			best_pos = p
			best = {"chessIndex": i, "pos": p}
	if best.is_empty(): return {}
	if E.teleport_spots(state, player, best_pos).is_empty(): return {}
	return best

static func has_chess_on_track(state: Dictionary, player: int) -> bool:
	for c in state.players[player].chesses:
		# ★ 上界是 TRACK_END(56) 不是跑道起点(51)：参考 bot.mjs:112 用 TRACK_END。
		#   注意和 teleportPick 的过滤（bot.gd:126，pos < 51）区分开 —— 那是「能传送的格子」，
		#   这里问的是「还有棋子在场上吗」（含跑道 51~56）。
		if not bool(c.finished) and int(c.pos) >= 0 and int(c.pos) < E.TRACK_END: return true
	return false

## 遥控骰子：1..6 全试一遍，挑能击败/到终点的最优点数
static func best_remote_value(state: Dictionary, player: int) -> int:
	var best_v := 0
	var best_w := -1e9
	for v in range(1, 7):
		var mv := E.movable_chess(state, player, v)
		if mv.is_empty(): continue
		var b := best_move(state, player, v, mv)
		if b.is_empty(): continue
		# ★ 对齐参考 bot.mjs:105 `scored.score + value * 0.1`：同分时走得远一点
		var worth: float = float(b.score) + float(v) * 0.1
		if worth > best_w:
			best_w = worth
			best_v = v
	return best_v

## 道具模式下这一步该不该买/用什么
static func choose_item_action(state: Dictionary, player: int, difficulty: String) -> Dictionary:
	if not bool(state.get("skillMode", false)): return {}
	if state.get("pendingItem", null) != null:
		var pend = state.pendingItem
		if int(pend.player) != player: return {}
		if str(pend.item) == "remote-dice":
			var v := best_remote_value(state, player)
			return {"type": "roll", "value": v, "maxDice": 6, "noBonus": true, "item": "remote-dice"}
		if str(pend.item) == "teleport":
			var t := teleport_pick(state, player)
			if not t.is_empty():
				return {"type": "teleport", "chessIndex": int(t.chessIndex)}
			return {"type": "item_cancel"}
		return {}
	if difficulty != "hard": return {}          # 只有困难 AI 会用道具
	if state.phase != "rolling": return {}
	var en: int = int(state.energy.get(player, 0))

	# 遥控骰子：有能击败的走法才买（最贵，优先级最高）
	if en >= int(E.ITEM_COSTS["remote-dice"]):
		var bv := best_remote_value(state, player)
		if bv > 0:
			var mv := E.movable_chess(state, player, bv)
			var b := best_move(state, player, bv, mv)
			if not b.is_empty() and int(b.score) >= int(SCORE.beat):
				return {"type": "item_activate", "item": "remote-dice"}

	# 传送门：落后 + 跑道上有棋子
	if is_behind(state, player) and has_chess_on_track(state, player) \
			and en >= int(E.ITEM_COSTS["teleport"]):
		var t2 := teleport_pick(state, player)
		if not t2.is_empty():
			return {"type": "item_activate", "item": "teleport"}

	# 盲盒：大幅落后且积分不足以买传送门时赌一把
	if is_behind(state, player, FAR_BEHIND_GAP) \
			and en >= int(E.ITEM_COSTS["mysteryBox"]) and en < int(E.ITEM_COSTS["teleport"]):
		return {"type": "item_activate", "item": "mysteryBox"}

	# 多面骰子：落后时直接掷（买与掷是同一步）
	if is_behind(state, player) and has_chess_on_track(state, player) \
			and en >= int(E.ITEM_COSTS["polyhedral-dice"]):
		return {"type": "roll", "item": "polyhedral-dice", "maxDice": 12, "noBonus": true}
	return {}
