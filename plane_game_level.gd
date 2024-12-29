class_name PlaneGameLevel
extends Node2D

func _ready() -> void:
	if Lobby.is_playing_online():
		Lobby.player_finished_loading.rpc_id(1)
		NetcodeManager.game_started.connect(start_game)
		NetcodeManager.begin_syncing.connect(begin_sync)
		%GameManager.level = self
		
func begin_sync() -> void:
	print("Begin Sync! %d" % multiplayer.get_unique_id())
	if multiplayer.is_server():
		%GameManager.setup_round()

func start_game() -> void:
	print("Start Game! %d" % multiplayer.get_unique_id())

func _physics_process(delta: float) -> void:
	if multiplayer.is_server()==false:
		var player: NetcodeManager.Player = NetcodeManager.get_player(multiplayer.get_unique_id())
		if player == null:
			return
		
		%HUD.update_connection_stats(player.ping, NetcodeManager.get_rollback_frames())
		var player_0_wins: int = %GameManager.wins.get(Lobby.player_assignments.get(0), 0)
		var player_1_wins: int = %GameManager.wins.get(Lobby.player_assignments.get(1), 0)
		
		%HUD.update_player(0, 0, player_0_wins)
		%HUD.update_player(1, 0, player_1_wins)
		
