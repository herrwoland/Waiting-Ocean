@tool
class_name Weather extends Node
## Weather presets (SeaState files in assets/weather/presets): pick one in `preset` and the sea,
## sky, clouds, fog, sun and rain switch over to it, in the editor too. From code,
## transition_to() blends to one over time (eg. a storm building up during a day).
## To make a preset: tune the scene in the inspector, type a name in `new_preset_name` and press
## "Save Current As Preset". "Update Preset" overwrites the selected preset with the scene.

const PRESET_DIR := 'res://assets/weather/presets/'
## Wave cascade properties a preset holds.
const WAVE_PROPS : Array[StringName] = [&'tile_length', &'displacement_scale', &'normal_scale',
		&'wind_speed', &'wind_direction', &'fetch_length', &'swell', &'spread', &'detail', &'whitecap', &'foam_amount']
const WATER_PROPS : Array[StringName] = [&'water_color', &'foam_color', &'translucency_color',
		&'translucency_strength', &'translucency_see_through', &'translucency_sharpness', &'translucency_distortion',
		&'translucency_height_bias', &'translucency_crest_glow']
const ENVIRONMENT_PROPS : Array[StringName] = [&'background_energy_multiplier', &'ambient_light_color',
		&'ambient_light_energy', &'ambient_light_sky_contribution', &'tonemap_exposure', &'glow_intensity',
		&'glow_strength', &'glow_bloom', &'fog_enabled', &'fog_light_color', &'fog_light_energy',
		&'fog_sun_scatter', &'fog_density', &'fog_sky_affect', &'fog_height', &'fog_height_density',
		&'fog_depth_curve', &'fog_depth_begin', &'fog_depth_end', &'volumetric_fog_enabled',
		&'volumetric_fog_density', &'volumetric_fog_albedo', &'volumetric_fog_emission',
		&'volumetric_fog_emission_energy', &'volumetric_fog_anisotropy', &'volumetric_fog_length',
		&'volumetric_fog_ambient_inject', &'volumetric_fog_sky_affect']
const SUN_PROPS : Array[StringName] = [&'quaternion', &'light_color', &'light_energy',
		&'light_indirect_energy', &'light_volumetric_fog_energy', &'shadow_opacity']
const FOG_PROPS : Array[StringName] = [&'density', &'albedo', &'emission', &'height_falloff', &'edge_fade']
const RAIN_PROPS : Array[StringName] = [&'intensity', &'wind_direction', &'wind_strength', &'gustiness', &'streak_opacity']
## Water material parameters that aren't weather: driven by code every frame, or by the
## graphics quality setting.
const WATER_MATERIAL_SKIP : Array[StringName] = [&'camera_submersion', &'underwater_light', &'rain_intensity', &'map_scales',
		&'wake_map_rect', &'water_shape_a', &'water_shape_b', &'wave_blocker_a', &'wave_blocker_b',
		# Translucency: stored as the Water node's dials (WATER_PROPS), which set these.
		&'sss_color', &'sss_strength', &'sss_power', &'sss_distortion', &'sss_height_bias',
		&'sss_crest_glow', &'sss_wave_amplitude', &'sss_see_through', &'sss_sun']
## Only continuous values are blended and stored from materials (no textures, switches or counts).
const MATERIAL_TYPES : Array[int] = [TYPE_FLOAT, TYPE_COLOR, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4]
## How often the waves are rebuilt during a transition (each rebuild is a small GPU job).
const WAVE_UPDATE_INTERVAL := 0.1

## The weather. Picking one applies it straight away.
@export var preset : SeaState :
	set(value):
		preset = value
		if is_node_ready() and value: apply(value)

@export_group('Days')
## Weather each day wakes up to. Empty keeps whatever the weather is.
@export var day_1 : SeaState
@export var day_2 : SeaState
@export var day_3 : SeaState
@export var day_4 : SeaState
@export var day_5 : SeaState
@export_group('')

@export var water : MeshInstance3D
@export var sun : DirectionalLight3D
@export var world_environment : WorldEnvironment
@export var world_fog : FogVolume
@export var rain : Rain

@export_group('Make Presets')
## File name for "Save Current As Preset" (saved to assets/weather/presets/).
@export var new_preset_name := ''
@export_tool_button('Save Current As Preset', 'Save') var save_preset_button := save_current_as_preset
@export_tool_button('Update Preset', 'Reload') var update_preset_button := update_preset

var _from : SeaState
var _to : SeaState
var _duration := 0.0
var _t := 0.0
var _wave_timer := 0.0

func _ready() -> void:
	add_to_group(&'weather')
	_add_cloud_map()
	# In the editor the scene already holds the look (tweaks made after picking a preset
	# included), so it's only applied when a preset is picked.
	if Engine.is_editor_hint(): return
	if preset: apply(preset)
	var bus := get_node_or_null(^'/root/EventBus')
	if bus: bus.day_started.connect(_on_day_started)

## The sky's clouds are rendered into a map on the GPU (see cloud_map.gd), in the editor too.
## An internal child, so it's never saved with the scene.
func _add_cloud_map() -> void:
	var env := _environment()
	var mat := env.sky.sky_material as ShaderMaterial if env and env.sky else null
	if not mat: return
	var map := CloudMap.new()
	map.sky_material = mat
	map.sun = sun
	add_child(map, false, Node.INTERNAL_MODE_BACK)

## The weather set for `day` (1 = first), or null.
func day_weather(day : int) -> SeaState:
	return get('day_%d' % day) as SeaState if day >= 1 and day <= 5 else null

func _on_day_started(day : int) -> void:
	var state := day_weather(day)
	if state: transition_to(state)

## Switches to `state` at once.
func apply(state : SeaState) -> void:
	_to = null
	_apply(null, state, 1.0, true)
	for child in get_children(true):
		if child is CloudMap: child.restart() # Redraw the clouds at once rather than blend over.
	_mark_scene_unsaved()

## Blends everything from how it looks now to `state` over `seconds` (0 = at once).
func transition_to(state : SeaState, seconds := 0.0) -> void:
	if not state: return
	if seconds <= 0.0:
		apply(state)
		return
	_from = capture()
	_to = state
	_duration = seconds
	_t = 0.0
	_wave_timer = 0.0

func is_transitioning() -> bool:
	return _to != null

func _process(delta : float) -> void:
	if not _to: return
	_t = minf(_t + delta / _duration, 1.0)
	_wave_timer -= delta
	var waves := _t >= 1.0 or _wave_timer <= 0.0
	if waves: _wave_timer = WAVE_UPDATE_INTERVAL
	_apply(_from, _to, smoothstep(0.0, 1.0, _t), waves)
	if _t >= 1.0: _to = null

## The scene's current weather as a preset.
func capture() -> SeaState:
	var s := SeaState.new()
	if water:
		for cascade in _cascades():
			s.waves.append(_read(cascade, WAVE_PROPS))
		s.water = _read(water, WATER_PROPS)
		s.water_material = _read_material(water.material_override, WATER_MATERIAL_SKIP)
	var env := _environment()
	if env:
		s.environment = _read(env, ENVIRONMENT_PROPS)
		if env.sky: s.sky_material = _read_material(env.sky.sky_material, [])
	if sun: s.sun = _read(sun, SUN_PROPS)
	# Under water the live lighting is dimmed; store the surface values.
	var surface := _surface_lighting()
	if surface.x >= 0.0 and s.sun.has(&'light_energy'): s.sun[&'light_energy'] = surface.x
	if surface.y >= 0.0 and s.environment.has(&'ambient_light_energy'): s.environment[&'ambient_light_energy'] = surface.y
	if surface.z >= 0.0 and s.environment.has(&'background_energy_multiplier'): s.environment[&'background_energy_multiplier'] = surface.z
	if world_fog and world_fog.material: s.world_fog = _read(world_fog.material, FOG_PROPS)
	if rain: s.rain = _read(rain, RAIN_PROPS)
	return s

func save_current_as_preset() -> void:
	var file := new_preset_name.strip_edges().to_snake_case().validate_filename()
	if file.is_empty():
		push_warning('Weather: type a name in "New Preset Name" first.')
		return
	DirAccess.make_dir_recursive_absolute(PRESET_DIR)
	var path := PRESET_DIR + file + '.tres'
	var err := ResourceSaver.save(capture(), path)
	if err != OK:
		push_error('Weather: could not save %s (error %d).' % [path, err])
		return
	_rescan()
	preset = load(path)
	new_preset_name = ''
	print('Weather: saved preset ', path)

func update_preset() -> void:
	if not preset or preset.resource_path.is_empty():
		push_warning('Weather: pick a preset to update first.')
		return
	var s := capture()
	for p in [&'waves', &'water', &'water_material', &'sky_material', &'environment', &'sun', &'world_fog', &'rain']:
		preset.set(p, s.get(p))
	var err := ResourceSaver.save(preset, preset.resource_path)
	if err != OK:
		push_error('Weather: could not save %s (error %d).' % [preset.resource_path, err])
		return
	print('Weather: updated preset ', preset.resource_path)

# --- Applying ---

func _apply(a : SeaState, b : SeaState, k : float, waves : bool) -> void:
	if water:
		if waves:
			var cascades := _cascades()
			for i in mini(b.waves.size(), cascades.size()):
				_write(cascades[i], a.waves[i] if a and i < a.waves.size() else {}, b.waves[i], k)
		_write(water, a.water if a else {}, b.water, k)
		_write_material(water.material_override, a.water_material if a else {}, b.water_material, k)
	var env := _environment()
	# The sun's and sky's brightness go through the water, which dims them while under it.
	var sun_b := b.sun.duplicate()
	var env_b := b.environment.duplicate()
	var lighting_keys : Array[StringName] = [&'light_energy', &'ambient_light_energy', &'background_energy_multiplier']
	var lighting := Vector3(-1.0, -1.0, -1.0)
	var current := _current_lighting()
	for i in 3:
		var key := lighting_keys[i]
		var target : Dictionary = b.sun if i == 0 else b.environment
		var start : Dictionary = (a.sun if i == 0 else a.environment) if a else {}
		lighting[i] = _mix(start.get(key, current[i]), target.get(key, current[i]), k)
	if water and water.has_method(&'set_surface_lighting') and not Engine.is_editor_hint() \
			and water.call(&'set_surface_lighting', lighting):
		sun_b.erase(&'light_energy')
		env_b.erase(&'ambient_light_energy')
		env_b.erase(&'background_energy_multiplier')
	if env:
		_write(env, a.environment if a else {}, env_b, k)
		if env.sky: _write_material(env.sky.sky_material, a.sky_material if a else {}, b.sky_material, k)
	if sun: _write(sun, a.sun if a else {}, sun_b, k)
	if world_fog and world_fog.material: _write(world_fog.material, a.world_fog if a else {}, b.world_fog, k)
	if rain: _write(rain, a.rain if a else {}, b.rain, k)

func _write(target : Object, a : Dictionary, b : Dictionary, k : float) -> void:
	for key in b:
		target.set(key, _mix(a.get(key), b[key], k))

func _write_material(material : Material, a : Dictionary, b : Dictionary, k : float) -> void:
	var mat := material as ShaderMaterial
	if not mat: return
	for key in b:
		mat.set_shader_parameter(key, _mix(a.get(key), b[key], k))

## Blends numbers, colours, vectors and rotations; anything else switches halfway through.
static func _mix(a : Variant, b : Variant, k : float) -> Variant:
	if k >= 1.0 or a == null or typeof(a) != typeof(b): return b
	match typeof(a):
		TYPE_FLOAT, TYPE_COLOR, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4:
			return lerp(a, b, k)
		TYPE_QUATERNION:
			return (a as Quaternion).slerp(b, k)
	return b if k >= 0.5 else a

# --- Reading ---

static func _read(source : Object, props : Array[StringName]) -> Dictionary:
	var d := {}
	for p in props:
		var v : Variant = source.get(p)
		if v != null: d[p] = v
	return d

static func _read_material(material : Material, skip : Array[StringName]) -> Dictionary:
	var d := {}
	var mat := material as ShaderMaterial
	if not mat or not mat.shader: return d
	for u in mat.shader.get_shader_uniform_list():
		var uname := StringName(u.name)
		if uname in skip: continue
		var v : Variant = mat.get_shader_parameter(uname)
		if v == null: v = RenderingServer.shader_get_parameter_default(mat.shader.get_rid(), uname)
		if v != null and typeof(v) in MATERIAL_TYPES: d[uname] = v
	return d

func _cascades() -> Array:
	return water.get(&'parameters') if water else []

func _environment() -> Environment:
	return world_environment.environment if world_environment else null

func _surface_lighting() -> Vector3:
	if water and water.has_method(&'get_surface_lighting') and not Engine.is_editor_hint():
		return water.call(&'get_surface_lighting')
	return Vector3(-1.0, -1.0, -1.0)

## The surface sun, ambient and sky energy right now.
func _current_lighting() -> Vector3:
	var env := _environment()
	var live := Vector3(sun.light_energy if sun else 1.0, env.ambient_light_energy if env else 1.0,
			env.background_energy_multiplier if env else 1.0)
	var surface := _surface_lighting()
	for i in 3:
		if surface[i] >= 0.0: live[i] = surface[i]
	return live

# --- Editor ---

func _rescan() -> void:
	if not Engine.is_editor_hint(): return
	var ei := Engine.get_singleton(&'EditorInterface')
	if ei: ei.get_resource_filesystem().scan()

func _mark_scene_unsaved() -> void:
	if not Engine.is_editor_hint(): return
	var ei := Engine.get_singleton(&'EditorInterface')
	if ei: ei.mark_scene_as_unsaved()
