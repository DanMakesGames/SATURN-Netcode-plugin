extends Node

func spawn_scene(manifest: Dictionary, scene_resource: PackedScene, parent: Node) -> Node:
	var fresh_scene_root: Node = scene_resource.instantiate()
	parent.add_child(fresh_scene_root)
	fresh_scene_root.name = fresh_scene_root.name.validate_node_name()
	
	manifest[fre]
	
	return fresh_scene_root

func destroy_scene(manifest: Dictionary, ) -> bool:
	return true
