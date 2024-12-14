extends Node

const DELAY_TIME: float = 0.05

signal recieve_input_update(sender_peer_id: int, message: PackedByteArray)
signal recieve_state_update(message: PackedByteArray)
signal recieve_ping_update(ping:int)

var ping_timeout_timer: Timer = null
var ping_start_time: int = -1

func _ready() -> void:
	ping_timeout_timer = Timer.new()
	add_child(ping_timeout_timer)
	ping_timeout_timer.wait_time = 5
	ping_timeout_timer.timeout.connect(self.ping_timeout)

func send_ping_request(peer_id: int) -> void:
	if ping_timeout_timer.is_stopped() == false:
		return

	ping_start_time = Time.get_ticks_msec()
	ping_timeout_timer.start()
	
	if DELAY_TIME > 0:
		await get_tree().create_timer(DELAY_TIME, true, true).timeout
	recieve_ping_request.rpc_id(peer_id)

func send_ping_response(peer_id: int) -> void:
	if DELAY_TIME > 0:
		await get_tree().create_timer(DELAY_TIME, true, true).timeout
	recieve_ping_response.rpc_id(peer_id)
	
@rpc("any_peer", "unreliable")
func recieve_ping_request() -> void:
	var return_peer_id: int = multiplayer.get_remote_sender_id()
	send_ping_response(return_peer_id)
	
@rpc("any_peer", "unreliable")
func recieve_ping_response() -> void:
	var ping_end_time: int = Time.get_ticks_msec()
	var ping: int = ping_end_time - ping_start_time
	recieve_ping_update.emit(ping)
	ping_start_time = -1
	
func ping_timeout() -> void:
	if ping_start_time == -1:
		return
	
	var ping_end_time: int = Time.get_ticks_msec()
	var ping: int = ping_end_time - ping_start_time
	recieve_ping_update.emit(ping)
	ping_start_time = -1
	
func send_input_update(peer_id : int, message: PackedByteArray) -> void:
	if DELAY_TIME > 0:
		await get_tree().create_timer(DELAY_TIME, true, true).timeout
	riu.rpc_id(peer_id, message)

func send_state_update(peer_id : int, message : PackedByteArray) -> void:
	if DELAY_TIME > 0:
		await get_tree().create_timer(DELAY_TIME, true, true).timeout
	rsu.rpc_id(peer_id, message)

@rpc("any_peer", "call_local", "unreliable")
func riu(message : PackedByteArray) -> void:
	recieve_input_update.emit(multiplayer.get_remote_sender_id(), message)

@rpc("authority","call_local", "unreliable")
func rsu(message : PackedByteArray) -> void:
	# Sanity Check
	assert(multiplayer.get_remote_sender_id() == 1, \
	"Recieved State update from something that is not the server. Peer_id: %d" % multiplayer.get_remote_sender_id())
	
	recieve_state_update.emit(message)
