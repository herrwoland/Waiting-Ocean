class_name LeviathanSplash extends Node3D
## The water a body the size of the Leviathan throws about. It reads the body's colliders every
## physics frame (track()) and finds, all along it, where each cross-section cuts the waterline
## and how fast each side of it is driving into the water there. Wherever a side pushes the sea
## aside at u m/s, the water climbs it and is flung off, up to about u^2 / 2g (what a film's
## whitewater solver keys on too: water that is suddenly accelerated). That one rule makes:
##  - the bow: the blunt head shoves the sea aside at its full speed (50 m/s: walls ~100 m high);
##  - surfacing: the waterline races outward round the head as it comes up, faster than it rises;
##  - turns and the tail beat: the side swinging into the water throws it;
##  - diving: the sea closes over the back and the meeting water is thrown up between;
## and while a part is newly out of the water, it pours off it in cascades.
## The sea itself answers too (water shapes, like a WaterDeformer): the open mouth swallows the water
## in front of it, so the sea is drawn down into it there, while either side of the opening it is
## piled up against the cheeks, about V^2 / 2g high at full tilt, and breaks where that is steep.
## As in film work, the water is built in stages (bulk sheets, then lumps, then drops and a mist
## that hangs on long after), the bigger the slower: it all flies under real gravity. Each
## stretch of the body also leaves a churned wake on the sea (WakeEmitters it moves itself).

const SHEET_TEXTURE := preload('res://assets/textures/water_splash.png')
const SPRAY_TEXTURE := preload('res://assets/water/sea_spray.png')
const SPRAY_SHADER := preload('res://assets/shaders/particles/leviathan_spray.gdshader')
const DRAW_SHADER := preload('res://assets/shaders/spatial/leviathan_spray_draw.gdshader')
const G := 9.8
const FLAGS := GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_VELOCITY \
		| GPUParticles3D.EMIT_FLAG_COLOR | GPUParticles3D.EMIT_FLAG_CUSTOM
enum Kind { SHEET, PUFF, DROP, MIST }

## Speed (m/s) a side must drive into the water before it throws any.
@export var min_push := 2.5
## How high the water climbs for the speed it is hit at, x u^2 / 2g (1 = all of it, as at the
## very front of a blunt bow; a slick body lets less climb).
@export_range(0.0, 2.0, 0.01) var climb := 0.8
## The tallest a sheet may stand (m).
@export var max_height := 140.0
## Fastest a side may drive into the water (m/s): guards against a jump in the pose.
@export var max_push := 60.0
## How much spray overall (thins every layer alike).
@export_range(0.0, 3.0, 0.05) var density := 1.0
## Seconds the water keeps pouring off a part after it has come out.
@export var pour_time := 9.0
## Farther than this from the camera, nothing is thrown.
@export var cull_distance := 4000.0
@export var spray_color := Color(0.82, 0.88, 0.9, 0.92) # sea water, a little grey-green
## How bright the spray is in the light falling on it (1 = as bright as white sea foam there).
@export_range(0.0, 3.0, 0.01) var spray_brightness := 0.9
## A churned wake left behind each stretch of the body that is in the water.
@export var leave_wake := true
## How far (m) behind the mouth the body begins: anything of the colliders in front of that is not
## body (the mouth is open there).
@export var mouth_trim := 0.0

@export_group('Crown')
## Where its back first breaks the surface coming up, the water heaped on it (the HeadWater dome)
## and what the climb throws burst up and fall off it. Height x this (1 = just that water).
@export_range(0.0, 3.0, 0.05) var crown_drama := 1.8
## How much water each burst throws (thins or thickens it).
@export_range(0.0, 4.0, 0.05) var crown_amount := 2.0
## Seconds a burst lasts.
@export var crown_time := 2.5

@export_group('Jaw corners')
## Markers on the corners of the mouth (children of the Leviathan named jaw_splash_zone...): the
## water rushing into the open mouth slams into the jaw's edge there head-on, the hardest-hit
## water on the whole body. Each throws as much as this many metres of flank would.
@export var jaw_amount := 60.0
## How high the water climbs a jaw corner, x V^2 / 2g (1 = all of it: a blunt edge met head-on).
@export_range(0.0, 2.0, 0.01) var jaw_climb := 1.0
## A corner farther than this (m) above or below the sea throws nothing.
@export var jaw_band := 30.0

@export_group('Bow wave')
## Height of the water piled against the cheeks, x V^2 / 2g (a blunt bow piles it to about half the
## height the water would climb at a dead stop; the open mouth lets the rest through).
@export_range(0.0, 1.5, 0.01) var bow_pile := 0.25
## How deep the sea is drawn down into the open mouth, x V^2 / 2g.
@export_range(0.0, 1.0, 0.01) var mouth_draw := 0.2

@export_group('Budget')
@export var max_sheets := 400
@export var max_puffs := 900
@export var max_drops := 1400
@export var max_mist := 90

var _water: Node
var _layers := {} # Kind -> GPUParticles3D
var _stations: Array = [] # see _build_stations()
var _wakes: Array[WakeEmitter] = []
var _jaws: Array = [] # per mouth corner: the same bookkeeping as a station (see _build_stations)
var _rng := RandomNumberGenerator.new()
const UPDATE_EVERY := 2 # physics frames per update
const SEA_STEP := 8 # sections per reading of the waves
const SLICE := 24.0 # m along the body between cross-sections
var _frame := 0
var _skipped := 0.0 # s since the last update
var _bow_at := Vector3.INF # the middle of the front of the body at the waterline (INF: not in the water)
var _bow_fwd := Vector3.ZERO # the way it faces (flat)
var _bow_w := 0.0 # its half-width at the waterline (m)
var _bow_speed := 0.0 # m/s through the water, eased (the sea takes a moment to pile up)
var emitted := [0, 0, 0, 0]
## The body at rest, measured from its colliders in setup() (m, from the middle of the mouth): how
## far it stands above that, hangs below it and reaches to either side. 0 without colliders.
var body_top := 0.0
var body_bottom := 0.0
var body_side := 0.0
var last_crown := 0.0 # height (m) of the last crown burst thrown # particles placed so far, per layer (for a look in the debugger)

## The body to follow, called once at rest: its colliders (each with a CollisionShape3D child
## holding a capsule or a box lying along its local Y) and the head, whose origin is the mouth.
func setup(colliders: Array[Node3D], mouth: Node3D) -> void:
	_rng.randomize()
	add_to_group(&'water_deformer') # water.gd takes our bow wave from pack_shapes()
	_build_stations(colliders, mouth)
	for marker in get_parent().find_children('jaw_splash_zone*', 'Node3D', false):
		# its ellipse is a point; the way to the tail is the Leviathan's +Z, in the marker's space
		var to_tail: Vector3 = (marker as Node3D).global_basis.inverse() * get_parent().global_basis.z
		_jaws.append({col = marker, centre = Vector3.ZERO, across = Vector3.ZERO, updown = Vector3.ZERO,
				along = to_tail, c = Vector3.INF, credit = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]})
	_layers[Kind.SHEET] = _make_layer(Kind.SHEET, max_sheets, SHEET_TEXTURE)
	_layers[Kind.PUFF] = _make_layer(Kind.PUFF, max_puffs, SHEET_TEXTURE)
	_layers[Kind.DROP] = _make_layer(Kind.DROP, max_drops, _drop_texture())
	_layers[Kind.MIST] = _make_layer(Kind.MIST, max_mist, SPRAY_TEXTURE)
	if leave_wake:
		for i in 3: # the bow, the widest part, the last part in the water
			var w := WakeEmitter.new()
			w.top_level = true
			w.full_speed = 25.0
			w.min_speed = 2.0
			w.max_height_above_water = 20.0
			w.edge_bias = 0.55
			add_child(w)
			_wakes.append(w)

## Cross-sections along the body, worked out once at rest from the colliders' own shapes (any kind:
## meshes, capsules, boxes...): each collider's surface is sliced every SLICE m along the body and
## each slice fitted with an ellipse, kept in the collider's own space so it bends with its bone.
## Where colliders overlap only the outside of the body is kept (the widest slice there).
## Each: {col, centre / across / updown / along (the ellipse's middle, half-width, half-height and
## the way to the tail, in the collider's space), s (m behind the mouth at rest), width (its
## half-width, m), len (m of body it stands for)} plus what is tracked from frame to frame.
func _build_stations(colliders: Array[Node3D], mouth: Node3D) -> void:
	var cands := []
	var origin := mouth.global_position
	var fwd := -mouth.global_basis.z.normalized() # the way the mouth faces
	var right := mouth.global_basis.x.normalized()
	for col in colliders:
		var pts := PackedVector3Array()
		for cs in col.get_children():
			if cs is CollisionShape3D and (cs as CollisionShape3D).shape:
				pts.append_array(_surface_points(cs))
		if pts.is_empty():
			continue
		# slice it along the body
		var slices := {} # slice index -> [x min, x max, y min, y max]
		for p in pts:
			var rel := p - origin
			var k := int(floor(rel.dot(-fwd) / SLICE))
			var x := rel.dot(right)
			body_top = maxf(body_top, rel.y)
			body_bottom = maxf(body_bottom, -rel.y)
			body_side = maxf(body_side, absf(x))
			var e: Array = slices.get(k, [INF, -INF, INF, -INF])
			slices[k] = [minf(e[0], x), maxf(e[1], x), minf(e[2], p.y), maxf(e[3], p.y)]
		var rest := col.global_transform
		var to_col := rest.affine_inverse()
		var basis_inv := rest.basis.inverse()
		for k: int in slices:
			var e: Array = slices[k]
			var s_at := (k + 0.5) * SLICE
			var half_w: float = (e[1] - e[0]) * 0.5
			var half_h: float = (e[3] - e[2]) * 0.5
			if s_at < mouth_trim or half_w < 1.0 or half_h < 0.5:
				continue # in front of the mouth (it is open there), or a sliver
			var centre: Vector3 = origin + fwd * -s_at + right * (e[0] + e[1]) * 0.5
			centre.y = (e[2] + e[3]) * 0.5
			cands.append({col = col, s = s_at, width = half_w,
					centre = to_col * centre, across = basis_inv * (right * half_w),
					updown = basis_inv * (Vector3.UP * half_h), along = basis_inv * -fwd})
	# keep the outside of the body: the widest slice at each place along it
	for a in cands:
		var widest: float = a.width
		for b in cands:
			if absf(b.s - a.s) < SLICE * 0.6:
				widest = maxf(widest, b.width)
		if a.width >= widest * 0.92:
			_stations.append(a)
	_stations.sort_custom(func(a, b): return a.s < b.s)
	for i in _stations.size():
		var st: Dictionary = _stations[i]
		var prev_s: float = _stations[i - 1].s if i > 0 else st.s
		var next_s: float = _stations[i + 1].s if i < _stations.size() - 1 else st.s
		st.len = maxf((next_s - prev_s) * 0.5, 4.0)
		# how fast the body widens going back from here: tilts its surface to face forward, so
		# swimming it shoves the water ahead aside (the front faces straight ahead: a blunt bow)
		st.slope = 3.0 if i == 0 else clampf((st.width - _stations[i - 1].width) / maxf(st.s - _stations[i - 1].s, 1.0), -3.0, 3.0)
		st.w = 0.0 # half-width at the waterline (m), 0 = not cutting it
		st.c = Vector3.INF # axis point last frame
		st.state = 0 # -1 all under, 1 all out, 0 cutting the waterline
		st.out_t = 99.0 # s since its top came out
		st.top_was = 0.0 # how far its top stood out last frame
		st.push = [0.0, 0.0] # how fast each side (left, right) drove into the water last frame
		st.crown = false # its top broke the surface coming up: bursting through (see _crown())
		st.crown_credit = [0.0, 0.0, 0.0, 0.0]
		st.credit = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0] # per side and layer: particles owed

## Points over a collision shape's surface, in world space (its edges filled in, so a mesh made of
## a few big triangles still lands in every slice it spans).
static func _surface_points(cs: CollisionShape3D) -> PackedVector3Array:
	var local := shape_points(cs.shape, SLICE * 0.4 / cs.global_basis.get_scale().x)
	var m := cs.global_transform
	var out := PackedVector3Array()
	out.resize(local.size())
	for i in local.size():
		out[i] = m * local[i]
	return out

## Points over a shape's surface, in its own space. A mesh's edges are filled in every `edge_step`.
static func shape_points(shape: Shape3D, edge_step: float) -> PackedVector3Array:
	var local := PackedVector3Array()
	if shape is ConcavePolygonShape3D:
		var faces: PackedVector3Array = shape.get_faces()
		for t in range(0, faces.size() - 2, 3):
			for e in 3:
				var p0 := faces[t + e]
				var p1 := faces[t + (e + 1) % 3]
				var steps := maxi(1, ceili(p0.distance_to(p1) / edge_step))
				for q in steps:
					local.append(p0.lerp(p1, float(q) / steps))
	elif shape is ConvexPolygonShape3D:
		local = shape.points
	elif shape is CapsuleShape3D or shape is CylinderShape3D or shape is SphereShape3D:
		var r: float = shape.radius
		var half: float = r if shape is SphereShape3D else shape.height * 0.5
		var cap: float = r if (shape is CapsuleShape3D or shape is SphereShape3D) else 0.0
		for k in 17:
			var y := lerpf(-half, half, k / 16.0)
			var into := absf(y) - (half - cap)
			var ry := r * sqrt(maxf(1.0 - pow(into / cap, 2.0), 0.0)) if cap > 0.0 and into > 0.0 else r
			for j in 12:
				var a := TAU * j / 12.0
				local.append(Vector3(cos(a) * ry, y, sin(a) * ry))
	elif shape is BoxShape3D:
		var h: Vector3 = shape.size * 0.5
		for x in 5:
			for y in 5:
				for z in 5:
					local.append(Vector3(lerpf(-h.x, h.x, x / 4.0), lerpf(-h.y, h.y, y / 4.0), lerpf(-h.z, h.z, z / 4.0)))
	return local

## The body is heaving itself up out of the sea (the Leviathan's breach): every part of it in the
## water bursts through anew, the sea heaped on it thrown up and off (the crown) and pouring down
## its flanks, just as when it first came up.
func breach() -> void:
	for st: Dictionary in _stations:
		if st.state != -1:
			st.out_t = 0.0
			st.crown = true

## A station's ellipse now: [middle, half-width vector, half-height vector, way to the tail (unit)].
static func _now(st: Dictionary) -> Array:
	var m: Transform3D = st.col.global_transform
	return [m * (st.centre as Vector3), m.basis * (st.across as Vector3), m.basis * (st.updown as Vector3), (m.basis * (st.along as Vector3)).normalized()]

## Every physics frame, after the body has been posed. The work is done every other frame (the
## spray owed piles up meanwhile, so nothing is lost): the sea is read at only some of the
## sections and filled in between, the costly part being reading the waves on the CPU.
func track(delta: float) -> void:
	if delta <= 0.0 or _stations.is_empty():
		return
	_skipped += delta
	_frame += 1
	if _frame % UPDATE_EVERY != 0:
		return
	delta = _skipped
	_skipped = 0.0
	if not is_instance_valid(_water):
		_water = get_tree().get_first_node_in_group(&'water')
		if _water == null:
			return
	# all of it well under the waves (rising from the deep, gone down): nothing to do
	var level: float = _water.global_position.y
	var shallowest := -INF
	for st: Dictionary in _stations:
		var m: Transform3D = st.col.global_transform
		shallowest = maxf(shallowest, (m * (st.centre as Vector3)).y + (m.basis * (st.updown as Vector3)).length() * 1.5)
	if shallowest < level - 40.0:
		for st: Dictionary in _stations:
			st.c = Vector3.INF
			st.state = -1
			st.top_was = -1.0
		_place_wakes(-1, -1, -1)
		_track_bow(-1, delta)
		return
	# the sea under every SEA_STEP-th section (and the last), straight lines between
	var n := _stations.size()
	var seas := PackedFloat32Array()
	seas.resize(n)
	var last := -1
	for i in n:
		if i % SEA_STEP != 0 and i != n - 1:
			continue
		var st: Dictionary = _stations[i]
		seas[i] = _water.get_wave_height((st.col as Node3D).global_transform * (st.centre as Vector3), false)
		if last >= 0:
			for j in range(last + 1, i):
				seas[j] = lerpf(seas[last], seas[i], float(j - last) / float(i - last))
		last = i
	var cam := get_viewport().get_camera_3d()
	var near := cam != null and cam.global_position.distance_to(_stations[0].col.global_position) < cull_distance
	var wake_bow := -1
	var wake_wide := -1
	var wake_stern := -1
	for i in _stations.size():
		var st: Dictionary = _stations[i]
		var now := _now(st)
		var c: Vector3 = now[0]
		var a: Vector3 = now[1] # across
		var b: Vector3 = now[2] # up and down
		var along: Vector3 = now[3]
		var sea: float = seas[i]
		# where the ellipse c + a cos f + b sin f meets the sea: a.y cos f + b.y sin f = sea - c.y
		var reach := sqrt(a.y * a.y + b.y * b.y)
		var d := sea - c.y
		var top := c.y + reach - sea # how far its top stands out
		var vel: Vector3 = Vector3.ZERO if st.c == Vector3.INF else (c - st.c) / delta
		var went_under: bool = top <= 0.0 and st.top_was > 0.0
		if top > 0.0 and st.top_was <= 0.0:
			st.out_t = 0.0 # its top just came out
			st.crown = vel.y > 1.0 # coming up, not a wave washing off it
		st.out_t += delta
		st.top_was = top
		st.c = c
		var w := 0.0
		var mid := Vector3(c.x, sea, c.z)
		var left := Vector3.UP.cross(Vector3(along.x, 0.0, along.z)).normalized() # left of the way to the tail
		var sides: Array[Vector3] = [] # the two waterline points: left, right
		var normals: Array[Vector3] = [] # the body's outward surface there
		var state := 0
		if d >= reach:
			state = -1
		elif d <= -reach:
			state = 1
		else:
			var f0 := atan2(b.y, a.y)
			var df := acos(clampf(d / maxf(reach, 0.001), -1.0, 1.0))
			var ia := a / maxf(a.length_squared(), 0.001)
			var ib := b / maxf(b.length_squared(), 0.001)
			for f: float in [f0 + df, f0 - df]:
				sides.append(c + a * cos(f) + b * sin(f))
				# the section's outward normal there, tilted forward where the body widens behind it
				var nrm := (ia * cos(f) + ib * sin(f)).normalized()
				normals.append((nrm - along * st.slope).normalized())
			if (sides[0] - sides[1]).dot(left) < 0.0:
				sides.reverse()
				normals.reverse()
			w = Vector3(sides[0].x - sides[1].x, 0.0, sides[0].z - sides[1].z).length() * 0.5
			mid = (sides[0] + sides[1]) * 0.5
			mid.y = sea
		st.w = w
		st.state = state
		# going under: the sea closes over its back and the water meeting from both sides is
		# thrown up between them, as fast as they met
		if went_under and near:
			var meet := 2.0 * maxf(-vel.y, 0.0) + 0.3 * absf(vel.dot(left))
			if meet > min_push:
				_throw(st, 0, mid, Vector3.ZERO, minf(meet, max_push), st.len, vel, 1.0) # one burst
		# bursting through: the water heaped on its back thrown up and off where its top comes out
		if st.crown and st.out_t < crown_time and near:
			var f_top := atan2(b.y, a.y)
			var crest := c + a * cos(f_top) + b * sin(f_top)
			var heaped := maxf(sea - _water.global_position.y, 0.0) + vel.y * vel.y / (2.0 * G)
			_crown(st, Vector3(crest.x, sea, crest.z), minf(heaped * crown_drama, max_height), a.length(), exp(-st.out_t / (crown_time * 0.35)), vel, delta)
			last_crown = minf(heaped * crown_drama, max_height) # for a look in the debugger
		if state != 0:
			continue
		if wake_bow < 0: wake_bow = i
		wake_stern = i
		if wake_wide < 0 or w > _stations[wake_wide].w: wake_wide = i
		if not near:
			continue
		var len_m: float = st.len
		for k in 2:
			# the water there is shoved as fast as the body's surface moves into it
			var u := clampf(vel.dot(normals[k]), -max_push, max_push)
			st.push[k] = u # for a look in the debugger
			var at := Vector3(sides[k].x, sea, sides[k].z)
			var out := left * (1.0 if k == 0 else -1.0)
			if u > min_push:
				_throw(st, k * 4, at, out, u, len_m, vel, delta)
			# newly out: the water it lifted pours off it down its flank
			# (it falls from as high as the part now stands; less and less is left to fall)
			if top > 3.0 and st.out_t < pour_time * 2.0:
				_pour(st, k * 4, at, out, minf(top, max_height), exp(-st.out_t / pour_time), len_m, delta)
	_place_wakes(wake_bow, wake_wide, wake_stern)
	_track_bow(wake_bow, delta)
	if near:
		_track_jaws(delta)

## The mouth's corners: the sea streams into the open mouth at the speed it swims and slams into
## the jaw's edge at each side, climbing it all the way to V^2 / 2g and flung out to the side.
func _track_jaws(delta: float) -> void:
	for jaw: Dictionary in _jaws:
		var p: Vector3 = (jaw.col as Node3D).global_position
		var vel: Vector3 = Vector3.ZERO if jaw.c == Vector3.INF else (p - jaw.c) / delta
		jaw.c = p
		var sea: float = _water.get_wave_height(p, false)
		if absf(p.y - sea) > jaw_band:
			continue
		var tail: Vector3 = _now(jaw)[3]
		var fwd := -Vector3(tail.x, 0.0, tail.z).normalized()
		var mouth: Vector3 = get_parent().global_position
		var out := Vector3(p.x - mouth.x, 0.0, p.z - mouth.z)
		out = (out - fwd * out.dot(fwd)).normalized() # straight out to its side
		# met head-on as it swims, plus the jaw slapping up and down through the surface
		var u := minf(maxf(vel.dot(fwd), 0.0) + absf(vel.y), max_push)
		if u > min_push:
			_throw(jaw, 0, Vector3(p.x, sea, p.z), (out + fwd * 0.3).normalized(), u, jaw_amount, vel, delta, jaw_climb)

## The front of the body in the water, for the bow wave.
func _track_bow(front: int, delta: float) -> void:
	if front < 0:
		_bow_at = Vector3.INF
		_bow_speed = 0.0
		return
	var st: Dictionary = _stations[front]
	var tail: Vector3 = _now(st)[3]
	var fwd := -Vector3(tail.x, 0.0, tail.z).normalized()
	var moved: Vector3 = Vector3.ZERO if _bow_at == Vector3.INF else (Vector3(st.c.x, 0.0, st.c.z) - Vector3(_bow_at.x, 0.0, _bow_at.z)) / delta
	_bow_at = Vector3(st.c.x, _water.global_position.y, st.c.z)
	_bow_fwd = fwd
	_bow_w = st.w
	var speed := maxf(moved.dot(fwd), 0.0) if moved.length() < 200.0 else _bow_speed
	_bow_speed = lerpf(_bow_speed, speed, 1.0 - exp(-0.8 * delta))

## ---- the sea's side (called by water.gd, like a WaterDeformer) ------------------------

func update_state(_delta: float, _water_level: float) -> void:
	pass # all worked out in track()

## The bow wave: the sea piled against both cheeks, and drawn down into the open mouth between.
## Same packing as WaterDeformer.pack_shapes(): dome a = (x, z, width, height),
## b = (trough, calm, 0, foam); a negative height is a hollow.
func pack_shapes() -> Array:
	if _bow_at == Vector3.INF or _bow_w < 1.0:
		return []
	var head := _bow_speed * _bow_speed / (2.0 * G) # how high the water would climb at a dead stop
	var pile := bow_pile * head
	var draw := mouth_draw * head
	if pile < 0.3:
		return []
	var left := Vector3.UP.cross(_bow_fwd)
	var width := _bow_w * 0.5
	# breaks along its crest where it stands steep (a dome's steepest slope is 0.86 h / width)
	var foam := smoothstep(0.15, 0.35, 0.86 * pile / maxf(width, 1.0)) * 0.9
	var shapes := []
	for sgn: float in [1.0, -1.0]:
		var p := _bow_at + left * sgn * _bow_w * 0.85 + _bow_fwd * _bow_w * 0.15
		shapes.append([Vector4(p.x, p.z, width, pile), Vector4(0.0, 0.5, 0.0, foam)])
	if draw > 0.3:
		var p := _bow_at + _bow_fwd * _bow_w * 0.3
		shapes.append([Vector4(p.x, p.z, _bow_w * 0.45, -draw), Vector4(0.0, 0.3, 0.0, 0.0)])
	return shapes

## Water flung off a side driving into it at u m/s: a sheet climbing it, lumps and drops thrown
## up and out, and a mist that hangs where a big one was.
func _throw(st: Dictionary, slot: int, at: Vector3, out: Vector3, u: float, len_m: float, carry: Vector3, delta: float, how_high := -1.0) -> void:
	var h := minf((climb if how_high < 0.0 else how_high) * u * u / (2.0 * G), max_height)
	if h < 1.0:
		return
	var rise := sqrt(2.0 * h / G)
	var sheet_life := 2.0 * rise + 0.8
	var sheet_w := h * 0.84
	# an unbroken curtain: sheets side by side along the stretch, each renewed once a life, and a
	# new one each time the body has swept on by half a sheet into fresh water
	var sweep := Vector2(carry.x, carry.z).length()
	var gap := maxf(sheet_w * 0.5, 1.0)
	_owe(st, slot + 0, minf(len_m / gap / sheet_life + sweep / gap, 4.0) * density * delta)
	var lumps := (len_m + sweep) * minf(u / 20.0, 2.5) * density * delta
	_owe(st, slot + 1, lumps * 0.12)
	_owe(st, slot + 2, lumps * 0.18)
	if h > 12.0:
		_owe(st, slot + 3, (len_m + sweep) * 0.006 * minf(h / 40.0, 3.0) * density * delta)
	var credit: Array = st.credit
	var up := Vector3.UP
	# thrown up and out at about 55 degrees (straight up where the sides meet), carrying a little
	# of the body's own motion
	var throw_dir := (out * 0.57 + up * 0.82).normalized() if out != Vector3.ZERO else up
	while credit[slot] >= 1.0:
		credit[slot] -= 1.0
		var p := at + _along(st, len_m) + out * _rng.randf_range(0.0, h * 0.1)
		var hh := h * _rng.randf_range(0.7, 1.05)
		_emit(Kind.SHEET, p, Vector3.ZERO, hh, 2.0 * sqrt(2.0 * hh / G) + 0.8)
	while credit[slot + 1] >= 1.0:
		credit[slot + 1] -= 1.0
		var v := _jitter(throw_dir, 0.25) * u * _rng.randf_range(0.55, 1.0) + carry * 0.3
		_emit(Kind.PUFF, at + _along(st, len_m), v, clampf(h * 0.3, 4.0, 45.0) * _rng.randf_range(0.7, 1.3), _flight(v))
	while credit[slot + 2] >= 1.0:
		credit[slot + 2] -= 1.0
		var v := _jitter(throw_dir, 0.4) * u * _rng.randf_range(0.4, 1.1) + carry * 0.3
		_emit(Kind.DROP, at + _along(st, len_m), v, clampf(h * 0.09, 1.5, 11.0) * _rng.randf_range(0.7, 1.3), _flight(v))
	while credit[slot + 3] >= 1.0:
		credit[slot + 3] -= 1.0
		var v := up * _rng.randf_range(1.0, 3.0) + out * _rng.randf_range(0.5, 2.0)
		var pos := at + _along(st, len_m) + up * h * _rng.randf_range(0.2, 0.5)
		_emit(Kind.MIST, pos, v, h * _rng.randf_range(0.5, 0.9), _rng.randf_range(9.0, 16.0))

## A part bursting up through the surface at `at`: sheets standing in a ring round where its top
## comes out, lumps and drops flung up off it, and a mist that hangs over it all. `h` is how high
## (m), `across` its half-width, `left` how much of the burst is still to come (1 = just broke).
func _crown(st: Dictionary, at: Vector3, h: float, across: float, left: float, carry: Vector3, delta: float) -> void:
	if h < 2.0:
		return
	var k := crown_amount * density * left * delta
	var credit: Array = st.crown_credit
	credit[0] = minf(credit[0] + 8.0 * k, 8.0)
	credit[1] = minf(credit[1] + 40.0 * k, 8.0)
	credit[2] = minf(credit[2] + 70.0 * k, 8.0)
	credit[3] = minf(credit[3] + (3.0 if h > 12.0 else 0.0) * k, 8.0)
	var up := sqrt(2.0 * G * h)
	var ring := across * 0.45
	while credit[0] >= 1.0:
		credit[0] -= 1.0
		var a := _rng.randf_range(0.0, TAU)
		var hh := h * _rng.randf_range(0.6, 1.0)
		_emit(Kind.SHEET, at + Vector3(cos(a), 0.0, sin(a)) * ring * _rng.randf_range(0.3, 1.0), Vector3.ZERO, hh, 2.0 * sqrt(2.0 * hh / G) + 0.8)
	while credit[1] >= 1.0:
		credit[1] -= 1.0
		var v := _jitter(Vector3.UP, 0.45) * up * _rng.randf_range(0.5, 1.0) + carry * 0.5
		var a := _rng.randf_range(0.0, TAU)
		_emit(Kind.PUFF, at + Vector3(cos(a), 0.0, sin(a)) * ring * _rng.randf(), v, clampf(h * 0.3, 4.0, 45.0) * _rng.randf_range(0.7, 1.3), _flight(v))
	while credit[2] >= 1.0:
		credit[2] -= 1.0
		var v := _jitter(Vector3.UP, 0.6) * up * _rng.randf_range(0.4, 1.1) + carry * 0.5
		var a := _rng.randf_range(0.0, TAU)
		_emit(Kind.DROP, at + Vector3(cos(a), 0.0, sin(a)) * ring * _rng.randf(), v, clampf(h * 0.09, 1.5, 11.0) * _rng.randf_range(0.7, 1.3), _flight(v))
	while credit[3] >= 1.0:
		credit[3] -= 1.0
		var v := Vector3.UP * _rng.randf_range(1.0, 3.0) + carry * 0.3
		_emit(Kind.MIST, at + Vector3.UP * h * _rng.randf_range(0.3, 0.6), v, h * _rng.randf_range(0.6, 1.0), _rng.randf_range(10.0, 16.0))

## Water running off a part that has come out and stands `height` m tall: cascades down its flank
## (sheets standing on the sea there) and the drops that rain off its edge. `left` is how much of
## the water it brought up is still on it (1 = just out).
func _pour(st: Dictionary, slot: int, at: Vector3, out: Vector3, height: float, left: float, len_m: float, delta: float) -> void:
	var life := 2.0 * sqrt(2.0 * height / G) + 0.8
	_owe(st, slot + 0, clampf(len_m / maxf(height * 0.5, 1.0), 0.5, 10.0) / life * density * delta * left)
	_owe(st, slot + 2, len_m * 0.25 * density * delta * left)
	var credit: Array = st.credit
	while credit[slot] >= 1.0:
		credit[slot] -= 1.0
		_emit(Kind.SHEET, at + _along(st, len_m) + out * 2.0, Vector3.ZERO, height * _rng.randf_range(0.6, 1.0), life)
	while credit[slot + 2] >= 1.0:
		credit[slot + 2] -= 1.0
		var from := at + _along(st, len_m) + Vector3.UP * height * _rng.randf_range(0.3, 0.9) - out * height * 0.15
		var v := out * _rng.randf_range(1.0, 4.0) + Vector3.DOWN * _rng.randf_range(0.0, 3.0)
		_emit(Kind.DROP, from, v, _rng.randf_range(1.5, 4.0), sqrt(2.0 * maxf(from.y - at.y, 1.0) / G) + 0.3)

func _owe(st: Dictionary, k: int, amount: float) -> void:
	st.credit[k] = minf(st.credit[k] + amount, 8.0) # never a backlog flood after a hitch

## A random spot along the stretch a station stands for.
func _along(st: Dictionary, len_m: float) -> Vector3:
	var tail: Vector3 = _now(st)[3]
	var axis := Vector3(tail.x, 0.0, tail.z).normalized()
	return axis * _rng.randf_range(-0.5, 0.5) * len_m

func _jitter(dir: Vector3, amount: float) -> Vector3:
	return (dir + Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * amount).normalized()

## Time to fall back to the sea from a throw (s), a little longer for the air holding it.
static func _flight(v: Vector3) -> float:
	return clampf(2.0 * maxf(v.y, 1.0) / G + 0.6, 1.0, 18.0)

func _emit(kind: Kind, at: Vector3, v: Vector3, size: float, life: float) -> void:
	emitted[kind] += 1
	var custom := Color(_rng.randf_range(0.0, TAU), size, life, 0.0)
	(_layers[kind] as GPUParticles3D).emit_particle(Transform3D(Basis(), at), v, Color.WHITE, custom, FLAGS)

## The wake emitters onto the bow, the widest part and the last part cutting the water.
func _place_wakes(bow: int, wide: int, stern: int) -> void:
	var picks := [bow, wide, stern]
	for k in _wakes.size():
		var i: int = picks[k]
		var wk := _wakes[k]
		if i < 0:
			wk.foam = 0.0
			wk.churn = 0.0
			continue
		var st: Dictionary = _stations[i]
		wk.global_position = Vector3(st.c.x, _water.global_position.y, st.c.z)
		wk.half_width = maxf(st.w * 0.9, 2.0)
		wk.foam = 0.9
		wk.churn = 1.0

## ---- the particles ------------------------------------------------------------------

func _make_layer(kind: Kind, count: int, texture: Texture2D) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.top_level = true
	p.amount = count
	p.lifetime = 30.0 # the longest any may live; each has its own
	p.local_coords = false
	p.emitting = false # only what the script places
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-4000, -200, -4000), Vector3(8000, 800, 8000)) # follows the body anywhere
	var pm := ShaderMaterial.new()
	pm.shader = SPRAY_SHADER
	pm.set_shader_parameter(&'kind', kind)
	match kind:
		Kind.SHEET:
			pm.set_shader_parameter(&'drag', 0.0)
		Kind.PUFF:
			pm.set_shader_parameter(&'drag', 0.25) # lumps of water: the air barely holds them
			pm.set_shader_parameter(&'grow', 2.2) # they break up into spray as they fly
		Kind.DROP:
			pm.set_shader_parameter(&'drag', 0.6)
			pm.set_shader_parameter(&'grow', 0.7)
		Kind.MIST:
			pm.set_shader_parameter(&'gravity', 0.2)
			pm.set_shader_parameter(&'drag', 0.3)
			pm.set_shader_parameter(&'wind', Vector3(1.2, 0.0, 0.6))
			pm.set_shader_parameter(&'grow', 2.4)
	p.process_material = pm
	# drawn turned to the eye but lit as if facing the sky, see leviathan_spray_draw.gdshader
	var mat := ShaderMaterial.new()
	mat.shader = DRAW_SHADER
	mat.set_shader_parameter(&'tex', texture)
	mat.set_shader_parameter(&'tint', Color(spray_color.r * spray_brightness, spray_color.g * spray_brightness,
			spray_color.b * spray_brightness, spray_color.a))
	mat.render_priority = 1 # after the water, never hidden behind it
	var quad := QuadMesh.new()
	match kind:
		Kind.SHEET:
			mat.set_shader_parameter(&'axis_mode', 1) # stands upright, turned to the eye
			quad.center_offset = Vector3(0.0, 0.5, 0.0) # standing on the sea, not sunk to its middle
		Kind.PUFF:
			mat.set_shader_parameter(&'axis_mode', 1) # a burst of water held upright as it flies
		Kind.DROP:
			mat.set_shader_parameter(&'axis_mode', 1) # a streak along its flight
			quad.size = Vector2(0.45, 1.1)
		_:
			mat.set_shader_parameter(&'axis_mode', 0)
	quad.material = mat
	p.draw_pass_1 = quad
	add_child(p)
	return p

## A soft round drop (white centre, fading edge).
static func _drop_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.45, Color(1, 1, 1, 0.8))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 32
	t.height = 32
	return t
