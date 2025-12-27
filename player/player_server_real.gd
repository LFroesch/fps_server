extends CharacterBody3D
class_name PlayerServerReal

const ANIM_BLEND_TIME := 0.2
const MAX_HEALTH := 100
const BLEED_OUT_TIME := 10.0  # Seconds until death when downed (reduced for testing)
const REVIVE_HEALTH := 30  # Health restored when revived

var current_health := MAX_HEALTH
var lobby : Lobby
var grenades_left := 2
var is_downed := false
var bleed_out_timer := 0.0
var being_revived_by : int = -1  # Client ID of reviver, -1 if not being revived
var is_waiting_for_respawn := false  # Dead and waiting for next round (zombies mode only)

@onready var animation_player: AnimationPlayer = %AnimationPlayer

func set_anim(anim_name : String) -> void:
	if animation_player.assigned_animation == anim_name:
		return
	animation_player.play(anim_name, ANIM_BLEND_TIME)

func change_health(amount : int, maybe_damage_dealer : int = 0, is_headshot := false) -> void:
	# Can't take damage while downed or waiting for respawn
	if is_downed or is_waiting_for_respawn:
		return

	current_health = clampi(current_health + amount, 0, MAX_HEALTH)

	if current_health <= 0:
		# In zombies mode, go down instead of dying
		if lobby.game_mode == 1:  # MapRegistry.GameMode.ZOMBIES = 1
			enter_downed_state(maybe_damage_dealer)
		else:
			die(maybe_damage_dealer)
	else:
		lobby.update_health(name.to_int(), current_health, MAX_HEALTH, amount, maybe_damage_dealer, is_headshot)

func enter_downed_state(damager_id : int) -> void:
	if is_downed:
		return

	print("Player ", name, " is downed!")
	is_downed = true
	bleed_out_timer = BLEED_OUT_TIME
	current_health = 0

	# Notify clients about downed state
	lobby.player_downed(name.to_int(), damager_id)

	# Start bleed-out timer
	set_physics_process(true)

func _physics_process(delta: float) -> void:
	if is_downed:
		bleed_out_timer -= delta
		if bleed_out_timer <= 0:
			die(0)  # Bled out
		else:
			# Update bleed-out timer on clients
			lobby.update_bleed_out_timer(name.to_int(), bleed_out_timer)

func revive() -> void:
	if not is_downed:
		return

	print("Player ", name, " has been revived!")
	is_downed = false
	current_health = REVIVE_HEALTH
	bleed_out_timer = 0.0
	being_revived_by = -1

	# Notify clients
	lobby.player_revived(name.to_int())
	lobby.update_health(name.to_int(), current_health, MAX_HEALTH, 0, 0, false)

func can_be_revived() -> bool:
	return is_downed and being_revived_by == -1

func start_being_revived(reviver_id : int) -> void:
	if is_downed:
		being_revived_by = reviver_id

func stop_being_revived() -> void:
	being_revived_by = -1

func die(killer_id : int) -> void:
	is_downed = false

	# In zombies mode, enter waiting state instead of actually dying
	if lobby.game_mode == 1:  # MapRegistry.GameMode.ZOMBIES = 1
		print("Player ", name, " died - waiting for next round")
		is_waiting_for_respawn = true
		current_health = 0

		# Notify lobby to check if all players are dead
		lobby.player_waiting_for_respawn(name.to_int())
	else:
		# PvP mode - normal death
		lobby.player_died(name.to_int(), killer_id)

func respawn_for_new_round() -> void:
	if not is_waiting_for_respawn:
		return

	print("Player ", name, " respawning for new round")
	is_waiting_for_respawn = false
	is_downed = false
	current_health = MAX_HEALTH
	grenades_left = 2
	bleed_out_timer = 0.0
	being_revived_by = -1

	# Notify clients
	lobby.player_respawned(name.to_int())
	lobby.update_health(name.to_int(), current_health, MAX_HEALTH, 0, 0, false)

func update_grenades_left(new_amount : int) -> void:
	grenades_left = new_amount
	lobby.update_grenades_left(name.to_int(), grenades_left)
