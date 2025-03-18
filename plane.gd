class_name PlayerPlane
extends Node2D

const Bullet = preload("res://bullet.tscn")
const RedSprite = preload("res://PlaneSpriteRed.png")
const BlueSprite = preload("res://PlaneSpriteBlue.png")

signal on_died(dead_plane: PlayerPlane)

var velocity : Vector2
@export var acceleration : float = 1000
@export var rotation_rate: float = 2.2
@export var drag_coefficient : float = 0.08
@export var bullet_impulse: float = 100
@export var max_health: int = 5
@export var post_hit_frames: int = 120

var shoot_old: bool = false
var hit_invulnerability: bool = false
var post_hit_timer: int = 0
var health: int = 0

func _ready() -> void:
	health = max_health

func die() -> void:
	on_died.emit(self)
	NetcodeManager.netcode_spawner.destroy_scene(self)

func set_plane_sprite(index: int) -> void:
	if index == 0:
		%PlaneSprite.texture = RedSprite
	else:
		%PlaneSprite.texture = BlueSprite

## Network Plugin
func _get_local_input()->Dictionary:
	var input := {}
	
	input["thrust"] = Input.get_axis("thrust_forward", "thrust_backwards")
	input["yaw"] = Input.get_axis("yaw_left", "yaw_right")
	input["shoot"] = Input.get_action_strength("shoot")
	
	return input

## Network Plugin
func _network_transform_process(input:Dictionary) -> void:
	var fixed_delta : float = 1.0 / 60.0
	
	rotation = rotation + (input.get("yaw", 0) * rotation_rate * fixed_delta)
	var forward: Vector2 = Vector2(0,1).rotated(rotation)
	var drag: Vector2 = drag_coefficient * velocity.length() * -1 * velocity.normalized()
	velocity += acceleration * fixed_delta * forward * input.get("thrust", 0)
	velocity += drag
	position += fixed_delta * velocity
	
	var viewport_bounds: Rect2 = get_viewport_rect()
	if position.x > viewport_bounds.size.x:
		position.x = viewport_bounds.size.x
	elif position.x < 0:
		position.x = 0
	
	if position.y > viewport_bounds.size.y:
		position.y = viewport_bounds.size.y
	elif position.y < 0:
		position.y = 0
	
	if input.get("shoot", 0.0) > 0:
		if shoot_old != true:
			var fresh_bullet:Node2D = Bullet.instantiate()
			get_tree().current_scene.add_child(fresh_bullet)
			fresh_bullet.name = fresh_bullet.name.validate_node_name()
			fresh_bullet.initialize(get_path(), velocity, -forward)
			fresh_bullet.position = self.position
			if multiplayer.is_server():
				NetcodeManager.node_manifest[String(fresh_bullet.get_path())] = NetcodeManager.NodeLifetime.new(NetcodeManager.get_current_tick(), 0, "res://bullet.tscn",multiplayer.get_unique_id())
		shoot_old = true
	else:
		shoot_old = false
	
	post_hit_timer -= 1
	if post_hit_timer <= 0:
		end_post_hit()
	
	if hit_invulnerability == true:
		%PlaneSprite.self_modulate.a = 0.5
		%HitShapeMarker.self_modulate.a = 0
	else:
		%PlaneSprite.self_modulate.a = 1
		%HitShapeMarker.self_modulate.a = 1
	
	if health <= 0:
		die()
	
	get_parent().get_node("%HUD").update_player_health(Lobby.get_player_index(get_multiplayer_authority()), health)

## Network Plugin
func _save_state() -> Dictionary:
	var state : Dictionary
	state["position"] = position
	state["rotation"] = rotation
	state["velocity"] = velocity
	state["shoot_old"] = shoot_old
	state["hit_invulnerability"] = hit_invulnerability
	state["post_hit_timer"] = post_hit_timer
	
	return state

## Network Plugin
func _load_state(state: Dictionary) -> void:
	position = state.get("position", 0)
	rotation = state["rotation"]
	velocity = state["velocity"]
	shoot_old = state["shoot_old"]
	hit_invulnerability = state["hit_invulnerability"]
	post_hit_timer = state["post_hit_timer"]

func _on_area_2d_area_entered(area: Area2D) -> void:
	var node: Node = area.get_parent()
	if node != null && (node is Bullet) && hit_invulnerability == false:
		var bullet: Bullet = node
		if bullet.instigator != get_path():
			var impulse: Vector2 = position - bullet.position
			velocity += impulse.normalized() * bullet_impulse
			health -= 1
			start_post_hit()
		
func start_post_hit() -> void:
	post_hit_timer = post_hit_frames
	hit_invulnerability = true
	
func end_post_hit() -> void:
	post_hit_timer = 0
	hit_invulnerability = false
