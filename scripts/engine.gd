# ============================================================================
#  飞行棋规则引擎（GDScript 移植版）
#
#  移植自 ZTMYO/MinimalistAeroplaneChess 的 shared/engine.mjs
#  原项目授权：AGPL-3.0 —— 本文件为衍生作品，同样以 AGPL-3.0 发布
#  原项目：https://github.com/ZTMYO/MinimalistAeroplaneChess
# ============================================================================
class_name FxqEngine
# 继承链：FxqBoard（几何）-> FxqState（状态）-> FxqEnergy（积分）
#         -> FxqMovement（走子骨架）-> FxqItems（道具）-> FxqEngine（结算与回合/入口）
# 外部照旧写 FxqEngine.BASE / FxqEngine.cell_of() / FxqEngine.create_state()，调用方零改动。
extends FxqItems

## 引擎版本号：动作日志 / 回放的状态兼容性校验用；规则语义或序列化口径变化时递增。
const ENGINE_VERSION := 1

## 击败积分：基础 15 + 完成度x0.85，按棋子数系数放大，封顶 100（参考 engine.mjs:51/62-67）


# ---------------------------------------------------------------- 击败矩阵
## 参考 engine.mjs:864-873 的 emptyDefeatMatrix：每个攻击者 -> 每个被击败者（不含自己）
static func empty_defeat_matrix(players: Array) -> Dictionary:
	var m := {}
	for a in players:
		m[int(a)] = {}
		for t in players:
			if int(t) != int(a): m[int(a)][int(t)] = 0
	return m

## 参考 engine.mjs:875-895 的 countBeats：把一批事件里的击败计进【逐对手】矩阵。
## 引擎自己只记 defeats 总数，这张矩阵在参考里也是前端/快照层记的 —— 这里补一个等价实现。
static func count_beats(matrix: Dictionary, events: Array) -> Dictionary:
	for ev in events:
		var ty := str(ev.get("type", ""))
		var atk := int(ev.get("player", 0))
		var tgt := int(ev.get("targetPlayer", 0))
		if ty == "collide":
			# 撞上叠子双方都算被击败：撞的人吃下叠子上所有棋子，叠子主人收下撞上来的那颗
			if not matrix.has(atk) or not matrix.has(tgt): continue
			var ra: Dictionary = matrix[atk]
			var rb: Dictionary = matrix[tgt]
			if ra.has(tgt): ra[tgt] = int(ra[tgt]) + maxi(1, (ev.get("chesses", []) as Array).size())
			if rb.has(atk): rb[atk] = int(rb[atk]) + 1
			continue
		if ty != "beat" and ty != "collision_bonus": continue
		if not matrix.has(atk): continue
		var r2: Dictionary = matrix[atk]
		if not r2.has(tgt): continue
		r2[tgt] = int(r2[tgt]) + (int(ev.get("enemyCount", 1)) if ty == "collision_bonus" else 1)
	return matrix

# ---------------------------------------------------------------- 一次移动
## 取本局的模式实例。模式对象承载所有「经典 vs 欢乐」的差异，
## 公共流程（core/movement.gd）里【一行模式判断都不需要】。
static func mode_of(state: Dictionary):
	return FxqModeHappy.new() if state.get("happy", false) else FxqModeClassic.new()

## 完赛记账（全项目唯一一处）：某位玩家 4 颗全部到达终点时登记名次；
## 第 n-1 家完成时收口结束，最后一家自动垫底（方案 B；参考 engine.mjs 是第一个完成就结束）。
## 【两条走子路径都必须走它】：骰子那一次走子（resolve_move 里 walk 返回 true）
## 与链式奖励走子（欢乐模式 happy_collision 走完、resolve_move 落点结算之后）——
## 否则链式走子完赛的棋子不进 finishOrder，之后被 end_turn 永久跳过。
static func register_finish(state: Dictionary, player: int, events: Array) -> void:
	var all_done := true
	for c in state.players[player].chesses:
		if not c.finished: all_done = false
	if not all_done: return
	var fo: Array = state.get("finishOrder", [])
	if not fo.has(player): fo.append(player)
	if fo.size() >= state.order.size() - 1:
		for pid2 in state.order:
			if not fo.has(pid2): fo.append(pid2)
		state.finishOrder = fo
		state.winner = fo[0]
		state.phase = "ended"
		events.append({"type": "end", "winner": fo[0], "order": fo})
	else:
		state.finishOrder = fo

static func resolve_move(state: Dictionary, player: int, index: int, events: Array) -> void:
	var chess: Dictionary = state.players[player].chesses[index]
	var dice: int = state.dice
	# 起飞
	if chess.pos == BASE:
		chess.pos = LAUNCH
		state.players[player].totalDistance += 1
		events.append({"type": "launch", "player": player, "chess": index, "to": LAUNCH})
		emit_stack(state, player, LAUNCH, events)
		return
	var from_rel: int = chess.pos
	state.players[player].totalDistance += dice
	var mode = mode_of(state)
	# 叠子是否阻挡去路：欢乐模式不阻挡（参考 engine.mjs:439）
	var stack := stack_in_move_path(state, player, from_rel, dice) if mode.blocks_by_stack() else {}
	var stack_crash: bool = not stack.is_empty() and bool(stack.isExactHit)
	var stack_bounce: bool = not stack.is_empty() and bool(stack.needsBounce)
	var overshoot_raw: int = (from_rel + dice - TRACK_END) if from_rel + dice > TRACK_END else 0
	# 超点是否反弹：欢乐模式直接停在终点格（参考 engine.mjs:444）
	var overshoot: int = overshoot_raw if mode.bounces_on_overshoot() else 0
	var forward: int = dice
	if stack_crash or stack_bounce: forward = stack.distance
	elif overshoot_raw > 0: forward = TRACK_END - from_rel
	var back: int = 0
	if stack_bounce: back = mini(int(stack.remaining), from_rel + forward - LAUNCH)
	elif overshoot > 0: back = overshoot
	var bounce_reason = ("stack" if stack_bounce else ("overshoot" if overshoot > 0 else null))
	var blocker = (stack.player if stack_bounce else null)
	var finished := walk(state, player, index, from_rel, forward, back, bounce_reason, blocker, events)
	if finished:
		register_finish(state, player, events)
		return
	if stack_crash:
		# 被撞回家的每颗棋子都按击败结算给撞的人加分（落点要在送回基地之前量）。
		# 遥控骰子撞的同样不给分，和单颗击败口径一致；reward 是应得总额，energy 是实际入账。
		# 参考 engine.mjs:462-477：走 beatReward（含棋子数量系数）并累加 grantEnergy。
		var gain := 0
		var reward := 0
		if str(state.diceItem) != "remote-dice":
			for v in stack.cells:
				var vp: int = state.players[v.player].chesses[v.index].pos
				var each: int = beat_reward(state, vp)
				reward += each
				gain += grant_energy(state, player, each)
		send_home(state, player, index)
		for v in stack.cells: send_home(state, v.player, v.index)
		events.append({"type": "collide", "player": player, "targetPlayer": stack.player,
			"cell": stack.cell, "chesses": stack.cells, "reward": reward, "energy": gain})
		return
	if stack_bounce or overshoot > 0:
		mode.on_stop(state, player, index, int(chess.pos), events)
		return
	# 落点链路交给模式：经典 = 撞人+特殊位+再撞；欢乐 = happy_collision 一次走完
	mode.resolve_landing(state, player, index, events)
	# 链式奖励走子（欢乐模式）可能把棋子走到终点：完赛/名次/胜负记账走【同一处】公共函数
	if bool(state.players[player].chesses[index].finished):
		register_finish(state, player, events)
		return
	emit_stack(state, player, int(chess.pos), events)

# 移植自 ZTMYO/MinimalistAeroplaneChess shared/engine.mjs（AGPL-3.0）

# ================================================================ 回合流程
static func roll_die(rng, max_dice: int = 6) -> int:
	if rng == null: return randi_range(1, max_dice)
	return 1 + int(floor(rng.randf() * float(max_dice)))

static func end_turn(state: Dictionary, events: Array) -> void:
	state.consecutiveSixes = 0
	state.dice = null
	state.diceItem = false
	state.phase = "rolling"
	state.turn = int(state.turn) + 1
	# 跳过已完成的玩家（4 颗全部到达终点就不再参与：不摇骰、不能走子）
	var n_ord: int = state.order.size()
	var idx: int = int(state.currentIndex)
	for _k in n_ord:
		idx = (idx + 1) % n_ord
		if not player_done(state, int(state.order[idx])): break
	# 真正的回合：索引回绕（绕完一圈）才算一回合。
	# 已完赛玩家会被跳过，所以一圈的长度随人数自动变化，索引回绕天然适配。
	if idx <= int(state.currentIndex):
		state.round = int(state.get("round", 1)) + 1
	state.currentIndex = idx
	state.currentPlayer = state.order[idx]
	state.pendingItem = null
	events.append({"type": "turn", "player": state.currentPlayer})

## 执行一个动作。纯函数：不修改传入的 state，返回 {ok, state, events, error}
static func apply(state: Dictionary, player_id: int, action: Dictionary, rng = null) -> Dictionary:
	if state.phase == "ended":
		return {"ok": false, "error": "对局已结束", "events": [], "state": state}
	var next: Dictionary = state.duplicate(true)
	var events: Array = []
	var t: String = action.type
	if int(next.currentPlayer) != player_id:
		return {"ok": false, "error": "当前轮到玩家 %d" % next.currentPlayer, "events": [], "state": state}

	# ---------------------------------------------------------- 掷骰
	if t == "roll":
		if next.phase != "rolling":
			return {"ok": false, "error": "阶段 %s 不接受掷骰" % next.phase, "events": [], "state": state}
		var max_dice: int = int(action.get("maxDice", 6))
		# 参考 engine.mjs:718 用 action.value ?? rollDie()：null 视为未指定。Godot 里 int(null) 会抛错并让 apply 返回 null，必须判空。
		var has_val: bool = action.has("value") and action.value != null
		if has_val and float(action.value) != floor(float(action.value)):
			return {"ok": false, "error": "非法点数", "events": [], "state": state}
		var value: int = int(action.value) if has_val else roll_die(rng, max_dice)
		if value < 1 or value > max_dice:
			return {"ok": false, "error": "非法点数：%d" % value, "events": [], "state": state}
		var used_item := str(action.get("item", ""))
		# 遥控骰子先在激活时买了单，这里只消费激活态；不认这笔账就没法白拿道具
		if used_item == "remote-dice":
			var pend0 = next.pendingItem
			if pend0 == null or str(pend0.item) != "remote-dice" or int(pend0.player) != player_id:
				return {"ok": false, "error": "遥控骰子尚未激活", "events": [], "state": state}
		# 多面骰子在这一掷买下；已经为它激活过就不再收第二遍
		var planned = next.pendingItem
		var already_paid: bool = planned != null and str(planned.item) == "polyhedral-dice" and int(planned.player) == player_id
		var item_cost := 0
		if used_item == "polyhedral-dice" and not already_paid:
			var ch0 := charge_item(next, player_id, "polyhedral-dice")
			if not bool(ch0.ok): return {"ok": false, "error": str(ch0.error), "events": [], "state": state}
			item_cost = int(ch0.cost)
		next.pendingItem = null
		var counts_six: bool = not bool(action.get("noBonus", false))
		next.dice = value
		next.diceItem = false if counts_six else (used_item if used_item != "" else true)
		next.consecutiveSixes = (int(next.consecutiveSixes) + 1) if (counts_six and value == 6) else 0
		# diceItem 可能是 false（普通骰）或 String（道具骰），不能直接和 bool 比 —— 用 typeof 判
		var item_out = next.diceItem if typeof(next.diceItem) == TYPE_STRING else null
		events.append({"type": "dice", "player": player_id, "value": value,
			"item": item_out, "cost": item_cost,
			"sixStreak": next.consecutiveSixes})
		# 连投 3 次 6 惩罚（欢乐模式豁免）
		# 三连6是否惩罚：欢乐模式不惩罚（参考 engine.mjs:746-760）
		if int(next.consecutiveSixes) >= 3 and mode_of(next).punishes_three_sixes():
			var pieces := []
			var cs: Array = next.players[player_id].chesses
			for i in cs.size():
				if cs[i].finished: continue
				send_home(next, player_id, i)
				pieces.append(i)
			events.append({"type": "reset", "player": player_id, "reason": "three-sixes", "pieces": pieces})
			end_turn(next, events)
			return {"ok": true, "state": next, "events": events}
		if int(next.consecutiveSixes) >= 3: next.consecutiveSixes = 0
		if movable_chess(next, player_id, value).is_empty():
			events.append({"type": "skip", "player": player_id, "value": value})
			end_turn(next, events)
			return {"ok": true, "state": next, "events": events}
		next.phase = "selecting"
		return {"ok": true, "state": next, "events": events}

	# ---------------------------------------------------------- 道具
	if t == "item_activate":
		# ★ 参考接受 rolling 与 selecting 两个阶段（engine.mjs:803）。
		#   原来只认 rolling：掷完骰子、还没选子时点道具栏会被引擎拒绝，
		#   而 UI 侧这个阶段是可点可买的（玩家点了没反应，只在战报里留一条报错）。
		if next.phase != "rolling" and next.phase != "selecting":
			return {"ok": false, "error": "阶段 %s 不接受道具" % next.phase, "events": [], "state": state}
		var it := str(action.get("item", ""))
		var ra := activate_item(next, player_id, it, events, rng, action.get("amount", null))
		if not bool(ra.ok): return {"ok": false, "error": str(ra.error), "events": [], "state": state}
		# 盲盒当场结算并【交出回合】；其余只记激活态，等选点/选子落地
		if it == "mysteryBox": end_turn(next, events)
		return {"ok": true, "state": next, "events": events}

	if t == "item_cancel":
		var rc := cancel_item(next, player_id, events)
		if not bool(rc.ok): return {"ok": false, "error": str(rc.error), "events": [], "state": state}
		return {"ok": true, "state": next, "events": events}

	if t == "teleport":
		# 传送门是【掷骰之前】用的动作（买下当即使用，用完交出回合），
		# 所以 rolling 阶段也要接受 —— 之前只认 selecting，AI 买了用不出来会卡死。
		if next.phase != "selecting" and next.phase != "rolling":
			return {"ok": false, "error": "阶段 %s 不接受传送" % next.phase, "events": [], "state": state}
		var pend1 = next.pendingItem
		if pend1 == null or str(pend1.item) != "teleport" or int(pend1.player) != player_id:
			return {"ok": false, "error": "传送门尚未激活", "events": [], "state": state}
		var ci1 := int(action.chessIndex)
		var cs1: Array = next.players[player_id].chesses
		# ★ 参考 engine.mjs:812-817 有两道校验：棋子不存在要报错（而不是下标越界崩），
		#   起始区/已到终点的棋子不能传送。
		if ci1 < 0 or ci1 >= cs1.size():
			return {"ok": false, "error": "棋子 %d 不存在" % ci1, "events": [], "state": state}
		if bool(cs1[ci1].finished) or int(cs1[ci1].pos) == BASE:
			return {"ok": false, "error": "起始区或已完成的棋子无法传送", "events": [], "state": state}
		var from1: int = int(cs1[ci1].pos)
		var to1: int = teleport_spot(next, player_id, from1, rng, action.get("to", null))
		if to1 < 0: return {"ok": false, "error": "没有可用的传送落点", "events": [], "state": state}
		next.pendingItem = null
		next.players[player_id].chesses[ci1].pos = to1
		# 参考 engine.mjs:827：向前传送要累计里程（用于统计；向后传送不扣）
		if to1 > from1: next.players[player_id].totalDistance += to1 - from1
		events.append({"type": "teleport", "player": player_id, "chess": ci1,
			"from": from1, "to": to1})
		# 参考 engine.mjs:822-831：传送只做「改坐标 + 记事件 + 交出回合」，【不做】任何落点结算。
		# 否则传到 rel18/30 这类格子会白拿跳子/飞棋，欢乐模式还会多出参考里不存在的碰撞连锁。
		end_turn(next, events)
		return {"ok": true, "state": next, "events": events}

	# ---------------------------------------------------------- 走子
	if t == "move":
		if next.phase != "selecting":
			return {"ok": false, "error": "阶段 %s 不接受走子" % next.phase, "events": [], "state": state}
		var idx: int = int(action.chessIndex)
		if not movable_chess(next, player_id, int(next.dice)).has(idx):
			return {"ok": false, "error": "棋子 %d 当前不可移动" % idx, "events": [], "state": state}
		var value2: int = int(next.dice)
		resolve_move(next, player_id, idx, events)
		# diceItem 有 false / true / 字符串三态；参考 engine.mjs:783 的判据是 !next.diceItem（JS 真值语义）。
		# ★ GDScript 既不能 String==bool、也没有 bool(String) 构造，所以显式按三态算一次真值：
		#   非空字符串 / true / 其它非空值 = 真 -> 不连投；false / null = 假 -> 连投。
		var item_truthy: bool = false
		match typeof(next.diceItem):
			TYPE_BOOL: item_truthy = bool(next.diceItem)
			TYPE_STRING: item_truthy = str(next.diceItem) != ""
			_: item_truthy = next.diceItem != null
		# 名次判定已在 resolve_move 里做了（带 order）；这里只兜底。
		# winner 一旦产生就必须【短路】后面的连投/换人分支（参考 engine.mjs:780-782），
		# 否则 phase 会被 reroll / end_turn 冲回 rolling —— 假结束，极端情况下整局死局。
		if next.winner != null:
			if next.phase != "ended":
				next.phase = "ended"
				events.append({"type": "end", "winner": next.winner, "order": next.get("finishOrder", [])})
		# ★ 参考 engine.mjs:783 是 value === 6 && !next.diceItem：
		#   原来写 typeof != TYPE_STRING -> true 也算"不是字符串" -> 会连投，与参考相反。
		elif value2 == 6 and not item_truthy:
			next.dice = null
			next.phase = "rolling"
			events.append({"type": "reroll", "player": player_id})
		else:
			end_turn(next, events)
		return {"ok": true, "state": next, "events": events}

	# ---------------------------------------------------------- 跳过
	if t == "skip":
		if next.phase != "rolling" and next.phase != "selecting":
			return {"ok": false, "error": "阶段 %s 不接受跳过" % next.phase, "events": [], "state": state}
		events.append({"type": "pass", "player": player_id, "reason": action.get("reason", null)})
		end_turn(next, events)
		return {"ok": true, "state": next, "events": events}

	return {"ok": false, "error": "未知动作：%s" % t, "events": [], "state": state}

## 预览一次动作的结果（不改动传入状态）。dice 供 AI 试算假想点数
static func preview(state: Dictionary, player_id: int, action: Dictionary, dice = null) -> Dictionary:
	var trial: Dictionary = state.duplicate(true)
	if dice != null:
		trial.currentPlayer = player_id
		trial.phase = "selecting"
		trial.dice = int(dice)
		trial.diceItem = false
	return apply(trial, player_id, action, null)
