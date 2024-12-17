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

# Variables
var started : bool

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
var debug_ticks_since_last_process: int = 0

var tick_throttle: int = 0

var minimum_target_input_buffer_size: int = 2
var maximum_target_input_buffer_size: int = 7

var wait_for_all_player_input: bool = false

# Signals
signal game_started()
signal game_stopped()
signal game_error()

class Player extends Object:
	var peer_id : int
	var ping: int = -1
	var packet_reception_history: int
	var packet_history_length: int = 100
	var tick_throttle: int = 0
	
	var debug_buffer_total: int = 0
	
	func _init() -> void:
		packet_reception_history = packet_history_length
	
	func packet_recieved() -> void:
		packet_reception_history += 1
		packet_reception_history = clampi(packet_reception_history, -100, 100)
	
	func update_packet_reception_history() -> void:
		packet_reception_history -= 1
	
	func get_packet_loss() -> float:
		return (packet_history_length - packet_reception_history) / packet_history_length

var players : Array[Player]

## indexed by tick. Element Last is most recent.
var state_buffer : Array[TickState]

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
	var is_true: bool = false
	
	var state: Dictionary

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
	
	var fresh_input_prediction: Dictionary = generate_input_prediction(previous_player_input.input[node_path])
	
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
	for index in player_input_buffer.size():
		var player_input: PlayerInput = player_input_buffer[index]
		if player_input.tick > last_processed_tick && player_input.is_predicted == false:
			true_input_count += 1 
	
	# Because we send redundant input messages, player should hypothetically only be missing the very most recent input.
	return true_input_count
		

func _ready() -> void:
	network_adaptor = NetworkAdaptor.new()
	add_child(network_adaptor)
	network_adaptor.recieve_input_update.connect(self.on_recieve_input_update)
	network_adaptor.recieve_state_update.connect(self.on_recieve_node_state_update)
	network_adaptor.recieve_ping_update.connect(self.on_recieve_ping_update)
	
	message_serializer = MessageSerializer.new()

# Starts ticking the game. Call when you want the gameplay to start.
func game_start() -> void:
	started = true
	client_game_start.rpc()

@rpc("authority", "call_local", "reliable")
func client_game_start() -> void:
	started = true
	game_started.emit()

# main loop
func _physics_process(delta: float) -> void:
	if not started:
		return
	
	if multiplayer.is_server() == false:
		print ("Delta %f throttle %d" % [delta,tick_throttle])
	# Cleanup state buffer. Retire state that it's unlikely we'll need to return to.
	# Let's save the input buffer on the server so we can save it as a replay?
	cleanup_state_buffer()
	cleanup_input_buffer()
	
	if multiplayer.is_server() == false:
		if perform_realtime_tick() == false:
			get_tree().quit(1)
	else:
		if perform_server_realtime_tick() == false:
			get_tree().quit(1)

func perform_server_realtime_tick() -> bool:
	if started == false:
		return true
	
	current_tick = last_processed_tick + 1
	
	# update throttling
	for player in players:
		player.update_packet_reception_history()
		var player_input_buffer_size: int = get_player_input_buffer_size(player.peer_id)
		player.debug_buffer_total += player_input_buffer_size
		var average_buffer_size:float = player.debug_buffer_total / (current_tick + 1)
		print("Server: Ave Buffer: %f" % average_buffer_size)
		if player_input_buffer_size < 3:
			player.tick_throttle = 1
		else:
			player.tick_throttle = 0
	
	var should_tick: bool = true
	
	# Old: Before the input buffer and throttling, I used to wait for all inputs from all players before ticking.
	if wait_for_all_player_input:
		for player in players:
			var player_input := get_player_input(player.peer_id, current_tick)
			if player_input == null || player_input.is_predicted == true:
				should_tick = false
				break
			
	if should_tick:
		network_tick()

		if not save_game_state(current_tick, true):
			push_error("error saving game in server realtime tick")
			return false
		
		last_processed_tick = last_processed_tick + 1
		#print("SERVER: TICK:%d %d " % [debug_ticks_since_last_process,last_processed_tick])
		debug_ticks_since_last_process = 0
	
	debug_ticks_since_last_process = debug_ticks_since_last_process + 1
	send_state_to_all_clients()
	return true
	
func perform_realtime_tick() -> bool:
	if started == false:
		return true
		
	network_adaptor.send_ping_request(1)
	
	perform_rollback()
	
	# UPSTREAM THROTTLE. Modulate time to increase or decrease input sent to server. See Overwatch.
	if tick_throttle > 0:
		Engine.physics_ticks_per_second = 120
	else:
		Engine.physics_ticks_per_second = 60
	
	current_tick = last_processed_tick + 1
	
	# Cleanup departing player input buffer
	if multiplayer.is_server() == false:
		if last_unconfirmed_player_tick > last_unconfirmed_player_tick_old:
			var delta_tick : int = last_unconfirmed_player_tick - last_unconfirmed_player_tick_old
			
			for count in delta_tick:
				player_input_departure_buffer.pop_front()
				
			last_unconfirmed_player_tick_old = last_unconfirmed_player_tick
	
	# STEP 3: GATHER INPUT
	# create a new state for this tick
	get_or_add_tick_state(get_current_tick())
	
	# Gather local input from all entities
	if multiplayer.is_server() == false:
		var local_input := gather_local_input()
		var player_input := get_or_add_player_input(multiplayer.get_unique_id(), current_tick)
		player_input.input = local_input
		player_input.is_predicted = false
	
		# throw the new input onto the hopper to be sent off eventually
		add_outbound_player_input(local_input)
	
	# Client: Send input to server
	# We want the grab all the input from the last_unconfirmed_player_tick to the most 
	# recent tick (if possible based on message size). We want the redundancy of resending ticks so 
	# theres a higher chance they get through and we dont have to wait on the last_confirmed_player_tick.
	if multiplayer.is_server() == false:
		send_all_unconfirmed_input_to_server()
	
	# Step 4: Clients Do tick and save resulting state
	# Perform Tick
	network_tick()
	
	# Save Game State
	# create a new Tick State
	if not save_game_state(current_tick, false):
		return false
	
	#print("CLIENT: processed tick: %d" % current_tick)
	last_processed_tick = last_processed_tick + 1
	
	return true

func network_tick() -> void:
	# Call on this node grabbing either from entity state or the input state, neutral
	var nodes : Array[Node] = get_tree().get_nodes_in_group(NETWORK_ENTITY_GROUP)
	for node in nodes:
		var player : Player = get_player(node.get_multiplayer_authority())
		var node_input: Dictionary
		if player != null:
			var player_input : PlayerInput = get_player_input(node.get_multiplayer_authority(), current_tick)
			
			# if we dont have any true input, then do a prediction.
			
			if player_input == null || player_input.is_predicted:
				node_input = generate_and_save_input_prediction(current_tick, node.get_multiplayer_authority(), node.get_path())
				if multiplayer.is_server():
					print("Server: STARVATION %d" % get_player_input_buffer_size(player.peer_id))
			else:
				node_input = player_input.input.get(String(node.get_path()), {})
		
		if node.has_method(NETWORK_PROCESS_FUNCTION):
			node.call(NETWORK_PROCESS_FUNCTION, node_input)

## Either add or modify state buffer
func save_game_state(tick: int, should_overwrite_true_states : bool = true) -> bool:
	var tick_state := get_or_add_tick_state(tick)
	if tick_state == null:
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
			entity_state.state = node.call(SAVE_STATE_FUNCTION)
	
	return true

## loads game state.
## Arguement only_load_true_states is for loading each tick of a rollback after the inital load were we want to everything.
func load_game_state(tick: int, only_load_true_states : bool = false) -> bool:
	var tick_state := get_tick_state(tick)

	if tick_state == null:
		assert(tick_state != null, "Tried to load state we dont have.")
		return false
		
	var entity_states : Dictionary = tick_state.entity_states
	
	var nodes : Array[Node] = get_tree().get_nodes_in_group(NETWORK_ENTITY_GROUP)
	for node in nodes: 
		if !node.has_method(LOAD_STATE_FUNCTION) || !node.is_inside_tree() || node.is_queued_for_deletion():
			continue
			
		var node_path : String = node.get_path()
		var entity_state : EntityState = entity_states.get(node_path)
		
		if entity_state == null:
			continue
		
		if (only_load_true_states && entity_state.is_true) || only_load_true_states == false:
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

## Grab the inputs from last confirmed player input tick to most recent tick.
func get_departing_player_input() -> Array[PackedByteArray]:
	var departing_player_input : Array[PackedByteArray] = player_input_departure_buffer.slice(0, MAX_PLAYER_INPUT_TICKS_PER_MESSAGE)
	return departing_player_input

## Client Side: Each frame load true state if it exits, or calculate predictated state if it does not.
func perform_rollback() -> bool:
	if rollback_tick < 0:
		return true
	#print("CLIENT: Rollback to %d" % rollback_tick)
	is_rollback = true
	
	# Rewind Time and load rollback state.
	if not load_game_state(rollback_tick, false):
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

## On Server
func send_state_to_all_clients() -> void:
	# first get the last processed tick
	var latest_state := get_tick_state(last_processed_tick)
	if latest_state == null:
		return
	
	for node_path : String in latest_state.entity_states:
		var authority_peer_id : int = get_node(node_path).get_multiplayer_authority()
		var player_input_for_node : Dictionary = {}
		if authority_peer_id != 1: 
			var player_input : PlayerInput = get_player_input(authority_peer_id, last_processed_tick)
			if player_input == null:
				continue
			player_input_for_node = player_input.input.get(node_path, {})

		var node_state : Dictionary = latest_state.entity_states[node_path].state
		
		for player in players:
			if input_buffer.has(player.peer_id) == false:
				break
				
			var player_input_buffer: Array[PlayerInput] = input_buffer[player.peer_id]
			var oldest_unrecieved_input_tick: int = last_processed_tick + 1
			for index in player_input_buffer.size():
				var player_input: PlayerInput = get_player_input(player.peer_id, oldest_unrecieved_input_tick)
				if player_input == null:
					break
				elif player_input.is_predicted == false:
					oldest_unrecieved_input_tick = 1 + oldest_unrecieved_input_tick
			
			#print("SERVER: %d oldest_unconfirmed: %d" % [last_processed_tick, oldest_unrecieved_input_tick])
			send_node_state_to_client(player.peer_id, last_processed_tick, node_path, node_state, authority_peer_id, player_input_for_node, oldest_unrecieved_input_tick, player.tick_throttle)

## On Server
func send_node_state_to_client(\
	peer_id: int,\
	tick: int,\
	node_path: String,\
	node_state: Dictionary,\
	input_peer_id: int,\
	node_input: Dictionary,\
	oldest_unrecieved_input_tick: int,\
	throttle_command: int) -> void:
	
	var message := {}
	message[message_serializer.StateKeys.TICK] = tick
	message[message_serializer.StateKeys.INPUT_PEER_ID] = input_peer_id
	message[message_serializer.StateKeys.NODE_PATH] = node_path
	message[message_serializer.StateKeys.STATE] = message_serializer.serialize_state(node_state)
	message[message_serializer.StateKeys.PLAYER_INPUT_DATA] = message_serializer.serialize_node_input(node_input)
	message[message_serializer.StateKeys.OLDEST_INPUT_TICK_UNRECIEVED] = oldest_unrecieved_input_tick
	message[message_serializer.StateKeys.THROTTLE_COMMAND] = throttle_command
	
	var message_data : PackedByteArray = message_serializer.serialize_state_message(message)
	assert(message_data.size() != 0, "Error serializing state")
	
	network_adaptor.send_state_update(peer_id, message_data)

## On Client. State update for a single node.
func on_recieve_node_state_update(serialized_message: PackedByteArray) -> void:
	assert(serialized_message.size() != 0, "Recieved empty state message")
	
	var message := message_serializer.deserialize_state_message(serialized_message)
	assert(message.is_empty() != true, "Deserialization issue.")
	
	var tick : int = message[message_serializer.StateKeys.TICK]
	# the clients should always be ahead of the server, im pretty sure.
	#assert(tick <= last_processed_tick, "Client recieved state update from future.")
	
	# we have the state for a single node here
	var tick_state : TickState = get_tick_state(tick)
	if tick_state == null:
		return

	# update state buffer
	var node_path : String = message[message_serializer.StateKeys.NODE_PATH]
	assert(tick_state.entity_states.get(node_path) != null, "Received state for node that doesnt exist in local state_buffer")
	
	var entity_state : EntityState = tick_state.entity_states[node_path]
	entity_state.state = message[message_serializer.StateKeys.STATE]
	
	# request a rollback if we just recieved a new state
	if entity_state.is_true == false:
		request_rollback(tick)
		entity_state.is_true = true
		
	# update input buffer
	var input_peer_id : int = message[message_serializer.StateKeys.INPUT_PEER_ID] 
	var player_input := get_or_add_player_input(input_peer_id, tick)
	player_input.input[node_path] = message[message_serializer.StateKeys.PLAYER_INPUT_DATA]
	player_input.is_predicted = false
	
	var new_input_unrecieved : int = message[message_serializer.StateKeys.OLDEST_INPUT_TICK_UNRECIEVED]
	if new_input_unrecieved > last_unconfirmed_player_tick:
		#print("CLIENT %d: input confirmation %d -> %d" % [multiplayer.get_unique_id(), last_unconfirmed_player_tick, new_input_unrecieved])
		last_unconfirmed_player_tick = new_input_unrecieved
	
	tick_throttle = message[message_serializer.StateKeys.THROTTLE_COMMAND]
	
	if tick > debug_last_recieved_state_tick:
		debug_last_recieved_state_tick = tick

func send_all_unconfirmed_input_to_server() -> void:
	var unconfirmed_input: Array[PackedByteArray] = player_input_departure_buffer.duplicate()

	var messages_to_send: int = ceili(float(unconfirmed_input.size()) / float(MAX_PLAYER_INPUT_TICKS_PER_MESSAGE))
	var debug_string: String = "CLIENT %d: Send Tick %d, Last %d Buffer Size: %d" % [multiplayer.get_unique_id(), current_tick, current_tick - unconfirmed_input.size(), unconfirmed_input.size()]
	
	for count in messages_to_send:
		var start_index: int = count * MAX_PLAYER_INPUT_TICKS_PER_MESSAGE
		var end_index: int = (count + 1) * MAX_PLAYER_INPUT_TICKS_PER_MESSAGE
		var initial_tick: int = last_unconfirmed_player_tick + (count * MAX_PLAYER_INPUT_TICKS_PER_MESSAGE)
		#debug_string = debug_string + ("[%d, %d], " % [start_index, start_index + MAX_PLAYER_INPUT_TICKS_PER_MESSAGE])
		send_input_to_server(unconfirmed_input.slice(start_index, end_index), initial_tick)
	
	#print(debug_string)

## On Client, used to send local player input for all nodes up to the server
func send_input_to_server(serialized_input_ticks: Array[PackedByteArray], initial_tick : int, peer_id : int = 1) -> void:
	var message := {}
	message[message_serializer.PlayerInputKeys.INITIAL_TICK] = initial_tick
	message[message_serializer.PlayerInputKeys.PLAYER_INPUT_DATA] = serialized_input_ticks
	
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
	
	player.packet_recieved()

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
			
func on_recieve_ping_update(ping: int) -> void:
	var player: Player = get_player(multiplayer.get_unique_id())
	player.ping = ping
