extends Node

const NETWORK_ENTITY_GROUP : String = "network_entity"
const SAVE_STATE_FUNCTION : String = "_save_state"
const LOAD_STATE_FUNCTION : String = "_load_state"

var started : bool

signal game_started()
signal game_stopped()
signal game_error()

class Player extends Object:
	var peer_id : int

var players : Array[Player]

## indexed by tick. Element Last is most recent.
var state_buffer : Array[TickState]

## state on this tick
class TickState extends Object:
	## tick for this state
	var tick : int
	
	## node path -> EntityState
	var entity_states : Dictionary

class EntityState extends Object:
	## Is this game state a client-side prediction or a true state from the server? Always true on the server.
	var is_game_state_true : bool
	
	## gameplay state at the start of this tick
	var game_state : Dictionary
	
	## is this predicted input or true input from the server? On the owning client this is always true.
	var is_input_true : bool
	
	## gathered input for this entity this frame.
	var input_state : Dictionary
	
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

func _ready() -> void:
	pass

# Starts ticking the game. Call when you want the gameplay to start.
func game_start() -> void:
	started = true
	client_game_start.rpc()

@rpc("authority", "call_local", "reliable")
func client_game_start() -> void:
	game_started.emit()

# main loop
func _physics_process(delta: float) -> void:
	# STEP 1: PERFORM ANY ROLLBACKS, IF NECESSARY. Proccess newly recieved input (on the server), or newly recieved 
		# Client Rollback (state rollback): Each frame load true state if it exits, or calculate predictated state if it does not.
		# Server Rollback (input rollback): Rollback then replay each tick, loading state (true or predicted) each frame
	# TODO

	# STEP 2: SKIP TICKS, IF NECESSARY. Maintain sync
	# TODO
	
	# STEP 3: GATHER INPUT AND RUN CURRENT TICK
	# Gather input from all entities
	# Client: Send input to server
	# Perform Tick
	# do input prediction if necessary
	if started:
		network_tick()
		# Perform Transform Tick
			
		# Perform Game logic Tick
	# Save Game State
	#save_game_state()
	# Server: Send true state to all clients

## Either add or modify state buffer
func save_game_state(entity_states : Dictionary) -> void:
	var nodes : Array[Node] = get_tree().get_nodes_in_group(NETWORK_ENTITY_GROUP)
	for node in nodes:
		if !node.has_method(SAVE_STATE_FUNCTION) || !node.is_inside_tree() || node.is_queued_for_deletion():
			continue
		
		# Does a state exist for this node currently? If not create one.
		var node_path : String = node.get_path()
		var entity_state : EntityState = entity_states.get_or_add(node_path)
		
		# Keep in mind, on the client we NEVER want to overwrite a true state.
		if multiplayer.is_server() || entity_state.is_game_state_true == false:
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

func network_tick() -> void:
	pass

func send_state_to_all_clients() -> void:
	pass

func send_state_to_client() -> void:
	pass
	
func send_input_to_server() -> void:
	pass

func on_recieve_state_update() -> void:
	# request a rollback if we just recieved a new state
	pass

func on_recieve_input_update() ->void:
	# request a rollback if input prediction was wrong
	pass
