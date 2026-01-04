extends CharacterBody3D
class_name ZombieServer

enum ZombieType {
	NORMAL,
	FAST,
	TANK
}

enum State {
	IDLE,
	CHASE,
	ATTACK,
	JUMPING,
	DEAD
}

# Zombie type configuration
const TYPE_CONFIG = {
	ZombieType.NORMAL: {
		"max_health": 100,
		"speed": 3.0,
		"damage": 15,
		"points": 100,
		"attack_cooldown": 1.0
	},
	ZombieType.FAST: {
		"max_health": 60,
		"speed": 5.5,
		"damage": 10,
		"points": 150,
		"attack_cooldown": 0.7
	},
	ZombieType.TANK: {
		"max_health": 300,
		"speed": 1.5,
		"damage": 30,
		"points": 200,
		"attack_cooldown": 1.5
	}
}

const ATTACK_RANGE := 1.5
const DETECTION_RANGE := 200.0
const GRAVITY := 20.0
const ANIM_BLEND_TIME := 0.2
const JUMP_COOLDOWN_TIME := 5.0
const TARGET_REEVALUATION_TIME := 2.0

var zombie_type : ZombieType = ZombieType.NORMAL
var current_state : State = State.IDLE
var current_health : int
var max_health : int
var speed : float
var damage : int
var points_value : int
var attack_cooldown_time : float

var lobby : Lobby
var target_player : PlayerServerReal = null
var can_attack := true
var current_anim := "idle"
var available_jump_points : Array[ZombieJumpPoint] = []
var jump_cooldown := 0.0
var target_reevaluation_timer := 0.0
var path_recalc_timer := 0.0
var path_recalc_time : float  # Randomized per zombie

# Stuck detection
var last_position := Vector3.ZERO
var stuck_timer := 0.0
const STUCK_TIMEOUT := 1.0  # If stuck for 3 seconds, unstuck
const STUCK_DISTANCE_THRESHOLD := 0.3  # Must move at least 0.5m
var active_jump_tween : Tween = null

@onready var navigation_agent : NavigationAgent3D = $NavigationAgent3D
@onready var attack_timer : Timer = $AttackTimer
@onready var animation_player : AnimationPlayer = $AnimationPlayer

func _ready() -> void:
	# Initialize based on zombie type
	var config = TYPE_CONFIG[zombie_type]
	max_health = config.max_health
	current_health = max_health
	speed = config.speed
	damage = config.damage
	points_value = config.points
	attack_cooldown_time = config.attack_cooldown

	# Randomize path recalc timing to prevent hivemind behavior
	path_recalc_time = randf_range(0.3, 1.2)

	# Configure CharacterBody3D for proper collision handling
	floor_max_angle = deg_to_rad(46)  # Can walk up 46 degree slopes
	floor_snap_length = 0.6  # Snap to floor from this distance
	wall_min_slide_angle = deg_to_rad(15)  # Slide along walls at shallow angles

	# Setup navigation agent properly
	if navigation_agent:
		navigation_agent.radius = 0.25  # Narrow enough for 0.6-wide doorways
		navigation_agent.height = 1.8
		navigation_agent.path_desired_distance = 0.5
		navigation_agent.target_desired_distance = 0.5  # Must be <= ATTACK_RANGE to prevent dead zone
		navigation_agent.path_max_distance = 15.0  # Give up if path is this far
		navigation_agent.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL
		navigation_agent.avoidance_enabled = true
		navigation_agent.max_speed = speed
		navigation_agent.neighbor_distance = 2.0  # Look for other zombies within 2m
		navigation_agent.max_neighbors = 5  # Consider up to 5 nearby zombies
		navigation_agent.time_horizon_agents = 0.5  # Predict collisions 0.5s ahead
		navigation_agent.velocity_computed.connect(_on_velocity_computed)

	# Setup attack timer
	attack_timer.wait_time = attack_cooldown_time
	attack_timer.timeout.connect(_on_attack_timer_timeout)

	# Find all jump points in the scene
	find_jump_points()

	# Wait for navigation to be ready
	await get_tree().physics_frame
	await get_tree().physics_frame

	# CRITICAL: Assign nav agent AFTER physics frames so it's fully initialized
	if navigation_agent and lobby and lobby.navigation_map_rid.is_valid():
		# Use the NavigationAgent3D property, NOT NavigationServer3D directly
		navigation_agent.set_navigation_map(lobby.navigation_map_rid)

		await get_tree().physics_frame

	# Start AI
	set_physics_process(true)

func _physics_process(delta: float) -> void:
	# Check if zombie is stuck (check distance over the full timeout period)
	stuck_timer += delta
	if stuck_timer >= STUCK_TIMEOUT:
		var moved_distance = global_position.distance_to(last_position)
		if moved_distance < STUCK_DISTANCE_THRESHOLD:
			unstuck()
		last_position = global_position
		stuck_timer = 0.0

	if current_state == State.DEAD:
		return

	# Update jump cooldown
	if jump_cooldown > 0:
		jump_cooldown -= delta

	# Update target reevaluation timer
	target_reevaluation_timer += delta
	if target_reevaluation_timer >= TARGET_REEVALUATION_TIME:
		target_reevaluation_timer = 0.0
		reevaluate_target()

	# Don't process physics during jump animation
	if current_state == State.JUMPING:
		return

	# Apply gravity
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	match current_state:
		State.IDLE:
			_process_idle()
		State.CHASE:
			_process_chase(delta)
		State.ATTACK:
			_process_attack(delta)

	# Move using Godot's built-in physics
	move_and_slide()

	# Manual step-up for small obstacles
	if current_state == State.CHASE and is_on_floor() and is_on_wall():
		_try_step_up()

	# Update animation based on movement
	if velocity.length() > 0.1:
		set_anim("run")
	else:
		set_anim("idle")

func _process_idle() -> void:
	target_player = find_nearest_player()
	if target_player:
		current_state = State.CHASE

func _process_chase(delta: float) -> void:
	# Check if target is still valid and alive
	if not is_instance_valid(target_player) or target_player.is_downed:
		target_player = null
		current_state = State.IDLE
		return

	var distance_to_target = global_position.distance_to(target_player.global_position)

	# Switch to attack if in range
	if distance_to_target <= ATTACK_RANGE:
		current_state = State.ATTACK
		velocity = Vector3.ZERO
		return

	# Check for jump points if not on cooldown
	if jump_cooldown <= 0:
		check_and_use_jump_points()

	# Recalculate path periodically
	path_recalc_timer += delta
	if path_recalc_timer >= path_recalc_time:
		path_recalc_timer = 0.0
		# NavigationAgent3D works in GLOBAL space
		navigation_agent.target_position = target_player.global_position

	# Check if target is reachable
	if not navigation_agent.is_target_reachable():
		# Target unreachable - try jump points or direct path
		if jump_cooldown <= 0 and not available_jump_points.is_empty():
			check_and_use_jump_points()
		else:
			# Fall back to direct movement with avoidance
			var direction = (target_player.global_position - global_position).normalized()
			direction.y = 0
			var desired_velocity = direction * speed
			navigation_agent.set_velocity(desired_velocity)
			if direction.length() > 0.1:
				look_at(global_position + direction, Vector3.UP)
		return

	# Simple direct navigation
	if not navigation_agent.is_navigation_finished():
		var next_position = navigation_agent.get_next_path_position()

		# Use only XZ from navigation, let physics handle Y
		var direction = (next_position - global_position).normalized()
		direction.y = 0

		# Set desired velocity for avoidance system
		var desired_velocity = direction * speed
		navigation_agent.set_velocity(desired_velocity)

		# Face the movement direction
		if direction.length() > 0.1:
			look_at(global_position + direction, Vector3.UP)
	else:
		# Reached navigation target
		velocity.x = 0
		velocity.z = 0

func _on_velocity_computed(safe_velocity: Vector3) -> void:
	# Apply collision-avoided velocity from navigation system
	velocity.x = safe_velocity.x
	velocity.z = safe_velocity.z

func _process_attack(delta: float) -> void:
	# Check if target is still valid and alive
	if not is_instance_valid(target_player) or target_player.is_downed:
		target_player = null
		current_state = State.IDLE
		return

	var distance_to_target = global_position.distance_to(target_player.global_position)

	# If target moved away, go back to chase
	if distance_to_target > ATTACK_RANGE * 1.5:
		current_state = State.CHASE
		return

	# Face the target
	var direction_to_target = (target_player.global_position - global_position)
	direction_to_target.y = 0
	if direction_to_target.length() > 0.1:
		look_at(global_position + direction_to_target, Vector3.UP)

	# Attack if cooldown is ready
	if can_attack:
		attack_player()
		can_attack = false
		attack_timer.start()

	velocity = Vector3.ZERO

func find_nearest_player() -> PlayerServerReal:
	if not lobby:
		print("ERROR: Zombie ", name, " has no lobby reference!")
		return null

	var nearest_player : PlayerServerReal = null
	var nearest_distance := DETECTION_RANGE

	if lobby.server_players.is_empty():
		return null

	for player_data in lobby.server_players.values():
		var player : PlayerServerReal = player_data.real
		if not is_instance_valid(player):
			continue

		# Skip downed or waiting players
		if player.is_downed or player.is_waiting_for_respawn:
			continue

		var distance = global_position.distance_to(player.global_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_player = player

	return nearest_player

func reevaluate_target() -> void:
	# Only reevaluate if we're chasing or attacking
	if current_state != State.CHASE and current_state != State.ATTACK:
		return

	var new_target := find_nearest_player()

	# If current target is downed or waiting, immediately switch
	if is_instance_valid(target_player) and (target_player.is_downed or target_player.is_waiting_for_respawn):
		target_player = new_target
		if target_player:
			current_state = State.CHASE
		else:
			current_state = State.IDLE
		return

	# Always switch to closer target (no threshold)
	if new_target and is_instance_valid(target_player):
		var current_distance := global_position.distance_to(target_player.global_position)
		var new_distance := global_position.distance_to(new_target.global_position)

		if new_distance < current_distance:
			target_player = new_target
			current_state = State.CHASE
	elif new_target:
		# No current target, switch to new one
		target_player = new_target
		current_state = State.CHASE

func attack_player() -> void:
	if not is_instance_valid(target_player):
		return

	# Deal damage to the target
	target_player.change_health(-damage, name.to_int())
	set_anim("attack")

func _on_attack_timer_timeout() -> void:
	can_attack = true

func change_health(amount : int, maybe_damage_dealer : int = 0) -> void:
	if current_state == State.DEAD:
		return

	current_health = clampi(current_health + amount, 0, max_health)

	# Award points for damage dealt (5 damage = 1 point)
	if amount < 0 and maybe_damage_dealer != 0 and lobby:
		var damage_dealt = mini(abs(amount), max_health)  # Cap to max health to prevent insta-kill exploits
		var points_earned = floori(damage_dealt / 5.0)
		if points_earned > 0:
			lobby.award_damage_points(maybe_damage_dealer, points_earned)

	if current_health <= 0 and current_state != State.DEAD:
		die(maybe_damage_dealer)

func die(killer_id : int) -> void:
	if current_state == State.DEAD:
		return

	current_state = State.DEAD
	set_physics_process(false)

	# Cancel any active jump tween
	if active_jump_tween:
		active_jump_tween.kill()
		active_jump_tween = null

	# Notify lobby of zombie death
	if lobby:
		lobby.zombie_died(name.to_int(), killer_id, zombie_type, position)  # Use LOCAL position, not global

func set_anim(anim_name : String) -> void:
	if current_anim == anim_name:
		return
	if not animation_player:
		return
	if not animation_player.has_animation(anim_name):
		return
	current_anim = anim_name
	animation_player.play(anim_name, ANIM_BLEND_TIME)

func find_jump_points() -> void:
	# Find all ZombieJumpPoint nodes in the scene
	available_jump_points.clear()
	if not lobby:
		return

	var map_node = lobby.get_node_or_null("Map")
	if not map_node:
		return

	# Search recursively for jump points
	_recursive_find_jump_points(map_node)

func _recursive_find_jump_points(node: Node) -> void:
	if node is ZombieJumpPoint:
		available_jump_points.append(node)

	for child in node.get_children():
		_recursive_find_jump_points(child)

func check_and_use_jump_points() -> void:
	if not target_player or available_jump_points.is_empty():
		return

	# Find best jump point (closest to trigger)
	var best_jump_point : ZombieJumpPoint = null
	var best_distance_to_jump := INF

	for jump_point in available_jump_points:
		if not is_instance_valid(jump_point):
			continue

		if not jump_point.is_within_trigger_range(global_position):
			continue

		# Pick closest jump point if multiple in range
		var dist_to_jump := global_position.distance_to(jump_point.global_position)
		if dist_to_jump < best_distance_to_jump:
			best_distance_to_jump = dist_to_jump
			best_jump_point = jump_point

	# Execute jump if any valid point found (trust level design)
	if best_jump_point:
		var dest = best_jump_point.get_destination_position(global_position)
		execute_jump(best_jump_point)

func execute_jump(jump_point: ZombieJumpPoint) -> void:
	# Cancel any existing jump tween
	if active_jump_tween:
		var old_tween = active_jump_tween
		active_jump_tween = null  # Clear reference BEFORE killing so callback knows it's replaced
		old_tween.kill()
		print("  Killed existing tween")

	# Enter jumping state
	var previous_state := current_state
	current_state = State.JUMPING
	velocity = Vector3.ZERO
	jump_cooldown = JUMP_COOLDOWN_TIME

	# Disable avoidance during jump to prevent interference
	if navigation_agent:
		navigation_agent.avoidance_enabled = false

	var start_pos := global_position
	var end_pos := jump_point.get_destination_position(global_position)
	var duration := jump_point.get_jump_duration()

	# Create tween
	active_jump_tween = create_tween()
	active_jump_tween.set_ease(Tween.EASE_IN_OUT)

	if jump_point.is_linear_jump():
		# LINEAR: Simple linear interpolation (walking up stairs)
		active_jump_tween.set_trans(Tween.TRANS_LINEAR)
		active_jump_tween.tween_property(self, "global_position", end_pos, duration)
	else:
		# JUMP: Arc motion with vertical boost
		active_jump_tween.set_trans(Tween.TRANS_QUAD)

		# Calculate arc height (based on distance)
		var horizontal_dist := Vector2(end_pos.x - start_pos.x, end_pos.z - start_pos.z).length()
		var arc_height : float = max(2.0, horizontal_dist * 0.5)  # At least 2m high, scales with distance

		# Midpoint with height boost
		var mid_pos := start_pos.lerp(end_pos, 0.5)
		mid_pos.y += arc_height

		# Tween in two parts: start -> peak -> end
		active_jump_tween.tween_property(self, "global_position", mid_pos, duration * 0.5)
		active_jump_tween.tween_property(self, "global_position", end_pos, duration * 0.5)

	# When jump completes, return to previous state
	var this_tween = active_jump_tween  # Capture reference
	active_jump_tween.finished.connect(func():
		# Only reset if THIS tween is still active (not killed by new jump)
		if active_jump_tween == this_tween:
			current_state = previous_state
			active_jump_tween = null
			# Re-enable avoidance after jump
			if navigation_agent:
				navigation_agent.avoidance_enabled = true
		else:
			print("  Old tween finished but was replaced, ignoring")
	)

func _try_step_up() -> void:
	# Aggressive step-up - try multiple heights
	var step_heights = [0.2, 0.4, 0.6, 0.8]

	for step_height in step_heights:
		var old_pos = global_position
		global_position.y += step_height

		# Test if we can move forward at this height
		var test_velocity = velocity
		test_velocity.y = 0

		# Small forward test
		global_position += test_velocity.normalized() * 0.1

		# Check if we're still colliding
		var collision_test = move_and_collide(Vector3.ZERO, true)

		if not collision_test:
			# Success! We cleared the obstacle
			return

		# Failed, restore position and try next height
		global_position = old_pos

func unstuck() -> void:
	# Try multiple unstuck strategies
	
	# Strategy 1: Clear navigation and force new target
	if navigation_agent:
		navigation_agent.target_position = global_position  # Reset nav
	
	target_player = null  # Force new target selection
	
	# Strategy 2: Teleport slightly up and forward
	var forward_dir = -global_transform.basis.z
	var unstuck_pos = global_position + Vector3(0, 0.5, 0) + (forward_dir * 1.0)
	
	# Make sure unstuck position is valid
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(global_position, unstuck_pos)
	query.exclude = [self]
	var result = space_state.intersect_ray(query)
	
	if not result:
		# Path is clear, teleport
		global_position = unstuck_pos
	else:
		# Try moving up only
		global_position += Vector3(0, 1.0, 0)
	
	# Strategy 3: Reset state
	current_state = State.IDLE
	velocity = Vector3.ZERO

	# Force immediate path recalculation
	path_recalc_timer = path_recalc_time
