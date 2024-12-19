extends Node

const DELAY_TIME: float = 0.01
const PACKET_LOSS: float = 0.01

signal recieve_input_update(sender_peer_id: int, message: PackedByteArray)
signal recieve_state_update(message: PackedByteArray)
signal recieve_ping_update(ping:int, sender_peer_id: int)

# peer_id -> PingRequest
var ping_requests: Dictionary = {}

class PingRequest extends Object:
	var ping_start_time: int = -1
	var timer: Timer
	
	func _init(parent: Node)->void:
		timer = Timer.new()
		parent.add_child(timer)
		timer.wait_time = 1

func send_ping_request(peer_id: int) -> void:
	var ping_request: PingRequest = ping_requests.get(peer_id, null)
	if ping_request == null:
		ping_request = PingRequest.new(self)
		ping_requests[peer_id] = ping_request 
		
	if ping_request.timer.is_stopped() == false:
		return

	ping_request.ping_start_time = Time.get_ticks_msec()
	ping_request.timer.start()
	
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
	var peer_id: int = multiplayer.get_remote_sender_id()
	
	var ping_request: PingRequest = ping_requests.get(peer_id, null)
	if ping_request == null:
		push_error("No request found for recieved ping.")
		return
	
	var ping_end_time: int = Time.get_ticks_msec()
	var ping: int = ping_end_time - ping_request.ping_start_time
	
	recieve_ping_update.emit(ping, peer_id)

func send_input_update(peer_id : int, message: PackedByteArray) -> void:
	if DELAY_TIME > 0:
		await get_tree().create_timer(DELAY_TIME, true, true).timeout
	if PACKET_LOSS > 0:
		var rand_value := randf()
		if rand_value <= PACKET_LOSS:
			return
	riu.rpc_id(peer_id, message)

func send_state_update(peer_id : int, message : PackedByteArray) -> void:
	if DELAY_TIME > 0:
		await get_tree().create_timer(DELAY_TIME, true, true).timeout
	if PACKET_LOSS > 0:
		var rand_value := randf()
		if rand_value <= PACKET_LOSS:
			return
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
