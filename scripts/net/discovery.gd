# ============================================================================
#  局域网发现（M2）：UDP 广播 7789（L1）+ 房间列表维护
#
#  【定位】只负责「找人」：房主每秒广播房间信息，客户端监听并维护 3 秒内活跃列表。
#  不承载游戏逻辑（广播丢包不影响对局）；发现失败时 UI 走「手动 IP」（L2 必做）。
#  载荷用 JSON（人可读、字段全是字符串/数字，没有 int 键问题）。
# ============================================================================
class_name FxqDiscovery
extends RefCounted

const TTL_MS := 3000
const BROADCAST_ADDR := "255.255.255.255"

var _udp_out: PacketPeerUDP = null
var _udp_in: PacketPeerUDP = null
var _adv_info := {}
var _adv_port := FxqProtocol.DISCOVERY_PORT
var _adv_t := 1.0
var _rooms := {}
var _listening := false
var _advertising := false

# ---------------------------------------------------------------- 码/解码（测试可直接用）
static func encode_info(info: Dictionary) -> PackedByteArray:
	var m: Dictionary = info.duplicate(true)
	m["magic"] = FxqProtocol.MAGIC
	m["v"] = FxqProtocol.VERSION
	return JSON.stringify(m).to_utf8_buffer()

static func decode_info(bytes: PackedByteArray) -> Dictionary:
	var j := JSON.new()
	if j.parse(bytes.get_string_from_utf8()) != OK: return {}
	var d = j.data
	if not (d is Dictionary): return {}
	if str(d.get("magic", "")) != FxqProtocol.MAGIC: return {}
	if int(d.get("v", -1)) != FxqProtocol.VERSION: return {}
	if str(d.get("roomId", "")) == "": return {}
	return d

# ---------------------------------------------------------------- 房主：广播
func start_advertise(info: Dictionary, port: int = FxqProtocol.DISCOVERY_PORT,
		dest_addr: String = BROADCAST_ADDR) -> Error:
	close_advertise()
	var udp := PacketPeerUDP.new()
	udp.set_broadcast_enabled(true)
	var err := udp.set_dest_address(dest_addr, port)
	if err != OK: return err
	_udp_out = udp
	_adv_info = info.duplicate(true)
	_adv_port = port
	_adv_t = 1.0          # 下一帧立刻发一次
	_advertising = true
	return OK

func update_advertise(info: Dictionary) -> void:
	_adv_info = info.duplicate(true)
	_adv_t = 1.0          # 房间信息变化时立刻重播

func close_advertise() -> void:
	_advertising = false
	_udp_out = null

# ---------------------------------------------------------------- 客户端：监听
func start_listen(port: int = FxqProtocol.DISCOVERY_PORT) -> Error:
	close_listen()
	var udp := PacketPeerUDP.new()
	udp.set_broadcast_enabled(true)
	var err := udp.bind(port, "0.0.0.0")
	if err != OK:
		return err
	_udp_in = udp
	_listening = true
	return OK

func close_listen() -> void:
	_listening = false
	_udp_in = null
	_rooms = {}

# ---------------------------------------------------------------- 每帧推进
## 房主：每秒广播；客户端：收取并更新房间表
func tick(delta: float) -> void:
	if _advertising and _udp_out != null:
		_adv_t += delta
		if _adv_t >= 1.0:
			_adv_t = 0.0
			var info := _adv_info.duplicate(true)
			info["port"] = int(_adv_info.get("port", FxqProtocol.PORT))
			_udp_out.put_packet(encode_info(info))
	if _listening and _udp_in != null:
		while _udp_in.get_available_packet_count() > 0:
			var bytes := _udp_in.get_packet()
			var ip := _udp_in.get_packet_ip()
			ingest(bytes, ip)

# ---------------------------------------------------------------- 收包入口（测试可直调）
func ingest(bytes: PackedByteArray, ip: String) -> void:
	var d := decode_info(bytes)
	if d.is_empty(): return
	d["ip"] = ip
	d["lastSeen"] = Time.get_ticks_msec()
	_rooms[str(d["roomId"])] = d

## 3 秒内活跃的房间（按最近广播时间倒序）
func rooms() -> Array:
	var now := Time.get_ticks_msec()
	var out := []
	for k in _rooms.keys():
		var d: Dictionary = _rooms[k]
		if now - int(d.get("lastSeen", 0)) <= TTL_MS:
			out.append(d)
	out.sort_custom(func(a, b): return int(a.get("lastSeen", 0)) > int(b.get("lastSeen", 0)))
	return out

func room_count() -> int:
	return rooms().size()

func clear_rooms() -> void:
	_rooms = {}

func is_listening() -> bool: return _listening
func is_advertising() -> bool: return _advertising

func close() -> void:
	close_advertise()
	close_listen()