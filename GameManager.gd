extends Node

const PlayerPlaneScene = preload("res://plane.tscn")

# player_id -> plane
var player_planes: Array[PlayerPlane]

var level: PlaneGameLevel

# wins
var wins: Array[int]

func increment_wins(winner_index: int) -> void:
	wins.resize(Lobby.player_assignments.size())
	wins[winner_index] += 1

# Server
func end_round(winner_index: int) -> void:
	increment_wins(winner_index)
	client_end_round.rpc(winner_index)
	
	setup_round()

@rpc("call_remote","reliable","authority")
func client_end_round(winner_index: int)->void:
	increment_wins(winner_index)
	
func on_player_death(dead_plane: PlayerPlane) -> void:
	player_planes.erase(dead_plane)
	
	if player_planes.size() == 1:
		end_round(Lobby.get_player_index(player_planes[0].get_multiplayer_authority()))

# Server
func setup_round() -> void:
	for plane in player_planes:
		NetcodeManager.netcode_spawner.destroy_scene(plane)

	player_planes.clear()

	# spawn planes
	for index: int in Lobby.player_assignments.size():
		var peer_id: int = Lobby.player_assignments[index]
		var fresh_player_plane: Node = PlayerPlaneScene.instantiate()
		get_tree().current_scene.add_child(fresh_player_plane)
		fresh_player_plane.name = fresh_player_plane.name.validate_node_name()
		fresh_player_plane.set_multiplayer_authority(peer_id)
		fresh_player_plane.position = Vector2((index + 1) * 300, 300)
		player_planes.push_back(fresh_player_plane)
		fresh_player_plane.on_died.connect(self.on_player_death)
		print("Server: Spawn player %s: %d" % [fresh_player_plane.get_path(), peer_id])
		NetcodeManager.node_manifest[String(fresh_player_plane.get_path())] = NetcodeManager.NodeLifetime.new(NetcodeManager.get_current_tick(), 0, "res://plane.tscn",peer_id)
