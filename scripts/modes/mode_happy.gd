# ============================================================================
#  欢乐模式
#
#  移植自 ZTMYO/MinimalistAeroplaneChess 的 shared/engine.mjs（AGPL-3.0）
#  原项目：https://github.com/ZTMYO/MinimalistAeroplaneChess
#
#  【规则差异】把「击败」改成「碰撞奖励」：
#    - 落在敌方棋子上：对方【不回基地】，改为自己【奖励前进】
#    - 奖励步数 = max(2, 敌方颗数 * 2)  -> 撞 3 颗给 6 步
#    - 可以【连锁】：奖励步数走到的新落点再撞就继续
#    - 叠子不阻挡 / 超点不反弹 / 交叉点不撞机 / 三连6不惩罚
#
#  【实现要点】不要重写 on_stop —— 那会造成无限递归：
#      happy_collision -> handle_special_positions -> jump/fly -> on_stop -> ...
#    参考实现里 beatAtCell 在欢乐模式是【空操作】，整条落点链路由
#    happyCollision 从 resolve_landing 单独走一次。本文件照此结构。
# ============================================================================
class_name FxqModeHappy
extends FxqModeClassic

# 连锁上限 HAPPY_CHAIN_LIMIT 继承自 FxqBoard（=32）

# ---------------------------------------------------------------- 策略钩子
func blocks_by_stack() -> bool: return false        # 叠子不阻挡（参考 engine.mjs:439）
func bounces_on_overshoot() -> bool: return false   # 超点不反弹（参考 engine.mjs:444）
func punishes_three_sixes() -> bool: return false   # 三连6不惩罚（参考 engine.mjs:746）
func cross_blocked(state: Dictionary, player: int) -> Dictionary: return {}   # 交叉点不撞机
func fly_guard(state: Dictionary, player: int, index: int, target_rel: int,
		target_cell, events: Array) -> bool: return false               # 飞棋畅通无阻

## 欢乐模式没有「停下就撞人」，所以这个钩子是【空操作】
func on_stop(state: Dictionary, player: int, index: int, rel: int, events: Array) -> void:
	pass

## 落点入口的【第二个口子】，必须和 on_stop 一起空掉：
## movement.gd:100 的飞棋交叉点补刀直接传格子编号，走 mode_base.gd:39-41
## 的 on_stop_cell -> beat_at_cell，绕开了 on_stop。只覆写 on_stop 会漏掉它，
## 导致欢乐模式下飞棋仍把交叉点上的对家撞回基地、并污染 defeats。
## 参考 engine.mjs:254-256 是让 beatAtCell 在 state.happy 时直接 return，
## 一次性关掉【所有】击败入口；这里等价地把两个落点入口都覆写成空实现。
func on_stop_cell(state: Dictionary, player: int, index: int, cell, events: Array,
		allow_cross: bool = false) -> void:
	pass

# ---------------------------------------------------------------- 落点链路
func resolve_landing(state: Dictionary, player: int, index: int, events: Array) -> void:
	happy_collision(state, player, index, events)

## 某个「停下」的格子上的碰撞：有人就记账并给出一条事件，没有返回空字典
func take_happy_collision(state: Dictionary, player: int, rel: int) -> Dictionary:
	var cell = cell_of(player, rel)
	var enemies := enemies_at_cell(state, cell, player)
	if enemies.is_empty(): return {}
	state.players[player].defeats += enemies.size()
	# 撞几颗给几份积分；遥控骰子撞到人一律不给分（与常规击败同口径）
	var reward: int = 0
	if state.skillMode and str(state.diceItem) != "remote-dice":
		reward = int(HAPPY_BONUS_PER_ENEMY) * enemies.size()
	var e0: Dictionary = enemies[0]
	return {
		"type": "collision_bonus", "player": player,
		"targetPlayer": e0.player, "targetChess": e0.index,
		"cell": cell, "enemyCount": enemies.size(),
		"steps": maxi(2, enemies.size() * 2),
		"reward": reward,
		"energy": grant_energy(state, player, reward) if reward > 0 else 0,
	}

## 欢乐模式的落点结算：不送人回基地，改为「碰撞奖励」。
## 落点、跳子终点、飞棋终点各判一次；奖励步数攒到跳子/飞棋走完之后一起走，
## 走到的新落点上再撞就继续连锁（参考 engine.mjs:300-343）。
func happy_collision(state: Dictionary, player: int, index: int, events: Array) -> void:
	for _guard in HAPPY_CHAIN_LIMIT:
		var chess: Dictionary = state.players[player].chesses[index]
		if chess.finished: return
		var steps := 0
		var landed := take_happy_collision(state, player, int(chess.pos))
		if not landed.is_empty():
			events.append(landed)
			steps += int(landed.steps)

		var mark: int = events.size()
		handle_special_positions(state, player, index, int(chess.pos), events, self)

		# 跳子终点、飞棋终点上的碰撞，补在把棋子送过去的那条动作【后面】。
		# 记账按「停下」的先后顺序（积分封顶要看先后），事件倒着插回去。
		var stops: Array = []
		for i in range(mark, events.size()):
			var ev: Dictionary = events[i]
			if str(ev.type) == "jump" or str(ev.type) == "fly":
				stops.append({"at": i, "rel": int(ev.to), "hit": {}})
		for st2 in stops:
			var hit := take_happy_collision(state, player, int(st2.rel))
			if hit.is_empty(): continue
			st2["hit"] = hit
			steps += int(hit.steps)
		for i in range(stops.size() - 1, -1, -1):
			if not (stops[i].hit as Dictionary).is_empty():
				events.insert(int(stops[i].at) + 1, stops[i].hit)

		if steps <= 0: return
		var from_rel: int = int(state.players[player].chesses[index].pos)
		# 终点钳制：奖励步数越过 TRACK_END 时只走到终点，由 walk 置 finished 并发 finish 事件。
		# 不钳制会把棋子推到 57+（cell_of=null、finished=false）→ 该棋子永久不可动、也永远不能完赛。
		var forward: int = mini(steps, maxi(0, TRACK_END - from_rel))
		if walk(state, player, index, from_rel, forward, 0, null, null, events): return
