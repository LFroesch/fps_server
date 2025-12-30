extends Node3D
class_name ZombieJumpPoint

## Manual jump point for zombies to navigate vertical terrain
## Place this at the START position, set the destination marker to END position

enum JumpType {
	LINEAR,  ## Walk/climb in straight line (for stairs, ramps)
	JUMP     ## Arc jump (for ledges, containers)
}

@export var destination : Marker3D  ## Where the zombie will land after jumping
@export var trigger_radius := 2.0  ## How close zombie needs to be to trigger jump
@export var jump_type := JumpType.LINEAR  ## How the zombie moves: LINEAR (walk) or JUMP (arc)
@export var min_duration := 1.0  ## Minimum time for jump animation (seconds)
@export var max_duration := 2.0  ## Maximum time for jump animation (seconds)
@export var one_way := false  ## If true, zombies can only jump from this point to destination (not reverse)
@export var enabled := true  ## Toggle this jump point on/off

func _ready() -> void:
	pass

func is_within_trigger_range(zombie_position : Vector3) -> bool:
	if not enabled:
		return false
	if not destination:
		return false
	var dist := global_position.distance_to(zombie_position)
	return dist <= trigger_radius

func get_destination_position() -> Vector3:
	if destination:
		return destination.global_position
	return global_position

func get_jump_duration() -> float:
	return randf_range(min_duration, max_duration)

func is_linear_jump() -> bool:
	return jump_type == JumpType.LINEAR

func is_arc_jump() -> bool:
	return jump_type == JumpType.JUMP
