extends Node

signal recieve_input_update(sender_peer_id: int, message: PackedByteArray)
signal recieve_state_update(message: PackedByteArray)

func send_input_update(peer_id : int, message: PackedByteArray) -> void:
	riu.rpc_id(peer_id, message)

func send_state_update(peer_id : int, message : PackedByteArray) -> void:
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
