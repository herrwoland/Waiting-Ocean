"""Adds IK controls to the player's animation rig (Quaternius' universal humanoid).

Run it once in Blender with animations_custom.blend open: Scripting tab > Open > this file > Run
Script (the play button). Then save.

What it adds, all in the bone collection "IK Controls" (none of it deforms the mesh, so none of it
goes into the game, see the export note below):
  - IK_hand_l / IK_hand_r: grab and move a hand; it also turns the wrist.
  - IK_foot_l / IK_foot_r: grab and move a foot; it also turns the ankle.
  - Pole_arm_l / Pole_arm_r, Pole_knee_l / Pole_knee_r: which way the elbows and knees point.
The controls start where the hands and feet are in the pose on screen when you run it, so that pose
does not jump.

Switches: select the Armature object > Object properties (orange square) > Custom Properties:
"IK Arms" and "IK Legs", 1 = IK, 0 = the old FK keys. They can be keyed too. The standard clips were
keyed in FK, so turn IK off to look at them as they are.

Export: glTF 2.0, with Include > Data > "Deform Bones Only" ticked, and Animation > Sampling on
(the default). The IK result gets baked onto the real bones and the controls are left out.
"""
import bpy
from mathutils import Matrix, Vector

ARMATURE = 'Armature'
COLLECTION = 'IK Controls'
FRONT = Vector((0.0, -1.0, 0.0)) # the rig faces -Y
ELBOWS = Vector((0.0, 1.0, -1.0)).normalized() # behind and below: the elbows hang down, as climbing

# (side, upper, lower, end, control, pole, which way the pole sits if the limb is straight)
LIMBS = [
	('l', 'upperarm_l', 'lowerarm_l', 'hand_l', 'IK_hand_l', 'Pole_arm_l', ELBOWS, 'IK Arms'),
	('r', 'upperarm_r', 'lowerarm_r', 'hand_r', 'IK_hand_r', 'Pole_arm_r', ELBOWS, 'IK Arms'),
	('l', 'thigh_l', 'calf_l', 'foot_l', 'IK_foot_l', 'Pole_knee_l', FRONT, 'IK Legs'),
	('r', 'thigh_r', 'calf_r', 'foot_r', 'IK_foot_r', 'Pole_knee_r', FRONT, 'IK Legs'),
]
POLE_DISTANCE = 0.5 # m out from the elbow / knee
CONTROL_LENGTH = 0.12
POLE_LENGTH = 0.06


def main():
	arm = bpy.data.objects.get(ARMATURE)
	if arm is None or arm.type != 'ARMATURE':
		raise RuntimeError('No armature called %r in this file.' % ARMATURE)
	if 'IK_hand_l' in arm.data.bones:
		raise RuntimeError('The IK controls are already there; nothing done.')

	view_layer = bpy.context.view_layer
	if bpy.context.object and bpy.context.object.mode != 'OBJECT':
		bpy.ops.object.mode_set(mode='OBJECT')
	for o in view_layer.objects:
		o.select_set(False)
	view_layer.objects.active = arm
	arm.select_set(True)
	scene = bpy.context.scene
	scene.frame_set(scene.frame_current) # the pose of the frame on screen, evaluated

	# Where everything is in the pose on screen (armature space), before any of it changes.
	posed = {pb.name: pb.matrix.copy() for pb in arm.pose.bones}
	root_pose = arm.pose.bones['root'].matrix.copy()
	root_rest = arm.data.bones['root'].matrix_local.copy()
	to_rest = root_rest @ root_pose.inverted() # posed armature space -> where a child of root rests

	plan = []
	for side, upper, lower, end, control, pole, fallback, switch in LIMBS:
		shoulder = posed[upper].translation
		elbow = posed[lower].translation
		wrist = posed[end].translation
		mid = (shoulder + wrist) * 0.5
		out = elbow - mid
		out = out.normalized() if out.length > 0.01 else fallback.copy()
		plan.append(dict(upper=upper, lower=lower, end=end, control=control, pole=pole, switch=switch,
			control_m=to_rest @ posed[end], pole_at=to_rest @ (elbow + out * POLE_DISTANCE), elbow=elbow.copy()))

	bpy.ops.object.mode_set(mode='EDIT')
	eb = arm.data.edit_bones
	root = eb['root']
	for p in plan:
		c = eb.new(p['control'])
		m = p['control_m'].to_3x3().normalized() # lined up with the hand / foot: same axes and roll
		c.head = p['control_m'].translation
		c.tail = c.head + m.col[1] * CONTROL_LENGTH
		c.align_roll(m.col[2])
		c.parent = root
		c.use_deform = False
		k = eb.new(p['pole'])
		k.head = p['pole_at']
		k.tail = p['pole_at'] + Vector((0.0, 0.0, POLE_LENGTH))
		k.parent = root
		k.use_deform = False
	bpy.ops.object.mode_set(mode='POSE')

	coll = arm.data.collections.get(COLLECTION) or arm.data.collections.new(COLLECTION)
	for name in ('IK Arms', 'IK Legs'):
		arm[name] = 1.0
		arm.id_properties_ui(name).update(min=0.0, max=1.0, soft_min=0.0, soft_max=1.0,
			description='1 = this limb follows its IK control, 0 = its own FK keys')

	pbs = arm.pose.bones
	for p in plan:
		for name in (p['control'], p['pole']):
			coll.assign(arm.data.bones[name])
			pbs[name].custom_shape = None
		ik = pbs[p['lower']].constraints.new('IK')
		ik.name = 'IK'
		ik.target = arm
		ik.subtarget = p['control']
		ik.pole_target = arm
		ik.pole_subtarget = p['pole']
		ik.chain_count = 2
		ik.use_tail = True # lowerarm/calf + upperarm/thigh; their tail is the wrist / ankle, where the control is
		rot = pbs[p['end']].constraints.new('COPY_ROTATION')
		rot.name = 'IK Rotation'
		rot.target = arm
		rot.subtarget = p['control']
		for con in (ik, rot):
			_drive(con, arm, p['switch'])
		p['ik'] = ik

	# The pole angle (it depends on the bones' rolls) that bends each elbow / knee straight at its
	# pole. Found with the limb bent (control pulled halfway to the shoulder / hip): in a straight
	# limb every angle looks the same.
	for p in plan:
		ctl = pbs[p['control']]
		ctl.matrix = Matrix.Translation((pbs[p['upper']].matrix.translation - ctl.matrix.translation) * 0.5) @ ctl.matrix
		scene.frame_set(scene.frame_current)
		pole_at = pbs[p['pole']].matrix.translation
		best, best_d = 0.0, -float('inf')
		for step in [s * 2.0 for s in range(-90, 91)] + [None]:
			if step is None: # then finer, round the best
				for fine in [best + s * 0.25 for s in range(-8, 9)]:
					p['ik'].pole_angle = fine * 3.14159265 / 180.0
					scene.frame_set(scene.frame_current)
					d = _toward(pbs, p, pole_at)
					if d > best_d:
						best, best_d = fine, d
				break
			p['ik'].pole_angle = step * 3.14159265 / 180.0
			scene.frame_set(scene.frame_current)
			d = _toward(pbs, p, pole_at)
			if d > best_d:
				best, best_d = step, d
		p['ik'].pole_angle = best * 3.14159265 / 180.0
		ctl.matrix_basis = Matrix.Identity(4) # back where the pose had it
		scene.frame_set(scene.frame_current)
		print('%s: pole angle %.2f deg, elbow/knee off by %.1f mm' % (p['lower'], best, (pbs[p['lower']].matrix.translation - p['elbow']).length * 1000.0))
	print('IK controls added. Bone collection: %r.' % COLLECTION)


def _toward(pbs, p, pole_at):
	"""How squarely the bent elbow / knee points at its pole (1 = straight at it)."""
	root = pbs[p['upper']].matrix.translation
	tip = pbs[p['control']].matrix.translation
	axis = (tip - root).normalized()
	def off(x):
		v = x - root
		return (v - axis * v.dot(axis)).normalized()
	return off(pbs[p['lower']].matrix.translation).dot(off(pole_at))


def _drive(con, arm, prop):
	fc = con.driver_add('influence')
	d = fc.driver
	d.type = 'AVERAGE'
	v = d.variables.new()
	v.name = 'ik'
	v.type = 'SINGLE_PROP'
	v.targets[0].id = arm
	v.targets[0].data_path = '["%s"]' % prop


main()
