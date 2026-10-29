# ============================================================================
#  对局状态与同格查询（与模式无关的公共层）
#
#  移植自 ZTMYO/MinimalistAeroplaneChess 的 shared/engine.mjs
#  原项目授权：AGPL-3.0 —— 本文件为衍生作品，同样以 AGPL-3.0 发布
#  原项目：https://github.com/ZTMYO/MinimalistAeroplaneChess
#
#  【职责】状态的构造与"查询"：谁在哪一格、能否移动、叠子在哪、送回基地。
#          不做任何走子结算，也不含模式差异。
# ============================================================================
class_name FxqState
extends FxqBoard

# ---------------------------------------------------------------- 状态
static func create_state(players: Array = PLAYERS, pieces: int = PIECES_PER_PLAYER,
		happy: bool = false, skill: bool = false, launch_values: Array = [2, 4, 6],
		start_energy: int = 0) -> Dictionary:
	var st := {
		"order": players.duplicate(), "currentIndex": 0, "currentPlayer": players[0],
		"phase": "rolling", "dice": null, "diceItem": false, "pendingItem": null,
		"consecutiveSixes": 0, "turn": 0, "winner": null,
		"round": 1,                        # 真正的回合数（所有活跃玩家各动一次 = 1 回合）
		"finishOrder": [],                 # 完成名次（第 1 个到第 n 个）
		"happy": happy, "skillMode": skill, "players": {}, "energy": {},
		"launchValues": launch_values,          # ★ 只有摇到这些点数才能起飞
	}
	for pid in players:
		var cs := []
		for i in pieces:
			cs.append({"pos": BASE, "finished": false})
		st.players[pid] = {"id": pid, "chesses": cs, "totalDistance": 0, "defeats": 0}
		st.energy[pid] = clampi(start_energy, 0, 100)   # 起始积分（上限同 FxqEnergy.ENERGY_MAX）
	return st

## 该点数下可动的棋子索引
static func movable_chess(state: Dictionary, player: int, dice: int) -> Array:
	# ★ 起飞点数可配置（设置页逐点开关），但白名单只覆盖 1~6。
	#   参考是「偶数即可起飞」（engine.mjs:146 dice % 2 === 0）—— 道具模式的多面骰
	#   能摇出 8/10/12，它们同样是偶数、同样能起飞。原来白名单判 false -> 引擎直接 skip，
	#   玩家摇到 8/10/12 会白丢一手（"明明摇了大点却什么都没发生"）。
	var lv: Array = state.get("launchValues", [2, 4, 6])
	var can_launch: bool = lv.has(dice) or (dice > 6 and dice % 2 == 0)
	var out := []
	var cs: Array = state.players[player].chesses
	for i in cs.size():
		var c: Dictionary = cs[i]
		if c.finished: continue
		if c.pos == BASE:
			if can_launch: out.append(i)
		elif c.pos >= LAUNCH and c.pos < TRACK_END:
			out.append(i)
	return out

# ---------------------------------------------------------------- 同格查询
static func stack_at_cell(state: Dictionary, cell) -> Dictionary:
	if cell == null: return {}
	for pid in state.order:
		if not state.players.has(pid): continue
		var cells := []
		var cs: Array = state.players[pid].chesses
		for i in cs.size():
			var c: Dictionary = cs[i]
			if c.finished or c.pos == BASE: continue
			if cell_of(pid, c.pos) == cell: cells.append({"player": pid, "index": i})
		if cells.size() >= 2: return {"player": pid, "cell": cell, "cells": cells, "count": cells.size()}
	return {}

static func enemy_at_cell(state: Dictionary, cell, exclude: int) -> Dictionary:
	if cell == null: return {}
	for pid in state.order:
		if pid == exclude or not state.players.has(pid): continue
		var cs: Array = state.players[pid].chesses
		for i in cs.size():
			var c: Dictionary = cs[i]
			if c.finished or c.pos == BASE: continue
			if cell_of(pid, c.pos) == cell:
				return {"player": pid, "index": i}
	return {}

## 同一格上某位对手的【全部】棋子（欢乐模式按颗数算奖励，因此要拿全）
## 参考 engine.mjs:186-199：找到第一个有棋子的对手就返回，不跨玩家合并
static func enemies_at_cell(state: Dictionary, cell, exclude: int) -> Array:
	if cell == null: return []
	for pid in state.order:
		if pid == exclude or not state.players.has(pid): continue
		var found := []
		var cs: Array = state.players[pid].chesses
		for i in cs.size():
			var c: Dictionary = cs[i]
			if c.finished or c.pos == BASE: continue
			if cell_of(pid, c.pos) == cell: found.append({"player": pid, "index": i})
		if not found.is_empty(): return found
	return []

## 目标格是否已被任意棋子占用（传送门要求落点为空位）
static func cell_occupied(state: Dictionary, cell) -> bool:
	if cell == null: return false
	for pid in state.order:
		if not state.players.has(pid): continue
		for c in state.players[pid].chesses:
			if c.finished or c.pos == BASE: continue
			if cell_of(pid, c.pos) == cell: return true
	return false

static func send_home(state: Dictionary, player: int, index: int) -> void:
	var c: Dictionary = state.players[player].chesses[index]
	c.pos = BASE
	c.finished = false

## 移动路径上的敌方叠子（阻挡判定）
static func stack_in_move_path(state: Dictionary, player: int, from_rel: int, steps: int) -> Dictionary:
	if from_rel < LAUNCH or from_rel >= RUNWAY_START: return {}
	for step in range(1, steps + 1):
		var rel := from_rel + step
		if rel > 50: break
		var st := stack_at_cell(state, cell_of(player, rel))
		if not st.is_empty() and int(st.player) != player:
			return {"rel": rel, "cell": cell_of(player, rel), "distance": step,
				"remaining": steps - step, "isExactHit": step == steps,
				"needsBounce": step < steps, "player": st.player, "cells": st.cells}
	return {}

static func stack_in_jump_path(state: Dictionary, player: int, from_rel: int, to_rel: int) -> Dictionary:
	if from_rel <= LAUNCH or to_rel <= LAUNCH: return {}
	var lo: int = mini(from_rel, to_rel)
	var hi: int = maxi(from_rel, to_rel)
	for rel in range(lo + 1, hi):
		var st := stack_at_cell(state, cell_of(player, rel))
		if not st.is_empty() and int(st.player) != player:
			return {"rel": rel, "cell": cell_of(player, rel), "player": st.player}
	return {}

## 该玩家 4 颗是否全部到达终点
static func player_done(state: Dictionary, pid: int) -> bool:
	for c in state.players[pid].chesses:
		if not bool(c.finished): return false
	return true
