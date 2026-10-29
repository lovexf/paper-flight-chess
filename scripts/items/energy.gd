# ============================================================================
#  积分记账（道具模式的经济系统）
#
#  移植自 ZTMYO/MinimalistAeroplaneChess 的 shared/engine.mjs
#  原项目授权：AGPL-3.0 —— 本文件为衍生作品，同样以 AGPL-3.0 发布
#  原项目：https://github.com/ZTMYO/MinimalistAeroplaneChess
#
#  【职责】只有一件事：积分怎么算、怎么加。
#          积分【只在道具模式存在】，规则一律由引擎算（参考 engine.mjs:35-67）。
# ============================================================================
class_name FxqEnergy
extends FxqState

const ENERGY_MAX := 100          # 积分上限
const ENERGY_BASE := 15          # 击败保底积分
const ENERGY_PROGRESS_COEF := 0.85
const HAPPY_BONUS_PER_ENEMY := 20
const MYSTERY_BOX_MAX := 40

## 棋子数量系数：人越少每颗越值钱
const PIECE_MULT := {2: 1.35, 3: 1.15, 4: 1.0}

## 击败积分：基础 15 + 完成度x0.85，按棋子数系数放大，封顶 100（参考 engine.mjs:61-67）
static func beat_reward(state: Dictionary, victim_pos: int) -> int:
	var n: int = 4
	for pid in state.order:
		if state.players.has(pid):
			n = state.players[pid].chesses.size()
			break
	var mult: float = float(PIECE_MULT.get(n, 1.0))
	return int(round(minf((float(ENERGY_BASE) + chess_progress(victim_pos) * ENERGY_PROGRESS_COEF) * mult,
		float(ENERGY_MAX))))

## 加分（仅道具模式生效，封顶 100）。返回【实际到账数】（封顶后的增量），不是总额
static func grant_energy(state: Dictionary, player: int, amount: int) -> int:
	if not state.skillMode or amount <= 0: return 0
	var before: int = int(state.energy[player])
	var after: int = mini(before + amount, ENERGY_MAX)
	state.energy[player] = after
	return after - before
