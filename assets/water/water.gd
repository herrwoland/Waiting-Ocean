# Adapted from https://github.com/Lucactus22/GodotOceanWaves_bouyancy/tree/main
@tool
extends MeshInstance3D
## Handles updating the displacement/normal maps for the water material as well as
## managing wave generation pipelines.

const WATER_MAT := preload('res://assets/water/mat_water.tres')
const SPRAY_MAT := preload('res://assets/water/mat_spray.tres')
const WATER_MESH_HIGH8K := preload('res://assets/water/clipmap_high_8k.obj')
const WATER_MESH_HIGH := preload('res://assets/water/clipmap_high.obj')
const WATER_MESH_LOW := preload('res://assets/water/clipmap_low.obj')

enum MeshQuality { LOW, HIGH, HIGH8K }

# ----- Config Variables ----- #
@export_group('Wave Parameters')
@export_color_no_alpha var water_color : Color = Color(0.1, 0.15, 0.18) :
	set(value): water_color = value; RenderingServer.global_shader_parameter_set(&'water_color', water_color)

@export_color_no_alpha var foam_color : Color = Color(0.73, 0.67, 0.62) :
	set(value): foam_color = value; RenderingServer.global_shader_parameter_set(&'foam_color', foam_color)

## The parameters for wave cascades. Each parameter set represents one cascade.
## Recreates all compute piplines whenever a cascade is added or removed!
@export var parameters : Array[WaveCascadeParameters] :
	set(value):
		var new_size := len(value)
		# All below logic is basically just required for using in the editor!
		for i in range(new_size):
			# Ensure all values in the array have an associated cascade
			if not value[i]: value[i] = WaveCascadeParameters.new()
			if not value[i].is_connected(&'scale_changed', _update_scales_uniform):
				value[i].scale_changed.connect(_update_scales_uniform)
			value[i].spectrum_seed = Vector2i(rng.randi_range(-10000, 10000), rng.randi_range(-10000, 10000))
			value[i].time = 120.0 + PI*i # We make sure to choose a time offset such that cascades don't interfere!
		parameters = value
		_setup_wave_generator()
		_update_scales_uniform()

## The thin top of a tall wave: looking towards the sun, its colour turns paler and greener (the
## sun comes through it and loses its red on the way), and what lies behind it shows through a
## little. Nothing glows: it is lit like the rest of the sea. Heights are the waves' own, measured
## against the waves actually running, so it works the same in a calm and in a storm.
@export_group('Translucency')
## The colour a thin crest turns. Paler and greener than the sea itself.
@export_color_no_alpha var translucency_color := Color(0.16, 0.55, 0.46) :
	set(value): translucency_color = value; WATER_MAT.set_shader_parameter(&'sss_color', value)
## How far the colour shifts, and how much the sun lights a crest from behind (0 = off).
@export_range(0.0, 4.0, 0.01) var translucency_strength := 2.0 :
	set(value): translucency_strength = value; WATER_MAT.set_shader_parameter(&'sss_strength', value)
## How much the tops of the waves let through what lies behind them (the sky, a hull), as if
## they were only a metre of water thick. 0 = as opaque as the rest of the sea.
@export_range(0.0, 1.0, 0.01) var translucency_see_through := 0.5 :
	set(value): translucency_see_through = value; WATER_MAT.set_shader_parameter(&'sss_see_through', value)
## How tightly it gathers round looking straight into the light. Higher = only when facing the
## sun; lower = it shows from further round to the side.
@export_range(0.5, 16.0, 0.1) var translucency_sharpness := 4.0 :
	set(value): translucency_sharpness = value; WATER_MAT.set_shader_parameter(&'sss_power', value)
## How much the wave's own slope bends the light through it. Higher lights the thin edge of
## a crest more than the face turned to you.
@export_range(0.0, 1.0, 0.01) var translucency_distortion := 0.3 :
	set(value): translucency_distortion = value; WATER_MAT.set_shader_parameter(&'sss_distortion', value)
## Where on the wave the glow starts, as a share of a typical crest's height: 0 = from sea level
## up, 0.5 = only the top half, negative = into the troughs.
@export_range(-1.0, 0.9, 0.01) var translucency_height_bias := 0.0 :
	set(value): translucency_height_bias = value; WATER_MAT.set_shader_parameter(&'sss_height_bias', value)
## A little of the colour in high crests from any side, not only looking into the sun.
@export_range(0.0, 2.0, 0.01) var translucency_crest_glow := 0.3 :
	set(value): translucency_crest_glow = value; WATER_MAT.set_shader_parameter(&'sss_crest_glow', value)

@export_group('Performance Parameters')
@export_enum('256x256:256', '512x512:512', '1024x1024:1024') var map_size := 1024 : # 128 breaks the ocean.
	set(value):
		map_size = value
		_setup_wave_generator()

@export var mesh_quality := MeshQuality.HIGH8K :
	set(value):
		mesh_quality = value
		if mesh_quality == MeshQuality.LOW:
			mesh = WATER_MESH_LOW
		if mesh_quality == MeshQuality.HIGH:
			mesh = WATER_MESH_HIGH
		if mesh_quality == MeshQuality.HIGH8K:
			mesh = WATER_MESH_HIGH8K
		if is_node_ready(): _build_far_ring()

## How many times the wave simulation should update per second.
## Note: This doesn't reduce the frame stutter caused by FFT calculation, only
##       minimizes GPU time taken by it!
@export_range(0, 60) var updates_per_second := 50.0 :
	set(value):
		next_update_time = next_update_time - (1.0/(updates_per_second + 1e-10) - 1.0/(value + 1e-10))
		updates_per_second = value

@export var displacement_updates_per_second := 10
## How many wave cascades (largest first) are read back to the CPU for floating things, the
## player's eyes and the underwater effect. Each costs a readback. The rest only exist on the GPU,
## so things floating on the CPU heights miss them: 2 covers the swell and the chop on top of
## it in every preset (the third is flat in all of them).
@export_range(1, 4) var cpu_cascades := 2

## Full-screen underwater effect (see underwater_effect.gd). Fog colour and absorption are
## taken from the water material's "Underwater" uniforms so they match the surface.
@export_group('Underwater Effect')
@export var underwater_effect_enabled := true :
	set(value):
		underwater_effect_enabled = value
		if underwater_effect: underwater_effect.enabled = value
## How fast light fades per meter of depth. Higher = darker the deeper you sink.
@export_range(0.0, 0.5, 0.005) var depth_darkening := 0.04
## Screen wobble strength (UV units).
@export_range(0.0, 0.02, 0.0005) var underwater_distortion := 0.0025
## Blur radius in pixels.
@export_range(0.0, 6.0, 0.1) var underwater_blur := 1.5
## Width of the dark meniscus line where a wave crosses the lens, in pixels.
@export_range(0.0, 12.0, 0.1) var waterline_width := 2.5
## Froth and bubbles along that line. Widens into a churn of air as you go under.
@export_range(0.0, 2.0, 0.01) var waterline_foam := 0.8
## Foam thrown up each time the head breaks the surface, in or out. How long it lasts (s).
@export_range(0.0, 3.0, 0.05) var crossing_foam_time := 0.5
## How much of it there is (0 = none).
@export_range(0.0, 2.0, 0.05) var crossing_foam_strength := 1.0
## Shape of the fade. 1 fades evenly; higher drops away sooner, lower lingers before going.
@export_range(0.25, 6.0, 0.05) var crossing_foam_falloff := 2.0
## How long the churn of air takes to clear after the camera crosses the surface (s).
@export_range(0.1, 4.0, 0.05) var waterline_churn_time := 0.9
@export_subgroup('Going Under')
## The exposure drops this far the moment the camera goes under, then comes back (0 = off, 1 = black).
## Also hides any frame where the waves glitch as the camera crosses them.
@export_range(0.0, 1.0, 0.01) var submerge_exposure_dip := 0.97
## Seconds it stays that dark before it starts to come back.
@export_range(0.0, 2.0, 0.01) var submerge_exposure_hold := 0.1
## Seconds until the exposure is back to normal.
@export_range(0.05, 4.0, 0.05) var submerge_exposure_time := 0.5
## Just before going under, the dark water in front of the lens rises up the screen from the
## bottom: it starts when the lens is this far above the surface (m) and covers it at the surface.
## Keep it under the player's float_eye_height, or floating darkens the bottom of the view.
@export_range(0.0, 1.0, 0.01) var submerge_wipe_height := 0.18
## How much the top of that water swells up and down across the screen (fraction of its height).
@export_range(0.0, 0.3, 0.005) var submerge_wipe_wave := 0.07
## How soft (out of focus) its top is.
@export_range(0.0, 0.3, 0.005) var submerge_wipe_softness := 0.06
## Sky caught along its top, like the lit back of a swell.
@export_range(0.0, 1.5, 0.01) var submerge_wipe_sheen := 0.4
## Beads of air left on the lens for a moment each time the camera goes under (submerge_lens.gd).
@export var lens_beads_enabled := true
## Seconds until the last bead has slid off.
@export_range(0.1, 3.0, 0.05) var lens_bead_time := 0.6
@export_range(0, 12, 1) var lens_bead_count := 9
## Radius of a typical bead (fraction of screen height).
@export_range(0.001, 0.2, 0.001) var lens_bead_size := 0.009
## How much a bead shrinks the view behind it.
@export_range(0.0, 2.0, 0.05) var lens_bead_refraction := 0.6
## Brightness of their silver edges (light from the surface caught in them).
@export_range(0.0, 4.0, 0.05) var lens_bead_brightness := 0.9
@export var lens_bead_color := Color(0.75, 0.85, 0.9)
## Out-of-focus blur inside a bead.
@export_range(0.0, 5.0, 0.1) var lens_bead_blur := 2.0
## How fast they slide up off the lens.
@export_range(0.0, 1.0, 0.01) var lens_bead_rise := 0.25
## How much their outline trembles.
@export_range(0.0, 3.0, 0.05) var lens_bead_wobble := 1.0
## Seconds above water before going under again counts as a new dive (so bobbing doesn't).
@export_range(0.0, 2.0, 0.05) var lens_bead_min_air_time := 0.3
@export_subgroup('')
@export_range(0.0, 1.0, 0.01) var underwater_vignette := 0.35
## How far away big shapes can still be made out as dark silhouettes against the water (m).
## Detail and colour are lost much sooner (the material's underwater_absorption).
@export_range(5.0, 300.0, 1.0) var silhouette_range := 45.0
## Water brightness looking straight down vs straight up (light comes from above, so things
## below you are hidden in the dark and things above you are black shapes against the glow).
@export_range(0.0, 2.0, 0.01) var fog_brightness_down := 0.35
@export_range(0.0, 4.0, 0.01) var fog_brightness_up := 1.6
## Dim the sun and sky light as the camera goes deeper (same rate as depth_darkening), so
## everything around you is lit like it is that deep. Lamps and other local lights stay bright.
@export var dim_sunlight_underwater := true
## Brightness of UnderwaterGlow nodes with the camera under the water (0 = off). Seen from above
## the water it's the water material's glow_above_water instead.
@export_range(0.0, 8.0, 0.01) var underwater_glow_strength := 1.0
## Under the water, the blue all around you (the water material's underwater_color) is light
## that came down from above. With this on it dims with that light, so a dark preset (night) is
## dark under the water too, and dusk fades there with the sky. Measured as the brightest of
## the sun (weaker as it sinks to the horizon), the sky energy and the ambient energy.
@export var underwater_follows_light := true
## How bright the sun/sky/ambient must be for the underwater colour to show in full. 1 = the
## day presets (their sky and ambient energy are 1).
@export_range(0.05, 4.0, 0.01) var underwater_daylight := 1.0
## Brightness of the beams lamps throw through the water with the camera under it, like the
## sun's light shafts but from scene lights (0 = off). A lamp joins by being in the
## `underwater_beam` group (the searchlight adds itself): spot and omni lights, up to 8, the
## nearest ones count. They use the light's own colour, energy, range and cone.
@export_range(0.0, 8.0, 0.01) var light_beam_strength := 0.5
## How much a beam favours looking straight into the lamp. 0 = the beam glows the same from
## every side; towards 1 it is nearly invisible side-on and blinding head-on (the sun's shafts
## use 0.6). Lower reads better as a searchlight cutting through the dark.
@export_range(0.0, 0.95, 0.01) var light_beam_scattering := 0.25
## How much the waves break a lamp's beam into streaks, like the sun's light shafts: 0 is a
## smooth cone, 1 fully streaked. Only for lamps above the water (the light has to come through
## the waves). Uses the same wave focus as the sun's shafts (water material, Light Shafts).
@export_range(0.0, 1.0, 0.01) var light_beam_shafts := 0.7
## Samples per lamp along each view ray. Fewer is cheaper but grainier (streaks want more).
@export_range(4, 64, 1) var light_beam_quality := 24

## Shadows of things above the water (boats, creatures, cliffs) cut through the underwater light
## shafts and caustics. A small hidden camera renders the scene from the sun, depth only.
@export_group('Water Shadows')
@export var water_shadows_enabled := true :
	set(value):
		water_shadows_enabled = value
		if _shadow_viewport: _shadow_viewport.render_target_update_mode = \
				SubViewport.UPDATE_ALWAYS if value else SubViewport.UPDATE_DISABLED
## Shadow map resolution. Higher = sharper shadow edges, slightly slower.
@export_enum('256:256', '512:512', '1024:1024') var water_shadow_resolution := 512 :
	set(value):
		water_shadow_resolution = value
		if _shadow_viewport: _shadow_viewport.size = Vector2i(value, value)
## Width of the square around the camera that receives water shadows (m).
@export_range(16.0, 512.0, 1.0) var water_shadow_coverage := 128.0
## Blur of the shadow edges, in shadow map texels.
@export_range(0.0, 4.0, 0.05) var water_shadow_softness := 1.0
## Render layers that cast water shadows. The water itself lives on WATER_RENDER_LAYER and
## is never part of it.
@export_flags_3d_render var water_shadow_layers := 0x7FFFF :
	set(value):
		water_shadow_layers = value
		if _shadow_camera: _shadow_camera.cull_mask = value & ~WATER_LAYER_BIT

## Foam trails behind boats (see WakeEmitter). A world-space map around the camera.
@export_group('Wakes')
@export var wakes_enabled := true
## Seconds a wake takes to fade away completely.
@export_range(1.0, 120.0, 0.5) var wake_lifetime := 15.0
## How fast a wake widens as it ages (m/s). This is what opens it into a V behind the boat.
## Widening also thins the foam, so high values make a wake fade out sooner than its lifetime.
@export_range(0.0, 10.0, 0.05) var wake_spread := 0.5
## Width of the square around the camera that keeps wakes (m). Map resolution is fixed at 512.
@export_range(64.0, 1024.0, 1.0) var wake_coverage := 256.0 :
	set(value):
		wake_coverage = value
		if _wake_map: _wake_map.free_resources(); _wake_map = null

## Shore waves, in a ShoreZone (see shore_zone.gd and shore.gdshaderinc): the sea's own waves
## die down in the shallows and these roll in instead, steepen, break and run up the beach.
@export_group('Shore')
## The shore waves' height for the sea state: 1 = as tall as the open sea's typical crest.
@export_range(0.0, 3.0, 0.01) var shore_wave_height := 0.5
## They never fall below this, so even a still sea laps at the beach (m).
@export_range(0.0, 2.0, 0.01, 'suffix:m') var shore_wave_min_height := 0.15
## ...nor rise above this, however wild the open sea (m).
@export_range(0.1, 5.0, 0.01, 'suffix:m') var shore_wave_max_height := 1.0
## Crest to crest (m).
@export_range(4.0, 120.0, 0.5, 'suffix:m') var shore_wavelength := 26.0
## Seconds between crests reaching the beach.
@export_range(2.0, 30.0, 0.1, 'suffix:s') var shore_wave_period := 8.0
## Depth where they start to grow and steepen (m); they appear from three times as deep.
@export_range(0.5, 30.0, 0.1, 'suffix:m') var shore_shoal_depth := 5.0
## How high up the sand each wave's swash climbs, as a height above sea level for a share of
## the wave's height: it runs far up a gentle beach and only a little up a steep one.
@export_range(0.0, 6.0, 0.01) var shore_run_up := 2.5
## How much the waves differ in how far they run up (0 = all alike).
@export_range(0.0, 1.0, 0.01) var shore_run_up_variation := 0.35
## Thickness of the sheet of water the swash spreads on the sand (m).
@export_range(0.01, 0.5, 0.005, 'suffix:m') var shore_swash_film := 0.06
## How ragged the swash's front is along the beach: tongues and scallops running up further than
## the water beside them, a new pattern every wave (0 = an even line).
@export_range(0.0, 0.9, 0.01) var shore_swash_lobes := 0.35
## Width of the foam lace along the swash's leading edge (m); behind it the sheet is clear.
@export_range(0.1, 6.0, 0.05, 'suffix:m') var shore_swash_foam_width := 1.5
## How much the clear sheet of swash shows on the sand (0 = only its foam).
@export_range(0.0, 1.0, 0.01) var shore_swash_sheen := 0.3
## Furthest inland the run-up may reach (m); hollows beyond it stay dry.
@export_range(1.0, 100.0, 0.5, 'suffix:m') var shore_run_up_reach := 25.0
## How much the crests are staggered along the coast, in waves (0 = all in step).
@export_range(0.0, 2.0, 0.01) var shore_stagger := 0.6
## Width of the foam band along the shoreline (m), drawn like contact foam (0 = off).
@export_range(0.0, 60.0, 0.5, 'suffix:m') var shore_foam_width := 20.0
## How far the shoreline foam band bends in and out with the swash's tongues (m), in the same
## pattern, a new one every wave.
@export_range(0.0, 10.0, 0.05, 'suffix:m') var shore_foam_wobble := 1.5
## How solid the shoreline foam is: 1 = like contact foam, higher fills in its lace.
@export_range(0.5, 4.0, 0.05) var shore_foam_opacity := 1.6
## Depth where the longest waves (the largest cascade) are no longer calmed by the floor (m).
## Shorter cascades keep going into shallower water, in proportion to their tile length.
@export_range(1.0, 300.0, 0.5, 'suffix:m') var shore_damping_depth := 40.0

## Marine snow: specks hanging in the water around the camera while it is underwater.
@export_group('Marine Snow')
@export var marine_snow_enabled := true
## Number of specks (spread over the box around the camera).
@export_range(0, 8000, 10) var marine_snow_amount := 3000 :
	set(value):
		marine_snow_amount = value
		if _marine_snow: _marine_snow.amount = maxi(value, 1)
## Size of the box of specks around the camera (m).
@export var marine_snow_box := Vector3(24, 16, 24)
## Speck size (m).
@export_range(0.005, 0.3, 0.001) var marine_snow_size := 0.07
@export_range(0.0, 2.0, 0.01) var marine_snow_drift := 0.12
@export_range(0.0, 1.0, 0.005) var marine_snow_sink := 0.04
@export var marine_snow_color := Color(0.75, 0.82, 0.78)
## Square specks (PS1 look) instead of round ones.
@export var marine_snow_square := true
## Specks further than this fade out (m).
@export_range(1.0, 50.0, 0.5) var marine_snow_fade_distance := 12.0

# ----- Bookkeeping Variables ----- #
var wave_generator : WaveGenerator :
	set(value):
		if wave_generator: wave_generator.queue_free()
		wave_generator = value
		add_child(wave_generator)
var rng = RandomNumberGenerator.new()
var time := 0.0
var next_update_time := 0.0

var underwater_effect : UnderwaterEffect
var caustics_effect : CausticsEffect
var _sun : DirectionalLight3D
var _shadow_viewport : SubViewport
var _shadow_camera : Camera3D
var _waterline_churn := 0.0
var _crossing_foam := 0.0
var _last_cam_submersion := INF
var _submerge_lens : SubmergeLens
var _shadow_capture : WaterShadowCapture
var _wake_map : WakeMap
var _marine_snow : GPUParticles3D
# Sunlight dimming underwater: the sun's and environment's own values, restored at the surface.
var _sun_energy_base := -1.0
var _env : Environment
var _env_ambient_base := -1.0
var _env_sky_energy_base := -1.0
const WAKE_MAP_RESOLUTION := 512

var displacement_maps := Texture2DArrayRD.new()
var normal_maps := Texture2DArrayRD.new()

var _accumulator = 0.0;
var _displacement_update_rate: float;
## Per cascade: the latest readback, the one before it, and the water `time` each was asked
## for. Heights are carried forward from the two to now (see _sample_displacement), so they
## neither step 10 times a second nor trail the waves being drawn.
var _imgs: Array[Image] = []
var _imgs_prev: Array[Image] = []
var _img_times := PackedFloat64Array()
var _img_prev_times := PackedFloat64Array()
var _requested_times := PackedFloat64Array()
var map_scales : PackedVector4Array;

const MAX_WAVE_BLOCKERS := 8
const WATER_RENDER_LAYER := 20 # Render layer of the water surface/spray (skipped by the sun shadow camera).
const WATER_LAYER_BIT := 1 << (WATER_RENDER_LAYER - 1)
const MAX_WATER_SHAPES := 16 # Matches the water shader and effect arrays.
const MAX_GLOWS := 16 # UnderwaterGlow nodes; matches the water shader and effect arrays.
const MAX_BEAMS := 8 # Lamps in the underwater_beam group; matches the underwater effect.
const MAX_DRY_VOLUMES := 4 # DryVolume nodes; matches the water shader arrays.
const MAX_CONTACT_BODIES := 16 # Things touching the water that get contact foam; matches the water shader.
const CONTACT_RANGE := 500.0 # (m) around the camera. Further out the foam band is a pixel or two.
const CONTACT_BAND := 15.0 # (m) above/below the rest surface a mesh must reach to count as touching it.
const CONTACT_LAND_SIZE := 80.0 # (m) radius. Anything bigger is land, which the shader finds on its own.
const CONTACT_REFRESH := 0.25 # (s) between looking for new things; the ones found move every frame.
var _dry_volumes : Array = []
var _dry_signature := []
var _dry_maps := Texture2DArray.new()
var _glow_count := 0
var _glow_a := PackedVector4Array()
var _glow_b := PackedVector4Array()
var _beam_count := 0
var _beam_a := PackedVector4Array()
var _beam_b := PackedVector4Array()
var _beam_c := PackedVector4Array()
var _water_shapes_a := PackedVector4Array()
var _water_shapes_b := PackedVector4Array()
var _water_shape_count := 0
var _wave_blockers: Array[Node] = []
var _blocker_a := PackedVector4Array()
var _blocker_b := PackedVector4Array()
var _blocker_c := PackedVector4Array()
var _contact_nodes := [] # See _contact_body.
var _contact_bodies := PackedVector4Array()
var _contact_refresh := 0.0
var _shore: Node # The ShoreZone in use (the first one found), see _update_shore.
var _shore_img: Image
var _shore_rect := Vector4.ZERO # As the shader's shore_rect.
var _shore_a := Vector4.ZERO
var _shore_b := Vector4.ZERO
var _shore_c := Vector4.ZERO
var _shore_clock := 0.0 # Waves so far (wrapped at 256): shore_c.x, the phase is its fraction.
var _shore_frame := -1
var _cascade_height_var := PackedFloat32Array() # See _measure_wave_amplitude.
var _wave_amplitude := -1.0

# ------ Public Interface ----- #
## `masked = false` ignores wave blockers (eg. buoyancy keeps rocking the ship
## even when a calm zone flattens the water visually around it).
## Height of the water surface above/below `global_position` (the cascades read back to the
## CPU, see cpu_cascades).
## The waves move the water sideways as well as up and down, so the water that ends up above a
## point started somewhere beside it. Reading the height at the point itself gives the height of
## a neighbouring piece of wave -- a metre or two off in a storm, which floating things feel as
## being lifted at the wrong moment. So find where that water came from first: a few steps of
## "step back by the sideways shift found there". Mirrors wave_height() in underwater_post.glsl.
func get_wave_height(global_position: Vector3, masked: bool = true) -> float:
	var xz := Vector2(global_position.x, global_position.z)

	# Domes/swells from WaterDeformer nodes lift the surface and calm the waves riding on it.
	var shape := water_shapes_eval(xz)
	var calm := blocker_calm(global_position) if masked else Vector2(1.0, 0.0)
	var wave_scale := (1.0 - shape.y) * calm.x

	var rest := xz
	var displacement := Vector3.ZERO
	for i in 3:
		displacement = _cpu_displacement(rest) * wave_scale
		rest = xz - Vector2(displacement.x, displacement.z)
	return displacement.y + shape.x + calm.y * (1.0 - calm.x) + shore_wave(shore_sample(rest), rest) * calm.x

## Where a piece of the water surface is right now, given where it sits at rest (x, z with no
## waves): the waves carry it round in a small loop as well as up and down. Following one piece
## over time is floating exactly on the waves, sideways sway included. Same cascade, calm zones
## and water shapes as get_wave_height().
func surface_point(rest: Vector2, masked: bool = true) -> Vector3:
	var shape := water_shapes_eval(rest)
	var calm := blocker_calm(Vector3(rest.x, 0.0, rest.y)) if masked else Vector2(1.0, 0.0)
	var wave_scale := (1.0 - shape.y) * calm.x
	var d := _cpu_displacement(rest) * wave_scale
	var y := d.y + shape.x + calm.y * (1.0 - calm.x) + shore_wave(shore_sample(rest), rest) * calm.x
	return Vector3(rest.x + d.x, y, rest.y + d.z) # same height convention as get_wave_height()

## The rest position (see surface_point) of the water that is over `global_position` right now.
func surface_rest(global_position: Vector3, masked: bool = true) -> Vector2:
	var xz := Vector2(global_position.x, global_position.z)
	var rest := xz
	for i in 3:
		var p := surface_point(rest, masked)
		rest -= Vector2(p.x, p.z) - xz
	return rest

## Water shapes (from WaterDeformer nodes) at a world XZ position: (height offset, calm).
## Must mirror water_shapes_eval() in the water shader.
func water_shapes_eval(p: Vector2) -> Vector2:
	var result := Vector2.ZERO
	for i in _water_shape_count:
		var a := _water_shapes_a[i]
		var b := _water_shapes_b[i]
		var rel := p - Vector2(a.x, a.y)
		if b.z < 0.5: # Dome
			var q := rel.length_squared() / (a.z * a.z)
			if q > 16.0: continue
			var e := exp(-q)
			result.x += a.w * e * (1.0 - b.x * q)
			result.y = maxf(result.y, b.y * e)
		elif b.z < 1.5: # Ring swell (boil patches, b.z = 2, are foam only)
			var u := (rel.length() - a.z) / b.x
			if absf(u) > 4.0: continue
			result.x += a.w * exp(-u * u)
	return result

## Combined wave-blocker attenuation at a position (0 = fully calmed, 1 = untouched).
func blocker_mask(global_position: Vector3) -> float:
	return blocker_calm(global_position).x

## (attenuation, height of the calmed water) at a position: the strongest blocker there decides
## both. The surface is the waves * attenuation + that height * (1 - attenuation).
## Must mirror wave_blocker_eval() in water.gdshader and underwater_post.glsl.
func blocker_calm(global_position: Vector3) -> Vector2:
	var mask := 1.0
	var height := 0.0
	for i in mini(_wave_blockers.size(), MAX_WAVE_BLOCKERS):
		var blocker = _wave_blockers[i]
		if not is_instance_valid(blocker):
			continue
		var m: float = blocker.attenuation(global_position)
		if m < mask:
			mask = m
			height = blocker.calm_height(global_position)
	return Vector2(mask, height)

## True inside a HOLE blocker or a DryVolume (eg. the inside of a hull): there is no water here.
func is_water_hole(global_position: Vector3) -> bool:
	for blocker in _wave_blockers:
		if is_instance_valid(blocker) and blocker.mode == 1 and blocker.contains(global_position):
			return true
	for volume in _dry_volumes:
		if is_instance_valid(volume) and volume.contains(global_position):
			return true
	return false

# ------ Private Methods ----- #
func _init() -> void:
	rng.set_seed(1234) # This seed gives big waves!

func _enter_tree() -> void:
	# Lets floating things find the ocean without a hand-wired NodePath (see boat.gd).
	add_to_group(&'water')

func _ready() -> void:
	map_scales.resize(len(parameters))

	RenderingServer.global_shader_parameter_set(&'water_color', water_color)
	RenderingServer.global_shader_parameter_set(&'foam_color', foam_color)
	for p in [&'translucency_color', &'translucency_strength', &'translucency_see_through', &'translucency_sharpness',
			&'translucency_distortion', &'translucency_height_bias', &'translucency_crest_glow']:
		set(p, get(p)) # Push the dials to the material.

	var n := _cpu_cascade_count()
	_imgs.resize(n)
	_imgs_prev.resize(n)
	_img_times.resize(n)
	_img_prev_times.resize(n)
	_requested_times.resize(n)
	_imgs[0] = wave_generator.retrieve_displacement_map(0) # the rest arrive with the first readback
	# Float division: 1 / 10 in integers is 0, which read the whole map back every frame.
	_displacement_update_rate = 1.0 / maxf(float(displacement_updates_per_second), 1.0)
	_setup_underwater_effect()
	_build_far_ring()

func _process(delta : float) -> void:
	_update_wave_blockers()
	_update_shore()
	_update_water_shapes(delta)
	_update_glows()
	_update_beams()
	_update_dry_volumes()
	_update_contact_bodies(delta)
	_update_underwater_effect()
	_update_translucency_sun()
	_update_see_through()
	_update_wakes(delta)
	_update_marine_snow()
	_update_submerge_lens(delta)
	_update_depth_lighting()
	# TODO: These should probably be the same update
	# Update waves once every 1.0/updates_per_second.
	if updates_per_second == 0 or time >= next_update_time:
		var target_update_delta := 1.0 / (updates_per_second + 1e-10)
		var update_delta := delta if updates_per_second == 0 else target_update_delta + (time - next_update_time)
		next_update_time = time + target_update_delta
		_update_water(update_delta)
	time += delta
	
	# Resample displacement (async: the data arrives a few frames later, which
	# buoyancy easily tolerates, and avoids a full GPU pipeline stall). The cascades take turns
	# through each interval rather than all going at once: each readback is a spike, and
	# stacking them in one frame makes a hitch.
	var n := _imgs.size()
	var before: float = _accumulator
	_accumulator += delta;
	for c in n:
		var slot := _displacement_update_rate * c / n
		if before < slot and _accumulator >= slot or (c == 0 and _accumulator >= _displacement_update_rate):
			_requested_times[c] = time
			wave_generator.retrieve_displacement_map_async(c, _on_displacement_map_data.bind(c))
	if _accumulator >= _displacement_update_rate:
		_accumulator -= _displacement_update_rate

func _on_displacement_map_data(data: PackedByteArray, cascade: int) -> void:
	var size: int = wave_generator.map_size if is_instance_valid(wave_generator) else 0
	if size == 0 or data.size() != size * size * 8 or cascade >= _imgs.size(): # stale readback (eg. resolution just changed)
		return
	# Kept as the half floats the GPU wrote: get_pixel() decodes them directly, and converting
	# 8 MB to full floats cost ~10 ms of CPU per readback. The last map stays as the previous one
	# to predict from; its Image is then reused for the next one.
	var latest := _imgs[cascade]
	var spare := _imgs_prev[cascade]
	_imgs_prev[cascade] = latest if latest != null and latest.get_width() == size else null
	if spare == null or spare.get_width() != size or spare.get_format() != Image.FORMAT_RGBAH:
		spare = Image.create_from_data(size, size, false, Image.FORMAT_RGBAH, data)
	else:
		spare.set_data(size, size, false, Image.FORMAT_RGBAH, data)
	_imgs[cascade] = spare
	_img_prev_times[cascade] = _img_times[cascade]
	_img_times[cascade] = _requested_times[cascade]
	_measure_wave_amplitude(cascade)

## Which way the sun is, for the translucency (light coming through a crest towards the eye).
## w fades it out as the sun sets, or with no sun at all.
func _update_translucency_sun() -> void:
	var sun := Vector4.ZERO
	if is_instance_valid(_sun) and _sun.visible:
		var to_sun := _sun.global_basis.z.normalized() # A DirectionalLight3D shines along -Z.
		sun = Vector4(to_sun.x, to_sun.y, to_sun.z, smoothstep(-0.02, 0.08, to_sun.y))
	WATER_MAT.set_shader_parameter(&'sss_sun', sun)

## How high a typical crest stands, for the translucency (the shader's sss_wave_amplitude):
## twice the spread of the heights, from a sparse grid over each CPU cascade's map. The small
## GPU-only cascades barely add height. Eased, so a weather change glides rather than jumps.
func _measure_wave_amplitude(cascade: int) -> void:
	var img := _imgs[cascade]
	if img == null or cascade >= map_scales.size(): return
	const GRID := 8
	var w := img.get_width()
	var sum_sq := 0.0
	for y in GRID:
		for x in GRID:
			var h := img.get_pixel((x * w) / GRID, (y * w) / GRID).g
			sum_sq += h * h
	_cascade_height_var.resize(_imgs.size())
	_cascade_height_var[cascade] = sum_sq / (GRID * GRID) * pow(map_scales[cascade].z, 2.0)
	var total := 0.0
	for v in _cascade_height_var: total += v
	var target := 2.0 * sqrt(total)
	_wave_amplitude = target if _wave_amplitude < 0.0 else lerpf(_wave_amplitude, target, 0.2)
	WATER_MAT.set_shader_parameter(&'sss_wave_amplitude', maxf(_wave_amplitude, 0.05))

func _cpu_cascade_count() -> int:
	return clampi(cpu_cascades, 1, maxi(map_scales.size(), 1))

## The displacement of the CPU cascades together at a rest position (see surface_point).
func _cpu_displacement(rest: Vector2) -> Vector3:
	var d := Vector3.ZERO
	var shore := shore_sample(rest)
	for c in mini(_imgs.size(), map_scales.size()):
		var scales: Vector4 = map_scales[c]
		d += _sample_displacement(c, rest * Vector2(scales.x, scales.y)) * scales.z * shore_damp(shore, 1.0 / scales.x)
	return d

## The shore map at a rest position: (floor depth, distance to the shoreline, zone weight,
## stagger), open sea outside a ShoreZone. Mirrors shore_sample() in shore.gdshaderinc, bilinear
## filtering included.
func shore_sample(rest: Vector2) -> Vector4:
	_shore_params_now()
	if _shore_img == null or _shore_rect.z <= 0.0:
		return Vector4(400.0, 2000.0, 0.0, 0.0)
	var uv := (rest - Vector2(_shore_rect.x, _shore_rect.y)) * Vector2(_shore_rect.z, _shore_rect.w)
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return Vector4(400.0, 2000.0, 0.0, 0.0)
	var w := _shore_img.get_width()
	var h := _shore_img.get_height()
	var x := uv.x * w - 0.5
	var y := uv.y * h - 0.5
	var x0 := floori(x)
	var y0 := floori(y)
	var fx := x - x0
	var fy := y - y0
	var xa := clampi(x0, 0, w - 1)
	var xb := clampi(x0 + 1, 0, w - 1)
	var ya := clampi(y0, 0, h - 1)
	var yb := clampi(y0 + 1, 0, h - 1)
	var top := _shore_img.get_pixel(xa, ya).lerp(_shore_img.get_pixel(xb, ya), fx)
	var bottom := _shore_img.get_pixel(xa, yb).lerp(_shore_img.get_pixel(xb, yb), fx)
	var c := top.lerp(bottom, fy)
	# Towards the map's border the floor fades to open sea (no seam), as in the shader.
	var edge := minf(minf(uv.x, 1.0 - uv.x) / _shore_rect.z, minf(uv.y, 1.0 - uv.y) / _shore_rect.w)
	return Vector4(lerpf(400.0, c.r, smoothstep(0.0, 30.0, edge)), c.g, c.b, c.a)

## Mirrors shore_damp() in shore.gdshaderinc: by depth wherever the map knows the floor.
func shore_damp(s: Vector4, wavelength: float) -> float:
	return smoothstep(0.0, _shore_b.w * wavelength, s.x)

## Height of the shore waves at a rest position. Mirrors shore_wave() in shore.gdshaderinc.
func shore_wave(s: Vector4, xz: Vector2) -> float:
	var depth := s.x
	var height := 0.0
	var stagger := s.w * _shore_a.w
	if s.z > 0.0:
		var shoal := maxf(_shore_b.x, 0.1)
		var p := fposmod(s.y / maxf(_shore_a.y, 1.0) + _shore_a.z + stagger, 1.0)
		var steep := clampf(1.0 - depth / shoal, 0.0, 1.0)
		var g := pow(p, 1.0 + 1.5 * steep)
		var c := pow(0.5 + 0.5 * cos(TAU * g), 1.0 + 2.0 * steep)
		var amp := _shore_a.x * pow(shoal / maxf(depth, 0.25 * shoal), 0.25) * (1.0 - smoothstep(shoal, 3.0 * shoal, depth))
		amp = minf(amp, 0.39 * maxf(depth, 0.0))
		height = amp * (2.0 * c - 1.0) * s.z
	var sand := -depth
	var front := shore_swash(s, xz)
	var q := fposmod(_shore_c.x + stagger, 1.0)
	var film := _shore_c.z * clampf((front - sand) / 0.1, 0.0, 1.0) * (1.0 - 0.6 * smoothstep(0.35, 1.0, q))
	return maxf(height, sand + film if sand < front else front)

## How high up the beach the swash has climbed (m above sea level). Mirrors shore_swash() in
## shore.gdshaderinc.
func shore_swash(s: Vector4, xz: Vector2) -> float:
	var clock := _shore_c.x + s.w * _shore_a.w
	var q := fposmod(clock, 1.0)
	var n := floorf(clock)
	var h := fposmod(n * 0.618034, 1.0)
	h = fposmod(h * h * 37.1 + h * 7.3, 1.0)
	var r := 1.0 - (1.0 - q / 0.35) * (1.0 - q / 0.35) if q < 0.35 else 1.0 - ((q - 0.35) / 0.65) * ((q - 0.35) / 0.65)
	var reach := maxf(_shore_b.z, 1.0)
	var a := TAU * h
	var lobes := sin(xz.dot(Vector2(0.61, 0.79)) * 0.55 + a * 3.0) * 0.6 \
			+ sin(xz.dot(Vector2(-0.83, 0.56)) * 1.3 + a * 5.0) * 0.4
	return _shore_b.y * (1.0 + _shore_c.y * (2.0 * h - 1.0)) * (1.0 + _shore_c.w * lobes) * r \
			* smoothstep(-reach, -0.7 * reach, s.y)

## The shore waves' parameters for this frame, worked out once per frame by whatever asks first
## (physics runs before _process), so every height read this frame and the frame drawn agree.
func _shore_params_now() -> void:
	var frame := Engine.get_process_frames()
	if frame == _shore_frame: return
	_shore_frame = frame
	if is_inside_tree() and can_process():
		_shore_clock = fposmod(_shore_clock + get_process_delta_time() / maxf(shore_wave_period, 0.1), 256.0)
	var height := clampf(shore_wave_height * maxf(_wave_amplitude, 0.0) * 0.5, shore_wave_min_height, maxf(shore_wave_max_height, shore_wave_min_height))
	_shore_a = Vector4(height, shore_wavelength, fposmod(_shore_clock, 1.0), shore_stagger)
	_shore_c = Vector4(_shore_clock, shore_run_up_variation, shore_swash_film, shore_swash_lobes)
	var longest := 0.0
	for sc in map_scales: longest = maxf(longest, 1.0 / maxf(sc.x, 1e-6))
	_shore_b = Vector4(shore_shoal_depth, shore_run_up * height, shore_run_up_reach,
			shore_damping_depth / maxf(longest, 1.0))

## Finds the ShoreZone and hands its map and this frame's parameters to everything that draws
## the waves (see shore.gdshaderinc).
func _update_shore() -> void:
	var zone := get_tree().get_first_node_in_group(&'shore_zone')
	if zone != _shore or (zone and zone.baked != _shore_img):
		_shore = zone
		_shore_img = zone.baked if zone else null
		var tex: Texture2D = zone.texture if zone else null
		RenderingServer.global_shader_parameter_set(&'shore_map', tex)
		var r: Rect2 = zone.map_rect() if zone else Rect2()
		_shore_rect = Vector4(r.position.x, r.position.y, 1.0 / r.size.x, 1.0 / r.size.y) if tex and r.size.x > 0.0 else Vector4.ZERO
		RenderingServer.global_shader_parameter_set(&'shore_rect', _shore_rect)
		if underwater_effect:
			underwater_effect.shore_texture = RenderingServer.texture_get_rd_texture(tex.get_rid()) if tex else RID()
	_shore_params_now()
	WATER_MAT.set_shader_parameter(&'shore_foam_width', shore_foam_width if _shore_rect.z > 0.0 else 0.0)
	WATER_MAT.set_shader_parameter(&'shore_foam_opacity', shore_foam_opacity)
	WATER_MAT.set_shader_parameter(&'shore_foam_wobble', shore_foam_wobble)
	WATER_MAT.set_shader_parameter(&'swash_foam_width', shore_swash_foam_width)
	WATER_MAT.set_shader_parameter(&'swash_sheen', shore_swash_sheen)
	RenderingServer.global_shader_parameter_set(&'shore_a', _shore_a)
	RenderingServer.global_shader_parameter_set(&'shore_b', _shore_b)
	RenderingServer.global_shader_parameter_set(&'shore_c', _shore_c)
	if underwater_effect:
		underwater_effect.shore_rect = _shore_rect
		underwater_effect.shore_a = _shore_a
		underwater_effect.shore_b = _shore_b
		underwater_effect.shore_c = _shore_c
func _setup_wave_generator() -> void:
	if parameters.size() <= 0: return
	for param in parameters:
		param.should_generate_spectrum = true

	wave_generator = WaveGenerator.new()
	wave_generator.map_size = map_size
	wave_generator.init_gpu(maxi(2, parameters.size())) # FIXME: This is needed because my RenderContext API sucks...

	displacement_maps.texture_rd_rid = RID()
	normal_maps.texture_rd_rid = RID()
	displacement_maps.texture_rd_rid = wave_generator.descriptors[&'displacement_map'].rid
	normal_maps.texture_rd_rid = wave_generator.descriptors[&'normal_map'].rid

	RenderingServer.global_shader_parameter_set(&'num_cascades', parameters.size())
	RenderingServer.global_shader_parameter_set(&'displacements', displacement_maps)
	RenderingServer.global_shader_parameter_set(&'normals', normal_maps)

## Adds the caustics and underwater effects to the scene's WorldEnvironment compositor
## (reusing ones that are already there, eg. saved into the scene by the editor).
func _setup_underwater_effect() -> void:
	var scene_root := owner if owner else get_parent()
	if not scene_root: return
	var envs := scene_root.find_children('*', 'WorldEnvironment', true, false)
	if envs.is_empty():
		push_warning('Water: no WorldEnvironment found, underwater effect disabled.')
		return
	var suns := scene_root.find_children('*', 'DirectionalLight3D', true, false)
	if not suns.is_empty(): _sun = suns[0]
	var env : WorldEnvironment = envs[0]
	if not env.compositor: env.compositor = Compositor.new()
	var effects := env.compositor.compositor_effects
	for effect in effects:
		if effect is UnderwaterEffect: underwater_effect = effect
		if effect is CausticsEffect: caustics_effect = effect
	if not caustics_effect:
		caustics_effect = CausticsEffect.new()
		effects.append(caustics_effect)
	if not underwater_effect:
		underwater_effect = UnderwaterEffect.new()
		effects.append(underwater_effect)
	env.compositor.compositor_effects = effects
	underwater_effect.enabled = underwater_effect_enabled
	_setup_water_shadows()

## Hidden orthographic camera looking down the sunbeams. Renders unshaded, without the scene's
## environment or effects, and hands its depth to the shafts/caustics via WaterShadowCapture.
func _setup_water_shadows() -> void:
	if _shadow_viewport: return
	_shadow_viewport = SubViewport.new()
	_shadow_viewport.name = 'WaterShadowViewport'
	_shadow_viewport.size = Vector2i(water_shadow_resolution, water_shadow_resolution)
	_shadow_viewport.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	_shadow_viewport.positional_shadow_atlas_size = 0
	_shadow_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_shadow_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if water_shadows_enabled else SubViewport.UPDATE_DISABLED
	_shadow_camera = Camera3D.new()
	_shadow_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_shadow_camera.near = 0.5
	_shadow_camera.far = 800.0
	_shadow_camera.cull_mask = water_shadow_layers & ~WATER_LAYER_BIT
	# The water surface and spray are transparent (they'd never cast a shadow) but expensive,
	# so they go on their own layer that the sun camera skips. Normal cameras still see it.
	layers = WATER_LAYER_BIT
	for child in get_children():
		if child is GPUParticles3D: child.layers = WATER_LAYER_BIT
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	_shadow_camera.environment = env
	_shadow_capture = WaterShadowCapture.new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [_shadow_capture]
	_shadow_camera.compositor = compositor
	_shadow_viewport.add_child(_shadow_camera)
	add_child(_shadow_viewport, false, Node.INTERNAL_MODE_BACK) # Internal: never saved into scenes.

func _update_water_shadows(fx_list : Array) -> void:
	var active := water_shadows_enabled and _shadow_camera != null and is_instance_valid(_sun) and _sun.visible
	for fx in fx_list:
		if not fx: continue
		fx.shadow_texture = _shadow_capture.shadow_texture if active else RID()
	if not active: return
	var view_camera := get_viewport().get_camera_3d()
	if Engine.is_editor_hint() and Engine.has_singleton(&'EditorInterface'):
		# Looked up dynamically: EditorInterface doesn't exist in exported builds.
		var editor_vp = Engine.get_singleton(&'EditorInterface').get_editor_viewport_3d(0)
		if editor_vp: view_camera = editor_vp.get_camera_3d()
	if not view_camera: return

	var to_sun := _sun.global_basis.z.normalized()
	var basis := Basis.looking_at(-to_sun, Vector3.UP if absf(to_sun.y) < 0.99 else Vector3.FORWARD)
	# Centre on the camera's spot at water level, snapped to whole texels so edges don't shimmer.
	var center := view_camera.global_position
	center.y = global_position.y
	var texel := water_shadow_coverage / float(water_shadow_resolution)
	var r := snappedf(center.dot(basis.x), texel)
	var u := snappedf(center.dot(basis.y), texel)
	var f := center.dot(-basis.z)
	var snapped := basis.x * r + basis.y * u - basis.z * f
	_shadow_camera.size = water_shadow_coverage
	_shadow_camera.global_transform = Transform3D(basis, snapped + to_sun * 400.0)
	for fx in fx_list:
		if not fx: continue
		fx.shadow_transform = _shadow_camera.global_transform
		fx.shadow_half_size = water_shadow_coverage * 0.5
		fx.shadow_softness = water_shadow_softness

func _update_underwater_effect() -> void:
	if not underwater_effect or not wave_generator: return
	var fx := underwater_effect
	fx.displacement_map = wave_generator.descriptors[&'displacement_map'].rid
	fx.normal_map = wave_generator.descriptors[&'normal_map'].rid
	fx.map_scales = map_scales
	fx.water_level = global_position.y
	fx.shape_count = _water_shape_count
	fx.shape_a = _water_shapes_a
	fx.shape_b = _water_shapes_b
	var fog = _water_mat_param(&'underwater_color')
	var absorb = _water_mat_param(&'underwater_absorption')
	if fog is Vector3: fog = Color(fog.x, fog.y, fog.z)
	if absorb is Color: absorb = Vector3(absorb.r, absorb.g, absorb.b)
	var light := _underwater_light_level()
	WATER_MAT.set_shader_parameter(&'underwater_light', light)
	if fog is Color: fx.fog_color = fog * light
	if absorb is Vector3: fx.absorption = absorb
	fx.depth_darkening = depth_darkening
	fx.distortion = underwater_distortion
	fx.blur = underwater_blur
	fx.waterline_width = waterline_width
	fx.waterline_foam = waterline_foam
	fx.waterline_churn = _waterline_churn
	fx.crossing_foam = crossing_foam_strength * pow(_crossing_foam, crossing_foam_falloff)
	var view_cam := _view_camera()
	# masked: the calm near a shore is part of the surface, so it is part of being underwater.
	var lens_sub := (get_wave_height(view_cam.global_position) - view_cam.global_position.y) if view_cam else 0.0
	# Inside a hull (DryVolume) the sea outside may stand higher than your eyes: still dry.
	var lens_dry := view_cam != null and _in_dry_volume(view_cam.global_position)
	if lens_dry: lens_sub = minf(lens_sub, -1.0)
	fx.lens_submersion = lens_sub
	fx.lens_dry = lens_dry
	fx.blocker_count = mini(_wave_blockers.size(), MAX_WAVE_BLOCKERS)
	fx.blocker_a = _blocker_a
	fx.blocker_b = _blocker_b
	fx.blocker_c = _blocker_c
	fx.glow_count = _glow_count
	fx.glow_a = _glow_a
	fx.glow_b = _glow_b
	fx.glow_strength = underwater_glow_strength
	fx.beam_count = _beam_count
	fx.beam_a = _beam_a
	fx.beam_b = _beam_b
	fx.beam_c = _beam_c
	fx.beam_strength = light_beam_strength
	fx.beam_steps = light_beam_quality
	fx.beam_scattering = light_beam_scattering
	fx.beam_shafts = light_beam_shafts
	# The surface needs it too, to know whether a back face is the underside (see water.gdshader).
	WATER_MAT.set_shader_parameter(&'camera_submersion', lens_sub)
	fx.vignette = underwater_vignette
	fx.silhouette_range = silhouette_range
	fx.fog_down = fog_brightness_down
	fx.fog_up = fog_brightness_up
	# The same fog for see-through things that sit in the water (air_bubble.gdshader): the screen
	# effect fogs them at their own distance, so they add the fog for what lies behind them.
	if fog is Color and absorb is Vector3:
		RenderingServer.global_shader_parameter_set(&'underwater_fog', Vector4(fx.fog_color.r, fx.fog_color.g, fx.fog_color.b, depth_darkening))
		RenderingServer.global_shader_parameter_set(&'underwater_absorb', Vector4(absorb.x, absorb.y, absorb.z, silhouette_range))
	RenderingServer.global_shader_parameter_set(&'underwater_view', Vector4(global_position.y, -1.0 if lens_dry else lens_sub, fog_brightness_down, fog_brightness_up))
	if is_instance_valid(_sun) and _sun.visible:
		fx.sun_direction = _sun.global_basis.z # A DirectionalLight3D shines along -Z.
		fx.sun_color = _sun.light_color * _sun_base_energy()
	else:
		fx.sun_direction = Vector3.ZERO
	# Light shaft controls live in the water material's "Light Shafts" uniform group.
	var shaft_tint = _water_mat_param(&'shaft_tint')
	if shaft_tint is Vector3: shaft_tint = Color(shaft_tint.x, shaft_tint.y, shaft_tint.z)
	if shaft_tint is Color: fx.shaft_tint = shaft_tint
	fx.shaft_strength = _water_mat_param(&'shaft_strength') if _water_mat_param(&'shafts_enabled') == true else 0.0
	fx.shaft_max_brightness = _water_mat_param(&'shaft_max_brightness')
	fx.shaft_contrast = _water_mat_param(&'shaft_contrast')
	fx.shaft_threshold = _water_mat_param(&'shaft_threshold')
	fx.shaft_softness = _water_mat_param(&'shaft_softness')
	fx.shaft_scale = _water_mat_param(&'shaft_scale')
	fx.shaft_focus_depth = _water_mat_param(&'shaft_focus_depth')
	fx.shaft_max_distance = _water_mat_param(&'shaft_max_distance')
	fx.shaft_scattering = _water_mat_param(&'shaft_scattering')
	fx.shaft_steps = _water_mat_param(&'shaft_quality')

	_update_water_shadows([underwater_effect, caustics_effect])
	if not caustics_effect: return
	var cx := caustics_effect
	cx.displacement_map = fx.displacement_map
	cx.normal_map = fx.normal_map
	cx.map_scales = map_scales
	cx.shape_count = _water_shape_count
	cx.shape_a = _water_shapes_a
	cx.shape_b = _water_shapes_b
	cx.water_level = fx.water_level
	cx.absorption = fx.absorption
	cx.sun_direction = fx.sun_direction
	cx.sun_color = fx.sun_color
	# Caustic controls live in the water material's "Caustics" uniform group.
	cx.enabled = _water_mat_param(&'caustics_enabled') == true
	var tint = _water_mat_param(&'caustic_tint')
	if tint is Vector3: tint = Color(tint.x, tint.y, tint.z)
	if tint is Color: cx.tint = tint
	cx.strength = _water_mat_param(&'caustic_strength')
	cx.max_brightness = _water_mat_param(&'caustic_max_brightness')
	cx.contrast = _water_mat_param(&'caustic_contrast')
	cx.darkening = _water_mat_param(&'caustic_darkening')
	cx.pattern_scale = _water_mat_param(&'caustic_scale')
	cx.focus_depth = _water_mat_param(&'caustic_focus_depth')
	cx.fade_depth = _water_mat_param(&'caustic_fade_depth')
	cx.dispersion = _water_mat_param(&'caustic_dispersion')
	cx.cascade = _water_mat_param(&'caustic_cascade')

## Material value, falling back to the shader default when it was never changed.
func _water_mat_param(param : StringName) -> Variant:
	var value = WATER_MAT.get_shader_parameter(param)
	if value == null:
		value = RenderingServer.shader_get_parameter_default(WATER_MAT.shader.get_rid(), param)
	return value

## Advances all WaterDeformer nodes and uploads their shapes to the water shader. Effects and
## get_wave_height() read the same packed arrays, so everything agrees on the water height.
func _update_water_shapes(delta : float) -> void:
	_water_shapes_a.resize(MAX_WATER_SHAPES)
	_water_shapes_b.resize(MAX_WATER_SHAPES)
	var count := 0
	for deformer in get_tree().get_nodes_in_group(&'water_deformer'):
		deformer.update_state(delta, global_position.y)
		for shape in deformer.pack_shapes():
			if count >= MAX_WATER_SHAPES: break
			_water_shapes_a[count] = shape[0]
			_water_shapes_b[count] = shape[1]
			count += 1
	_water_shape_count = count
	WATER_MAT.set_shader_parameter(&'water_shape_count', count)
	WATER_MAT.set_shader_parameter(&'water_shape_a', _water_shapes_a)
	WATER_MAT.set_shader_parameter(&'water_shape_b', _water_shapes_b)

## Uploads bounding spheres of the meshes reaching into the water around the camera: the water
## shader only searches for nearby objects (contact foam) inside them, which spares the open sea
## the costliest part of the water. Land (terrain, islands) is found by the shader on its own.
func _update_contact_bodies(delta: float) -> void:
	_contact_refresh -= delta
	if _contact_refresh <= 0.0:
		_contact_refresh = CONTACT_REFRESH
		_find_contact_nodes()
	_contact_bodies.resize(MAX_CONTACT_BODIES)
	var count := 0
	for body in _contact_nodes:
		if is_instance_valid(body[0]) and is_instance_valid(body[1]) and body[0].is_visible_in_tree():
			_contact_bodies[count] = _world_sphere(body)
			count += 1
	WATER_MAT.set_shader_parameter(&'contact_body_count', count)
	WATER_MAT.set_shader_parameter(&'contact_bodies', _contact_bodies)

func _find_contact_nodes() -> void:
	_contact_nodes.clear()
	var cam := _view_camera()
	if cam == null or not is_inside_tree(): return
	var eye := cam.global_position
	var box := AABB(Vector3(eye.x - CONTACT_RANGE, global_position.y - CONTACT_BAND, eye.z - CONTACT_RANGE),
			Vector3(CONTACT_RANGE * 2.0, CONTACT_BAND * 2.0, CONTACT_RANGE * 2.0))
	var found := [] # [mesh or its body (skinned), world sphere]
	for id in RenderingServer.instances_cull_aabb(box, get_world_3d().scenario):
		var node := instance_from_id(id) as MeshInstance3D
		if node == null or node == self or node.layers & WATER_LAYER_BIT or not node.is_visible_in_tree(): continue
		var body := _contact_body(node) if node.skin else []
		# The renderer's bounds can be far bigger than the mesh (cull margins); check the mesh's own.
		var reach: AABB = body[1].global_transform * body[3] if node.skin else node.global_transform * node.get_aabb()
		if reach.position.y > global_position.y + CONTACT_BAND or reach.end.y < global_position.y - CONTACT_BAND: continue
		if reach.size.length() * 0.5 > CONTACT_LAND_SIZE: continue # Land: the shader finds it like terrain.
		var c := reach.get_center()
		found.append([node if body.is_empty() else body, Vector4(c.x, c.y, c.z, reach.size.length() * 0.5)])
	# Drop whatever sits inside another (props on a deck, hull parts): only the outermost are kept.
	var kept := []
	for f in found:
		var s: Vector4 = f[1]
		var inside := false
		for k in range(kept.size() - 1, -1, -1):
			var o: Vector4 = kept[k][1]
			var apart := Vector3(s.x, s.y, s.z).distance_to(Vector3(o.x, o.y, o.z))
			if apart + s.w <= o.w:
				inside = true
				break
			if apart + o.w <= s.w: kept.remove_at(k)
		if not inside: kept.append(f)
	# Nearest first, so if there are too many it is the far ones that lose their foam.
	var near_edge := func(f: Array) -> float: return Vector3(f[1].x, f[1].y, f[1].z).distance_to(eye) - f[1].w
	kept.sort_custom(func(a, b): return near_edge.call(a) < near_edge.call(b))
	for i in mini(kept.size(), MAX_CONTACT_BODIES):
		_contact_nodes.append(kept[i][0] if kept[i][0] is Array else _contact_body(kept[i][0]))

## [mesh, the node it moves with, (centre, radius) and box in that node's space]. A skinned mesh (kraken, fish) is placed by its bones, not by its own node, which
## may carry any scale the skin undoes: its bounds are its bones, worked out every CONTACT_REFRESH
## and padded for the flesh around them and the arms moving in between.
func _contact_body(node: MeshInstance3D) -> Array:
	var box := node.get_aabb()
	var anchor: Node3D = node
	var skeleton := node.get_node_or_null(node.skeleton) as Skeleton3D if node.skin else null
	if skeleton and skeleton.get_bone_count() > 0:
		anchor = skeleton
		box = AABB(skeleton.get_bone_global_pose(0).origin, Vector3.ZERO)
		for bone in range(1, skeleton.get_bone_count()):
			box = box.expand(skeleton.get_bone_global_pose(bone).origin)
		var s := skeleton.global_transform.basis.get_scale()
		var pad := 1.5 + box.size.length() * maxf(s.x, maxf(s.y, s.z)) * 0.15
		box = box.grow(pad / maxf(s.x, maxf(s.y, s.z)))
	var c := box.get_center()
	return [node, anchor, Vector4(c.x, c.y, c.z, box.size.length() * 0.5), box]

func _world_sphere(body: Array) -> Vector4:
	var anchor: Node3D = body[1]
	var local: Vector4 = body[2]
	var t := anchor.global_transform
	var centre := t * Vector3(local.x, local.y, local.z)
	var s := t.basis.get_scale()
	return Vector4(centre.x, centre.y, centre.z, local.w * maxf(s.x, maxf(s.y, s.z)))

## Uploads all WaveBlocker nodes to the water shader (they can move each frame,
## eg. a calm zone parented to the ship) and caches them for CPU sampling.
func _update_wave_blockers() -> void:
	_wave_blockers = get_tree().get_nodes_in_group(&'wave_blocker')
	var count := mini(_wave_blockers.size(), MAX_WAVE_BLOCKERS)
	_blocker_a.resize(MAX_WAVE_BLOCKERS)
	_blocker_b.resize(MAX_WAVE_BLOCKERS)
	_blocker_c.resize(MAX_WAVE_BLOCKERS)
	for i in count:
		var blocker = _wave_blockers[i]
		if blocker.follows_waves:
			blocker.calm_plane = _wave_plane(blocker)
		_blocker_a[i] = blocker.pack_a()
		_blocker_b[i] = blocker.pack_b()
		_blocker_c[i] = blocker.pack_c()
	WATER_MAT.set_shader_parameter(&'wave_blocker_count', count)
	WATER_MAT.set_shader_parameter(&'wave_blocker_a', _blocker_a)
	WATER_MAT.set_shader_parameter(&'wave_blocker_b', _blocker_b)
	WATER_MAT.set_shader_parameter(&'wave_blocker_c', _blocker_c)

## The plane through the real waves under a blocker's footprint: (height at its centre, dh/dx,
## dh/dz), from the heights at its ends and sides. Spanning the whole footprint, it follows the
## long waves (a swell lifting and tilting a ship) and averages away the short ones.
func _wave_plane(blocker: Node) -> Vector3:
	var c: Vector4 = blocker.pack_a()
	var center := Vector3(c.x, 0.0, c.y)
	var along := Vector3(c.z, 0.0, c.w) # the footprint's frame, see wave_blocker.gd
	var across := Vector3(-c.w, 0.0, c.z)
	var half: Vector2 = blocker.half_size()
	half = Vector2(maxf(half.x, 0.5), maxf(half.y, 0.5))
	var slope_along := (_waves_only(center + along * half.x) - _waves_only(center - along * half.x)) / (2.0 * half.x)
	var slope_across := (_waves_only(center + across * half.y) - _waves_only(center - across * half.y)) / (2.0 * half.y)
	var gradient := Vector2(c.z, c.w) * slope_along + Vector2(-c.w, c.z) * slope_across
	return Vector3(_waves_only(center), gradient.x, gradient.y)

## The waves alone at a position, without the water shapes: those are added on top of a calm
## plane everywhere (here, in the shader and the underwater effect), so a plane that held them
## too would lift the calmed water by them twice.
func _waves_only(p: Vector3) -> float:
	return get_wave_height(p, false) - water_shapes_eval(Vector2(p.x, p.z)).x

func _in_dry_volume(world_pos : Vector3) -> bool:
	for volume in _dry_volumes:
		if is_instance_valid(volume) and volume.contains(world_pos):
			return true
	return false

## Uploads the DryVolume nodes (their baked maps, and where they are now) to the water shader,
## which leaves the surface out inside them.
func _update_dry_volumes() -> void:
	_dry_volumes.clear()
	for volume in get_tree().get_nodes_in_group(&'dry_volume'):
		if volume.enabled and volume.map and _dry_volumes.size() < MAX_DRY_VOLUMES:
			_dry_volumes.append(volume)
	var signature := []
	for volume in _dry_volumes: signature.append([volume.get_instance_id(), volume.bake_version])
	if signature != _dry_signature:
		_dry_signature = signature
		var images : Array[Image] = []
		for volume in _dry_volumes: images.append(volume.map)
		if not images.is_empty():
			_dry_maps.create_from_images(images)
			WATER_MAT.set_shader_parameter(&'dry_maps', _dry_maps)
	var rows := PackedVector4Array()
	var bounds := PackedVector4Array()
	rows.resize(MAX_DRY_VOLUMES * 3)
	bounds.resize(MAX_DRY_VOLUMES)
	for i in _dry_volumes.size():
		var r : Array[Vector4] = _dry_volumes[i].pack_rows()
		for k in 3: rows[i * 3 + k] = r[k]
		bounds[i] = _dry_volumes[i].bounds
	WATER_MAT.set_shader_parameter(&'dry_count', _dry_volumes.size())
	WATER_MAT.set_shader_parameter(&'dry_rows', rows)
	WATER_MAT.set_shader_parameter(&'dry_bounds', bounds)

## Uploads the UnderwaterGlow nodes nearest the camera to the water shader and underwater effect.
## Lamps shining into the water (group underwater_beam), nearest to the camera first. Lamps
## that are switched off (hidden) or dark throw no beam.
func _update_beams() -> void:
	var cam := _view_camera()
	var eye := cam.global_position if cam else Vector3.ZERO
	var lights := []
	if light_beam_strength > 0.0:
		for light in get_tree().get_nodes_in_group(&'underwater_beam'):
			if light is Light3D and light.is_visible_in_tree() and light.light_energy > 0.0 \
					and (light is SpotLight3D or light is OmniLight3D):
				lights.append(light)
	if lights.size() > MAX_BEAMS:
		lights.sort_custom(func(a, b): return a.global_position.distance_squared_to(eye) < b.global_position.distance_squared_to(eye))
	_beam_count = mini(lights.size(), MAX_BEAMS)
	_beam_a.resize(MAX_BEAMS)
	_beam_b.resize(MAX_BEAMS)
	_beam_c.resize(MAX_BEAMS)
	for i in _beam_count:
		var light: Light3D = lights[i]
		var p := light.global_position
		var energy := light.light_color * light.light_energy
		var reach: float
		if light is SpotLight3D:
			reach = light.spot_range
			var edge := deg_to_rad(light.spot_angle)
			var forward := -light.global_basis.z.normalized() # a SpotLight3D shines along -Z
			_beam_b[i] = Vector4(forward.x, forward.y, forward.z, cos(edge))
			_beam_c[i] = Vector4(energy.r, energy.g, energy.b, cos(edge * 0.7))
		else:
			reach = light.omni_range
			_beam_b[i] = Vector4(0.0, 0.0, 0.0, -2.0) # no cone: every direction is inside
			_beam_c[i] = Vector4(energy.r, energy.g, energy.b, -1.0)
		_beam_a[i] = Vector4(p.x, p.y, p.z, reach)

func _update_glows() -> void:
	var glows := []
	for glow in get_tree().get_nodes_in_group(&'underwater_glow'):
		if glow.is_visible_in_tree(): glows.append(glow)
	var cam := _view_camera()
	if cam and glows.size() > MAX_GLOWS:
		var eye := cam.global_position
		glows.sort_custom(func(a, b): return a.global_position.distance_squared_to(eye) < b.global_position.distance_squared_to(eye))
	_glow_count = mini(glows.size(), MAX_GLOWS)
	_glow_a.resize(MAX_GLOWS)
	_glow_b.resize(MAX_GLOWS)
	for i in _glow_count:
		_glow_a[i] = glows[i].pack_a()
		_glow_b[i] = glows[i].pack_b()
	WATER_MAT.set_shader_parameter(&'glow_count', _glow_count)
	WATER_MAT.set_shader_parameter(&'glow_a', _glow_a)
	WATER_MAT.set_shader_parameter(&'glow_b', _glow_b)

func _update_scales_uniform() -> void:
	map_scales.resize(len(parameters))
	for i in len(parameters):
		var params := parameters[i]
		var uv_scale := Vector2.ONE / params.tile_length
		map_scales[i] = Vector4(uv_scale.x, uv_scale.y, params.displacement_scale, params.normal_scale)
	
	# No global shader parameter for arrays :(
	WATER_MAT.set_shader_parameter(&'map_scales', map_scales)
	SPRAY_MAT.set_shader_parameter(&'map_scales', map_scales)

func _update_water(delta : float) -> void:
	if wave_generator == null: _setup_wave_generator()
	wave_generator.update(delta, parameters)

## The sea past the clipmap's edge, out to FAR_RING_REACH: an internal child drawn with the same
## material, so it is lit, tinted and mirrors the sky exactly like the water near you, and the
## ocean runs on to the horizon instead of ending in a seam against the sky. Its inner edge is
## the clipmap's own boundary vertices, so the waves (which the shader fades to flat by ~1 km
## anyway) carry across without a crack; past that it is a few big flat triangles. Follows the
## camera with this node, like the clipmap.
const FAR_RING_REACH := 16000.0 # m from the centre: beyond any camera's far plane
const FAR_RING_GROWTH := 1.06 # each loop of the ring is this much wider than the last

var _far_ring: MeshInstance3D

func _build_far_ring() -> void:
	if mesh == null:
		return
	# The clipmap's boundary, in order around it.
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var half := 0.0
	for v in verts:
		half = maxf(half, maxf(absf(v.x), absf(v.z)))
	var edge := {}
	for v in verts:
		if absf(absf(v.x) - half) < 0.01 or absf(absf(v.z) - half) < 0.01:
			edge[Vector2(snappedf(v.x, 0.01), snappedf(v.z, 0.01))] = true
	var loop: Array = edge.keys()
	loop.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.angle() < b.angle())
	var n := loop.size()
	if n < 4:
		return
	# Loops of the same shape, each FAR_RING_GROWTH times wider, until it reaches FAR_RING_REACH.
	var loops := ceili(log(FAR_RING_REACH / half) / log(FAR_RING_GROWTH))
	var points := PackedVector3Array()
	for k in loops + 1:
		var scale := pow(FAR_RING_GROWTH, k)
		for v: Vector2 in loop:
			points.append(Vector3(v.x * scale, 0.0, v.y * scale))
	var indices := PackedInt32Array()
	for k in loops:
		for i in n:
			var a := k * n + i
			var b := k * n + (i + 1) % n
			indices.append_array([a, b, a + n, b, b + n, a + n])
	var normals := PackedVector3Array()
	normals.resize(points.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var ring := ArrayMesh.new()
	ring.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if not is_instance_valid(_far_ring):
		_far_ring = MeshInstance3D.new()
		_far_ring.name = &'FarRing'
		add_child(_far_ring, false, Node.INTERNAL_MODE_BACK)
	_far_ring.mesh = ring
	_far_ring.material_override = material_override
	_far_ring.layers = layers
	_far_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_far_ring.sorting_offset = sorting_offset
	_far_ring.extra_cull_margin = extra_cull_margin

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		displacement_maps.texture_rd_rid = RID()
		normal_maps.texture_rd_rid = RID()
		if _wake_map: _wake_map.free_resources()

var _quality_base := {}

## Water effects quality preset from the settings menu: 0 = low, 1 = medium, 2 = high (the values
## set in the scene and the water material). Lower levels scale down from those values.
##   low:    no water shadows, no caustics, coarse light shafts, fewer foam samples and specks
##   medium: small shadow map, lighter shafts/foam/specks
func set_effects_quality(level : int) -> void:
	level = clampi(level, 0, 2)
	if _quality_base.is_empty():
		_quality_base = {
			shadows = water_shadows_enabled,
			shadow_res = water_shadow_resolution,
			snow = marine_snow_amount,
			caustics = _water_mat_param(&'caustics_enabled'),
			shaft_quality = _water_mat_param(&'shaft_quality'),
			foam_samples = _water_mat_param(&'contact_foam_samples'),
		}
	var scale : float = [0.3, 0.6, 1.0][level]
	water_shadows_enabled = _quality_base.shadows and level > 0
	water_shadow_resolution = _quality_base.shadow_res if level == 2 else mini(_quality_base.shadow_res, 256)
	marine_snow_amount = maxi(int(_quality_base.snow * scale), 1)
	WATER_MAT.set_shader_parameter(&'caustics_enabled', _quality_base.caustics == true and level > 0)
	WATER_MAT.set_shader_parameter(&'shaft_quality', maxi(int(_quality_base.shaft_quality * scale), 6))
	WATER_MAT.set_shader_parameter(&'contact_foam_samples', maxi(int(_quality_base.foam_samples * scale), 4))

## How much light comes down into the water right now, 0..1 (see underwater_follows_light).
## Uses the surface values, not the ones dimmed while the camera is under.
func _underwater_light_level() -> float:
	if not underwater_follows_light: return 1.0
	var sun_part := 0.0
	if is_instance_valid(_sun) and _sun.visible:
		# A DirectionalLight3D shines along -Z, so +Z points at the sun: its height is z.y.
		sun_part = _sun_base_energy() * smoothstep(-0.05, 0.2, _sun.global_basis.z.y)
	var sky := 1.0
	_find_environment()
	if _env:
		var ambient := _env_ambient_base if _env_ambient_base >= 0.0 else _env.ambient_light_energy
		var background := _env_sky_energy_base if _env_sky_energy_base >= 0.0 else _env.background_energy_multiplier
		sky = maxf(ambient, background)
	return clampf(maxf(sun_part, sky) / maxf(underwater_daylight, 0.01), 0.0, 1.0)

func _find_environment() -> void:
	if _env: return
	var envs := (owner if owner else get_parent()).find_children('*', 'WorldEnvironment', true, false)
	if not envs.is_empty(): _env = envs[0].environment

func _sun_base_energy() -> float:
	return _sun_energy_base if _sun_energy_base >= 0.0 else _sun.light_energy

## Sun, ambient and sky energy as they are above the water (x, y, z), or -1 for any not yet
## remembered (then the live value is still the surface one). Used by weather presets, since the
## live values are dimmed while the camera is under water.
func get_surface_lighting() -> Vector3:
	return Vector3(_sun_energy_base, _env_ambient_base, _env_sky_energy_base)

## Sets the above-water sun, ambient and sky energy the depth dimming works from. Returns false
## if they aren't remembered yet, in which case set the live values instead.
func set_surface_lighting(energy : Vector3) -> bool:
	if _sun_energy_base < 0.0 or _env_ambient_base < 0.0: return false
	_sun_energy_base = energy.x
	_env_ambient_base = energy.y
	_env_sky_energy_base = energy.z
	return true

## Sunlight and skylight only reach the depth through the water: dim them as the camera sinks.
## The originals are remembered and put back when the camera surfaces (and in the editor).
func _update_depth_lighting() -> void:
	if Engine.is_editor_hint() or not is_instance_valid(_sun): return
	_find_environment()
	if _sun_energy_base < 0.0:
		_sun_energy_base = _sun.light_energy
		if _env:
			_env_ambient_base = _env.ambient_light_energy
			_env_sky_energy_base = _env.background_energy_multiplier
	var cam := _view_camera()
	var depth := 0.0
	if dim_sunlight_underwater and cam:
		depth = maxf(get_wave_height(cam.global_position) - cam.global_position.y, 0.0)
	_update_waterline_churn(cam)
	var light := exp(-depth_darkening * depth)
	_sun.light_energy = _sun_energy_base * light
	if _env:
		_env.ambient_light_energy = _env_ambient_base * light
		_env.background_energy_multiplier = _env_sky_energy_base * light

## Air is only churned up where the surface is actually being broken: the faster the lens
## crosses it, the more of a cloud it drags down, and the cloud clears over the next second.
func _update_waterline_churn(cam : Camera3D) -> void:
	var delta := get_process_delta_time()
	_waterline_churn = maxf(_waterline_churn - delta / maxf(waterline_churn_time, 0.05), 0.0)
	if not cam or delta <= 0.0: return
	var submersion := get_wave_height(cam.global_position) - cam.global_position.y
	# Breaking the surface, either way round, throws up foam: rises fast, then fades out.
	# Full the instant the surface is broken, then down to nothing over crossing_foam_time.
	_crossing_foam = maxf(_crossing_foam - delta / maxf(crossing_foam_time, 0.05), 0.0)
	if _last_cam_submersion != INF and signf(submersion) != signf(_last_cam_submersion):
		_crossing_foam = 1.0
	if _last_cam_submersion != INF and absf(submersion) < 1.5:
		var crossing_speed := absf(submersion - _last_cam_submersion) / delta
		_waterline_churn = maxf(_waterline_churn, clampf(crossing_speed / 2.5, 0.0, 1.0))
	_last_cam_submersion = submersion

func _view_camera() -> Camera3D:
	var cam := get_viewport().get_camera_3d()
	if Engine.is_editor_hint() and Engine.has_singleton(&'EditorInterface'):
		var editor_vp = Engine.get_singleton(&'EditorInterface').get_editor_viewport_3d(0)
		if editor_vp: cam = editor_vp.get_camera_3d()
	return cam

## The water rising up the screen, the exposure dip and air beads on the lens around going under (not in the editor; inside a dry hull
## the lens isn't underwater).
func _update_submerge_lens(delta : float) -> void:
	if Engine.is_editor_hint(): return
	if not _submerge_lens:
		_submerge_lens = SubmergeLens.new()
		add_child(_submerge_lens, false, Node.INTERNAL_MODE_BACK) # Internal: never saved into scenes.
	var cam := _view_camera()
	if not cam: return
	var submersion := get_wave_height(cam.global_position) - cam.global_position.y
	var lens := _submerge_lens
	lens.enabled = lens_beads_enabled
	lens.duration = lens_bead_time
	lens.count = lens_bead_count
	lens.bead_size = lens_bead_size
	lens.refraction = lens_bead_refraction
	lens.brightness = lens_bead_brightness
	lens.tint = lens_bead_color
	lens.blur = lens_bead_blur
	lens.rise = lens_bead_rise
	lens.wobble = lens_bead_wobble
	lens.min_air_time = lens_bead_min_air_time
	lens.exposure_dip = submerge_exposure_dip
	lens.exposure_hold = submerge_exposure_hold
	lens.exposure_time = submerge_exposure_time
	lens.wipe_height = submerge_wipe_height
	lens.wipe_wave = submerge_wipe_wave
	lens.wipe_softness = submerge_wipe_softness
	lens.wipe_sheen = submerge_wipe_sheen
	lens.update(submersion, _in_dry_volume(cam.global_position), delta)

## Keeps the marine snow box centred on the camera; hidden above water.
func _update_marine_snow() -> void:
	var cam := _view_camera()
	var active := marine_snow_enabled and cam != null and cam.global_position.y < get_wave_height(cam.global_position, false)
	if not _marine_snow:
		if not active: return
		_marine_snow = GPUParticles3D.new()
		_marine_snow.name = 'MarineSnow'
		_marine_snow.amount = maxi(marine_snow_amount, 1)
		_marine_snow.lifetime = 600.0
		_marine_snow.explosiveness = 1.0 # All specks exist at once; they never die, just wrap around.
		_marine_snow.local_coords = false
		_marine_snow.fixed_fps = 0
		_marine_snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_marine_snow.layers = WATER_LAYER_BIT # Skipped by the sun shadow camera.
		var pm := ShaderMaterial.new()
		pm.shader = preload('res://assets/shaders/particles/marine_snow.gdshader')
		_marine_snow.process_material = pm
		var mat := ShaderMaterial.new()
		mat.shader = preload('res://assets/shaders/particles/water_speck.gdshader')
		var quad := QuadMesh.new()
		quad.material = mat
		_marine_snow.draw_pass_1 = quad
		add_child(_marine_snow, false, Node.INTERNAL_MODE_BACK) # Internal: never saved into scenes.
	_marine_snow.visible = active
	if not active: return
	var center := cam.global_position
	_marine_snow.global_position = center
	_marine_snow.visibility_aabb = AABB(-marine_snow_box * 0.5 - Vector3.ONE, marine_snow_box + Vector3.ONE * 2.0)
	var pm := _marine_snow.process_material as ShaderMaterial
	pm.set_shader_parameter(&'center', center)
	pm.set_shader_parameter(&'box_size', marine_snow_box)
	pm.set_shader_parameter(&'size', marine_snow_size)
	pm.set_shader_parameter(&'drift_speed', marine_snow_drift)
	pm.set_shader_parameter(&'sink_speed', marine_snow_sink)
	var mat := (_marine_snow.draw_pass_1 as QuadMesh).material as ShaderMaterial
	mat.set_shader_parameter(&'color', marine_snow_color)
	mat.set_shader_parameter(&'fade_distance', marine_snow_fade_distance)
	mat.set_shader_parameter(&'square', marine_snow_square)
	mat.set_shader_parameter(&'water_level', global_position.y)
	mat.set_shader_parameter(&'depth_darkening', depth_darkening)
	apply_glows_to(mat)

## See-through things in the water (air_bubble.gdshader, meshes in the underwater_see_through
## group) add the glow light behind them that the underwater effect stops at their front.
func _update_see_through() -> void:
	var done := {}
	for mesh in get_tree().get_nodes_in_group(&'underwater_see_through'):
		if not (mesh is GeometryInstance3D) or not mesh.is_visible_in_tree(): continue
		var mat : Material = mesh.material_override
		if not mat and mesh is MeshInstance3D: mat = mesh.get_surface_override_material(0)
		while mat is ShaderMaterial and not done.has(mat):
			done[mat] = true
			apply_glows_to(mat)
			mat = mat.next_pass

## Hands this frame's UnderwaterGlow nodes to a speck material (water_speck.gdshader), so marine
## snow and bubbles catch their light.
func apply_glows_to(mat : ShaderMaterial) -> void:
	mat.set_shader_parameter(&'glow_count', _glow_count)
	mat.set_shader_parameter(&'glow_a', _glow_a)
	mat.set_shader_parameter(&'glow_b', _glow_b)
	mat.set_shader_parameter(&'glow_strength', underwater_glow_strength)
	var cam := _view_camera()
	if cam: mat.set_shader_parameter(&'viewport_height', cam.get_viewport().get_visible_rect().size.y)

## Stamps every WakeEmitter's path into the wake map and hands it to the water material.
func _update_wakes(delta : float) -> void:
	if not wakes_enabled:
		WATER_MAT.set_shader_parameter(&'wake_map_rect', Vector4.ZERO)
		return
	if not _wake_map:
		_wake_map = WakeMap.new(WAKE_MAP_RESOLUTION, wake_coverage)
		WATER_MAT.set_shader_parameter(&'wake_map', _wake_map.texture)
	var view_camera := get_viewport().get_camera_3d()
	if Engine.is_editor_hint() and Engine.has_singleton(&'EditorInterface'):
		var editor_vp = Engine.get_singleton(&'EditorInterface').get_editor_viewport_3d(0)
		if editor_vp: view_camera = editor_vp.get_camera_3d()
	var center := view_camera.global_position if view_camera else global_position
	var stamps := []
	for emitter in get_tree().get_nodes_in_group(&'wake_emitter'):
		var stamp : Array = emitter.get_stamp(delta, get_wave_height(emitter.global_position, false))
		if not stamp.is_empty(): stamps.append(stamp)
	_wake_map.update(delta, center, stamps, wake_lifetime, wake_spread)
	WATER_MAT.set_shader_parameter(&'wake_map_rect', _wake_map.rect)

## Displacement at `uv` right now. The newest readback is already a readback interval plus a
## few frames old, and the eyes are kept off the waterline with it (player.gd), so a lagging
## surface puts them straight into the one being drawn. Instead it is carried forward along
## the change between the last two readbacks: waves change smoothly over seconds, so the
## straight-line guess lands within a couple of centimetres. Capped at 1.5 intervals ahead,
## in water time, so a stalled readback or a paused game can't send it running off.
func _sample_displacement(cascade: int, uv: Vector2) -> Vector3:
	var img := _imgs[cascade]
	if img == null:
		return Vector3.ZERO # not read back yet
	var latest := _sample_image(img, uv)
	var prev := _imgs_prev[cascade]
	var span := _img_times[cascade] - _img_prev_times[cascade]
	if prev == null or span <= 0.0:
		return latest
	var ahead := clampf((time - _img_times[cascade]) / span, 0.0, 1.5)
	return latest + (latest - _sample_image(prev, uv)) * ahead

func _sample_image(img: Image, uv: Vector2) -> Vector3:
	# Wrap UVs
	uv.x = wrapf(uv.x, 0.0, 1.0)
	uv.y = wrapf(uv.y, 0.0, 1.0)
	
	# Calculate coordinates
	var w := img.get_width()
	var x: float = uv.x * (w - 1)
	var y: float = uv.y * (w - 1)
	
	var x0 := int(floor(x))
	var y0 := int(floor(y))
	var x1 = min(x0 + 1, w - 1)
	var y1 = min(y0 + 1, w - 1)
	
	var fx := x - x0
	var fy := y - y0
	
	# Get cached pixel data
	var c00: Color = img.get_pixel(x0, y0) # _cached_displacements[y0 * img_width + x0]
	var c10: Color = img.get_pixel(x1, y0) # _cached_displacements[y0 * img_width + x1]
	var c01: Color = img.get_pixel(x0, y1) #_cached_displacements[y1 * img_width + x0]
	var c11: Color = img.get_pixel(x1, y1) #_cached_displacements[y1 * img_width + x1]
	
	# Bilinear interpolation
	var col_x0 := c00.lerp(c10, fx)
	var col_x1 := c01.lerp(c11, fx)
	var col := col_x0.lerp(col_x1, fy)
	
	return Vector3(col.r, col.g, col.b)
