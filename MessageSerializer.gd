extends Object

# Even though ENet will handle fragmenting overlarge messages into packets for me, I do in general 
# want to keep packet sizes below the average MTU if possible.
# See https://gafferongames.com/post/packet_fragmentation_and_reassembly/
const DEFAULT_MESSAGE_SIZE = 1024

enum PlayerInputKeys {
	INITIAL_TICK,
	PLAYER_INPUT_DATA
}

enum StateKeys {
	TICK,
	INPUT_PEER_ID,
	NODE_PATH,
	STATE,
	PLAYER_INPUT_DATA
}

func serialize_player_input(player_input: Dictionary) -> PackedByteArray:
	return var_to_bytes(player_input)

func deserialize_player_input(player_input_data: PackedByteArray) -> Dictionary:
	return bytes_to_var(player_input_data)
	
func serialize_node_input(node_input: Dictionary) -> PackedByteArray:
	if node_input.is_empty():
		return PackedByteArray()
	return var_to_bytes(node_input)

func deserialize_node_input(node_input_data: PackedByteArray) -> Dictionary:
	return bytes_to_var(node_input_data)

## state: node_path -> Dictionary (which contains the generated node state)
func serialize_state(state: Dictionary) -> PackedByteArray:
	return var_to_bytes(state)
	
func deserialize_state(state_data: PackedByteArray) -> Dictionary:
	return bytes_to_var(state_data)

func serialize_state_message(message : Dictionary) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.resize(DEFAULT_MESSAGE_SIZE)
	
	var tick : int = message.get(StateKeys.TICK, -1)
	assert(tick != -1, "state message has no tick element")
	buffer.put_u32(tick)
	
	var input_peer_id: int = message.get(StateKeys.INPUT_PEER_ID, -1)
	assert(input_peer_id != -1, "no input peer id provided")
	buffer.put_u32(input_peer_id)
	
	var node_path : String = message.get(StateKeys.NODE_PATH, "")
	assert(node_path.is_empty() == false, "message node path is empty")
	buffer.put_string(node_path)
	
	var state : PackedByteArray = message.get(StateKeys.STATE)
	assert(state != null, "State message has no state")
	buffer.put_u16(state.size())
	buffer.put_data(state)
	
	var node_input : PackedByteArray = message.get(StateKeys.PLAYER_INPUT_DATA)
	assert(node_input != null, "state message has no input")
	buffer.put_u16(node_input.size())
	buffer.put_data(node_input)
	
	buffer.resize(buffer.get_position())
	return buffer.data_array

func deserialize_state_message(data: PackedByteArray) -> Dictionary:
	var buffer := StreamPeerBuffer.new()
	buffer.put_data(data)
	buffer.seek(0)
	
	var message : Dictionary = {}
	
	message[StateKeys.TICK] = buffer.get_u32()
	
	message[StateKeys.INPUT_PEER_ID] = buffer.get_u32()
	
	var state_size := buffer.get_u16()
	message[StateKeys.STATE] = deserialize_state(buffer.get_data(state_size))

	var input_size := buffer.get_u16()
	if input_size == 0:
		message[StateKeys.PLAYER_INPUT_DATA] = PackedByteArray()
	else:
		message[StateKeys.PLAYER_INPUT_DATA] = deserialize_node_input(buffer.get_data(input_size))
	
	return message

func serialize_input_message(message : Dictionary) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.resize(DEFAULT_MESSAGE_SIZE)
	
	var tick : int = message.get(PlayerInputKeys.INITIAL_TICK,-1)
	assert(tick != -1, "Input message has no tick element.")
	buffer.put_u32(tick)
		
	## peer_id -> PackedByteArray
	var player_input_ticks : Dictionary = message.get(PlayerInputKeys.PLAYER_INPUT_DATA)
	assert(player_input_ticks != null, "Input message has not input element")
	
	buffer.put_u8(player_input_ticks.size())
	
	for player_input_tick : PackedByteArray in player_input_ticks:
		buffer.put_u16(player_input_tick.size())
		buffer.put_data(player_input_tick) 
	
	buffer.resize(buffer.get_position())
	return buffer.data_array

func deserialize_input_message(data : PackedByteArray) -> Dictionary:
	var buffer := StreamPeerBuffer.new()
	buffer.put_data(data)
	buffer.seek(0)
	
	var message : Dictionary = {}
	
	message[PlayerInputKeys.INITIAL_TICK] = buffer.get_u32()
	
	var player_input_data : Array[PackedByteArray] = []
	
	var player_input_count : int = buffer.get_u8()
	player_input_data.resize(player_input_count)
	
	for index in player_input_count:
		var input_data_size : int = buffer.get_u16()
		player_input_data.push_back(buffer.get_data(input_data_size))
	
	message[PlayerInputKeys.PLAYER_INPUT_DATA] = player_input_data
	return message
