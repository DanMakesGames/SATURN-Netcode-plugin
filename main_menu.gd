extends Control

func _ready() -> void:
	Lobby.server_connected.connect(on_server_connected)
	Lobby.server_connected_failed.connect(on_server_connected_failed)

func _on_connect_button_pressed() -> void:
	Lobby.connect_to_server(%IpLineEdit.text)

func _on_start_button_pressed() -> void:
	Lobby.tell_server_to_start_game()

func on_server_connected() -> void:
	%StatusText.text = "Server connected!"

func on_server_connected_failed() -> void:
	%StatusText.text = "Failed to connect to server."
