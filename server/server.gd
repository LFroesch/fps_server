extends Node

const PORT := 7777
const MAX_CLIENTS := 64
const MAX_LOBBIES := 4
const DISTANCE_BETWEEN_LOBBIES := 50

var peer := ENetMultiplayerPeer.new()
var lobbies : Array[Lobby] = []
var idle_clients : Array[int] = []
var lobby_spots : Array[Lobby] = []

func _get_time_string() -> String:
	var datetime = Time.get_datetime_dict_from_system()
	return "[%02d:%02d:%02d] -" % [datetime.hour, datetime.minute, datetime.second]

func _ready() -> void:
	var error := peer.create_server(PORT, MAX_CLIENTS)

	if error != OK:
		return
	
	multiplayer.multiplayer_peer = peer
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)
	
	lobby_spots.resize(MAX_LOBBIES)

func _on_peer_connected(id : int) -> void:
	idle_clients.append(id)

func _on_peer_disconnected(id : int) -> void:
	remove_client_from_lobby(id)
	idle_clients.erase(id)

func remove_client_from_lobby(client_id : int) -> void:
	var maybe_lobby := get_lobby_from_client_id(client_id)
	
	if maybe_lobby:
		maybe_lobby.remove_client(client_id)
		if is_instance_valid(maybe_lobby):
			lobby_clients_updated(maybe_lobby)

func update_lobby_spots() -> void:
	# Inserting new lobbies
	for lobby in lobbies:
		if lobby in lobby_spots:
			continue
		for i in lobby_spots.size():
			if lobby_spots[i] == null:
				lobby_spots[i] = lobby
				var old_y = lobby.global_position.y
				lobby.global_position.y = DISTANCE_BETWEEN_LOBBIES * i
				print("[SERVER] Lobby %s assigned to slot %d (Y %.1f -> %.1f), zombies: %d" % [lobby.lobby_id, i, old_y, lobby.global_position.y, lobby.zombies.size()])
				break
	# Deleting unused lobby spots
	for i in lobby_spots.size():
		if lobby_spots[i] != null and not lobby_spots[i] in lobbies:
			print("[SERVER] Clearing lobby spot %d" % i)
			lobby_spots[i] = null

func get_lobby_from_client_id(id : int) -> Lobby:
	for lobby in lobbies:
		if lobby.client_data.keys().has(id):
			return lobby
	return null

@rpc("any_peer", "call_remote", "reliable")
func c_try_connect_client_to_lobby(player_name : String, map_id : int, game_mode : int = MapRegistry.GameMode.PVP) -> void:
	var client_id := multiplayer.get_remote_sender_id()
	var maybe_lobby := get_non_full_lobby(map_id, game_mode)

	if maybe_lobby:
		# Double-check: Verify lobby is still valid before adding client
		if maybe_lobby.status != Lobby.IDLE or maybe_lobby.being_deleted:
			s_client_cant_connect_to_lobby.rpc_id(client_id)
			return

		maybe_lobby.add_client(client_id, player_name)

		# Double-check: Verify lobby still exists after adding client
		if not is_instance_valid(maybe_lobby) or maybe_lobby.being_deleted:
			# Lobby was deleted during add, rollback
			idle_clients.erase(client_id)
			s_client_cant_connect_to_lobby.rpc_id(client_id)
			return

		idle_clients.erase(client_id)
		lobby_clients_updated(maybe_lobby)

		if maybe_lobby.client_data.keys().size() >= maybe_lobby.max_players:
			lock_lobby(maybe_lobby)

		return

	s_client_cant_connect_to_lobby.rpc_id(client_id)

func lock_lobby(lobby : Lobby) -> void:

	# Verify we still have enough connected players before locking
	var connected_count := 0
	for client_id in lobby.client_data.keys():
		var data = lobby.client_data[client_id]
		var actually_connected = client_id in multiplayer.get_peers()
		# Check both the data flag AND if peer is actually connected
		if data.connected and actually_connected:
			connected_count += 1

	# Determine minimum required players based on game mode
	var min_required := 1
	if lobby.game_mode == MapRegistry.GameMode.PVP:
		min_required = 2


	if connected_count < min_required:
		# Not enough players, revert to IDLE or delete if empty
		if connected_count == 0:
			lobby.maybe_delete_empty_lobby()
		else:
			lobby.status = Lobby.IDLE
		return

	lobby.status = Lobby.LOCKED
	create_lobby_on_clients(lobby)

func create_lobby_on_clients(lobby : Lobby) -> void:
	for lobby_client_id in lobby.client_data.keys():
		s_create_lobby_on_clients.rpc_id(lobby_client_id, lobby.name)

@rpc("authority", "call_remote", "reliable")
func s_create_lobby_on_clients(lobby_name: String) -> void:
	pass

func get_non_full_lobby(map_id : int, game_mode : int, desired_size : int = -1) -> Lobby:
	# If "Any Map" (-1), try to backfill any non-full lobby
	if map_id == MapRegistry.ANY_MAP:
		for lobby in lobbies:
			if lobby.status != Lobby.IDLE:
				continue
			if lobby.being_deleted:
				continue
			if lobby.game_mode != game_mode:
				continue
			if desired_size > 0 and lobby.max_players != desired_size:
				continue
			if lobby.client_data.keys().size() < lobby.max_players:
				return lobby
	else:
		# Look for lobbies matching the specific map and game mode
		for lobby in lobbies:
			if lobby.status != Lobby.IDLE:
				continue
			if lobby.being_deleted:
				continue
			if lobby.map_id != map_id:
				continue
			if lobby.game_mode != game_mode:
				continue
			if desired_size > 0 and lobby.max_players != desired_size:
				continue
			if lobby.client_data.keys().size() < lobby.max_players:
				return lobby

	# Create new lobby if we have space
	if lobbies.size() < MAX_LOBBIES:
		var new_lobby := Lobby.new()
		lobbies.append(new_lobby)
		new_lobby.lobby_id = Lobby.generate_lobby_code()
		new_lobby.name = new_lobby.lobby_id
		new_lobby.game_mode = game_mode
		new_lobby.max_players = desired_size if desired_size > 0 else 4
		new_lobby.is_public = true
		# Randomly select a map if "Any" was chosen
		if map_id == MapRegistry.ANY_MAP:
			var available_maps := MapRegistry.get_all_map_ids()
			new_lobby.map_id = available_maps.pick_random()
		else:
			new_lobby.map_id = map_id
		add_child(new_lobby)
		update_lobby_spots()
		var mode_name := "PvP" if game_mode == MapRegistry.GameMode.PVP else "Zombies"
		print("%s Created new lobby (%s) for Map: %s (%s mode, %d players)" % [_get_time_string(), new_lobby.lobby_id, MapRegistry.get_map_name(new_lobby.map_id), mode_name, new_lobby.max_players])
		return new_lobby

	print("%s Lobbies Full" % _get_time_string())
	return null

func lobby_clients_updated(lobby : Lobby) -> void:
	# Check if lobby is still valid before sending updates
	if not is_instance_valid(lobby) or lobby.being_deleted:
		return

	for client_id in lobby.client_data.keys():
		s_lobby_clients_updated.rpc_id(client_id, lobby.client_data.keys().size(), lobby.max_players)

@rpc("authority", "call_remote", "reliable")
func s_lobby_clients_updated(connected_clients : int, max_clients : int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_client_cant_connect_to_lobby() -> void:
	pass

@rpc("any_peer", "call_remote", "reliable")
func c_cancel_quickplay_search() -> void:
	var client_id := multiplayer.get_remote_sender_id()
	remove_client_from_lobby(client_id)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func c_get_server_clock_time(client_clock_time : int) -> void:
	s_return_server_clock_time.rpc_id(
		multiplayer.get_remote_sender_id(),
		floori(Time.get_unix_time_from_system() * 1000),
		client_clock_time
	)
	
@rpc("authority", "call_remote", "unreliable_ordered")
func s_return_server_clock_time(server_clock_time : int, old_client_clock_time : int) -> void:
	pass

func delete_lobby(lobby : Lobby) -> void:
	print("%s Deleted lobby for Map: %s" % [_get_time_string(), MapRegistry.get_map_name(lobby.map_id)])
	lobbies.erase(lobby)
	lobby.queue_free()
	update_lobby_spots()

# New matchmaking system RPCs
@rpc("any_peer", "call_remote", "reliable")
func c_create_lobby(player_name: String, max_players: int, map_id: int, game_mode: int, is_public: bool) -> void:
	var client_id := multiplayer.get_remote_sender_id()

	# Validate max_players
	if game_mode == MapRegistry.GameMode.PVP and (max_players != 2 and max_players != 4):
		s_client_cant_connect_to_lobby.rpc_id(client_id)
		return
	if max_players < 1 or max_players > 4:
		s_client_cant_connect_to_lobby.rpc_id(client_id)
		return

	if lobbies.size() >= MAX_LOBBIES:
		s_client_cant_connect_to_lobby.rpc_id(client_id)
		return

	# Create new lobby
	var new_lobby := Lobby.new()
	lobbies.append(new_lobby)
	new_lobby.lobby_id = Lobby.generate_lobby_code()
	new_lobby.name = new_lobby.lobby_id
	new_lobby.host_id = client_id
	new_lobby.max_players = max_players
	new_lobby.map_id = map_id
	new_lobby.game_mode = game_mode
	new_lobby.is_public = is_public
	add_child(new_lobby)
	update_lobby_spots()

	print("%s [SERVER] Created lobby %s. Total lobbies: %d" % [_get_time_string(), new_lobby.lobby_id, lobbies.size()])
	for i in lobbies.size():
		var lob = lobbies[i]
		print("  Lobby %d: %s (players: %d/%d, zombies: %d)" % [i, lob.lobby_id, lob.client_data.size(), lob.max_players, lob.zombies.size()])

	# Add creator as first player
	new_lobby.add_client(client_id, player_name)
	idle_clients.erase(client_id)

	print("%s Client (%d) created lobby (%s): %d players, %s mode, Map: %s" % [_get_time_string(), client_id, new_lobby.lobby_id, max_players, "PvP" if game_mode == MapRegistry.GameMode.PVP else "Zombies", MapRegistry.get_map_name(map_id)])

	# Send lobby data to creator
	s_joined_lobby.rpc_id(client_id, new_lobby.lobby_id, get_lobby_data(new_lobby))

@rpc("any_peer", "call_remote", "reliable")
func c_join_lobby(lobby_id: String, player_name: String) -> void:
	var client_id := multiplayer.get_remote_sender_id()

	# Find lobby by ID
	var target_lobby: Lobby = null
	for lobby in lobbies:
		if lobby.lobby_id == lobby_id:
			target_lobby = lobby
			break

	if not target_lobby or target_lobby.status != Lobby.IDLE or target_lobby.being_deleted:
		s_client_cant_connect_to_lobby.rpc_id(client_id)
		return

	if target_lobby.client_data.keys().size() >= target_lobby.max_players:
		s_client_cant_connect_to_lobby.rpc_id(client_id)
		return

	target_lobby.add_client(client_id, player_name)
	idle_clients.erase(client_id)

	print("%s Client (%d) joined lobby (%s)" % [_get_time_string(), client_id, lobby_id])

	var lobby_data = get_lobby_data(target_lobby)

	# Send s_joined_lobby to the NEW player (transitions to waiting room)
	s_joined_lobby.rpc_id(client_id, lobby_id, lobby_data)

	# Send s_lobby_updated to EXISTING players (updates their waiting room)
	for existing_client_id in target_lobby.client_data.keys():
		if existing_client_id != client_id:  # Don't send update to the new joiner
			s_lobby_updated.rpc_id(existing_client_id, lobby_id, lobby_data)

@rpc("any_peer", "call_remote", "reliable")
func c_quick_play(player_name: String, game_mode: int, map_pref: int, size_pref: int) -> void:
	var client_id := multiplayer.get_remote_sender_id()
	var maybe_lobby := get_non_full_lobby(map_pref, game_mode, size_pref)

	if maybe_lobby:
		maybe_lobby.add_client(client_id, player_name)
		idle_clients.erase(client_id)

		print("%s Client (%d) quick-joined lobby (%s)" % [_get_time_string(), client_id, maybe_lobby.lobby_id])

		var lobby_data = get_lobby_data(maybe_lobby)

		# Send s_joined_lobby to the NEW player (transitions to waiting room)
		s_joined_lobby.rpc_id(client_id, maybe_lobby.lobby_id, lobby_data)

		# Send s_lobby_updated to EXISTING players (updates their waiting room)
		for existing_client_id in maybe_lobby.client_data.keys():
			if existing_client_id != client_id:  # Don't send update to the new joiner
				s_lobby_updated.rpc_id(existing_client_id, maybe_lobby.lobby_id, lobby_data)
	else:
		s_client_cant_connect_to_lobby.rpc_id(client_id)

@rpc("any_peer", "call_remote", "reliable")
func c_start_lobby() -> void:
	var client_id := multiplayer.get_remote_sender_id()
	var lobby := get_lobby_from_client_id(client_id)

	if not lobby or lobby.host_id != client_id:
		return

	# Validate player count
	var player_count = lobby.client_data.keys().size()
	if lobby.game_mode == MapRegistry.GameMode.PVP and player_count < 2:
		return
	if player_count < 1:
		return

	lock_lobby(lobby)

@rpc("any_peer", "call_remote", "reliable")
func c_kick_player(target_client_id: int) -> void:
	var client_id := multiplayer.get_remote_sender_id()
	var lobby := get_lobby_from_client_id(client_id)

	if not lobby or lobby.host_id != client_id:
		return

	if not lobby.client_data.has(target_client_id):
		return

	print("%s Host (%d) kicked player (%d) from lobby (%s)" % [_get_time_string(), client_id, target_client_id, lobby.lobby_id])
	s_kicked_from_lobby.rpc_id(target_client_id, "You were removed from the lobby")
	remove_client_from_lobby(target_client_id)

@rpc("authority", "call_remote", "reliable")
func s_joined_lobby(lobby_id: String, lobby_data: Dictionary) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_lobby_updated(lobby_id: String, lobby_data: Dictionary) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func s_kicked_from_lobby(reason: String) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable")
func c_request_lobby_list(game_mode: int) -> void:
	var client_id := multiplayer.get_remote_sender_id()
	var lobby_list: Array[Dictionary] = []

	for lobby in lobbies:
		# Only show public lobbies that are idle (not started/locked) and match game mode
		if lobby.is_public and lobby.status == Lobby.IDLE and lobby.game_mode == game_mode and not lobby.being_deleted:
			var player_count = lobby.client_data.keys().size()
			# Only show lobbies that aren't full
			if player_count < lobby.max_players:
				lobby_list.append({
					"lobby_id": lobby.lobby_id,
					"map_id": lobby.map_id,
					"map_name": MapRegistry.get_map_name(lobby.map_id),
					"game_mode": lobby.game_mode,
					"current_players": player_count,
					"max_players": lobby.max_players,
					"host_id": lobby.host_id,
					"host_name": lobby.client_data.get(lobby.host_id, {}).get("display_name", "Unknown")
				})

	s_lobby_list_updated.rpc_id(client_id, lobby_list)

@rpc("authority", "call_remote", "reliable")
func s_lobby_list_updated(lobbies_list: Array[Dictionary]) -> void:
	pass

func get_lobby_data(lobby: Lobby) -> Dictionary:
	return {
		"lobby_id": lobby.lobby_id,
		"host_id": lobby.host_id,
		"max_players": lobby.max_players,
		"current_players": lobby.client_data.keys().size(),
		"map_id": lobby.map_id,
		"game_mode": lobby.game_mode,
		"is_public": lobby.is_public,
		"player_names": lobby.client_data
	}
