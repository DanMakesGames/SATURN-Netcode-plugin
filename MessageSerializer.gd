extends Object

# Even though ENet will handle fragmenting overlarge messages into packets for me, I do in general 
# want to keep packet sizes below the average MTU if possible.
# See https://gafferongames.com/post/packet_fragmentation_and_reassembly/
const DEFAULT_MESSAGE_SIZE = 1024

enum PlayerInputKeys {
	INITIAL_TICK,
	PLAYER_INPUT_DATA
}

func serialize_player_input(player_input: Dictionary) -> PackedByteArray:
	return var_to_bytes(player_input)

func deserialize_player_input(player_input_data: PackedByteArray) -> Dictionary:
	return bytes_to_var(player_input_data)

func serialize_state_message(message : Dictionary) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.resize(DEFAULT_MESSAGE_SIZE)
	buffer.resize(buffer.get_position())
	return buffer.data_array
	
func serialize_input_message(message : Dictionary) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.resize(DEFAULT_MESSAGE_SIZE)
	
	var tick : int = message.get(PlayerInputKeys.INITIAL_TICK,-1)
	assert(tick != -1, "Input message has no tick element.")
	buffer.put_u32(tick)
		
	var player_input_ticks : Array[PackedByteArray] = message.get(PlayerInputKeys.PLAYER_INPUT_DATA)
	assert(player_input_ticks != null, "Input message has not input element")
	
	buffer.put_u8(player_input_ticks.size())
	
	for player_input_tick in player_input_ticks:
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
