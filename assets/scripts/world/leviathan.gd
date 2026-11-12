class_name Leviathan extends Node3D
## Something ancient and colossal, shaped like a basking shark, that swims half out of the sea with
## its mouth always open. It eats lit ships. LeviathanEncounter brings it: begin() places it deep
## below the surface (it never pops into view) and it plays out one encounter, then frees itself.
## Too big to turn on the spot, it always swims on a curve (tuned in
## backups/leviathan_replays/leviathan_tuning.html, which these defaults come from):
##
##  - RISE: swims up from the deep on a gentle drifting curve. Shortly before it breaks the surface
##    its call is heard (call_lead s ahead), then silence; it surfaces surface_distance_min..max off. Its
##    WaterDeformers swell, break and calm the sea.
##  - DRIFT: the ship is dark, it does not know she is there. Its curve was aimed at spawn to pass
##    dark_gap_min..max off her flank; it passes, then goes down (PASSED, DIVE).
##  - HUNT: the ship is lit: it curves in on her at chase_speed. If she gets inside the circle it
##    can turn, it swims straight out (RUNUP) until she is run_up_margin outside it, then turns in
##    again. Within lunge_distance its head swings round as tight as lunge_turn_radius and the sea
##    flows into its mouth (suction_*), faster than she can sail.
##  - COMMIT: lit inside judge_distance: it comes for her at hunt_speed. Cut the power now and it
##    is too late: it holds its course.
##  - MISS: the power was cut before judge_distance: it carries on past her, cut_gap off its
##    flank, and goes down dive_after_min..max m past her. Lights on again before it goes down: it
##    comes round for her (return_multiplier faster, return_judge_distance, return_turn_radius);
##    cut again in time and it passes return_gap off. A lit ship it missed is hunted again.
##  - DIVE: sinks away to despawn_depth and, once its tail too is under, is gone.
## A lure (group "leviathan_lure") within lure_range draws it while the ship is dark.
## Swallowing: the ship touching its MouthZone (at the end of the throat) is caught there and
## carried with it from then on; nothing ever moves the player, who stays aboard her like on any
## moving deck. The player inside its MouthInside (the mouth cavity) for mouth_time s straight is
## lost: the view fades to black over fade_time s and they die (the same morning restages). Once it
## has caught the ship or the player is in its mouth it swims on slowly dive_delay_min..max s and
## goes down (SWALLOW, then DIVE). A ship it took down without the player is kept until morning.
##
## Body: the Head (mouth at the origin, the body toward +Z) is rigid; the Body's segments are laid
## along the path the head swam, so the long body bends through the curves behind it. A rigged model
## bends the same way: its spine (the bone chain from body_center down to the tail, bones named
## *obsolete* left alone) is turned to follow the path, with a slow tail beat on top. The scene is
## built at MODEL_LENGTH; body_length scales the whole creature.

enum State { RISE, DRIFT, HUNT, RUNUP, COMMIT, MISS, PASSED, DIVE, SWALLOW }

const MODEL_LENGTH := 500.0 # m: the length the scene is built at
const TAKEN_META := &'leviathan_taken' # on a ship it took down: the encounter gives her back at dawn
const TRAIL_STEP := 4.0 # m (model units) between remembered head positions
const MOUTH_REACH := 35.0 # m: the ship this far past the mouth has slipped by
const HEAD_LENGTH := 160.0 # m (model units) from the mouth to where the Body's segments begin

## Length of the body (m). Everything (mouth, turns, water, gullet) scales with it.
@export_range(50.0, 2000.0, 1.0, 'or_greater') var body_length := 500.0
## Body axis height above sea level while at the surface (m). 0 = half out of the water.
@export var surface_offset := 0.0

@export_group('Rising')
## How deep it starts and ends (m below sea level). It starts deeper where it must, for its back
## to be well under and its call to come call_lead s before it shows.
@export var despawn_depth := 250.0
@export var rise_speed := 12.0 # m/s forward while rising
@export var rise_climb := 5.0 # m/s fastest climb; it eases off near the surface
## Seconds to ease out of the climb: higher = a slower, gentler surfacing.
@export var rise_ease := 6.0
## How far from the ship it breaks the surface (m): a random distance between these, measured
## from where she will be by then (sailing toward it doesn't bring it up on top of her).
@export var surface_distance_min := 1500.0
@export var surface_distance_max := 2500.0
## Seconds before it breaks the surface that its call is heard (the call is ~5 s, then silence).
@export var call_lead := 10.0

@export_group('Swimming')
@export var cruise_speed := 9.0 # m/s when it is not after anything
@export var chase_speed := 17.0 # m/s chasing a lit ship
@export var hunt_speed := 20.0 # m/s inside the safe distance
## Speed (and safe distance, turn) once it came back for a ship that lit up again.
@export var return_multiplier := 1.5
@export var acceleration := 0.6 # m/s²
@export var vertical_acceleration := 1.0 # m/s²
## Its gentle drifting curve (m radius) when it is after nothing.
@export var drift_radius := 3000.0
@export var hunt_turn_radius := 500.0 # m, tightest whole-body turn while hunting
@export var return_turn_radius := 600.0 # m, ... coming back
## Seconds to go from straight to its tightest turn.
@export var steer_ease := 8.0
## Most the head tilts nose up or down (degrees) as it climbs or sinks.
@export var max_pitch := 15.0
## Swimming: degrees the tail tip beats to each side at cruise speed (less when slow, a little more
## flat out). The rear of the body bends most, the head swings back a little the other way.
@export var tail_sway := 18.0
## Body lengths it swims per tail beat: the faster it swims, the faster it beats.
@export var tail_stride := 0.35
## Seconds per beat when it barely moves (it never stops beating).
@export var tail_period := 20.0
## How much the head swings against the tail (fraction of the tail's swing).
@export_range(0.0, 1.0, 0.01) var head_recoil := 0.12

@export_group('Collision')
## The model's own collision (its whole mesh at rest: it does not bend). Untick once BodyColliders
## and a head-only collision on the model cover the fish.
@export var model_collision := true

@export_group('Jaw tremble')
## The jaw shakes against the sea pushing into its open mouth (a rigged model's jaw bones).
@export var jaw_shake := true
## The jaw bones (by name). Left out of the spine; only this moves them.
@export var jaw_bones := PackedStringArray(['bone_mouth_top_obsolete', 'bone_mouth_bottom_obsolete'])
## Degrees the jaw shakes at most, at hunting speed.
@export_range(0.0, 15.0, 0.05) var jaw_shake_angle := 1.5
## How much of that is left when it barely moves (0 = still, 1 = as strong as at full speed).
@export_range(0.0, 1.0, 0.01) var jaw_shake_idle := 0.25
## How fast the shaking flickers: higher = a quicker, buzzier tremble.
@export_range(0.1, 40.0, 0.1) var jaw_shake_rate := 6.0
## Share of the shake that opens and closes the jaw (the rest twists it side to side).
@export_range(0.0, 1.0, 0.01) var jaw_shake_hinge := 0.7
## m down the body the beat travels per radian: lower = more of an S-wave along the body.
@export var tail_wave := 120.0

@export_group('Passing by')
## Gaps between its flank and the ship as it passes (m).
@export var dark_gap_min := 100.0 # dark from the start: it never knew she was there
@export var dark_gap_max := 200.0
@export var cut_gap := 50.0 # lights cut in time
@export var return_gap := 30.0 # cut again after it came back
## How far past the ship it goes down (m).
@export var dive_after_min := 200.0
@export var dive_after_max := 500.0
@export var sink_speed := 5.0 # m/s

@export_group('The lunge')
## Within this distance of the ship its head swings round tighter than the body can turn.
@export var lunge_distance := 450.0
@export var lunge_turn_radius := 100.0
## She is inside the circle it can turn: it swims straight until she is this far outside it (m).
@export var run_up_margin := 150.0
## Hunting, the sea flows into its mouth from up to suction_range m ahead (within ±suction_cone
## degrees), at up to suction_flow m/s at the mouth. The ship does 10 m/s flat out.
@export var suction_range := 250.0
@export var suction_flow := 20.0
@export var suction_cone := 60.0

@export_group('Judging the ship')
## Mouth to ship distance (m) inside which cutting the lights is too late.
@export var judge_distance := 200.0
@export var return_judge_distance := 300.0
## A lure (group "leviathan_lure") this close draws it while the ship is dark (m).
@export var lure_range := 400.0

@export_group('Swallowing')
## Seconds the player must be inside its mouth (without getting out) before the dark comes.
@export var mouth_time := 10.0
## Seconds the view takes to fade to black after that; then they die.
@export var fade_time := 3.0
## Seconds after the ship or the player got into its mouth before it goes back down.
@export var dive_delay_min := 3.0
@export var dive_delay_max := 4.0
## m/s it slows to meanwhile, so the walls of its mouth don't sweep through a player aboard.
@export var swallow_speed := 3.0
@export var swallow_shake := 0.3 # camera trauma while the player is in its mouth

var state := State.RISE
var ship: RigidBody3D
var player: Node3D
var water: Node3D

@onready var _head: Node3D = $Head
@onready var _mouth_zone: Area3D = $Head/MouthZone # the end of the throat: catches the ship
@onready var _mouth_inside: Area3D = get_node_or_null(^'Head/MouthInside') # the mouth: the player's countdown
@onready var _call_sound: AudioStreamPlayer3D = get_node_or_null(^'Head/CallSound')
@onready var _surface_sound: AudioStreamPlayer3D = get_node_or_null(^'Head/SurfaceSound')
@onready var _suction_sound: AudioStreamPlayer3D = get_node_or_null(^'Head/SuctionSound')

var _k := 1.0 # body_length / MODEL_LENGTH
var _yaw := 0.0
var _pitch := 0.0
var _speed := 0.0
var _vy := 0.0
var _curve := 0.0 # its turn: yaw change per m swum (1 / radius); + = yaw increasing
var _curve_target := 0.0
var _lit := true
var _returned := false # came back for a ship that lit up again
var _called := false
var _surfaced := false
var _min_d := INF # closest it has been to her on this pass
var _swum := 0.0 # m swum so far
var _passed_at := 0.0
var _dive_after := 0.0
var _drift_passed := false
var _ship_vel := Vector3.ZERO # her velocity, averaged over a few seconds
var _trail := PackedVector3Array() # where the head has been, newest first, TRAIL_STEP apart
var _segments: Array[Node3D] = []
var _seg_offsets: Array[float] = [] # m behind the mouth (model units)
var _tail: Node3D
var _tail_rest := Basis.IDENTITY
var _beat := 0.0 # the tail beat's phase (radians)
var _skel: Skeleton3D # a rigged model's skeleton (null for the placeholder)
var _spine: Array[int] = [] # its spine bones, head to tail
var _spine_s: Array[float] = [] # m behind the mouth of each (model units, at rest)
var _spine_rest: Array[Quaternion] = [] # their rest turn, in the skeleton's space
var _jaw: Array[int] = [] # the jaw bones
var _jaw_rest: Array[Quaternion] = []
var _jaw_noise := FastNoiseLite.new()
var _jaw_t := 0.0
## BodyColliders: each child named after a bone follows that bone (its offset from it at rest).
var _colliders: Array[Node3D] = []
var _collider_bones: Array[int] = []
var _collider_offsets: Array[Transform3D] = []
var _shapes: Array[CollisionShape3D] = [] # every shape of the body colliders, and the box round each
var _shape_boxes: Array[AABB] = []
var _rng := RandomNumberGenerator.new()
var _fed := false # it caught the ship or the player is in its mouth
var _ship_held := false
var _player_on_ship := Vector3.INF # where on the held ship the player last stood (her space)
var _player_held := false # the player is carried inside it with her (see _hold_player())
var _ship_local := Transform3D.IDENTITY # the caught ship, in the head's (unscaled) space
var _dive_in := 0.0 # s left before it goes down after feeding
var _mouth_t := 0.0 # s the player has been inside its mouth, straight
var _fade_t := -1.0 # s into the fade to black (< 0: not started)
var _died := false
var _fade: ColorRect
var _splash: LeviathanSplash # the water its body throws about

## Before its bodies reach the physics engine (they enter the tree after it does).
func _enter_tree() -> void:
	_bake_stretched_shapes()

func _ready() -> void:
	_k = body_length / MODEL_LENGTH
	scale = Vector3.ONE * _k
	_rng.randomize()
	var body := get_node_or_null(^'Body')
	if body:
		for seg in body.get_children():
			if seg is Node3D:
				_segments.append(seg)
				_seg_offsets.append(seg.position.z)
				seg.top_level = true # laid on the path by _place_body
	_head.top_level = true # so is the head
	_tail = find_child('Tail', true, false) as Node3D
	if _tail:
		_tail_rest = _tail.basis
	for d in find_children('*', 'WaterDeformer', true, false):
		_scale_deformer(d)
	# It moves before anything riding it: a ship it holds is in place before the player standing on
	# her is carried along, or each frame the deck runs a frame ahead and shakes them loose.
	process_physics_priority = -10
	# Mesh colliders are solid from both sides: from inside its mouth, nothing slips out through
	# the walls of its head.
	for cs: CollisionShape3D in find_children('*', 'CollisionShape3D', true, false):
		if cs.shape is ConcavePolygonShape3D:
			(cs.shape as ConcavePolygonShape3D).backface_collision = true
	_make_bodies_move()
	_find_spine()
	# a LeviathanSplash child of its own (to tune in the editor), else a default one
	_splash = get_node_or_null(^'LeviathanSplash') as LeviathanSplash
	if _splash == null:
		_splash = LeviathanSplash.new()
		_splash.name = &'LeviathanSplash'
		add_child(_splash)
	_splash.setup(_colliders, _head)
	_mouth_zone.body_entered.connect(_on_throat_body_entered)
	_fill_sounds()
	EventBus.day_started.connect(_on_day_started)

## Places it despawn_depth under the sea, far enough off that it surfaces surface_distance_min..max from
## the ship along `bearing` (a flat direction from the ship), on a curve that would carry it past
## her dark_gap off its flank.
func begin(p_ship: RigidBody3D, p_player: Node3D, p_water: Node3D, bearing: Vector3) -> void:
	ship = p_ship
	player = p_player
	water = p_water
	bearing.y = 0.0
	bearing = bearing.normalized()
	# the run it swims climbing up until its back breaks the surface, and where she'll be by then
	var depth := maxf(despawn_depth, _top() + rise_climb * call_lead + 20.0)
	var rise_time := maxf(depth - _top(), 0.0) / maxf(rise_climb, 0.1)
	var run := rise_time * rise_speed
	var flat_vel := Vector3(ship.linear_velocity.x, 0.0, ship.linear_velocity.z)
	var ship_then := ship.global_position + flat_vel * rise_time
	var dist := _rng.randf_range(minf(surface_distance_min, surface_distance_max), maxf(surface_distance_min, surface_distance_max))
	var origin := ship_then + bearing * (dist + run)
	origin.y = _sea() - depth
	_curve = (1.0 if _rng.randf() < 0.5 else -1.0) / (drift_radius * _k)
	_curve_target = _curve
	# aim the drifting curve so that, unseen, it passes her dark_gap off its flank
	var gap := _rng.randf_range(dark_gap_min, dark_gap_max)
	var at := Vector2(origin.x, origin.z)
	var toward := _yaw_of(-bearing)
	var best_err := INF
	_yaw = toward
	for i in range(-60, 61):
		var yaw := toward + deg_to_rad(i)
		var c := _closest(at, yaw, _curve, Vector2(ship_then.x, ship_then.z), 9000.0)
		var err := absf(c.x - (gap + _side()))
		if c.y > run and err < best_err:
			best_err = err
			_yaw = yaw
	_speed = rise_speed
	_vy = rise_climb
	global_transform = Transform3D(_basis(), origin)
	_lit = _ship_lit()
	# the body lies straight out behind the head
	_trail.clear()
	var back := -_flat_dir(_yaw) * TRAIL_STEP * _k
	for i in int(ceil(_trail_length() / (TRAIL_STEP * _k))) + 2:
		_trail.append(origin + back * i)
	_place_body()
	_set_state(State.RISE)

## Where its mouth is.
func mouth_position() -> Vector3:
	return global_position

func is_swallowing() -> bool:
	return state == State.SWALLOW

func _physics_process(delta: float) -> void:
	if ship == null or water == null or delta <= 0.0:
		return
	var d := _mouth_to_ship()
	var flat_vel := Vector3(ship.linear_velocity.x, 0.0, ship.linear_velocity.z)
	_ship_vel = _ship_vel.lerp(flat_vel, minf(1.0, delta / 5.0))
	var lit := _ship_lit()
	if lit != _lit:
		_lit = lit
		_on_lights()
	var target_speed := cruise_speed * _mult()
	match state:
		State.RISE: target_speed = _process_rise(delta)
		State.DRIFT: _process_drift(d)
		State.HUNT, State.COMMIT: target_speed = _process_hunt(d)
		State.RUNUP: target_speed = _process_runup()
		State.MISS: _process_miss(d)
		State.PASSED: _process_passed()
		State.DIVE:
			if _process_dive(delta):
				return
		State.SWALLOW:
			target_speed = swallow_speed
			_curve_target = 0.0
			_dive_in -= delta
			if _dive_in <= 0.0:
				_set_state(State.DIVE)
	if state != State.RISE and state != State.DIVE:
		_hold_surface(delta)
	# its turn eases toward the one it wants
	var mk := _max_curve()
	_curve += clampf(_curve_target - _curve, -mk * delta / steer_ease, mk * delta / steer_ease)
	_speed = move_toward(_speed, target_speed, acceleration * delta)
	_move(delta)
	# one beat per tail_stride body lengths swum, never slower than tail_period
	_beat += TAU * maxf(_speed / (body_length * tail_stride), 1.0 / tail_period) * delta
	if state != State.RISE:
		_min_d = minf(_min_d, _mouth_to_ship())
	_suck(d)
	_place_body()
	_shake_jaw(delta)
	_place_colliders()
	_sway_tail()
	_splash.track(delta)
	if _ship_held:
		ship.global_transform = _frame() * _ship_local
		_hold_player()
	_watch_mouth(delta)

## ---- states --------------------------------------------------------------------

func _process_rise(delta: float) -> float:
	var gap := _surface_y() - global_position.y
	_climb_to(clampf(gap / rise_ease, 0.0, rise_climb), delta)
	# the call, heard a little before it breaks the surface
	var top := global_position.y + _top()
	var eta := (_sea() - top) / maxf(_vy, 0.5)
	if not _called and eta <= call_lead:
		_called = true
		_play(_call_sound)
	if not _surfaced and top > _sea():
		_surfaced = true
		_play(_surface_sound)
	if _surfaced or gap < 2.0:
		# its back shows: from here it hunts or drifts, still climbing (see _hold_surface)
		_set_state(State.HUNT if _lit else State.DRIFT)
	return rise_speed

## Never knowing she is there, it holds its curve and passes her.
func _process_drift(d: float) -> void:
	_steer_at_lure()
	if not _drift_passed and not _ahead() and d > _min_d + 2.0:
		_drift_passed = true
		_begin_passed()

func _process_hunt(d: float) -> float:
	var speed := (hunt_speed if state == State.COMMIT else chase_speed) * _mult()
	if not _lit:
		return maxf(_speed * 0.999, cruise_speed * _mult()) # too late: it holds its course
	# she is inside the circle it can turn: out, then back at her in a line
	if state == State.HUNT and d > lunge_distance and _facing() > PI / 6.0 and _turn_circle_gap() < 0.0:
		_set_state(State.RUNUP)
		return speed
	if _ship_in_mouth():
		_curve_target = 0.0 # she is in its mouth: straight on, until she is at its throat
		return speed
	# steer for where she will be by the time it gets there
	var t := minf(d / maxf(_speed, 1.0), 20.0)
	var to := ship.global_position + _ship_vel * t - global_position
	var angle := wrapf(_yaw_of(to) - _yaw, -PI, PI)
	var mk := _max_curve()
	_curve_target = clampf(angle / (4.0 * maxf(_speed, 1.0)), -mk, mk)
	var jd := return_judge_distance if _returned else judge_distance
	if state == State.HUNT and d <= jd and _facing() < PI / 4.0:
		_set_state(State.COMMIT)
	elif state == State.COMMIT and not _ahead() and d > MOUTH_REACH * 3.0:
		_min_d = d
		_begin_passed() # she slipped past its mouth: while lit it comes round for her
	_shake_with_closeness(d)
	return speed

func _process_runup() -> float:
	_curve_target = 0.0
	if _turn_circle_gap() > run_up_margin * _k:
		_set_state(State.HUNT)
	return chase_speed * _mult()

func _process_miss(d: float) -> void:
	_steer_at_lure()
	if not _ahead() and d > _min_d + 2.0:
		_begin_passed()

func _process_passed() -> void:
	if _lit:
		_returned = true # lit after it went by: it comes round for her
		_set_state(State.HUNT)
	elif _swum - _passed_at >= _dive_after:
		_set_state(State.DIVE)
	else:
		_steer_at_lure()

## Returns true once it is gone.
func _process_dive(delta: float) -> bool:
	_climb_to(-sink_speed, delta, 0.6)
	if global_position.y < _sea() - despawn_depth and _body_under() and (_fade_t < 0.0 or _died):
		if _ship_held:
			# she stays down there with it, out of sight, until the morning gives her back
			ship.visible = false
			ship.set_meta(TAKEN_META, true)
		if _player_held:
			_let_player_go()
			if not _died:
				_died = true
				EventBus.player_died.emit() # taken down into the deep with her
		queue_free()
		return true
	return false

## All of it is under the sea, by `margin` m: nothing of it is left in sight to vanish. Its tail
## follows the head down a long way behind (and stands tall), so the head is far deeper by then.
func _body_under(margin := 15.0) -> bool:
	var limit := _sea() - margin
	for i in _shapes.size():
		var at := _shapes[i].global_transform
		for corner in 8:
			if (at * _shape_boxes[i].get_endpoint(corner)).y > limit:
				return false
	return true

## The ship's power changed.
func _on_lights() -> void:
	if not _lit and (state == State.HUNT or state == State.RUNUP):
		# in time: it no longer steers for her and carries on past
		_curve_target = _plan_pass(return_gap if _returned else cut_gap)
		_min_d = INF
		_set_state(State.MISS)
	elif _lit and (state == State.DRIFT or state == State.MISS or state == State.PASSED):
		if state != State.DRIFT:
			_returned = true # it had gone by her: it comes round faster
		_set_state(State.HUNT)

func _begin_passed() -> void:
	_passed_at = _swum
	_dive_after = _rng.randf_range(dive_after_min, dive_after_max)
	_set_state(State.PASSED)

func _steer_at_lure() -> void:
	var lure := _lure()
	if lure:
		var angle := wrapf(_yaw_of(lure.global_position - global_position) - _yaw, -PI, PI)
		var mk := _max_curve()
		_curve_target = clampf(angle / (4.0 * maxf(_speed, 1.0)), -mk, mk)

## ---- swallowing ----------------------------------------------------------------

## The ship touched the end of its throat: caught. From now on she moves with it (nothing touches
## the player: aboard, the deck carries them).
func _on_throat_body_entered(body: Node3D) -> void:
	if body != ship or _ship_held or ship.freeze:
		return
	_ship_held = true
	ship.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	ship.freeze = true
	ship.linear_velocity = Vector3.ZERO
	ship.angular_velocity = Vector3.ZERO
	_ship_local = _frame().affine_inverse() * ship.global_transform
	_feed()

## While it holds the ship the player aboard her walks about as they like (the deck carries them).
## Should they come loose from her in its mouth (thrown off by its swing, or her deck going under
## and them floating up off it) it does not let them swim out: they are held where they were on her
## and go wherever she goes. Taken down with her, they die.
func _hold_player() -> void:
	if not is_instance_valid(player) or not player.has_method(&'set_captured'):
		return
	if _player_held:
		player.global_position = ship.global_transform * _player_on_ship
		return
	if player.has_method(&'ship_aboard') and player.ship_aboard() == ship:
		_player_on_ship = ship.global_transform.affine_inverse() * player.global_position
	elif _player_on_ship != Vector3.INF and player.global_position.distance_to(ship.global_transform * _player_on_ship) < 30.0:
		_player_held = true # came loose aboard her, in its mouth
		player.set_captured(true)
		player.global_position = ship.global_transform * _player_on_ship

## Gone for any reason (down into the deep, a new morning): it holds no one any more.
func _exit_tree() -> void:
	_let_player_go()

func _let_player_go() -> void:
	if _player_held and is_instance_valid(player):
		player.set_captured(false)
	_player_held = false

## Caught the ship or has the player in its mouth: it swims on slowly a moment, then goes down.
func _feed() -> void:
	if _fed:
		return
	_fed = true
	_dive_in = _rng.randf_range(dive_delay_min, dive_delay_max)
	if state != State.DIVE:
		_set_state(State.SWALLOW)

## The player in its mouth: the countdown runs (it starts over if they get out); at mouth_time s
## the dark comes, then death. Tested by position, not by the area's signals: at the helm the
## player's own collider is switched off.
func _watch_mouth(delta: float) -> void:
	if _died:
		return
	var player_in := _in_area(_mouth_inside if _mouth_inside else _mouth_zone, player.global_position)
	if player_in:
		_feed()
	if _fade_t < 0.0:
		_mouth_t = _mouth_t + delta if player_in else 0.0
		if player_in:
			EventBus.camera_shake_requested.emit(swallow_shake)
		if _mouth_t >= mouth_time:
			_fade_t = 0.0
			_make_fade()
	else:
		_fade_t += delta
		_fade.modulate.a = clampf(_fade_t / maxf(fade_time, 0.01), 0.0, 1.0)
		if _fade_t >= fade_time:
			_died = true
			EventBus.player_died.emit() # the mission controller restages the morning

## The point is inside one of the area's shapes.
func _in_area(area: Area3D, p: Vector3) -> bool:
	for c in area.get_children():
		var cs := c as CollisionShape3D
		if cs == null or cs.disabled or cs.shape == null:
			continue
		var l := cs.global_transform.affine_inverse() * p
		var sh := cs.shape
		if sh is BoxShape3D:
			var h: Vector3 = (sh as BoxShape3D).size * 0.5
			if absf(l.x) <= h.x and absf(l.y) <= h.y and absf(l.z) <= h.z:
				return true
		elif sh is SphereShape3D:
			if l.length() <= (sh as SphereShape3D).radius:
				return true
		elif sh is CylinderShape3D or sh is CapsuleShape3D:
			if Vector2(l.x, l.z).length() <= sh.radius and absf(l.y) <= sh.height * 0.5:
				return true
	return false

func _make_fade() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 90
	_fade = ColorRect.new()
	_fade.color = Color.BLACK
	_fade.modulate.a = 0.0
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_fade)
	add_child(layer)

## Hunting, the sea runs into its mouth: a current that pushes her toward it (a force: physics
## moves her), up to suction_flow m/s near the mouth.
func _suck(d: float) -> void:
	var reach := suction_range * _k
	var hunting := state == State.HUNT or state == State.COMMIT
	var on := _lit and hunting and not _ship_held and d < reach and d > 1.0 \
			and global_position.y > _sea() - _top() and _facing() < deg_to_rad(suction_cone)
	if on:
		var to := global_position - ship.global_position
		to.y = 0.0
		to = to.normalized()
		var flow := suction_flow * (1.0 - d / reach)
		var along := ship.linear_velocity.dot(to)
		if flow > along:
			ship.apply_central_force(to * (flow - along) / 1.5 * ship.mass)
	_set_suction(on or _mouth_t > 0.0)

## A new morning: it is gone, and its fade with it; a ship it was holding floats free again.
func _on_day_started(_day: int) -> void:
	if _ship_held and is_instance_valid(ship):
		ship.freeze = false
		ship.visible = true
	queue_free()

## ---- movement ------------------------------------------------------------------

## Forward along its heading, turning by its curve, plus its climb or sink. The head is laid down
## on the trail the body follows.
func _move(delta: float) -> void:
	_yaw += _curve * _speed * delta
	global_position += _flat_dir(_yaw) * _speed * delta + Vector3.UP * _vy * delta
	_swum += _speed * delta
	var climb := atan2(_vy, maxf(_speed, 1.0))
	var limit := deg_to_rad(max_pitch)
	_pitch = lerpf(_pitch, clampf(climb, -limit, limit), 1.0 - exp(-0.5 * delta))
	global_basis = _basis()
	if _trail.is_empty() or _trail[0].distance_to(global_position) >= TRAIL_STEP * _k:
		_trail.insert(0, global_position)
		var keep := int(ceil(_trail_length() / (TRAIL_STEP * _k))) + 3
		if _trail.size() > keep:
			_trail.resize(keep)

## Each body segment where the head was, that far back along its path, facing along it.
func _place_body() -> void:
	# for each segment: a little ahead of it, where it is, a little behind it (all in order down the
	# body, so one walk along the trail finds them all)
	var wants := PackedFloat32Array([HEAD_LENGTH * _k])
	var segments: Array[Node3D] = _segments if _body_shown() else ([] as Array[Node3D])
	for i in segments.size():
		var o := _seg_offsets[i]
		var back := o * _k
		wants.append(maxf(back - 6.0 * _k, 0.0))
		wants.append(back)
		wants.append(back + 6.0 * _k)
	var pts := _trail_points(wants)
	var s := Vector3.ONE * _k
	# the head lies from the mouth back to its neck on the path, so it meets the body on a bend
	var head_dir := global_position - pts[0]
	if head_dir.length() > 0.01:
		_head.global_transform = Transform3D(Basis.looking_at(head_dir.normalized(), Vector3.UP).scaled(s), global_position)
	for i in segments.size():
		var dir := pts[1 + i * 3] - pts[1 + i * 3 + 2]
		if dir.length() < 0.01:
			dir = _flat_dir(_yaw)
		segments[i].global_transform = Transform3D(Basis.looking_at(dir.normalized(), Vector3.UP).scaled(s), pts[1 + i * 3 + 1])
	_pose_spine()

## The placeholder body is in use (a rigged model hides it and bends itself).
func _body_shown() -> bool:
	var body := get_node_or_null(^'Body') as Node3D
	return body != null and body.visible

## The rigged spine: each bone turned the way the path runs where it is (relative to the way the
## head faces), so on a straight course it is the rest pose and on a curve the body bends through
## it. The tail beats slowly on top, growing toward the tail and travelling down the body.
func _pose_spine() -> void:
	if _spine.is_empty():
		return
	var wants := PackedFloat32Array()
	var last := 0.0
	for sb in _spine_s:
		for w in [maxf(sb * _k - 6.0 * _k, 0.0), sb * _k + 6.0 * _k]:
			last = maxf(last, w) # ascending, for one walk along the trail
			wants.append(last)
	var pts := _trail_points(wants)
	var ahead := -global_basis.z.normalized() # the way the head faces
	var sk_rot := _skel.global_basis.orthonormalized().get_rotation_quaternion()
	var sk_inv := sk_rot.inverse()
	var swing := deg_to_rad(tail_sway) * clampf(0.4 + 0.6 * _speed / maxf(cruise_speed, 0.1), 0.4, 1.25)
	var placed := {}
	for i in _spine.size():
		var along := pts[i * 2] - pts[i * 2 + 1] # the path here, toward the head
		var turn := Quaternion(ahead, along.normalized()) if along.length() > 0.01 else Quaternion.IDENTITY
		# a shark's beat: the rear of the body bends most, the head swings back a little against it
		var t := clampf(_spine_s[i] / MODEL_LENGTH, 0.0, 1.0)
		var reach := t * t - head_recoil * (1.0 - t) * (1.0 - t)
		turn = Quaternion(Vector3.UP, swing * reach * sin(_beat - _spine_s[i] / tail_wave)) * turn
		var g := (sk_inv * turn * sk_rot) * _spine_rest[i] # its turn in the skeleton's space
		var b := _spine[i]
		var parent := _skel.get_bone_parent(b)
		var pg: Quaternion = placed.get(parent, _skel.get_bone_global_rest(parent).basis.get_rotation_quaternion() if parent >= 0 else Quaternion.IDENTITY)
		_skel.set_bone_pose_rotation(b, (pg.inverse() * g).normalized())
		placed[b] = g

## Each body collider where its bone is now, so the collision bends with the body.
func _place_colliders() -> void:
	for i in _colliders.size():
		_colliders[i].global_transform = _skel.global_transform * _skel.get_bone_global_pose(_collider_bones[i]) * _collider_offsets[i]

## The jaw trembles on smooth noise, harder the faster it swims: each jaw bone turned a little from
## its rest pose, mostly about its hinge (its own X), the rest a side-to-side twist.
func _shake_jaw(delta: float) -> void:
	if _jaw.is_empty():
		return
	if not jaw_shake:
		for i in _jaw.size():
			_skel.set_bone_pose_rotation(_jaw[i], _jaw_rest[i])
		return
	_jaw_t += delta * jaw_shake_rate
	var effort := clampf(_speed / maxf(hunt_speed, 0.1), 0.0, 1.0)
	var amount := deg_to_rad(jaw_shake_angle) * lerpf(jaw_shake_idle, 1.0, effort)
	for i in _jaw.size():
		var hinge := _jaw_noise.get_noise_2d(_jaw_t, i * 97.0) * amount * jaw_shake_hinge
		var twist := _jaw_noise.get_noise_2d(_jaw_t, i * 97.0 + 41.0) * amount * (1.0 - jaw_shake_hinge)
		_skel.set_bone_pose_rotation(_jaw[i], _jaw_rest[i] * Quaternion(Vector3.RIGHT, hinge) * Quaternion(Vector3.UP, twist))

## A rigged model: its spine is the chain from the bone named body_center down to the tail (bones
## named *obsolete*, the jaw, are left alone).
func _find_spine() -> void:
	for sk: Skeleton3D in find_children('*', 'Skeleton3D', true, false):
		var b := sk.find_bone('body_center')
		if b < 0:
			continue
		_skel = sk
		for jaw_name in jaw_bones:
			var j := sk.find_bone(jaw_name)
			if j >= 0:
				_jaw.append(j)
				_jaw_rest.append(sk.get_bone_rest(j).basis.get_rotation_quaternion())
		_jaw_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_jaw_noise.frequency = 1.0
		_jaw_noise.seed = _rng.randi()
		var holder := get_node_or_null(^'BodyColliders')
		if holder:
			for c in holder.get_children():
				var bone := sk.find_bone(c.name)
				if c is Node3D and bone >= 0:
					_colliders.append(c)
					_collider_bones.append(bone)
					_collider_offsets.append((sk.global_transform * sk.get_bone_global_rest(bone)).affine_inverse() * c.global_transform)
					(c as Node3D).top_level = true
					for cs in c.get_children():
						if cs is CollisionShape3D and cs.shape:
							_shapes.append(cs)
							_shape_boxes.append((cs.shape as Shape3D).get_debug_mesh().get_aabb())
		var to_root := global_transform.affine_inverse() * sk.global_transform
		while b >= 0:
			_spine.append(b)
			var rest := sk.get_bone_global_rest(b)
			_spine_s.append(maxf((to_root * rest.origin).z, 0.0))
			_spine_rest.append(rest.basis.get_rotation_quaternion())
			var next := -1
			for c in sk.get_bone_children(b):
				if not sk.get_bone_name(c).contains('obsolete'):
					next = c
					break
			b = next
		# a bent body reaches outside its rest box: don't let it be culled while still in view
		for m: MeshInstance3D in sk.find_children('*', 'MeshInstance3D', true, false):
			m.extra_cull_margin = MODEL_LENGTH * 0.5
		return

## The points `wants` m (ascending) behind the mouth along the path it swam.
func _trail_points(wants: PackedFloat32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var prev := global_position
	var walked := 0.0
	var j := 0
	var w := 0
	while w < wants.size():
		if j < _trail.size():
			var l := prev.distance_to(_trail[j])
			if walked + l >= wants[w] and l > 0.0001:
				out.append(prev.lerp(_trail[j], (wants[w] - walked) / l))
				w += 1
				continue
			walked += l
			prev = _trail[j]
			j += 1
		else:
			out.append(prev - _flat_dir(_yaw) * (wants[w] - walked)) # past the end: straight on
			w += 1
	return out

func _trail_length() -> float:
	var longest := MODEL_LENGTH
	for o in _seg_offsets:
		longest = maxf(longest, o + 40.0)
	for o in _spine_s:
		longest = maxf(longest, o + 40.0)
	return longest * _k

func _basis() -> Basis:
	return Basis.from_euler(Vector3(_pitch, _yaw, 0.0)).scaled(Vector3.ONE * _k)

func _climb_to(target: float, delta: float, accel := -1.0) -> void:
	_vy = move_toward(_vy, target, (vertical_acceleration if accel < 0.0 else accel) * delta)

func _hold_surface(delta: float) -> void:
	_climb_to(clampf((_surface_y() - global_position.y) / rise_ease, -2.0, rise_climb), delta)

func _sway_tail() -> void:
	if _tail:
		var a := deg_to_rad(tail_sway) * sin(_beat)
		_tail.basis = _tail_rest.rotated(Vector3.UP, a)

## Tightest turn it can make right now, as a curve (1 / radius).
func _max_curve() -> float:
	var r := (return_turn_radius if _returned else hunt_turn_radius) * _k
	var hunting := state == State.HUNT or state == State.COMMIT
	if _lit and hunting and _mouth_to_ship() < lunge_distance:
		r = minf(r, lunge_turn_radius * _k)
	return 1.0 / maxf(r, 1.0)

## How far she is outside the circle it can turn toward her (m; negative = inside: it cannot reach
## her by turning).
func _turn_circle_gap() -> float:
	var r := 1.0 / _max_curve()
	var to := _ship2() - _pos2()
	var f := _flat2(_yaw)
	var n := to - f * to.dot(f)
	n = n.normalized() if n.length() > 0.01 else Vector2(-f.y, f.x)
	return _ship2().distance_to(_pos2() + n * r) - r

## Closest a path of constant curve passes `target`: (distance, m along the path to it).
func _closest(at: Vector2, yaw: float, curve: float, target: Vector2, max_s: float) -> Vector2:
	var best := INF
	var best_s := 0.0
	var s := 0.0
	var step := 16.0
	while s < max_s:
		var d := at.distance_to(target)
		if d < best:
			best = d
			best_s = s
		elif d > best + 400.0:
			break
		if absf(curve * s) > PI * 1.2:
			break
		yaw += curve * step
		at += _flat2(yaw) * step
		s += step
	return Vector2(best, best_s)

## A curve (within its tightest turn) that carries it past her `gap` m off its flank, changing its
## turn as little as it can.
func _plan_pass(gap: float) -> float:
	var want := gap + _side()
	var mk := _max_curve()
	var best := _curve
	var best_err := INF
	for i in range(-40, 41):
		var c := mk * i / 40.0
		var r := _closest(_pos2(), _yaw, c, _ship2(), 6000.0)
		if r.y < 1.0:
			continue
		var err := absf(r.x - want) + absf(c - _curve) * 2000.0
		if err < best_err:
			best_err = err
			best = c
	return best

## ---- reading the world ---------------------------------------------------------

func _sea() -> float:
	return water.global_position.y

func _surface_y() -> float:
	return _sea() + surface_offset * _k

## A rough half-thickness, for a body with no colliders to measure.
func _radius() -> float:
	return body_length * 0.1

## How far its back stands above its axis and its flank is from it (m), measured from its colliders.
func _top() -> float:
	return _splash.body_top if _splash and _splash.body_top > 0.0 else _radius()

func _side() -> float:
	return _splash.body_side if _splash and _splash.body_side > 0.0 else _radius()

func _mult() -> float:
	return return_multiplier if _returned else 1.0

func _ship_lit() -> bool:
	return ship.get(&'powered') != false

func _pos2() -> Vector2:
	return Vector2(global_position.x, global_position.z)

func _ship2() -> Vector2:
	return Vector2(ship.global_position.x, ship.global_position.z)

func _mouth_to_ship() -> float:
	return _pos2().distance_to(_ship2())

## She is inside its mouth (not yet caught at its throat).
func _ship_in_mouth() -> bool:
	return _in_area(_mouth_inside if _mouth_inside else _mouth_zone, ship.global_position)

## She is in front of its mouth.
func _ahead() -> bool:
	return (_ship2() - _pos2()).dot(_flat2(_yaw)) > 0.0

## Angle between its heading and the way to her (radians).
func _facing() -> float:
	var to := _ship2() - _pos2()
	return absf(wrapf(_yaw_of(Vector3(to.x, 0.0, to.y)) - _yaw, -PI, PI))

func _lure() -> Node3D:
	var best: Node3D = null
	var best_d := lure_range
	for n in get_tree().get_nodes_in_group(&'leviathan_lure'):
		var d := (n as Node3D).global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best = n
	return best

func _shake_with_closeness(d: float) -> void:
	var reach := return_judge_distance if _returned else judge_distance
	if d < reach:
		EventBus.camera_shake_requested.emit(lerpf(0.05, 0.4, 1.0 - d / reach))

static func _yaw_of(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)

static func _flat_dir(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))

static func _flat2(yaw: float) -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))

func _set_state(s: State) -> void:
	state = s

## ---- set-up --------------------------------------------------------------------

## A model's collision usually imports as StaticBody3D, which is meant to stand still: moved with the
## creature it jumps from place to place and throws whatever it lands on. AnimatableBody3D is the
## moving kind: it pushes and carries what it touches. Swapped here, so a re-imported model needs
## nothing done to it.
## The physics engine can't stretch a collision shape unevenly (a model whose scale was never
## applied): it would fall back to an even scale, and the collision would no longer match what is
## seen. So the shapes are rebuilt with the stretch baked in, on a body with no stretch at all.
func _make_bodies_move() -> void:
	for body: StaticBody3D in find_children('*', 'StaticBody3D', true, false):
		if body is AnimatableBody3D:
			continue # already a moving body (BodyColliders' capsules)
		if not model_collision:
			body.get_parent().remove_child(body)
			body.free()
			continue
		var mover := AnimatableBody3D.new()
		mover.name = body.name
		mover.collision_layer = body.collision_layer
		mover.collision_mask = body.collision_mask
		mover.physics_material_override = body.physics_material_override
		mover.sync_to_physics = false # moved from our _physics_process
		add_child(mover) # under the root: its scale is even
		var at := body.global_transform
		mover.global_transform = Transform3D(at.basis.orthonormalized(), at.origin)
		for c in body.get_children():
			var cs := c as CollisionShape3D
			if cs == null or cs.shape == null:
				continue
			var xf := mover.global_transform.affine_inverse() * cs.global_transform
			var copy := CollisionShape3D.new()
			copy.name = cs.name
			copy.disabled = cs.disabled
			var baked := _bake_shape(cs.shape, xf)
			if baked:
				copy.shape = baked
			else:
				copy.shape = cs.shape
				copy.transform = xf
			mover.add_child(copy)
		body.get_parent().remove_child(body)
		body.free()

## The same goes for BodyColliders: a capsule, cylinder or sphere stretched more one way than
## another (to fit the body) can't be stretched so by the physics engine, which would even the
## stretch out. Each is rebuilt as a hull of its stretched surface, so it collides as it is drawn.
func _bake_stretched_shapes() -> void:
	var holder := get_node_or_null(^'BodyColliders')
	if holder == null:
		return
	for cs: CollisionShape3D in holder.find_children('*', 'CollisionShape3D', true, false):
		var shape := cs.shape
		if not (shape is CapsuleShape3D or shape is CylinderShape3D or shape is SphereShape3D):
			continue
		var stretch := cs.basis.get_scale().abs()
		if maxf(stretch.x, maxf(stretch.y, stretch.z)) < minf(stretch.x, minf(stretch.y, stretch.z)) * 1.01:
			continue
		var points := LeviathanSplash.shape_points(shape, 1.0)
		for i in points.size():
			points[i] *= stretch
		var hull := ConvexPolygonShape3D.new()
		hull.points = points
		cs.shape = hull
		var turn := cs.basis.orthonormalized() # its turn alone, the stretch now in the hull
		if turn.determinant() < 0.0:
			turn.x = -turn.x # mirrored: the same shape, these being alike on both sides
		cs.basis = turn

## The shape with `xf` (position, turn and any stretch) built into its points; null for shapes
## made of no points (box, sphere...), which keep a transform instead.
func _bake_shape(shape: Shape3D, xf: Transform3D) -> Shape3D:
	if shape is ConcavePolygonShape3D:
		var faces := (shape as ConcavePolygonShape3D).get_faces()
		for i in faces.size():
			faces[i] = xf * faces[i]
		var concave := ConcavePolygonShape3D.new()
		concave.backface_collision = true # solid from both sides: nothing slips through its walls
		concave.set_faces(faces)
		return concave
	if shape is ConvexPolygonShape3D:
		var points := (shape as ConvexPolygonShape3D).points
		for i in points.size():
			points[i] = xf * points[i]
		var convex := ConvexPolygonShape3D.new()
		convex.points = points
		return convex
	return null

## The head's own frame, without its scale: what the caught ship is held in.
func _frame() -> Transform3D:
	return Transform3D(_head.global_basis.orthonormalized(), _head.global_position)

## The water shapes are in world meters: grow them with the body.
func _scale_deformer(d: WaterDeformer) -> void:
	d.radius *= _k
	d.max_lift *= _k
	d.influence_depth *= _k
	d.max_drawdown *= _k
	d.rebound_height *= _k
	d.ring_amplitude *= _k
	d.ring_width *= _k
	d.ring_speed *= sqrt(_k)

## The suction's roar. Decided once a frame (in _suck): two callers that disagree would restart it
## every frame, a buzz.
func _set_suction(on: bool) -> void:
	if _suction_sound == null or _suction_sound.stream == null:
		return
	if on and not _suction_sound.playing:
		_suction_sound.play()
	elif not on and _suction_sound.playing:
		_suction_sound.stop()

func _play(p: AudioStreamPlayer3D) -> void:
	if p and p.stream:
		p.play()

## Placeholder sounds for any player still without a stream (see SOUNDS.md).
func _fill_sounds() -> void:
	for sound: AudioStreamPlayer3D in [_call_sound, _surface_sound, _suction_sound]:
		if sound and sound.stream == null:
			warm_sounds()
			sound.stream = _placeholder_sounds[sound.name]

static var _placeholder_sounds := {} # by the name of the player they are for; made once a game

## Makes the placeholder sounds, once. It takes a moment (~60 ms): LeviathanEncounter calls this as
## the game loads, so it is not paid as a stutter when the creature appears.
static func warm_sounds() -> void:
	if _placeholder_sounds.is_empty():
		_placeholder_sounds = {&'CallSound': _make_call(), &'SurfaceSound': _make_noise(7.0, 0.02, false),
				&'SuctionSound': _make_noise(4.0, 0.05, true)}

const RATE := 22050

## A long, low moan, falling and rising, like something singing very far down.
static func _make_call() -> AudioStreamWAV:
	var seconds := 5.0
	var frames := int(RATE * seconds)
	var data := PackedByteArray()
	data.resize(frames * 2)
	var phase := 0.0
	for i in frames:
		var t := float(i) / RATE
		var env := smoothstep(0.0, 0.8, t) * (1.0 - smoothstep(3.6, 5.0, t))
		var freq := 55.0 + 18.0 * sin(t * 1.3) - 8.0 * t
		phase += TAU * freq / RATE
		var s := sin(phase) * 0.6 + sin(phase * 2.01) * 0.25 + sin(phase * 3.03) * 0.12
		s *= env * (0.85 + 0.15 * sin(t * 23.0))
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 22000.0))
	return _wav(data, false)

## Low rushing water: filtered noise (`smooth` = one-pole filter weight; lower = deeper).
static func _make_noise(seconds: float, smooth: float, loop: bool) -> AudioStreamWAV:
	var frames := int(RATE * seconds)
	var data := PackedByteArray()
	data.resize(frames * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var y := 0.0
	for i in frames:
		var t := float(i) / RATE
		y = lerpf(y, rng.randf_range(-1.0, 1.0), smooth)
		var env := 1.0 if loop else smoothstep(0.0, 0.3, t) * (1.0 - smoothstep(2.0, seconds, t))
		data.encode_s16(i * 2, int(clampf(y * 6.0 * env, -1.0, 1.0) * 20000.0))
	return _wav(data, loop)

static func _wav(data: PackedByteArray, loop: bool) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = data.size() / 2
	return wav
