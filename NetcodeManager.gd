extends Node

# Preloads
const NetworkAdaptor = preload("res://NetworkAdaptor.gd")
const MessageSerializer = preload("res://MessageSerializer.gd")

# Consts
const NETWORK_ENTITY_GROUP : String = "network_entity"
const SAVE_STATE_FUNCTION : String = "_save_state"
const LOAD_STATE_FUNCTION : String = "_load_state"
const GET_LOCAL_INPUT_FUNCTION : String = "_get_local_input"
const NETWORK_PROCESS_FUNCTION : String = "_network_transform_process"
const MAX_STATE_BUFFER_SIZE_SERVER : int = 1
const MAX_INPUT_BUFFER_SIZE_SERVER : int = 500
const MAX_BUFFER_SIZE_CLIENT : int = 500
const MAX_PLAYER_INPUT_TICKS_PER_MESSAGE: int = 5

#  node manifest entries older than this are cleaned up.
const MAX_NODE_MANIFEST_AGE: int = 60

enum NetworkState 
{
	INACTIVE,
	SYNCING,
	STARTED
}

var network_state: NetworkState = NetworkState.INACTIVE

# the newest tick we have processed. Does not change with rollback.
var last_processed_tick : int = -1

## Tick we are currently processing. Changes based on realtime vs rollback.
var current_tick :int
func get_current_tick() -> int:
	return current_tick

## tick we would like to rollback to. -1 means no rollback requested.
var rollback_tick : int = -1

## true when currently within a rollback. DO NOT MODIFY
var is_rollback : bool = false

## this is the last player input tick that the server confirmed to us it recieved.
var last_unconfirmed_player_tick : int = 0
# used for updating var player_input_departure_buffer. DO NOT MANUALLY UPDATE
var last_unconfirmed_player_tick_old : int = 0

var network_adaptor : NetworkAdaptor
var message_serializer : MessageSerializer

## Array of serialized player input that needs to be sent off to the server. Shrinks as we
## get confirmations from the server that it recieved our input. A client input tick must eventually
## arrive.
## Element 0: player_input for tick last_unconfirmed_player_tick
## Element Last: most recent player input tick
var player_input_departure_buffer : Array[PackedByteArray]

var debug_last_recieved_state_tick: int = -1

var tick_throttle: int = 0

# added onto the minimum buffer size to create a range 
var input_buffer_range_max: int = 7

var last_received_state_tick: int = -1

# Signals
signal begin_syncing()
signal game_started()
signal game_stopped()
signal game_error()

class Player extends Object:
	var peer_id : int
	var ping: int = -1
	var tick_throttle: int = 0
	var oldest_unrecieved_input_tick: int = 0
	# SERVER
	var client_received_state_tick: int = 0

var players : Array[Player]

## indexed by tick. Element Last is most recent.
var state_buffer : Array[TickState]

## node_path -> NodeLifeTime
var node_manifest: Dictionary

## peer_id -> Array[PlayerInput]
var input_buffer : Dictionary

## state on this tick
class TickState extends Object:
	## tick for this state
	var tick : int
	
	## node path -> EntityState
	## gameplay state at the end of this tick ("as a result of this tick")
	var entity_states : Dictionary
	
	func _init(_tick : int) -> void:
		tick = _tick

## State for a single node at a single frame
class EntityState extends Object:
	## Is this game state a client-side prediction or a true state from the server? Always true on the server.
	#TODO, is this redundant? We never want to override a true state, but now that we send state as a contigous block hopefully this should be impossible. 
	var is_true: bool = false
	
	## Used for spawning this on the client or rollbacks
	# TODO: Now that we have the node_manifest, this information is redundant. If we need to lookup the asset we can just look it up in the manifest.
	var scene_asset: String
	
	# TODO: Now that we have the node_manifest, this information is redundant. Just look it up in the manifest.
	var owning_peer: int = 1
	
	var state: Dictionary

class NodeLifetime extends Object:
	var spawn_tick: int = 0
	var destroy_tick: int = 0
	var asset: String
	var owning_peer: int = 1
	
	func _init(_spawn: int, _destroy: int, _asset: String, _owning_peer: int = 1) -> void:
		spawn_tick = _spawn
		destroy_tick = _destroy
		asset = _asset
		owning_peer = _owning_peer
	
	func is_alive(tick: int) -> bool:
		# we consider destroy_tick == 0 to mean it hasnt been destroyed yet. I did this to make it so I can send unsigned ints across the net.
		if tick >= spawn_tick && (destroy_tick == 0 || tick < destroy_tick):
			return true
		
		return false

class PlayerInput extends Object:
	var tick : int = 0
	
	## is this predicted input or true input from the server? On the owning client this is always true.
	var is_predicted : bool = true
	
	## node_path (String) -> InputData (Dictionary)
	var input : Dictionary = {}
	
	func _init(_tick: int, _is_predicted : bool, _input: Dictionary) -> void:
		tick = _tick
		is_predicted = _is_predicted
		input = _input

func add_player(peer_id : int) -> void:
	# Don't add the server
	if peer_id == 1:
		return
	
	if get_player(peer_id) != null:
		push_error("DUPLICATE PLAYER ADD")
		return
	
	var new_player : Player = Player.new()
	new_player.peer_id = peer_id
	players.push_back(new_player)

func remove_player(peer_id : int) -> void:
	for index : int in players.size():
		if players[index].peer_id == peer_id:
			players.remove_at(index)
			return

func clear_players() -> void:
	players.clear()

func get_player(peer_id : int) -> Player:
	for player : Player in players:
		if peer_id == player.peer_id:
			return player
	return null

func get_tick_state(tick : int) -> TickState:
	if state_buffer.is_empty():
		return null
		
	var last_saved_tick : int = state_buffer.back().tick
	var tick_delta : int = last_saved_tick - tick
	if tick_delta < 0:
		push_error("get_tick_state() called for future tick not yet saved. Last Saved Tick %d, Requested Tick %d" % [last_saved_tick, tick])
		return null
	
	var state_index := -tick_delta - 1

	# possible when maybe recieving a really really old tick packet and we already cleaned it up from the buffer.
	if abs(state_index) > state_buffer.size():
		return null
	
	assert(state_buffer[state_index].tick == tick, "get_tick_state returned wrong tick. Wanted %d, returned %d" % [tick, state_buffer[state_index].tick])
	return state_buffer[state_index]

func get_or_add_tick_state(tick : int) -> TickState:
	var last_saved_tick : int = -1
	if state_buffer.is_empty() == false:
		last_saved_tick = state_buffer.back().tick
		
	var tick_delta : int = tick - last_saved_tick
	
	# we need to add new ticks.
	if (last_saved_tick == -1) || (tick_delta > 0):
		for new_tick in range(last_saved_tick + 1, tick + 1):
			state_buffer.push_back(TickState.new(new_tick))
		return state_buffer[-1]
	else:
		var state_index := tick_delta - 1
		assert("get_or_add_tick_state returned wrong tick. Wanted %d, returned %d" % [tick, state_buffer[state_index].tick])
		return state_buffer[tick_delta - 1]

func network_free(node: Node) -> void:
	var tick_state: TickState = get_or_add_tick_state(current_tick)
	if multiplayer.is_server():
		tick_state.destroy_events.push_back(node.get_path())
	
	node.queue_free()

func get_or_add_player_input(peer_id: int, tick: int) -> PlayerInput:
	var default_array : Array[PlayerInput] = []
	var player_input_buffer : Array[PlayerInput] = input_buffer.get_or_add(peer_id,default_array)
	
	# catch if the player tick belongs at the end of the the buffer
	if (player_input_buffer.size() == 0) || (tick > player_input_buffer.back().tick):
		var fresh_player_input := PlayerInput.new(tick, true, {})
		player_input_buffer.push_back(fresh_player_input) 
		return fresh_player_input
	
	for index in player_input_buffer.size():
		var player_input : PlayerInput = player_input_buffer[index]
		if tick == player_input.tick:
			return player_input
		
		if tick < player_input.tick:
			var fresh_player_input := PlayerInput.new(tick, true, {})
			player_input_buffer.insert(index, fresh_player_input)
			return fresh_player_input
	
	assert(false, "Error get_or_add_player_input()")
	return null

## TODO This is really non-performant. Enforce index to tick ratio just like state?
func get_player_input(peer_id: int, tick: int) -> PlayerInput:
	var default_array : Array[PlayerInput] = []
	var player_input_buffer : Array[PlayerInput] = input_buffer.get(peer_id, default_array)
	if player_input_buffer.is_empty():
		return null
		
	for player_input in player_input_buffer:
		if tick == player_input.tick:
			return player_input
	return null

func add_outbound_player_input(player_input : Dictionary) -> void:
	var serialized_player_input : PackedByteArray = message_serializer.serialize_player_input(player_input)
	player_input_departure_buffer.push_back(serialized_player_input)

func generate_input_prediction(previous_input: Dictionary) -> Dictionary:
	return previous_input

## Generates input prediction and saves it to the input_buffer.
## Returns newly generated input prediction. If no previous input can be found, just returns empty dictionary.
## TODO If on server, when we timeout on a client's unrecieved input and move on without them, advance their last_input_tick_recieved
func generate_and_save_input_prediction(tick: int, peer_id: int, node_path: String) -> Dictionary:
	var previous_player_input: PlayerInput = get_player_input(peer_id, tick - 1)
	if previous_player_input == null:
		return {}
	
	var fresh_input_prediction: Dictionary = generate_input_prediction(previous_player_input.input.get(node_path,{}))
	
	# save to input buffer
	var player_input: PlayerInput = get_or_add_player_input(peer_id, tick)
	if player_input.is_predicted == false:
		return player_input.input
	
	player_input.input[node_path] = fresh_input_prediction
	player_input.is_predicted = true
	
	return fresh_input_prediction
	
func request_rollback(tick : int) -> void:
	if (tick <= last_processed_tick) && ((tick < rollback_tick) || (rollback_tick == -1)):
		rollback_tick = tick 

func get_rollback_frames() -> int:
	return last_processed_tick - debug_last_recieved_state_tick

## calculated current buffer size for this player for throttling purposes.
func get_player_input_buffer_size(peer_id: int) -> int:
	if input_buffer.has(peer_id) == false:
		return 0
	
	var player_input_buffer: Array[PlayerInput] = input_buffer[peer_id]
	
	# starting at the last processed tick, count forward
	var true_input_count: int = 0
	var sequential_tick: int = last_processed_tick + 1
	for index in player_input_buffer.size():
		var player_input: PlayerInput = player_input_buffer[index]
		if player_input.tick > last_processed_tick && player_input.is_predicted == false && player_input.tick == sequential_tick:
			sequential_tick += 1
			true_input_count += 1 
	
	# Because we send redundant input messages, player should hypothetically only be missing the very most recent input.
	return true_input_count
		
func _ready() -> void:
	network_adaptor = NetworkAdaptor.new()
	add_child(network_adaptor)
	network_adaptor.recieve_input_update.connect(self.on_recieve_input_update)
	network_adaptor.recieve_state_update.connect(self.receive_state_update)
	network_adaptor.recieve_ping_update.connect(self.on_recieve_ping_update)
	
	message_serializer = MessageSerializer.new()

func begin_sync() -> void:
	network_state = NetworkState.SYNCING
	begin_syncing.emit()

@rpc("authority", "call_remote", "reliable")
func client_begin_sync() -> void:
	network_state = NetworkState.SYNCING
	begin_syncing.emit()

# Starts ticking the game. Call when you want the gameplay to start.
func game_start() -> void:
	network_state = NetworkState.STARTED
	client_game_start.rpc()

@rpc("authority", "call_local", "reliable")
func client_game_start() -> void:
	network_state = NetworkState.STARTED
	game_started.emit()

# main loop
func _physics_process(delta: float) -> void:
	if network_state == NetworkState.INACTIVE:
		return
	
	# Cleanup state buffer. Retire state that it's unlikely we'll need to return to.
	# Let's save the input buffer on the server so we can save it as a replay?
	cleanup_state_buffer()
	cleanup_input_buffer()
	#cleanup_manifest()
	
	if multiplayer.is_server() == false:
		if perform_realtime_tick() == false:
			push_error("CLIENT: Critical error. Closing!")
			get_tree().quit(1)
	else:
		if perform_server_realtime_tick() == false:
			push_error("SERVER: Critical error. Closing!")
			get_tree().quit(1)

func perform_server_realtime_tick() -> bool:
	current_tick = last_processed_tick + 1
	
	for player in players:
		network_adaptor.send_ping_request(player.peer_id)
	
	update_client_throttle()
	
	update_oldest_unrecieved_input_tick()
	
	network_tick()

	if not save_game_state(current_tick, true):
		push_error("error saving game in server realtime tick")
		return false
			
	if network_state == NetworkState.STARTED:
		last_processed_tick = last_processed_tick + 1
	
	send_state_to_all_clients()
	return true
	
func perform_realtime_tick() -> bool:

	network_adaptor.send_ping_request(1)
	
	perform_rollback()
	
	# UPSTREAM THROTTLE. Modulate time to increase or decrease input sent to server. See Overwatch.
	if tick_throttle > 0:
		Engine.physics_ticks_per_second = 66
	elif tick_throttle == 0:
		Engine.physics_ticks_per_second = 60
	elif tick_throttle < 0:
		Engine.physics_ticks_per_second = 54
	
	current_tick = last_processed_tick + 1
	
	# Cleanup departing player input buffer
	if last_unconfirmed_player_tick > last_unconfirmed_player_tick_old:
		var delta_tick : int = last_unconfirmed_player_tick - last_unconfirmed_player_tick_old
		
		for count in delta_tick:
			player_input_departure_buffer.pop_front()
			
		last_unconfirmed_player_tick_old = last_unconfirmed_player_tick
	
	# Gather local input from all entities
	var local_input := gather_local_input()
	var player_input := get_or_add_player_input(multiplayer.get_unique_id(), current_tick)
	player_input.input = local_input
	player_input.is_predicted = false

	# throw the new input onto the hopper to be sent off eventually
	add_outbound_player_input(local_input)
	
	# We want the grab all the input from the last_unconfirmed_player_tick to the most 
	# recent tick (if possible based on message size). We want the redundancy of resending ticks so 
	# theres a higher chance they get through and we dont have to wait on the last_confirmed_player_tick.
	send_all_unconfirmed_input_to_server()
	
	# Perform Tick
	network_tick()
	
	# Save Game State
	if not save_game_state(current_tick, false):
		return false
	
	if network_state == NetworkState.STARTED:
		last_processed_tick = last_processed_tick + 1
	
	return true

func network_tick() -> void:
	# Call on this node grabbing either from entity state or the input state, neutral
	var nodes : Array[Node] = get_tree().get_nodes_in_group(NETWORK_ENTITY_GROUP)
	for node in nodes:
		if node.is_queued_for_deletion():
			continue
			
		var player : Player = get_player(node.get_multiplayer_authority())
		var node_input: Dictionary
		if player != null:
			var player_input : PlayerInput = get_player_input(node.get_multiplayer_authority(), current_tick)
			
			# if we dont have any true input, then do a prediction.
			if player_input == null || player_input.is_predicted:
				node_input = generate_and_save_input_prediction(current_tick, node.get_multiplayer_authority(), node.get_path())
				# Dont log spam me at the start while we are syncing the server and client up. There will always be starvation at the beginning.
				if multiplayer.is_server() && network_state != NetworkState.SYNCING:
					print("Server: STARVATION: %d on tick %d" % [player.peer_id, current_tick])
			else:
				node_input = player_input.input.get(String(node.get_path()), {})
		
		if node.has_method(NETWORK_PROCESS_FUNCTION):
			node.call(NETWORK_PROCESS_FUNCTION, node_input)

func update_client_throttle() -> void:
	for player in players:
		var player_input_buffer_size: int = get_player_input_buffer_size(player.peer_id)
		
		# all calculations are in milliseconds.
		# minimum should always be at least 1
		var minimum_buffer_size: int = maxi(1, ceili((float(Engine.physics_ticks_per_second) / 1000.0) * float(player.ping)))
		var maximum_buffer_size: int = input_buffer_range_max + minimum_buffer_size
		
		if player_input_buffer_size < minimum_buffer_size:
			#print("Server: LOW BUFFER %d on %d: %d < [%d : %d]" % [player.peer_id, current_tick, player_input_buffer_size, minimum_buffer_size, maximum_buffer_size])
			player.tick_throttle = 1 
		elif player_input_buffer_size > maximum_buffer_size:
			#print("Server: HIGH BUFFER %d on %d: %d > [%d : %d]" % [player.peer_id, current_tick, player_input_buffer_size, minimum_buffer_size, maximum_buffer_size])
			player.tick_throttle = -1
		else:
			player.tick_throttle = 0

## Either add or modify state buffer
func save_game_state(tick: int, should_overwrite_true_states : bool = true) -> bool:
	var tick_state := get_or_add_tick_state(tick)
	if tick_state == null:
		push_error("save_game_state(), could not generate new tick")
		return false
	
	var entity_states : Dictionary = tick_state.entity_states
	var nodes : Array[Node] = get_tree().get_nodes_in_group(NETWORK_ENTITY_GROUP)
	for node in nodes:
		if !node.has_method(SAVE_STATE_FUNCTION) || !node.is_inside_tree() || node.is_queued_for_deletion():
			continue
		
		# Does a state exist for this node currently? If not create one.
		var node_path : String = node.get_path()
		var entity_state : EntityState = entity_states.get_or_add(node_path, EntityState.new())

		# Keep in mind, on the client we NEVER want to overwrite a true state.
		if should_overwrite_true_states || entity_state.is_true == false:
			entity_state.scene_asset = node.scene_file_path
			entity_state.owning_peer = node.get_multiplayer_authority()
			entity_state.state = node.call(SAVE_STATE_FUNCTION)
	
	return true

## loads game state.
## Arguement only_load_true_states is for loading each tick of a rollback after the inital load were we want to everything.
func load_game_state(tick: int) -> bool:
	var tick_state := get_tick_state(tick)

	if tick_state == null:
		assert(tick_state != null, "Tried to load state we dont have.")
		return false
		
	var entity_states : Dictionary = tick_state.entity_states
	
	var current_nodes : Array[Node] = get_tree().get_nodes_in_group(NETWORK_ENTITY_GROUP)
	
	# loop over manifest, and ensure proper spawns
	for manifest_node_path: String in node_manifest:
		var node_lifetime: NodeLifetime = node_manifest[manifest_node_path]
		
		if node_lifetime.is_alive(tick) == false:
			continue
	
		# if node doesnt exist, spawn it.
		if current_nodes.any(func(node: Node)-> bool: return String(node.get_path()) == manifest_node_path) == false:
			# create missing scene
			# TODO: synch Loading assets like this is probably a terrible idea
			var scene: PackedScene = load(node_lifetime.asset)
			var instance: Node = scene.instantiate()
			var node_path: NodePath = NodePath(manifest_node_path)
			instance.set_multiplayer_authority(node_lifetime.owning_peer)
			instance.name = String(node_path.get_name(node_path.get_name_count() - 1))

			get_tree().current_scene.add_child(instance)
			current_nodes.push_back(instance)
		
	# We are doing an initial rollback load, we delete everything thats not in the manifest. 
	# If its not in the manifest then it's some kind of client prediction, that never had a server-side spawn.
	for node in current_nodes:
		if !node.has_method(LOAD_STATE_FUNCTION) || !node.is_inside_tree() || node.is_queued_for_deletion():
			continue
			
		var node_path: NodePath = node.get_path()
		var manifest_entry: NodeLifetime = node_manifest.get(node_path)
		
		# node does not have an entry in the manifest then it is a prediction and should be destroyed
		if manifest_entry == null || manifest_entry.is_alive(tick) == false:
			node.queue_free()
			continue
			
		# update existing nodes
		var entity_state : EntityState = entity_states.get(node_path)
		if entity_state == null:
			push_error("Could Not find Entity State for node %n tick %d" % [node_path, tick])
			return false
		node.call(LOAD_STATE_FUNCTION, entity_state.state)

	return true

## Gathers all the input for everynode this client has authority over. Called on clients. 
func gather_local_input() -> Dictionary:
	var local_player_input := {}
	var nodes : Array[Node] = get_tree().get_nodes_in_group(NETWORK_ENTITY_GROUP)
	for node in nodes:
		if !node.has_method(GET_LOCAL_INPUT_FUNCTION) \
		|| !node.is_inside_tree() \
		|| node.is_queued_for_deletion() \
		|| !node.is_multiplayer_authority():
			continue
		
		var node_input : Dictionary = node.call(GET_LOCAL_INPUT_FUNCTION)
		local_player_input[String(node.get_path())] = node_input

	return local_player_input

## Client Side: Each frame load true state if it exits, or calculate predictated state if it does not.
func perform_rollback() -> bool:
	if rollback_tick < 0:
		return true
	is_rollback = true
	
	# Rewind Time and load rollback state.
	if not load_game_state(rollback_tick):
		return false
	
	# loop and perform ticks.
	# rollback tick is for the state we just recieved. The state is at the end of the tick frame. If we
	# started at rollback_tick, we would double process the first tick  
	var rollback_starting_tick: int = rollback_tick + 1
	for tick in range(rollback_starting_tick, last_processed_tick + 1): 
		current_tick = tick
		network_tick()	

		# save new state each tick.
		save_game_state(current_tick, false)
		
	is_rollback = false
	current_tick = last_processed_tick + 1
	rollback_tick = -1
	return true

# on server
func update_oldest_unrecieved_input_tick() -> void:
	for player in players:
		if input_buffer.has(player.peer_id) == false:
			return
			
		var player_input_buffer: Array[PlayerInput] = input_buffer[player.peer_id]
		for index in player_input_buffer.size():
			var player_input: PlayerInput = get_player_input(player.peer_id, player.oldest_unrecieved_input_tick)
			if player_input == null:
				break
			elif player_input.is_predicted == false:
				player.oldest_unrecieved_input_tick += 1
	
## On Server
func send_state_to_all_clients() -> void:
	# Generate a single state message
	var primary_message: Dictionary
	# Pack on all housekeeping information, like oldest_unrecieved_input_tick, tick_throttle. This will only be attached to first packet.
	primary_message[message_serializer.StateUpdateKeys.TICK] = current_tick

	# generate list of destruction events, from the last client acknoledgement to last_processed_tick. This will be attached to first packet.
	var latest_state: TickState = get_tick_state(current_tick)
	if latest_state != null:
		
		# generate serialized list of most current states. If this gets too big, then break up into subsequent State-Only packets.
		var serialized_node_state_messages: Array[PackedByteArray] = []
		for node_path: String in latest_state.entity_states:
			var entity_state: EntityState = latest_state.entity_states[node_path]
			var node_state_message: Dictionary
			node_state_message[message_serializer.NodeStateKeys.NODE_PATH] = node_path
			node_state_message[message_serializer.NodeStateKeys.ASSET] = entity_state.scene_asset
			node_state_message[message_serializer.NodeStateKeys.STATE] = message_serializer.default_serialize_state(entity_state.state)
			node_state_message[message_serializer.NodeStateKeys.OWNER] = entity_state.owning_peer
			
			# Grab the input for this node on this frame, if its controlled by a player.
			if entity_state.owning_peer != 1:
				var player_input: PlayerInput = get_player_input(entity_state.owning_peer, current_tick)
				if player_input != null:
					node_state_message[message_serializer.NodeStateKeys.PLAYER_INPUT] = message_serializer.serialize_node_input(player_input.input)
			#else:
			#	node_state_message[message_serializer.NodeStateKeys.PLAYER_INPUT] = PackedByteArray()
			
			var serialized_node_state_message: PackedByteArray = message_serializer.serializer_node_state_message(node_state_message)
			var debug_node_message: Dictionary = message_serializer.deserializer_node_state_message(serialized_node_state_message)
			
			assert(node_state_message[message_serializer.NodeStateKeys.NODE_PATH] == debug_node_message[message_serializer.NodeStateKeys.NODE_PATH])
			assert(node_state_message[message_serializer.NodeStateKeys.ASSET] == debug_node_message[message_serializer.NodeStateKeys.ASSET])
			assert(message_serializer.default_deserialize_state(node_state_message[message_serializer.NodeStateKeys.STATE]) == message_serializer.default_deserialize_state(debug_node_message[message_serializer.NodeStateKeys.STATE]))
			assert(node_state_message[message_serializer.NodeStateKeys.OWNER] == debug_node_message[message_serializer.NodeStateKeys.OWNER])
			
			serialized_node_state_messages.push_back(serialized_node_state_message)
		
		primary_message[message_serializer.StateUpdateKeys.STATE] = serialized_node_state_messages
		
	# loop over players and send everyone that state message
	for player in players:
		primary_message[message_serializer.StateUpdateKeys.OLDEST_INPUT_TICK_UNRECIEVED] = player.oldest_unrecieved_input_tick
		primary_message[message_serializer.StateUpdateKeys.THROTTLE_COMMAND] = player.tick_throttle
		
		# grab all the nodes that have changed since last confirmation from the client
		var node_manifest_to_send := {}
		for node_path: String in node_manifest:
			var lifetime: NodeLifetime = node_manifest[node_path]
			if lifetime.spawn_tick >= player.client_received_state_tick || lifetime.destroy_tick > current_tick:
				node_manifest_to_send[node_path] = lifetime
		
		for manifest_node_path: String in node_manifest:
			print("Server: %d - %s" % [get_current_tick(), manifest_node_path])
		
		var serialized_manifest: PackedByteArray = message_serializer.serialize_manifest(node_manifest_to_send)
		var deserialized_manifest: Dictionary = message_serializer.deserialize_manifest(serialized_manifest)
		#assert(deserialized_manifest == node_manifest_to_send)
		primary_message[message_serializer.StateUpdateKeys.MANIFEST] = serialized_manifest
		
		var serialized_message: PackedByteArray = message_serializer.serialize_state_update_message(primary_message)
		var deserialized_message: Dictionary = message_serializer.deserialize_state_update_message(serialized_message)
		
		assert(primary_message[message_serializer.StateUpdateKeys.TICK] == deserialized_message[message_serializer.StateUpdateKeys.TICK])
		assert(primary_message[message_serializer.StateUpdateKeys.OLDEST_INPUT_TICK_UNRECIEVED] == deserialized_message[message_serializer.StateUpdateKeys.OLDEST_INPUT_TICK_UNRECIEVED])
		assert(primary_message[message_serializer.StateUpdateKeys.THROTTLE_COMMAND] == deserialized_message[message_serializer.StateUpdateKeys.THROTTLE_COMMAND])
		assert(primary_message[message_serializer.StateUpdateKeys.STATE].size() == deserialized_message[message_serializer.StateUpdateKeys.STATE].size())
		assert(primary_message[message_serializer.StateUpdateKeys.MANIFEST] == deserialized_message[message_serializer.StateUpdateKeys.MANIFEST])
		
		send_state_to_client(player.peer_id, serialized_message)

## On Server
func send_state_to_client(peer_id: int, serialized_message: PackedByteArray) -> void:
	network_adaptor.send_state_update(peer_id, serialized_message)

func receive_state_update(serialized_message: PackedByteArray) -> void:
	var message: Dictionary = message_serializer.deserialize_state_update_message(serialized_message)
	
	var tick: int = message[message_serializer.StateUpdateKeys.TICK]
	
	if tick > debug_last_recieved_state_tick:
		debug_last_recieved_state_tick = tick
	
	if tick > last_received_state_tick:
		last_received_state_tick = tick
	
	tick_throttle = message[message_serializer.StateUpdateKeys.THROTTLE_COMMAND]
	
	var new_input_unrecieved : int = message[message_serializer.StateUpdateKeys.OLDEST_INPUT_TICK_UNRECIEVED]
	if new_input_unrecieved > last_unconfirmed_player_tick:
		last_unconfirmed_player_tick = new_input_unrecieved
	
	var tick_state : TickState = get_or_add_tick_state(tick)
	
	# TODO update node manifest
	var new_node_manifest: Dictionary = message_serializer.deserialize_manifest(message[message_serializer.StateUpdateKeys.MANIFEST])
	
	node_manifest.merge(new_node_manifest, true)
	for manifest_node_path: String in node_manifest:
		print("%d: %d - %s" % [multiplayer.get_unique_id(), get_current_tick(), manifest_node_path])
	
	var node_states: Array[PackedByteArray] = message[message_serializer.StateUpdateKeys.STATE]
	for node_state in node_states:
		var node_state_message: Dictionary = message_serializer.deserializer_node_state_message(node_state)
		var node_path: String = node_state_message[message_serializer.NodeStateKeys.NODE_PATH]
		var entity_state : EntityState = tick_state.entity_states.get_or_add(node_path, EntityState.new())
		entity_state.scene_asset = node_state_message[message_serializer.NodeStateKeys.ASSET]
		entity_state.owning_peer = node_state_message[message_serializer.NodeStateKeys.OWNER]
		entity_state.state = message_serializer.default_deserialize_state(node_state_message[message_serializer.NodeStateKeys.STATE])
		
		var node_input: Dictionary = message_serializer.deserialize_node_input(node_state_message[message_serializer.NodeStateKeys.PLAYER_INPUT])
		var player_input: PlayerInput = get_or_add_player_input(entity_state.owning_peer, tick)
		player_input.input[node_path] = node_input
		player_input.is_predicted = false
				
		if entity_state.is_true == false:
			request_rollback(tick)
			entity_state.is_true = true

func send_all_unconfirmed_input_to_server() -> void:
	var unconfirmed_input: Array[PackedByteArray] = player_input_departure_buffer.duplicate()

	var messages_to_send: int = ceili(float(unconfirmed_input.size()) / float(MAX_PLAYER_INPUT_TICKS_PER_MESSAGE))
	
	for count in messages_to_send:
		var start_index: int = count * MAX_PLAYER_INPUT_TICKS_PER_MESSAGE
		var end_index: int = (count + 1) * MAX_PLAYER_INPUT_TICKS_PER_MESSAGE
		var initial_tick: int = last_unconfirmed_player_tick + (count * MAX_PLAYER_INPUT_TICKS_PER_MESSAGE)
		send_input_to_server(unconfirmed_input.slice(start_index, end_index), initial_tick)

## On Client, used to send local player input for all nodes up to the server
func send_input_to_server(serialized_input_ticks: Array[PackedByteArray], initial_tick : int, peer_id : int = 1) -> void:
	var message := {}
	message[message_serializer.PlayerInputKeys.INITIAL_TICK] = initial_tick
	message[message_serializer.PlayerInputKeys.PLAYER_INPUT_DATA] = serialized_input_ticks
	message[message_serializer.PlayerInputKeys.LAST_RECEIVED_STATE_TICK] = last_received_state_tick
	var message_bytes : PackedByteArray = message_serializer.serialize_input_message(message)
	
	# Debug
	var tick_string : String = ""
	for index in serialized_input_ticks.size():
		tick_string = "%s, %d" % [tick_string, index + initial_tick]
	#print("CLIENT: send_input_to_server, message size: %d, init tick %d, array size: %d : %s" % [message_bytes.size(), initial_tick, serialized_input_ticks.size(), tick_string])
	network_adaptor.send_input_update(peer_id, message_bytes)

## On Server
func on_recieve_input_update(peer_id: int, serialized_message: PackedByteArray) -> void:
	var message : Dictionary = message_serializer.deserialize_input_message(serialized_message)
	
	var initial_tick : int = message[message_serializer.PlayerInputKeys.INITIAL_TICK]
	var player_input_data : Array[PackedByteArray] = message[message_serializer.PlayerInputKeys.PLAYER_INPUT_DATA]
	var last_tick : int = initial_tick + player_input_data.size()
	
	var player : Player = get_player(peer_id)
	
	# save the inputs to the state_buffer	
	#if last_tick > player.last_input_tick_recieved:
	for input_index in player_input_data.size():
		var input_tick := input_index + initial_tick
		
		var player_input : PlayerInput = get_or_add_player_input(peer_id, input_tick)
		
		var recieved_player_input := message_serializer.deserialize_player_input(player_input_data[input_index])
		player_input.input = recieved_player_input
		player_input.is_predicted = false
	
	player.client_received_state_tick = message[message_serializer.PlayerInputKeys.LAST_RECEIVED_STATE_TICK]
	
# client
func cleanup_state_buffer() -> void:
	# remove all state buffers older than the cut off.
	var max_elements: int = MAX_STATE_BUFFER_SIZE_SERVER if multiplayer.is_server() else MAX_BUFFER_SIZE_CLIENT
	var elements_to_remove: int = state_buffer.size() - max_elements
	
	if elements_to_remove <= 0:
		return
	
	for count in elements_to_remove:
		state_buffer.pop_front()

func cleanup_input_buffer() -> void:
	var max_elements: int = MAX_INPUT_BUFFER_SIZE_SERVER if multiplayer.is_server() else MAX_BUFFER_SIZE_CLIENT
	
	for peer_id: int in input_buffer:
		var player_input_buffer : Array[PlayerInput] = input_buffer[peer_id]
		var elements_to_remove: int = player_input_buffer.size() - max_elements
		
		if elements_to_remove <= 0:
			return
		
		for count in elements_to_remove:
			player_input_buffer.pop_front()

# TODO this is probably really inefficient
func cleanup_manifest() -> void:
	# loop over the manifest and remove destroyed nodes that are old.
	for node_path: String in node_manifest:
		var lifetime : NodeLifetime = node_manifest[node_path]
		if current_tick - lifetime.destroy_tick > MAX_NODE_MANIFEST_AGE:
			node_manifest.erase(node_path) 

func on_recieve_ping_update(ping: int, peer_id: int) -> void:
	if multiplayer.is_server() == false:
		peer_id = multiplayer.get_unique_id()
	var player: Player = get_player(peer_id)
	assert(player != null, "Recieved ping from unknown player")
	player.ping = ping
