extends Node2D

const Bullet = preload("res://bullet.tscn")

var velocity : Vector2
@export var acceleration : float = 3000
@export var drag : float = 0.1

var horizontal_input : float
var vertical_input : float

var shoot_old: bool = false

## Network Plugin
func _get_local_input()->Dictionary:
	var input := {}
	
	input["vertical"] = Input.get_axis("move_up", "move_down")
	input["horizontal"] = Input.get_axis("move_left", "move_right")
	input["shoot"] = Input.get_action_strength("shoot")
	
	return input

## Network Plugin
func _network_transform_process(input:Dictionary) -> void:
	var fixed_delta : float = 1.0 / 60
	process_input(input, fixed_delta)
	process_movement(fixed_delta)
	
	if input.get("shoot", 0.0) > 0:
		if shoot_old != true:
			var fresh_bullet:Node2D = Bullet.instantiate()
			get_tree().current_scene.add_child(fresh_bullet)
			fresh_bullet.velocity = velocity
			fresh_bullet.position = self.position

		shoot_old = true
	else:
		shoot_old = false

## Network Plugin
func _save_state() -> Dictionary:
	var state : Dictionary
	state["position"] = position
	state["velocity"] = velocity
	state["shoot_old"] = shoot_old
	return state

## Network Plugin
func _load_state(state: Dictionary) -> void:
	position = state["position"]
	velocity = state["velocity"]
	shoot_old = state["shoot_old"]

func process_input(input : Dictionary, delta : float) -> void:
	horizontal_input = input.get("horizontal", 0.0)
	vertical_input = input.get("vertical", 0.0)

func process_movement(delta_time : float) -> void:
	#var thrust_delta_velocity : Vector2 = Vector2(horizontal_input, vertical_input).normalized() * acceleration * delta_time
	#var drag_delta_velocity := (velocity * drag * delta_time) * -1.0 * velocity.normalized()
	#velocity = thrust_delta_velocity + drag_delta_velocity
	#position += delta_time * velocity
	var old_position: Vector2 = position
	position += delta_time * 100 * Vector2(horizontal_input, vertical_input).normalized()
	velocity = (position - old_position).normalized()

## provides single player functionality
func _physics_process(delta: float) -> void:
	if Lobby.is_playing_online():
		return
		
	var input : Dictionary = _get_local_input()
	_network_transform_process(input)
