extends SkeletonModifier3D
## Adjusts the player's body after its clip has posed it (see PlayerBody):
##  - the look: the upper body turns toward where the view looks while the legs stay where they
##    stand, shared out from the lower back up to the neck as a real one turns;
##  - the lean: the upper body bends forward/back and side to side from the lower back, so it can
##    ride a heaving deck softly while the feet stay put;
##  - the hands: each arm reaches its hand to a point (on the helm's wheel), the elbow bending out
##    and down toward a pole, the way an arm does (two-bone IK), its fingers closed round a grip.
## All points are in the skeleton's own space; PlayerBody sets them every frame.

## How far the upper body is turned toward the view (radians, about the skeleton's up).
var twist := 0.0
## Hands to reach, or Vector3.INF to leave that arm to its clip.
var hand_l := Vector3.INF
var hand_r := Vector3.INF
## Where each elbow bends toward.
var pole_l := Vector3.ZERO
var pole_r := Vector3.ZERO
## The upper body's lean (radians): x forward (+) or back, y to its right (+) or left.
var lean := Vector2.ZERO
## Hands and feet moved from where the clip put them (skeleton space; the body faces +Z, its left
## is +X): end bone ('hand_l', 'foot_r', ...) -> offset. The arm or leg bends to follow (two-bone
## IK, the elbow or knee bending the way the clip bends it) and the hand or foot keeps the clip's
## turn. Fits a clip to what it holds or stands on (the ladder's rails and rungs, see PlayerBody).
var nudge := {}
## How far (0..1) the fingers are opened from the clip's pose toward the open hand (the rest pose),
## where no grip closes them.
var fingers_open := 0.0
const LIMBS := {&'hand_l': [&'upperarm_l', &'lowerarm_l'], &'hand_r': [&'upperarm_r', &'lowerarm_r'],
		&'foot_l': [&'thigh_l', &'calf_l'], &'foot_r': [&'thigh_r', &'calf_r']}
const FINGERS := ['index', 'middle', 'ring', 'pinky', 'thumb']
var _finger_bones: Array[int] = []
## How closed each hand is round a grip, from an open hand (just above 0) to the holding pose (1);
## 0 leaves the fingers to the clip. The holding fingers' turns (bone -> local rotation) are taken
## from a clip that grips (see PlayerBody); the open hand is the rig's rest pose.
var grip_l := 0.0
var grip_r := 0.0
var fingers_l := {}
var fingers_r := {}
## How deep a handle sits in the hand (0 = at the wrist, 1 = at the knuckles).
var grip_depth := 0.55
## The gripping hands' turn at the wrist (radians): x bend, y twist about the forearm, z tilt.
## Applied to the left hand as is and mirrored on the right.
var wrist := Vector3.ZERO
## The thumbs' turn at their base (radians): x pitch (opening the thumb out from the palm), y turn.
## Mirrored on the right like the wrists.
var thumb := Vector2.ZERO
## The wheel the hands hold, in the skeleton's space: its middle and axle, and where each hand
## likes to hold it (a direction out from the middle). A hand stays locked to its spoke: past
## LOCK_FROM from home it turns with the spoke as a hand gripping it would, rather than keeping
## the angle the forearm gives it (which, at full lock, turns the back of the hand to the handle).
var wheel_center := Vector3.INF
var wheel_axle := Vector3.ZERO
var home_l := Vector3.ZERO
var home_r := Vector3.ZERO
## The wrists' extra turn once a hand is turning with its spoke (radians, like `wrist`), faded in
## with the lock.
var lock_wrist := Vector3.ZERO
## Carrying: each hand's grip on the item (the grip marker's turn, in the skeleton's space). The hand
## is turned by its marker, so it holds the item the same way however it was picked up, and the
## wrist doesn't roll on it as the body turns under the view (only the elbow and forearm give): the
## fingers point along the marker's +Y, the thumb along its +Z, and the palm faces its -X on the
## right hand, +X on the left (toward the item's middle, for grips on its right and left sides).
## `settling`: the item is still gliding into the hands.
var carrying := false
var settling := false
var item_frame_l := Basis()
var item_frame_r := Basis()
## The thumbs' closing while carrying, apart from the fingers (see grip_l); below 0 they close with
## the fingers (the wheel's grip, the thumb wrapped round its spoke).
var thumb_grip := -1.0
var _marker_to_hand := {} # per side: the hand's rest turn, from its marker's axes (see item_frame_l)
var _reach_len := {} # per side: how far from the shoulder the palm can be (skeleton space)
var _second_on: Node3D # the item the second hand took hold of, and where on it (its own space)
var _second_at := Vector3.ZERO
const SECOND_HAND_EASE := 0.85 # of its reach, how far the second hand takes hold: room to sway in
## The item hangs from the `anchor` hand ('_l' or '_r'): the rig moves it so its grip sits on that
## palm, wherever the arm could reach, and it never leaves the hand. `hang` (0..1) eases it there
## from where it glides as it is taken. Null when held by its sides.
var carried_item: Node3D
var anchor := '_r'
var hang := 1.0
## How far (0..1) the back and collarbones are held out of the clip's swing from step to step: the
## arms reach from the shoulders, so as a walk turns and rocks the back, all the hands hold swings.
var steady_shoulders := 0.0
const STEADY := [&'spine_01', &'spine_02', &'spine_03', &'clavicle_l', &'clavicle_r']
const STEADY_SMOOTH := 0.35 # s: longer than a step, so a stride's swing is smoothed away
var _steady_q := {} # per bone: its turn, smoothed
var _pull := Vector3.ZERO # the chest drawn toward the handles (see _process_modification)
var _clip_hand := {} # per side: the hand's turn as the clip posed it, this frame
var _lock := {} # per side: the hand's turn relative to its spoke, as it was near home
const LOCK_FROM := 10.0 # degrees from home: up to here the hand is as the arm leaves it
const LOCK_FULL := 25.0 # degrees from home: from here it turns wholly with its spoke

## How the lean is shared out up the back (adds up to 1).
const LEAN := {&'spine_01': 0.4, &'spine_02': 0.35, &'spine_03': 0.25}

## How the turn is shared out, lower back to neck (adds up to 1).
const TWIST := {&'spine_01': 0.15, &'spine_02': 0.2, &'spine_03': 0.25, &'neck_01': 0.4}
const SHOULDER_SHARE := 0.6 # of the twist, what the bones below the shoulders take
const MAX_PASSES := 6 # aims per hand per frame
const SOFT_FROM := 0.9 # of an arm's full length, where its reach starts to ease off
const PULL_GAIN := 0.35 # of what the arms couldn't reach, how much more the chest is drawn in next frame
const PULL_LET_GO := 0.985 # how much of the pull is kept each frame (the rest lets go)

func _process_modification() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	# first, before the look and the lean turn them: the back and collarbones steadied (see
	# steady_shoulders). Each is turned toward its own pose smoothed over STEADY_SMOOTH, so they keep
	# the walk's lean but not its swing from step to step.
	var dt := get_process_delta_time()
	for name: StringName in STEADY:
		var c := sk.find_bone(name)
		if c < 0:
			continue
		var q := sk.get_bone_pose_rotation(c)
		_steady_q[name] = q if not _steady_q.has(name) else (_steady_q[name] as Quaternion).slerp(q, 1.0 - exp(-dt / STEADY_SMOOTH))
		if steady_shoulders > 0.001:
			sk.set_bone_pose_rotation(c, q.slerp(_steady_q[name], steady_shoulders))
	if lean.length() > 0.0001:
		# in the skeleton's space the body faces +Z: about +X leans it forward, about +Z to its right
		for bone_name: StringName in LEAN:
			var b := sk.find_bone(bone_name)
			if b < 0:
				continue
			var g := sk.get_bone_global_pose(b)
			var k: float = LEAN[bone_name]
			g.basis = Basis(Vector3.RIGHT, lean.x * k) * Basis(Vector3.BACK, lean.y * k) * g.basis
			sk.set_bone_global_pose(b, g)
	if absf(twist) > 0.001:
		for bone_name: StringName in TWIST:
			var b := sk.find_bone(bone_name)
			if b < 0:
				continue
			var g := sk.get_bone_global_pose(b)
			g.basis = Basis(Vector3.UP, twist * TWIST[bone_name]) * g.basis
			sk.set_bone_global_pose(b, g)
	for end: StringName in nudge:
		_nudge(sk, end, nudge[end])
	if fingers_open > 0.001 and grip_l <= 0.001 and grip_r <= 0.001:
		_open_fingers(sk)
	if hand_l == Vector3.INF:
		_lock.erase('_l')
	if hand_r == Vector3.INF:
		_lock.erase('_r')
	# the hands as the clip left them: each reach below starts from here (the wrist turn is laid on
	# once per reach, never on top of the last one)
	_clip_hand.clear()
	for side in ['_l', '_r']:
		var hb := sk.find_bone('hand' + side)
		if hb >= 0:
			_clip_hand[side] = sk.get_bone_pose_rotation(hb)
	# holding on: the chest is drawn toward the handles by a pull kept from frame to frame, then the
	# arms reach. What they still can't reach adds to the pull; when they reach easily it lets go,
	# slowly. Worked out afresh each frame (pull or no pull), the chest snapped back and forth.
	if hand_l == Vector3.INF and hand_r == Vector3.INF:
		_pull = Vector3.ZERO
	elif _pull.length() > 0.0001:
		_hold_on(sk, _pull)
	var miss := Vector3.ZERO
	if carried_item == null:
		_second_on = null
	# a carried item hangs from its anchor hand: that hand reaches first, the item is moved onto its
	# palm wherever it got to, and the other hand holds on where the item now is
	var sides := ['_l', '_r'] if carried_item == null or anchor == '_l' else ['_r', '_l']
	var shift := Vector3.ZERO # how far the item was moved onto the anchor hand (skeleton space)
	var anchor_at := Vector3.INF # the anchor's grip, on its palm
	for side: String in sides:
		var target := hand_l if side == '_l' else hand_r
		if target == Vector3.INF:
			continue
		target += shift
		if carried_item and side != anchor and anchor_at != Vector3.INF:
			# where it holds the item is picked once, as it takes hold, and kept: its own grip if it
			# reaches it, else (a long item held at its two ends) the nearest place toward the anchor
			# that it does reach. Picked afresh each frame it slid up and down the item as we turned.
			# (while it is still coming up into the hands that place follows it, so taking hold
			# is one smooth move)
			if settling or _second_on != carried_item:
				_second_on = null if settling else carried_item
				var shoulder := sk.get_bone_global_pose(sk.find_bone('upperarm' + side)).origin
				var t := _within_reach(target, anchor_at, shoulder, _reach_of(sk, side) * SECOND_HAND_EASE)
				_second_at = carried_item.global_transform.affine_inverse() * (sk.global_transform * target.lerp(anchor_at, t))
			target = sk.global_transform.affine_inverse() * (carried_item.global_transform * _second_at)
		var m := _grip(sk, side, target, pole_l if side == '_l' else pole_r)
		if m.length() > miss.length(): miss = m
		if carried_item and side == anchor:
			shift = -m * hang # the palm, from where the grip was (eased onto it as it is taken)
			anchor_at = target + shift
			carried_item.global_position += sk.global_basis * shift
	_pull = (_pull + miss * PULL_GAIN) * PULL_LET_GO
	_close(sk, fingers_l, grip_l)
	_close(sk, fingers_r, grip_r)
	if grip_l > 0.001:
		_turn_thumb(sk, '_l')
	if grip_r > 0.001:
		_turn_thumb(sk, '_r')

## Moves a hand or foot `by` from where the clip put it (see `nudge`).
func _nudge(sk: Skeleton3D, end: StringName, by: Vector3) -> void:
	if by.length() < 0.0001 or not LIMBS.has(end):
		return
	var e := sk.find_bone(end)
	var mid := sk.find_bone(LIMBS[end][1])
	var root := sk.find_bone(LIMBS[end][0])
	if e < 0 or mid < 0 or root < 0:
		return
	var kept := sk.get_bone_global_pose(e).basis # the hand's / foot's turn, kept
	var s := sk.get_bone_global_pose(root).origin
	var m := sk.get_bone_global_pose(mid).origin
	var t := sk.get_bone_global_pose(e).origin
	# the pole: out from the limb's line through the elbow / knee, so it keeps bending the clip's way
	var line := (t - s).normalized()
	var out := (m - s) - line * (m - s).dot(line)
	var pole := m + (out.normalized() if out.length() > 0.001 else Vector3.BACK) * 0.5
	_reach(sk, LIMBS[end][0], LIMBS[end][1], end, t + by, pole)
	var g := sk.get_bone_global_pose(e)
	g.basis = kept
	sk.set_bone_global_pose(e, g)

## The fingers opened `fingers_open` of the way toward the rest pose (the open hand).
func _open_fingers(sk: Skeleton3D) -> void:
	if _finger_bones.is_empty():
		for b in sk.get_bone_count():
			var n := sk.get_bone_name(b)
			for f in FINGERS:
				if n.begins_with(f) and not n.contains('leaf'):
					_finger_bones.append(b)
	for b in _finger_bones:
		var open := sk.get_bone_rest(b).basis.get_rotation_quaternion()
		sk.set_bone_pose_rotation(b, sk.get_bone_pose_rotation(b).slerp(open, fingers_open))

## Holding on: the body can't sway farther from a handle than its arm reaches, the grip pulls it
## along. The back bends about the waist to bring the shoulders `miss` nearer the handle.
func _hold_on(sk: Skeleton3D, miss: Vector3) -> void:
	var waist := sk.get_bone_global_pose(sk.find_bone(&'spine_01')).origin
	var chest := (sk.get_bone_global_pose(sk.find_bone(&'upperarm_l')).origin + sk.get_bone_global_pose(sk.find_bone(&'upperarm_r')).origin) * 0.5
	var up := chest - waist
	var axis := up.cross(miss)
	if axis.length() < 0.000001:
		return
	var angle := minf(miss.length() / maxf(up.length(), 0.01), deg_to_rad(10.0))
	for bone_name: StringName in LEAN:
		var b := sk.find_bone(bone_name)
		if b < 0:
			continue
		var g := sk.get_bone_global_pose(b)
		g.basis = Basis(axis.normalized(), angle * LEAN[bone_name]) * g.basis
		sk.set_bone_global_pose(b, g)

## The thumb opened and turned at its base, by the thumb sliders.
func _turn_thumb(sk: Skeleton3D, side: String) -> void:
	var b := sk.find_bone('thumb_01' + side)
	if b < 0 or thumb == Vector2.ZERO:
		return
	var m := 1.0 if side == '_l' else -1.0
	sk.set_bone_pose_rotation(b, sk.get_bone_pose_rotation(b) * Quaternion.from_euler(Vector3(thumb.x, thumb.y * m, 0.0)))

## The arm reaches so its palm lands on `grip`: aimed once, then corrected by what it missed (the
## hand angles at the wrist, so the first aim is a few cm off).
func _grip(sk: Skeleton3D, side: String, grip: Vector3, pole: Vector3) -> Vector3:
	var upper := StringName('upperarm' + side)
	var lower := StringName('lowerarm' + side)
	var hand := StringName('hand' + side)
	var knuckle := StringName('middle_01' + side)
	# the wrist's turn first, so the reach below lands the palm with the hand already turned
	var h := sk.find_bone(hand)
	if h >= 0:
		var m := 1.0 if side == '_l' else -1.0
		var turn := Quaternion.from_euler(Vector3(wrist.x, wrist.y * m, wrist.z * m))
		sk.set_bone_pose_rotation(h, (_clip_hand.get(side, sk.get_bone_pose_rotation(h)) as Quaternion) * turn)
	# aimed, then corrected by what it missed, always the same number of times (stopping as soon as
	# it was near enough stopped at a different pass each frame, the arm jittering between them)
	var shoulder := sk.get_bone_global_pose(sk.find_bone(upper)).origin
	var aim := _palm_on(sk, upper, hand, knuckle, grip)
	for pass_i in MAX_PASSES:
		_reach(sk, upper, lower, hand, aim, pole)
		_lock_to_spoke(sk, h, side, grip, shoulder)
		_lock_to_item(sk, h, side)
		aim += grip - _palm(sk, hand, knuckle)
	return grip - _palm(sk, hand, knuckle) # what it could not reach

## Keeps the hand gripping the handle it holds as the wheel turns (see wheel_center). A handle is a
## bar sticking out from the wheel, and a hand can hold a bar from any side round it: it holds it
## from the side its arm comes from. So the hand keeps the bar across its palm as it was tuned, and
## turns round the bar to face its arm (a hand turned rigidly with the spoke would end up facing
## away from the arm at full lock, out of its reach, the wrist wrung).
func _lock_to_spoke(sk: Skeleton3D, h: int, side: String, grip: Vector3, shoulder: Vector3) -> void:
	if h < 0 or wheel_center == Vector3.INF:
		return
	var axle := wheel_axle.normalized()
	var out := grip - wheel_center
	out = (out - axle * out.dot(axle)).normalized()
	var home: Vector3 = home_l if side == '_l' else home_r
	var off := rad_to_deg(absf(home.signed_angle_to(out, axle)))
	var reach := grip - shoulder # the way the arm comes to the handle
	var facing := reach - out * reach.dot(out) # ... round the bar
	if facing.length() < 0.001:
		return
	facing = facing.normalized()
	var spoke := Basis(out, facing, out.cross(facing)) # the bar, and the side the arm holds it from
	var g := sk.get_bone_global_pose(h)
	var as_left := g.basis.orthonormalized()
	if off < LOCK_FROM:
		_lock[side] = spoke.inverse() * as_left # how the tuned hand sits on its spoke
		return
	if not _lock.has(side):
		return # took the wheel already turned: nothing to go by yet
	var locked: Basis = spoke * (_lock[side] as Basis)
	var w := smoothstep(LOCK_FROM, LOCK_FULL, off)
	var q := as_left.get_rotation_quaternion().slerp(locked.get_rotation_quaternion(), w)
	if lock_wrist != Vector3.ZERO:
		var m := 1.0 if side == '_l' else -1.0
		q = q * Quaternion.from_euler(Vector3(lock_wrist.x, lock_wrist.y * m, lock_wrist.z * m) * w)
	g.basis = Basis(q).scaled(g.basis.get_scale())
	sk.set_bone_global_pose(h, g)

## Turns the hand on a carried item as its grip marker says (see `carrying`).
func _lock_to_item(sk: Skeleton3D, h: int, side: String) -> void:
	if h < 0 or not carrying:
		return
	if not _marker_to_hand.has(side):
		# the hand at rest, as a marker's axes: the fingers (+Y), the thumb's side of the palm (+Z),
		# and +X = Y x Z, which comes out the back of the right hand and the palm of the left
		var o := func(n: String) -> Vector3: return sk.get_bone_global_rest(sk.find_bone(n + side)).origin
		var fingers: Vector3 = (o.call('middle_01') - o.call('hand')).normalized()
		var thumb_side: Vector3 = o.call('index_01') - o.call('pinky_01')
		thumb_side = (thumb_side - fingers * thumb_side.dot(fingers)).normalized()
		var rest_marker := Basis(fingers.cross(thumb_side), fingers, thumb_side)
		_marker_to_hand[side] = rest_marker.inverse() * sk.get_bone_global_rest(h).basis.orthonormalized()
	var frame: Basis = (item_frame_l if side == '_l' else item_frame_r).orthonormalized()
	var g := sk.get_bone_global_pose(h)
	g.basis = (frame * (_marker_to_hand[side] as Basis)).scaled(g.basis.get_scale())
	sk.set_bone_global_pose(h, g)

## How far (0..1) from `from` toward `to` the first point within `reach` of `shoulder` lies; when
## none is, the point nearest the shoulder (where the first one appears as the item turns, so the
## hand never jumps between the two).
static func _within_reach(from: Vector3, to: Vector3, shoulder: Vector3, reach: float) -> float:
	var f := from - shoulder
	if f.length() <= reach:
		return 0.0
	var d := to - from
	var a := d.length_squared()
	if a < 0.000001:
		return 0.0
	var b := f.dot(d)
	var disc := b * b - a * (f.length_squared() - reach * reach)
	if disc < 0.0:
		return clampf(-b / a, 0.0, 1.0)
	return clampf((-b - sqrt(disc)) / a, 0.0, 1.0)

## How far from its shoulder a hand can hold something: the arm and a palm, a little short of
## straight (skeleton space).
func _reach_of(sk: Skeleton3D, side: String) -> float:
	if not _reach_len.has(side):
		var o := func(n: String) -> Vector3: return sk.get_bone_global_rest(sk.find_bone(n + side)).origin
		_reach_len[side] = (o.call('upperarm').distance_to(o.call('lowerarm')) + o.call('lowerarm').distance_to(o.call('hand'))
				+ o.call('hand').distance_to(o.call('middle_01')) * grip_depth) * 0.95
	return _reach_len[side]

## Where the palm is: halfway from the wrist to the knuckles.
func _palm(sk: Skeleton3D, hand_name: StringName, knuckle_name: StringName) -> Vector3:
	return sk.get_bone_global_pose(sk.find_bone(hand_name)).origin.lerp(sk.get_bone_global_pose(sk.find_bone(knuckle_name)).origin, grip_depth)

## Where the wrist goes for the palm (halfway to the knuckles) to sit on `grip`: a little short of it,
## back toward the shoulder, so the fingers close round the handle rather than the wrist.
func _palm_on(sk: Skeleton3D, shoulder_name: StringName, hand_name: StringName, knuckle_name: StringName, grip: Vector3) -> Vector3:
	var hand := sk.find_bone(hand_name)
	var knuckle := sk.find_bone(knuckle_name)
	if hand < 0 or knuckle < 0:
		return grip
	var palm := sk.get_bone_global_pose(hand).origin.distance_to(sk.get_bone_global_pose(knuckle).origin) * grip_depth
	var shoulder := sk.get_bone_global_pose(sk.find_bone(shoulder_name)).origin
	return grip - (grip - shoulder).normalized() * palm

## Fingers set `weight` of the way from an open hand to their holding pose.
func _close(sk: Skeleton3D, fingers: Dictionary, weight: float) -> void:
	if weight <= 0.001:
		return
	for b: int in fingers:
		var open := sk.get_bone_rest(b).basis.get_rotation_quaternion()
		var w := weight
		if thumb_grip >= 0.0 and sk.get_bone_name(b).begins_with('thumb'):
			w = thumb_grip
		sk.set_bone_pose_rotation(b, open.slerp(fingers[b], w))

## Upper arm and forearm turned so the hand lands on `target`, the elbow toward `pole`.
func _reach(sk: Skeleton3D, upper_name: StringName, lower_name: StringName, hand_name: StringName, target: Vector3, pole: Vector3) -> void:
	var upper := sk.find_bone(upper_name)
	var lower := sk.find_bone(lower_name)
	var hand := sk.find_bone(hand_name)
	if upper < 0 or lower < 0 or hand < 0:
		return
	var gu := sk.get_bone_global_pose(upper)
	var s := gu.origin
	var e := sk.get_bone_global_pose(lower).origin
	var h := sk.get_bone_global_pose(hand).origin
	var a := s.distance_to(e)
	var b := e.distance_to(h)
	var to := target - s
	# soft near straight: the last stretch of the arm's reach is eased into, never snapped to (a
	# nearly straight arm swings its elbow by cm for a mm of reach, and shook as the body swayed)
	var full := a + b
	var soft := full * SOFT_FROM
	var d := maxf(to.length(), 0.01)
	if d > soft:
		d = soft + (full - soft) * (1.0 - exp(-(d - soft) / (full - soft)))
	d = minf(d, full * 0.999)
	var dir := to.normalized()
	# the elbow: on the circle the two bones allow, on the pole's side
	var cos_a := clampf((a * a + d * d - b * b) / (2.0 * a * d), -1.0, 1.0)
	var side := (pole - s) - dir * (pole - s).dot(dir)
	side = side.normalized() if side.length() > 0.0001 else dir.cross(Vector3.RIGHT).normalized()
	var elbow := s + dir * a * cos_a + side * a * sqrt(1.0 - cos_a * cos_a)
	gu.basis = Basis(Quaternion((e - s).normalized(), (elbow - s).normalized())) * gu.basis
	sk.set_bone_global_pose(upper, gu)
	var gl := sk.get_bone_global_pose(lower)
	var e2 := gl.origin
	var h2 := sk.get_bone_global_pose(hand).origin
	gl.basis = Basis(Quaternion((h2 - e2).normalized(), (s + dir * d - e2).normalized())) * gl.basis
	sk.set_bone_global_pose(lower, gl)
