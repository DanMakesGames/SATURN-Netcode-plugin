extends Control

func update_player_health(index: int, health: int) -> void:
	var player_label: Label
	if index == 0:
		player_label = %Player1Info
	elif index == 1:
		player_label = %Player2Info
	
	player_label.text = "%d: Health: %d" % [index, health]
	
func update_connection_stats(ping: int, rollback_frames: int) -> void:
	%ConnectionStats.text = "ping: %d, rollback frames: %d" % [ping, rollback_frames]

func update_player_wins(index: int, wins: int) -> void:
	var player_label: Label
	if index == 0:
		player_label = %Player1Wins
	elif index == 1:
		player_label = %Player2Wins
		
	player_label.text = "%d: Wins: %d" % [index, wins]
