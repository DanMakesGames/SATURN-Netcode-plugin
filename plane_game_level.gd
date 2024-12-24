extends Node2D

func _ready() -> void:
	if Lobby.is_playing_online():
		Lobby.player_finished_loading.rpc_id(1)
		NetcodeManager.game_started.connect(start_game)
	
		%Player1.set_multiplayer_authority(Lobby.player_assignments[0])
		if Lobby.player_assignments.size() > 1:
			%Player2.set_multiplayer_authority(Lobby.player_assignments[1])

func start_game() -> void:
	print("Start Game! %d" % multiplayer.get_unique_id())

func _physics_process(delta: float) -> void:
	if multiplayer.is_server()==false:
		var player: NetcodeManager.Player = NetcodeManager.get_player(multiplayer.get_unique_id())
		if player == null:
			return
		%ConnectionStats.text = "rollback frames: %d, ping: %d, simulated packet loss: %d%%, throttle: %d" \
		% [NetcodeManager.get_rollback_frames(), player.ping, NetcodeManager.network_adaptor.PACKET_LOSS * 100, NetcodeManager.tick_throttle]
