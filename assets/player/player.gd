extends CharacterBody3D
## First person player controller with five states: walking, swimming, piloting
## a ship's helm, operating a mounted station (eg. the searchlight) and climbing a Ladder. Swim state is driven by comparing the player's feet
## height against the wave height sampled from `water`.

enum State { WALK, SWIM, PILOT, OPERATE, CLIMB }

@export var water: Node
@export var walk_speed: float = 5.0
@export var sprint_speed: float = 8.5
@export var swim_speed: float = 1.75
@export var jump_velocity: float = 4.5
## Our own body (PlayerBody): seen looking down and in our shadow.
@export var show_body := true
@export_group('Body at the Helm')
## How far the fingers close round a handle: 0 = an open hand, 1 = a tight fist.
@export_range(0.0, 1.0, 0.01) var grip_closure := 0.55
## How deep the handle sits in the hand: 0 = at the wrist, 1 = at the knuckles.
@export_range(0.0, 1.0, 0.01) var grip_depth := 0.55
## The wrists, turned from where the arm leaves them (degrees; the hands mirror each other):
## bend = the palm folds down (+) or back (-) ...
@export_range(-90.0, 90.0, 0.5) var wrist_bend := 0.0
## ... twist = the hand rolls about the forearm, thumbs out (+) or in (-) ...
@export_range(-90.0, 90.0, 0.5) var wrist_twist := 0.0
## ... tilt = the hand swings toward the little finger (+) or the thumb (-).
@export_range(-90.0, 90.0, 0.5) var wrist_tilt := 0.0
## The thumbs, turned at their base on top of the grip (degrees, mirrored): pitch opens the thumb
## out from the palm (+) or folds it in (-) ...
@export_range(-90.0, 90.0, 0.5) var thumb_pitch := 0.0
## ... turn swings it round toward the fingers (+) or away (-).
@export_range(-90.0, 90.0, 0.5) var thumb_turn := 0.0
## The wrists again, but only as the wheel goes round toward full lock and the hands turn with
## their spokes (degrees, on top of the wrist sliders above; fading in from 10 to 25 degrees round).
@export_range(-90.0, 90.0, 0.5) var lock_wrist_bend := 0.0
@export_range(-90.0, 90.0, 0.5) var lock_wrist_twist := 0.0
@export_range(-90.0, 90.0, 0.5) var lock_wrist_tilt := 0.0
@export_group('')
@export var mouse_sensitivity: float = 0.0025
@export var turn_speed: float = 2.0 # radians/sec, for keyboard look (Q/R or arrow keys), eg. over a remote desktop
@export var look_speed: float = 1.5 # radians/sec, for keyboard look up/down (arrow keys)
@export var swim_enter_depth: float = 0.6 # how deep water must be over the feet before we start swimming
@export var swim_exit_depth: float = 0.45 # while grounded, water shallower than this switches back to walking (wading)
@export var sink_speed: float = 1.0 # constant downward speed while swimming unless swim_up is held
## Keeping afloat (holding swim_up at the surface) rides the water exactly, like a Water
## surface_point: the eyes this high above it (m), carried up, down and round with the waves.
@export_range(0.0, 1.0, 0.01) var float_eye_height: float = 0.25
## Afloat, the view rolls with the slope of the water under you, like a body lying on it:
## degrees of roll on a 45 degree slope (0 = keep the view level).
@export_range(0.0, 30.0, 0.5) var float_tilt: float = 12.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var interact_ray: RayCast3D = $Head/Camera3D/InteractRay
@onready var collider: CollisionShape3D = $Collider
@onready var carry_controller: Node = $CarryController
@onready var splash_particles: GPUParticles3D = $SplashParticles
## The small, quick splash thrown up each time the head crosses the waterline, either way.
## Tune it on the node: amount, lifetime and the process material's speeds and scale.
@onready var head_splash: GPUParticles3D = get_node_or_null(^'HeadSplash')
@onready var surface_ripples: GPUParticles3D = $SurfaceRipples
@onready var splash_player: AudioStreamPlayer = get_node_or_null(^'SplashPlayer')
## Air dragged under as we break the surface. Not breath -- see OxygenController for that;
## this is the cloud that comes down with a body. Tune its look on the node itself.
@onready var plunge_bubbles: BubbleEmitter = get_node_or_null(^'Head/Camera3D/PlungeBubbles')
@onready var gasp_player: AudioStreamPlayer = get_node_or_null(^'GaspPlayer')

var state: State = State.WALK
var piloted_ship: Node = null
var helm_marker: Node3D = null
var station: Node = null # the mounted station (eg. searchlight) we are operating
var hovered_interactable: Object = null
var inspecting: bool = false # set by InspectionController; freezes movement and look
var captured: bool = false # in a hunter's jaws; the CreatureDirector drives our position
## Drowned and limp (see OxygenController): no control, the body just sinks.
var unconscious: bool = false
var unconscious_sink_speed: float = 0.6
var interact_cooldown_until_msec: int = 0
## Ship whose deck is under our feet. Its collision is made of StaticBody3D pieces parented
## to the hull's RigidBody3D, so the physics engine sees them teleport rather than move and
## carries us nowhere: we have to travel with the deck ourselves or it slides out from under us.
var _deck: PhysicsBody3D = null
var _deck_xform: Transform3D
var _deck_coyote: float = 0.0
var _deck_velocity := Vector3.ZERO # measured from the deck's movement, so it is right no
								   # matter what moves her: engine, waves or a creature
## The deck's sideways speed we left with (a jump, a step off her side), kept on top of walking
## input until we land: jump on a ship under way and you come down on the same plank. Taken once,
## at the moment we leave, so a creature yanking her about while we're in the air can't throw us.
var _air_momentum := Vector3.ZERO
const MAX_AIR_MOMENTUM := 10.0 # m/s: a violent jerk of the hull as we leave doesn't launch us
const DECK_COYOTE := 0.35 # keep carrying this long after the deck drops away, so a heaving
						  # sea doesn't shake us loose every time contact is lost
const AIRBORNE_DECK_REACH := 8.0 # m: still over her deck this far below us, we are still aboard
var ladder: Node = null # the Ladder we are on (see ladder.gd)
var _ladders_in_reach: Array[Node] = []
var _climb_t := 0.0 # where on the ladder, 0 = bottom, 1 = top
var _climb_exit := -1.0 # 0..1 while stepping over the top, -1 otherwise
## On a ladder: how fast we are climbing it (m/s along it, < 0 going down). The body's climb clip
## keeps pace with it (see player_body.gd).
var climb_rate := 0.0
var _ladder_regrab_block := false # just got off: let go of the keys before a ladder takes us again
var _grab_offset := Vector3.ZERO # where we were when we grabbed, relative to the ladder (its space)
var _grab_blend := 0.0 # 1 at the grab, easing to 0 as we are pulled onto the ladder
const LADDER_GRAB_TIME := 0.25

const GRAVITY: float = 9.8

@export var underwater_cutoff_hz: float = 600.0 # low-pass cutoff while the camera is submerged

var _lowpass_idx: int = -1
var _last_eye_submersion: float = INF
var _head_base_y: float = 1.6
var _eye_offset: float = 0.0
var _ears_underwater: bool = false
var _submerged_at_msec: int = 0 # when the ears last went under, for the surfacing gasp
var _float_rest := Vector2.INF # afloat: the piece of water we ride (Water.surface_rest); INF = not afloat
var _float_roll := 0.0 # the view's roll from the wave we are riding
## Swimming: the way and speed we are swimming under our own power (m/s), up and down included;
## zero while only sinking or treading water. The body strokes by it (see player_body.gd).
var swim_stroke := Vector3.ZERO

const GASP_AFTER_SECONDS := 4.0 # dives shorter than this surface without a gasp

## The sea passing exactly through the eyes draws a hard line across the middle of the view:
## a plane through a camera always projects to one. Keep the eyes this far clear of the
## surface, plainly above it or plainly under, rather than sitting in it (0 = allow it).
@export_range(0.0, 2.5, 0.01) var eye_waterline_clearance: float = 0.18
## How quickly the eyes follow that push. Higher is more immediate, lower is softer.
@export_range(1.0, 40.0, 0.5) var eye_waterline_speed: float = 10.0
## How many times faster than the body the eyes cross the surface. 1 disables the rush; the
## higher it is, the briefer the moment spent in the waterline -- and the sharper the plunge.
@export_range(1.0, 15.0, 0.5) var eye_waterline_rush: float = 6.0
## How fast the surface has to pass the eyes for the plunge to drag a full lungful of air
## under (m/s). Jumping off the deck is well past this; a wave washing over is not.
@export var plunge_full_speed: float = 4.0
## Bubbles from merely drifting through the surface (0..1 of the emitter's budget).
@export_range(0.0, 1.0, 0.01) var plunge_idle_bubbles: float = 0.12
## How long the hardest plunge keeps bubbling (s).
@export_range(0.05, 3.0, 0.05) var plunge_burst_seconds: float = 0.5

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	var camera_shake := CameraShake.new() # answers EventBus.camera_shake_requested
	camera_shake.name = &'CameraShake'
	camera_shake.camera = camera
	add_child(camera_shake)
	var sonar := SonarPulse.new() # V under the water: a moment's grainy echo of everything around
	sonar.name = &'SonarPulse'
	sonar.player = self
	add_child(sonar)
	var body := get_node_or_null(^'Body') as PlayerBody # our own body: seen looking down, and in our shadow
	if body:
		if show_body:
			move_child(body, -1) # after CameraShake, so the eyes place the camera last
			body.setup(self)
		else:
			body.queue_free()
	_head_base_y = head.position.y
	floor_snap_length = 0.5 # a deck falling out of a wave can outrun gravity; stay stuck to it
	# Muffle all audio while underwater via a low-pass filter on the Master bus.
	var lowpass := AudioEffectLowPassFilter.new()
	lowpass.cutoff_hz = underwater_cutoff_hz
	_lowpass_idx = AudioServer.get_bus_effect_count(0)
	AudioServer.add_bus_effect(0, lowpass)
	AudioServer.set_bus_effect_enabled(0, _lowpass_idx, false)

func _update_underwater_audio(delta: float) -> void:
	if not water:
		return
	var submersion: float = water.get_wave_height(camera.global_position) - camera.global_position.y
	var underwater: bool = submersion > 0.0 and not water.is_water_hole(camera.global_position)
	# How fast the surface is passing the eyes, for the plunge below.
	var crossing_speed := 0.0
	if _last_eye_submersion != INF and delta > 0.0:
		crossing_speed = absf(submersion - _last_eye_submersion) / delta
	_last_eye_submersion = submersion
	if underwater != _ears_underwater:
		_ears_underwater = underwater
		AudioServer.set_bus_effect_enabled(0, _lowpass_idx, underwater)
		_splash_at_head(camera.global_position.y + submersion)
		if underwater:
			_plunge(crossing_speed)
			_submerged_at_msec = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - _submerged_at_msec > GASP_AFTER_SECONDS * 1000.0 \
				and gasp_player and gasp_player.stream and not captured:
			gasp_player.play() # breaking the surface after a long dive

## Rushes the eyes through the waterline instead of parking them clear of it. Holding them
## to one side means the offset grows exactly as fast as the body sinks, so the view stops
## dead while the body keeps going: you float on the surface, snap under, then hang there on
## the way back up. Here they always travel the same way the body does, only several times
## faster across the surface, so the crossing is quick without ever stalling.
func _keep_eyes_clear_of_waterline(delta: float) -> void:
	var target := 0.0
	# Afloat, the eyes are set above the water exactly; pushing them off it would only lift them.
	var afloat := state == State.SWIM and _float_rest != Vector2.INF
	if water and eye_waterline_clearance > 0.0 and state != State.PILOT and not captured and not afloat:
		# Work from where the head would sit untouched, never from the nudged position, or the
		# nudge chases its own tail.
		var eye := camera.global_position
		var rest_eye := eye.y - _eye_offset
		var submersion: float = water.get_wave_height(eye) - rest_eye
		# tanh rises to the clearance and stays there, so the eyes never turn back on the body
		# -- a push that peaks and returns hands back the distance it gained, which stalls the
		# view just as badly as parking it did. The wide falloff then gives that distance back
		# over meters, where a few per cent of lost speed cannot be felt.
		var width := eye_waterline_clearance / maxf(eye_waterline_rush - 1.0, 0.1)
		var falloff := maxf(6.0 * eye_waterline_clearance, 3.0)
		var fade := submersion / falloff
		target = -eye_waterline_clearance * tanh(submersion / width) * exp(-fade * fade)
	_eye_offset = lerpf(_eye_offset, target, 1.0 - exp(-delta * eye_waterline_speed))
	head.position.y = _head_base_y + _eye_offset

## A small splash where the head goes through the surface, in or out. The big SplashParticles
## is the whole body hitting the water; this is just the head, so it is quicker and lighter.
func _splash_at_head(surface_y: float) -> void:
	if not head_splash:
		return
	head_splash.global_position = Vector3(camera.global_position.x, surface_y, camera.global_position.z)
	head_splash.restart()

## The air a body drags under with it. Slipping through the surface barely clouds the water;
## jumping off the deck takes a great gout of it down.
func _plunge(crossing_speed: float) -> void:
	if not plunge_bubbles:
		return
	var hardness := clampf(crossing_speed / maxf(plunge_full_speed, 0.1), 0.0, 1.0)
	plunge_bubbles.burst(lerpf(0.12, plunge_burst_seconds, hardness),
			lerpf(plunge_idle_bubbles, 1.0, hardness))

## At the helm (from_helm) only things marked usable_from_helm can be reached.
func _update_interact_hover(from_helm := false) -> void:
	var target: Object = null
	if interact_ray.is_colliding():
		var collider_hit := interact_ray.get_collider()
		if collider_hit and collider_hit.has_method(&'interact') and collider_hit.get(&'enabled') != false:
			if not from_helm or collider_hit.get(&'usable_from_helm') == true:
				target = collider_hit

	if target == hovered_interactable:
		return
	if hovered_interactable and is_instance_valid(hovered_interactable) and hovered_interactable.has_method(&'set_highlighted'):
		hovered_interactable.set_highlighted(false)
	if target and target.has_method(&'set_highlighted'):
		target.set_highlighted(true)
	hovered_interactable = target

func _unhandled_input(event: InputEvent) -> void:
	if unconscious:
		return
	if inspecting:
		return # the InspectionController owns input while an item is held up
	if state == State.OPERATE:
		_station_input(event)
		return
	if state == State.PILOT and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		head.rotation.y -= event.relative.x * mouse_sensitivity
		camera.rotation.x -= event.relative.y * mouse_sensitivity
		camera.rotation.x = clampf(camera.rotation.x, -PI / 2.0, PI / 2.0)
	elif event.is_action_pressed(&'interact') and not captured:
		_try_interact(event is InputEventKey)

## While captured the body is dragged by the creature: controls and collisions
## are off, but the head is free to look around on the way down.
func set_captured(caught: bool) -> void:
	captured = caught
	collider.disabled = caught
	_deck = null
	velocity = Vector3.ZERO
	surface_ripples.emitting = false

func _physics_process(delta: float) -> void:
	_update_underwater_audio(delta)
	if captured:
		return # the creature moves us; nothing to simulate
	if unconscious:
		velocity = Vector3(0.0, -unconscious_sink_speed, 0.0)
		move_and_slide() # Limp: drift down until the sea floor stops us.
		return
	if inspecting:
		velocity = Vector3.ZERO
		move_and_slide()
		return
	_process_turn_keys(delta)
	if state == State.WALK or state == State.SWIM:
		_update_interact_hover()
		_try_grab_ladder()
	elif state == State.PILOT:
		_update_interact_hover(true)
	match state:
		State.WALK:
			_process_walk(delta)
			_check_enter_swim()
		State.SWIM:
			_process_swim(delta)
			_check_exit_swim()
		State.PILOT:
			_process_pilot(delta)
		State.OPERATE:
			_process_operate(delta)
		State.CLIMB:
			_process_ladder(delta)

	_keep_eyes_clear_of_waterline(delta)

func _process_turn_keys(delta: float) -> void:
	var turn := Input.get_action_strength(&'turn_left') - Input.get_action_strength(&'turn_right')
	var pitch := Input.get_action_strength(&'look_up') - Input.get_action_strength(&'look_down')
	if state == State.OPERATE:
		if turn != 0.0 or pitch != 0.0:
			station.aim(turn * turn_speed * delta, pitch * look_speed * delta)
		return
	if turn != 0.0:
		head.rotation.y += turn * turn_speed * delta
	if pitch != 0.0:
		camera.rotation.x = clampf(camera.rotation.x + pitch * look_speed * delta, -PI / 2.0, PI / 2.0)

## Called by a Ladder when we come into (or leave) its reach.
func ladder_in_reach(target: Node, in_reach: bool) -> void:
	if in_reach:
		if not target in _ladders_in_reach: _ladders_in_reach.append(target)
	else:
		_ladders_in_reach.erase(target)

## Takes hold of a ladder in reach: jump/space (swimming up to one, or at its foot), walking
## into it while facing it, or walking over the edge at its top.
func _try_grab_ladder() -> void:
	var climbing_keys := Input.is_action_pressed(&'jump') or Input.is_action_pressed(&'move_forward')
	if _ladder_regrab_block:
		_ladder_regrab_block = climbing_keys
		return
	if _ladders_in_reach.is_empty() or captured:
		return
	var look := -head.global_basis.z
	look.y = 0.0
	look = look.normalized()
	for l in _ladders_in_reach:
		if not is_instance_valid(l): continue
		var t: float = l.closest_t(global_position)
		var toward: float = look.dot(l.facing())
		var grab := Input.is_action_pressed(&'jump') and t < 0.9 # from below or from the water
		grab = grab or (Input.is_action_pressed(&'move_forward') and toward > 0.5 and t < 0.9)
		grab = grab or (Input.is_action_pressed(&'move_forward') and toward < -0.5 and t >= 0.9) # over the top
		if grab:
			_start_climb(l, minf(t, 0.97)) # from above: just under the top, so back goes down
			return

func _start_climb(target: Node, t: float) -> void:
	if hovered_interactable and hovered_interactable.has_method(&'set_highlighted'):
		hovered_interactable.set_highlighted(false)
	hovered_interactable = null
	state = State.CLIMB
	ladder = target
	_climb_t = t
	_climb_exit = -1.0
	# Pulled onto the ladder over a moment rather than snapped there.
	_grab_offset = target.global_basis.inverse() * (global_position - target.point(t))
	_grab_blend = 1.0
	_deck = null # the ladder carries us now
	_air_momentum = Vector3.ZERO
	velocity = Vector3.ZERO
	collider.disabled = true # the hull and rungs are right in front of us
	surface_ripples.emitting = false
	_float_rest = Vector2.INF
	_float_roll = 0.0
	camera.rotation.z = 0.0

## On the ladder: forward/space climbs, back goes down, back at the foot steps off, swim_down
## (C) lets go. The position is worked out along the ladder every frame, so a moving ship
## carries us exactly. At the top we step over onto its landing.
func _process_ladder(delta: float) -> void:
	if not is_instance_valid(ladder):
		_leave_ladder(false)
		return
	velocity = Vector3.ZERO
	if _climb_exit >= 0.0:
		_climb_exit = minf(_climb_exit + delta / maxf(ladder.exit_time, 0.01), 1.0)
		var k := smoothstep(0.0, 1.0, _climb_exit)
		var from: Vector3 = ladder.point(1.0)
		var to: Vector3 = ladder.top_exit.global_position
		var p := from.lerp(to, k)
		p.y += sin(k * PI) * 0.25 # up and over the edge
		global_position = p
		climb_rate = ladder.climb_speed # still climbing, over the edge
		if _climb_exit >= 1.0:
			_leave_ladder(true)
		return
	if Input.is_action_just_pressed(&'swim_down'):
		_leave_ladder(false)
		return
	var up := maxf(Input.get_action_strength(&'move_forward'), 1.0 if Input.is_action_pressed(&'jump') else 0.0)
	var input := clampf(up - Input.get_action_strength(&'move_back'), -1.0, 1.0)
	var was_t := _climb_t
	_climb_t += input * ladder.climb_speed / maxf(ladder.length(), 0.1) * delta
	if _climb_t >= 1.0:
		_climb_t = 1.0
		if input > 0.0:
			_climb_exit = 0.0 # over the top
	elif _climb_t <= 0.0:
		_climb_t = 0.0
		if input < 0.0:
			_leave_ladder(false)
			return
	climb_rate = (_climb_t - was_t) * ladder.length() / maxf(delta, 1e-6) # 0 when held at an end
	_grab_blend = move_toward(_grab_blend, 0.0, delta / LADDER_GRAB_TIME)
	global_position = ladder.point(_climb_t) + ladder.global_basis * _grab_offset * smoothstep(0.0, 1.0, _grab_blend)

func _leave_ladder(at_top: bool) -> void:
	state = State.WALK
	ladder = null
	climb_rate = 0.0
	_climb_exit = -1.0
	collider.disabled = false
	velocity = Vector3.ZERO
	_ladder_regrab_block = true
	if at_top:
		# Stepped onto a deck: stand on it from this very frame, or a moving ship leaves us behind.
		var ship := _ship_under_feet()
		if ship:
			_deck = ship
			_deck_xform = ship.global_transform
			_deck_coyote = DECK_COYOTE

func _process_walk(delta: float) -> void:
	_carry_with_deck(delta)
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif Input.is_action_just_pressed(&'jump'):
		velocity.y = jump_velocity

	var speed := sprint_speed if Input.is_action_pressed(&'sprint') else walk_speed
	var input_dir := Vector2(
		Input.get_action_strength(&'move_right') - Input.get_action_strength(&'move_left'),
		Input.get_action_strength(&'move_back') - Input.get_action_strength(&'move_forward')
	).normalized()
	var move_dir := (head.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	velocity.x = move_dir.x * speed + _air_momentum.x
	velocity.z = move_dir.z * speed + _air_momentum.z

	move_and_slide()
	if is_on_floor():
		_air_momentum = Vector3.ZERO # landed: the deck or the ground carries us from here
	_update_deck()

## Moves us by however much the deck moved since the last frame and turns us with it, so
## standing still on a boat under way keeps us standing on the same plank.
func _carry_with_deck(delta: float) -> void:
	if not is_instance_valid(_deck):
		_deck = null
		return
	_deck_coyote -= delta
	if _deck_coyote <= 0.0:
		# Still over her (a jump, a fall into the well of her deck): in the air we keep her motion,
		# so we stay carried and come down on the same plank. Only off her side do we let go.
		if _ship_under_feet(AIRBORNE_DECK_REACH) == _deck:
			_deck_coyote = DECK_COYOTE
		else:
			_release_deck() # airborne too long to still count as standing on her
			return
	var step := _deck_step()
	var carried_to := step * global_position
	_deck_velocity = (carried_to - global_position) / delta
	global_position = carried_to
	head.rotation.y += step.basis.get_euler().y

## How fast the deck we stand on is carrying us (zero on land or afloat):
## what a dropped item has to inherit to stay with the ship.
func deck_velocity() -> Vector3:
	return _deck_velocity if _deck else Vector3.ZERO

## The deck's movement since we last looked.
func _deck_step() -> Transform3D:
	var step := _deck.global_transform * _deck_xform.affine_inverse()
	_deck_xform = _deck.global_transform
	return step

## Re-anchors to whatever we are standing on at the end of a frame.
func _update_deck() -> void:
	if not is_on_floor():
		return # the coyote timer keeps us aboard for a moment; _carry_with_deck runs it down
	var ship := _ship_under_feet()
	if not ship:
		if _deck: _release_deck() # stepped off onto the island, or a jetty
		return
	if ship != _deck:
		_deck_velocity = Vector3.ZERO
	_deck = ship
	_deck_xform = ship.global_transform
	_deck_coyote = DECK_COYOTE

## Lets go of the deck, keeping its momentum, so stepping off a moving boat throws us
## forward the way it should instead of dropping us straight down.
func _release_deck() -> void:
	velocity += _deck_velocity
	_air_momentum = Vector3(_deck_velocity.x, 0.0, _deck_velocity.z).limit_length(MAX_AIR_MOMENTUM)
	_deck = null
	_deck_coyote = 0.0
	_deck_velocity = Vector3.ZERO

## The hull under our feet, found by looking past the deck's static collision pieces to the
## body they hang from -- a ship, or anything else built to move under us. A ray rather than
## the slide collisions: standing perfectly still reports none. Loose items lying on the deck
## (carryables: a fuel cell, a letter) are looked through -- they are rigid bodies too, and
## riding one would drag us along with it as it rolls.
func _ship_under_feet(reach := 0.8) -> PhysicsBody3D:
	var from := global_position + Vector3.UP * 0.3
	var exclude: Array[RID] = [get_rid()]
	for attempt in 4:
		var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * reach,
				collision_mask, exclude)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit:
			return null
		var node = hit.get('collider')
		if node is Node and node.is_in_group(&'carryable'):
			exclude.append(hit.get('rid'))
			continue
		while node is Node:
			if node is RigidBody3D or node is AnimatableBody3D:
				return node
			node = node.get_parent() # the deck's own StaticBody3D pieces are not what carries us
		return null
	return null

func _process_swim(delta: float) -> void:
	var surface_y: float = water.get_wave_height(global_position)
	var swim_top_y: float = surface_y - 0.4 # highest the feet can get: head roughly at the surface

	var input_dir := Vector2(
		Input.get_action_strength(&'move_right') - Input.get_action_strength(&'move_left'),
		Input.get_action_strength(&'move_back') - Input.get_action_strength(&'move_forward')
	).normalized()
	var move_dir := head.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)
	if move_dir.length() > 0.0:
		move_dir = move_dir.normalized()

	# Holding swim_up at the surface: afloat, riding the waves exactly (see _float_on_surface).
	# From below, swim_up swims us up until the eyes reach the water, then catches us there.
	if Input.is_action_pressed(&'swim_up') and water.has_method(&'surface_point'):
		var afloat_feet := surface_y + float_eye_height - _head_base_y
		if _float_rest != Vector2.INF or global_position.y >= afloat_feet - 0.05:
			swim_stroke = move_dir * swim_speed # treading water is not a stroke, the waves' motion neither
			_float_on_surface(delta, move_dir)
			_roll_with_wave(delta, true)
			surface_ripples.global_position = Vector3(global_position.x, surface_y, global_position.z)
			return
	_float_rest = Vector2.INF
	_roll_with_wave(delta, false)

	velocity.x = move_dir.x * swim_speed
	velocity.z = move_dir.z * swim_speed

	# The player constantly sinks; swim_up (space) is required to rise or stay afloat,
	# swim_down speeds up the sinking.
	swim_stroke = Vector3(velocity.x, 0.0, velocity.z) # sinking is no stroke
	if Input.is_action_pressed(&'swim_up'):
		velocity.y = swim_speed
		swim_stroke.y = swim_speed
	elif Input.is_action_pressed(&'swim_down'):
		velocity.y = -swim_speed
		swim_stroke.y = -swim_speed
	else:
		velocity.y = -sink_speed

	move_and_slide()

	# You can't swim out of the water: clamp to the wave surface so holding
	# swim_up rides the waves instead of launching into the sky.
	if global_position.y > swim_top_y:
		global_position.y = swim_top_y
		velocity.y = minf(velocity.y, 0.0)

	# Keep the surface ripples sitting on the waves above us.
	surface_ripples.global_position = Vector3(global_position.x, surface_y, global_position.z)

## Afloat: ride one piece of the water surface -- up, down and round with the waves, the way
## the test float in scenes/test does -- with the eyes float_eye_height above it. Swimming moves
## which piece we ride. We still go through move_and_slide, so a hull stops us; if something
## holds us back, we take hold of the water where we are instead of being dragged into it.
func _float_on_surface(delta: float, move_dir: Vector3) -> void:
	if _float_rest == Vector2.INF:
		_float_rest = water.surface_rest(global_position)
	_float_rest += Vector2(move_dir.x, move_dir.z) * swim_speed * delta
	var p: Vector3 = water.surface_point(_float_rest)
	var target := Vector3(p.x, p.y + float_eye_height - _head_base_y, p.z)
	velocity = (target - global_position) / maxf(delta, 1e-4)
	move_and_slide()
	if global_position.distance_to(target) > 0.1:
		_float_rest = water.surface_rest(global_position)

## Rolls the view with the slope of the water across it while afloat, easing back to level
## otherwise. Only roll: pitching would fight the mouse.
func _roll_with_wave(delta: float, afloat: bool) -> void:
	var target := 0.0
	if afloat and float_tilt > 0.0:
		var right := camera.global_basis.x
		right.y = 0.0
		right = right.normalized() * 0.6
		var slope: float = (water.get_wave_height(global_position + right) - water.get_wave_height(global_position - right)) / 1.2
		target = atan(slope) * float_tilt / 45.0
	if target == 0.0 and _float_roll == 0.0:
		return
	_float_roll = lerpf(_float_roll, target, 1.0 - exp(-delta * 5.0))
	if absf(_float_roll) < 0.0005 and target == 0.0:
		_float_roll = 0.0
	camera.rotation.z = _float_roll

func _process_pilot(delta: float) -> void:
	if not is_instance_valid(helm_marker):
		exit_pilot()
		return

	global_position = helm_marker.global_position
	velocity = Vector3.ZERO
	if is_instance_valid(_deck):
		head.rotation.y += _deck_step().basis.get_euler().y # the helm turns with her

	var throttle := Input.get_action_strength(&'move_forward') - Input.get_action_strength(&'move_back')
	var rudder := Input.get_action_strength(&'move_right') - Input.get_action_strength(&'move_left')
	if piloted_ship and piloted_ship.has_method(&'set_helm_input'):
		piloted_ship.set_helm_input(throttle, rudder)

	if Input.is_action_just_pressed(&'jump'):
		exit_pilot()

func _check_enter_swim() -> void:
	if not water:
		return
	if water.is_water_hole(global_position):
		return # inside a HOLE wave blocker (eg. a dry shaft) there is no water to swim in
	var surface_y: float = water.get_wave_height(global_position)
	if surface_y - global_position.y > swim_enter_depth:
		state = State.SWIM
		_release_deck()
		_air_momentum = Vector3.ZERO # the water takes it
		collider.disabled = false
		_play_splash(surface_y)
		surface_ripples.emitting = true

func _check_exit_swim() -> void:
	if not water:
		return
	# Standing on ground (eg. a beach slope or the ship's deck) in shallow-enough
	# water means we can wade: back to walking, which also restores jumping.
	var surface_y: float = water.get_wave_height(global_position)
	if is_on_floor() and surface_y - global_position.y < swim_exit_depth:
		state = State.WALK
		swim_stroke = Vector3.ZERO
		surface_ripples.emitting = false
		_float_rest = Vector2.INF
		_float_roll = 0.0
		camera.rotation.z = 0.0

func _play_splash(surface_y: float) -> void:
	splash_particles.global_position = Vector3(global_position.x, surface_y, global_position.z)
	splash_particles.restart()
	if splash_player and splash_player.stream:
		splash_player.play()

## from_key: pressed on the keyboard (E), not the mouse button.
func _try_interact(from_key := false) -> void:
	if state == State.PILOT:
		# At the helm the only thing in reach is a control beside the wheel (see
		# _update_interact_hover); looking at none, the E key lets go of the
		# wheel, the same as the jump (space) key.
		if hovered_interactable and hovered_interactable.get(&'usable_from_helm') == true:
			hovered_interactable.interact(self)
		elif from_key:
			exit_pilot()
		return
	if Time.get_ticks_msec() < interact_cooldown_until_msec:
		return # eg. the press that just closed an inspection
	if carry_controller.is_carrying():
		carry_controller.drop() # hands full: interact always means "put it down"
		return
	if hovered_interactable and hovered_interactable.has_method(&'interact'):
		hovered_interactable.interact(self)

func enter_pilot(ship: Node, marker: Node3D) -> void:
	if state == State.PILOT:
		return
	if hovered_interactable and hovered_interactable.has_method(&'set_highlighted'):
		hovered_interactable.set_highlighted(false)
	hovered_interactable = null
	state = State.PILOT
	piloted_ship = ship
	helm_marker = marker
	_deck = ship as PhysicsBody3D
	if _deck: _deck_xform = _deck.global_transform
	collider.disabled = true
	velocity = Vector3.ZERO
	if ship.has_method(&'set_piloted'):
		ship.set_piloted(true)

func exit_pilot() -> void:
	if piloted_ship and piloted_ship.has_method(&'set_piloted'):
		piloted_ship.set_piloted(false)
	if is_instance_valid(helm_marker):
		global_position = helm_marker.global_position + helm_marker.global_transform.basis.y * 0.1
	state = State.WALK
	piloted_ship = null
	helm_marker = null
	collider.disabled = false
	if is_instance_valid(_deck): # step off the helm already moving with her
		_deck_xform = _deck.global_transform
		_deck_coyote = DECK_COYOTE

## Takes hold of a mounted station: the body stays where it stands on the deck and the
## view moves to the station's camera, where looking around turns the station instead.
func enter_station(target: Node) -> void:
	if state != State.WALK:
		return
	if hovered_interactable and hovered_interactable.has_method(&'set_highlighted'):
		hovered_interactable.set_highlighted(false)
	hovered_interactable = null
	state = State.OPERATE
	station = target
	station.set_operated(true, camera)

func exit_station() -> void:
	if is_instance_valid(station):
		station.set_operated(false, camera)
	else:
		camera.make_current()
	station = null
	state = State.WALK

## The ship we are aboard -- at her helm, or standing on her deck -- or null.
func ship_aboard() -> RigidBody3D:
	if captured:
		return null
	if state == State.PILOT:
		return piloted_ship as RigidBody3D
	if state == State.WALK or state == State.OPERATE:
		return _deck as RigidBody3D
	return null

## Thrown clear of whatever we stand on or steer (a capsizing ship): hands off the
## controls, and the body flies with `impulse` (m/s).
func throw_off(impulse: Vector3) -> void:
	release_controls()
	_deck = null
	_deck_coyote = 0.0
	_deck_velocity = Vector3.ZERO
	collider.disabled = false
	velocity = impulse

## Leaves the helm or a station cleanly, eg. when a new day puts us back in bed.
func release_controls() -> void:
	if state == State.PILOT:
		exit_pilot()
	elif state == State.OPERATE:
		exit_station()
	elif state == State.CLIMB:
		_leave_ladder(false)
	state = State.WALK

func _station_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		station.aim(-event.relative.x * mouse_sensitivity, -event.relative.y * mouse_sensitivity)
	elif event is InputEventMouseButton and event.is_action_pressed(&'interact'):
		if station.has_method(&'toggle'):
			station.toggle() # the click that took hold is spent already; the next one flips the switch
	# Let go with jump or the interact key -- not the mouse button, which also means interact.
	elif event.is_action_pressed(&'jump') or (event is InputEventKey and event.is_action_pressed(&'interact')):
		exit_station()
		get_viewport().set_input_as_handled()

## Standing at a station: still carried by the deck and pulled by gravity, but the legs
## stay put.
func _process_operate(delta: float) -> void:
	if not is_instance_valid(station):
		exit_station()
		return
	_carry_with_deck(delta)
	velocity.x = 0.0
	velocity.z = 0.0
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	move_and_slide()
	_update_deck()
