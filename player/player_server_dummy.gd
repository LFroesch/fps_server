extends CharacterBody3D
class_name ServerPlayerDummy

const NECK_ROT_SCALAR : PackedFloat32Array = [0.2, -0.2]
const ABDOMEN_ROT_SCALAR : PackedFloat32Array = [0.17, 0]
const TORSO_ROT_SCALAR : PackedFloat32Array = [0.19, -0.15]
const ARM_X_ROT_SCALAR : PackedFloat32Array = [0.19, 0]
const ARM_Y_ROT_SCALAR : PackedFloat32Array = [-0.39, -1.25]

@onready var skeleton: Skeleton3D = %Skeleton3D
@onready var bone_neck := skeleton.find_bone("Neck")
@onready var bone_torso := skeleton.find_bone("Torso")
@onready var bone_abdomen := skeleton.find_bone("Abdomen")
@onready var bone_upper_arm_r := skeleton.find_bone("UpperArm.R")

@onready var animation_player: AnimationPlayer = %AnimationPlayer
@onready var head: Node3D = $Head

var hitboxes : Array[RID] = []
var id : int

func _ready() -> void:
	for bone in skeleton.get_children():
		for maybe_hitbox in bone.get_children():
			if maybe_hitbox is HitBox:
				hitboxes.append(maybe_hitbox.get_rid())
				maybe_hitbox.player = self

func update_body_geometry(player_data : Dictionary) -> void:
	position = player_data.pos
	rotation.y = player_data.rot_y
	head.rotation.x = player_data.rot_x

	if player_data.has("anim_pos"):
		set_anim(player_data.anim, player_data.anim_pos)
	set_rot_x_visuals(player_data.rot_x)
	
func set_anim(anim_name : String, anim_pos : float) -> void:
	animation_player.play(anim_name)
	animation_player.seek(anim_pos, true)
	animation_player.pause()

func set_rot_x_visuals(rot_x : float) -> void:
	var rot_weight := remap(rot_x, -PI/2.0, PI/2.0, 0, 0.7)
	# neck
	var q_neck := skeleton.get_bone_pose_rotation(bone_neck)
	q_neck.x = lerp_angle(NECK_ROT_SCALAR[0], NECK_ROT_SCALAR[1], rot_weight)
	skeleton.set_bone_pose_rotation(bone_neck, q_neck)
	# torso
	var q_torso := skeleton.get_bone_pose_rotation(bone_torso)
	q_torso.x = lerp_angle(TORSO_ROT_SCALAR[0], TORSO_ROT_SCALAR[1], rot_weight)
	skeleton.set_bone_pose_rotation(bone_torso, q_torso)
	# abdomen
	var q_abdomen := skeleton.get_bone_pose_rotation(bone_abdomen)
	q_abdomen.x = lerp_angle(ABDOMEN_ROT_SCALAR[0], ABDOMEN_ROT_SCALAR[1], rot_weight)
	skeleton.set_bone_pose_rotation(bone_abdomen, q_abdomen)
	# upper arm r
	var q_upper_arm_r := skeleton.get_bone_pose_rotation(bone_upper_arm_r)
	q_upper_arm_r.x = lerp_angle(ARM_X_ROT_SCALAR[0], ARM_X_ROT_SCALAR[1], rot_weight)
	q_upper_arm_r.y = lerp_angle(ARM_Y_ROT_SCALAR[0], ARM_Y_ROT_SCALAR[1], rot_weight)
	skeleton.set_bone_pose_rotation(bone_upper_arm_r, q_upper_arm_r)
