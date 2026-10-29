# ============================================================================
#  走子骨架（经典模式与欢乐模式【完全共用】）
#
#  移植自 ZTMYO/MinimalistAeroplaneChess 的 shared/engine.mjs
#  原项目授权：AGPL-3.0 —— 本文件为衍生作品，同样以 AGPL-3.0 发布
#  原项目：https://github.com/ZTMYO/MinimalistAeroplaneChess
#
#  【职责】与模式无关的行进动作：逐格行走、叠子播报。
#          【不含】任何 if state.happy / beat_at_cell —— 那些是模式差异，
#          由 modes/ 下的模式类提供（见第 0.4 步）。
# ============================================================================
class_name FxqMovement
extends FxqEnergy

## 直线行走（含回退）。返回是否到达终点
static func walk(state: Dictionary, player: int, index: int, from_rel: int,
		forward: int, back: int, bounce_reason, blocker, events: Array) -> bool:
	var chess: Dictionary = state.players[player].chesses[index]
	var path := []
	var rel := from_rel
	for i in forward:
		rel += 1
		path.append({"rel": rel, "cell": cell_of(player, rel)})
	var finished := rel == TRACK_END and back == 0
	var i2 := 0
	while i2 < back and rel > LAUNCH:
		rel -= 1
		path.append({"rel": rel, "cell": cell_of(player, rel)})
		i2 += 1
	chess.pos = rel
	events.append({"type": "walk", "player": player, "chess": index, "from": from_rel,
		"to": rel, "path": path, "bounced": back > 0, "bounceReason": bounce_reason,
		"bounceSteps": back, "blocker": blocker})
	if finished:
		chess.finished = true
		events.append({"type": "finish", "player": player, "chess": index})
	return finished

## 叠子播报
static func emit_stack(state: Dictionary, player: int, rel: int, events: Array) -> void:
	var cell = cell_of(player, rel)
	if cell == null or int(cell) == HOME: return
	if int(cell) == LAUNCH: return
	var idx := []
	var cs: Array = state.players[player].chesses
	for i in cs.size():
		var c: Dictionary = cs[i]
		if c.finished or c.pos == BASE: continue
		if cell_of(player, c.pos) == cell: idx.append(i)
	if idx.size() >= 2:
		events.append({"type": "stack", "player": player, "cell": cell,
			"chesses": idx, "count": idx.size()})

# ---------------------------------------------------------------- 跳子 / 飞棋
# 这三个函数是【经典与欢乐完全共用】的流程骨架 ——
# 里面【没有任何 if state.happy】，差异一律通过传进来的 mode 钩子表达。

static func jump(state: Dictionary, player: int, index: int, target_rel: int,
		events: Array, mode) -> void:
	var chess: Dictionary = state.players[player].chesses[index]
	var from_rel: int = chess.pos
	var target_cell = cell_of(player, target_rel)
	var in_path := stack_in_jump_path(state, player, from_rel, target_rel)
	if not in_path.is_empty():
		events.append({"type": "blocked", "reason": "jump-stack-in-path", "player": player,
			"chess": index, "cell": in_path.cell, "targetPlayer": in_path.player})
		mode.on_stop(state, player, index, from_rel, events)
		return
	var tgt_stack := stack_at_cell(state, target_cell)
	if not tgt_stack.is_empty() and int(tgt_stack.player) != player:
		events.append({"type": "blocked", "reason": "jump-target-stack", "player": player,
			"chess": index, "cell": target_cell, "targetPlayer": tgt_stack.player})
		mode.on_stop(state, player, index, from_rel, events)
		return
	mode.on_stop(state, player, index, from_rel, events)
	events.append({"type": "jump", "player": player, "chess": index,
		"from": from_rel, "to": target_rel, "path": [from_rel, target_rel]})
	chess.pos = target_rel
	state.players[player].totalDistance += target_rel - from_rel
	mode.on_stop(state, player, index, target_rel, events)

static func fly(state: Dictionary, player: int, index: int, target_rel: int,
		events: Array, mode) -> void:
	var chess: Dictionary = state.players[player].chesses[index]
	var from_rel: int = chess.pos
	var target_cell = cell_of(player, target_rel)
	if mode.fly_guard(state, player, index, target_rel, target_cell, events):
		return
	events.append({"type": "fly", "player": player, "chess": index,
		"from": from_rel, "to": target_rel, "path": [from_rel, target_rel]})
	chess.pos = target_rel
	state.players[player].totalDistance += target_rel - from_rel
	# 交叉点是两两共用的（1/3、2/4），对方可能根本不在局中
	var opp: int = int(OPPOSITE[player])
	if state.players.has(opp):
		var at_cross := false
		for c in state.players[opp].chesses:
			if not c.finished and c.pos == RUNWAY_START + CROSS_STEP - 1: at_cross = true
		if at_cross:
			mode.on_stop_cell(state, player, index, cross_cell_of(player), events, true)
	mode.on_stop(state, player, index, target_rel, events)

## 落点特殊格处理：跳子 / 飞棋 / 交叉点阻挡。返回是否触发了特殊处理
static func handle_special_positions(state: Dictionary, player: int, index: int,
		rel: int, events: Array, mode) -> bool:
	var cross_stack: Dictionary = mode.cross_blocked(state, player)
	var blocked := not cross_stack.is_empty()
	if rel == 14:
		jump(state, player, index, rel + JUMP_STEP, events, mode)
		if blocked:
			events.append({"type": "blocked", "reason": "cross-stack", "player": player,
				"chess": index, "cell": cross_cell_of(player), "targetPlayer": cross_stack.player})
			return true
		if int(state.players[player].chesses[index].pos) == FLY_ENTRY:
			fly(state, player, index, FLY_EXIT, events, mode)
		return true
	if rel == FLY_ENTRY:
		mode.on_stop(state, player, index, rel, events)
		if blocked:
			events.append({"type": "blocked", "reason": "cross-stack", "player": player,
				"chess": index, "cell": cross_cell_of(player), "targetPlayer": cross_stack.player})
			jump(state, player, index, rel + JUMP_STEP, events, mode)
			return true
		fly(state, player, index, FLY_EXIT, events, mode)
		if int(state.players[player].chesses[index].pos) == FLY_EXIT:
			jump(state, player, index, FLY_EXIT + JUMP_STEP, events, mode)
		return true
	var target = next_jump_rel(rel)
	if target != null:
		jump(state, player, index, int(target), events, mode)
		return true
	return false
