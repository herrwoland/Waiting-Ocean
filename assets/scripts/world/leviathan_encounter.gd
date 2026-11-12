extends Node3D
## Brings the Leviathan. At night, when the player comes into encounter_area (swimming or sailing),
## one encounter starts: the creature is made deep under the sea ahead of the ship and plays it out
## (leviathan.gd), then frees itself. One encounter per entry, never two at once, and not again
## before `cooldown` has passed. Costs nothing while no encounter is running.
##
## Night: there is no clock yet, night is a weather preset; it counts as night while the sun is
## dimmer than night_sun_energy (the night presets are 0.3 and 0.5, the dimmest day one 0.6).

const LEVIATHAN_SCENE := 'res://assets/models/creatures/leviathan/leviathan.tscn'
const SHORE_X_LIMIT := -85.0 # keep it out of the cove's shallows (as the CreatureDirector does)

@export var player: Node3D
@export var ship: RigidBody3D
@export var water: Node3D
@export var sun: DirectionalLight3D
## Where it hunts. Its CollisionShape3D children mark the waters; size and move them freely.
@export var encounter_area: Area3D
@export var night_sun_energy := 0.55
## Seconds after an encounter starts before another can.
@export var cooldown := 240.0
## It rises somewhere within this many degrees of the ship's bow, so it can be seen coming.
@export_range(0.0, 180.0, 1.0) var bearing_spread := 70.0
## Debug builds only: this key calls it at once, night or day, anywhere.
@export var debug_key := KEY_F8

var _active: Node3D
var _cooldown_left := 0.0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	if player == null:
		player = get_tree().get_first_node_in_group(&'player')
	if water == null:
		water = get_tree().get_first_node_in_group(&'water')
	if ship == null:
		var mission := get_tree().get_first_node_in_group(&'mission_controller')
		if mission:
			ship = mission.get(&'boat')
	if sun == null and get_tree().current_scene:
		var suns := get_tree().current_scene.find_children('*', 'DirectionalLight3D', true, false)
		if not suns.is_empty():
			sun = suns[0]
	if encounter_area:
		encounter_area.body_entered.connect(_on_area_body_entered)
	else:
		push_warning('LeviathanEncounter: no encounter_area set; it only comes on the debug key.')
	EventBus.day_started.connect(_on_day_started)
	Leviathan.warm_sounds() # now, while the game loads, not as a stutter when it comes
	set_process(false)

func _process(delta: float) -> void:
	_cooldown_left -= delta
	if _cooldown_left <= 0.0:
		set_process(false)

func is_night() -> bool:
	return sun != null and sun.visible and sun.light_energy < night_sun_energy

func is_active() -> bool:
	return is_instance_valid(_active)

## The player swimming in, or the ship coming in with them aboard (at her helm the player's own
## body is switched off, so the ship stands in for them).
func _on_area_body_entered(body: Node3D) -> void:
	var aboard: bool = body == ship and player.has_method(&'ship_aboard') and player.ship_aboard() == ship
	if (body == player or aboard) and is_night() and _cooldown_left <= 0.0:
		summon()

func _unhandled_input(event: InputEvent) -> void:
	if OS.is_debug_build() and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == debug_key:
		summon()

## Starts an encounter now (unless one is running).
func summon() -> void:
	if is_active() or ship == null or water == null or player == null:
		return
	var scene := load(LEVIATHAN_SCENE) as PackedScene
	_active = scene.instantiate()
	add_child(_active)
	_active.begin(ship, player, water, _pick_bearing())
	_cooldown_left = cooldown
	set_process(true)

## A direction from the ship within bearing_spread of her bow (her bow is her -X), away from the
## shore: the creature rises out there and comes in from it.
func _pick_bearing() -> Vector3:
	var bow := -ship.global_basis.x
	bow.y = 0.0
	bow = bow.normalized() if bow.length() > 0.01 else Vector3.RIGHT
	var spread := deg_to_rad(bearing_spread)
	var best := bow
	for _try in 12:
		var dir := bow.rotated(Vector3.UP, _rng.randf_range(-spread, spread))
		best = dir
		if (ship.global_position + dir * 1000.0).x > SHORE_X_LIMIT:
			break
	return best

## A ship it took down and kept is given back by the morning (the mission controller has already
## put her at her mooring).
func _on_day_started(_day: int) -> void:
	if ship and ship.has_meta(Leviathan.TAKEN_META):
		ship.remove_meta(Leviathan.TAKEN_META)
		ship.freeze = false
		ship.visible = true
