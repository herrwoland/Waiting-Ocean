extends RigidBody3D
## A physical item the player can pick up, carry in front of the camera and
## drop anywhere (Amnesia-style). Reading happens by simply holding it close
## (Firewatch-style) — no inspection mode. Pairs with the player's
## CarryController; the one interaction rule lives there.
##
## While carried the body is frozen (kinematic) and its collision disabled,
## following the CarrySocket. Dropping restores physics and inherits the
## player's motion, so a letter left on the deck sails with the ship.
##
## Come to rest on a ship's deck, it is stowed: frozen and made part of the
## ship, so it rides her exactly through any surge, roll or turn and can never
## slide overboard. Picking it up takes it off the ship again.
##
## The package uses two extra behaviours (see exports): it is grabbed on touch
## (no aiming/E needed while diving) and it is neutrally buoyant — dropped in
## the water it hangs where it is instead of sinking away forever; dropped in
## air it falls until it meets the water and then holds there.

enum MissionRole { NONE, LETTER, PACKAGE }

@export var item_name: String = ""
@export var mission_role: MissionRole = MissionRole.NONE

@export_group("Package behaviour")
## Grab the moment the player is within pickup_touch_radius — no interact press.
@export var auto_pickup_on_touch: bool = false
@export var pickup_touch_radius: float = 1.8
## Dropped in water it hangs in place instead of sinking; dropped in air it
## falls until it reaches the surface, then holds. Needs `water`.
@export var neutral_buoyancy: bool = false
@export var water: Node

const LAYER_INTERACTABLE := 0b100 # layer 3
const LAYER_ITEMS := 0b1000 # layer 4
const LAYER_DECKS := 0b10 # layer 2: a ship's deck pieces
const STOW_SPEED := 1.0 # m/s of falling (relative to the deck) below which a landed item counts as down
const STOW_GAP := 0.15 # m of air between the item's underside and a deck that still counts as resting on it

var carried := false
## Never collide with the player's body (set by the printer for its sheets). The
## player shares layer 2 with the decks, so something this light lying on the
## floor or landing on them gets shoved out of them at absurd speed.
var ignore_player := false
var _picked_once := false
var _floating := false # neutral-buoyancy item currently held by the water
var _highlight_materials: Array[StandardMaterial3D] = []
var _stowed_on: RigidBody3D = null # the ship it is stowed on, if any
var _loose_parent: Node = null # where it lived before being stowed
var _half_height := 0.25 # from the origin down to the item's underside

func _ready() -> void:
	add_to_group(&'carryable') # the player's feet look through us for the deck beneath
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	for shape: CollisionShape3D in find_children("*", "CollisionShape3D", false, false):
		if shape.shape:
			var box := shape.shape.get_debug_mesh().get_aabb()
			_half_height = maxf(-(shape.transform * box).position.y, 0.05)
			break
	# Every surface you can see gets its own material copy to glow, so highlighting never leaks
	# to other items. Hidden meshes are skipped: the fuel cell keeps its old placeholder
	# capsule ("Mesh", hidden) next to the model with its glass and metal parts.
	for mesh_instance: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
		if mesh_instance.mesh == null or _hidden_within(mesh_instance):
			continue
		for s in mesh_instance.mesh.get_surface_count():
			var mat := mesh_instance.get_active_material(s) as StandardMaterial3D
			if mat:
				mat = mat.duplicate() as StandardMaterial3D
				mesh_instance.set_surface_override_material(s, mat)
				_highlight_materials.append(mat)

func _physics_process(_delta: float) -> void:
	if carried:
		return
	if auto_pickup_on_touch and GameState.phase == GameState.Phase.HAS_LETTER:
		var player: Node3D = get_tree().get_first_node_in_group(&'player')
		if player and player.global_position.distance_to(global_position) < pickup_touch_radius:
			get_tree().get_first_node_in_group(&'carry_controller').pick_up(self)
			return
	if not _stowed_on and not _floating:
		_try_stow()
	if neutral_buoyancy and not _floating and not _stowed_on and water:
		# The moment it reaches (or starts below) the surface, hold it there.
		if global_position.y <= water.get_wave_height(global_position):
			_floating = true
			freeze = true
			linear_velocity = Vector3.ZERO
			angular_velocity = Vector3.ZERO

## Hidden in the item itself (it or a node between it and us), whatever the item sits in.
func _hidden_within(node: Node3D) -> bool:
	while node and node != self:
		if not node.visible:
			return true
		node = node.get_parent() as Node3D
	return false

## Crosshair hover feedback (called by the player's hover system).
func set_highlighted(on: bool) -> void:
	var settings := GameSettings.current() # "Item glow" in game_settings.tres
	for mat in _highlight_materials:
		mat.emission_enabled = on
		mat.emission = settings.item_glow_color
		mat.emission_energy_multiplier = settings.item_glow_energy

## Landed on a ship's deck (just above it, no longer falling onto it): become
## part of the ship. Only the vertical speed is judged: the deck pieces are
## carried along by the ship rather than moved by the physics, so the solver
## treats them as standing still and friction drags a landed item backwards
## across a deck under way -- waiting for it to settle would let it slide off.
##
## A falling item is set down by hand instead of left to the solver: the decks are
## moved by the ship, not by the physics, so a thin sheet landing on one (or lying
## there as she heaves up into it) can be pushed out through the wrong side. When
## the deck is within this step's fall, it is laid flat onto it right away.
func _try_stow() -> void:
	var from := global_position
	var step := get_physics_process_delta_time()
	var fall := maxf(-linear_velocity.y, 0.0) * step * 2.0 # this step's fall, with margin
	# Bodies it is told to pass (eg. the printer it just fell out of) can't catch it either.
	var ignore: Array[RID] = [get_rid()]
	for body: PhysicsBody3D in get_collision_exceptions():
		ignore.append(body.get_rid())
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * (_half_height + STOW_GAP + fall), LAYER_DECKS, ignore)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var ship := _ship_of(hit.collider)
	if ship == null:
		return
	var deck_point_velocity := ship.linear_velocity + ship.angular_velocity.cross(global_position - ship.global_position)
	var falling := -(linear_velocity - deck_point_velocity).dot(ship.global_basis.y)
	if falling > STOW_SPEED:
		if from.y - hit.position.y > _half_height + STOW_GAP + falling * step * 2.0:
			return # still well above her
		# About to hit the deck: land it now, flat on the boards.
		var up := ship.global_basis.y
		var level := Basis(Quaternion(global_basis.y.normalized(), up)) * global_basis
		global_transform = Transform3D(level, hit.position + up * _half_height)
	_stowed_on = ship
	_loose_parent = get_parent()
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	reparent(ship) # keeps where it lies; from now on it moves with her

## The moving body a deck piece hangs from (the ship), or null.
static func _ship_of(node: Object) -> RigidBody3D:
	while node is Node:
		if node is RigidBody3D:
			return node
		node = node.get_parent()
	return null

## Taken off the ship (picked up, restaged): back to where it lived before.
func _unstow() -> void:
	if not _stowed_on:
		return
	_stowed_on = null
	if is_instance_valid(_loose_parent) and get_parent() != _loose_parent:
		reparent(_loose_parent)
	_loose_parent = null

func interact(_player: Node) -> void:
	get_tree().get_first_node_in_group(&'carry_controller').pick_up(self)

func on_picked_up() -> void:
	_unstow()
	carried = true
	_floating = false
	freeze = true
	collision_layer = 0
	collision_mask = 0
	set_highlighted(false)
	if not _picked_once:
		_picked_once = true
		if mission_role == MissionRole.LETTER and GameState.phase == GameState.Phase.WAKE:
			GameState.set_phase(GameState.Phase.HAS_LETTER)
			EventBus.letter_read.emit()
		elif mission_role == MissionRole.PACKAGE and GameState.phase == GameState.Phase.HAS_LETTER:
			GameState.set_phase(GameState.Phase.PICKED_UP)
			EventBus.package_picked_up.emit()

func on_dropped(inherited_velocity: Vector3) -> void:
	_unstow()
	carried = false
	_floating = false
	freeze = false
	# Loose items live on their own layer. Not "world": a ship's hull is one big box around
	# the whole vessel, and anything on the world layer lying on her deck is deep inside it --
	# the physics would shove the entire ship to get it out.
	collision_layer = LAYER_ITEMS | LAYER_INTERACTABLE
	collision_mask = 0b11 # land on the world (shore) and on ship decks (layer 2)
	if ignore_player:
		var player := get_tree().get_first_node_in_group(&'player')
		if player is PhysicsBody3D:
			add_collision_exception_with(player)
	linear_velocity = inherited_velocity
	angular_velocity = Vector3.ZERO
	sleeping = false

## Puts the item back into the world for a new morning.
func restage(world_parent: Node, world_position: Vector3) -> void:
	var controller: Node = get_tree().get_first_node_in_group(&'carry_controller')
	if controller and controller.carried == self:
		controller.carried = null
	on_dropped(Vector3.ZERO)
	_picked_once = false
	if get_parent() != world_parent:
		reparent(world_parent)
	global_transform = Transform3D(Basis.IDENTITY, world_position)
	visible = true

func set_label_text(text: String) -> void:
	if has_node(^'ItemLabel'):
		get_node(^'ItemLabel').text = text
