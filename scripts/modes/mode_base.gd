# ============================================================================
#  模式接口（默认实现 = 经典模式）
#
#  移植自 ZTMYO/MinimalistAeroplaneChess 的 shared/engine.mjs
#  原项目授权：AGPL-3.0 —— 本文件为衍生作品，同样以 AGPL-3.0 发布
#  原项目：https://github.com/ZTMYO/MinimalistAeroplaneChess
#
#  【为什么要这一层】
#  经典模式与欢乐模式的差异只在少数几个「策略点」上（落点怎么结算、
#  叠子挡不挡路、超点反不反弹、交叉点撞不撞、三连6罚不罚）。
#  把它们抽成钩子，公共流程（core/movement.gd）就【一行模式判断都不需要】。
#
#  【用法】引擎通过 mode_of(state) 拿到一个模式实例，把差异点交给它。
#          钩子默认返回【经典模式】的行为，所以 FxqModeClassic 是空的。
# ============================================================================
class_name FxqModeBase
extends FxqMovement

# ---------------------------------------------------------------- 策略钩子
## 叠子是否阻挡去路（欢乐模式 = false）
func blocks_by_stack() -> bool: return true

## 超点是否反弹（欢乐模式 = false，直接停在终点格）
func bounces_on_overshoot() -> bool: return true

## 三连6是否惩罚（欢乐模式 = false，计数清零后照常连投）
func punishes_three_sixes() -> bool: return true

## 交叉点是否被对家阻挡；返回被占的叠子（空 = 不阻挡）
func cross_blocked(state: Dictionary, player: int) -> Dictionary:
	return opponent_stack_at_cross(state, player)

# ---------------------------------------------------------------- 落点结算
## 棋子在某格「停下」时的结算。经典 = 撞人送回家；欢乐 = 奖励前进（重写这个）
func on_stop(state: Dictionary, player: int, index: int, rel: int, events: Array) -> void:
	on_stop_cell(state, player, index, cell_of(player, rel), events)

## 同上，但直接给格子编号（交叉点等不能用 rel 表示的位置）
func on_stop_cell(state: Dictionary, player: int, index: int, cell, events: Array,
		allow_cross: bool = false) -> void:
	beat_at_cell(state, cell, player, events, allow_cross)

## 飞棋前的阻挡判定。返回 true = 已被处理（本次飞棋中止）
func fly_guard(state: Dictionary, player: int, index: int, target_rel: int,
		target_cell, events: Array) -> bool:
	var cross_stack := cross_blocked(state, player)
	if not cross_stack.is_empty():
		events.append({"type": "blocked", "reason": "cross-stack", "player": player,
			"chess": index, "cell": cross_cell_of(player), "targetPlayer": cross_stack.player})
		return true
	var tgt_stack := stack_at_cell(state, target_cell)
	if not tgt_stack.is_empty() and int(tgt_stack.player) != player:
		# 撞上叠子：双方都回基地（参考 engine.mjs 的 collide 分支）
		send_home(state, player, index)
		for v in tgt_stack.cells: send_home(state, v.player, v.index)
		events.append({"type": "collide", "player": player, "targetPlayer": tgt_stack.player,
			"cell": target_cell, "chesses": tgt_stack.cells})
		return true
	return false

# ---------------------------------------------------------------- 落点链路
## 一次行进走完后的完整落点结算。
## 经典 = 落点撞人 + 特殊位（跳子/飞棋）+ 再撞一次；
## 欢乐 = 整条链路（含连锁）由 happy_collision 一次走完（重写这个）。
func resolve_landing(state: Dictionary, player: int, index: int, events: Array) -> void:
	var rel: int = int(state.players[player].chesses[index].pos)
	on_stop(state, player, index, rel, events)
	handle_special_positions(state, player, index, rel, events, self)
	on_stop(state, player, index, int(state.players[player].chesses[index].pos), events)

# ---------------------------------------------------------------- 经典模式专属
## 撞机：把落点上的敌方单颗棋子送回基地
func beat_at_cell(state: Dictionary, cell, by_player: int, events: Array,
		allow_cross: bool = false) -> void:
	if cell == null: return
	var tgt := enemy_at_cell(state, cell, by_player)
	if tgt.is_empty(): return
	if not beatable(cell, allow_cross): return
	# 被击败棋子当时的落点：击败积分按对手损失的完成度算，得在送回基地之前量下来
	var victim_pos: int = state.players[tgt.player].chesses[tgt.index].pos
	# 遥控骰子能指定点数，击败不给积分（避免刷分）；多面骰子照常计分（参考 engine.mjs:264-267）
	var is_remote: bool = str(state.diceItem) == "remote-dice"
	var reward: int = 0 if is_remote else mini(beat_reward(state, victim_pos), ENERGY_MAX)
	send_home(state, tgt.player, tgt.index)
	state.players[by_player].defeats += 1
	var gain: int = 0 if is_remote else grant_energy(state, by_player, reward)
	events.append({"type": "beat", "player": by_player, "targetPlayer": tgt.player,
		"chess": tgt.index, "cell": cell, "itemRoll": state.diceItem,
		"reward": reward, "energy": gain})

## 对家是否占住了自己的交叉点
func opponent_stack_at_cross(state: Dictionary, player: int) -> Dictionary:
	var st := stack_at_cell(state, cross_cell_of(player))
	if st.is_empty(): return {}
	return st if int(st.player) == int(OPPOSITE[player]) else {}
