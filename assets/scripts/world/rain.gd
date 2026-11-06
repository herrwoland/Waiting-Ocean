@tool
class_name Rain extends Node3D
## The storm's rain, all driven by one `intensity` (0..1) so days and story beats can make it
## worse: falling streaks around the camera that end on the real waves (and on decks/land via a
## heightfield), splashes, ripples and a matte beaten-down sea (water material "rain" group),
## drops on the lens (toggle) and a rain hiss. Stops drawing while the camera is underwater.
## Finds the water node by itself (group "water"); follows whatever camera is current.

const DROPS_SHADER := preload('res://assets/shaders/particles/rain_drops.gdshader')
const STREAK_SHADER := preload('res://assets/shaders/particles/rain_streak.gdshader')
const SPLASH_SHADER := preload('res://assets/shaders/particles/rain_splash.gdshader')
const SPLASH_DRAW_SHADER := preload('res://assets/shaders/particles/rain_splash_draw.gdshader')
const LENS_SHADER := preload('res://assets/shaders/post/rain_lens.gdshader')
const WATER_LAYER_BIT := 1 << 19 # Water surface/spray layer (see water.gd).

## How hard it rains. Everything scales with this.
@export_range(0.0, 1.0, 0.01) var intensity := 0.7
## Direction the wind blows towards (degrees, 0 = +X, 90 = +Z).
@export_range(-180.0, 180.0, 1.0) var wind_direction := 30.0
## Wind speed (m/s): slants the rain.
@export_range(0.0, 30.0, 0.1) var wind_strength := 6.0
## How much the wind gusts (0 = steady).
@export_range(0.0, 1.0, 0.01) var gustiness := 0.4

@export_group('Drops')
## Drops at full intensity.
@export_range(100, 60000, 100) var max_drops := 16000 :
	set(value):
		max_drops = value
		if _drops: _drops.amount = value
## Rain falls in a disc this wide around the camera (m).
@export_range(5.0, 150.0, 1.0) var area_radius := 40.0
@export_range(1.0, 40.0, 0.1) var fall_speed := 13.0
@export_range(0.05, 4.0, 0.01) var streak_length := 0.9
@export_range(0.002, 0.1, 0.001) var streak_width := 0.012
@export var streak_color := Color(0.62, 0.66, 0.7)
## How see-through each streak is: lower = finer, fainter rain.
@export_range(0.0, 1.0, 0.01) var streak_opacity := 0.45
## Softens the streaks: 0 = crisp lines, 1 = soft smears (like motion blur in the eye).
@export_range(0.0, 1.0, 0.01) var streak_blur := 0.5
## Far streaks are drawn at least this many pixels wide and fade instead, so they don't sparkle.
@export_range(0.5, 4.0, 0.1) var streak_min_pixels := 1.5

@export_group('Splashes')
@export var splashes_enabled := true
## Only drops this close to the camera splash (m).
@export_range(1.0, 60.0, 0.5) var splash_radius := 22.0
## Share of drops that splash.
@export_range(0.0, 1.0, 0.01) var splash_chance := 0.5
## Droplets thrown up by each splash (more = fuller crowns, more particles).
@export_range(0, 12) var splash_droplets := 5
@export_range(0.005, 0.3, 0.001) var splash_droplet_size := 0.05
## Radius the ring on the water spreads to (m).
@export_range(0.05, 2.0, 0.01) var splash_ring_size := 0.35
## How high droplets are thrown (m/s).
@export_range(0.1, 8.0, 0.05) var splash_speed := 2.2
## Seconds a splash lasts.
@export_range(0.1, 2.0, 0.01) var splash_lifetime := 0.45 :
	set(value):
		splash_lifetime = value
		if _splashes: _splashes.lifetime = value
## Particle budget for splashes. Raise if splashes pop in and out in heavy rain.
@export_range(500, 60000, 500) var max_splash_particles := 14000 :
	set(value):
		max_splash_particles = value
		if _splashes: _splashes.amount = value
@export var splash_color := Color(0.85, 0.9, 0.9)
## Stop rain on decks, rooftops and land too (heightfield of the scene around the camera).
@export var collide_with_geometry := true

@export_group('Lens')
## Rain drops on the camera lens (only above water).
@export var lens_drops_enabled := true
## Drop count on the lens at full intensity (0..1).
@export_range(0.0, 1.0, 0.01) var lens_amount := 0.7
@export_range(0.0, 0.1, 0.001) var lens_refraction := 0.035
@export_range(0.005, 0.1, 0.001) var lens_drop_size := 0.03
## Seconds the whole-lens wet film lasts after surfacing.
@export_range(0.0, 10.0, 0.1) var lens_surface_film_time := 2.5

@export_group('Sound')
@export var sound_enabled := true
@export_range(-60.0, 12.0, 0.5) var sound_volume_db := -6.0

var _water : Node
var _drops : GPUParticles3D
var _splashes : GPUParticles3D
var _collider : GPUParticlesCollisionHeightField3D
var _lens_layer : CanvasLayer
var _lens_rect : ColorRect
var _sound : AudioStreamPlayer
var _was_underwater := false
var _film := 0.0
var _gust_time := 0.0

func _ready() -> void:
	add_to_group(&'rain')
	_build()

var _quality_base := {}

## Effects quality preset from the settings menu: 0 = low, 1 = medium, 2 = high (the values set
## in the scene). Lower levels scale down from the scene's own values, never overwrite them.
func set_effects_quality(level : int) -> void:
	if _quality_base.is_empty():
		_quality_base = {max_drops = max_drops, splash_droplets = splash_droplets, splash_radius = splash_radius}
	var scale : float = [0.35, 0.65, 1.0][clampi(level, 0, 2)]
	max_drops = maxi(int(_quality_base.max_drops * scale), 100)
	splash_droplets = clampi(int(round(_quality_base.splash_droplets * scale)), 1, 12)
	splash_radius = _quality_base.splash_radius * lerpf(0.6, 1.0, scale)

func _build() -> void:
	# Falling drops.
	_drops = GPUParticles3D.new()
	_drops.name = 'Drops'
	_drops.amount = max_drops
	_drops.lifetime = 3.0 # ~ the fall from the top of the column (column_height / fall_speed).
	_drops.preprocess = 3.0
	_drops.local_coords = false
	_drops.fixed_fps = 0
	_drops.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_drops.layers = WATER_LAYER_BIT # The water sun-shadow camera skips it.
	_drops.collision_base_size = 0.05
	var pm := ShaderMaterial.new()
	pm.shader = DROPS_SHADER
	_drops.process_material = pm
	var streak_mat := ShaderMaterial.new()
	streak_mat.shader = STREAK_SHADER
	streak_mat.render_priority = 1 # Blended: draw after the water (priority 0), never behind it.
	var quad := QuadMesh.new()
	quad.material = streak_mat
	_drops.draw_pass_1 = quad
	add_child(_drops, false, Node.INTERNAL_MODE_BACK)

	# Splashes: a ring on the water and a crown of droplets where a drop lands.
	_splashes = GPUParticles3D.new()
	_splashes.name = 'Splashes'
	_splashes.amount = max_splash_particles
	_splashes.lifetime = splash_lifetime
	_splashes.emitting = false # Fed by the drops' emit_subparticle().
	_splashes.local_coords = false
	_splashes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_splashes.layers = WATER_LAYER_BIT
	var spm := ShaderMaterial.new()
	spm.shader = SPLASH_SHADER
	_splashes.process_material = spm
	var splash_mat := ShaderMaterial.new()
	splash_mat.shader = SPLASH_DRAW_SHADER
	var splash_quad := QuadMesh.new()
	splash_quad.material = splash_mat
	_splashes.draw_pass_1 = splash_quad
	add_child(_splashes, false, Node.INTERNAL_MODE_BACK)
	_drops.sub_emitter = _drops.get_path_to(_splashes)

	# Solid geometry (decks, land) around the camera; the water itself is handled in the shader.
	_collider = GPUParticlesCollisionHeightField3D.new()
	_collider.name = 'Collider'
	_collider.size = Vector3(area_radius * 2.0, 60.0, area_radius * 2.0)
	_collider.resolution = GPUParticlesCollisionHeightField3D.RESOLUTION_256
	_collider.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_ALWAYS
	_collider.follow_camera_enabled = true
	_collider.heightfield_mask = 0xFFFFF & ~WATER_LAYER_BIT
	add_child(_collider, false, Node.INTERNAL_MODE_BACK)

	# Lens drops, drawn just before the PS1 post-process (layer -1 in main.tscn).
	_lens_layer = CanvasLayer.new()
	_lens_layer.name = 'LensDrops'
	_lens_layer.layer = -2
	_lens_rect = ColorRect.new()
	_lens_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lens_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lens_mat := ShaderMaterial.new()
	lens_mat.shader = LENS_SHADER
	_lens_rect.material = lens_mat
	_lens_layer.add_child(_lens_rect)
	add_child(_lens_layer, false, Node.INTERNAL_MODE_BACK)

	_sound = AudioStreamPlayer.new()
	_sound.name = 'Hiss'
	_sound.stream = _make_hiss_stream()
	add_child(_sound, false, Node.INTERNAL_MODE_BACK)

func _process(delta : float) -> void:
	if not is_instance_valid(_water):
		_water = get_tree().get_first_node_in_group(&'water')
	var cam := _current_camera()
	if not cam or not _drops: return
	var cam_pos := cam.global_position
	var water_level : float = _water.global_position.y if _water else 0.0
	var surface : float = _water.get_wave_height(cam_pos, false) if _water else water_level
	var underwater := cam_pos.y < surface

	# Wind with slow gusts.
	_gust_time += delta
	var gust := 1.0 + gustiness * (0.6 * sin(_gust_time * 0.7) + 0.4 * sin(_gust_time * 1.9 + 1.3))
	var wind := Vector2(cos(deg_to_rad(wind_direction)), sin(deg_to_rad(wind_direction))) * wind_strength * gust

	global_position = cam_pos
	_drops.visible = not underwater
	_splashes.visible = not underwater
	_drops.amount_ratio = intensity
	_drops.emitting = intensity > 0.001 # amount_ratio = 0 alone doesn't stop emission.
	_drops.visibility_aabb = AABB(Vector3(-area_radius, -80, -area_radius), Vector3(area_radius * 2.0, 160, area_radius * 2.0))
	_splashes.visibility_aabb = _drops.visibility_aabb
	_drops.collision_base_size = 0.05 if collide_with_geometry else 0.0
	_collider.visible = collide_with_geometry
	_collider.size = Vector3(area_radius * 2.0, 60.0, area_radius * 2.0)

	var pm := _drops.process_material as ShaderMaterial
	pm.set_shader_parameter(&'center', cam_pos)
	pm.set_shader_parameter(&'radius', area_radius)
	pm.set_shader_parameter(&'water_level', water_level)
	pm.set_shader_parameter(&'wind', wind)
	pm.set_shader_parameter(&'fall_speed', fall_speed)
	pm.set_shader_parameter(&'streak_length', streak_length)
	pm.set_shader_parameter(&'streak_width', streak_width)
	pm.set_shader_parameter(&'splash_radius', splash_radius)
	pm.set_shader_parameter(&'splash_chance', splash_chance if splashes_enabled else 0.0)
	pm.set_shader_parameter(&'splash_droplets', splash_droplets)
	pm.set_shader_parameter(&'splash_speed', splash_speed)
	var spm := _splashes.process_material as ShaderMaterial
	spm.set_shader_parameter(&'droplet_size', splash_droplet_size)
	spm.set_shader_parameter(&'ring_size', splash_ring_size)
	spm.set_shader_parameter(&'water_level', water_level)
	if _water and _water.get(&'map_scales'):
		var scales : PackedVector4Array = _water.map_scales
		var four := PackedVector4Array()
		four.resize(4)
		for i in mini(scales.size(), 4): four[i] = scales[i]
		pm.set_shader_parameter(&'map_scales', four)
		spm.set_shader_parameter(&'map_scales', four)
	var streak_mat := (_drops.draw_pass_1 as QuadMesh).material as ShaderMaterial
	streak_mat.set_shader_parameter(&'color', streak_color)
	streak_mat.set_shader_parameter(&'opacity', streak_opacity)
	streak_mat.set_shader_parameter(&'blur', streak_blur)
	streak_mat.set_shader_parameter(&'min_pixel_width', streak_min_pixels)
	var splash_mat := (_splashes.draw_pass_1 as QuadMesh).material as ShaderMaterial
	splash_mat.set_shader_parameter(&'color', splash_color)

	# The sea: ripples and a matte surface.
	if _water and _water.material_override is ShaderMaterial:
		_water.material_override.set_shader_parameter(&'rain_intensity', intensity)

	# Lens: drops above water; a wet film for a moment after surfacing.
	if _was_underwater and not underwater:
		_film = 1.0
	_was_underwater = underwater
	_film = maxf(_film - delta / maxf(lens_surface_film_time, 0.01), 0.0)
	var lens_on := lens_drops_enabled and not underwater and not Engine.is_editor_hint()
	_lens_layer.visible = lens_on and (intensity > 0.0 or _film > 0.0)
	var lens_mat := _lens_rect.material as ShaderMaterial
	lens_mat.set_shader_parameter(&'amount', intensity * lens_amount)
	lens_mat.set_shader_parameter(&'film', _film if lens_drops_enabled else 0.0)
	lens_mat.set_shader_parameter(&'refraction', lens_refraction)
	lens_mat.set_shader_parameter(&'drop_size', lens_drop_size)

	# Sound (the master bus low-pass already muffles it underwater).
	var want_sound := sound_enabled and intensity > 0.0 and not Engine.is_editor_hint()
	if want_sound and not _sound.playing: _sound.play()
	elif not want_sound and _sound.playing: _sound.stop()
	_sound.volume_db = sound_volume_db + linear_to_db(maxf(intensity, 0.001)) * 0.8

func _current_camera() -> Camera3D:
	var cam := get_viewport().get_camera_3d()
	if Engine.is_editor_hint() and Engine.has_singleton(&'EditorInterface'):
		var editor_vp = Engine.get_singleton(&'EditorInterface').get_editor_viewport_3d(0)
		if editor_vp: cam = editor_vp.get_camera_3d()
	return cam

## A looping rain hiss generated in code (placeholder until a real recording): filtered noise
## with the odd louder drop.
static func _make_hiss_stream() -> AudioStreamWAV:
	var rate := 22050
	var length := rate * 3
	var data := PackedByteArray()
	data.resize(length * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var low := 0.0
	var high := 0.0
	var prev := 0.0
	for i in length:
		var n := rng.randf_range(-1.0, 1.0)
		low += (n - low) * 0.18   # Soft, wide hiss.
		high = n - prev           # Fine patter.
		prev = n
		var s := low * 0.55 + high * 0.08
		if rng.randf() < 0.0015: s += rng.randf_range(-0.5, 0.5) # A louder drop now and then.
		# Dip the level at the loop seam so the jump back to the start doesn't click.
		var edge := minf(float(i), float(length - i)) / float(rate / 10)
		s *= clampf(edge, 0.0, 1.0) * 0.5 + 0.5
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 20000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = length
	return wav
