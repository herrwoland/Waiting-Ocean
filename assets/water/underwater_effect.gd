@tool
class_name UnderwaterEffect extends CompositorEffect
## Full-screen underwater effect: absorption/in-scattering, light shafts, wobble, blur,
## vignette and a frothing waterline that follows the FFT waves across the lens. Runs after the transparent pass so
## the water surface (Snell's window) is included. Configured and fed by water.gd.

const SHADER_PATH := 'res://assets/shaders/compute/underwater_post.glsl'
const COPY_SHADER_PATH := 'res://assets/shaders/compute/image_copy.glsl'
const CAUSTICS_SHADER_PATH := 'res://assets/shaders/compute/caustics.glsl'
const PARAMS_SIZE := 2448 # 2 mat4 + 4 vec4 map scales + 10 vec4 + 2x16 vec4 water shapes + 4 vec4 shadow + fog gradient + 3x8 vec4 blockers + glow info + 2x16 vec4 glows + beam info + 3x8 vec4 beams + beam info 2 + 7 vec4 sonar pulse + 4 vec4 shore zone, std140.
const MAX_WATER_SHAPES := 16
const MAX_GLOWS := 16
const MAX_BEAMS := 8
const FOCUS_MAP_SIZE := 256
const WATER_IOR := 1.333

# ----- Set every frame by water.gd ----- #
var displacement_map := RID()
var normal_map := RID()
var map_scales := PackedVector4Array()
var water_level := 0.0
var fog_color := Color(0.04, 0.13, 0.14)
var absorption := Vector3(0.22, 0.06, 0.05)
var depth_darkening := 0.04
var distortion := 0.0025
var blur := 1.5
var waterline_width := 2.5
var waterline_foam := 0.8
var waterline_churn := 0.0 # 0..1, spikes as the camera crosses the surface
var crossing_foam := 0.0 # 0..1, a burst thrown up as the head breaks the surface
var lens_submersion := 0.0 # how far the camera itself is below the surface (m)
var lens_dry := false # camera inside a DryVolume (eg. a hull): no underwater effect at all
var blocker_count := 0 # Wave blockers (ShoreCalm and the like), so the waterline matches the surface.
var blocker_a := PackedVector4Array()
var blocker_b := PackedVector4Array()
var blocker_c := PackedVector4Array()
# Shore zone (see shore.gdshaderinc), so the waterline follows the shore waves too.
var shore_texture := RID() # RenderingDevice texture of the baked shore map, or none.
var shore_rect := Vector4.ZERO
var shore_a := Vector4.ZERO
var shore_b := Vector4.ZERO
var shore_c := Vector4.ZERO
var vignette := 0.35
var silhouette_range := 45.0
var fog_down := 0.35
var fog_up := 1.6
var sun_direction := Vector3.ZERO # Towards the sun. Zero = no shafts.
var sun_color := Color.WHITE      # Already multiplied by energy.
var shaft_strength := 0.2
var shaft_focus_depth := 8.0
var shaft_max_distance := 40.0
var shaft_steps := 24
var shaft_scattering := 0.6
var shaft_tint := Color.WHITE
var shaft_max_brightness := 1.0
var shaft_contrast := 1.0
var shaft_threshold := 1.0
var shaft_softness := 3.0
var shaft_scale := 1.0
var shape_count := 0 # Water shapes from WaterDeformer nodes (see water.gdshader).
var shape_a := PackedVector4Array()
var shape_b := PackedVector4Array()
var shadow_texture := RID() # From WaterShadowCapture; invalid = no water shadows.
var shadow_transform := Transform3D() # Shadow camera: origin, basis x = right, y = up, z = towards sun.
var shadow_half_size := 64.0
var shadow_softness := 1.0
var shadow_bias := 0.3
var glow_count := 0 # UnderwaterGlow nodes: (pos, core size), (colour * strength, reach).
var glow_a := PackedVector4Array()
var glow_b := PackedVector4Array()
var glow_strength := 1.0
var beam_count := 0 # Lamps shining into the water: (pos, range), (dir, cos edge), (colour * energy, cos full).
var beam_a := PackedVector4Array()
var beam_b := PackedVector4Array()
var beam_c := PackedVector4Array()
var beam_strength := 1.0
var beam_steps := 24 # Ray march steps per lamp.
var beam_scattering := 0.25
var beam_shafts := 0.7

# ----- Set by SonarPulse while a pulse is showing ----- #
var pulse_visibility := 0.0 # 0 = no pulse
var pulse_origin := Vector3.ZERO
var pulse_front := 0.0 # how far the front has travelled (m)
var pulse_range := 35.0
var pulse_grain := 0.7
var pulse_streaks := 0.6
var pulse_echo_color := Color(1.3, 1.25, 1.05)
var pulse_rings := 0.0
var pulse_background := Color(0.015, 0.02, 0.045)
var pulse_facing := 1.5
var pulse_front_glow := 1.0
var pulse_seed := 0.0
var pulse_dissolve := 0.8
var pulse_opacity := 1.0
var pulse_age := 0.0 # seconds since it was sent
var pulse_speed := 140.0
var pulse_afterglow := 0.35
var pulse_flare := 1.5
var pulse_far_brightness := 0.4 # echo at the edge of the range, compared to close by
var pulse_surface := 0.15 # echo of the sea surface (the underside of the waves)

var _rd : RenderingDevice
var _shader : RID
var _pipeline : RID
var _copy_shader : RID
var _copy_pipeline : RID
var _caustics_shader : RID
var _caustics_pipeline : RID
var _shafts_shader : RID
var _shafts_pipeline : RID
var _shaft_tex : RID
var _shaft_size := Vector2i.ZERO
var _focus_tex : RID
var _linear_sampler : RID
var _repeat_sampler : RID
var _params_buffer : RID
var _dummy_shadow_tex : RID
var _temp_tex : RID
var _temp_size := Vector2i.ZERO
var _temp_format := -1

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_init_compute)

func _notification(what : int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		for rid in [_dummy_shadow_tex, _temp_tex, _shaft_tex, _focus_tex, _params_buffer, _repeat_sampler, _linear_sampler, _shafts_shader, _caustics_shader, _copy_shader, _shader]:
			if rid.is_valid(): _rd.free_rid(rid) # Freeing the shader also frees the pipeline.

func _init_compute() -> void:
	_rd = RenderingServer.get_rendering_device()
	if not _rd: return
	_copy_shader = _rd.shader_create_from_spirv(load(COPY_SHADER_PATH).get_spirv())
	_caustics_shader = _rd.shader_create_from_spirv(load(CAUSTICS_SHADER_PATH).get_spirv())
	var post_file : RDShaderFile = load(SHADER_PATH)
	_shader = _rd.shader_create_from_spirv(post_file.get_spirv(&'composite'))
	_shafts_shader = _rd.shader_create_from_spirv(post_file.get_spirv(&'shafts'))
	if not _shader.is_valid() or not _shafts_shader.is_valid() or not _copy_shader.is_valid() or not _caustics_shader.is_valid(): return
	_shafts_pipeline = _rd.compute_pipeline_create(_shafts_shader)
	_copy_pipeline = _rd.compute_pipeline_create(_copy_shader)
	_caustics_pipeline = _rd.compute_pipeline_create(_caustics_shader)
	_pipeline = _rd.compute_pipeline_create(_shader)

	var sampler := RDSamplerState.new()
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_linear_sampler = _rd.sampler_create(sampler)
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_repeat_sampler = _rd.sampler_create(sampler)
	_params_buffer = _rd.uniform_buffer_create(PARAMS_SIZE)

	# Bound in place of the water shadow map while there is none.
	var dummy_fmt := RDTextureFormat.new()
	dummy_fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	dummy_fmt.width = 4
	dummy_fmt.height = 4
	dummy_fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_dummy_shadow_tex = _rd.texture_create(dummy_fmt, RDTextureView.new())

	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	fmt.width = FOCUS_MAP_SIZE
	fmt.height = FOCUS_MAP_SIZE
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_focus_tex = _rd.texture_create(fmt, RDTextureView.new())

func _render_callback(_callback_type : int, render_data : RenderData) -> void:
	if not _pipeline.is_valid() or not displacement_map.is_valid() or not _rd.texture_is_valid(displacement_map):
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data() as RenderSceneDataRD
	if not buffers or not scene_data: return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0: return

	_update_focus_map()
	var shaft_size := Vector2i(maxi(size.x / 2, 1), maxi(size.y / 2, 1))
	var push := PackedFloat32Array([size.x, size.y, shaft_size.x, shaft_size.y]).to_byte_array()
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view)
		var depth := buffers.get_depth_layer(view)
		_ensure_temp_texture(color, size)
		_ensure_shaft_texture(shaft_size)
		_update_params(scene_data, view)
		var groups := Vector3i(ceili(size.x / 8.0), ceili(size.y / 8.0), 1)

		var copy_set := UniformSetCacheRD.get_cache(_copy_shader, 0, [
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color]),
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [_temp_tex]),
		])
		var copy_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(copy_list, _copy_pipeline)
		_rd.compute_list_bind_uniform_set(copy_list, copy_set, 0)
		_rd.compute_list_dispatch(copy_list, groups.x, groups.y, 1)
		_rd.compute_list_end()

		# Light shafts at half resolution.
		var shafts_set := UniformSetCacheRD.get_cache(_shafts_shader, 0, [
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [_shaft_tex]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_linear_sampler, depth]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_repeat_sampler, displacement_map]),
			_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 4, [_params_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 5, [_repeat_sampler, _focus_tex]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 7, [_linear_sampler, _shadow_tex()]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 8, [_linear_sampler, _shore_tex()]),
		])
		var shafts_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(shafts_list, _shafts_pipeline)
		_rd.compute_list_bind_uniform_set(shafts_list, shafts_set, 0)
		_rd.compute_list_set_push_constant(shafts_list, push, push.size())
		_rd.compute_list_dispatch(shafts_list, ceili(shaft_size.x / 8.0), ceili(shaft_size.y / 8.0), 1)
		_rd.compute_list_end()

		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_linear_sampler, depth]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_linear_sampler, _temp_tex]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_repeat_sampler, displacement_map]),
			_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 4, [_params_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 6, [_linear_sampler, _shaft_tex]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 8, [_linear_sampler, _shore_tex()]),
		])
		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		_rd.compute_list_set_push_constant(compute_list, push, push.size())
		_rd.compute_list_dispatch(compute_list, groups.x, groups.y, 1)
		_rd.compute_list_end()

## Recomputes where the largest wave cascade focuses sunlight (drives the light shafts).
func _update_focus_map() -> void:
	if map_scales.is_empty() or not normal_map.is_valid() or not _rd.texture_is_valid(normal_map): return
	var scales := map_scales[0]
	var tile_meters := 1.0 / maxf(scales.x, 1e-6)
	var bend := 1.0 - 1.0 / WATER_IOR # Sideways bend of a refracted beam per unit of slope.
	# Cascade 0 (largest waves), differenced over several texels so only big swells make shafts.
	var push := PackedFloat32Array([tile_meters / FOCUS_MAP_SIZE, scales.w, shaft_focus_depth * bend, FOCUS_MAP_SIZE, 0.0, shaft_softness, 0.0, 0.0]).to_byte_array()
	var uniform_set := UniformSetCacheRD.get_cache(_caustics_shader, 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [_focus_tex]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_repeat_sampler, normal_map]),
	])
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _caustics_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	_rd.compute_list_set_push_constant(compute_list, push, push.size())
	_rd.compute_list_dispatch(compute_list, FOCUS_MAP_SIZE / 8, FOCUS_MAP_SIZE / 8, 1)
	_rd.compute_list_end()

func _ensure_shaft_texture(size : Vector2i) -> void:
	if _shaft_tex.is_valid() and _shaft_size == size: return
	if _shaft_tex.is_valid(): _rd.free_rid(_shaft_tex)
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = size.x
	fmt.height = size.y
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_shaft_tex = _rd.texture_create(fmt, RDTextureView.new())
	_shaft_size = size

func _ensure_temp_texture(color : RID, size : Vector2i) -> void:
	var color_format := _rd.texture_get_format(color)
	if _temp_tex.is_valid() and _temp_size == size and _temp_format == color_format.format: return
	if _temp_tex.is_valid(): _rd.free_rid(_temp_tex)
	var fmt := RDTextureFormat.new()
	fmt.format = color_format.format
	fmt.width = size.x
	fmt.height = size.y
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_temp_tex = _rd.texture_create(fmt, RDTextureView.new())
	_temp_size = size
	_temp_format = color_format.format

func _update_params(scene_data : RenderSceneDataRD, view : int) -> void:
	var data := PackedFloat32Array()
	var inv_proj := scene_data.get_view_projection(view).inverse()
	for column in [inv_proj.x, inv_proj.y, inv_proj.z, inv_proj.w]:
		data.append_array([column.x, column.y, column.z, column.w])
	var cam := scene_data.get_cam_transform()
	data.append_array([cam.basis.x.x, cam.basis.x.y, cam.basis.x.z, 0.0])
	data.append_array([cam.basis.y.x, cam.basis.y.y, cam.basis.y.z, 0.0])
	data.append_array([cam.basis.z.x, cam.basis.z.y, cam.basis.z.z, 0.0])
	data.append_array([cam.origin.x, cam.origin.y, cam.origin.z, 1.0])
	var cascades := mini(map_scales.size(), 4)
	for i in 4:
		var s := map_scales[i] if i < cascades else Vector4.ZERO
		data.append_array([s.x, s.y, s.z, s.w])
	data.append_array([fog_color.r, fog_color.g, fog_color.b, depth_darkening])
	data.append_array([absorption.x, absorption.y, absorption.z, float(cascades)])
	data.append_array([Time.get_ticks_msec() / 1000.0, distortion, blur, waterline_width])
	data.append_array([vignette, water_level, silhouette_range, waterline_foam])
	var sun := sun_direction.normalized()
	data.append_array([sun.x, sun.y, sun.z, shaft_strength if sun != Vector3.ZERO else 0.0])
	data.append_array([sun_color.r, sun_color.g, sun_color.b, shaft_max_distance])
	var uv_scale := map_scales[0].x if not map_scales.is_empty() else 0.0
	data.append_array([uv_scale * shaft_scale, float(shaft_steps), shaft_scattering, shaft_contrast])
	data.append_array([shaft_tint.r, shaft_tint.g, shaft_tint.b, shaft_max_brightness])
	data.append_array([shaft_threshold, waterline_churn, float(blocker_count), lens_submersion])
	data.append_array([float(shape_count), crossing_foam, 1.0 if lens_dry else 0.0, 0.0])
	for shapes in [shape_a, shape_b]:
		for i in MAX_WATER_SHAPES:
			var v : Vector4 = shapes[i] if i < shapes.size() else Vector4.ZERO
			data.append_array([v.x, v.y, v.z, v.w])
	var shadows_on := 1.0 if shadow_texture.is_valid() and _rd.texture_is_valid(shadow_texture) else 0.0
	var sb := shadow_transform.basis
	data.append_array([shadow_transform.origin.x, shadow_transform.origin.y, shadow_transform.origin.z, shadows_on])
	data.append_array([sb.x.x, sb.x.y, sb.x.z, shadow_half_size])
	data.append_array([sb.y.x, sb.y.y, sb.y.z, shadow_softness])
	data.append_array([-sb.z.x, -sb.z.y, -sb.z.z, shadow_bias])
	data.append_array([fog_down, fog_up, 0.0, 0.0])
	for blockers in [blocker_a, blocker_b, blocker_c]:
		for i in 8:
			var v : Vector4 = blockers[i] if i < blockers.size() else Vector4.ZERO
			data.append_array([v.x, v.y, v.z, v.w])
	data.append_array([float(mini(glow_count, MAX_GLOWS)), glow_strength, 0.0, 0.0])
	for glows in [glow_a, glow_b]:
		for i in MAX_GLOWS:
			var v : Vector4 = glows[i] if i < glows.size() else Vector4.ZERO
			data.append_array([v.x, v.y, v.z, v.w])
	data.append_array([float(mini(beam_count, MAX_BEAMS)), beam_strength, float(beam_steps), beam_scattering])
	for beams in [beam_a, beam_b, beam_c]:
		for i in MAX_BEAMS:
			var v : Vector4 = beams[i] if i < beams.size() else Vector4.ZERO
			data.append_array([v.x, v.y, v.z, v.w])
	data.append_array([beam_shafts, 0.0, 0.0, 0.0])
	data.append_array([pulse_origin.x, pulse_origin.y, pulse_origin.z, pulse_front])
	data.append_array([pulse_visibility, pulse_range, pulse_grain, pulse_streaks])
	data.append_array([pulse_echo_color.r, pulse_echo_color.g, pulse_echo_color.b, pulse_rings])
	data.append_array([pulse_background.r, pulse_background.g, pulse_background.b, pulse_facing])
	data.append_array([pulse_front_glow, pulse_seed, pulse_dissolve, pulse_opacity])
	data.append_array([pulse_age, pulse_speed, pulse_afterglow, pulse_flare])
	data.append_array([pulse_far_brightness, pulse_surface, 0.0, 0.0])
	var has_shore := shore_texture.is_valid() and _rd.texture_is_valid(shore_texture)
	for v in [shore_rect if has_shore else Vector4.ZERO, shore_a, shore_b, shore_c]:
		data.append_array([v.x, v.y, v.z, v.w])
	var bytes := data.to_byte_array()
	_rd.buffer_update(_params_buffer, 0, bytes.size(), bytes)

func _shore_tex() -> RID:
	return shore_texture if shore_texture.is_valid() and _rd.texture_is_valid(shore_texture) else _dummy_shadow_tex

func _shadow_tex() -> RID:
	return shadow_texture if shadow_texture.is_valid() and _rd.texture_is_valid(shadow_texture) else _dummy_shadow_tex

static func _uniform(type : RenderingDevice.UniformType, binding : int, ids : Array) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids: u.add_id(id)
	return u
