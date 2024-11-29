extends Node2D

var velocity : Vector2
@export var acceleration : float = 3000
@export var drag : float = 0.1

var horizontal_input : float
var vertical_input : float

## Network Plugin
func _get_local_input()->Dictionary:
	var input := {}
	
	input["vertical"] = Input.get_axis("move_up", "move_down")
	input["horizontal"] = Input.get_axis("move_left", "move_right")
	
	return input

## Network Plugin
func _network_transform_process(input:Dictionary) -> void:
	var fixed_delta : float = 1.0 / ProjectSettings.get_setting("physics/common/physics_ticks_per_second") 
	process_input(input, fixed_delta)
	process_movement(fixed_delta)

## Network Plugin
func _save_state() -> Dictionary:
	var state : Dictionary
	state["position"] = position
	state["velocity"] = velocity
	return state

## Network Plugin
func _load_state(state: Dictionary) -> void:
	pass

func process_input(input : Dictionary, delta : float) -> void:
	horizontal_input = input.get("horizontal", 0.0)
	vertical_input = input.get("vertical", 0.0)

func process_movement(delta_time : float) -> void:
	var thrust_delta_velocity : Vector2 = Vector2(horizontal_input, vertical_input).normalized() * acceleration * delta_time
	var drag_delta_velocity := (velocity * drag * delta_time) * -1.0 * velocity.normalized()
	
	velocity = thrust_delta_velocity + drag_delta_velocity
	position += delta_time * velocity

## provides single player functionality
func _physics_process(delta: float) -> void:
	if Lobby.is_playing_online():
		return
		
	var input : Dictionary = _get_local_input()
	_network_transform_process(input)
