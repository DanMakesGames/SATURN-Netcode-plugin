extends Node

func spawn_scene(manifest: Dictionary, scene_resource: PackedScene, parent: Node) -> Node:
	var fresh_scene_root: Node = scene_resource.instantiate()
	parent.add_child(fresh_scene_root)
	fresh_scene_root.name = fresh_scene_root.name.validate_node_name()
	
	#manifest[fre]
	
	return fresh_scene_root

func destroy_scene(root_node: Node) -> bool:
	if multiplayer.is_server():
		var node_path: String = String(root_node.get_path())
		var lifetime: NetcodeManager.NodeLifetime = NetcodeManager.node_manifest.get(node_path)
		if lifetime != null:
			lifetime.destroy_tick = NetcodeManager.get_current_tick()
	
	root_node.queue_free()
	
	return true
