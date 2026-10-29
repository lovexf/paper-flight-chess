# ============================================================================
#  棋盘几何（与模式无关的公共层）
#
#  移植自 ZTMYO/MinimalistAeroplaneChess 的 shared/engine.mjs
#  原项目授权：AGPL-3.0 —— 本文件为衍生作品，同样以 AGPL-3.0 发布
#  原项目：https://github.com/ZTMYO/MinimalistAeroplaneChess
#
#  【职责】只做「位置」相关的纯计算：常量、编号换算、进度百分比。
#          不碰状态、不碰回合、不碰任何模式差异。
# ============================================================================
class_name FxqBoard
extends RefCounted

# ---------------------------------------------------------------- 位置常量
const BASE := -1            # 基地
const LAUNCH := 0           # 起飞点
const RING_LEN := 52        # 外圈格数
const RUNWAY_START := 51    # 跑道起始相对位置
const TRACK_END := 56       # 行进终点（第 56 步 = 终点）
const RUNWAY_BASE := 100    # 跑道格编号基址
const CROSS_BASE := 900     # 交叉点编号基址
const HOME := 999           # 终点

const PLAYERS := [1, 2, 3, 4]
const PIECES_PER_PLAYER := 4

const RING_ENTRY := {1: 1, 2: 14, 3: 27, 4: 40}
const OPPOSITE := {1: 3, 2: 4, 3: 1, 4: 2}
const JUMP_RELS := [2, 6, 10, 14, 18, 22, 26, 30, 34, 38, 42, 46]
const JUMP_STEP := 4
const FLY_ENTRY := 18
const FLY_EXIT := 30
const CROSS_STEP := 3
const HAPPY_CHAIN_LIMIT := 32   # 欢乐模式连锁上限

# ---------------------------------------------------------------- 位置换算
## 跑道格编号。第 CROSS_STEP 格是交叉点，第 6 格是终点
static func runway_cell(player: int, step: int) -> int:
	if step == CROSS_STEP: return cross_cell_of(player)
	if step == 6: return HOME
	return RUNWAY_BASE + (player - 1) * 10 + step

## 交叉点：1/3 号共用一个，2/4 号共用另一个
static func cross_cell_of(player: int) -> int:
	return CROSS_BASE + (0 if (player == 1 or player == 3) else 1)

## 相对位置 -> 全体共用的格子编号；null 表示不参与同格判定
static func cell_of(player: int, rel: int):
	if rel == BASE: return null
	if rel == LAUNCH: return LAUNCH
	if rel >= 1 and rel <= 50:
		return ((int(RING_ENTRY[player]) - 1 + (rel - 1)) % RING_LEN) + 1
	if rel >= RUNWAY_START and rel <= TRACK_END:
		return runway_cell(player, rel - RUNWAY_START + 1)
	return null

static func is_jump_rel(rel: int) -> bool:
	return JUMP_RELS.has(rel)

static func next_jump_rel(rel: int):
	return (rel + JUMP_STEP) if is_jump_rel(rel) else null

static func beatable(cell, allow_cross: bool = false) -> bool:
	if cell == null: return false
	if allow_cross and int(cell) >= CROSS_BASE and int(cell) < CROSS_BASE + 2: return true
	return int(cell) >= LAUNCH and int(cell) <= RING_LEN

## 棋子完成度百分比（0~100）：外圈 0-50 + 终点航道 51-56，共 57 格
static func chess_progress(pos: int, finished: bool = false) -> float:
	if finished: return 100.0
	if pos == BASE: return 0.0
	return clampf(minf(float(pos), float(TRACK_END)) / float(TRACK_END + 1) * 100.0, 0.0, 100.0)
