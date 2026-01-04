extends Node3D
class_name Pickup

@onready var cooldown_timer: Timer = $CooldownTimer

enum PickupTypes {
	HealthPickup,
	GrenadePickup,
	AmmoPickup
}

@export var pickup_type := PickupTypes.HealthPickup
@export var cooldown_time := 10.0

var lobby : Lobby
var is_one_time_use := false  # Zombie drops use this

var is_picked := false

func _ready() -> void:
	cooldown_timer.wait_time = cooldown_time

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
			lobby.replenish_ammo(player.name.to_int())
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
