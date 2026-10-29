# ============================================================================
#  道具的购买 / 激活 / 取消
#
#  移植自 ZTMYO/MinimalistAeroplaneChess 的 shared/engine.mjs（AGPL-3.0）
#  原项目：https://github.com/ZTMYO/MinimalistAeroplaneChess
#
#  【流程】activate = 先扣费（charge），再记激活态（pendingItem）。
#          真正的效果等选点/选子落地才发生 —— 只有盲盒是当场结算并交出回合。
#          取消（cancel）会把预扣的积分原样退回，免得选不出落点时白花钱。
# ============================================================================
class_name FxqItems
extends FxqTeleport

## 价目表（唯一一份，AI 决策与界面提示都读它）
const ITEM_COSTS := {
	"remote-dice": 70,
	"polyhedral-dice": 50,
	"teleport": 40,
	"mysteryBox": 15,
}

## 扣费。返回 {ok, cost, error}
static func charge_item(state: Dictionary, player: int, item: String) -> Dictionary:
	if not state.skillMode: return {"ok": false, "error": "本局未开启道具模式"}
	if not ITEM_COSTS.has(item): return {"ok": false, "error": "未知道具 " + item}
	var cost: int = int(ITEM_COSTS[item])
	var en: int = int(state.energy.get(player, 0))
	if en < cost: return {"ok": false, "error": "积分不足：%s 需要 %d" % [item, cost]}
	# 盲盒是落后方的翻盘手段，积分够高时禁止再摇
	if item == "mysteryBox" and en >= MYSTERY_BOX_MAX:
		return {"ok": false, "error": "积分已达 %d，盲盒不可使用" % MYSTERY_BOX_MAX}
	state.energy[player] = en - cost
	return {"ok": true, "cost": cost, "error": ""}

## 激活道具。盲盒当场开盒并交出回合；其余只记激活态。返回 {ok, cost, error}
## forced_amount：回放/联机下由动作显式指定的盲盒金额（null = 沿用原来的引擎随机逻辑）
static func activate_item(state: Dictionary, player: int, item: String,
		events: Array, rng, forced_amount = null) -> Dictionary:
	# ★ 显式金额必须在 charge_item 【之前】校验：否则非法值会先扣积分再报错，
	#   调用方拿到 ok=false 以为状态没动，实际已经扣费（回放/联机会直接分叉）。
	if forced_amount != null:
		var forced: int = int(forced_amount)
		if forced < 0 or forced > MYSTERY_BOX_MAX:
			return {"ok": false, "error": "非法盲盒金额：%d" % forced}
	var ch := charge_item(state, player, item)
	if not bool(ch.ok): return ch
	var cost: int = int(ch.cost)
	if item == "mysteryBox":
		var amount: int
		if forced_amount != null:
			amount = int(forced_amount)
		else:
			# 开盒数值由【引擎】摇，客户端只负责演出，刷新/回放都不会对不上号
			amount = int(floor((rng.randf() if rng != null else randf()) * float(MYSTERY_BOX_MAX + 1)))
		var gain: int = grant_energy(state, player, amount)
		events.append({"type": "mystery_box", "player": player, "cost": cost,
			"amount": amount, "energy": gain})
		return {"ok": true, "cost": cost, "error": ""}
	state.pendingItem = {"player": player, "item": item, "cost": cost}
	events.append({"type": "item_activate", "player": player, "item": item, "cost": cost})
	return {"ok": true, "cost": cost, "error": ""}

## 取消已激活的道具：预扣的积分原样退回
static func cancel_item(state: Dictionary, player: int, events: Array) -> Dictionary:
	var pending = state.pendingItem
	if pending == null or int(pending.player) != player:
		return {"ok": false, "error": "没有待取消的道具"}
	var refund: int = int(pending.cost)
	grant_energy(state, player, refund)
	events.append({"type": "item_cancel", "player": player, "item": str(pending.item),
		"refund": refund})
	state.pendingItem = null
	return {"ok": true, "error": ""}
