extends Node

var started : bool

signal game_started()
signal game_stopped()
signal game_error()

class Player extends Object:
	var peer_id : int

var players : Array[Player]

#var input_buffer
#var state_buffer

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
	if started:
		network_tick()
		# Perform Transform Tick
			
		# Perform Game logic Tick
	# Server: Send true state to all clients

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
