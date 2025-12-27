@tool
extends EditorScript

## HOW TO USE:
## 1. Open this script in Godot editor
## 2. Make sure your map scene is open and saved
## 3. Click File > Run (or press Ctrl+Shift+X)
## 4. This will add NavigationRegion3D to your map and bake it
## 5. Save the map scene after running

func _run() -> void:
	var editor_interface := get_editor_interface()
	var edited_scene_root := editor_interface.get_edited_scene_root()

	if not edited_scene_root:
		print("ERROR: No scene is currently open. Open your map scene first!")
		return

	print("Setting up navigation for: ", edited_scene_root.name)

	# Check if NavigationRegion3D already exists
	var existing_nav := edited_scene_root.find_child("NavigationRegion3D", false, false)
	if existing_nav:
		print("NavigationRegion3D already exists! Skipping...")
		return

	# Create NavigationRegion3D
	var nav_region := NavigationRegion3D.new()
	nav_region.name = "NavigationRegion3D"

	# Create NavigationMesh with good settings
	var nav_mesh := NavigationMesh.new()

	# Configure navmesh for zombie pathfinding
	nav_mesh.agent_height = 1.8
	nav_mesh.agent_radius = 0.5
	nav_mesh.agent_max_climb = 0.5  # Can step up 0.5m
	nav_mesh.agent_max_slope = 45.0  # Can walk up 45 degree slopes
	nav_mesh.cell_size = 0.25
	nav_mesh.cell_height = 0.2
	nav_mesh.region_min_size = 2.0
	nav_mesh.region_merge_size = 20.0
	nav_mesh.edge_max_length = 12.0
	nav_mesh.edge_max_error = 1.3

	# Set the filter settings to bake from geometry
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN

	nav_region.navigation_mesh = nav_mesh

	# Add to scene
	edited_scene_root.add_child(nav_region)
	nav_region.owner = edited_scene_root

	print("NavigationRegion3D created!")
	print("Now baking navigation mesh...")

	# Bake the mesh
	nav_region.bake_navigation_mesh()

	print("✅ Navigation setup complete!")
	print("IMPORTANT: Save your scene now! (Ctrl+S)")
	print("The navigation mesh has been baked and is ready for zombies.")
