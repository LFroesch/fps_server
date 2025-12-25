extends RigidBody3D
class_name Grenade

@onready var self_destruct_timer: Timer = $SelfDestructTimer
@onready var explosion_damage_area: Area3D = $ExplosionDamageArea
@onready var explosion_area_collision_shape: CollisionShape3D = $ExplosionDamageArea/CollisionShape3D

@export var lifetime := 2.0
@export var throw_impulse_strength := 20.0
@export var max_damage := 150
@export var damage_radius := 4.0

var lobby : Lobby

var direction : Vector3
var thrower_id : int

func set_data(_lobby : Lobby, _direction : Vector3, _thrower : PlayerServerReal) -> void:
	lobby = _lobby
	direction = _direction
	thrower_id = _thrower.name.to_int()
	
func _ready() -> void:
	var thrower = lobby.server_players.get(thrower_id).real if lobby.server_players.has(thrower_id) else null
	if thrower:
		add_collision_exception_with(thrower)
	apply_central_impulse(direction * throw_impulse_strength)
	
	var explosion_area_shape := SphereShape3D.new()
	explosion_area_shape.radius = damage_radius
	explosion_area_collision_shape.shape = explosion_area_shape
	
	self_destruct_timer.wait_time = lifetime
	self_destruct_timer.start()
	
	await get_tree().create_timer(1).timeout
	
	thrower = lobby.server_players.get(thrower_id).real if lobby.server_players.has(thrower_id) else null
	if thrower:
		remove_collision_exception_with(thrower)
	
func _on_self_destruct_timer_timeout() -> void:
	explode()
	
func explode() -> void:
	for player in explosion_damage_area.get_overlapping_bodies():
		var hurt_player_id := player.name.to_int()
		if lobby.client_data.get(thrower_id).team == lobby.client_data.get(hurt_player_id).team and thrower_id != hurt_player_id:
			continue
		var damage := max_damage - remap(
			global_position.distance_to(player.global_position + Vector3.UP * 0.8),
			0,
			damage_radius,
			0,
			max_damage
		)
		player.change_health(-damage, thrower_id)
		
	lobby.grenade_exploded(self)
