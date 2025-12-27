@tool
extends EditorScript

# Run this script in the Godot editor via File > Run to auto-setup navigation for maps
# This creates NavigationRegion3D nodes and bakes meshes for zombie pathfinding

const MAPS_TO_SETUP = [
	"res://maps/server_desert.tscn",
	"res://maps/server_killroom.tscn",
	"res://maps/server_farm.tscn"
]

func _run():
	print("===== Navigation Setup Script =====")

	for map_path in MAPS_TO_SETUP:
		print("\n--- Processing: ", map_path)
		setup_map_navigation(map_path)

	print("\n===== Navigation Setup Complete! =====")
	print("You can now test zombie mode.")

func setup_map_navigation(map_path: String):
	# Load the map scene
	var map_scene = load(map_path)
	if not map_scene:
		print("ERROR: Could not load ", map_path)
		return

	var map = map_scene.instantiate()
	if not map:
		print("ERROR: Could not instantiate ", map_path)
		return

	# Check if NavigationRegion3D already exists
	var existing_nav = map.find_child("NavigationRegion3D", false, false)
	if existing_nav:
		print("  ✓ NavigationRegion3D already exists, removing old one...")
		existing_nav.queue_free()

	# Create new NavigationRegion3D
	var nav_region = NavigationRegion3D.new()
	nav_region.name = "NavigationRegion3D"
	map.add_child(nav_region)
	nav_region.owner = map

	# Create and configure NavigationMesh
	var nav_mesh = NavigationMesh.new()

	# Configure nav mesh settings for zombie pathfinding
	nav_mesh.agent_height = 1.8
	nav_mesh.agent_radius = 0.45
	nav_mesh.agent_max_climb = 0.5
	nav_mesh.agent_max_slope = 45.0
	nav_mesh.region_min_size = 2.0
	nav_mesh.region_merge_size = 20.0
	nav_mesh.cell_size = 0.2
	nav_mesh.cell_height = 0.15
	nav_mesh.border_size = 0.0

	# Parse geometry from all physics bodies
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_collision_mask = 0xFFFFFFFF  # All layers

	nav_region.navigation_mesh = nav_mesh

	print("  ✓ NavigationRegion3D created with mesh settings")

	# Create simple fallback mesh (flat ground plane)
	# This ensures zombies can move even if parsing fails
	create_simple_navmesh(nav_mesh, map)

	# Save the modified scene
	var packed_scene = PackedScene.new()
	var result = packed_scene.pack(map)
	if result == OK:
		var save_result = ResourceSaver.save(packed_scene, map_path)
		if save_result == OK:
			print("  ✓ Saved map with navigation mesh: ", map_path)
		else:
			print("  ERROR: Could not save map: ", save_result)
	else:
		print("  ERROR: Could not pack scene: ", result)

	map.free()

func create_simple_navmesh(nav_mesh: NavigationMesh, map: Node3D):
	# Create a simple rectangular navigation mesh as fallback
	# This covers a 60x60 unit area centered at origin

	var vertices = PackedVector3Array([
		Vector3(-30, 0, -30),
		Vector3(30, 0, -30),
		Vector3(30, 0, 30),
		Vector3(-30, 0, 30)
	])

	# Create polygon (triangle fan from first vertex)
	var polygon = PackedInt32Array([0, 1, 2, 0, 2, 3])

	# Add vertices and polygons to nav mesh
	nav_mesh.clear_polygons()
	nav_mesh.vertices = vertices

	# Create two triangles for the quad
	var poly1 = PackedInt32Array([0, 1, 2])
	var poly2 = PackedInt32Array([0, 2, 3])

	nav_mesh.add_polygon(poly1)
	nav_mesh.add_polygon(poly2)

	print("  ✓ Created simple navigation mesh (60x60 ground plane)")
