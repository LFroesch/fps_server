extends Node3D
class_name Lobby

# CRITICAL: Each lobby needs its own physics space to prevent cross-lobby collisions
var physics_space_rid : RID

const WORLD_STATE_SEND_FRAME := 3
const WORLD_STATES_TO_REMEMBER := 60
const DEATH_COOLDOWN_LENGTH := 2
const MATCH_LENGTH_SEC := 300
const TEAM_SCORE_TO_WIN := 5

# Zombie Drop Table - Centralized for easy tuning
# Total drop chance: ~17% (roughly 1 in 6 zombies)
const ZOMBIE_DROP_TABLE := [
	{"name": "max_ammo",      "chance": 0.07,  "pickup_type": 2},  # 7% - Most common (essential)
	{"name": "double_points", "chance": 0.05,  "pickup_type": 5},  # 5% - Common (progression boost)
	{"name": "health",        "chance": 0.03,  "pickup_type": 0},  # 3% - Moderate (survival)
	{"name": "insta_kill",    "chance": 0.015, "pickup_type": 4},  # 1.5% - Rare (powerful)
	{"name": "nuke",          "chance": 0.005, "pickup_type": 6}   # 0.5% - Very rare (screen clear)
]

# Power-up durations
const POWERUP_DURATION := 30.0  # Insta-Kill, Double Points
const POWERUP_DESPAWN_TIME := 30.0  # How long before uncollected power-ups disappear

enum {
	IDLE,
	DELETING,
	LOCKED,
	GAME,
	FINISHED
}

var status := IDLE
var being_deleted := false
var map_id : int = -1
var game_mode : int = 0  # MapRegistry.GameMode.PVP default
var lobby_id : String = ""  # 6-char alphanumeric code
var host_id : int = -1  # First player = host
var max_players : int = 2  # 1-4 players
var is_public : bool = true  # Joinable via quick play

var callable_when_clients_ready : Callable
var waiting_players_ready := false

var client_data := {}
var ready_clients : Array[int] = []
var current_world_state := {"ps" : {}, "t" : 0, "gr" : {}, "zs" : {}} # ps = player states, t = time, gr = grenades, zs = zombie states
var server_players := {} 
var previous_world_states : Array[Dictionary] = []
var pickups : Array[Pickup] = []
var spawn_points : Array[Node3D] = []
var grenades := {}
var zombies := {}  # For zombies mode
var wave_manager = null  # WaveManager instance for zombies mode
var next_zombie_id := 0  # Unique zombie ID counter per lobby
var navigation_map_rid : RID  # Unique navigation map for this lobby's zombies

# Power-up state tracking (zombies mode)
var active_powerups := {}  # {"insta_kill": Timer, "double_points": Timer}

var match_time_left := MATCH_LENGTH_SEC
var match_timer := Timer.new()

func _get_time_string() -> String:
	var datetime = Time.get_datetime_dict_from_system()
	return "[%02d:%02d:%02d] -" % [datetime.hour, datetime.minute, datetime.second]

static func generate_lobby_code() -> String:
	const CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	var code = ""
	for i in 6:
		code += CHARS[randi() % CHARS.length()]
	return code

func _ready() -> void:
	# Create unique physics space for this lobby
	# CRITICAL: Without this, lobbies at different Y positions share physics,
	# causing zombies/players to collide with floors from other lobbies
	physics_space_rid = PhysicsServer3D.space_create()
	PhysicsServer3D.space_set_active(physics_space_rid, true)

	set_physics_process(false)
	add_child(match_timer)
	match_timer.timeout.connect(match_timer_sec_passed)

func _exit_tree() -> void:
	# Cleanup physics space
	if physics_space_rid.is_valid():
		PhysicsServer3D.free_rid(physics_space_rid)

	# Cleanup navigation map
	if navigation_map_rid.is_valid():
		NavigationServer3D.free_rid(navigation_map_rid)
	
## Recursively assigns all physics bodies in node tree to this lobby's physics space
## This prevents cross-lobby physics interactions (collisions between different lobbies)
func assign_physics_space_recursive(node: Node) -> void:
	if node is PhysicsBody3D:
		var body_rid = node.get_rid()
		PhysicsServer3D.body_set_space(body_rid, physics_space_rid)
	elif node is Area3D:
		var area_rid = node.get_rid()
		PhysicsServer3D.area_set_space(area_rid, physics_space_rid)

	# Recursively process all children
	for child in node.get_children():
		assign_physics_space_recursive(child)

func get_connected_clients() -> Array[int]:
	var connected_client_ids : Array[int] = []

	for client_id in client_data.keys():
		if client_data.get(client_id).connected:
			connected_client_ids.append(client_id)
	
	return connected_client_ids

func _physics_process(delta: float) -> void:
	if Engine.get_physics_frames() % WORLD_STATE_SEND_FRAME == 0:
		current_world_state.t = floori(Time.get_unix_time_from_system() * 1000)
		update_grenades_in_world_state()
		update_zombies_in_world_state()

		for client_id in get_connected_clients():
			s_send_world_state.rpc_id(client_id, current_world_state)
			
	while previous_world_states.size() >= WORLD_STATES_TO_REMEMBER:
		previous_world_states.pop_back()
		
	for client_id in server_players.keys():
		if not current_world_state.ps.has(client_id):
			continue

		var player_real = server_players.get(client_id).real
		if not is_instance_valid(player_real):
			continue

		current_world_state.ps[client_id]["anim_pos"] = player_real.animation_player.current_animation_position
	previous_world_states.push_front(current_world_state.duplicate(true))
	
func update_grenades_in_world_state() -> void:
	for grenade_name in grenades.keys():
		current_world_state.gr[grenade_name] = {"tform" : grenades.get(grenade_name).transform}

func update_zombies_in_world_state() -> void:
	# Clear old zombie states
	current_world_state.zs.clear()

	# Add current zombie positions (use local position relative to lobby)
	for zombie_id in zombies.keys():
		var zombie = zombies.get(zombie_id)
		if is_instance_valid(zombie):
			current_world_state.zs[zombie_id] = {
				"pos" : zombie.position,  # Local position, not global
				"rot_y" : zombie.rotation.y
			}
	
@rpc("authority", "call_remote", "unreliable_ordered")
func s_send_world_state(new_world_state : Dictionary) -> void:
	pass

func add_client(id : int, player_name : String) -> void:
	client_data[id] = {"display_name" : player_name, "connected" : true, "kills" : 0, "deaths" : 0, "weapon_id" : 0, "points" : 0}
	# Set first player as host
	if host_id == -1:
		host_id = id

func remove_client(id : int) -> void:
	client_data.get(id).connected = false

	# Host migration - promote oldest remaining player
	if id == host_id and status == IDLE:
		var connected = get_connected_clients()
		if connected.size() > 0:
			host_id = connected[0]

	check_players_ready()
	maybe_delete_empty_lobby()
	delete_player(id)
	check_both_teams_are_connected()

	# Notify remaining players in waiting room that someone left
	if status == IDLE:
		var server = get_node_or_null("/root/Server")
		if server and server.has_method("get_lobby_data"):
			var lobby_data = server.get_lobby_data(self)
			for client_id in get_connected_clients():
				server.s_lobby_updated.rpc_id(client_id, lobby_id, lobby_data)
	
func check_both_teams_are_connected() -> void:
	var connected_blue_players := 0
	var connected_red_players := 0
	for client_id in get_connected_clients():
		if not client_data.get(client_id).has("team"):
			return
		if client_data.get(client_id).team == 0:
			connected_blue_players += 1
		else:
			connected_red_players += 1
	if not connected_blue_players or not connected_red_players:
		end_match()
		
	
func delete_player(client_id: int) -> void:
	if server_players.has(client_id):
		server_players.get(client_id).real.queue_free()
		server_players.get(client_id).dummy.queue_free()
		server_players.erase(client_id)
		
		for connected_client_id in get_connected_clients():
			s_delete_player.rpc_id(connected_client_id, client_id)

@rpc("authority", "call_remote", "reliable")
func s_delete_player(client_id : int) -> void:
	pass

func maybe_delete_empty_lobby() -> void:
	# Already being deleted, don't delete twice
	if being_deleted:
		return

	# Check if any clients are still connected
	for data in client_data.values():
		if data.connected:
			return

	# Mark as being deleted and transition to DELETING status
	being_deleted = true
	status = DELETING

	# Defer deletion to next frame to ensure all current operations complete
	call_deferred("_safe_delete")

func _safe_delete() -> void:
	# Double-check no one joined in the meantime
	for data in client_data.values():
		if data.connected:
			# Someone joined, revert deletion
			being_deleted = false
			status = IDLE
			return

	# Safe to delete
	Server.delete_lobby(self)

@rpc("any_peer", "call_remote", "reliable")
func c_lock_client() -> void:
	var client_id := multiplayer.get_remote_sender_id()
	if not client_id in client_data.keys() or client_id in ready_clients:
		return
	ready_clients.append(client_id)
	waiting_players_ready = true
	check_players_ready(start_loading_map)

func check_players_ready(maybe_callable = null) -> void:
	if not waiting_players_ready:
		return
	var connected = get_connected_clients()
	for maybe_ready_client in connected:
		if not maybe_ready_client in ready_clients:
			return
	if maybe_callable is Callable:
		callable_when_clients_ready = maybe_callable

	callable_when_clients_ready.call()
	ready_clients.clear()
	waiting_players_ready = false
	
func start_loading_map() -> void:
	var map_path := MapRegistry.get_server_path(map_id)
	if map_path.is_empty():
		print("ERROR: Invalid map_id %d" % map_id)
		return

	var map = load(map_path).instantiate()
	map.name = "Map"

	add_child(map, true)

	# Assign all physics bodies in the map to this lobby's physics space
	assign_physics_space_recursive(map)

	# Setup navigation for modes that need AI pathfinding
	if game_mode == MapRegistry.GameMode.ZOMBIES:
		setup_map_navigation(map)
	
	var spawn_point_holder = map.get_node("SpawnPoints")
	if spawn_point_holder != null: # NOT GROUPS BECAUSE THESE ARE LOCAL TO EACH LOBBY
		for spawn_point in spawn_point_holder.get_children():
			spawn_points.append(spawn_point)

	var pickup_holder = map.get_node("Pickups")
	if pickup_holder != null: # NOT GROUPS BECAUSE THESE ARE LOCAL TO EACH LOBBY
		for maybe_pickup in pickup_holder.get_children():
			if maybe_pickup is Pickup:
				maybe_pickup.lobby = self
				pickups.append(maybe_pickup)

	# Remove static pickups in zombie mode (they should only spawn as zombie drops)
	if game_mode == MapRegistry.GameMode.ZOMBIES:
		for pickup in pickups:
			pickup.queue_free()
		pickups.clear()

	for ready_client in ready_clients:
		s_start_loading_map.rpc_id(ready_client, map_id, game_mode)

## Sets up navigation for AI pathfinding (zombies mode, etc)
## Requires map to have a NavigationRegion3D node at root level
func setup_map_navigation(map: Node3D) -> void:
	# Create a UNIQUE navigation map for THIS lobby only
	# This ensures zombies/AI in different lobbies use separate navigation
	navigation_map_rid = NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(navigation_map_rid, true)

	var nav_region = map.get_node_or_null("NavigationRegion3D")
	if not nav_region:
		return

	# Disable to clear any auto-registration to default navigation map
	nav_region.enabled = false

	# Duplicate the navmesh to avoid shared state between lobbies
	if nav_region.navigation_mesh:
		nav_region.navigation_mesh = nav_region.navigation_mesh.duplicate(true)

	# Register to our unique navigation map
	NavigationServer3D.region_set_map(nav_region.get_rid(), navigation_map_rid)

	# Re-enable
	nav_region.enabled = true

	# CRITICAL: Also assign all NavigationLink3D nodes to this navigation map
	# Without this, links exist on the default map and zombies can't use them
	_assign_navigation_links_to_map(map)

	# Wait for scene tree to update transforms
	await get_tree().physics_frame
	await get_tree().physics_frame

func _assign_navigation_links_to_map(node: Node) -> void:
	# Recursively find all NavigationLink3D nodes and assign them to our navigation map
	if node is NavigationLink3D:
		NavigationServer3D.link_set_map(node.get_rid(), navigation_map_rid)

	for child in node.get_children():
		_assign_navigation_links_to_map(child)

@rpc("authority", "call_remote", "reliable")
func s_start_loading_map(map_id: int, received_game_mode: int = 0) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable")
func c_map_ready() -> void:
	var client_id := multiplayer.get_remote_sender_id()
	if not client_id in client_data.keys() or client_id in ready_clients:
		return
	ready_clients.append(client_id)
	
	for pickup in pickups:
		s_spawn_pickup.rpc_id(client_id, pickup.name, pickup.pickup_type, pickup.position)
	
	waiting_players_ready = true
	check_players_ready(start_weapon_selection)



@rpc("authority", "call_remote", "reliable")
func s_spawn_pickup(pickup_name : String, pickup_type : int, pos : Vector3) -> void:
	pass

func spawn_players() -> void:
	if game_mode == MapRegistry.GameMode.ZOMBIES:
		spawn_players_zombies_mode()
	else:
		spawn_players_pvp_mode()

func spawn_players_pvp_mode() -> void:
	var blue_spawn_points : Array[Node3D] = []
	var red_spawn_points : Array[Node3D] = []

	for spawn_point in spawn_points:
		if spawn_point.name.begins_with("Blue"):
			blue_spawn_points.append(spawn_point)
		elif spawn_point.name.begins_with("Red"):
			red_spawn_points.append(spawn_point)

	ready_clients.shuffle()
	for i in ready_clients.size():
		var team := 0
		var spawn_tform := Transform3D.IDENTITY

		if i % 2 == 0:
			team = 0
			spawn_tform = blue_spawn_points[0].transform
			blue_spawn_points.pop_front()
		else:
			team = 1
			spawn_tform = red_spawn_points[0].transform
			red_spawn_points.pop_front()

		spawn_server_player(ready_clients[i], spawn_tform, team)

		for ready_client_id in ready_clients:
			s_spawn_player.rpc_id(
				ready_client_id,
				ready_clients[i],
				spawn_tform,
				team,
				client_data.get(ready_clients[i]).display_name,
				client_data.get(ready_clients[i]).weapon_id,
				true
			)

func spawn_players_zombies_mode() -> void:
	# All players on same team (Team 0 - Humans)
	var human_spawn_points : Array[Node3D] = []

	for spawn_point in spawn_points:
		# Use Blue spawn points for humans, or any non-zombie spawn
		if spawn_point.name.begins_with("Blue") or not spawn_point.name.begins_with("Zombie"):
			if not spawn_point.name.begins_with("Red"):
				human_spawn_points.append(spawn_point)

	# If no suitable spawns found, use any spawn point
	if human_spawn_points.is_empty():
		human_spawn_points = spawn_points.duplicate()

	for i in ready_clients.size():
		var team := 0  # All humans on Team 0
		var spawn_tform := human_spawn_points[i % human_spawn_points.size()].transform

		spawn_server_player(ready_clients[i], spawn_tform, team)

		for ready_client_id in ready_clients:
			s_spawn_player.rpc_id(
				ready_client_id,
				ready_clients[i],
				spawn_tform,
				team,
				client_data.get(ready_clients[i]).display_name,
				0,  # Force pistol (weapon_id = 0) in zombie mode
				true
			)

func spawn_server_player(client_id : int, spawn_tform : Transform3D, team : int):
	var server_player_real := preload("res://player/player_server_real.tscn").instantiate()
	var server_player_dummy := preload("res://player/player_server_dummy.tscn").instantiate()
	server_player_real.name = str(client_id)
	server_player_dummy.name = str(client_id) + "_dummy"
	server_player_real.global_transform = spawn_tform
	server_player_real.lobby = self
	server_player_dummy.id = client_id
	add_child(server_player_real, true)
	add_child(server_player_dummy, true)

	# CRITICAL: Assign players to lobby's physics space (fixes grenade detection in PVP)
	assign_physics_space_recursive(server_player_real)
	assign_physics_space_recursive(server_player_dummy)

	server_players[client_id] = {}
	server_players[client_id].real = server_player_real
	server_players[client_id].dummy = server_player_dummy
	client_data[client_id].team = team
		
@rpc("authority", "call_remote", "reliable")
func s_spawn_player(client_id: int, spawn_tform : Transform3D, team : int, player_name : String, weapon_id : int, auto_freeze: bool):
	pass

@rpc("authority", "call_remote", "reliable")
func s_player_weapon_changed(player_id: int, weapon_id: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_start_match() -> void:
	pass 

@rpc("any_peer", "call_remote", "unreliable_ordered")
func c_send_player_state(player_state : Dictionary) -> void:
	var client_id := multiplayer.get_remote_sender_id()

	if not server_players.has(client_id):
		return

	var player_real = server_players.get(client_id).real
	if not is_instance_valid(player_real):
		return

	current_world_state.ps[client_id] = player_state
	player_real.position = player_state.pos
	player_real.rotation.y = player_state.rot_y
	player_real.set_anim(player_state.anim)

func start_weapon_selection() -> void:
	for ready_client in get_connected_clients():
		s_start_weapon_selection.rpc_id(ready_client)

@rpc("authority", "call_remote", "reliable")
func s_start_weapon_selection() -> void:
	pass

@rpc("any_peer", "call_remote", "reliable")
func c_weapon_selected(weapon_id : int) -> void:
	var weapons := ["Pistol", "SMG", "Shotgun"]
	var client_id := multiplayer.get_remote_sender_id()
	if not client_id in client_data.keys() or client_id in ready_clients:
		return
	client_data[client_id].weapon_id = weapon_id

	if status == GAME:
		respawn_player(client_id)
		return

	ready_clients.append(client_id)
	waiting_players_ready = true
	check_players_ready(start_match)

@rpc("any_peer", "call_remote", "reliable")
func c_weapon_switched(weapon_id : int) -> void:
	var client_id := multiplayer.get_remote_sender_id()
	if not client_id in client_data.keys():
		return
	client_data[client_id].weapon_id = weapon_id

	# Broadcast weapon change to all other clients so they see the visual change
	for peer_id in get_connected_clients():
		if peer_id != client_id:
			s_player_weapon_changed.rpc_id(peer_id, client_id, weapon_id)

	print("%s Player %d switched to weapon %d" % [_get_time_string(), client_id, weapon_id])

func get_player_weapon_stats(player_id: int, weapon_id: int) -> Dictionary:
	# Get base weapon stats
	var weapon_data = WeaponConfig.get_weapon_data(weapon_id).duplicate(true)

	if not client_data.has(player_id):
		return weapon_data

	# Get weapon upgrade tier
	var upgrade_tier = 0
	if client_data[player_id].has("weapon_upgrade_tiers"):
		upgrade_tier = client_data[player_id].weapon_upgrade_tiers.get(weapon_id, 0)

	# Apply tier-based upgrade bonuses (additive per tier)
	# Each tier: +33% mag, +50% reserve ammo, +25% damage
	if upgrade_tier > 0:
		var mag_multiplier = 1.0 + (upgrade_tier * 0.33)
		var reserve_multiplier = 1.0 + (upgrade_tier * 0.5)
		var damage_multiplier = 1.0 + (upgrade_tier * 0.25)

		weapon_data["mag_size"] = int(weapon_data["mag_size"] * mag_multiplier)
		weapon_data["reserve_ammo"] = int(weapon_data["reserve_ammo"] * reserve_multiplier)
		weapon_data["damage"] = int(weapon_data["damage"] * damage_multiplier)

	return weapon_data

func start_match() -> void:
	status = GAME
	spawn_players()

	# Initialize zombies mode if needed
	if game_mode == MapRegistry.GameMode.ZOMBIES:
		var WaveManagerClass = load("res://server/zombies_mode/wave_manager.gd")
		wave_manager = WaveManagerClass.new()
		wave_manager.lobby = self
		add_child(wave_manager)
		# Start first wave after a brief delay
		await get_tree().create_timer(0.5).timeout
		wave_manager.start_first_wave()

	await get_tree().create_timer(1).timeout

	for ready_client_id in get_connected_clients():
		s_start_match.rpc_id(ready_client_id)

	set_physics_process(true)

	# Only use match timer for PvP mode
	if game_mode == MapRegistry.GameMode.PVP:
		update_match_time_left()
		match_timer.start()

func respawn_player(respawn_client_id : int) -> void:
	var team : int = client_data.get(respawn_client_id).team
	var team_prefix := "Blue" if team == 0 else "Red"
	var possible_spawn_points : Array[Node3D] = []
	
	for spawn_point in spawn_points:
		if spawn_point.name.begins_with(team_prefix):
			possible_spawn_points.append(spawn_point)
			
	var spawn_point : Node3D = possible_spawn_points.pick_random()
	
	spawn_server_player(respawn_client_id, spawn_point.transform, team)
	
	for client_id in get_connected_clients():
			s_spawn_player.rpc_id(
				client_id,
				respawn_client_id,
				spawn_point.transform,
				team,
				client_data.get(respawn_client_id).display_name,
				client_data.get(respawn_client_id).weapon_id,
				false
			)

@rpc("any_peer", "call_remote", "unreliable")
func c_shot_fired(time_stamp : int, player_data : Dictionary) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	#print("%s %d has shot a bullet" % [_get_time_string(), sender_id])
	for client_id in get_connected_clients():
		if client_id != sender_id:
			s_play_shoot_fx.rpc_id(client_id, sender_id)
	
	if sender_id in server_players.keys():
		calculate_shot_results(sender_id, time_stamp, player_data)

func calculate_shot_results(shooter_id : int, time_stamp : int, player_data : Dictionary) -> void:
	var target_time := time_stamp - 100 # 100 ms buffering delay from client
	var target_world_state : Dictionary

	for world_state in previous_world_states:
		if world_state.t < target_time:
			target_world_state = world_state
			break

	if target_world_state == null:
		return

	for client_id in target_world_state.ps.keys():
		if not client_id in server_players.keys():
			continue

		var player_dummy = server_players.get(client_id).dummy
		if not is_instance_valid(player_dummy):
			continue

		if not client_id in previous_world_states[0].ps.keys():
			continue

		if client_id == shooter_id:
			player_dummy.update_body_geometry(player_data)
			continue

		if not target_world_state.ps.get(client_id).is_empty():
			player_dummy.update_body_geometry(target_world_state.ps.get(client_id))

	await get_tree().physics_frame

	if not shooter_id in server_players.keys():
		return

	var shooter_dummy : ServerPlayerDummy = server_players.get(shooter_id).dummy
	if not is_instance_valid(shooter_dummy):
		return

	# LAG COMPENSATION FOR ZOMBIES: Rewind zombies to historical positions
	var zombie_original_states := {}
	if target_world_state.has("zs") and not target_world_state.zs.is_empty():
		for zombie_id in target_world_state.zs.keys():
			if zombies.has(zombie_id):
				var zombie = zombies.get(zombie_id)
				if is_instance_valid(zombie):
					# Store current state
					zombie_original_states[zombie_id] = {
						"pos": zombie.position,  # Store LOCAL position
						"rot_y": zombie.rotation.y
					}
					# Rewind to historical state (historical pos is in LOCAL coordinates)
					var historical_local_pos = target_world_state.zs[zombie_id].pos
					zombie.position = historical_local_pos  # Set LOCAL position
					zombie.rotation.y = target_world_state.zs[zombie_id].rot_y

	# Get weapon stats with upgrades applied
	var current_weapon_id = client_data.get(shooter_id).weapon_id
	var weapon_data := get_player_weapon_stats(shooter_id, current_weapon_id)
	var space_state = PhysicsServer3D.space_get_direct_state(physics_space_rid)
	var ray_params := PhysicsRayQueryParameters3D.new()
	var head_tform := shooter_dummy.head.global_transform

	ray_params.from = shooter_dummy.head.global_position
	ray_params.collide_with_areas = true
	var exclude_list : Array[RID] = []
	exclude_list.append(shooter_dummy.get_rid())  # Exclude the shooter's dummy body
	exclude_list.append_array(shooter_dummy.hitboxes)
	# Also exclude the shooter's real body to prevent self-hits
	var shooter_real : PlayerServerReal = server_players.get(shooter_id).real
	if is_instance_valid(shooter_real):
		exclude_list.append(shooter_real.get_rid())
	ray_params.exclude = exclude_list
	ray_params.collision_mask = 16 + 4 + 8 # 16 = environment_exact, 4 = hitboxes, 8 = zombies

	for i in weapon_data["projectiles"]:
		var rand_rot : float = deg_to_rad(randf() * (1 - weapon_data["accuracy"]) * 5) # 5 is the max degree of inaccuracy
		var shoot_tform := head_tform.rotated_local(Vector3.FORWARD, randf() * PI * 2)
		shoot_tform = shoot_tform.rotated_local(Vector3.UP, rand_rot)

		# Penetration system
		var max_penetrations : int = weapon_data.get("max_penetrations", 0)
		var penetration_falloff : float = weapon_data.get("penetration_damage_falloff", 1.0)
		var penetrations_done := 0
		var current_damage_multiplier := 1.0
		var excluded_colliders : Array = []
		excluded_colliders.append(shooter_dummy.get_rid())
		excluded_colliders.append_array(shooter_dummy.hitboxes)
		# Exclude real body from penetration checks too
		if is_instance_valid(shooter_real):
			excluded_colliders.append(shooter_real.get_rid())
		var ray_start := ray_params.from
		var ray_direction := shoot_tform.basis.z * -1
		var initial_ray_start := ray_start  # Track starting position for trail
		var final_hit_pos := ray_start + ray_direction * 100  # Default to max range

		while penetrations_done <= max_penetrations:
			ray_params.from = ray_start
			ray_params.to = ray_start + ray_direction * 100
			ray_params.exclude = excluded_colliders

			var result := space_state.intersect_ray(ray_params)

			# Shot forgiveness: if main ray misses, try offset rays in 3D sphere
			if result.is_empty() or (result.collider is not ZombieHitbox and result.collider is not ZombieServer and result.collider is not HitBox):
				const FORGIVENESS_RADIUS := 0.75  # 2x larger, equal in all dimensions
				const FORGIVENESS_SAMPLES := 4

				for sample_idx in FORGIVENESS_SAMPLES:
					var angle := (TAU / FORGIVENESS_SAMPLES) * sample_idx
					# Get perpendicular vectors in world space (not tied to ray direction)
					var right := Vector3.RIGHT
					var forward := Vector3.FORWARD

					# Create offset with equal distribution in all dimensions
					var offset := (right * cos(angle) + forward * sin(angle)) * FORGIVENESS_RADIUS
					offset.y = sin(angle * 2) * FORGIVENESS_RADIUS  # Full radius for vertical

					ray_params.from = ray_start + offset
					ray_params.to = ray_start + offset + ray_direction * 100

					var forgiveness_result := space_state.intersect_ray(ray_params)
					if not forgiveness_result.is_empty():
						# Check if we hit a valid target (zombie or player)
						if forgiveness_result.collider is ZombieHitbox or forgiveness_result.collider is ZombieServer or forgiveness_result.collider is HitBox:
							result = forgiveness_result
							break

			if result.is_empty():
				break

			var hit_something := false
			final_hit_pos = result.position  # Update final hit position

			# Check if hit a zombie hitbox (head or body)
			if result.collider is ZombieHitbox:
				var hitbox : ZombieHitbox = result.collider
				var zombie : ZombieServer = hitbox.zombie
				if is_instance_valid(zombie):
					var is_headshot : bool = hitbox.damage_multiplier > 1.5
					var base_damage = -weapon_data["damage"] * hitbox.damage_multiplier * current_damage_multiplier

					# Apply Insta-Kill power-up (instant kill)
					if is_powerup_active("insta_kill"):
						base_damage = -9999  # Guaranteed kill

					# Apply Marksman perk (+50% headshot damage)
					if is_headshot and client_data.has(shooter_id):
						var shooter_perks = client_data[shooter_id].get("perks", [])
						if "Marksman" in shooter_perks:
							base_damage *= 1.5

					var zombie_id = zombie.name.to_int()

					zombie.change_health(int(base_damage), shooter_id)
					update_zombie_health(zombie_id, zombie.current_health, zombie.max_health, int(base_damage), shooter_id, is_headshot)
					spawn_bullet_hit_fx(result.position - global_position, result.normal, 1)

					# Exclude ALL of this zombie's hitboxes and the zombie itself for penetration
					excluded_colliders.append(zombie)
					for child in zombie.get_children():
						if child is ZombieHitbox:
							excluded_colliders.append(child)
					hit_something = true

			# Check if hit a zombie body directly (fallback)
			elif result.collider is ZombieServer:
				var zombie : ZombieServer = result.collider
				var damage = -weapon_data["damage"] * current_damage_multiplier

				# Apply Insta-Kill power-up (instant kill)
				if is_powerup_active("insta_kill"):
					damage = -9999  # Guaranteed kill

				var zombie_id = zombie.name.to_int()
				zombie.change_health(int(damage), shooter_id)
				update_zombie_health(zombie_id, zombie.current_health, zombie.max_health, int(damage), shooter_id, false)
				spawn_bullet_hit_fx(result.position - global_position, result.normal, 1)

				excluded_colliders.append(result.collider)
				hit_something = true

			# Check if hit a player
			elif result.collider is HitBox:
				var hurt_client_id = result.collider.player.id

				if server_players.has(hurt_client_id):
					if client_data.get(shooter_id).team != client_data.get(hurt_client_id).team:
						var hurt_server_player : PlayerServerReal = server_players.get(hurt_client_id).real
						var is_headshot : bool = result.collider.damage_multiplier > 1.5
						var base_damage = -weapon_data["damage"] * result.collider.damage_multiplier * current_damage_multiplier

						# Apply Marksman perk (+50% headshot damage)
						if is_headshot and client_data.has(shooter_id):
							var shooter_perks = client_data[shooter_id].get("perks", [])
							if "Marksman" in shooter_perks:
								base_damage *= 1.5

						var damage_falloff_start := 10
						var damage_falloff_end := 20
						var damage_max_falloff := 0.4
						var distance = shooter_dummy.head.global_position.distance_to(result.position)
						var damage_falloff_multiplier = remap(distance, damage_falloff_start, damage_falloff_end, 1, damage_max_falloff)
						damage_falloff_multiplier = clampf(damage_falloff_multiplier, damage_max_falloff, 1)
						var damage_dealt = base_damage * damage_falloff_multiplier
						hurt_server_player.change_health(damage_dealt, shooter_id, is_headshot)
						spawn_bullet_hit_fx(result.position - global_position, result.normal, 1)

						excluded_colliders.append(result.collider)
						hit_something = true
			else:
				# Hit environment - stop penetration
				spawn_bullet_hit_fx(result.position - global_position, result.normal, 0)
				break

			# Continue penetration if we hit something and have penetrations left
			if hit_something and penetrations_done < max_penetrations:
				penetrations_done += 1
				current_damage_multiplier *= (1.0 - penetration_falloff)
				ray_start = result.position + ray_direction * 0.1  # Move forward to avoid re-hitting same collider
			else:
				break

		# Spawn bullet trail for upgraded weapons (from muzzle to final hit/max range)
		spawn_bullet_trail(shooter_id, initial_ray_start, final_hit_pos)

	# RESTORE ZOMBIE POSITIONS after raycasting
	for zombie_id in zombie_original_states.keys():
		if zombies.has(zombie_id):
			var zombie = zombies.get(zombie_id)
			if is_instance_valid(zombie):
				zombie.position = zombie_original_states[zombie_id].pos  # Restore LOCAL position
				zombie.rotation.y = zombie_original_states[zombie_id].rot_y

func spawn_bullet_hit_fx(pos: Vector3, normal : Vector3, type: int) -> void:
	# 0 environment, 1 player
	for client_id in get_connected_clients():
		s_spawn_bullet_hit_fx.rpc_id(client_id, pos, normal, type)
		
@rpc("authority", "call_remote", "unreliable")
func s_spawn_bullet_hit_fx(pos: Vector3, normal : Vector3, type: int) -> void:
	pass

func spawn_bullet_trail(shooter_id: int, from_pos: Vector3, to_pos: Vector3) -> void:
	# Get shooter's current weapon and upgrade tier
	if not client_data.has(shooter_id):
		return

	var weapon_id = client_data[shooter_id].weapon_id
	var upgrade_tier = 0

	if client_data[shooter_id].has("weapon_upgrade_tiers"):
		upgrade_tier = client_data[shooter_id].weapon_upgrade_tiers.get(weapon_id, 0)

	# Only spawn trails for upgraded weapons
	if upgrade_tier > 0:
		# Offset the trail start position forward from camera/head to make it more visible
		# Without this, the trail spawns too close to the camera and is hard to see
		const TRAIL_START_OFFSET = 1.5  # Meters forward from head position
		const TRAIL_Y_OFFSET = -0.3  # Drop trail down slightly to avoid blocking view
		var shoot_direction = (to_pos - from_pos).normalized()
		var offset_from_pos = from_pos + (shoot_direction * TRAIL_START_OFFSET)
		offset_from_pos.y += TRAIL_Y_OFFSET  # Drop it down

		for client_id in get_connected_clients():
			s_spawn_bullet_trail.rpc_id(client_id, offset_from_pos, to_pos, weapon_id, upgrade_tier)

@rpc("authority", "call_remote", "unreliable")
func s_spawn_bullet_trail(from_pos: Vector3, to_pos: Vector3, weapon_id: int, upgrade_tier: int) -> void:
	pass

@rpc("authority", "call_remote", "unreliable")
func s_play_shoot_fx(target_client_id : int) -> void:
	pass

func update_health(target_client_id : int, current_health : int, max_health : int, changed_amount: int, shooter_id : int = 0, is_headshot := false) -> void:
	for client_id in get_connected_clients():
		s_update_health.rpc_id(client_id, target_client_id, current_health, max_health, changed_amount, shooter_id, is_headshot)

@rpc("authority", "call_remote", "unreliable_ordered")
func s_update_health(target_client_id : int, current_health : int, max_health : int, changed_amount: int, shooter_id : int = 0, is_headshot := false) -> void:
	pass

func pickup_cooldown_started(pickup_name : String) -> void:
	for client_id in get_connected_clients():
		s_pickup_cooldown_started.rpc_id(client_id, pickup_name)

@rpc("authority", "call_remote", "reliable")
func s_pickup_cooldown_started(pickup_name : String) -> void:
	pass
	
func pickup_cooldown_ended(pickup_name : String) -> void:
	for client_id in get_connected_clients():
		s_pickup_cooldown_ended.rpc_id(client_id, pickup_name)

@rpc("authority", "call_remote", "reliable")
func s_pickup_cooldown_ended(pickup_name : String) -> void:
	pass

func player_died(dead_player_id : int, killer_id : int) -> void:
	server_players.get(dead_player_id).real.queue_free()
	server_players.get(dead_player_id).dummy.queue_free()
	server_players.erase(dead_player_id)
	current_world_state.ps.erase(dead_player_id)

	if client_data.has(dead_player_id):
		client_data.get(dead_player_id).deaths += 1
	if dead_player_id != killer_id and client_data.has(killer_id):
		client_data.get(killer_id).kills += 1
	
	for client_id in get_connected_clients():
		s_player_died.rpc_id(client_id, dead_player_id, killer_id)
		
	update_game_scores()
	await get_tree().create_timer(DEATH_COOLDOWN_LENGTH).timeout
	s_start_weapon_selection.rpc_id(dead_player_id)
	
@rpc("authority", "call_remote", "reliable")
func s_player_died(dead_player_id : int, killer_id) -> void:
	pass

func update_game_scores() -> void:
	var blue_team_kills := 0
	var red_team_kills := 0
	
	for data in client_data.values():
		if data.team == 0:
			red_team_kills += data.deaths
		else:
			blue_team_kills += data.deaths
			
	for client_id in get_connected_clients():
		s_update_game_scores.rpc_id(client_id, blue_team_kills, red_team_kills)
	
	if blue_team_kills >= TEAM_SCORE_TO_WIN or red_team_kills >= TEAM_SCORE_TO_WIN:
		end_match()
		
@rpc("authority", "call_remote", "reliable")
func s_update_game_scores(blue_score : int, red_score : int) -> void:
	pass

func match_timer_sec_passed() -> void:
	match_time_left -= 1
	update_match_time_left()
	if match_time_left <= 0:
		end_match()

func update_match_time_left() -> void:
	for client_id in get_connected_clients():
		s_update_match_time_left.rpc_id(client_id, match_time_left)

@rpc("authority", "call_remote", "unreliable_ordered")
func s_update_match_time_left(time_left : int) -> void:
	pass

func end_match() -> void:
	status = FINISHED
	match_timer.stop()
	set_physics_process(false)

	for client_id in client_data.keys():
		var data = client_data[client_id]

	for client_id in get_connected_clients():
		s_end_match.rpc_id(client_id, client_data, game_mode)

	Server.delete_lobby(self)
	
@rpc("authority", "call_remote", "reliable")
func s_end_match(end_client_data : Dictionary, end_game_mode : int) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable")
func c_try_throw_grenade(player_state : Dictionary) -> void:
	var client_id := multiplayer.get_remote_sender_id()
	
	if not server_players.has(client_id):
		return
		
	var player : PlayerServerReal = server_players.get(client_id).real
	
	if player.grenades_left <= 0:
		return
		
	player.update_grenades_left(player.grenades_left - 1)
	s_update_grenades_left.rpc_id(client_id, player.grenades_left)
	
	var grenade : Grenade = preload("res://player/grenade/grenade.tscn").instantiate()
	var direction := Vector3.FORWARD
	direction = direction.rotated(Vector3.RIGHT, player_state.rot_x)
	direction = direction.rotated(Vector3.UP, player_state.rot_y)
	
	grenade.set_data(self, direction, player)
	grenade.position = player_state.pos + Vector3.UP * 1.2
	
	grenade.name = str(grenade.get_instance_id())
	add_child(grenade, true)

	# CRITICAL: Assign grenade and its children (ExplosionDamageArea) to lobby's physics space
	assign_physics_space_recursive(grenade)

	grenades[grenade.name] = grenade

func update_grenades_left(client_id : int, amount : int) -> void:
	s_update_grenades_left.rpc_id(client_id, amount)

@rpc("authority", "call_remote", "unreliable_ordered")
func s_update_grenades_left(grenades_left : int) -> void:
	pass

func replenish_ammo(client_id : int) -> void:
	s_replenish_ammo.rpc_id(client_id)

@rpc("authority", "call_remote", "reliable")
func s_replenish_ammo() -> void:
	pass

func grenade_exploded(grenade : Grenade) -> void:
	var grenade_name = grenade.name
	
	if grenades.has(grenade_name):
		grenades.erase(grenade_name)
	if current_world_state.gr.has(grenade_name):
		current_world_state.gr.erase(grenade_name)
		
	grenade.queue_free()
	
	for client_id in get_connected_clients():
		s_explode_grenade.rpc_id(client_id, grenade_name)
		
@rpc("authority", "call_remote", "reliable")
func s_explode_grenade(grenade_name : String) -> void:
	pass

func play_pickup_fx(client_id : int, pickup_type : int) -> void:
	s_play_pickup_fx.rpc_id(client_id, pickup_type)
	
@rpc("authority", "call_remote", "unreliable")
func s_play_pickup_fx(pickup_type: int) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable")
func c_client_quit_match() -> void:
	var client_id := multiplayer.get_remote_sender_id()
	remove_client(client_id)
	current_world_state.ps.erase(client_id)

@rpc("any_peer", "call_remote", "reliable")
func c_send_chat_message(message: String) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	var sender_name = client_data.get(sender_id).display_name
	var sender_team = client_data.get(sender_id).team
	
	if message.begins_with("/t "):
		# Team-only message
		var team_message := message.substr(3)  # Remove "/t " prefix
		
		# Send to teammates only
		for client_id in get_connected_clients():
			if client_data.get(client_id).team == sender_team:
				s_receive_chat_message.rpc_id(client_id, sender_id, sender_name, sender_team, team_message, true)
	else:
		# Global message to all players
		for client_id in get_connected_clients():
			s_receive_chat_message.rpc_id(client_id, sender_id, sender_name, sender_team, message, false)

@rpc("authority", "call_remote", "reliable")
func s_receive_chat_message(sender_id: int, sender_name: String, sender_team: int, message: String, is_team_only: bool) -> void:
	pass

# Zombies mode specific methods
func zombie_died(zombie_id : int, killer_id : int, zombie_type : int, death_position : Vector3) -> void:
	if game_mode != 1:  # MapRegistry.GameMode.ZOMBIES = 1
		return

	# Remove zombie from tracking
	if zombies.has(zombie_id):
		zombies.get(zombie_id).queue_free()
		zombies.erase(zombie_id)

	# Award points to killer
	var zombie_points := 100  # Default
	match zombie_type:
		0: zombie_points = 100  # Normal
		1: zombie_points = 150  # Fast
		2: zombie_points = 200  # Tank

	# Apply Double Points power-up (2x multiplier)
	if is_powerup_active("double_points"):
		zombie_points *= 2

	if client_data.has(killer_id):
		client_data[killer_id].points += zombie_points
		client_data[killer_id].kills += 1
		s_update_player_points.rpc_id(killer_id, client_data[killer_id].points)
	else:
		print("WARNING: Zombie killer_id ", killer_id, " not in client_data!")

		# Broadcast all player scores to all clients (for teammate cards)
		update_all_player_scores()

	# Random chance to spawn pickup using weighted drop table
	var roll = randf() + (zombie_id * 0.00001)  # Add tiny offset based on zombie_id to prevent dupes
	roll = fmod(roll, 1.0)  # Wrap back to 0-1 range
	var cumulative_chance = 0.0
	for drop_entry in ZOMBIE_DROP_TABLE:
		cumulative_chance += drop_entry.chance
		if roll < cumulative_chance:
			spawn_zombie_drop(death_position, drop_entry.pickup_type)
			break

	# Notify wave manager
	if wave_manager:
		wave_manager.on_zombie_killed()

	# Notify clients
	for client_id in get_connected_clients():
		s_zombie_died.rpc_id(client_id, zombie_id)

func spawn_zombie_drop(pos : Vector3, pickup_type : int) -> void:
	var pickup : Pickup = preload("res://player/pickups/pickup.tscn").instantiate()
	var pickup_name = "zombie_drop_" + str(Time.get_ticks_msec()) + "_" + str(randi())
	pickup.name = pickup_name
	pickup.position = pos
	pickup.pickup_type = pickup_type
	pickup.lobby = self
	pickup.is_one_time_use = true  # Zombie drops disappear after pickup
	pickup.should_despawn = true  # Power-ups despawn after 30s
	add_child(pickup, true)

	# CRITICAL: Assign pickup's Area3D to lobby's physics space (fixes pickup detection)
	assign_physics_space_recursive(pickup)

	pickups.append(pickup)
	for client_id in get_connected_clients():
		s_spawn_pickup.rpc_id(client_id, pickup_name, pickup_type, pos)

func activate_max_ammo() -> void:
	# Refill all players' weapons and grenades
	for player_data in server_players.values():
		var player : PlayerServerReal = player_data.real
		if is_instance_valid(player):
			replenish_ammo(player.name.to_int())
			# Refill grenades to max (2)
			player.update_grenades_left(2)

	# Notify all clients with visual/audio effect
	for client_id in get_connected_clients():
		s_powerup_collected.rpc_id(client_id, "max_ammo")

func activate_powerup(powerup_name : String, collector_id : int) -> void:
	# Create or refresh timer for timed power-up
	if active_powerups.has(powerup_name):
		# Refresh duration if already active
		var timer : Timer = active_powerups[powerup_name]
		timer.start(POWERUP_DURATION)
	else:
		# Create new timer
		var timer = Timer.new()
		timer.wait_time = POWERUP_DURATION
		timer.one_shot = true
		timer.timeout.connect(func(): _on_powerup_expired(powerup_name))
		add_child(timer)
		timer.start()
		active_powerups[powerup_name] = timer

	# Notify all clients
	for client_id in get_connected_clients():
		s_powerup_activated.rpc_id(client_id, powerup_name, POWERUP_DURATION)

func activate_nuke(collector_id : int) -> void:
	const NUKE_POINTS = 50  # Reduced points per zombie
	var zombies_killed = 0

	# Kill all active zombies (need to iterate over keys to avoid modification during iteration)
	var zombie_ids = zombies.keys()
	for zombie_id in zombie_ids:
		if zombies.has(zombie_id):
			var zombie = zombies[zombie_id]
			if is_instance_valid(zombie):
				# Notify all clients this zombie died
				for client_id in get_connected_clients():
					s_zombie_died.rpc_id(client_id, zombie_id)

				zombie.queue_free()
				zombies.erase(zombie_id)
				zombies_killed += 1

	# Award points to collector
	if client_data.has(collector_id):
		var points_awarded = zombies_killed * NUKE_POINTS
		client_data[collector_id].points += points_awarded
		s_update_player_points.rpc_id(collector_id, client_data[collector_id].points)
		update_all_player_scores()

	# Update wave manager
	if wave_manager:
		for i in zombies_killed:
			wave_manager.on_zombie_killed()

	# Notify all clients
	for client_id in get_connected_clients():
		s_powerup_collected.rpc_id(client_id, "nuke")

func _on_powerup_expired(powerup_name : String) -> void:
	if active_powerups.has(powerup_name):
		var timer : Timer = active_powerups[powerup_name]
		timer.queue_free()
		active_powerups.erase(powerup_name)

	# Notify all clients
	for client_id in get_connected_clients():
		s_powerup_expired.rpc_id(client_id, powerup_name)

func is_powerup_active(powerup_name : String) -> bool:
	return active_powerups.has(powerup_name)

func award_damage_points(player_id : int, points : int) -> void:
	if game_mode != MapRegistry.GameMode.ZOMBIES:
		return

	if not client_data.has(player_id):
		return

	client_data[player_id].points += points
	s_update_player_points.rpc_id(player_id, client_data[player_id].points)
	update_all_player_scores()

func update_all_player_scores() -> void:
	# Build a dictionary of all player scores
	var scores := {}
	for player_id in client_data.keys():
		scores[player_id] = client_data[player_id].points

	# Broadcast to all clients
	for client_id in get_connected_clients():
		s_update_teammate_scores.rpc_id(client_id, scores)

func delete_pickup(pickup_name : String) -> void:
	# Remove from pickups array
	for i in range(pickups.size()):
		if pickups[i].name == pickup_name:
			pickups.remove_at(i)
			break

	# Tell clients to delete it
	for client_id in get_connected_clients():
		s_delete_pickup.rpc_id(client_id, pickup_name)

func update_zombie_health(zombie_id : int, current_health : int, max_health : int, changed_amount: int, shooter_id : int, is_headshot := false) -> void:
	for client_id in get_connected_clients():
		s_update_zombie_health.rpc_id(client_id, zombie_id, current_health, max_health, changed_amount, shooter_id, is_headshot)

# Down/Revive system for zombies mode
func player_downed(player_id : int, damager_id : int) -> void:
	if game_mode != 1:  # Only in zombies mode
		return

	print("Player ", player_id, " downed by ", damager_id)

	# Notify all clients
	for client_id in get_connected_clients():
		s_player_downed.rpc_id(client_id, player_id, damager_id)

	# Check if all players are downed (game over condition)
	check_all_players_downed()

func player_revived(player_id : int) -> void:
	print("Player ", player_id, " revived")
	for client_id in get_connected_clients():
		s_player_revived.rpc_id(client_id, player_id)

func player_waiting_for_respawn(player_id : int) -> void:
	print("Player ", player_id, " is waiting for next round")
	for client_id in get_connected_clients():
		s_player_waiting_for_respawn.rpc_id(client_id, player_id)

	# Check if all players are dead/waiting
	check_all_players_downed()

func player_respawned(player_id : int) -> void:
	print("Player ", player_id, " respawned")
	for client_id in get_connected_clients():
		s_player_respawned.rpc_id(client_id, player_id)

func update_bleed_out_timer(player_id : int, time_remaining : float) -> void:
	# Send to the downed player only (no need to spam everyone)
	if get_connected_clients().has(player_id):
		s_update_bleed_out_timer.rpc_id(player_id, time_remaining)

func check_all_players_downed() -> void:
	var all_downed_or_waiting := true
	for player_data in server_players.values():
		var player : PlayerServerReal = player_data.real
		if is_instance_valid(player) and not player.is_downed and not player.is_waiting_for_respawn:
			all_downed_or_waiting = false
			break

	if all_downed_or_waiting:
		print("All players downed or dead - Game Over!")
		end_zombies_match()

func end_zombies_match() -> void:
	print("Ending zombies match...")
	# TODO: Add proper end match screen with stats
	end_match()

# Revive RPCs
@rpc("any_peer", "call_remote", "reliable")
func c_try_start_revive(target_player_id : int) -> void:
	var reviver_id := multiplayer.get_remote_sender_id()

	# Validate reviver exists and is not downed
	if not server_players.has(reviver_id):
		return
	var reviver : PlayerServerReal = server_players.get(reviver_id).real
	if not is_instance_valid(reviver) or reviver.is_downed:
		return

	# Validate target exists and is downed
	if not server_players.has(target_player_id):
		return
	var target : PlayerServerReal = server_players.get(target_player_id).real
	if not is_instance_valid(target) or not target.can_be_revived():
		return

	# Check distance (must be within 5 meters)
	var distance := reviver.global_position.distance_to(target.global_position)
	if distance > 5.0:
		return

	# Start the revive
	target.start_being_revived(reviver_id)
	print("Player ", reviver_id, " started reviving ", target_player_id)

	# Notify clients
	var target_name : String = client_data.get(target_player_id).display_name
	s_revive_started.rpc_id(reviver_id, target_player_id, target_name)

@rpc("any_peer", "call_remote", "reliable")
func c_update_revive_progress(target_player_id : int, progress : float) -> void:
	var reviver_id := multiplayer.get_remote_sender_id()

	# Validate this player is actually reviving the target
	if not server_players.has(target_player_id):
		return
	var target : PlayerServerReal = server_players.get(target_player_id).real
	if not is_instance_valid(target) or target.being_revived_by != reviver_id:
		return

	# Send progress update to reviver
	s_revive_progress_update.rpc_id(reviver_id, progress)

@rpc("any_peer", "call_remote", "reliable")
func c_complete_revive(target_player_id : int) -> void:
	var reviver_id := multiplayer.get_remote_sender_id()

	# Validate this player is actually reviving the target
	if not server_players.has(target_player_id):
		return
	var target : PlayerServerReal = server_players.get(target_player_id).real
	if not is_instance_valid(target) or target.being_revived_by != reviver_id:
		return

	# Complete the revive
	target.revive()
	print("Player ", reviver_id, " completed revive of ", target_player_id)

@rpc("any_peer", "call_remote", "reliable")
func c_cancel_revive(target_player_id : int) -> void:
	var reviver_id := multiplayer.get_remote_sender_id()

	# Stop being revived
	if server_players.has(target_player_id):
		var target : PlayerServerReal = server_players.get(target_player_id).real
		if is_instance_valid(target):
			target.stop_being_revived()

# Debug RPCs (zombies mode only)
@rpc("any_peer", "call_remote", "reliable")
func c_debug_add_points(amount : int) -> void:
	if game_mode != 1:  # Only in zombies mode
		return
	var client_id := multiplayer.get_remote_sender_id()
	if client_data.has(client_id):
		client_data[client_id].points += amount
		s_update_player_points.rpc_id(client_id, client_data[client_id].points)
		print("DEBUG: Added ", amount, " points to player ", client_id)

@rpc("any_peer", "call_remote", "reliable")
func c_debug_damage_or_kill(damage : int) -> void:
	if game_mode != 1:  # Only in zombies mode
		return
	var client_id := multiplayer.get_remote_sender_id()
	if server_players.has(client_id):
		var player : PlayerServerReal = server_players.get(client_id).real
		if is_instance_valid(player):
			# If downed, force death
			if player.is_downed:
				print("DEBUG: Forcing downed player ", client_id, " to die")
				player.bleed_out_timer = 0
				player.die(0)
			# If health would drop below 0, kill instantly
			elif player.current_health <= damage:
				print("DEBUG: Killing player ", client_id, " instantly")
				player.change_health(-player.current_health, 0)
			# Otherwise just deal damage
			else:
				print("DEBUG: Dealing ", damage, " damage to player ", client_id)
				player.change_health(-damage, 0)

@rpc("authority", "call_remote", "reliable")
func s_player_downed(player_id : int, damager_id : int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_player_revived(player_id : int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_player_waiting_for_respawn(player_id : int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_player_respawned(player_id : int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_update_bleed_out_timer(time_remaining : float) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_revive_started(target_player_id : int, target_name : String) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_revive_progress_update(progress : float) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_zombie_died(zombie_id : int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_update_player_points(points : int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_powerup_collected(powerup_name : String) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_powerup_activated(powerup_name : String, duration : float) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_powerup_expired(powerup_name : String) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_pickup_despawn_started(pickup_name : String, despawn_time : float) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_update_teammate_scores(scores : Dictionary) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_start_wave(wave_number : int, zombie_count : int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_spawn_zombie(zombie_id : int, position : Vector3, zombie_type : int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_update_zombies_remaining(zombies_remaining : int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_wave_complete(wave_number : int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_update_break_time(time_remaining : int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_delete_pickup(pickup_name : String) -> void:
	pass

@rpc("authority", "call_remote", "unreliable_ordered")
func s_update_zombie_health(zombie_id : int, current_health : int, max_health : int, changed_amount: int, shooter_id : int, is_headshot := false) -> void:
	pass

# Economy System - Buyables
var weapon_costs = {
	0: 0,       # Pistol (free starter)
	1: 1000,    # SMG
	2: 1500,    # Shotgun
	3: 3000,    # Sniper
	4: 2000,    # Assault Rifle
	5: 2500     # LMG
}

var ammo_costs = {
	1: 500,     # SMG
	2: 500,     # Shotgun
	3: 1000,    # Sniper
	4: 750,     # Assault Rifle
	5: 750      # LMG
}

var door_costs = {
	"door_test": 750,
	"door_spawn_room": 750,
	"door_power": 1250,
	"door_mystery_box": 1000
}

var perk_costs = {
	"CombatMedic": 1500,
	"Marksman": 1500,
	"RapidFire": 2000,
	"Endurance": 2000,
	"TacticalVest": 2500,
	"BlastShield": 2500,
	"FastHands": 3000,
	"HeavyGunner": 4000
}

var opened_doors: Dictionary = {}
var weapon_upgrade_cost: int = 5000
var max_weapon_upgrade_tier: int = 10  # Maximum upgrade tier (expandable)

@rpc("any_peer", "call_remote", "reliable")
func c_try_buy_weapon(weapon_id: int, is_ammo: bool = false) -> void:
	var peer_id = multiplayer.get_remote_sender_id()

	if not client_data.has(peer_id):
		return

	# Special handling for grenades (weapon_id 6)
	if weapon_id == 6:
		# Manually handle grenade purchase inline
		if not server_players.has(peer_id):
			return

		const GRENADE_REFILL_COST = 500
		var player_points = client_data[peer_id].points

		if player_points < GRENADE_REFILL_COST:
			s_purchase_failed.rpc_id(peer_id, "Not enough points!")
			print("%s Player %d tried to buy grenades but only has %d points (needs %d)" % [_get_time_string(), peer_id, player_points, GRENADE_REFILL_COST])
			return

		# Deduct points
		client_data[peer_id].points -= GRENADE_REFILL_COST

		# Refill grenades to 5
		var player : PlayerServerReal = server_players.get(peer_id).real
		player.update_grenades_left(5)

		# Notify client
		s_grenades_purchased.rpc_id(peer_id)
		s_update_player_points.rpc_id(peer_id, client_data[peer_id].points)
		s_update_grenades_left.rpc_id(peer_id, 5)

		print("%s Player %d bought grenade refill for %d points (now has %d points, 5 grenades)" % [_get_time_string(), peer_id, GRENADE_REFILL_COST, client_data[peer_id].points])
		return

	var player_points = client_data[peer_id].points

	# Check if player already has this weapon in their inventory
	var has_weapon = false
	if client_data[peer_id].has("weapons"):
		has_weapon = weapon_id in client_data[peer_id].weapons

	var cost = ammo_costs.get(weapon_id, 500) if has_weapon else weapon_costs.get(weapon_id, 1000)
	
	if player_points < cost:
		s_purchase_failed.rpc_id(peer_id, "Not enough points!")
		print("%s Player %d tried to buy weapon %d but only has %d points (needs %d)" % [_get_time_string(), peer_id, weapon_id, player_points, cost])
		return
	
	# Deduct points
	client_data[peer_id].points -= cost
	
	# Update weapon inventory if buying new one
	if not has_weapon:
		if not client_data[peer_id].has("weapons"):
			client_data[peer_id].weapons = []
		# Add to inventory (max 2 weapons)
		if client_data[peer_id].weapons.size() < 2:
			client_data[peer_id].weapons.append(weapon_id)
		else:
			# Replace the last weapon (client handles which one)
			client_data[peer_id].weapons[-1] = weapon_id
		print("%s Player %d inventory: %s" % [_get_time_string(), peer_id, str(client_data[peer_id].weapons)])
	
	# Send confirmation to client
	s_weapon_purchased.rpc_id(peer_id, weapon_id, has_weapon)
	s_update_player_points.rpc_id(peer_id, client_data[peer_id].points)
	
	print("%s Player %d %s weapon %d for %d points (now has %d points)" % [_get_time_string(), peer_id, "refilled ammo for" if has_weapon else "bought", weapon_id, cost, client_data[peer_id].points])

@rpc("any_peer", "call_remote", "reliable")
func c_try_buy_door(door_id: String) -> void:
	var peer_id = multiplayer.get_remote_sender_id()
	print("%s SERVER: Player %d trying to buy door: '%s'" % [_get_time_string(), peer_id, door_id])

	# Already open?
	if opened_doors.has(door_id):
		print("%s Player %d tried to buy door %s but it's already open" % [_get_time_string(), peer_id, door_id])
		return

	if not client_data.has(peer_id):
		return

	var player_points = client_data[peer_id].points
	var cost = door_costs.get(door_id, 750)

	if player_points < cost:
		s_purchase_failed.rpc_id(peer_id, "Not enough points!")
		print("%s Player %d tried to buy door %s but only has %d points (needs %d)" % [_get_time_string(), peer_id, door_id, player_points, cost])
		return

	# Deduct points
	client_data[peer_id].points -= cost
	opened_doors[door_id] = true

	# Open door on server
	print("%s SERVER: Opening door '%s' on server..." % [_get_time_string(), door_id])
	open_door_on_server(door_id)

	# Broadcast to ALL clients
	print("%s SERVER: Broadcasting door open to %d clients" % [_get_time_string(), get_connected_clients().size()])
	for client_id in get_connected_clients():
		print("%s   Sending s_door_opened('%s') to client %d" % [_get_time_string(), door_id, client_id])
		s_door_opened.rpc_id(client_id, door_id)

	s_update_player_points.rpc_id(peer_id, client_data[peer_id].points)
	
	print("%s Player %d opened door %s for %d points (now has %d points)" % [_get_time_string(), peer_id, door_id, cost, client_data[peer_id].points])

@rpc("any_peer", "call_remote", "reliable")
func c_try_upgrade_weapon(weapon_id: int) -> void:
	var peer_id = multiplayer.get_remote_sender_id()

	if not client_data.has(peer_id):
		return

	# Check if player has enough points
	var player_points = client_data[peer_id].points
	if player_points < weapon_upgrade_cost:
		s_purchase_failed.rpc_id(peer_id, "Not enough points for upgrade!")
		print("%s Player %d tried to upgrade weapon %d but only has %d points (needs %d)" % [_get_time_string(), peer_id, weapon_id, player_points, weapon_upgrade_cost])
		return

	# Initialize upgrade tiers dictionary if needed
	if not client_data[peer_id].has("weapon_upgrade_tiers"):
		client_data[peer_id].weapon_upgrade_tiers = {}

	# Get current tier for this weapon
	var current_tier = client_data[peer_id].weapon_upgrade_tiers.get(weapon_id, 0)

	# Check if weapon is at max upgrade tier
	if current_tier >= max_weapon_upgrade_tier:
		s_purchase_failed.rpc_id(peer_id, "Weapon already at max tier (%d)!" % current_tier)
		print("%s Player %d tried to upgrade weapon %d but it's already at max tier %d" % [_get_time_string(), peer_id, weapon_id, current_tier])
		return

	# Deduct points
	client_data[peer_id].points -= weapon_upgrade_cost

	# Increment weapon tier
	var new_tier = current_tier + 1
	client_data[peer_id].weapon_upgrade_tiers[weapon_id] = new_tier

	# Notify client
	s_weapon_upgraded.rpc_id(peer_id, weapon_id)
	s_update_player_points.rpc_id(peer_id, client_data[peer_id].points)

	print("%s Player %d upgraded weapon %d to tier %d for %d points (now has %d points)" % [_get_time_string(), peer_id, weapon_id, new_tier, weapon_upgrade_cost, client_data[peer_id].points])

@rpc("any_peer", "call_remote", "reliable")
func c_try_buy_perk(perk_type: String) -> void:
	var peer_id = multiplayer.get_remote_sender_id()

	if not client_data.has(peer_id):
		return

	# Check if perk exists
	if not perk_costs.has(perk_type):
		s_purchase_failed.rpc_id(peer_id, "Invalid perk type!")
		print("%s Player %d requested invalid perk: %s" % [_get_time_string(), peer_id, perk_type])
		return

	# Initialize perks array if needed
	if not client_data[peer_id].has("perks"):
		client_data[peer_id].perks = []

	# Check if player already has this perk
	if perk_type in client_data[peer_id].perks:
		s_purchase_failed.rpc_id(peer_id, "You already have this perk!")
		print("%s Player %d already has perk: %s" % [_get_time_string(), peer_id, perk_type])
		return

	# Check if player has enough points
	var cost = perk_costs[perk_type]
	var player_points = client_data[peer_id].points
	if player_points < cost:
		s_purchase_failed.rpc_id(peer_id, "Not enough points!")
		print("%s Player %d tried to buy perk %s but only has %d points (needs %d)" % [_get_time_string(), peer_id, perk_type, player_points, cost])
		return

	# Deduct points
	client_data[peer_id].points -= cost

	# Add perk to player
	client_data[peer_id].perks.append(perk_type)

	# Apply server-side perk effects
	if perk_type == "TacticalVest" and server_players.has(peer_id):
		# Heal player to full HP with new max (2x base HP = 200)
		var player : PlayerServerReal = server_players.get(peer_id).real
		var new_max_hp = player.get_max_health()  # Will return 200 now
		player.current_health = new_max_hp
		update_health(peer_id, player.current_health, new_max_hp, 0, 0, false)

	# Notify client
	s_perk_purchased.rpc_id(peer_id, perk_type)
	s_update_player_points.rpc_id(peer_id, client_data[peer_id].points)

	print("%s Player %d bought perk %s for %d points (now has %d points, %d perks)" % [_get_time_string(), peer_id, perk_type, cost, client_data[peer_id].points, client_data[peer_id].perks.size()])

@rpc("any_peer", "call_remote", "reliable")
func c_try_buy_grenades() -> void:
	var peer_id = multiplayer.get_remote_sender_id()

	if not client_data.has(peer_id):
		return

	if not server_players.has(peer_id):
		return

	# Grenade refill cost
	const GRENADE_REFILL_COST = 500
	var player_points = client_data[peer_id].points

	# Check if player has enough points
	if player_points < GRENADE_REFILL_COST:
		s_purchase_failed.rpc_id(peer_id, "Not enough points!")
		print("%s Player %d tried to buy grenades but only has %d points (needs %d)" % [_get_time_string(), peer_id, player_points, GRENADE_REFILL_COST])
		return

	# Deduct points
	client_data[peer_id].points -= GRENADE_REFILL_COST

	# Refill grenades to 5
	var player : PlayerServerReal = server_players.get(peer_id).real
	player.update_grenades_left(5)

	# Notify client
	s_grenades_purchased.rpc_id(peer_id)
	s_update_player_points.rpc_id(peer_id, client_data[peer_id].points)
	s_update_grenades_left.rpc_id(peer_id, 5)

	print("%s Player %d bought grenade refill for %d points (now has %d points, 5 grenades)" % [_get_time_string(), peer_id, GRENADE_REFILL_COST, client_data[peer_id].points])

@rpc("authority", "call_remote", "reliable")
func s_weapon_purchased(weapon_id: int, is_ammo: bool) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_door_opened(door_id: String) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_purchase_failed(reason: String) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_weapon_upgraded(weapon_id: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_perk_purchased(perk_type: String) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_grenades_purchased() -> void:
	pass

# Called after door purchase - opens door on server
func open_door_on_server(door_id: String) -> void:
	# Find door in map
	var door = get_node_or_null("Map/" + door_id)
	if not door:
		door = get_node_or_null("Map/Doors/" + door_id)
	if not door:
		door = get_node_or_null("Map/Buyables/" + door_id)

	if door and door.has_method("open_door"):
		door.open_door()
		print("%s Door %s opened on server" % [_get_time_string(), door_id])
	else:
		print("%s WARNING: Could not find door %s to open on server" % [_get_time_string(), door_id])
