class_name PlaneGameLevel
extends Node2D

func _ready() -> void:
	if Lobby.is_playing_online():
		Lobby.player_finished_loading.rpc_id(1)
		NetcodeManager.game_started.connect(start_game)
	
		%Player1.set_multiplayer_authority(Lobby.player_assignments[0])
		%Player1.set_plane_sprite(0)
		if Lobby.player_assignments.size() > 1:
			%Player2.set_multiplayer_authority(Lobby.player_assignments[1])
			%Player2.set_plane_sprite(1)

func start_game() -> void:
	print("Start Game! %d" % multiplayer.get_unique_id())

func _physics_process(delta: float) -> void:
	if multiplayer.is_server()==false:
		var player: NetcodeManager.Player = NetcodeManager.get_player(multiplayer.get_unique_id())
		if player == null:
			return
		
		%HUD.update_connection_stats(player.ping, NetcodeManager.get_rollback_frames())
		%HUD.update_player(0, %Player1.health, 0)
		%HUD.update_player(1, %Player2.health, 0)
		
func get_planes() -> Array[PlayerPlane]:
	var children := get_children()
	var out_planes: Array[PlayerPlane] = []
	for child in children:
		if child is PlayerPlane:
			out_planes.push_back(child)
	
	return out_planes
