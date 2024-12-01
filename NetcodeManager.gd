extends Node

# Preloads
const NetworkAdaptor = preload("res://NetworkAdaptor.gd")
const MessageSerializer = preload("res://MessageSerializer.gd")

# Consts
const NETWORK_ENTITY_GROUP : String = "network_entity"
const SAVE_STATE_FUNCTION : String = "_save_state"
const LOAD_STATE_FUNCTION : String = "_load_state"
const GET_LOCAL_INPUT_FUNCTION : String = "_get_local_input"
const TRANSFORM_PROCESS_FUNCTION : String = "transform_process_function"

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
var last_confirmed_player_tick : int = -1
# used for updating var player_input_departure_buffer. DO NOT MANUALLY UPDATE
var last_confirmed_player_tick_old : int = -1

var max_player_input_ticks_per_message : int = 5

var network_adaptor : NetworkAdaptor
var message_serializer : MessageSerializer

## Array of serialized player input that needs to be sent off to the server. Shrinks as we
## get confirmations from the server that it recieved our input. A client input tick must eventually
## arrive.
## Element 0: player_input for tick last_confirmed_player_tick + 1
## Element Last: most recent player input tick
var player_input_departure_buffer : Array[PackedByteArray]

# Signals
signal game_started()
signal game_stopped()
signal game_error()

class Player extends Object:
	var peer_id : int
	var last_input_tick_recieved : int = -1

var players : Array[Player]

## indexed by tick. Element Last is most recent.
var state_buffer : Array[TickState]

# TODO, split off input into its own buffer: peer_id -> Array[InputState]

## state on this tick
class TickState extends Object:
	## tick for this state
	var tick : int
	
	## node path -> EntityState
	var entity_states : Dictionary
	
	## Peer_ID -> InputState
	var input_states : Dictionary
	
	func _init(_tick : int) -> void:
		tick = _tick
		
class EntityState extends Object:
	## Is this game state a client-side prediction or a true state from the server? Always true on the server.
	var is_true : bool = false
	
	## gameplay state at the end of this tick ("as a result of this tick")
	var game_state : Dictionary

class InputState extends Object:
	## is this predicted input or true input from the server? On the owning client this is always true.
	var is_predicted : bool = true
	
	## node_path -> InputData (in dictionary format)
	var input_state : Dictionary = {}

func add_player(peer_id : int) -> void:
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
	var last_saved_tick : int = state_buffer.back().tick
	var tick_delta : int = last_saved_tick - tick
	if tick_delta < 0:
		push_error("get_tick_state() called for future tick not yet saved. Last Saved Tick %d, Requested Tick %d" % [last_saved_tick, tick])
		return null
	
	return state_buffer[-tick_delta - 1]

func get_or_add_tick_state(tick : int) -> TickState:
	var last_saved_tick : int = -1
	if state_buffer.back() != null:
		last_saved_tick = state_buffer.back().tick
		
	var tick_delta : int = tick - last_saved_tick
	
	# we need to add new ticks.
	if tick_delta > 0:
		for new_tick in range(last_saved_tick + 1, tick + 1):
			state_buffer.push_back(TickState.new(new_tick))
		return state_buffer[-1]
	else:
		return state_buffer[tick_delta - 1]

func add_outbound_player_input(player_input : Dictionary) -> void:
	var serialized_player_input : PackedByteArray = message_serializer.serialize_player_input(player_input)
	player_input_departure_buffer.push_back(serialized_player_input)

func request_rollback(tick : int) -> void:
	if (tick <= last_processed_tick) && (tick < rollback_tick):
		rollback_tick = tick 

func _ready() -> void:
	network_adaptor = NetworkAdaptor.new()
	add_child(network_adaptor)
	network_adaptor.recieve_input_update.connect(self.on_recieve_input_update)
	network_adaptor.recieve_state_update.connect(self.on_recieve_state_update)
	
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
	# STEP 1: PERFORM ANY ROLLBACKS, IF NECESSARY. Proccess newly recieved input (on the server), or newly recieved 
		# TODO Client Rollback (state rollback): Each frame load true state if it exits, or calculate predictated state if it does not.
		# Server Rollback (input rollback): Rollback then replay each tick, loading state (true or predicted) each frame
	if multiplayer.is_server() >= 0:
		is_rollback = true
		current_tick = rollback_tick

		
			
		is_rollback = false

	# STEP 2: UPSTREAM/DOWNSTREAM THROTTLE. skip ticks to Maintain sync, or ensure that we have a decent buffer of client input. See Overwatch.
	# TODO
	
	if !started:
		return
	
	# Currently we only perform realtime ticks on the client.
	# Server ticks as needed when recieving input updates from clients.
	if multiplayer.is_server() == false:
		perform_realtime_tick()
	
	# Server: Send true state to all clients
	if multiplayer.is_server():
		send_state_to_all_clients()
	
func perform_realtime_tick() -> void:
	current_tick = last_processed_tick + 1
	
	# Cleanup departing player input buffer
	if last_confirmed_player_tick != last_confirmed_player_tick_old:
		var delta_tick : int = last_confirmed_player_tick - last_confirmed_player_tick_old
		player_input_departure_buffer = player_input_departure_buffer.slice(delta_tick)
		last_confirmed_player_tick_old = last_confirmed_player_tick
	
	# STEP 3: GATHER INPUT
	# create a new state for this tick
	get_or_add_tick_state(get_current_tick())
	
	# Gather local input from all entities
	var local_input := gather_local_input()
	var current_input_state : InputState = get_tick_state(current_tick).input_states.get_or_add(multiplayer.get_unique_id(), InputState.new())
	current_input_state.input_state = local_input
	
	# throw the new input onto the hopper to be sent off eventually
	add_outbound_player_input(local_input)
	
	# Client: Send input to server
	# We want the grab all the input from the last_confirmed_player_tick to the most 
	# recent tick (if possible based on message size). We want the redundancy of resending ticks so 
	# theres a higher chance they get through and we dont have to wait on the last_confirmed_player_tick.
	var departing_player_input : Array[PackedByteArray] = get_departing_player_input()
	send_input_to_server(departing_player_input, last_confirmed_player_tick + 1)
	
	# Step 4: Clients Do tick and save resulting state
	# Perform Tick
	network_tick()
	
	# Save Game State
	# create a new Tick State
	var current_tick_state := get_tick_state(get_current_tick())
	save_game_state(current_tick_state.entity_states)
	
	last_processed_tick = last_processed_tick + 1

func network_tick() -> void:
	# Call on this node grabbing either from entity state or the input state, neutral
	var nodes : Array[Node] = get_tree().get_nodes_in_group(NETWORK_ENTITY_GROUP)
	for node in nodes:
		var tick_state : TickState = get_or_add_tick_state()
		var input : Dictionary
		
		# Perform Transform Tick
		if node.has_method(TRANSFORM_PROCESS_FUNCTION):
			node.call(TRANSFORM_PROCESS_FUNCTION, input)

		# Perform Game logic Tick

func perform_tick_range(oldest_tick : int = 0, newest_tick : int = 0) -> void:
	# load state to oldest
	var tick_state : TickState = get_or_add_tick_state(oldest_tick)
	load_game_state(tick_state.entity_states)
	
	# loop performing network_ticks.
	for tick in range(oldest_tick, newest_tick + 1):
		current_tick = tick
		
		network_tick()
		
		# save new state
		var current_tick_state := get_tick_state(get_current_tick())
		save_game_state(current_tick_state.entity_states)

## Either add or modify state buffer
func save_game_state(entity_states : Dictionary, should_overwrite_true_states : bool = true) -> void:
	var nodes : Array[Node] = get_tree().get_nodes_in_group(NETWORK_ENTITY_GROUP)
	for node in nodes:
		if !node.has_method(SAVE_STATE_FUNCTION) || !node.is_inside_tree() || node.is_queued_for_deletion():
			continue
		
		# Does a state exist for this node currently? If not create one.
		var node_path : String = node.get_path()
		var entity_state : EntityState = entity_states.get_or_add(node_path, EntityState.new())
		
		# Keep in mind, on the client we NEVER want to overwrite a true state.
		if should_overwrite_true_states || entity_state.is_true == false:
			entity_state.game_state = node.call(SAVE_STATE_FUNCTION)

func load_game_tick(tick : int, should_load_true_states : bool) -> void:
	pass

## loads game state.
## Arguement only_load_true_states is for client side rollbacks.
func load_game_state(entity_states : Dictionary, only_load_true_states : bool = false) -> void:
	var nodes : Array[Node] = get_tree().get_nodes_in_group(NETWORK_ENTITY_GROUP)
	for node in nodes: 
		if !node.has_method(LOAD_STATE_FUNCTION) || !node.is_inside_tree() || node.is_queued_for_deletion():
			continue
			
		var node_path : String = node.get_path()
		var entity_state : EntityState = entity_states.get(node_path)
		
		if entity_state == null:
			continue
		
		if (only_load_true_states && entity_state.is_game_state_true) || only_load_true_states == false:
			node.call(LOAD_STATE_FUNCTION, entity_state.game_state)

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
		local_player_input[node.get_path()] = node_input
		
	return local_player_input

## Grab the inputs from last confirmed player input tick to most recent tick.
func get_departing_player_input() -> Array[PackedByteArray]:
	var departing_player_input : Array[PackedByteArray] = player_input_departure_buffer.slice(0, max_player_input_ticks_per_message)
	return departing_player_input

## On Server
func send_state_to_all_clients() -> void:
	# first gather all the most up-to-date true states for every node.
	pass

## On Server
func send_state_to_client() -> void:
	pass
	
## On Client, used to send local player input for all nodes up to the server
func send_input_to_server(serialized_input_ticks: Array[PackedByteArray], initial_tick : int, peer_id : int = 1) -> void:
	var message := {}
	message[message_serializer.PlayerInputKeys.INITIAL_TICK] = initial_tick
	message[message_serializer.PlayerInputKeys.PLAYER_INPUT_DATA] = serialized_input_ticks
	
	var message_bytes : PackedByteArray = message_serializer.serialize_input_message(message)
	
	# Debug
	#print_debug("send_input_to_server, message size: %d" %message_bytes.size())
	network_adaptor.send_input_update(peer_id, message_bytes)

## On Client
func on_recieve_state_update() -> void:
	# request a rollback if we just recieved a new state
	# deserialize into game_state Dictionary and input_state Dictionary for this node
	
	# Send input and game state together for a specific node. I'd say this is slightly easier with combined. +1
	
	pass

## On Server
func on_recieve_input_update(peer_id: int, serialized_message: PackedByteArray) -> void:
	var message : Dictionary = message_serializer.deserialize_input_message(serialized_message)
	
	var initial_tick : int = message[message_serializer.PlayerInputKeys.INITIAL_TICK]
	var player_input_data : Array[PackedByteArray] = message[message_serializer.PlayerInputKeys.PLAYER_INPUT_DATA]
	var last_tick : int = initial_tick + player_input_data.size()
	
	var player : Player = get_player(peer_id)

	# save the inputs to the state_buffer	
	if last_tick > player.last_input_tick_recieved:
		for input_index in player_input_data.size():
			var input_tick := input_index + initial_tick
			var tick_state := get_or_add_tick_state(input_tick)
			var input_state : InputState = tick_state.input_states.get_or_add(peer_id, InputState.new())
	
			var player_input_tick_data := player_input_data[input_index]
			var player_input := message_serializer.deserialize_player_input(player_input_tick_data)
	
			# request a rollback if input prediction was wrong
			# TODO, actually compare inputs, instead of just automatically doing rollback.
			if input_state.is_predicted:
				request_rollback(input_tick)
			
			# update last_recieved_input_tick for this player.
			if input_tick > player.last_input_tick_recieved:
				player.last_input_tick_recieved = input_tick
				print_debug("New tick Recieved: id: %d, tick: %d" % [peer_id, input_tick])
			
			input_state.input_state = player_input
			input_state.is_predicted = false
