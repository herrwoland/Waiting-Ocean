class_name KrakenArm extends RefCounted
## One arm of the Kraken, moved entirely in code.
##
## Built on how octopus arms actually move. An arm is a muscular hydrostat:
## no skeleton, and its stiffness falls steeply toward the thin tip, so the
## base stays long and nearly straight while the distal part does the
## curling. Reaching is a bend that travels from the base out to the tip
## (Gutfreund 1996, Sumbre 2001) — behind the bend the arm is straight and
## aimed, ahead of it the tip stays rolled; grasping is the tip coiling round
## the prey while the base positions it (Sumbre 2005). And a body this big
## moves slowly: everything eases, nothing snaps.
##
## So the arm is a chain of joints, each holding a bend (a swing away from
## the bone before it — no twist). Every frame:
##  1. the Kraken gives a goal shape (points in the world: trailing, wrapped
##     round a rock, aimed at the prey, gripping a hull);
##  2. that shape becomes a target bend per joint, walked from the root, each
##     clamped to the joint's limit — tiny near the body, large at the tip;
##  3. the targets are smoothed along the arm, so it always forms curves, and
##     special shapes are laid over them (the rolled tip ahead of a reach, a
##     coil round a held body);
##  4. each joint eases toward its target on a critically damped spring —
##     slow, no overshoot, no shiver;
##  5. the chain is rebuilt from the root and the bones are posed.
##
## Expects one bone chain per arm, root first, each bone's +Y running toward
## the tip, bones shortening toward the tip (see
## kraken/source/build_kraken_placeholder.py for the convention).

enum Role { FREE, REACH, HOLD, BOAT, RECOIL, FISH, CRAWL } # CRAWL: a foot on the rock (gripped = planted)

var skeleton: Skeleton3D
var index := 0 # which arm round the crown, 0..
var bones: PackedInt32Array # root to tip
var length := 0.0 # m, root to tip
var along: PackedFloat32Array # m from the root to each point (one per joint, plus the tip)
var points: PackedVector3Array # world, rebuilt every frame: joints, then the tip
var goals: PackedVector3Array # world, the shape the Kraken wants this frame
var root_radius := 1.35 # m, the arm's thickness at the root...
var tip_radius := 0.12 # ...and at the tip; wraps keep the arm on a surface, not in it

## Bend limits. Joint 0 is the arm's swing at the crown; after it the limit
## per joint grows from bend_root to bend_tip (radians) along the arm.
var swing_limit := deg_to_rad(40.0)
var bend_root := deg_to_rad(4.0)
var bend_tip := deg_to_rad(50.0)
var bend_exponent := 1.5 # >1: the limit stays small for longer before rising toward the tip
## How quickly the joints follow (natural frequency of their springs, rad/s).
## About 1 means a change takes ~3-4 s to settle. Set per role by the Kraken.
var response := 0.8
## Fastest any joint turns (rad/s). Joint motions add up toward the tip, so
## this is what keeps a 50 m arm from whipping.
var max_joint_speed := deg_to_rad(18.0)
## Fastest the tip may travel relative to the body (m/s).
var max_tip_speed := 14.0
## 0..1: how much of last frame's shape the goal keeps — the water holding a
## loose arm back as the body turns, so it trails instead of swinging stiffly.
var inertia := 0.0
## Holding: joints whose middle lies past curl_from meters coil at curl_rate
## radians per meter (a coil of radius 1/curl_rate). -1 = no coil.
var curl_from := -1.0
var curl_rate := 0.0
## x how quickly the coiling joints follow and how fast they may turn: the light tip snaps shut
## round what it holds while the rest of the arm moves slowly.
var curl_quick := 1.0
## World axis the coil winds round (a held body's spine); ZERO = whichever way the joints bend.
var curl_axis := Vector3.ZERO
## The coil keeps the shape it has now, in the arm's own frame (no longer turned after curl_axis):
## closed round a body, it goes as the arm goes, instead of turning round on itself as the arm
## swings and the axis falls another way in it.
var curl_hold := false
var _curl_shape := PackedVector2Array() # per joint: the coil's bend, kept while curl_hold
## Reaching: the bend front, 0..1 along the arm. Joints behind it aim at the
## goal; joints past it stay rolled up. 1 = no front (the whole arm aims).
var reach_front := 1.0
## Smoothing passes along the arm (curves). A grip lies on its route exactly: 0.
var smooth_passes := 2

var role := Role.FREE
var pin_tip := false # BOAT, gripped: the tip is held exactly on tip_target
var pin_joints := 7 # how many of the last joints turn to keep a pinned tip on
## 1/s how quickly a pinned tip is brought onto its spot (0 = at once). Eased,
## the arm never jumps in a frame when it takes hold.
var pin_rate := 0.0
var pin_max_turn := 0.0 # radians a pinning joint may turn in one frame at most (0 = no limit)
var limit_whole_arm := false # cap every point's speed, not only the tip's
## Holding on along a route (goals_path), the part of the arm on the route is
## laid exactly onto it every frame instead of chasing it on its springs: an
## arm wrapped round a rolling hull goes with her, never through her.
var lay_on_path := false
## 1/s the joints ease onto the laid path (0 = exactly, at once).
var lay_rate := 0.0
## Optional: (world point, thickness) -> how far it must move to be clear of
## the stone (ZERO = clear). Last thing each frame, a joint whose next point
## would lie in the stone turns out of it, within its limit.
var keep_out := Callable()
const STONE_GIVE := 3.0
const BOW_SKEW := 1.7 # >1: a bowed arm's belly sits past its middle (1 = an even arc)
const STONE_SPEED := 4.0 # x max_joint_speed: how fast a joint may turn out of the stone
## BOAT, not yet holding: meters its tip has climbed up its route from the
## bottom (under her keel) toward the grip spot; < 0 = still coming up to it.
var climb := -1.0
var _path_from := -1 # the first goal point that lies on the route (goals_path)
const PIN_DISTAL := 7 # the light end that holds a pinned tip exactly
const PIN_BASE_EASE := 0.12 # the heavier joints behind it lean this much of the way each frame
## The tip homing in on tip_target with its last joints (1/s, 0 = off): the
## fine finish of a reach, done by the light distal arm.
var seek_tip := 0.0
var tip_target := Vector3.ZERO # world
## BOAT: its route onto the hull, in the ship's local space, from the tip's
## hold on the deck back down the outside of the hull and under the keel.
var hull_path := PackedVector3Array()
var timer := 0.0 # seconds in the current role
var gripped := false # BOAT: the tip has hold of the hull
var fish_station := 0.5 # FISH: where along the fish (snout 0 .. tail 1) it coils

var _n := 0 # joints (= bones)
var _segments: PackedFloat32Array # m, bone lengths
var _limit: PackedFloat32Array # radians, per joint
var _bend: PackedVector2Array # current bend per joint: rotation vector (x, z) in the frame before it
var _vel: PackedVector2Array
var _target: PackedVector2Array
var _rest_local: Array[Basis] = [] # each bone's rest rotation against its parent
var _base: Basis # skeleton space: joint 0's frame before its bend (the crown socket)
var _root_origin: Vector3 # skeleton space
var _frames: Array[Basis] = [] # skeleton space, per bone, from the last rebuild
var _pos: PackedVector3Array # skeleton space, joints then the tip
var _world := 1.0 # world meters per skeleton unit (the model's scale in its scene)
## Loose arms never move in step: each has its own tempo and phases (set from its index).
var _tempo := 1.0
var _ph_a := 0.0
var _ph_b := 0.0
## How much a loose arm wanders (goals_spread): 0 = straight, as it used to be.
var sway := 1.0
## Loose, the tip rolls into a slow spiral (0..1), toward _curl_world; set by goals_spread.
var idle_curl := 0.0
var _curl_world := Vector3.ZERO
## Loose arms give a little past their goal and swing back at the thin end (soft tissue);
## an arm with a job to do never does.
var soft := false
## Keeping clear of the other arms: an offset per point (world, m) the Kraken adds to when two
## arms lie in each other; it is laid over the goals and fades by itself.
var avoid := PackedVector3Array()
var _lay_shape := PackedVector3Array() # the shape a laid arm is laid on this frame (goals + avoid)
var _drag := PackedFloat32Array() # per point: how much of the water's hold it feels (the thin end most)
var _frac := PackedFloat32Array() # per point: how far along the arm it is, 0..1
var _swell := PackedFloat32Array() # per point: how much of a loose arm's wave it takes (grows toward the tip)
var _local: Array[Basis] = [] # per bone: its pose against its parent, from the last full rebuild
var _local_fresh := false # nothing has turned a joint since
var _parent_basis := Basis.IDENTITY # skeleton space: what joint 0 hangs from
var avoid_live := false
const AVOID_FADE := 0.35 # 1/s
const TELEPORT := 30.0 # a root jump this big in one step starts the arm over

func _init(target: Skeleton3D, arm_index: int, chain: PackedInt32Array) -> void:
	skeleton = target
	index = arm_index
	bones = chain
	_n = bones.size()
	for k in _n:
		_rest_local.append(skeleton.get_bone_rest(bones[k]).basis.orthonormalized())
	for k in _n - 1:
		_segments.append(skeleton.get_bone_global_rest(bones[k]).origin.distance_to(
			skeleton.get_bone_global_rest(bones[k + 1]).origin))
	# The tip bone's length is not stored in the rig: carry the taper on.
	var last := _segments[-1] if _n > 1 else 1.0
	if _n > 2 and _segments[-2] > 0.0:
		last = _segments[-1] * _segments[-1] / _segments[-2]
	_segments.append(last)
	# The model may be scaled in its scene: goals, lengths and radii are world
	# meters, the chain itself is built in the skeleton's own units.
	_world = skeleton.global_transform.basis.get_scale().x
	along.append(0.0)
	for s in _segments:
		length += s * _world
		along.append(length)
	var parent := skeleton.get_bone_parent(bones[0])
	var parent_basis := skeleton.get_bone_global_rest(parent).basis.orthonormalized() if parent >= 0 else Basis.IDENTITY
	_base = parent_basis * _rest_local[0]
	_parent_basis = parent_basis
	_local.resize(_n)
	_root_origin = skeleton.get_bone_global_rest(bones[0]).origin
	_bend.resize(_n)
	_vel.resize(_n)
	_target.resize(_n)
	_frames.resize(_n)
	_pos.resize(_n + 1)
	points.resize(_n + 1)
	goals.resize(_n + 1)
	avoid.resize(_n + 1)
	for d in along:
		var t := d / length
		_frac.append(t)
		_drag.append(0.45 + 0.7 * t)
		_swell.append(t * sqrt(t))
	var h := float(arm_index) * 2.399963 # the golden angle: no two arms alike, none in step
	_tempo = 0.8 + 0.45 * fposmod(h * 0.618, 1.0)
	_ph_a = h
	_ph_b = h * 1.7 + 1.0
	configure()
	_rebuild()
	goals = points.duplicate()

## Recompute the per-joint limits after changing swing_limit / bend_*.
func configure() -> void:
	_limit.resize(_n)
	for k in _n:
		if k == 0:
			_limit[k] = maxf(swing_limit, _spread_swing) # spread flat from the web, crawling
		else:
			var t := (along[k] + _segments[k] * _world * 0.5) / length
			_limit[k] = lerpf(bend_root, bend_tip, pow(t, bend_exponent))
			if _tight > 1.0:
				_limit[k] = minf(_limit[k] * _tight, _tight_cap)

## Holding on, an arm clamps down: its joints may bend this much more, so it
## wraps tightly round what it holds instead of cutting across its corners.
const TIGHT_FACTOR := 2.0
var _tight := 1.0
var _tight_cap := deg_to_rad(100.0) # the most any joint bends, clamped down
var _spread_swing := 0.0
## Crawling with its crown on the rock, the arms leave the web flat out over
## the stone: the joint at the crown may swing this far (radians, 0 = as usual).
func set_spread(swing: float) -> void:
	if not is_equal_approx(swing, _spread_swing):
		_spread_swing = swing
		configure()
func set_tight(on: bool, factor := TIGHT_FACTOR, cap := deg_to_rad(100.0)) -> void:
	var f := factor if on else 1.0
	if not is_equal_approx(f, _tight) or not is_equal_approx(cap, _tight_cap):
		_tight = f
		_tight_cap = cap
		configure()

func root() -> Vector3:
	return skeleton.global_transform * _root_origin

func tip() -> Vector3:
	return points[-1]

## Thickness at a point, so wraps sit on the rock's skin instead of inside it.
func radius_at(i: int) -> float:
	return lerpf(root_radius, tip_radius, pow(along[i] / length, 0.8))

func set_role(new_role: Role) -> void:
	role = new_role
	timer = 0.0
	gripped = false
	pin_tip = false
	pin_rate = 0.0
	pin_max_turn = 0.0
	limit_whole_arm = false
	lay_on_path = false
	climb = -1.0
	set_tight(false)
	set_spread(0.0)
	seek_tip = 0.0
	curl_from = -1.0
	curl_axis = Vector3.ZERO
	curl_hold = false
	curl_quick = 1.0
	reach_front = 1.0
	idle_curl = 0.0
	if new_role == Role.BOAT:
		tip_target = tip() # the reach for the hull starts from wherever the tip is now

## Where a held body sits: the centre of the coil (world). Valid while
## curl_from >= 0. Uses the coil the joints can really make: short of bones
## or bend, it is wider than asked for.
func coil_center() -> Vector3:
	for k in _n:
		var seg := _segments[k] * _world
		if along[k] + seg * 0.5 > curl_from:
			var before := _base if k == 0 else _frames[k - 1] * _rest_local[k]
			var bend := minf(curl_rate * seg, _limit[k])
			var radius := seg / maxf(bend, 0.01) / _world # in skeleton units
			return skeleton.global_transform * (_pos[k] + before.z.normalized() * radius)
	return tip()

## Where a held body's middle sits in the coil as the arm really is now (world): see coil_frame().
func coil_seat() -> Vector3:
	return coil_frame(Vector3.UP).origin

## The bone in the middle of the coil (its index in `bones`), -1 when not coiling: a held body,
## once the coil has closed round it, rides on it.
func coil_bone() -> int:
	var first := _coil_first()
	return -1 if first < 0 else (first + _n) / 2

## Whether the coil has closed: every winding joint is bent as far as it is going to (however it
## is still turning about; not the first, which only lays the arm flat into it).
func coil_closed(tolerance := deg_to_rad(10.0)) -> bool:
	var first := _coil_first()
	if first < 0:
		return false
	for k in range(first + 1, _n):
		if _bend[k].length() < _target[k].length() - tolerance:
			return false
	return true

## From now on the coil keeps the shape it has (see curl_hold).
func hold_curl() -> void:
	_curl_shape = _bend.duplicate()
	curl_hold = true

## Bone k's place and turn in the world (unscaled; +Y along the arm toward the tip).
func bone_transform(k: int) -> Transform3D:
	var xf := skeleton.global_transform
	return Transform3D((xf.basis * _frames[k]).orthonormalized(), xf * _pos[k])

## The first coiling joint, or -1.
func _coil_first() -> int:
	if curl_from < 0.0:
		return -1
	for k in _n:
		if along[k] + _segments[k] * _world * 0.5 > curl_from:
			return k
	return -1

## The held body's place and turn in the coil as the arm really is now (world). Its place is the
## middle of the coil: in the plane the coil winds in, as far from every side of it (the arm's
## skin) as it can be. Its up is square to that plane, on the side of up_hint so the body does not
## flip over -- unless the rest of the arm is well over on that side: then it turns over, so the
## arm comes in past the feet, never through the chest or the view. Its left toward where the arm
## comes into the coil: as the arm turns, the body turns with it.
func coil_frame(up_hint: Vector3) -> Transform3D:
	var first := _coil_first()
	if first < 0 or _n - first < 2:
		return Transform3D(_upright(up_hint), coil_center())
	# the winding part: the first coiling joint only lays the arm flat into it
	var from := first + 1 if _n - first >= 3 else first
	var centre := Vector3.ZERO
	for k in range(from, _n + 1):
		centre += points[k]
	centre /= float(_n + 1 - from)
	# the plane it winds in (Newell: summed round its every side, not three points)
	var up := Vector3.ZERO
	for k in range(from, _n + 1):
		up += (points[k] - centre).cross((points[k + 1] if k < _n else points[from]) - centre)
	if up.length_squared() < 1e-8:
		return Transform3D(_upright(up_hint), coil_center()) # still straight: not coiled yet
	up = up.normalized()
	# its middle: from the middle of its corners, step away from whichever side is nearest, in
	# the plane, for as long as that gets it farther from all of them
	var seat := centre
	var gap := _skin_gap(seat, first)
	var step := 0.5
	for _it in 32:
		var away: Vector3 = seat - gap[1]
		away -= up * away.dot(up)
		if away.length_squared() < 1e-8 or step < 0.01:
			break
		var try := seat + away.normalized() * step
		var g := _skin_gap(try, first)
		if g[0] > gap[0]:
			seat = try
			gap = g
		else:
			step *= 0.5
	if up.dot(up_hint) < 0.0:
		up = -up
	var arm_side := 0.0 # how far the arm is, before the coil, on the head's side
	for k in range(maxi(first - 3, 0), first):
		arm_side += (points[k] - seat).dot(up)
	if arm_side > ARM_OVER_HEAD * 3.0:
		up = -up
	var a := points[first]
	var left := (a - seat) - up * (a - seat).dot(up)
	if left.length_squared() < 1e-6:
		return Transform3D(_upright(up), seat)
	left = left.normalized()
	return Transform3D(Basis(left, up, left.cross(up)), seat)

## [m from p to the nearest skin of the coiled arm, the point on its middle line there].
func _skin_gap(p: Vector3, first: int) -> Array:
	var best := INF
	var at := p
	for k in range(first, _n):
		var q := Geometry3D.get_closest_point_to_segment(p, points[k], points[k + 1])
		var d := q.distance_to(p) - radius_at(k + 1)
		if d < best:
			best = d
			at = q
	return [best, at]

const ARM_OVER_HEAD := 1.5 # m: the arm coming into a held body's coil this far on its head's side turns it over

static func _upright(up: Vector3) -> Basis:
	var y := up.normalized()
	var x := Vector3.FORWARD.cross(y)
	if x.length_squared() < 1e-4:
		x = Vector3.RIGHT
	x = x.normalized()
	return Basis(x, y, x.cross(y))

## Jump straight into the goal pose (a new morning: nobody saw it move).
func snap_to_goals() -> void:
	_lay_shape = goals
	_targets_from(goals)
	_smooth_targets()
	_lay_over_shapes()
	for k in _n:
		_bend[k] = _target[k]
		_vel[k] = Vector2.ZERO
	_rebuild()
	if lay_on_path and _path_from > 0:
		_lay_on_goals(_path_from - 1)
	_clear_of_stone()

## ---- goal shapes (all world space) -------------------------------------------

## Loose, swimming or hovering: out of the crown along axis, splayed by spread toward out (the
## arm's own side of the crown) — never a straight line: two slow waves run down it toward the
## tip, growing as the arm thins. The sideways one is shared round the crown (neighbours lean
## the same way, as in one current, so they do not swing into each other); the in-and-out one
## is the arm's own, at its own tempo. The tip rolls into a spiral (curl), in the joints
## themselves (_lay_over_shapes), slowly opening and closing.
func goals_spread(axis: Vector3, out: Vector3, spread: float, wave_amp: float, phase: float, curl: float) -> void:
	var start := points[0]
	var side := axis.cross(out).normalized()
	var own := phase * _tempo
	# it opens and closes a little on its own, and leans slowly to one side and back
	var open := spread * (1.0 + 0.25 * sway * sin(own * 0.23 + _ph_b))
	var lean := 0.1 * sway * minf(spread * 4.0, 1.0) * sin(phase * 0.17 + index * 0.45)
	var dir := (axis + out * open + side * lean).normalized()
	var amp := wave_amp * length / 26.0 * sway
	var shared0 := phase + index * 0.45
	var mine0 := own * 0.6 + _ph_a
	for i in points.size():
		var t := _frac[i]
		var shared := shared0 - t * 4.2
		var mine := mine0 - t * 2.6
		goals[i] = start + dir * along[i] + (side * sin(shared) + out * (0.6 * sin(mine) + 0.35 * cos(shared * 0.6 + _ph_b))) * (amp * _swell[i])
	idle_curl = curl * (0.75 + 0.25 * sin(own * 0.31 + _ph_a))
	var round_it := _ph_b + own * 0.05 # the way the spiral rolls drifts round the arm
	_curl_world = out * cos(round_it) + side * sin(round_it) * 0.8 - dir * 0.2

## m the wrapped shape is held off the stone: on a lumpy rock the measured
## shape rounds off the bumps.
const WRAP_CLEARANCE := 0.8

## Wrapped round a vertical-ish column. The base runs down along the rock
## (root_pitch, nearly straight) and the distal part winds round it at pitch
## (radians up + / down -), turn = +1/-1 for the direction. rock_radius
## (height, angle) -> m gives the rock's real surface, e1/e2 the frame its
## angles are measured in.
func goals_wrap_column(center: Vector3, up: Vector3, e1: Vector3, e2: Vector3, rock_radius: Callable, turn: float, pitch: float, root_pitch: float, angle_offset: float) -> void:
	idle_curl = 0.0
	var start := points[0]
	var rel := start - center
	var a := atan2(rel.dot(e2), rel.dot(e1)) + angle_offset
	var h := rel.dot(up)
	goals[0] = start
	# From a body resting off the rock's face the arm runs alongside the stone,
	# the gap closing over three times its width: its stiff base cannot turn in
	# any sharper, and aimed straight at the skin it would carry on into it.
	var skin := center + up * h + (e1 * cos(a) + e2 * sin(a)) * (float(rock_radius.call(h, a)) + radius_at(0) * 0.9)
	var off := start - skin
	var settle := maxf(7.0, off.length() * 3.0)
	_path_from = 1 # laid (lay_on_path): the whole arm, the gentle approach included
	for i in range(1, points.size()):
		var seg := along[i] - along[i - 1]
		var p := lerpf(root_pitch, pitch, smoothstep(0.1, 0.9, along[i] / length)) # turned gently: the stiff base bends only a few degrees a joint
		var r_here: float = rock_radius.call(h, a) + radius_at(i)
		a += turn * seg * cos(p) / maxf(r_here, 1.0)
		h += seg * sin(p)
		var r: float = rock_radius.call(h, a) + radius_at(i) * 0.9 + WRAP_CLEARANCE
		var on_rock := center + up * h + (e1 * cos(a) + e2 * sin(a)) * r
		goals[i] = on_rock + off * (1.0 - smoothstep(0.0, settle, along[i]))

## Lying on a flat surface (the sea floor, a rock shelf): spirals outward from
## the root along the plane, the tip curling round.
func goals_wrap_plane(origin: Vector3, normal: Vector3, out: Vector3, curl: float) -> void:
	idle_curl = 0.0
	var start := points[0]
	var flat_out := (out - normal * out.dot(normal)).normalized()
	var pos := start - normal * (start - origin).dot(normal)
	goals[0] = start
	for i in range(1, points.size()):
		var t := along[i] / length
		var dir := flat_out.rotated(normal, curl * t * t * PI * 1.6)
		pos += dir * (along[i] - along[i - 1])
		goals[i] = start.lerp(pos + normal * radius_at(i), smoothstep(0.0, 6.0, along[i]))

## Aimed at a point: a shallow arc from the root to the target, bowed
## toward bow.
func goals_reach(target: Vector3, bow: Vector3) -> void:
	idle_curl = 0.0
	var start := points[0]
	var span := minf(start.distance_to(target), length)
	for i in points.size():
		var t := along[i] / length
		goals[i] = start.lerp(target, t) + bow * sin(t * PI) * span * 0.12

## Following a route laid onto something (a hull), given in the world from
## the tip's end back toward the body: the distal arm lies along the route —
## as much of it as 60 % of the arm can cover — and the rest of the arm comes
## straight from the crown to where the route starts.
## bow (a unit vector, or ZERO): the arm is usually longer than the way to the route; with
## a bow its spare length bellies out that way in one arc, instead of buckling wherever the
## joints let it (and into the arms beside it).
func goals_path(path: PackedVector3Array, bow := Vector3.ZERO) -> void:
	idle_curl = 0.0
	var start := points[0]
	var walked := PackedFloat32Array([0.0])
	for j in range(1, path.size()):
		walked.append(walked[-1] + path[j].distance_to(path[j - 1]))
	var wrap := minf(walked[-1], length * 0.6)
	var join := _point_on(path, walked, wrap)
	var s0 := maxf(length - wrap, 1.0)
	var belly := Vector3.ZERO
	if bow != Vector3.ZERO:
		# a half-wave arc s0 long over a chord c is about (2c/pi) * sqrt(s0/c - 1) deep
		# (bow's own length scales it)
		var c := maxf(start.distance_to(join), 1.0)
		if s0 > c:
			belly = bow * minf(c * 0.6366 * sqrt(s0 / c - 1.0), s0 * 0.45)
	_path_from = -1
	for i in points.size():
		var from_tip := length - along[i]
		if from_tip <= wrap and _path_from < 0:
			_path_from = i
		if from_tip <= wrap:
			goals[i] = _point_on(path, walked, from_tip)
		else:
			var u := along[i] / s0
			# the belly sits toward the far end: the stiff base leaves the crown nearly
			# straight, the supple outer arm does the turning back
			goals[i] = start.lerp(join, u) + belly * sin(PI * pow(u, BOW_SKEW))

## The whole arm along a path, root first: every point of the arm at the same
## fraction of the path as of its own length (no straight stretch from the
## body: round a thin pillar the arm winds from where it leaves the body).
func goals_follow(path: PackedVector3Array) -> void:
	idle_curl = 0.0
	var walked := PackedFloat32Array([0.0])
	for j in range(1, path.size()):
		walked.append(walked[-1] + path[j].distance_to(path[j - 1]))
	for i in points.size():
		goals[i] = _point_on(path, walked, along[i] / length * walked[-1])

static func _point_on(path: PackedVector3Array, walked: PackedFloat32Array, distance: float) -> Vector3:
	for j in range(1, path.size()):
		if walked[j] >= distance:
			var seg := walked[j] - walked[j - 1]
			return path[j - 1].lerp(path[j], (distance - walked[j - 1]) / seg if seg > 0.0 else 0.0)
	return path[-1]

## ---- simulation ----------------------------------------------------------------

func simulate(delta: float) -> void:
	if root().distance_to(points[0]) > TELEPORT:
		snap_to_goals()
		return
	# The shape it goes for: its goals (left as the Kraken laid them: a loose arm's are only
	# laid out afresh every other frame), with its keeping clear of the other arms laid over
	# them, fading by itself.
	var shape := goals
	if avoid_live:
		shape = goals.duplicate()
		var fade := exp(-AVOID_FADE * delta)
		var most := 0.0
		for i in range(1, shape.size()):
			var give := avoid[i]
			shape[i] += give
			avoid[i] = give * fade
			most = maxf(most, give.length_squared())
		avoid_live = most > 0.01
	_lay_shape = shape
	var chain := shape
	if inertia > 0.0:
		# the water holds it back: the heavy base goes with the body, the thin end trails most
		chain = shape.duplicate()
		for i in chain.size():
			chain[i] = shape[i].lerp(points[i], minf(inertia * _drag[i], 0.95))
	_targets_from(chain)
	_smooth_targets()
	_lay_over_shapes()
	var before_bend := _bend.duplicate()
	var tip_before := _pos[_n]
	var pos_before := _pos.duplicate() if limit_whole_arm else _pos
	# Damped springs: ease in, ease out. The lighter tip answers a little quicker than the
	# heavy base; an arm with a job never overshoots, a loose one (soft) gives a little at its
	# thin end and swings back.
	for k in _n:
		var u := float(k) / maxf(_n - 1, 1)
		var w := response * lerpf(0.8, 1.3, u)
		var top := max_joint_speed
		if curl_from >= 0.0 and along[k] + _segments[k] * _world * 0.5 > curl_from:
			w *= curl_quick
			top *= curl_quick * 2.0
		var damp := 2.0 * w * (1.0 - 0.3 * u * u) if soft else 2.0 * w
		var acc := (_target[k] - _bend[k]) * (w * w) - _vel[k] * damp
		_vel[k] = (_vel[k] + acc * delta).limit_length(top)
		# a joint bent past its limit (it gave against the stone, or held on tight a moment
		# ago) eases back inside it at its own speed: clamped at once, the arm would jump
		_bend[k] = (_bend[k] + _vel[k] * delta).limit_length(maxf(_limit[k], _bend[k].length() - top * delta))
	_rebuild()
	if seek_tip > 0.0 and not pin_tip:
		_pin_tip_to(tip_target, 1.0 - exp(-seek_tip * delta))
	# Joint motions add up toward the tip: if together they would fling it
	# faster than max_tip_speed (relative to the body), scale every joint's
	# step down alike — same shape, slower.
	var moved := _pos[_n].distance_to(tip_before)
	if moved * _world > max_tip_speed * delta:
		var scale := max_tip_speed * delta / (moved * _world)
		for k in _n:
			_bend[k] = before_bend[k].lerp(_bend[k], scale)
			_vel[k] *= scale
		_rebuild()
	if lay_on_path and _path_from > 0:
		_lay_on_goals(_path_from - 1, 1.0 if lay_rate <= 0.0 else 1.0 - exp(-lay_rate * delta))
	if pin_tip: # a grip holds on whatever the hull does
		_pin_tip_to(tip_target, 1.0 if pin_rate <= 0.0 else 1.0 - exp(-pin_rate * delta))
	if limit_whole_arm:
		# no point of the arm moves faster than max_tip_speed, whatever moved it
		# (springs, a hold taking or letting go): the joints' speeds add up down
		# a long arm, so its middle could whip round while its tip barely moves
		var fastest := 0.0
		for i in range(1, _n + 1):
			fastest = maxf(fastest, _pos[i].distance_to(pos_before[i]))
		if fastest * _world > max_tip_speed * delta:
			var scale := max_tip_speed * delta / (fastest * _world)
			for k in _n:
				_bend[k] = before_bend[k].lerp(_bend[k], scale)
				_vel[k] *= scale
			_rebuild()
	_clear_of_stone(max_joint_speed * STONE_SPEED * delta)

## Root to tip: a joint whose next point lies in the stone (keep_out) turns to
## aim at where that point would be clear, and the rest of the arm follows.
## max_turn > 0: no joint turns more than that (radians) for it in one go — an arm wound
## round the rock swings a long way for a small turn at its base, and would jump.
func _clear_of_stone(max_turn := 0.0) -> void:
	if not keep_out.is_valid():
		return
	var xf := skeleton.global_transform
	var inv := xf.affine_inverse()
	var moved := false
	for k in _n:
		var at := xf * _pos[k + 1]
		var push: Vector3 = keep_out.call(at, radius_at(k + 1))
		if push.length_squared() < 0.0001:
			continue
		var before := _base if k == 0 else _frames[k - 1] * _rest_local[k]
		var want := inv * (at + push) - _pos[k]
		if want.length_squared() < 1e-8:
			continue
		# against the stone a joint gives more than its usual bend
		var clear := _swing(before.transposed() * want.normalized()).limit_length(minf(_limit[k] * STONE_GIVE, PI * 0.6))
		_bend[k] = clear if max_turn <= 0.0 else _bend[k].move_toward(clear, max_turn)
		_local_fresh = false
		for j in range(k, _n):
			var b := _base if j == 0 else _frames[j - 1] * _rest_local[j]
			_frames[j] = b * _bend_basis(_bend[j])
			_pos[j + 1] = _pos[j] + _frames[j].y * _segments[j]
		moved = true
	if moved:
		for k in _n + 1:
			points[k] = xf * _pos[k]

## From joint `from` on, each joint turns straight at its next goal point, from
## where the arm really is (within its limits): that part lies on the goals now.
func _lay_on_goals(from: int, amount := 1.0) -> void:
	var inv := skeleton.global_transform.affine_inverse()
	for k in range(maxi(from, 0), _n):
		var before := _base if k == 0 else _frames[k - 1] * _rest_local[k]
		var want := inv * _lay_shape[k + 1] - _pos[k]
		if want.length_squared() < 1e-8:
			continue
		var b := _swing(before.transposed() * want.normalized()).limit_length(_limit[k])
		_bend[k] = _bend[k].lerp(b, amount)
		_local_fresh = false
		_vel[k] = Vector2.ZERO
		_frames[k] = before * _bend_basis(_bend[k])
		_pos[k + 1] = _pos[k] + _frames[k].y * _segments[k]
	var xf := skeleton.global_transform
	for k in range(maxi(from, 0), _n + 1):
		points[k] = xf * _pos[k]

## The goal chain as a target bend per joint, walked from the root: each
## joint aims at its goal point from where the arm has really got to (after
## the joints before it were clamped), so the limits shape the whole arm.
func _targets_from(chain: PackedVector3Array) -> void:
	var inv := skeleton.global_transform.affine_inverse()
	var p := _root_origin
	var frame := _base
	for k in _n:
		var before := _base if k == 0 else frame * _rest_local[k]
		var want := inv * chain[k + 1] - p
		var b := Vector2.ZERO
		if want.length_squared() > 1e-8:
			b = _swing(before.transposed() * want.normalized())
			# A goal almost straight behind a joint has no clear side to bend
			# to: the side flips with every wobble and whips the arm across.
			# Past ~115 degrees, keep bending the way it already is.
			if b.length() > 2.0 and _bend[k].length() > 0.02 and b.dot(_bend[k]) < 0.0:
				b = _bend[k].normalized() * b.length()
			b = b.limit_length(_limit[k])
		_target[k] = b
		frame = before * _bend_basis(b)
		p += frame.y * _segments[k]

## Average each joint's target with its neighbours: no kinks, only curves.
func _smooth_targets() -> void:
	for _pass in smooth_passes:
		var prev := _target[0]
		for k in range(1, _n - 1):
			var here := _target[k]
			_target[k] = (prev * 0.25 + here * 0.5 + _target[k + 1] * 0.25).limit_length(_limit[k])
			prev = here

## The shapes that are not about reaching a point: the rolled tip ahead of a
## reach's bend front, and the coil round a held body.
func _lay_over_shapes() -> void:
	if curl_from >= 0.0 or reach_front < 1.0:
		var axis_sk := Vector3.ZERO
		var turn := 0.0 # which way round the axis it winds: kept from the first winding joint on
		var flattened := false
		if curl_from >= 0.0 and curl_axis != Vector3.ZERO:
			axis_sk = (skeleton.global_basis.inverse() * curl_axis).normalized()
		for k in _n:
			var mid := along[k] + _segments[k] * _world * 0.5
			if curl_from >= 0.0 and mid > curl_from:
				if curl_hold and _curl_shape.size() == _n:
					_target[k] = _curl_shape[k].limit_length(_limit[k])
					continue
				var amount := minf(curl_rate * _segments[k] * _world, _limit[k])
				var way := Vector2(1.0, 0.0)
				if axis_sk != Vector3.ZERO:
					var before := _base if k == 0 else _frames[k - 1] * _rest_local[k]
					var d := before.transposed() * axis_sk
					if not flattened:
						# the first coiled joint turns the arm flat across the axis, so the rest
						# winds round it like a belt, not up and down past it
						flattened = true
						var want := Vector3.UP - d * d.y # its own way on, minus the part along the axis
						if want.length_squared() > 0.01:
							_target[k] = _swing(want.normalized()).limit_length(_limit[k])
							continue
					# the bend's axis (x, z in the joint's frame) toward the coil's: the coil lies
					# across the axis, winding round it
					var flat := Vector2(d.x, d.z)
					if flat.length_squared() > 0.01:
						flat = flat.normalized()
						if turn == 0.0:
							turn = 1.0 if flat.dot(_bend[k]) >= 0.0 else -1.0 # the way it already bends
						way = flat * turn
				_target[k] = way * amount
			elif reach_front < 1.0 and mid > maxf(reach_front, 0.5) * length:
				_target[k] = Vector2(_limit[k] * 0.45, 0.0) # the far half stays rolled until the bend arrives
	if idle_curl > 0.0 and curl_from < 0.0 and reach_front >= 1.0:
		# a loose tip rolls into a spiral: each joint past the middle bends a little more than
		# the one before it, all the same way round (toward _curl_world, in the joint's frame)
		var first := -1
		var bend_way := Vector2.ZERO
		for k in _n:
			var e := ((along[k] + _segments[k] * _world * 0.5) / length - 0.5) / 0.5
			if e <= 0.0:
				continue
			if first < 0:
				first = k
				var before := _base if k == 0 else _frames[k - 1] * _rest_local[k]
				var d := before.transposed() * (skeleton.global_basis.inverse() * _curl_world)
				bend_way = Vector2(d.z, -d.x)
				if bend_way.length_squared() < 1e-8:
					return
				bend_way = bend_way.normalized()
			_target[k] = (_target[k] + bend_way * _limit[k] * idle_curl * 0.9 * e * e).limit_length(_limit[k])

## Rebuild the chain from the joints' bends (skeleton space, then world).
func _rebuild() -> void:
	var xf := skeleton.global_transform
	var p := _root_origin
	_pos[0] = p
	points[0] = xf * p
	var frame := _parent_basis
	for k in _n:
		var local := _rest_local[k] * _bend_basis(_bend[k]) # kept: it is the bone's pose (apply_to_skeleton)
		_local[k] = local
		frame = frame * local
		_frames[k] = frame
		p += frame.y * _segments[k]
		_pos[k + 1] = p
		points[k + 1] = xf * p
	_local_fresh = true

## Bring the tip onto a world point by turning the last few joints (cyclic
## coordinate descent), each within its limit. amount 1 = all the way now;
## less = that fraction of the way this frame, for a tip that homes in.
## With pin_joints past the light distal end, the heavy joints nearer the base
## first lean a little of the way each frame (PIN_BASE_EASE), so the whole arm
## drifts after a hold that moves away and the distal end does the exact part.
func _pin_tip_to(target: Vector3, amount: float) -> void:
	var t := skeleton.global_transform.affine_inverse() * target
	var distal := mini(pin_joints, PIN_DISTAL)
	var far_end := maxi(_n - distal, 0)
	var lowest := _n
	for k in range(_n - distal - 1, maxi(_n - pin_joints, 0) - 1, -1):
		_turn_tip_toward(k, t, amount * PIN_BASE_EASE)
		lowest = k
	for _it in (2 if amount >= 1.0 else 1):
		if lowest < _n:
			_rebuild_from(lowest) # the joints below have turned: bring the rest of the chain after them
		for k in range(_n - 1, far_end - 1, -1):
			_turn_tip_toward(k, t, amount)
		lowest = mini(lowest, far_end)
	_rebuild_from(lowest)
	var xf := skeleton.global_transform
	for k in range(lowest, _n + 1):
		points[k] = xf * _pos[k]

## Turn joint k so the tip swings toward t. Only the joint's own frame and the tip are moved
## here (turning a joint carries everything past it round rigidly); the joints in between are
## brought after by _rebuild_from, once per pass — not the whole chain again for every joint.
func _turn_tip_toward(k: int, t: Vector3, amount: float) -> void:
	var to_tip := _pos[_n] - _pos[k]
	var to_target := t - _pos[k]
	if to_tip.length_squared() < 1e-6 or to_target.length_squared() < 1e-6:
		return
	var turn := Quaternion(to_tip.normalized(), to_target.normalized())
	if amount < 1.0:
		turn = Quaternion.IDENTITY.slerp(turn, amount)
	if pin_max_turn > 0.0:
		# a long arm swings far for a small turn near its root: never more than
		# this much a frame at any joint, so it never jumps
		var angle := turn.get_angle()
		if angle > pin_max_turn:
			turn = Quaternion.IDENTITY.slerp(turn, pin_max_turn / angle)
	var turned := Basis(turn) * _frames[k]
	var before := _base if k == 0 else _frames[k - 1] * _rest_local[k]
	_bend[k] = _swing((before.transposed() * turned.y).normalized()).limit_length(_limit[k])
	_local_fresh = false
	_vel[k] *= 0.5
	var now := before * _bend_basis(_bend[k])
	_pos[_n] = _pos[k] + (now * _frames[k].transposed()) * to_tip
	_frames[k] = now

## Rebuild the chain past joint `from` (skeleton space only).
func _rebuild_from(from: int) -> void:
	for k in range(from, _n):
		var before := _base if k == 0 else _frames[k - 1] * _rest_local[k]
		_frames[k] = before * _bend_basis(_bend[k])
		_pos[k + 1] = _pos[k] + _frames[k].y * _segments[k]

## Pose the bones from the joints' bends.
func apply_to_skeleton() -> void:
	if _local_fresh:
		for k in _n:
			skeleton.set_bone_pose_rotation(bones[k], _local[k].get_rotation_quaternion())
		return
	for k in _n:
		skeleton.set_bone_pose_rotation(bones[k], (_rest_local[k] * _bend_basis(_bend[k])).get_rotation_quaternion())

## The swing that turns +Y onto dir, as a rotation vector (x, z).
static func _swing(dir: Vector3) -> Vector2:
	var axis := Vector3(dir.z, 0.0, -dir.x) # +Y cross dir
	var s := axis.length()
	if s < 1e-6:
		return Vector2.ZERO if dir.y > 0.0 else Vector2(PI, 0.0)
	return Vector2(axis.x, axis.z) / s * atan2(s, dir.y)

static func _bend_basis(b: Vector2) -> Basis:
	var angle := b.length()
	if angle < 1e-6:
		return Basis.IDENTITY
	return Basis(Vector3(b.x, 0.0, b.y) / angle, angle)
