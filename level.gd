extends Node2D

func _ready() -> void:
	if Lobby.is_playing_online():
		Lobby.player_finished_loading.rpc_id(1)
		NetcodeManager.game_started.connect(start_game)
		
		if multiplayer.is_server():
			var client_peer_id := multiplayer.get_peers()[0]
			%PlanePlayer1.set_multiplayer_authority(client_peer_id)
		else:
			%PlanePlayer1.set_multiplayer_authority(multiplayer.get_unique_id())

func start_game() -> void:
	print("Start Game! %d" % multiplayer.get_unique_id())
