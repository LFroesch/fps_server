class_name WeaponConfig

const WEAPON_DATA := {
	#pistol - reliable starter weapon
	0 : {"name" : "Pistol", "damage" : 30, "accuracy" : 0.95, "projectiles" : 1, "mag_size" : 12, "reserve_ammo" : 60, "reload_time" : 1.5, "is_automatic" : false, "shot_cooldown" : 0.3, "max_penetrations" : 1, "penetration_damage_falloff" : 0.8},
	#smg - close range spray
	1 : {"name" : "SMG", "damage" : 18, "accuracy" : 0.65, "projectiles" : 1, "mag_size" : 30, "reserve_ammo" : 120, "reload_time" : 2.0, "is_automatic" : true, "shot_cooldown" : 0.1, "max_penetrations" : 1, "penetration_damage_falloff" : 0.7},
	#shotgun - close quarters burst
	2 : {"name" : "Shotgun", "damage" : 15, "accuracy" : 0.4, "projectiles" : 6, "mag_size" : 8, "reserve_ammo" : 32, "reload_time" : 2.5, "is_automatic" : false, "shot_cooldown" : 0.7, "max_penetrations" : 0, "penetration_damage_falloff" : 1.0},
	#sniper - long range precision (one shot headshot)
	3 : {"name" : "Sniper", "damage" : 100, "accuracy" : 0.99, "projectiles" : 1, "mag_size" : 5, "reserve_ammo" : 25, "reload_time" : 3.0, "is_automatic" : false, "shot_cooldown" : 1.2, "max_penetrations" : 5, "penetration_damage_falloff" : 0.3},
	#assault rifle - balanced all-rounder
	4 : {"name" : "Assault Rifle", "damage" : 25, "accuracy" : 0.80, "projectiles" : 1, "mag_size" : 30, "reserve_ammo" : 150, "reload_time" : 2.0, "is_automatic" : true, "shot_cooldown" : 0.12, "max_penetrations" : 2, "penetration_damage_falloff" : 0.5},
	#lmg - suppressive fire, high volume low accuracy
	5 : {"name" : "LMG", "damage" : 16, "accuracy" : 0.50, "projectiles" : 1, "mag_size" : 100, "reserve_ammo" : 200, "reload_time" : 3.5, "is_automatic" : true, "shot_cooldown" : 0.08, "max_penetrations" : 3, "penetration_damage_falloff" : 0.4}
}

static func get_weapon_data(weapon_id) -> Dictionary:
	return WEAPON_DATA.get(weapon_id)
