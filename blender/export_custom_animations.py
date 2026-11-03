"""Exports the custom player clips from animations_custom.blend to the game.

Run it headless, so the file you work in is never changed (it is not saved either way):
  blender -b blender/animations_custom.blend --python blender/export_custom_animations.py
Inside Blender (Scripting tab > Open > this file > Run Script) it works too, but it takes the other
clips off the armature of the open file: File > Revert after, and don't save.

Writes assets/models/player/animations/Custom.glb with only the clips named in CLIPS, on the deform
bones only, with the IK controls baked in. The game loads it after the standard library, so a clip
here with the same name as a standard one replaces it.
"""
import os
import bpy

## The clips that go to the game. Name a looping clip ..._Loop: Godot plays it looped and drops the
## suffix (Climb_Loop plays as Climb).
CLIPS = ['Climb_Loop', 'Climb_Idle']
ARMATURE = 'Armature'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'models', 'player', 'animations', 'Custom.glb')


def main():
	arm = bpy.data.objects[ARMATURE]
	missing = [c for c in CLIPS if c not in bpy.data.actions]
	if missing:
		raise RuntimeError('No action called %s in this file.' % ', '.join(missing))
	ad = arm.animation_data
	for t in list(ad.nla_tracks): # stashed clips would export too
		ad.nla_tracks.remove(t)
	for a in list(bpy.data.actions):
		if a.name not in CLIPS:
			bpy.data.actions.remove(a)
	for name in CLIPS: # a track each, so every clip exports as its own animation
		a = bpy.data.actions[name]
		t = ad.nla_tracks.new()
		t.name = name
		t.strips.new(name, int(a.frame_range[0]), a)
	ad.action = None
	if bpy.context.object and bpy.context.object.mode != 'OBJECT':
		bpy.ops.object.mode_set(mode='OBJECT')
	for o in bpy.context.view_layer.objects:
		o.select_set(o == arm)
	bpy.context.view_layer.objects.active = arm
	bpy.ops.export_scene.gltf(
		filepath=os.path.normpath(OUT),
		use_selection=True,
		export_def_bones=True, # the IK controls stay behind; their motion is baked onto the real bones
		export_animations=True,
		export_animation_mode='NLA_TRACKS',
		export_force_sampling=True,
	)
	print('Exported %s to %s' % (', '.join(CLIPS), os.path.normpath(OUT)))


main()
