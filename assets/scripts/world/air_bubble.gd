@tool
class_name AirBubble extends Node3D
## A bubble of air hanging in the water. Put your head in it to breathe. One scene, two kinds:
##  - Pocket: breath comes back for as long as your head stays inside;
##  - Gulp: one breath, then it pops, and only comes back long after (longer than a held breath,
##    so it can't be used twice on one dive).
## Its size is the Area3D's sphere shape (scaled with the node). Everything comes back as it was
## at the start of each day.

enum Kind { POCKET, GULP }

const POCKET_COLOR := Color(0.719326, 0.92035115, 0.97677594)
const POCKET_GLOW := Color(0.0, 0.524553, 0.7307412)
const GULP_COLOR := Color(0.95, 0.96, 0.97)
const GULP_GLOW := Color(0.55, 0.6, 0.62)

## What it does when your head is inside it. Changing it also swaps the colours to that kind's
## (each one only if you haven't picked your own).
@export var kind := Kind.POCKET :
	set(value):
		if kind == value: return
		if color == _kind_color(kind): color = _kind_color(value)
		if glow_color == _kind_glow(kind): glow_color = _kind_glow(value)
		kind = value
## Colour of the skin.
@export var color := POCKET_COLOR :
	set(value): color = value; _apply_look()
## Colour of the light it throws into the water.
@export var glow_color := POCKET_GLOW :
	set(value): glow_color = value; _apply_look()

@export_group('Pocket')
## Seconds of breath regained per second with the head inside.
@export_range(0.0, 60.0, 0.5) var refill_rate := 12.0

@export_group('Gulp')
## Seconds of breath it gives (0 = a full breath).
@export_range(0.0, 120.0, 0.5) var breath_given := 0.0
## Seconds before it comes back after popping. Keep it longer than the player's breath (40 s).
@export_range(1.0, 1200.0, 1.0) var respawn_time := 120.0
## Seconds it takes to burst once you're in it.
@export_range(0.01, 2.0, 0.01) var pop_time := 0.15
## Seconds it takes to swell back up when it returns.
@export_range(0.1, 20.0, 0.1) var regrow_time := 4.0

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _glow: UnderwaterGlow = $UnderwaterGlow
@onready var _shape: CollisionShape3D = $Area3D/CollisionShape3D
@onready var _pop_bubbles: BubbleEmitter = get_node_or_null(^'PopBubbles')

var _glow_strength := 1.0
var _oxygen: Node
var _player: Node3D
var _inside := false
var _grow := 1.0 # 0 = popped, 1 = full size
var _respawn_left := 0.0
var _popping := false

func _ready() -> void:
	_glow_strength = _glow.strength
	_apply_look()
	if Engine.is_editor_hint(): return
	# The sphere only gives the size; the head is tested against it directly (cheap, and no
	# physics layers to keep clear of the boat's, see the boat).
	var area := $Area3D as Area3D
	area.monitoring = false
	area.monitorable = false
	EventBus.day_started.connect(_on_day_started)

func _exit_tree() -> void:
	_set_inside(false)

func _on_day_started(_day: int) -> void:
	_popping = false
	_respawn_left = 0.0
	_set_size(1.0)

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint(): return
	if not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group(&'player')
		_oxygen = _player.get_node_or_null(^'OxygenController') if _player else null
		if not _oxygen: return
	var head: Vector3 = _player.camera.global_position
	var radius := (_shape.shape as SphereShape3D).radius * _shape.global_basis.get_scale().x
	var head_in := head.distance_to(_shape.global_position) < radius

	if _popping:
		_set_size(maxf(_grow - delta / pop_time, 0.0))
		if _grow <= 0.0:
			_popping = false
			_respawn_left = respawn_time
		return
	if _grow < 1.0:
		if _respawn_left > 0.0:
			_respawn_left -= delta
			return
		if _grow <= 0.0 and head_in: return # Don't come back around someone's head.
		_set_size(minf(_grow + delta / regrow_time, 1.0))
		if _grow < 1.0: return

	match kind:
		Kind.POCKET:
			_set_inside(head_in)
		Kind.GULP:
			if head_in:
				_oxygen.gulp_air(breath_given)
				_popping = true
				if _pop_bubbles: _pop_bubbles.burst(0.35)

func _set_inside(inside: bool) -> void:
	if inside == _inside: return
	_inside = inside
	if not _oxygen: return
	if inside: _oxygen.enter_air(self, refill_rate)
	else: _oxygen.leave_air(self)

func _set_size(s: float) -> void:
	_grow = s
	var shown := s > 0.0
	_mesh.visible = shown
	_glow.visible = shown
	# Ease in and out so it swells and bursts rather than scaling linearly.
	var e := s * s * (3.0 - 2.0 * s)
	_mesh.scale = Vector3.ONE * maxf(e, 0.001)
	_glow.strength = _glow_strength * e

func _apply_look() -> void:
	if not is_node_ready(): return
	_mesh.set_instance_shader_parameter(&'tint', color)
	_glow.color = glow_color
	if _pop_bubbles: _pop_bubbles.bubble_color = color.lerp(Color(0.7, 0.85, 0.85), 0.5)

static func _kind_color(k: Kind) -> Color:
	return GULP_COLOR if k == Kind.GULP else POCKET_COLOR

static func _kind_glow(k: Kind) -> Color:
	return GULP_GLOW if k == Kind.GULP else POCKET_GLOW
