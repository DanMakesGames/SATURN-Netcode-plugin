extends Control

func update_player(index: int, health: int, wins: int) -> void:
	var player_label: Label
	if index == 0:
		player_label = %Player1Info
	elif index == 1:
		player_label = %Player2Info
	
	player_label.text = "Health: %d, Wins: %d" % [health, wins]
	
func update_connection_stats(ping: int, rollback_frames: int) -> void:
	%ConnectionStats.text = "ping: %d, rollback frames: %d" % [ping, rollback_frames]
