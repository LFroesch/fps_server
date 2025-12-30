extends Node

enum GameMode {
	PVP,
	ZOMBIES
}

const MAPS = {
	0: {
		"name": "Killroom",
		"client_path": "res://maps/map_killroom.tscn",
		"server_path": "res://maps/server_killroom.tscn"
	},
	1: {
		"name": "Farm",
		"client_path": "res://maps/map_farm.tscn",
		"server_path": "res://maps/server_farm.tscn"
	},
	2: {
		"name": "Shipment",
		"client_path": "res://maps/map_shipment.tscn",
		"server_path": "res://maps/server_shipment.tscn",
	},
	3: {
		"name": "Desert",
		"client_path": "res://maps/map_desert.tscn",
		"server_path": "res://maps/server_desert.tscn",
	},
	4: {
		"name": "Office",
		"client_path": "res://maps/map_office.tscn",
		"server_path": "res://maps/server_office.tscn",
		"screenshot_path": "res://asset_packs/tutorial-fps-assets/textures/fill_bg.jpg"
	}
}

const ANY_MAP := -1

func get_map_data(map_id: int) -> Dictionary:
	if map_id == ANY_MAP:
		return {}
	return MAPS.get(map_id, {})

func get_map_count() -> int:
	return MAPS.size()

func get_all_map_ids() -> Array[int]:
	var ids: Array[int] = []
	for id in MAPS.keys():
		ids.append(id)
	return ids

func get_map_name(map_id: int) -> String:
	if map_id == ANY_MAP:
		return "Any Map"
	var data = get_map_data(map_id)
	return data.get("name", "Unknown")

func get_client_path(map_id: int) -> String:
	var data = get_map_data(map_id)
	return data.get("client_path", "")

func get_server_path(map_id: int) -> String:
	var data = get_map_data(map_id)
	return data.get("server_path", "")
