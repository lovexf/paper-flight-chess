# ============================================================================
#  传送门落点
#
#  移植自 ZTMYO/MinimalistAeroplaneChess 的 shared/engine.mjs（AGPL-3.0）
#  原项目：https://github.com/ZTMYO/MinimalistAeroplaneChess
#
#  【规则】可选落点 = 1..50 中【没有棋子】且不是原位的格子；
#          由引擎做【三段加权随机】：近段 5 / 中段 3 / 远段 2。
# ============================================================================
class_name FxqTeleport
extends FxqMovement

## 可选落点：空位，按距离由近到远（参考 engine.mjs:219-228）
static func teleport_spots(state: Dictionary, player_id: int, from: int) -> Array:
	var spots := []
	for to in range(1, 51):
		if to == from: continue
		if cell_occupied(state, cell_of(player_id, to)): continue
		spots.append({"to": to, "distance": absi(to - from)})
	spots.sort_custom(func(a, b): return int(a.distance) < int(b.distance))
	return spots

## 落点：三段加权随机（参考 engine.mjs:230-243）。返回 -1 = 无可用落点
## forced_to：回放/联机下由动作显式指定的落点（null = 沿用原来的三段加权随机逻辑）
static func teleport_spot(state: Dictionary, player_id: int, from: int, rng, forced_to = null) -> int:
	var spots := teleport_spots(state, player_id, from)
	if forced_to != null:
		# 显式落点必须仍在「当前合法落点集」内（空位、非原位）。
		# 不在集合内一律视同无可用落点（-1），交回调用方按“没有可用的传送落点”报错。
		var forced: int = int(forced_to)
		for sp in spots:
			if int(sp.to) == forced: return forced
		return -1
	if spots.is_empty(): return -1
	var seg: int = int(ceil(float(spots.size()) / 3.0))
	var total := 0.0
	for i in spots.size():
		total += float(_weight_of(i, seg))
	var roll: float = (rng.randf() if rng != null else randf()) * total
	for i in spots.size():
		roll -= float(_weight_of(i, seg))
		if roll <= 0.0: return int(spots[i].to)
	return int(spots[spots.size() - 1].to)

static func _weight_of(index: int, seg: int) -> int:
	if index < seg: return 5
	if index < seg * 2: return 3
	return 2
