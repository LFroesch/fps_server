extends Node3D
# Server-side weapon wallbuy - just marks the position, no interaction needed
# All logic is handled in server/lobby.gd

@export var weapon_id: int = 1
@export var weapon_cost: int = 1000
@export var ammo_cost: int = 500

func _ready() -> void:
	# Server doesn't need visuals or collision
	# This is just a marker node for map organization
	pass
