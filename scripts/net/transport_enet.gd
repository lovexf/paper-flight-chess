# ============================================================================
#  传输层（M1）：ENet + MultiplayerAPI.send_bytes 原始字节消息
#
#  【为什么是这套】见 docs/lan_mp_research/01-network-architecture.md §10.1：
#    · ENetMultiplayerPeer：多 peer、可靠有序、断线信号齐全
#    · SceneMultiplayer.send_bytes：数据为中心的原始包，协议演进不用改方法签名
#    · 实测坑：必须 set_root_path("/root")，且每帧 poll()
#
#  【职责边界】只做连接/收发/信号；不碰规则、不碰房间语义、不解析业务字段。
# ============================================================================
class_name FxqTransportENet
extends RefCounted

signal connected_to_host()            # 客户端：已连上房主
signal connection_failed()            # 客户端：连接失败
signal host_disconnected()            # 客户端：与房主断开
signal peer_joined(net_id: int)       # 房主：有客户端加入
signal peer_left(net_id: int)         # 房主：有客户端离开
signal message_received(net_id: int, msg: Dictionary)   # 已解包的自定义消息

const CHANNEL := 0
var _api: SceneMultiplayer = null
var _peer: ENetMultiplayerPeer = null
var _host := false
var _closed := false

## 房主：监听端口。返回 OK / ENet 错误码（端口占用常见 ERR_CANT_CREATE=20）
func host(port: int = FxqProtocol.PORT, max_clients: int = 4) -> Error:
	close()
	var api := MultiplayerAPI.create_default_interface() as SceneMultiplayer
	if api == null: return ERR_UNCONFIGURED
	# ★ 必须：不设 root_path 时，收到第一个包就报 "Multiplayer root was not initialized"
	api.set_root_path(NodePath("/root"))
	var p := ENetMultiplayerPeer.new()
	var err := p.create_server(port, max_clients, 2)      # 2 个 channel（0 主通道）
	if err != OK: return err
	_api = api
	_peer = p
	_host = true
	api.peer_connected.connect(func(id: int) -> void: peer_joined.emit(id))
	api.peer_disconnected.connect(func(id: int) -> void: peer_left.emit(id))
	api.peer_packet.connect(_on_packet)
	api.multiplayer_peer = p
	return OK

## 客户端：连接房主
func join(ip: String, port: int = FxqProtocol.PORT) -> Error:
	close()
	var api := MultiplayerAPI.create_default_interface() as SceneMultiplayer
	if api == null: return ERR_UNCONFIGURED
	api.set_root_path(NodePath("/root"))
	var p := ENetMultiplayerPeer.new()
	var err := p.create_client(ip, port, 2)
	if err != OK: return err
	_api = api
	_peer = p
	_host = false
	api.connected_to_server.connect(func() -> void: connected_to_host.emit())
	api.connection_failed.connect(func() -> void: connection_failed.emit())
	api.server_disconnected.connect(func() -> void: host_disconnected.emit())
	api.peer_packet.connect(_on_packet)
	api.multiplayer_peer = p
	return OK

## 每帧调用（自建接口不会自动 poll；未挂到 SceneTree 默认 multiplayer）
func poll() -> void:
	if _api != null: _api.poll()

## 发一条消息给指定 peer。目标用 MultiplayerPeer.TARGET_PEER_SERVER(1) 或对端 unique_id
func send_to(net_id: int, kind: int, payload: Dictionary = {}) -> Error:
	if _api == null or _peer == null: return ERR_UNCONFIGURED
	return _api.send_bytes(FxqProtocol.pack(kind, payload), net_id,
		MultiplayerPeer.TRANSFER_MODE_RELIABLE, CHANNEL)

## 房主：广播给所有已连接客户端
func broadcast(kind: int, payload: Dictionary = {}) -> void:
	if _api == null: return
	for id in _api.get_peers():
		send_to(int(id), kind, payload)

func get_peers() -> Array:
	if _api == null: return []
	var out := []
	for id in _api.get_peers(): out.append(int(id))
	return out

func is_host() -> bool: return _host
func get_unique_id() -> int: return int(_peer.get_unique_id()) if _peer != null else 0
func is_connected_to_host() -> bool:
	return (not _host) and _peer != null and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
func is_host_active() -> bool: return _host and _peer != null

func close() -> void:
	_closed = true
	if _api != null:
		_api.multiplayer_peer = null
	if _peer != null:
		_peer.close()
	_peer = null
	_api = null
	_host = false
	_closed = false

func _on_packet(net_id: int, packet: PackedByteArray) -> void:
	var msg := FxqProtocol.unpack(packet)
	if msg.is_empty(): return          # 非法/版本不符：丢弃，不 crash
	message_received.emit(net_id, msg)
