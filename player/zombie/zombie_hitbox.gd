extends Area3D
class_name ZombieHitbox

@export var damage_multiplier := 1.0

var zombie : ZombieServer

func _ready() -> void:
	zombie = get_parent() as ZombieServer
