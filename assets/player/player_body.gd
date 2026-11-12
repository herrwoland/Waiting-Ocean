class_name PlayerBody extends Node3D
## The player's own body, only ever seen from inside it: look down and there are your legs, at the
## helm your hands are on the wheel, and the sun throws your whole shadow on the deck. Built from a
## rigged model and an animation library on the same rig (Quaternius' universal humanoid, CC0), so
## any clip in the library plays on it as it is, and a resculpted body keeps working as long as it
## keeps the rig.
##  - Its eyes are pinned to the camera, whatever the clip does (walking, swimming flat out, steering),
##    so the view is always from inside the head. It is scaled once so its eyes stand at the
##    camera's height, which also puts its feet on the ground.
##  - The head is cut out of the copy you see (from inside it would only block the view); a full copy
##    with the head casts the shadow and nothing else.
##  - It plays the clip for what the player is doing (see _pick()).
##  - It has a facing of its own: standing, the view can swing round some way before the feet follow,
##    the rest of the turn taken by the back and neck (see body_rig.gd); walking or swimming it turns
##    with the view; at the helm it faces the wheel with its hands on two spokes. Swimming under the
##    water it lies along the view, head first (see _swim_tilt()), so the strokes are out in front.
##  - Carrying something, its hands hold it at the item's grip markers (see _carry()).
##  - Under the water it is lit like it is that deep (see _depth_tint()), and swimming at the surface
##    its hands splash where they come down through the waves (see _hand_splashes()).

## Every .glb/.gltf in here is a set of clips on the body's rig. The standard library loads first, the
## rest after it by name, so a clip of the same name in a later file replaces the earlier one.
const ANIMATIONS_DIR := 'res://assets/models/player/animations/'
const BASE_ANIMATIONS := 'UAL1_Standard.glb'
## Bones whose skin is cut from the visible copy (and everything below them).
const HEAD_BONES := ['Head']
const BodyRig := preload('res://assets/player/body_rig.gd')
const WATER_MAT := preload('res://assets/water/mat_water.tres') # its underwater_absorption, see _depth_tint()

## The rigged model, a child of this node in player.tscn (swap it there for a resculpted body). It is
## scaled, turned and placed from code every frame, so its transform in the scene is only a preview.
@export var model: Node3D
## How far behind the eyes the camera sits (m): a little, so the inside of the face never shows at
## the edges of the view.
@export var eye_back := 0.08
## Seconds a clip takes to blend into the next.
@export var blend_time := 0.25
## Above 0, the clips move in steps at this many frames per second (the PS1's choppy animation);
## 0 = smooth.
@export_range(0.0, 60.0, 1.0) var anim_fps := 0.0
## Walking speed (m/s) at which the walk clip plays at its own pace (and so on for the others).
@export var walk_pace := 1.6
@export var jog_pace := 3.4
@export var sprint_pace := 6.0
@export var swim_pace := 1.5
## How far (m, in the game) one cycle of the climb clip (Climb) takes the body up a ladder: its
## hands' reach, so they keep pace with the rungs. Climb_Loop's hands go 0.36 m at the rig's own size,
## and the game draws the body 1.24 times that.
@export var climb_cycle := 0.45
@export_group('Ladder')
## Seconds the body takes to go over to the ladder's lean and the ship's motion as it grabs on (and
## back to upright, hung from the camera, as it steps off).
@export var ladder_blend_time := 0.25
## Looking round on a ladder, how far (m) the head leans out to that side by the look limit (the
## Player's ladder_look_limit), and from how far round (degrees) it starts to.
@export var ladder_lean_out := 0.3
@export_range(0.0, 180.0, 1.0) var ladder_lean_from := 40.0
## Fitting the body to the ladder, to put the climb clip's hands and feet on the rails and rungs
## (the view goes with it). In the ladder's own frame, so it holds as the ship rolls; drag them
## with the game running (Remote tree) to see it. Sideways (m, > 0 to the body's right)...
@export_range(-0.5, 0.5, 0.005, 'suffix:m') var ladder_shift_side := 0.0
## ...up and down along the ladder (m)...
@export_range(-1.0, 1.0, 0.005, 'suffix:m') var ladder_shift_up := 0.0
## ...toward the ladder (m, < 0 away from it)...
@export_range(-0.5, 0.5, 0.005, 'suffix:m') var ladder_shift_in := 0.0
## ...and turned about the ladder's length (degrees, > 0 to the left).
@export_range(-45.0, 45.0, 0.5, 'suffix:°') var ladder_turn := 0.0
## The hands moved from where the climb clip puts them (m; the arms bend to follow, the hands keep
## their turn): each out to its side (< 0 in toward the other)...
@export_range(-0.3, 0.3, 0.005, 'suffix:m') var ladder_hands_wider := 0.0
## ...toward the ladder (< 0 back from it)...
@export_range(-0.3, 0.3, 0.005, 'suffix:m') var ladder_hands_in := 0.0
## ...and up (< 0 down).
@export_range(-0.3, 0.3, 0.005, 'suffix:m') var ladder_hands_up := 0.0
## The feet the same way (the legs bend to follow, the feet keep their turn).
@export_range(-0.3, 0.3, 0.005, 'suffix:m') var ladder_feet_wider := 0.0
@export_range(-0.3, 0.3, 0.005, 'suffix:m') var ladder_feet_in := 0.0
@export_range(-0.3, 0.3, 0.005, 'suffix:m') var ladder_feet_up := 0.0
## How far the fingers open from the clip's grip toward an open hand (0 = as the clip has them).
@export_range(0.0, 1.0, 0.01) var ladder_fingers_open := 0.0
@export_group('')
## Seconds the body takes to lie along the view when it starts swimming under the water, and to
## stand back up when it stops (or comes up to the surface).
@export var swim_lean_time := 0.4
## Seconds the body takes to go over to the turn of what holds it (a coiling arm, see
## Player.hold_frame), and to come back upright when let go.
@export var held_blend_time := 1.0
## How quickly the light falling on the body fades with its depth, as a share of the water's own
## absorption (the colour it takes from what you see through it): red goes first, then the rest,
## so deep down the body is a dark shape like everything else. 0 = lit as on the surface.
@export_range(0.0, 2.0, 0.01) var depth_dimming := 1.0
@export_group('Hand Splashes')
## Swimming at the surface, each hand splashes where it comes down through the waves: the
## Player's HeadSplash, copied, with this share of its particles.
@export_range(0.0, 1.0, 0.01) var hand_splash_amount := 0.5
## How close (m) above the waves a hand must come down for its stroke to splash: the swim clip
## carries the hands high, and they only just reach the water (going through it always splashes).
@export var hand_splash_reach := 0.2
## Seconds before the same hand can splash again (the waves bob round it as it sweeps through).
@export var hand_splash_rest := 0.35
## How far (degrees) the view can turn from where the body faces before the feet follow.
@export var free_look := 50.0
## How far (degrees) the back and neck turn toward the view; past that only the eyes go on.
@export var max_twist := 75.0

@export_group('Helm')
## How much farther back (m) than the helm's marker the feet stand from the wheel.
@export var helm_step_back := 0.15
## Where each hand likes to hold (degrees round from the wheel's top, as the helmsman sees it).
@export var hand_home := 35.0
## How far (degrees) a hand is carried round with its handle before it lets go and takes the handle
## nearest home: hand over hand, one hand always on the wheel.
@export var hand_reach := 100.0
## Seconds a hand takes to let go and take a new handle.
@export var regrip_time := 0.28
## The upper body riding the deck: how hard the deck's lurches push it (radians per m/s^2)...
@export var sway_push := 0.02
## ...how much of the deck's tilt it straightens up against (0 = tilts with her, 1 = stays upright)...
@export_range(0.0, 1.0, 0.01) var sway_upright := 0.6
## ...how quickly it swings back (Hz), how soon it settles (0..1), and how far it may lean (degrees).
@export var sway_hz := 1.1
@export_range(0.05, 1.0, 0.01) var sway_damping := 0.55
@export var sway_max := 14.0
@export_group('Carrying')
## How closed the hands are round a carried item (0 = open, 1 = the wheel's grip).
@export_range(0.0, 1.0, 0.01) var carry_grip := 0.5
## How closed the thumbs are (0 = open, as in the rest pose; 1 = wrapped round like the fingers).
@export_range(0.0, 1.0, 0.01) var carry_thumb := 0.15
## How open the hands are while an item comes up into them, reaching to take it.
@export_range(0.0, 1.0, 0.01) var carry_reach_open := 0.15
## How quickly (per second) the hands close round it once it is there, or open again.
@export var carry_close_speed := 4.0
## Seconds an item takes to go from where it flies up to into the hand that takes it.
@export var carry_take_time := 0.4
## How still the back and shoulders are held while carrying, against the walk's swing from step to
## step (they keep its lean): the arms reach from them, so swinging with the clip they swung the
## hands and what they held up and down (0 = as the clip swings them, 1 = steadied fully).
@export_range(0.0, 1.0, 0.01) var carry_steady := 0.9
## How far out (m) from the item's sides the hands hold one that has no Grip_L / Grip_R markers.
@export var carry_side_gap := 0.02
@export_group('')

var player # the Player (player.gd): its state, Head and Camera3D
var _model: Node3D
var _skel: Skeleton3D
var _anim: AnimationPlayer
var _head_bone := -1
var _eye_in_head := Vector3.ZERO # the eyes, in the head bone's space
var _current := &''
var _step_left := 0.0
var _airborne := 0.0 # s off the ground
var _landing := 0.0 # s left of the landing clip
var _rig: BodyRig
var _yaw := NAN # where the body faces (the view's yaw convention), apart from the view
var _helm_ship: Node # the ship whose wheel we found
var _wheel: Node3D # her steering wheel, its axle and size (see _find_wheel())
var _wheel_axle := Vector3.RIGHT # in the wheel's own space
var _handles: Array[Node3D] = [] # the wheel's grip markers (Steering_*), round its rim
var _hold := [-1, -1] # per hand (left, right): the handle it holds
var _regrip := [-1.0, -1.0] # per hand: seconds into taking a new handle (< 0: holding)
var _regrip_from := [Vector3.ZERO, Vector3.ZERO] # where the hand let go (world)
var _lean := Vector2.ZERO # the upper body's lean on its spring, and how fast it swings
var _lean_v := Vector2.ZERO
var _stand_was := Vector3.INF # where the feet stood, and how fast they moved (the deck's lurch)
var _stand_v := Vector3.ZERO
var _lurch := Vector3.ZERO
const SWAY_SMOOTH := 0.12 # s: how long the deck's motion is smoothed over before the body feels it
var _arm_reach := 0.0 # m from the shoulder a hand can hold something (see _hands())
var _pivot: Node3D # what carries the camera (the camera shake's pivot, else the camera)
var _pivot_rest := Vector3.ZERO
var _ladder_blend := 0.0 # 0 = upright under the camera, 1 = on the ladder with the ship (see _on_ladder())
var _held_blend := 0.0 # 0 = upright under the camera, 1 = turned with what holds us (see _held())
var _held_frame := Transform3D() # the last hold_frame, kept while easing back upright
var _ladder: Node3D # the ladder we are on, or last were while easing off it
var _ladder_lean := Basis() # the body's turn and lean on it, in its space (so it moves with the ship)
var _ladder_offset := Vector3.ZERO # ...and its root from where we are, in its space
var _carried: Node3D # the item in our hands, its grips per hand (left, right) and its size
var _grips: Array[Node3D] = [null, null]
var _carried_box := AABB() # in the item's own space
var _carry_close := 0.0 # how closed the hands are round it now
var _carry_hang := 0.0 # how far it has been taken onto the hand (see _carry())
var _steady := 0.0 # how still the shoulders are being held now (eased in and out)
var _tinted: Array[StandardMaterial3D] = [] # the seen copy's materials, tinted by depth (see _depth_tint())
var _albedo: Array[Color] = [] # ...and their own colours
var _tint := Color.WHITE
var _hand_bones := [-1, -1] # left, right
var _hand_was := [INF, INF] # how far each hand was above the water last frame
var _hand_falling := [false, false] # ...and whether it was coming down
var _hand_rest := [0.0, 0.0] # s until each can splash again
var _hand_fx: Array[GPUParticles3D] = []
var _lying := 0.0 # 0 = upright, 1 = lying along the view, swimming under the water (see _swim_tilt())
# Lying along the view, the camera sits at a Marker3D named SwimAnchor anywhere under the model
# (eg. a child of Body/Model in player.tscn) instead of at the eyes: placed on the standing body
# relative to its head, it goes where the head goes in any clip. Without one, the eyes stay at the
# camera.
var _anchor_in_head := Vector3.INF # the SwimAnchor, in the head bone's space (INF: none)

## Rigs the body for `p` (the Player: its Head turns it, its Camera3D is the eyes).
func setup(p) -> void:
	player = p
	_model = model
	_skel = _model.find_children('*', 'Skeleton3D', true, false)[0]
	_head_bone = _skel.find_bone(HEAD_BONES[0])
	var eye_point := _rest_eyes()
	_eye_in_head = (_skel.global_transform * _skel.get_bone_global_rest(_head_bone)).affine_inverse() * eye_point
	var anchor := _model.find_child('SwimAnchor', true, false) as Node3D
	if anchor:
		_anchor_in_head = (_skel.global_transform * _skel.get_bone_global_rest(_head_bone)).affine_inverse() * anchor.global_position
	# scaled so its eyes stand where the camera does above the feet
	var camera: Camera3D = player.camera
	var eye_height: float = camera.global_position.y - player.global_position.y
	var model_eyes := (_model.global_transform.affine_inverse() * eye_point).y # unscaled, whatever the scene's preview
	_model.scale = Vector3.ONE * (eye_height / maxf(model_eyes, 0.1))
	_split_head()
	_anim = AnimationPlayer.new()
	_anim.name = &'AnimationPlayer'
	_model.add_child(_anim)
	_anim.root_node = _anim.get_path_to(_model)
	_anim.add_animation_library(&'', _library_for(_model.get_path_to(_skel)))
	_anim.playback_default_blend_time = blend_time
	_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_play(&'Idle')
	_rig = BodyRig.new()
	_rig.name = &'BodyRig'
	_skel.add_child(_rig) # runs after the clip has posed the skeleton
	_rig.fingers_l = _held_fingers(&'Driving', '_l')
	_rig.fingers_r = _held_fingers(&'Driving', '_r')
	_hand_bones = [_skel.find_bone('hand_l'), _skel.find_bone('hand_r')]
	_find_pivot.call_deferred() # after CameraShake has slipped its pivot in (deferred from its _ready)

func _find_pivot() -> void:
	var cam_parent: Node3D = player.camera.get_parent()
	_pivot = cam_parent if cam_parent.name == &'ShakePivot' else player.camera
	_pivot_rest = _pivot.position

## How far down the thighs, from the hips toward the knees, a grip round the body takes hold.
const HOLD_DOWN_THIGHS := 0.25
## Where a grip round the body takes hold (world): just below the waist, between the tops of the
## thighs, as the clip has them now.
func hold_position() -> Vector3:
	var hips := Vector3.ZERO
	var knees := Vector3.ZERO
	for side in ['_l', '_r']:
		hips += _skel.get_bone_global_pose(_skel.find_bone('thigh' + side)).origin * 0.5
		knees += _skel.get_bone_global_pose(_skel.find_bone('calf' + side)).origin * 0.5
	return _skel.global_transform * hips.lerp(knees, HOLD_DOWN_THIGHS)

## The finger bones' turns (bone -> local rotation) halfway through `clip`: a clip whose hands hold
## something, to close the hands with when they grip.
func _held_fingers(clip: StringName, side: String) -> Dictionary:
	var out := {}
	var a := _anim.get_animation(clip)
	if a == null:
		return out
	for t in a.get_track_count():
		if a.track_get_type(t) != Animation.TYPE_ROTATION_3D:
			continue
		var bone := String(a.track_get_path(t).get_concatenated_subnames())
		if not bone.ends_with(side):
			continue
		for finger in ['index', 'middle', 'ring', 'pinky', 'thumb']:
			if bone.begins_with(finger):
				var b := _skel.find_bone(bone)
				if b >= 0:
					out[b] = a.rotation_track_interpolate(t, a.length * 0.5)
	return out

## Where its eyes are at rest, in world space: the middle of the eye mesh, or a guess off the head.
func _rest_eyes() -> Vector3:
	for m: MeshInstance3D in _model.find_children('*', 'MeshInstance3D', true, false):
		if m.name.to_lower().begins_with('eyes'):
			return (m.global_transform * m.get_aabb()).get_center()
	var head := _skel.global_transform * _skel.get_bone_global_rest(_head_bone)
	return head.origin + _model.global_basis * Vector3(0.0, 0.08, 0.1) # the model's own up and front

## The clips of every file in ANIMATIONS_DIR, with their tracks pointed at this model's skeleton
## (same rig, same bone names).
func _library_for(skel_path: NodePath) -> AnimationLibrary:
	var files: Array[String] = []
	for f in ResourceLoader.list_directory(ANIMATIONS_DIR): # sees imported files in exports too
		if f != BASE_ANIMATIONS and f.get_extension().to_lower() in ['glb', 'gltf']:
			files.append(f)
	files.sort()
	files.push_front(BASE_ANIMATIONS)
	var lib := AnimationLibrary.new()
	for f in files:
		var scene := load(ANIMATIONS_DIR + f) as PackedScene
		if scene == null:
			push_warning('PlayerBody: %s is not an imported scene.' % f)
			continue
		var src := scene.instantiate()
		var players := src.find_children('*', 'AnimationPlayer', true, false)
		if players.is_empty():
			push_warning('PlayerBody: %s has no animations.' % f)
		for player_src: AnimationPlayer in players:
			for clip in player_src.get_animation_list():
				var a := player_src.get_animation(clip).duplicate() as Animation
				for t in a.get_track_count():
					var path := a.track_get_path(t)
					if path.get_subname_count() > 0: # a bone: Skeleton3D:bone
						a.track_set_path(t, NodePath(str(skel_path) + ':' + path.get_concatenated_subnames()))
				_fill_rest(a, skel_path)
				if lib.has_animation(clip):
					lib.remove_animation(clip)
				lib.add_animation(clip, a)
		src.free()
	return lib

## Every bone `a` doesn't move gets a track holding it at rest. A bone a clip has no track for is
## left where the clip before it put it (Blender's exporter drops the channels that never change):
## the climb clips had none for the upper back, collarbones and neck, so on the ladder they kept
## the walk's or the swim's, and the hands landed somewhere else every time we got on.
func _fill_rest(a: Animation, skel_path: NodePath) -> void:
	var have := {}
	for t in a.get_track_count():
		have[[a.track_get_type(t), String(a.track_get_path(t).get_concatenated_subnames())]] = true
	for b in _skel.get_bone_count():
		var bone := _skel.get_bone_name(b)
		var path := NodePath(str(skel_path) + ':' + bone)
		var rest := _skel.get_bone_rest(b)
		if not have.has([Animation.TYPE_ROTATION_3D, bone]):
			var t := a.add_track(Animation.TYPE_ROTATION_3D)
			a.track_set_path(t, path)
			a.rotation_track_insert_key(t, 0.0, rest.basis.get_rotation_quaternion())
		if not have.has([Animation.TYPE_POSITION_3D, bone]):
			var t := a.add_track(Animation.TYPE_POSITION_3D)
			a.track_set_path(t, path)
			a.position_track_insert_key(t, 0.0, rest.origin)

## The copy you see loses its head (and eyes, brows, hair); the full one only casts the shadow.
func _split_head() -> void:
	var cut := {}
	for name in HEAD_BONES:
		var b := _skel.find_bone(name)
		if b >= 0:
			_mark(b, cut)
	for m: MeshInstance3D in _model.find_children('*', 'MeshInstance3D', true, false):
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		if not _is_head_mesh(m):
			var seen := m.duplicate() as MeshInstance3D
			seen.name = StringName(m.name + '_Seen')
			seen.mesh = _without(m, cut)
			seen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			for k in seen.mesh.get_surface_count(): # its own materials, to tint by depth
				var mat := seen.get_active_material(k) as StandardMaterial3D
				if mat:
					mat = mat.duplicate() as StandardMaterial3D
					seen.set_surface_override_material(k, mat)
					_tinted.append(mat)
					_albedo.append(mat.albedo_color)
			m.get_parent().add_child(seen)
			seen.skeleton = seen.get_path_to(_skel)

func _mark(bone: int, cut: Dictionary) -> void:
	cut[bone] = true
	for c in _skel.get_bone_children(bone):
		_mark(c, cut)

## Eyes, brows, hair: nothing but head.
static func _is_head_mesh(m: MeshInstance3D) -> bool:
	var n := String(m.name).to_lower()
	return n.begins_with('eye') or n.contains('brow') or n.contains('hair')

## `m`'s mesh with every triangle that moves mostly with the cut bones taken out.
func _without(m: MeshInstance3D, cut: Dictionary) -> ArrayMesh:
	var skin := m.skin
	var src := m.mesh
	var out := ArrayMesh.new()
	for s in src.get_surface_count():
		var arrays := src.surface_get_arrays(s)
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var per := bones.size() / maxi(verts.size(), 1) # 4 or 8 influences
		var on_head := PackedByteArray()
		on_head.resize(verts.size())
		for v in verts.size():
			var w := 0.0
			for k in per:
				var bi := bones[v * per + k]
				var bone := bi
				if skin:
					bone = skin.get_bind_bone(bi)
					if bone < 0:
						bone = _skel.find_bone(skin.get_bind_name(bi))
				if cut.has(bone):
					w += weights[v * per + k]
			on_head[v] = 1 if w > 0.4 else 0
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var kept := PackedInt32Array()
		for t in range(0, idx.size(), 3):
			if on_head[idx[t]] or on_head[idx[t + 1]] or on_head[idx[t + 2]]:
				continue
			kept.append_array([idx[t], idx[t + 1], idx[t + 2]])
		arrays[Mesh.ARRAY_INDEX] = kept
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(out.get_surface_count() - 1, src.surface_get_material(s))
	return out

func _process(delta: float) -> void:
	if player == null:
		return
	_animate(delta)
	_depth_tint(delta)
	_rig.carrying = false # until _carry() finds something in our hands
	_rig.carried_item = null
	_rig.thumb_grip = -1.0
	# the shoulders held still while we carry (see carry_steady), eased in and out
	var carrying: bool = player.carry_controller.is_carrying()
	_steady = move_toward(_steady, carry_steady if carrying else 0.0, delta * 3.0)
	_rig.steady_shoulders = _steady
	# its own facing (never pitched); the model faces +Z, the view -Z
	var yaw: float = (player.head as Node3D).global_rotation.y
	var p = player
	if p.state == p.State.PILOT and _wheel_for(p.piloted_ship):
		_rig.twist = _square_shoulders()
		_helm(yaw, delta)
		return
	_leave_helm()
	_face(yaw, delta)
	var tilt := _swim_tilt(delta)
	_model.global_basis = (tilt * Basis(Vector3.UP, _yaw + PI)).scaled(_model.scale)
	_rig.twist = clampf(angle_difference(_yaw, yaw), -deg_to_rad(max_twist), deg_to_rad(max_twist))
	# and moved so its eyes are at the camera, a touch behind it
	var camera: Camera3D = player.camera
	var eyes := _skel.global_transform * _skel.get_bone_global_pose(_head_bone) * _eye_in_head
	var back := tilt * Basis(Vector3.UP, yaw) * Vector3(0.0, 0.0, eye_back)
	if _anchor_in_head != Vector3.INF and _lying > 0.0: # lying, the anchor is what sits at the camera
		var anchor := _skel.global_transform * _skel.get_bone_global_pose(_head_bone) * _anchor_in_head
		eyes = eyes.lerp(anchor, smoothstep(0.0, 1.0, _lying))
	_model.global_position += camera.global_position + back - eyes
	_on_ladder(yaw, delta)
	_held(yaw, delta)
	_carry(delta)
	_hand_splashes(delta)

## On a ladder the body is the ship's, not the camera's: leaning along the climb and riding every
## roll and pitch of her, so the hands and feet stay on the rails; the camera goes where its eyes
## are (only there: where we look, and the level horizon, stay ours). It hangs by its eyes as it
## does upright -- as high above the climb as the camera is above the feet, only along the ladder
## -- so wherever a clip carries the body about its root, the view stays put. Eased in over
## ladder_blend_time as we grab it, and out as we step off, from the upright body hung from the
## camera, so the view never jumps.
func _on_ladder(view_yaw: float, delta: float) -> void:
	var p = player
	var climbing: bool = p.state == p.State.CLIMB and is_instance_valid(p.ladder)
	_ladder_blend = move_toward(_ladder_blend, 1.0 if climbing else 0.0, delta / maxf(ladder_blend_time, 0.01))
	var upright := _model.global_transform # hung from the camera (see _process())
	# where we are on it, from where the ship is now (the player's own position is a physics step
	# behind her, see Player.ladder_position())
	var stand: Vector3 = p.ladder_position() if climbing else p.global_position
	if climbing:
		var l = p.ladder
		var up: Vector3 = (l.point(1.0) - l.point(0.0)).normalized() # along the climb, with her
		var f: Vector3 = l.top_exit.global_position - l.top.global_position # over the top: toward the ladder
		var fwd := (f - up * f.dot(up)).normalized()
		if fwd.length_squared() < 0.5:
			fwd = (-l.global_basis.z - up * (-l.global_basis.z).dot(up)).normalized()
		var turn := Basis(up, deg_to_rad(ladder_turn)) # the fitting sliders (see ladder_shift_side)
		fwd = turn * fwd
		var right := fwd.cross(up).normalized()
		var lean := Basis(-right, up, fwd).scaled(_model.scale)
		_model.global_transform = Transform3D(lean, stand)
		var eyes := _skel.global_transform * _skel.get_bone_global_pose(_head_bone) * _eye_in_head
		# the camera's height above the feet (the pivot is at rest here), without the nudge that
		# keeps the eyes out of the waterline: the waves washing round the ladder's foot pushed the
		# body up and down the rails with it
		var eye_height: float = player.camera.global_position.y - p.global_position.y - p._eye_offset
		# eye_back measured along where the body faces, not the view: by the view, the whole body
		# swung round the camera as we looked about, taking the hands off the rails
		var offset: Vector3 = up * eye_height - fwd * eye_back - (eyes - stand)
		offset += right * ladder_shift_side + up * ladder_shift_up + fwd * ladder_shift_in
		_ladder = l
		var inv: Basis = l.global_basis.inverse()
		_ladder_lean = inv * lean # in the ladder's space, so it moves with her
		_ladder_offset = inv * offset # from where we are to the body's root
	if _ladder_blend <= 0.0 or not is_instance_valid(_ladder):
		_ladder = null
		_model.global_transform = upright
		_rig.nudge = {}
		_rig.fingers_open = 0.0
		return
	# stepped off, the lean eases out, but the body comes along with us from where we are
	var b: Basis = _ladder.global_basis
	var on_it := Transform3D(b * _ladder_lean, stand + b * _ladder_offset)
	var k := smoothstep(0.0, 1.0, _ladder_blend)
	_model.global_transform = upright.interpolate_with(on_it, k)
	_rig.twist *= 1.0 - k # the back stays square to the ladder as we look round: it turned the shoulders, and the hands with them, off the rails
	# the hands and feet fitted to the rails and rungs (the sliders, m, into the skeleton's space:
	# it faces +Z, its left is +X, and it is scaled with the model)
	var to_sk := k / maxf(_skel.global_basis.get_scale().x, 0.001)
	var hands := Vector3(ladder_hands_wider, ladder_hands_up, ladder_hands_in) * to_sk
	var feet := Vector3(ladder_feet_wider, ladder_feet_up, ladder_feet_in) * to_sk
	_rig.nudge = {&'hand_l': hands, &'hand_r': hands * Vector3(-1, 1, 1),
			&'foot_l': feet, &'foot_r': feet * Vector3(-1, 1, 1)}
	_rig.fingers_open = ladder_fingers_open * k
	var eyes := _skel.global_transform * _skel.get_bone_global_pose(_head_bone) * _eye_in_head
	# looking round, the head leans out to that side, so what's behind us is seen past the
	# shoulder rather than from inside the neck
	var body := on_it.basis.orthonormalized() # faces +Z, its left is +X
	var off := angle_difference(atan2(-body.z.x, -body.z.z), view_yaw) # > 0: turned to the left
	var lean_k := smoothstep(deg_to_rad(ladder_lean_from), deg_to_rad(player.ladder_look_limit), absf(off))
	var lean_out := body.x * signf(off) * ladder_lean_out * lean_k * k
	_pivot.global_position = eyes + Basis(Vector3.UP, view_yaw) * Vector3(0.0, 0.0, -eye_back) + lean_out

## Held by something that turns with us (Player.hold_frame: a coiling arm), the body is its, not
## the camera's: the hips where it holds them, turned as it turns, so the arm goes round with the
## body instead of through it. The camera goes where the eyes are (only there: where we look, and
## the level horizon, stay ours). Eased in over held_blend_time from the upright body hung from the
## camera, and back out when let go.
func _held(view_yaw: float, delta: float) -> void:
	var p = player
	var on: bool = p.captured and p.hold_frame != Transform3D()
	if on:
		_held_frame = p.hold_frame
	_held_blend = move_toward(_held_blend, 1.0 if on else 0.0, delta / maxf(held_blend_time, 0.01))
	if _held_blend <= 0.0:
		return
	var upright := _model.global_transform
	var hips := upright.affine_inverse() * hold_position() # in the model's own space: the clip's pose
	var b := _held_frame.basis.orthonormalized().scaled(_model.scale)
	var k := smoothstep(0.0, 1.0, _held_blend)
	_model.global_transform = upright.interpolate_with(Transform3D(b, _held_frame.origin - b * hips), k)
	var eyes := _skel.global_transform * _skel.get_bone_global_pose(_head_bone) * _eye_in_head
	var at := eyes + Basis(Vector3.UP, view_yaw) * Vector3(0.0, 0.0, -eye_back)
	_pivot.global_position = _pivot.global_position.lerp(at, k)

## Swimming under the water (the eyes under, not afloat), the body lies along the view like a diver,
## head first, its strokes out in front of the eyes. The swim clip already lies flat, head forward,
## so it is only pitched with the view: not at all looking level, head down looking straight down.
## Not stroking, or with the head out of the water, it levels out again as the clip goes back to the
## upright swim idle. Eased both ways (swim_lean_time).
func _swim_tilt(delta: float) -> Basis:
	var p = player
	var water = p.water
	var under := false
	if p.state == p.State.SWIM and p._float_rest == Vector2.INF and water:
		var eyes: Vector3 = p.camera.global_position
		under = eyes.y < water.get_wave_height(eyes) and not (water.has_method(&'is_water_hole') and water.is_water_hole(eyes))
	var lie: bool = under and p.swim_stroke.length() > 0.3
	_lying = move_toward(_lying, 1.0 if lie else 0.0, delta / maxf(swim_lean_time, 0.01))
	if _lying <= 0.0:
		return Basis.IDENTITY
	var facing := Basis(Vector3.UP, _yaw + PI) * Vector3.BACK # the model faces +Z
	var axis := Vector3.UP.cross(facing).normalized() # turns its up toward where it faces
	var pitch: float = p.camera.rotation.x # < 0 looking down
	return Basis(axis, smoothstep(0.0, 1.0, _lying) * -pitch)

## The sunlight reaching the body has come down through the water over it, losing its red first and
## then the rest (the water's underwater_absorption, depth_dimming of it), so deep down it is a dark
## shape. The underwater screen effect only takes away what is lost between the body and the eyes,
## a few centimeters, so without this it stayed lit like on the surface (the sun dims a little with
## depth too, see the Water's depth_darkening; this is on top of that). Measured at the chest.
func _depth_tint(delta: float) -> void:
	var water = player.water
	if _tinted.is_empty() or water == null or not water.has_method(&'get_wave_height'):
		return
	var chest: Vector3 = player.global_position + Vector3.UP * 1.0
	var depth := maxf(water.get_wave_height(chest) - chest.y, 0.0) * depth_dimming
	if depth > 0.0 and water.has_method(&'is_water_hole') and water.is_water_hole(chest):
		depth = 0.0 # in a dry hull or shaft
	var target := Color.WHITE
	if depth > 0.0:
		var a = WATER_MAT.get_shader_parameter(&'underwater_absorption')
		if a == null:
			a = RenderingServer.shader_get_parameter_default(WATER_MAT.shader.get_rid(), &'underwater_absorption')
		if a is Vector3:
			target = Color(exp(-a.x * depth), exp(-a.y * depth), exp(-a.z * depth))
	# eased, so going under or surfacing doesn't snap it (and the waves washing over the chest don't flicker it)
	var k := 1.0 - exp(-delta * 6.0)
	_tint = Color(lerpf(_tint.r, target.r, k), lerpf(_tint.g, target.g, k), lerpf(_tint.b, target.b, k))
	for i in _tinted.size():
		var c := _albedo[i]
		_tinted[i].albedo_color = Color(c.r * _tint.r, c.g * _tint.g, c.b * _tint.b, c.a)

## Swimming at the surface (the head above it): a small splash where a hand comes down onto the
## waves, at the bottom of its stroke (within hand_splash_reach of them) or going through. Copies of the Player's HeadSplash, one per hand, so tuning that tunes these.
func _hand_splashes(delta: float) -> void:
	var p = player
	var water = p.water
	var template: GPUParticles3D = p.head_splash
	if template == null or water == null or _hand_bones[0] < 0 or _hand_bones[1] < 0:
		return
	if _hand_fx.is_empty():
		for k in 2:
			var fx := template.duplicate() as GPUParticles3D
			fx.name = &'HandSplashL' if k == 0 else &'HandSplashR'
			fx.amount = maxi(int(template.amount * hand_splash_amount), 1)
			fx.emitting = false
			p.add_child(fx)
			_hand_fx.append(fx)
	var stroking: bool = p.state == p.State.SWIM and p.swim_stroke.length() > 0.3 			and p.camera.global_position.y > water.get_wave_height(p.camera.global_position)
	for k in 2:
		_hand_rest[k] = maxf(_hand_rest[k] - delta, 0.0)
		var hand := _skel.global_transform * _skel.get_bone_global_pose(_hand_bones[k]).origin
		var surface_y: float = water.get_wave_height(hand)
		var above := hand.y - surface_y
		var was: float = _hand_was[k]
		var through: bool = was > 0.0 and above <= 0.0
		var bottomed: bool = _hand_falling[k] and above > was and was < hand_splash_reach
		if stroking and (through or bottomed) and _hand_rest[k] <= 0.0:
			_hand_fx[k].global_position = Vector3(hand.x, surface_y, hand.z)
			_hand_fx[k].restart()
			_hand_rest[k] = hand_splash_rest
		_hand_falling[k] = stroking and above < was
		_hand_was[k] = above if stroking else INF

## Carrying: each hand holds the item at its own grip, the item's Grip_L / Grip_R marker (at any
## depth, so empties from Blender work too); a hand the item has no grip for is left to its clip. An
## item with neither marker is held by its sides, with both hands.
func _carry(delta: float) -> void:
	var item: Node3D = player.carry_controller.carried
	if item == null or not is_instance_valid(item):
		_carried = null
		_carry_close = 0.0
		return
	if item != _carried:
		_carried = item
		_carry_hang = 0.0
		_grips = [item.find_child('Grip_L', true, false) as Node3D, item.find_child('Grip_R', true, false) as Node3D]
		_carried_box = AABB()
		for m: MeshInstance3D in item.find_children('*', 'MeshInstance3D', true, false): # not its label
			var box := item.global_transform.affine_inverse() * m.global_transform * m.get_aabb()
			_carried_box = box if _carried_box.size == Vector3.ZERO else _carried_box.merge(box)
	var right := -_model.global_basis.x.normalized() # the model faces +Z, so its +X is the body's left
	var targets := [Vector3.INF, Vector3.INF]
	if _grips[0] or _grips[1]:
		for k in 2:
			if _grips[k]:
				targets[k] = _grips[k].global_position
	else:
		# its half width across the body: the box's reach along our right, in the item's own space
		var r := item.global_basis.inverse() * right
		var half := _carried_box.size * 0.5
		var reach := absf(r.x) * half.x + absf(r.y) * half.y + absf(r.z) * half.z
		var mid := item.global_transform * _carried_box.get_center()
		var gap := right * (reach + carry_side_gap)
		targets = [mid - gap, mid + gap]
	var to_sk := _skel.global_transform.affine_inverse()
	# each hand turned on the item by its grip marker (see body_rig.gd's `carrying`)
	_rig.carrying = true
	_rig.settling = player.carry_controller.is_settling()
	# open, reaching to take it while it comes up into the hands; closing round it once it is there
	var close_to := carry_reach_open if _rig.settling else carry_grip
	_carry_close = move_toward(_carry_close, close_to, carry_close_speed * delta)
	_rig.item_frame_l = to_sk.basis * (_grips[0] if _grips[0] else item).global_basis
	_rig.item_frame_r = to_sk.basis * (_grips[1] if _grips[1] else item).global_basis
	# it hangs from a hand (the right, if it has a grip for it): the socket is only where that hand
	# reaches for, and the item goes wherever the hand got to. Eased onto the hand as it comes up
	# into it: switched over once it had arrived, an item held beyond the arm's reach jumped back
	# into the hand, and the other hand jumped with it.
	if _grips[0] or _grips[1]:
		_carry_hang = move_toward(_carry_hang, 1.0, delta / maxf(carry_take_time, 0.01))
		_rig.carried_item = item
		_rig.anchor = '_r' if _grips[1] else '_l'
		_rig.hang = smoothstep(0.0, 1.0, _carry_hang)
	var down := Vector3.DOWN * 0.6
	if targets[0] != Vector3.INF:
		_rig.hand_l = to_sk * targets[0]
		_rig.pole_l = to_sk * (targets[0] + down - right * 0.5)
		_rig.grip_l = _carry_close
	if targets[1] != Vector3.INF:
		_rig.hand_r = to_sk * targets[1]
		_rig.pole_r = to_sk * (targets[1] + down + right * 0.5)
		_rig.grip_r = _carry_close
	_rig.grip_depth = player.grip_depth
	_rig.wrist = Vector3.ZERO # the helm's wrist and thumb tuning is for its spokes
	_rig.thumb = Vector2.ZERO
	_rig.thumb_grip = _carry_close / maxf(carry_grip, 0.01) * carry_thumb

## Where the body faces: the wheel at the helm; the ladder on a ladder, whatever the view (the back
## and neck still turn toward it, max_twist); with the view while walking or swimming (quickly);
## standing, it lets the view swing free_look either way before the feet shuffle round after it.
func _face(view_yaw: float, delta: float) -> void:
	if is_nan(_yaw):
		_yaw = view_yaw
	var p = player
	var moving := Vector2(p.velocity.x, p.velocity.z).length() > 0.3
	if p.state == p.State.CLIMB and is_instance_valid(p.ladder):
		var f: Vector3 = p.ladder.facing()
		_yaw = lerp_angle(_yaw, atan2(-f.x, -f.z), 1.0 - exp(-10.0 * delta)) # turned onto it as we grab it
	elif p.state == p.State.SWIM or moving:
		_yaw = lerp_angle(_yaw, view_yaw, 1.0 - exp(-10.0 * delta))
	else:
		var off := angle_difference(_yaw, view_yaw)
		var limit := deg_to_rad(free_look)
		if absf(off) > limit:
			_yaw = wrapf(_yaw + off - signf(off) * limit, -PI, PI)

## The ship's wheel (the node the helm turns: her `steering_hinge`), found once per ship: its axle
## and the handles on it to hold.
func _wheel_for(ship: Node) -> bool:
	if ship == null:
		return false
	if ship != _helm_ship:
		_helm_ship = ship
		_wheel = ship.find_child('steering_hinge', true, false) as Node3D
		if _wheel == null:
			return false
		for n in ship.find_children('*', '', true, false):
			if n.get(&'wheel') == _wheel and n.get(&'wheel_axis') is Vector3:
				_wheel_axle = (n.get(&'wheel_axis') as Vector3).normalized()
			# where hands can hold it: the markers on it named Steering_* (one per spoke handle)
		_handles.clear()
		for m: Node3D in _wheel.find_children('Steering_*', 'Marker3D', true, false):
			_handles.append(m)
		_hold = [-1, -1]
		_regrip = [-1.0, -1.0]
	return _wheel != null and _handles.size() >= 2

## At the helm. The feet stand helm_step_back behind the helm's marker, square to the wheel, on her
## deck as it tilts; the upper body rides her lurches and rolls on a soft spring (leaning back into
## a sudden stop, keeping itself fairly upright as she rolls), and the eyes, the camera, go with it.
## The hands hold the wheel's handles hand over hand (see _hands()).
func _helm(view_yaw: float, delta: float) -> void:
	var p = player
	var ship: Node3D = p.piloted_ship
	var marker: Node3D = p.helm_marker
	var wheel_at := _wheel.global_position
	var deck_up: Vector3 = ship.global_basis.y.normalized()
	# square to the wheel's face: on its axle, on the marker's side, at the marker's distance (a
	# marker a little off to one side of the axle would have us see the wheel at a slant, the far
	# side's handles out of reach)
	var to_marker := marker.global_position - wheel_at
	var flat_to_marker := to_marker - deck_up * to_marker.dot(deck_up)
	var away := _wheel.global_basis * _wheel_axle
	away = away - deck_up * away.dot(deck_up)
	away = away.normalized() if away.length() > 0.001 else flat_to_marker.normalized()
	if away.dot(flat_to_marker) < 0.0:
		away = -away
	var stand: Vector3 = wheel_at + deck_up * to_marker.dot(deck_up) + away * (flat_to_marker.length() + helm_step_back)
	# square to the wheel, standing on her deck
	var fwd := -away
	_yaw = atan2(-fwd.x, -fwd.z)
	var right := fwd.cross(deck_up).normalized()
	_model.global_transform = Transform3D(Basis(-right, deck_up, fwd).scaled(_model.scale), stand)
	# the upper body on its spring: pushed by how her deck lurches under the feet, and straightening
	# up against her tilt
	if _stand_was != Vector3.INF and delta > 0.0:
		# the deck's speed and lurch, smoothed: she moves in physics steps that don't line up with
		# drawn frames, so taken raw, frame to frame, they are mostly that stepping, and the body
		# shook with it
		var v := (stand - _stand_was) / delta
		var was_v := _stand_v
		_stand_v = _stand_v.lerp(v, 1.0 - exp(-delta / SWAY_SMOOTH))
		_lurch = _lurch.lerp((_stand_v - was_v) / delta, 1.0 - exp(-delta / SWAY_SMOOTH))
		var lurch := _lurch
		var tilt_fwd := asin(clampf(Vector3.UP.dot(fwd), -1.0, 1.0)) # world up leans this way off her deck
		var tilt_right := asin(clampf(Vector3.UP.dot(right), -1.0, 1.0))
		var target := Vector2(-lurch.dot(fwd) * sway_push + tilt_fwd * sway_upright,
				-lurch.dot(right) * sway_push + tilt_right * sway_upright)
		var limit := deg_to_rad(sway_max)
		target = Vector2(clampf(target.x, -limit, limit), clampf(target.y, -limit, limit))
		var w := TAU * sway_hz
		_lean_v += (w * w * (target - _lean) - 2.0 * sway_damping * w * _lean_v) * delta
		_lean += _lean_v * delta
	_stand_was = stand
	_rig.lean = _lean
	_hands(right, delta)
	# the eyes carry the camera now (it turns as the player looks; the body stays square)
	var eyes := _skel.global_transform * _skel.get_bone_global_pose(_head_bone) * _eye_in_head
	_pivot.global_position = eyes + Basis(Vector3.UP, view_yaw) * Vector3(0.0, 0.0, -eye_back)

## The turn that squares the shoulders to the way the body faces: the standing clip carries its
## torso a little turned (the right shoulder back), which at the wheel leaves one hand short.
func _square_shoulders() -> float:
	var l := _skel.get_bone_global_pose(_skel.find_bone('upperarm_l')).origin
	var r := _skel.get_bone_global_pose(_skel.find_bone('upperarm_r')).origin
	var across := l - r # the body's left, in the skeleton's space (it faces +Z)
	# the spine below the shoulders takes only part of the twist (the neck the rest; see body_rig.gd)
	return atan2(across.z, across.x) / BodyRig.SHOULDER_SHARE

## Off the helm: the camera goes back where the Head carries it, the hands let go, the back unbends.
func _leave_helm() -> void:
	if _pivot and _pivot.position != _pivot_rest:
		_pivot.position = _pivot_rest
	_rig.hand_l = Vector3.INF
	_rig.hand_r = Vector3.INF
	_rig.wheel_center = Vector3.INF
	_rig.grip_l = 0.0
	_rig.grip_r = 0.0
	_rig.lean = Vector2.ZERO
	_lean = Vector2.ZERO
	_lean_v = Vector2.ZERO
	_stand_was = Vector3.INF
	_stand_v = Vector3.ZERO
	_lurch = Vector3.ZERO
	_hold = [-1, -1]
	_regrip = [-1.0, -1.0]

## Each hand holds a handle near its home (hand_home either side of the top), and is carried round
## with it as the wheel turns. Carried hand_reach past home, it lets go and takes the free handle
## nearest home again, in a short lifted reach (one hand at a time: the other keeps the wheel), the
## way a helmsman goes hand over hand on a big turn.
func _hands(right: Vector3, delta: float) -> void:
	var axle := (_wheel.global_basis * _wheel_axle).normalized()
	var top := Vector3.UP - axle * Vector3.UP.dot(axle)
	top = top.normalized()
	var side := (right - axle * right.dot(axle)).normalized() # the helmsman's right, on the wheel
	var clock := func(h: Node3D) -> float: # degrees round from the top, clockwise as he sees it
		var d := h.global_position - _wheel.global_position
		return rad_to_deg(atan2(d.dot(side), d.dot(top)))
	var home := [-hand_home, hand_home]
	# how far each hand can reach from its shoulder (an arm and a palm, a little short of straight)
	var shoulders: Array[Vector3] = []
	for k in 2:
		var b := _skel.find_bone('upperarm_l' if k == 0 else 'upperarm_r')
		shoulders.append(_skel.global_transform * _skel.get_bone_global_pose(b).origin)
	if _arm_reach <= 0.0:
		var sc := _skel.global_transform.basis.get_scale().x
		var r := func(a: String, b: String) -> float:
			return _skel.get_bone_global_rest(_skel.find_bone(a)).origin.distance_to(_skel.get_bone_global_rest(_skel.find_bone(b)).origin)
		_arm_reach = (r.call('upperarm_l', 'lowerarm_l') + r.call('lowerarm_l', 'hand_l') + r.call('hand_l', 'middle_01_l') * 0.6) * sc * 0.97
	var reachable := func(i: int, k: int) -> bool:
		return shoulders[k].distance_to(_handles[i].global_position) < _arm_reach
	for k in 2:
		if _hold[k] < 0: # just took the helm: the handle nearest home
			_hold[k] = _nearest(clock, home[k], _hold[1 - k], reachable.bind(k))
	for k in 2:
		var other := 1 - k
		if _regrip[k] < 0.0 and _regrip[other] < 0.0:
			var off := angle_difference(deg_to_rad(home[k]), deg_to_rad(clock.call(_handles[_hold[k]])))
			# carried too far round, or out of the arm's reach: let go and take a better handle
			if absf(off) > deg_to_rad(hand_reach) or not reachable.call(_hold[k], k):
				var next := _nearest(clock, home[k], _hold[other], reachable.bind(k))
				if next != _hold[k]:
					_regrip_from[k] = _handles[_hold[k]].global_position
					_hold[k] = next
					_regrip[k] = 0.0
	var to_sk := _skel.global_transform.affine_inverse()
	var toward_me: Vector3 = -_model.global_basis.z.normalized() # the body faces the wheel along +Z
	var targets: Array[Vector3] = []
	var grips: Array[float] = []
	for k in 2:
		var at: Vector3 = _handles[_hold[k]].global_position
		var grip := 1.0
		if _regrip[k] >= 0.0:
			_regrip[k] += delta
			var t := clampf(_regrip[k] / maxf(regrip_time, 0.01), 0.0, 1.0)
			var arc := sin(t * PI)
			# let go, lift off toward the chest a little, and take the new handle
			at = (_regrip_from[k] as Vector3).lerp(at, smoothstep(0.0, 1.0, t)) + toward_me * arc * 0.12 + Vector3.UP * arc * 0.06
			grip = maxf(1.0 - arc, 0.2) # opens to let go and take the next handle
			if t >= 1.0:
				_regrip[k] = -1.0
		targets.append(at)
		grips.append(grip)
	var down := Vector3.DOWN * 0.6
	_rig.hand_l = to_sk * targets[0]
	_rig.hand_r = to_sk * targets[1]
	_rig.pole_l = to_sk * (targets[0] + down - right * 0.5)
	_rig.pole_r = to_sk * (targets[1] + down + right * 0.5)
	# how the hands hold: the sliders on the Player (its 'Body at the Helm' group), read live
	var p = player
	_rig.grip_l = grips[0] * p.grip_closure
	_rig.grip_r = grips[1] * p.grip_closure
	_rig.grip_depth = p.grip_depth
	_rig.wrist = Vector3(deg_to_rad(p.wrist_bend), deg_to_rad(p.wrist_twist), deg_to_rad(p.wrist_tilt))
	_rig.thumb = Vector2(deg_to_rad(p.thumb_pitch), deg_to_rad(p.thumb_turn))
	_rig.lock_wrist = Vector3(deg_to_rad(p.lock_wrist_bend), deg_to_rad(p.lock_wrist_twist), deg_to_rad(p.lock_wrist_tilt))
	# the wheel, for the hands to stay locked to their spokes as it turns
	_rig.wheel_center = to_sk * _wheel.global_position
	_rig.wheel_axle = to_sk.basis * axle
	for k in 2:
		var c := deg_to_rad(home[k]) # home[k] degrees round from the top, as clock() counts
		var home_dir := top * cos(c) + side * sin(c)
		if k == 0:
			_rig.home_l = to_sk.basis * home_dir
		else:
			_rig.home_r = to_sk.basis * home_dir

## The handle nearest `home` degrees round, other than `taken`; one in reach (`reachable`) if any is.
func _nearest(clock: Callable, home: float, taken: int, reachable: Callable) -> int:
	var best := -1
	var best_off := INF
	for i in _handles.size():
		if i == taken:
			continue
		var off := absf(angle_difference(deg_to_rad(home), deg_to_rad(clock.call(_handles[i]))))
		if not reachable.call(i):
			off += 1000.0 # only if nothing in reach
		if off < best_off:
			best_off = off
			best = i
	return best

## Picks the clip and moves it on (in steps, if anim_fps is set).
func _animate(delta: float) -> void:
	var pick := _pick(delta)
	if pick[0] != _current:
		_play(pick[0])
	_anim.speed_scale = pick[1]
	if anim_fps > 0.0:
		_step_left -= delta
		if _step_left <= 0.0:
			var step := 1.0 / anim_fps
			_anim.advance(step - _step_left)
			_step_left += step
	else:
		_anim.advance(delta)

func _play(clip: StringName) -> void:
	if _anim.has_animation(clip):
		_anim.play(clip)
		_current = clip

## [clip, speed] for what the player is doing now.
func _pick(delta: float) -> Array:
	var p = player
	var flat := Vector2(p.velocity.x, p.velocity.z)
	var facing := -(p.head as Node3D).global_basis.z
	var ahead := flat.dot(Vector2(facing.x, facing.z)) # forward speed, < 0 backing off
	var speed := flat.length()
	var dir := -1.0 if ahead < -0.1 else 1.0 # walk the clip backwards when backing up
	if p.state == p.State.PILOT:
		return [&'Idle', 1.0] # standing at the wheel; the hands and back are posed by the rig
	if p.state == p.State.SWIM:
		# by the stroke, not how we move: rising or diving under our own power is swimming, and
		# being rocked by the waves or sinking is not
		var stroke: float = p.swim_stroke.length()
		if stroke > 0.3:
			# backing off, the strokes run backwards (straight up or down they don't)
			var back := Vector2(p.swim_stroke.x, p.swim_stroke.z).dot(Vector2(facing.x, facing.z)) < -0.1
			return [&'Swim_Fwd', (-1.0 if back else 1.0) * clampf(stroke / swim_pace, 0.5, 2.0)]
		return [&'Swim_Idle', 1.0]
	if p.state == p.State.CLIMB and _anim.has_animation(&'Climb'):
		var rate: float = p.climb_rate
		if absf(rate) > 0.05:
			# as many cycles a second as it takes to keep up with the climb; backwards going down
			return [&'Climb', rate / maxf(climb_cycle, 0.01) * _anim.get_animation(&'Climb').length]
		if _anim.has_animation(&'Climb_Idle'):
			return [&'Climb_Idle', 1.0] # hanging on
		return [&'Climb', 0.0] # held where it stopped
	if p.state != p.State.WALK:
		return [&'Idle', 1.0] # at a station
	if p.is_on_floor():
		if _airborne > 0.35:
			_landing = 0.35 # came down from a real fall or jump
		_airborne = 0.0
	else:
		_airborne += delta
	if _airborne > 0.15:
		return [&'Jump', 1.0]
	if _landing > 0.0:
		_landing -= delta
		return [&'Jump_Land', 1.0]
	if speed < 0.3:
		if p.carry_controller.is_carrying() and _anim.has_animation(&'Hold_Idle'):
			return [&'Hold_Idle', 1.0] # how the body stands holding something (the hands still go to it)
		return [&'Idle', 1.0]
	if speed > p.walk_speed + 0.5:
		return [&'Sprint', dir * clampf(speed / sprint_pace, 0.6, 2.0)]
	if p.carry_controller.is_carrying() and _anim.has_animation(&'Hold_Walk'):
		return [&'Hold_Walk', dir * clampf(speed / walk_pace, 0.5, 2.0)] # a calmer walk, holding something
	if speed > walk_pace * 1.6:
		return [&'Jog_Fwd', dir * clampf(speed / jog_pace, 0.6, 2.0)]
	return [&'Walk', dir * clampf(speed / walk_pace, 0.5, 2.0)]
