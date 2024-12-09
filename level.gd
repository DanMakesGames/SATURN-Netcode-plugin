extends Node2D

func _ready() -> void:
	if Lobby.is_playing_online():
		Lobby.player_finished_loading.rpc_id(1)
		NetcodeManager.game_started.connect(start_game)
	
		%PlanePlayer1.set_multiplayer_authority(Lobby.player_assignments[0])
		%PlanePlayer2.set_multiplayer_authority(Lobby.player_assignments[1])

func start_game() -> void:
	print("Start Game! %d" % multiplayer.get_unique_id())

func _physics_process(delta: float) -> void:
	if multiplayer.is_server()==false:
		var player: NetcodeManager.Player = NetcodeManager.get_player(multiplayer.get_unique_id())
		if player == null:
			return
		%RollbackFrames.text = "Rollback Frames: %d, ping: %d\n Last Confirmed Input %d delta %d\n Tick%d" \
		% [NetcodeManager.get_rollback_frames(), player.ping, NetcodeManager.last_confirmed_player_tick, NetcodeManager.last_processed_tick - NetcodeManager.last_confirmed_player_tick, NetcodeManager.last_processed_tick]
