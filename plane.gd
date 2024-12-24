extends Node2D

const Bullet = preload("res://bullet.tscn")

var velocity : Vector2
@export var acceleration : float = 3000
@export var rotation_acceleration: float = 1
@export var drag : float = 0.1

var shoot_old: bool = false

func set_plane_sprite(index: int) -> void:
	if index == 0:
		%PlaneSprite.texture = "res://PlaneSpriteRed.png"
	else:
		%PlaneSprite.texture = "res://PlaneSpriteBlue.png"

## Network Plugin
func _get_local_input()->Dictionary:
	var input := {}
	
	input["thrust"] = Input.get_axis("thrust_forward", "thrust_backwards")
	input["yaw"] = Input.get_axis("yaw_left", "yaw_right")
	input["shoot"] = Input.get_action_strength("shoot")
	
	return input

## Network Plugin
func _network_transform_process(input:Dictionary) -> void:
	var fixed_delta : float = 1.0 / 60
	
	rotation += input.get("yaw") * rotation_acceleration * fixed_delta
	var forward: Vector2 = (transform * Vector2(1,0)).normalized()
	velocity += acceleration * fixed_delta * forward * input.get("thrust")
	position += fixed_delta * velocity
	
	if input.get("shoot", 0.0) > 0:
		if shoot_old != true:
			var fresh_bullet:Node2D = Bullet.instantiate()
			get_tree().current_scene.add_child(fresh_bullet)
			fresh_bullet.name = fresh_bullet.name.validate_node_name()
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
