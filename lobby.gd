extends Node

const PORT : int = 7000
const DEFAULT_SERVER_IP : String = "127.0.0.1"
const MAX_CLIENTS : int = 8

signal server_connected
signal server_connected_failed

# index : Peer_id
var player_assignments : Dictionary

# sever side
var players_loaded : int = 0

func _ready() -> void:
	var args : Array = Array(OS.get_cmdline_args())
	for arg : String in args:
		var key : String = arg.trim_prefix("--")
		if key == "server":
			initialize_server()
	
	multiplayer.peer_connected.connect(on_peer_connected)
	multiplayer.peer_disconnected.connect(on_peer_disconnected)
	#SyncManager.sync_lost.connect(on_sync_lost)
	#SyncManager.sync_regained.connect(on_sync_regained)
	#SyncManager.sync_error.connect(on_sync_error)

func initialize() -> void:
	players_loaded = 0

func initialize_server() -> void:
	print("Server spun up")
	var peer := ENetMultiplayerPeer.new()
	peer.create_server(PORT, MAX_CLIENTS)
	multiplayer.multiplayer_peer = peer

func initialize_client(in_ip:String) -> void:
	var peer : ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	peer.create_client(in_ip, PORT)
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(on_server_connected)
	multiplayer.connection_failed.connect(on_server_connected_failed)

func is_playing_online() -> bool:
	return multiplayer.has_multiplayer_peer() == true && multiplayer.multiplayer_peer.get_connection_status() != 0

func on_server_connected() -> void:
	server_connected.emit()
	
func on_server_connected_failed() -> void:
	server_connected_failed.emit()

func connect_to_server(input_IP : String ) -> void:
	initialize_client(input_IP)
	NetcodeManager.add_player(multiplayer.get_unique_id())
	
func on_peer_connected(peer_id : int) -> void:
	if multiplayer.is_server():
		print("SERVER: peer connected peer_id: %d" % peer_id)
		NetcodeManager.add_player(peer_id)
	else:
		print("CLIENT: peer connected peer_id: %d" % peer_id)
		NetcodeManager.add_player(peer_id)

func on_peer_disconnected(peer_id : int) -> void:
	print("%d: peer disconnected id: %d" % [multiplayer.get_unique_id(), peer_id])
	if multiplayer.is_server():
		NetcodeManager.remove_player(peer_id)

func tell_server_to_start_game(level: String) -> void:
	if multiplayer.is_server() == true:
		return
	start_game_server.rpc_id(1, level)
	
@rpc("any_peer","call_remote","reliable")
func start_game_server(level_to_load: String) -> void:
	if multiplayer.is_server() == false:
		return
	# let server gather some ping data if it hasnt already.
	
	print("Server: Begin Game")
	
	var count : int = 0
	for peer_id in multiplayer.get_peers():
		player_assignments[count] = peer_id
		count = count + 1
		
	load_game.rpc(player_assignments, level_to_load)

@rpc("authority", "call_local", "reliable")
func load_game(_player_assignments: Dictionary, level_to_load: String) -> void:
	player_assignments = _player_assignments
	get_tree().change_scene_to_file(level_to_load)

@rpc("any_peer", "call_local", "reliable")
func player_finished_loading() -> void:
	players_loaded += 1
	var required_loaded := multiplayer.get_peers().size() + 1
	print("Player Loaded %d / %d" % [players_loaded, required_loaded])
	if players_loaded >= required_loaded:
		print("All players loaded. Waiting for snyc.")
		NetcodeManager.begin_sync()
		await get_tree().create_timer(2, true, true).timeout
		NetcodeManager.game_start()
