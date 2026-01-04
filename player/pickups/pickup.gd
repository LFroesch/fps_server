extends Node3D
class_name Pickup

@onready var cooldown_timer: Timer = $CooldownTimer
@onready var despawn_timer: Timer = Timer.new()

enum PickupTypes {
	HealthPickup = 0,
	GrenadePickup = 1,
	AmmoPickup = 2,         # Max Ammo (refills all weapons)
	InstaKill = 4,
	DoublePoints = 5,
	Nuke = 6
}

@export var pickup_type := PickupTypes.HealthPickup
@export var cooldown_time := 10.0

var lobby : Lobby
var is_one_time_use := false  # Zombie drops use this
var should_despawn := false  # Power-ups despawn after 30s

var is_picked := false

func _ready() -> void:
	cooldown_timer.wait_time = cooldown_time

	# Setup despawn timer for zombie drops
	if should_despawn:
		add_child(despawn_timer)
		despawn_timer.wait_time = lobby.POWERUP_DESPAWN_TIME if lobby else 30.0
		despawn_timer.one_shot = true
		despawn_timer.timeout.connect(_on_despawn_timeout)
		despawn_timer.start()

		# Notify clients to start despawn countdown
		if lobby:
			lobby.s_pickup_despawn_started.rpc(name, despawn_timer.wait_time)

func _on_body_entered(player: PlayerServerReal) -> void:
	if is_picked:
		return

	match pickup_type:
		PickupTypes.HealthPickup:
			if player.current_health < player.get_max_health():
				player.change_health(75)
				picked_up(player)
		PickupTypes.GrenadePickup:
			if player.grenades_left < 2:
				player.update_grenades_left(player.grenades_left + 1)
				picked_up(player)
		PickupTypes.AmmoPickup:
			lobby.activate_max_ammo()
			picked_up(player)
		PickupTypes.InstaKill:
			lobby.activate_powerup("insta_kill", player.name.to_int())
			picked_up(player)
		PickupTypes.DoublePoints:
			lobby.activate_powerup("double_points", player.name.to_int())
			picked_up(player)
		PickupTypes.Nuke:
			lobby.activate_nuke(player.name.to_int())
			picked_up(player)
			
func picked_up(player : PlayerServerReal) -> void:
	is_picked = true
	lobby.play_pickup_fx(player.name.to_int(), pickup_type)

	if is_one_time_use:
		# Zombie drops disappear after one use
		lobby.delete_pickup(name)
		queue_free()
	else:
		# Normal pickups go on cooldown
		cooldown_timer.start()
		lobby.pickup_cooldown_started(name)

func _on_cooldown_timer_timeout() -> void:
	is_picked = false
	lobby.pickup_cooldown_ended(name)

func _on_despawn_timeout() -> void:
	# Pickup expired, remove it
	if lobby:
		lobby.delete_pickup(name)
	queue_free()
