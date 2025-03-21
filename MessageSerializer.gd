extends Object

const NetcodeManager = preload("res://NetcodeManager.gd")

# Even though ENet will handle fragmenting overlarge messages into packets for me, I do in general 
# want to keep packet sizes below the average MTU if possible.
# See https://gafferongames.com/post/packet_fragmentation_and_reassembly/
const DEFAULT_MESSAGE_SIZE = 1024

enum PlayerInputKeys {
	INITIAL_TICK,
	PLAYER_INPUT_DATA,
	LAST_RECEIVED_STATE_TICK
}

enum StateUpdateKeys {
	TICK,
	OLDEST_INPUT_TICK_UNRECIEVED,
	THROTTLE_COMMAND,
	MANIFEST,
	STATE
}

enum NodeStateKeys {
	NODE_PATH,
	ASSET,
	OWNER,
	STATE,
	PLAYER_INPUT
}

func serialize_player_input(player_input: Dictionary) -> PackedByteArray:
	return var_to_bytes(player_input)

func deserialize_player_input(player_input_data: PackedByteArray) -> Dictionary:
	if player_input_data.is_empty():
		return {}
	return bytes_to_var(player_input_data)
	
func serialize_node_input(node_input: Dictionary) -> PackedByteArray:
	if node_input.is_empty():
		return PackedByteArray()
	return var_to_bytes(node_input)

func deserialize_node_input(node_input_data: PackedByteArray) -> Dictionary:
	if node_input_data.is_empty():
		return {}
	return bytes_to_var(node_input_data)

## state: node_path -> Dictionary (which contains the generated node state)
func default_serialize_state(state: Dictionary) -> PackedByteArray:
	return var_to_bytes(state)
	
func default_deserialize_state(state_data: PackedByteArray) -> Dictionary:
	return bytes_to_var(state_data)

func serialize_manifest(manifest: Dictionary) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.resize(DEFAULT_MESSAGE_SIZE)
	
	buffer.put_u32(manifest.size())
	
	for node_path: String in manifest:
		var lifetime: NetcodeManager.NodeLifetime = manifest.get(node_path) 
		buffer.put_string(node_path)
		buffer.put_u32(lifetime.spawn_tick)
		buffer.put_u32(lifetime.destroy_tick)
		buffer.put_string(lifetime.asset)
		buffer.put_u32(lifetime.owning_peer)
	
	buffer.resize(buffer.get_position())
	return buffer.data_array

func deserialize_manifest(data: PackedByteArray) -> Dictionary:
	var buffer := StreamPeerBuffer.new()
	buffer.put_data(data)
	buffer.seek(0)
	var manifest : Dictionary = {}
	
	var size: int = buffer.get_u32()
	for index: int in size:
		var node_path: String = buffer.get_string()
		var spawn: int = buffer.get_u32()
		var destroy: int = buffer.get_u32()
		var asset: String = buffer.get_string()
		var owner: int = buffer.get_u32()
		var lifetime: NetcodeManager.NodeLifetime = NetcodeManager.NodeLifetime.new(spawn, destroy, asset, owner)
		manifest[node_path] = lifetime
	
	return manifest

func serializer_node_state_message(state_message: Dictionary) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.resize(DEFAULT_MESSAGE_SIZE)
	
	var node_path: String = state_message.get(NodeStateKeys.NODE_PATH, "")
	buffer.put_string(node_path)
	
	var asset: String = state_message.get(NodeStateKeys.ASSET, "")
	buffer.put_string(asset)
	
	var owner: int = state_message.get(NodeStateKeys.OWNER, 1)
	buffer.put_u32(owner)
	
	var state: PackedByteArray = state_message.get(NodeStateKeys.STATE, PackedByteArray())
	buffer.put_u16(state.size())
	buffer.put_data(state)
	
	var input: PackedByteArray = state_message.get(NodeStateKeys.PLAYER_INPUT, PackedByteArray())
	buffer.put_u16(input.size())
	buffer.put_data(input)
	
	buffer.resize(buffer.get_position())
	return buffer.data_array

func deserializer_node_state_message(data: PackedByteArray) -> Dictionary:
	var buffer := StreamPeerBuffer.new()
	buffer.put_data(data)
	buffer.seek(0)
	var message : Dictionary = {}
	
	message[NodeStateKeys.NODE_PATH] = buffer.get_string()
	
	message[NodeStateKeys.ASSET] = buffer.get_string()
	
	message[NodeStateKeys.OWNER] = buffer.get_u32()
	
	var state_size: int = buffer.get_u16()
	message[NodeStateKeys.STATE] = buffer.get_data(state_size)[1]
	
	var input_size: int = buffer.get_u16()
	message[NodeStateKeys.PLAYER_INPUT] = buffer.get_data(input_size)[1]
	
	return message

func serialize_state_update_message(message: Dictionary) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.resize(DEFAULT_MESSAGE_SIZE)
	
	#TICK
	buffer.put_u32(message.get(StateUpdateKeys.TICK, 0))
	#OLDEST_INPUT_TICK_UNRECIEVED
	buffer.put_u32(message.get(StateUpdateKeys.OLDEST_INPUT_TICK_UNRECIEVED,0))
	#THROTTLE_COMMAND,
	buffer.put_8(message.get(StateUpdateKeys.THROTTLE_COMMAND, 0))
	
	# manifest
	var manifest_data: PackedByteArray = message.get(StateUpdateKeys.MANIFEST)
	buffer.put_u16(manifest_data.size())
	buffer.put_data(manifest_data)
	
	#STATE, array of data
	var default_node_array: Array[PackedByteArray] = []
	var all_node_data: Array[PackedByteArray] = message.get(StateUpdateKeys.STATE, default_node_array)
	buffer.put_u16(all_node_data.size())
	for node_data in all_node_data:
		buffer.put_u16(node_data.size())
		buffer.put_data(node_data)
	
	buffer.resize(buffer.get_position())
	return buffer.data_array

func deserialize_state_update_message(data: PackedByteArray) -> Dictionary:
	var buffer := StreamPeerBuffer.new()
	buffer.put_data(data)
	buffer.seek(0)
	var message : Dictionary = {}
	
	message[StateUpdateKeys.TICK] = buffer.get_u32()
	
	message[StateUpdateKeys.OLDEST_INPUT_TICK_UNRECIEVED] = buffer.get_u32()
	
	message[StateUpdateKeys.THROTTLE_COMMAND] = buffer.get_8()
	
	# manifest
	var manifest_size: int = buffer.get_u16()
	var serialized_manifest: PackedByteArray = buffer.get_data(manifest_size)[1]
	message[StateUpdateKeys.MANIFEST] = serialized_manifest

	# node states
	var node_state_count: int = buffer.get_u16()
	var node_state_messages: Array[PackedByteArray] = []
	for count in node_state_count:
		var node_state_message_size: int = buffer.get_u16()
		var serialized_node_state_message: PackedByteArray = buffer.get_data(node_state_message_size)[1]
		node_state_messages.push_back(serialized_node_state_message)
	
	message[StateUpdateKeys.STATE] = node_state_messages
	
	return message

func serialize_input_message(message : Dictionary) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.resize(DEFAULT_MESSAGE_SIZE)
	
	var tick : int = message.get(PlayerInputKeys.INITIAL_TICK,-1)
	assert(tick != -1, "Input message has no tick element.")
	buffer.put_u32(tick)
	
	var last_recieved_tick: int = message[PlayerInputKeys.LAST_RECEIVED_STATE_TICK]
	buffer.put_u32(last_recieved_tick)
	
	var player_input_ticks : Array[PackedByteArray] = message.get(PlayerInputKeys.PLAYER_INPUT_DATA)
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
	message[PlayerInputKeys.LAST_RECEIVED_STATE_TICK] = buffer.get_u32()
	
	var player_input_data : Array[PackedByteArray] = []
	
	var player_input_count : int = buffer.get_u8()
	
	player_input_data.resize(player_input_count)
	
	for index in player_input_count:
		var input_data_size : int = buffer.get_u16()
		var data_array := buffer.get_data(input_data_size)
		player_input_data[index] = data_array[1]
	
	message[PlayerInputKeys.PLAYER_INPUT_DATA] = player_input_data
	return message
