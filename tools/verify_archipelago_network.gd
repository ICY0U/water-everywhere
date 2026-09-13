extends SceneTree

## Real two-process ENet test of the main scene, entered through H and J.
## godot --headless --path . --script tools/verify_archipelago_network.gd -- --port=27119
func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var game := load("res://scenes/archipelago.tscn").instantiate() as Node3D
	root.add_child(game)
	current_scene = game
	var probe := Node.new()
	probe.name = "NetworkVerification"
	probe.set_script(load("res://tools/archipelago_network_probe.gd"))
	game.add_child(probe)
