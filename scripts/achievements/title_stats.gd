# ============================================================================
#  称号统计（per-game，事件驱动）
#
#  移植自 feixinqi-web/frontend/js/gameState.js 的 titleStats / defeatCounts /
#  diceStatistics / totalDistance / progressHistory，以及 enginePlayback.js
#  里「引擎事件 -> gameState.recordXxx」的那张映射表。
#  原项目：https://github.com/ZTMYO/MinimalistAeroplaneChess（AGPL-3.0）
#
#  【用法】
#    var ts := TitleStats.new([1, 2, 3, 4], 4)
#    ts.apply_events(res.events, st)      # 每批事件后调用，st 是引擎状态（可选）
#    ts.value("ones", 1)                  # 只读访问器
#
#  【state 的两层】
#    公开层：FAMILIES 引用的全部统计字段 + defeat_counts / dice_six_counts /
#            total_distance / progress_history / first_* / is_normal_game_end。
#    内部层：state["_rt"]，只放「连击 / 复仇窗口 / 出机场窗口 / 棋子追踪」这类
#            跨批次运行时，不参与称号判定，也不该被存档。
#
#  【事件 -> 统计】映射照抄 enginePlayback.js:547-657 的 handleEvent，
#  事件类型见 scripts/engine.gd 与 core/movement.gd、modes/*.gd 的 events.append。
# ============================================================================
class_name TitleStats
extends RefCounted

const Defs = preload("res://scripts/achievements/title_defs.gd")

## 公开统计快照（可直接存档 / 传给 TitleManager）
var state: Dictionary

## 计数型字段（玩家 -> 数值），初值 0
const COUNTER_FIELDS := [
	"max_consecutive_ones",
	"max_consecutive_sixes",
	"max_consecutive_no_takeoff",
	"max_move_distance",
	"bounce_steps",
	"max_beats_in_move",
	"max_collide_in_move",
	"max_teleport_distance",
	"mystery_box_max",
	"skill_use_count",
	"block_count",
	"polyhedral_max",
	"runway_kills",
	"airport_rekt",
	"oriole_kills",
	"revenge_kills",
	"petty_teleports",
	"dice_six_counts",
	"total_distance",
]

## 取最小值型字段（玩家 -> 数值），初值 99
const MIN_FIELDS := ["mystery_box_min", "polyhedral_min"]

## 进度快照上限（参考 gameState.MAX_PROGRESS_HISTORY）
const MAX_PROGRESS_HISTORY := 500

func _init(players: Array = [1, 2, 3, 4], piece_count: int = 4) -> void:
	state = new_state(players, piece_count)

# ---------------------------------------------------------------- 构造 / 重置
## 新建一份统计快照
static func new_state(players: Array = [1, 2, 3, 4], piece_count: int = 4) -> Dictionary:
	var ps: Array = players.duplicate()
	var st := {
		"first_finished_player": null,
		"first_beater_player": null,
		"is_normal_game_end": false,
		"progress_history": [],
		"defeat_counts": {},
		"_rt": {},
	}
	for f in COUNTER_FIELDS:
		st[f] = {}
	for f in MIN_FIELDS:
		st[f] = {}
	for p in ps:
		var pid := int(p)
		for f in COUNTER_FIELDS:
			var table: Dictionary = st[f]
			table[pid] = 0
		for f2 in MIN_FIELDS:
			var table2: Dictionary = st[f2]
			table2[pid] = Defs.field_default(f2)
		st["defeat_counts"][pid] = {}
	for a in ps:
		for b in ps:
			if int(a) == int(b):
				continue
			var row: Dictionary = st["defeat_counts"][int(a)]
			row[int(b)] = 0
	var pieces := {}
	for p2 in ps:
		var row2 := []
		for i in piece_count:
			row2.append({"pos": -1, "finished": false})
		pieces[int(p2)] = row2
	var rt := {
		"player_count": ps.size(),
		"piece_count": piece_count,
		"turn_clock": 0,          # 全局掷骰计数，当回合钟用（含道具骰）
		"turn_no": 0,             # turn 事件计数，进度快照用它当回合号
		"consecutive_ones": {},   # 连续摇到 1
		"six_streak": {},         # 玩家自己连投 6（跨回合，不受三连 6 惩罚影响）
		"consecutive_no_takeoff": {},
		"airport_steps": {},      # 每颗棋子出机场后走了几步（出师未捷）
		"airport_clock": {},      # 出机场那一步的回合钟
		"revenge": {},            # 被谁、被哪颗棋子踩回家（以牙还牙）
		"last_kill": {},          # 这一手刚得手的是哪颗棋子（黄雀在后）
		"reroll_seat": 0,         # 0 = 没有连投；玩家号从 1 开始
		"pending_dice": {},
		"move_open": {},
		"pieces": pieces,
		"current_move_chess": null,
	}
	for p3 in ps:
		var pid3 := int(p3)
		rt["consecutive_ones"][pid3] = 0
		rt["six_streak"][pid3] = 0
		rt["consecutive_no_takeoff"][pid3] = 0
		rt["airport_steps"][pid3] = {}
		rt["airport_clock"][pid3] = {}
		rt["revenge"][pid3] = null
		rt["last_kill"][pid3] = null
	st["_rt"] = rt
	return st

## 重置对局统计（玩家集合变化时也要调）
func reset(players: Array = [1, 2, 3, 4], piece_count: int = 4) -> void:
	state = new_state(players, piece_count)

## 取内部运行时；缺失时补一个空字典（会写回 state）
static func runtime(state: Dictionary) -> Dictionary:
	if not state.has("_rt") or not (state["_rt"] is Dictionary):
		state["_rt"] = {}
	return state["_rt"]

# ---------------------------------------------------------------- 事件入口
## 每批引擎事件后调用：更新统计，并同步引擎状态（可选）。
func apply_events(events: Array, engine_state: Dictionary = {}) -> void:
	update_from_events(events, state)
	if not engine_state.is_empty():
		sync_engine_state(state, engine_state)

## 事件流 -> 统计（static 版，直接改传入的统计字典并返回它）
static func update_from_events(events: Array, state: Dictionary) -> Dictionary:
	if events == null or state.is_empty():
		return state
	var rt := runtime(state)
	# 这三张表只在「一批事件」内累计，像 enginePlayback 的 moveDistances 一样
	var move_dist := {}
	var move_beats := {}
	var move_collisions := {}
	for ev in events:
		if not (ev is Dictionary):
			continue
		match str(ev.get("type", "")):
			"dice":
				_on_dice(state, ev)
			"launch":
				_on_launch(state, ev)
			"walk":
				_on_walk(state, ev, move_dist)
			"jump", "fly":
				_on_jump_like(state, ev, move_dist)
			"finish":
				_on_finish(state, ev)
			"beat":
				_on_beat(state, ev, move_beats)
			"collision_bonus":
				_on_collision_bonus(state, ev, move_collisions)
			"collide":
				_on_collide(state, ev)
			"blocked":
				_on_blocked(state, ev)
			"reset":
				_on_reset(state, ev)
			"teleport":
				_on_teleport(state, ev)
			"mystery_box":
				_on_mystery_box(state, ev)
			"skip":
				_on_skip(state, ev)
			"turn":
				_on_turn(state, ev)
			"reroll":
				rt["reroll_seat"] = int(ev.get("player", 0))
			_:
				pass
	_flush_move_distance(state, move_dist)
	_flush_max(state, "max_beats_in_move", move_beats)
	_flush_max(state, "max_collide_in_move", move_collisions)
	# 一批事件 = 一手；下一批重新认「这一手在动哪颗棋子」
	rt["current_move_chess"] = null
	return state

# ---------------------------------------------------------------- 掷骰
static func _on_dice(state: Dictionary, ev: Dictionary) -> void:
	var p := int(ev.get("player", 0))
	var value := int(ev.get("value", 0))
	var item = ev.get("item", null)
	var is_item: bool = typeof(item) == TYPE_STRING and str(item) != ""
	var rt := runtime(state)
	rt["turn_clock"] = int(rt.get("turn_clock", 0)) + 1
	# 道具骰点数是预定的：不参与连 1 / 连 6，也不打断已有连击（参考 recordRollStreak）
	if is_item:
		rt["pending_dice"][p] = value
		rt["move_open"][p] = false
		if str(item) == "polyhedral-dice":
			_bump(state, "skill_use_count", p, 1)
			_raise(state, "polyhedral_max", p, value)
			_lower(state, "polyhedral_min", p, value)
		else:
			# 遥控骰子同样算「一次道具使用」，只是没有多面骰点数
			_bump(state, "skill_use_count", p, 1)
		_record_turn_start(state, p)
		return
	if value == 1:
		var streak := int(rt["consecutive_ones"].get(p, 0)) + 1
		rt["consecutive_ones"][p] = streak
		_raise(state, "max_consecutive_ones", p, streak)
	else:
		rt["consecutive_ones"][p] = 0
	# 连投 6：玩家自己连着摇到 6 的次数（跨回合累计）
	var six := int(rt["six_streak"].get(p, 0))
	six = six + 1 if value == 6 else 0
	rt["six_streak"][p] = six
	_raise(state, "max_consecutive_sixes", p, six)
	# diceStatistics 只统计普通骰 1..6；6 点次数用于「六点狂魔」
	if value == 6:
		_bump(state, "dice_six_counts", p, 1)
	rt["pending_dice"][p] = value
	rt["move_open"][p] = false
	_record_turn_start(state, p)

## 参考 gameState.recordTurnStart：维护「黄雀在后 / 以牙还牙」两个窗口
static func _record_turn_start(state: Dictionary, player: int) -> void:
	var rt := runtime(state)
	var is_reroll := int(rt.get("reroll_seat", 0)) == player
	rt["reroll_seat"] = 0
	var last_kill: Dictionary = rt.get("last_kill", {})
	if not is_reroll:
		for key in last_kill.keys():
			var kill = last_kill[key]
			if kill == null:
				continue
			if bool(kill.get("armed", false)):
				last_kill[key] = null
			else:
				kill["armed"] = true
	var revenge: Dictionary = rt.get("revenge", {})
	for seat in revenge.keys():
		var pending = revenge[seat]
		if pending == null:
			continue
		if int(seat) != player and bool(pending.get("armed", false)):
			revenge[seat] = null
	if revenge.get(player, null) != null:
		revenge[player]["armed"] = true

# ---------------------------------------------------------------- 起飞 / 走子
static func _on_launch(state: Dictionary, ev: Dictionary) -> void:
	var p := int(ev.get("player", 0))
	var c := int(ev.get("chess", 0))
	var rt := runtime(state)
	_bump(state, "total_distance", p, 1)
	_record_takeoff(state, p, true)
	var steps := _player_map(rt, "airport_steps", p)
	steps[c] = 0
	_set_piece(rt, p, c, int(ev.get("to", 0)), false)

static func _on_walk(state: Dictionary, ev: Dictionary, move_dist: Dictionary) -> void:
	var p := int(ev.get("player", 0))
	var c := int(ev.get("chess", 0))
	var from := int(ev.get("from", 0))
	var to := int(ev.get("to", 0))
	var rt := runtime(state)
	_record_airport_step(state, p, c, from)
	_add_move_distance(move_dist, p, c, to - from)
	# 引擎在「一手」开始时只加一次骰点（欢乐连锁的奖励步不另加里程），
	# 所以这里用「本手第一段 walk」补骰点，而不是每段都加。
	if not bool(rt.get("move_open", {}).get(p, false)):
		var dice := int(rt.get("pending_dice", {}).get(p, maxi(to - from, 0)))
		_bump(state, "total_distance", p, dice)
		rt["move_open"][p] = true
	if bool(ev.get("bounced", false)):
		var bs := int(ev.get("bounceSteps", 0))
		if bs > 0:
			_bump(state, "bounce_steps", p, bs)
		if str(ev.get("bounceReason", "")) == "stack" and ev.get("blocker", null) != null:
			_bump(state, "block_count", int(ev["blocker"]), 1)
	_set_piece(rt, p, c, to, false)
	rt["current_move_chess"] = {"player": p, "chess": c}

static func _on_jump_like(state: Dictionary, ev: Dictionary, move_dist: Dictionary) -> void:
	var p := int(ev.get("player", 0))
	var c := int(ev.get("chess", 0))
	var from := int(ev.get("from", 0))
	var to := int(ev.get("to", 0))
	var rt := runtime(state)
	_add_move_distance(move_dist, p, c, to - from)
	# 跳子 / 飞棋的距离由引擎自己累加，这里照抄
	if to > from:
		_bump(state, "total_distance", p, to - from)
	_set_piece(rt, p, c, to, false)
	rt["current_move_chess"] = {"player": p, "chess": c}

static func _on_finish(state: Dictionary, ev: Dictionary) -> void:
	var p := int(ev.get("player", 0))
	var c := int(ev.get("chess", 0))
	_record_first_finished(state, p)
	var rt := runtime(state)
	_set_piece(rt, p, c, Defs.TRACK_END, true)
	if _all_finished(rt, p):
		state["is_normal_game_end"] = true

static func _on_skip(state: Dictionary, ev: Dictionary) -> void:
	_record_takeoff(state, int(ev.get("player", 0)), false)

## 参考 recordTakeoffAttempt：只有「全在基地、一颗都没飞出去」才算连续无法起飞
static func _record_takeoff(state: Dictionary, player: int, success: bool) -> void:
	var rt := runtime(state)
	if success:
		rt["consecutive_no_takeoff"][player] = 0
		return
	var in_base := false
	var on_track := false
	for c in _pieces(rt, player):
		var pos := int(c.get("pos", -1))
		if pos == -1:
			in_base = true
		elif pos >= 0 and not bool(c.get("finished", false)):
			on_track = true
	if in_base and not on_track:
		var streak := int(rt["consecutive_no_takeoff"].get(player, 0)) + 1
		rt["consecutive_no_takeoff"][player] = streak
		_raise(state, "max_consecutive_no_takeoff", player, streak)
	else:
		rt["consecutive_no_takeoff"][player] = 0

# ---------------------------------------------------------------- 击败 / 碰撞
static func _on_beat(state: Dictionary, ev: Dictionary, move_beats: Dictionary) -> void:
	var p := int(ev.get("player", 0))
	var tgt := int(ev.get("targetPlayer", 0))
	var chess = ev.get("chess", null)
	_record_revenge_kill(state, p, tgt, chess)
	var rt := runtime(state)
	var cm = rt.get("current_move_chess", null)
	if cm is Dictionary and int(cm.get("player", 0)) == p:
		_record_oriole_kill(state, p, tgt, chess)
		_record_beaten_by(state, tgt, p, int(cm.get("chess", -1)))
		_record_kill(state, p, int(cm.get("chess", -1)), tgt)
	_record_beaten_home(state, tgt, chess)
	_record_first_beater(state, p)
	if Defs.is_runway_cell(ev.get("cell", null)):
		_bump(state, "runway_kills", p, 1)
	_bump_defeat(state, p, tgt, 1)
	move_beats[p] = int(move_beats.get(p, 0)) + 1
	_set_piece(rt, tgt, int(chess) if chess != null else -1, -1, false)

static func _on_collision_bonus(state: Dictionary, ev: Dictionary, move_collisions: Dictionary) -> void:
	var p := int(ev.get("player", 0))
	var tgt := int(ev.get("targetPlayer", 0))
	var n := int(ev.get("enemyCount", 1))
	if n <= 0:
		n = 1
	_record_first_beater(state, p)
	_bump_defeat(state, p, tgt, n)
	move_collisions[p] = int(move_collisions.get(p, 0)) + n

static func _on_collide(state: Dictionary, ev: Dictionary) -> void:
	var p := int(ev.get("player", 0))
	var tgt := int(ev.get("targetPlayer", 0))
	var chesses = ev.get("chesses", [])
	var victims: Array = chesses if chesses is Array else []
	# 参考 FxqEngine.count_beats：撞的人吃下整叠，叠子主人收下撞上来的那颗
	_bump_defeat(state, p, tgt, maxi(1, victims.size()))
	_bump_defeat(state, tgt, p, 1)
	var rt := runtime(state)
	var cm = rt.get("current_move_chess", null)
	if cm is Dictionary and int(cm.get("player", 0)) == p:
		_set_piece(rt, p, int(cm.get("chess", -1)), -1, false)
	for v in victims:
		if v is Dictionary:
			_set_piece(rt, int(v.get("player", 0)), int(v.get("index", 0)), -1, false)

static func _on_blocked(state: Dictionary, ev: Dictionary) -> void:
	# 叠子挡路 / 交叉点挡路：被挡的那一方记一次「用叠子阻挡」（记账给挡人的玩家）
	var tp = ev.get("targetPlayer", null)
	if typeof(tp) == TYPE_INT:
		_bump(state, "block_count", int(tp), 1)

static func _on_reset(state: Dictionary, ev: Dictionary) -> void:
	# 三连 6 惩罚：该玩家所有未完成的棋子回基地（只挪位置，不动机场窗口）
	var p := int(ev.get("player", 0))
	var pieces = ev.get("pieces", [])
	if not (pieces is Array):
		return
	var rt := runtime(state)
	for c in pieces:
		_set_piece(rt, p, int(c), -1, false)

static func _record_beaten_by(state: Dictionary, victim: int, attacker: int, attacker_chess: int) -> void:
	if attacker_chess < 0:
		return
	var rt := runtime(state)
	rt["revenge"][victim] = {"attacker": attacker, "chess": attacker_chess, "armed": false}

static func _record_kill(state: Dictionary, beater: int, beater_chess: int, victim: int) -> void:
	if beater_chess < 0:
		return
	var rt := runtime(state)
	rt["last_kill"][beater] = {"chess": beater_chess, "victim": victim, "armed": false}

static func _record_oriole_kill(state: Dictionary, beater: int, target_player: int, target_chess) -> void:
	if target_chess == null:
		return
	var rt := runtime(state)
	var kill = rt["last_kill"].get(target_player, null)
	if kill == null:
		return
	if not bool(kill.get("armed", false)):
		return
	if int(kill.get("chess", -1)) != int(target_chess):
		return
	if int(kill.get("victim", -1)) == beater:
		return
	rt["last_kill"][target_player] = null
	_bump(state, "oriole_kills", beater, 1)

static func _record_revenge_kill(state: Dictionary, beater: int, victim: int, victim_chess) -> void:
	if victim_chess == null:
		return
	var rt := runtime(state)
	var pending = rt["revenge"].get(beater, null)
	if pending == null or not bool(pending.get("armed", false)):
		return
	if int(pending.get("attacker", -1)) != victim:
		return
	if int(pending.get("chess", -1)) != int(victim_chess):
		return
	rt["revenge"][beater] = null
	_bump(state, "revenge_kills", beater, 1)

# ---------------------------------------------------------------- 出机场窗口
## 参考 recordAirportStep：踏出机场那一步开窗口，之后再动一步就关掉
static func _record_airport_step(state: Dictionary, player: int, chess: int, from: int) -> void:
	var rt := runtime(state)
	var steps := _player_map(rt, "airport_steps", player)
	if not steps.has(chess):
		return
	var clock := _player_map(rt, "airport_clock", player)
	if from == 0:
		steps[chess] = 1
		clock[chess] = int(rt.get("turn_clock", 0))
	else:
		steps[chess] = 2
		clock[chess] = -1

## 参考 recordBeatenHome：出门一步、且还没轮到它再动就被踩回去，算「出师未捷」
static func _record_beaten_home(state: Dictionary, victim: int, chess) -> void:
	if chess == null:
		return
	var rt := runtime(state)
	var steps := _player_map(rt, "airport_steps", victim)
	var clock := _player_map(rt, "airport_clock", victim)
	var c := int(chess)
	var walked = steps.get(c, null)
	var entered = clock.get(c, null)
	steps[c] = 0
	clock[c] = -1
	var seats := int(rt.get("player_count", 4))
	var fresh := false
	if walked != null and int(walked) == 1 and entered != null and int(entered) >= 0:
		fresh = int(rt.get("turn_clock", 0)) - int(entered) <= seats - 1
	if fresh:
		_bump(state, "airport_rekt", victim, 1)

# ---------------------------------------------------------------- 道具
static func _on_teleport(state: Dictionary, ev: Dictionary) -> void:
	var p := int(ev.get("player", 0))
	var c := int(ev.get("chess", 0))
	var from := int(ev.get("from", 0))
	var to := int(ev.get("to", 0))
	var rt := runtime(state)
	# 传送门真正落地才算「用了一次道具」（item_activate 只算激活，见参考 recordItemResult）
	_bump(state, "skill_use_count", p, 1)
	_raise(state, "max_teleport_distance", p, absi(to - from))
	if to - from == 1:
		_bump(state, "petty_teleports", p, 1)
	_record_airport_step(state, p, c, from)
	_set_piece(rt, p, c, to, false)
	rt["current_move_chess"] = {"player": p, "chess": c}

static func _on_mystery_box(state: Dictionary, ev: Dictionary) -> void:
	var p := int(ev.get("player", 0))
	var amount := int(ev.get("amount", 0))
	_bump(state, "skill_use_count", p, 1)
	_raise(state, "mystery_box_max", p, amount)
	_lower(state, "mystery_box_min", p, amount)

# ---------------------------------------------------------------- 回合 / 进度
static func _on_turn(state: Dictionary, ev: Dictionary) -> void:
	var rt := runtime(state)
	rt["turn_no"] = int(rt.get("turn_no", 0)) + 1
	add_progress_snapshot(state, int(rt["turn_no"]))

## 追加一条完成度快照（参考 gameState.saveProgressSnapshot）
static func add_progress_snapshot(state: Dictionary, round_no: int) -> void:
	var hist: Array = state.get("progress_history", [])
	if hist.size() >= MAX_PROGRESS_HISTORY:
		hist.remove_at(0)
	var players := {}
	var rt: Dictionary = state.get("_rt", {})
	var pieces: Dictionary = rt.get("pieces", {})
	for p in pieces.keys():
		players[int(p)] = progress_of(state, int(p))
	hist.append({"round": round_no, "players": players})
	state["progress_history"] = hist

## 单个玩家的完成度（参考 progressDisplay.calculatePlayerProgress，0..100）
static func progress_of(state: Dictionary, player: int) -> float:
	var rt: Dictionary = state.get("_rt", {})
	var pieces: Dictionary = rt.get("pieces", {})
	if not pieces.has(player):
		return 0.0
	var cs: Array = pieces[player]
	var n := cs.size()
	if n <= 0:
		return 0.0
	var per := 100.0 / float(n)
	var total := 0.0
	for c in cs:
		if bool(c.get("finished", false)):
			total += per
		else:
			var pos := int(c.get("pos", -1))
			if pos >= 0:
				total += minf(float(pos) / float(Defs.TRACK_END) * per, per)
	var r: float = round(total * 10000.0) / 10000.0
	return round(r * 100.0) / 100.0

# ---------------------------------------------------------------- 只读访问器
## 家族当前数值（等价于 JS family.value(stats, player)）
func value(family_key: String, player: int) -> int:
	return value_of_state(state, family_key, player)

static func value_of_state(stats: Dictionary, family_key: String, player: int) -> int:
	var fam := Defs.family(family_key)
	if fam.is_empty():
		return 0
	return Defs.family_value(fam, stats, player)

## 直接读一个统计字段（-min 类字段在未发生时返回 99）
func raw(field: String, player: int):
	return raw_of_state(state, field, player)

static func raw_of_state(stats: Dictionary, field: String, player: int):
	return Defs.field_value(stats, field, player)

func total_distance(player: int) -> int:
	return int(raw("total_distance", player))

func dice_six_count(player: int) -> int:
	return int(raw("dice_six_counts", player))

func defeat_count(attacker: int, victim: int) -> int:
	var all: Dictionary = state.get("defeat_counts", {})
	var row: Dictionary = all.get(attacker, {})
	return int(row.get(victim, 0))

func progress_history() -> Array:
	return state.get("progress_history", [])

func normal_game_end() -> bool:
	return has_normal_game_end(state)

# ---------------------------------------------------------------- 引擎状态同步
## 把引擎（FxqEngine.create_state 的形状）里「事件流推不出来」或「更权威」的量同步过来：
## totalDistance、棋子位置、玩家数、是否正常收官、可选 defeat_matrix。
static func sync_engine_state(state: Dictionary, engine_state: Dictionary) -> void:
	if engine_state == null or engine_state.is_empty():
		return
	var rt := runtime(state)
	var order = engine_state.get("order", null)
	if order is Array and not (order as Array).is_empty():
		rt["player_count"] = (order as Array).size()
	var players: Dictionary = engine_state.get("players", {})
	for key in players.keys():
		var pid := int(key)
		var pl = players[key]
		if not (pl is Dictionary):
			continue
		if pl.has("totalDistance"):
			_set_counter(state, "total_distance", pid, int(pl["totalDistance"]))
		var cs = pl.get("chesses", null)
		if cs is Array:
			var row := []
			for c in cs:
				if c is Dictionary:
					row.append({"pos": int(c.get("pos", -1)), "finished": bool(c.get("finished", false))})
			if not (rt.get("pieces", {}) is Dictionary):
				rt["pieces"] = {}
			rt["pieces"][pid] = row
			if _all_finished(rt, pid):
				state["is_normal_game_end"] = true
	var dm = engine_state.get("defeat_matrix", null)
	if dm is Dictionary:
		var copy := {}
		for a in dm.keys():
			var src: Dictionary = dm[a]
			var row2 := {}
			for b in src.keys():
				row2[int(b)] = int(src[b])
			copy[int(a)] = row2
		state["defeat_counts"] = copy
	var fo = engine_state.get("finishOrder", null)
	if fo is Array and not (fo as Array).is_empty():
		if state.get("first_finished_player", null) == null:
			state["first_finished_player"] = int((fo as Array)[0])

## 是否正常收官：任一玩家的棋子全部到达终点（强制结算时不算）
static func has_normal_game_end(state: Dictionary) -> bool:
	if bool(state.get("is_normal_game_end", false)):
		return true
	var rt: Dictionary = state.get("_rt", {})
	var pieces: Dictionary = rt.get("pieces", {})
	for p in pieces.keys():
		if _all_finished(rt, int(p)):
			return true
	return false

# ---------------------------------------------------------------- 内部工具
static func _player_map(rt: Dictionary, key: String, player: int) -> Dictionary:
	var all: Dictionary = rt.get(key, {})
	if not all.has(player) or not (all[player] is Dictionary):
		all[player] = {}
	rt[key] = all
	return all[player]

static func _pieces(rt: Dictionary, player: int) -> Array:
	var pieces: Dictionary = rt.get("pieces", {})
	if not pieces.has(player) or not (pieces[player] is Array):
		return []
	return pieces[player]

static func _all_finished(rt: Dictionary, player: int) -> bool:
	var cs := _pieces(rt, player)
	if cs.is_empty():
		return false
	for c in cs:
		if not bool(c.get("finished", false)) and int(c.get("pos", -1)) != Defs.TRACK_END:
			return false
	return true

static func _set_piece(rt: Dictionary, player: int, chess: int, pos: int, finished: bool) -> void:
	var pieces: Dictionary = rt.get("pieces", {})
	if not pieces.has(player) or not (pieces[player] is Array):
		return
	var row: Array = pieces[player]
	if chess < 0 or chess >= row.size():
		return
	row[chess]["pos"] = pos
	row[chess]["finished"] = finished

static func _record_first_finished(state: Dictionary, player: int) -> void:
	if state.get("first_finished_player", null) == null:
		state["first_finished_player"] = player

static func _record_first_beater(state: Dictionary, player: int) -> void:
	if state.get("first_beater_player", null) == null:
		state["first_beater_player"] = player

static func _add_move_distance(move_dist: Dictionary, player: int, chess: int, distance: int) -> void:
	if distance <= 0:
		return
	var key := "%d-%d" % [player, chess]
	var entry: Dictionary = move_dist.get(key, {"player": player, "distance": 0})
	entry["distance"] = int(entry.get("distance", 0)) + distance
	move_dist[key] = entry

static func _flush_move_distance(state: Dictionary, move_dist: Dictionary) -> void:
	for key in move_dist.keys():
		var entry: Dictionary = move_dist[key]
		_raise(state, "max_move_distance", int(entry.get("player", 0)), int(entry.get("distance", 0)))

static func _flush_max(state: Dictionary, field: String, table: Dictionary) -> void:
	for p in table.keys():
		_raise(state, field, int(p), int(table[p]))

static func _counter_table(state: Dictionary, field: String) -> Dictionary:
	var table = state.get(field, null)
	if not (table is Dictionary):
		table = {}
		state[field] = table
	return table

static func _bump(state: Dictionary, field: String, player: int, amount: int = 1) -> void:
	var table := _counter_table(state, field)
	table[player] = int(table.get(player, Defs.field_default(field))) + amount

static func _raise(state: Dictionary, field: String, player: int, value: int) -> void:
	var table := _counter_table(state, field)
	if value > int(table.get(player, Defs.field_default(field))):
		table[player] = value

static func _lower(state: Dictionary, field: String, player: int, value: int) -> void:
	var table := _counter_table(state, field)
	if value < int(table.get(player, Defs.field_default(field))):
		table[player] = value

static func _set_counter(state: Dictionary, field: String, player: int, value: int) -> void:
	var table := _counter_table(state, field)
	table[player] = value

## 逐对手击败矩阵：attackers[target] += amount（撞叠子双方各计）
static func _bump_defeat(state: Dictionary, attacker: int, victim: int, amount: int) -> void:
	if attacker == victim or victim <= 0:
		return
	var all: Dictionary = state.get("defeat_counts", {})
	if not all.has(attacker) or not (all[attacker] is Dictionary):
		all[attacker] = {}
	var row: Dictionary = all[attacker]
	row[victim] = int(row.get(victim, 0)) + amount
	state["defeat_counts"] = all
