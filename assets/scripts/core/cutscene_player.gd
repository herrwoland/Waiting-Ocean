extends Node
## Cutscene machinery (autoload). Owns a temporary camera and a white-fade /
## end-screen overlay. Placeholder sequences are tween-driven; real cutscenes
## can later swap in AnimationPlayer content behind the same entry points.

var _camera: Camera3D
var _layer: CanvasLayer
var _fade: ColorRect
var _end_label: Label
var _ending_active := false
var _end_screen_shown := false

func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 6
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_layer)

	_fade = ColorRect.new()
	_fade.color = Color(0.98, 0.97, 0.94)
	_fade.modulate.a = 0.0
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_fade)

	_end_label = Label.new()
	_end_label.text = "The fifth day ends.\n\nTHE END\n\n\nE — return"
	_end_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_end_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_end_label.modulate = Color(0.1, 0.1, 0.12)
	_end_label.visible = false
	_layer.add_child(_end_label)

## The day-5 finale: the fish rises from the shore and carries the player
## toward the moon; white-out; end screen. `fish` is the EndingFish root.
func play_ending(fish: Node3D, player: Node3D) -> void:
	if _ending_active:
		return
	_ending_active = true

	# Take control away from the player, and ride the fish with a chase camera.
	player.controls_frozen = true
	player.set_physics_process(false)
	player.visible = false

	_camera = Camera3D.new()
	fish.add_child(_camera)
	_camera.position = Vector3(-14, 5, 11)
	_camera.look_at(fish.global_position + Vector3.UP * 2.0, Vector3.UP)
	_camera.current = true

	var tween := create_tween()
	# A slow, considered rise off the sand...
	tween.tween_property(fish, "global_position", fish.global_position + Vector3.UP * 5.0, 3.0) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_interval(1.0)
	# ...then out and up, toward the moon.
	tween.tween_property(fish, "global_position", fish.global_position + Vector3(220, 420, 60), 14.0) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	# White-out during the climb, then the end screen.
	tween.parallel().tween_property(_fade, "modulate:a", 1.0, 5.0).set_delay(9.0)
	tween.tween_callback(_show_end_screen)

func _show_end_screen() -> void:
	_end_screen_shown = true
	_end_label.visible = true
	get_tree().paused = true

func _unhandled_input(event: InputEvent) -> void:
	if _end_screen_shown and event.is_action_pressed(&'interact'):
		_end_screen_shown = false
		_ending_active = false
		_end_label.visible = false
		_fade.modulate.a = 0.0
		get_tree().paused = false
		get_tree().reload_current_scene()
