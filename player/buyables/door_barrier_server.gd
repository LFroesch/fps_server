extends StaticBody3D
# Server-side door barrier - blocks zombies until opened

@export var door_id: String = "door_1"
@export var cost: int = 750

var is_open: bool = false

func _ready() -> void:
	# Server needs collision to block zombies
	# But no visuals needed
	add_to_group("door_barriers")

func open_door() -> void:
	if is_open:
		return

	is_open = true

	# Disable collision so zombies can pass
	collision_layer = 0
	collision_mask = 0

	# Disable all child collision shapes
	for child in get_children():
		if child is CollisionShape3D:
			child.disabled = true

	print("Server: Door %s opened and collision disabled" % door_id)
