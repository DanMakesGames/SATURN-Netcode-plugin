class_name Bullet
extends Node2D

const speed: float = 200
const life_time: float = 1.5

var total_time: float = 0
var velocity: Vector2
var instigator: NodePath

func initialize(_instigator:NodePath, initial_velocity: Vector2, initial_heading: Vector2) -> void:
	velocity = initial_velocity + (initial_heading.normalized() * speed)
	instigator = _instigator

## Network Plugin
func _save_state() -> Dictionary:
	var state : Dictionary
	state["position"] = position
	state["velocity"] = velocity
	state["total_time"] = total_time
	state["insti"] = instigator
	return state

## Network Plugin
func _load_state(state: Dictionary) -> void:
	position = state.get("position", 0)
	velocity = state.get("velocity", 0)
	total_time = state.get("total_time", 0)
	instigator = state.get("insti",NodePath())

## Network Plugin
func _network_transform_process(input:Dictionary) -> void:
	var fixed_delta : float = 1.0 / 60
	
	position += fixed_delta * velocity
	
	total_time += fixed_delta
	
	#if total_time > life_time:
	#	queue_free()
