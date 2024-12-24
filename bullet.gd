extends Node2D

const speed: float = 300
const life_time: float = 1

var total_time: float = 0
var velocity: Vector2

## Network Plugin
func _save_state() -> Dictionary:
	var state : Dictionary
	state["position"] = position
	state["velocity"] = velocity
	state["total_time"] = total_time
	return state

## Network Plugin
func _load_state(state: Dictionary) -> void:
	position = state["position"]
	velocity = state["velocity"]
	total_time = state["total_time"]

## Network Plugin
func _network_transform_process(input:Dictionary) -> void:
	var fixed_delta : float = 1.0 / 60
	
	position += fixed_delta * velocity.normalized() * speed
	total_time += fixed_delta
	
	if total_time > life_time:
		queue_free()
