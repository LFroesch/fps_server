extends Node
class_name WaveManager

const BASE_ZOMBIE_COUNT := 5
const ZOMBIES_PER_WAVE := 3
const WAVE_BREAK_TIME := 1.0  # 1 second between waves (debug: was 10.0)
const SPAWN_INTERVAL := 0.3  # 0.3 seconds between individual zombie spawns (debug: was 2.0)

var lobby : Lobby
var current_wave := 0
var zombies_remaining := 0
var zombies_to_spawn := 0
var is_wave_active := false
var spawn_points : Array[Node3D] = []

var spawn_timer : Timer
var break_timer : Timer
var current_spawn_index := 0  # Track which spawn point to use next

func _ready() -> void:
	# Create timers
	spawn_timer = Timer.new()
	spawn_timer.one_shot = false
	spawn_timer.timeout.connect(_on_spawn_timer_timeout)
	add_child(spawn_timer)

	break_timer = Timer.new()
	break_timer.one_shot = true
	break_timer.timeout.connect(_on_break_timer_timeout)
	add_child(break_timer)

	# Collect zombie spawn points
	collect_spawn_points()

func collect_spawn_points() -> void:
	if not lobby:
		return

	# Look for spawn points prefixed with "Zombie"
	for spawn_point in lobby.spawn_points:
		if spawn_point.name.begins_with("Zombie"):
			spawn_points.append(spawn_point)

	# If no zombie spawn points, use Red team spawns (since players are on Blue/Team 0)
	if spawn_points.is_empty():
		for spawn_point in lobby.spawn_points:
			if spawn_point.name.begins_with("Red"):
				spawn_points.append(spawn_point)

func start_first_wave() -> void:
	current_wave = 0
	start_next_wave()

func start_next_wave() -> void:
	current_wave += 1
	zombies_to_spawn = BASE_ZOMBIE_COUNT + (current_wave - 1) * ZOMBIES_PER_WAVE
	zombies_remaining = zombies_to_spawn
	is_wave_active = true

	# Notify all clients about new wave
	for client_id in lobby.get_connected_clients():
		lobby.s_start_wave.rpc_id(client_id, current_wave, zombies_to_spawn)

	# Start spawning zombies
	spawn_timer.wait_time = SPAWN_INTERVAL
	spawn_timer.start()
	_on_spawn_timer_timeout()  # Spawn first zombie immediately

func respawn_waiting_players() -> void:
	for player_data in lobby.server_players.values():
		var player : PlayerServerReal = player_data.real
		if is_instance_valid(player) and player.is_waiting_for_respawn:
			player.respawn_for_new_round()

func _on_spawn_timer_timeout() -> void:
	if zombies_to_spawn > 0:
		spawn_zombie()
		zombies_to_spawn -= 1
	else:
		spawn_timer.stop()

func spawn_zombie() -> void:
	if spawn_points.is_empty():
		return

	# Use round-robin spawn point selection to spread out zombies
	var spawn_point = spawn_points[current_spawn_index % spawn_points.size()]
	current_spawn_index += 1

	# Determine zombie type based on wave
	var zombie_type := determine_zombie_type()

	# Create zombie with unique ID using lobby's counter
	var zombie_id := lobby.next_zombie_id
	lobby.next_zombie_id += 1

	var zombie : ZombieServer = preload("res://player/zombie/zombie_server.tscn").instantiate()
	zombie.zombie_type = zombie_type
	zombie.lobby = lobby
	zombie.name = str(zombie_id)

	lobby.add_child(zombie, true)
	# Add random offset to prevent collision (especially important with fast spawns)
	# Zombie radius is ~0.25, so offset by 1.5 units ensures no overlap
	var spawn_offset = Vector3(randf_range(-1.5, 1.5), 0, randf_range(-1.5, 1.5))
	zombie.global_position = spawn_point.global_position + spawn_offset

	# CRITICAL: Assign zombie AND child hitboxes (Area3D) to lobby's physics space
	lobby.assign_physics_space_recursive(zombie)

	lobby.zombies[zombie_id] = zombie

	# Notify clients to spawn zombie visually
	# Send position RELATIVE to lobby offset (clients are always at y=0)
	var client_position = zombie.position  # Use LOCAL position, not global
	for client_id in lobby.get_connected_clients():
		lobby.s_spawn_zombie.rpc_id(client_id, zombie_id, client_position, zombie_type)

func determine_zombie_type() -> int:
	# Wave 1-3: 100% normal
	if current_wave <= 3:
		return 0  # ZombieType.NORMAL

	# Wave 4-6: 80% normal, 20% fast
	if current_wave <= 6:
		return 0 if randf() < 0.8 else 1

	# Wave 7+: 60% normal, 25% fast, 15% tank
	var rand_val = randf()
	if rand_val < 0.6:
		return 0  # Normal
	elif rand_val < 0.85:
		return 1  # Fast
	else:
		return 2  # Tank

func on_zombie_killed() -> void:
	zombies_remaining -= 1

	# Update clients with remaining zombie count
	for client_id in lobby.get_connected_clients():
		lobby.s_update_zombies_remaining.rpc_id(client_id, zombies_remaining)

	# Check if wave is complete
	if zombies_remaining <= 0 and zombies_to_spawn <= 0 and is_wave_active:
		complete_wave()

func complete_wave() -> void:
	is_wave_active = false

	# Notify clients of wave completion and break time
	for client_id in lobby.get_connected_clients():
		lobby.s_wave_complete.rpc_id(client_id, current_wave)

	# Respawn any players waiting from previous round (at countdown start instead of wave start)
	respawn_waiting_players()

	# Start break timer
	break_timer.wait_time = WAVE_BREAK_TIME
	break_timer.start()

	# Send break time updates to clients
	update_break_time()

func update_break_time() -> void:
	if not break_timer.is_stopped():
		var time_remaining = int(break_timer.time_left)
		for client_id in lobby.get_connected_clients():
			lobby.s_update_break_time.rpc_id(client_id, time_remaining)

		# Schedule next update in 1 second
		await get_tree().create_timer(1.0).timeout
		if break_timer and not break_timer.is_stopped():
			update_break_time()

func _on_break_timer_timeout() -> void:
	# Start next wave
	start_next_wave()

func get_current_wave() -> int:
	return current_wave

func get_zombies_remaining() -> int:
	return zombies_remaining
