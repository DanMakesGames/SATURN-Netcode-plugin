extends Node

const PlayerPlaneScene = preload("res://plane.tscn")

var player_planes: Array[PlayerPlane]

var level: PlaneGameLevel

# player_id -> wins
var wins: Dictionary = {}

func increment_wins(winner_peer_id: int) -> void:
	if winner_peer_id != -1:
		var current_score: int = wins.get_or_add(winner_peer_id, 0)
		wins[winner_peer_id] = current_score + 1

# Server
func end_round(winner_peer_id: int) -> void:
	increment_wins(winner_peer_id)
	client_end_round.rpc(winner_peer_id)
	
	#setup_round()

@rpc("call_remote","reliable","authority")
func client_end_round(winner_peer_id: int)->void:
	increment_wins(winner_peer_id)
	
func on_player_death(dead_plane: PlayerPlane) -> void:
	player_planes.erase(dead_plane)
	
	if player_planes.size() == 1:
		end_round(player_planes[0].get_multiplayer_authority())

# Server
func setup_round() -> void:
	for plane in player_planes:
		plane.queue_free()	

	player_planes.clear()

	# spawn planes
	for index: int in Lobby.player_assignments:
		var peer_id: int = Lobby.player_assignments[index]
		var fresh_player_plane: Node = PlayerPlaneScene.instantiate()
		get_tree().current_scene.add_child(fresh_player_plane)
		fresh_player_plane.name = fresh_player_plane.name.validate_node_name()
		fresh_player_plane.set_multiplayer_authority(peer_id)
		fresh_player_plane.position = Vector2((index + 1) * 300, 300)
		player_planes.push_back(fresh_player_plane)
		fresh_player_plane.on_died.connect(self.on_player_death)
		print("Server: Spawn player %s: %d" % [fresh_player_plane.get_path(), peer_id])
