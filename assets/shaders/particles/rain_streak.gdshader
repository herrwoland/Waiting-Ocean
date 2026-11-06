shader_type spatial;
// Rain streaks: thin quads stretched along the fall direction, turned to face the camera around
// that axis. Soft and see-through: blended (not dithered), with a blurred falloff across the
// width, and far streaks never thinner than a pixel or two (thinner ones fade instead of
// sparkling). Lit by scattering like the marine snow: brightest when between the camera and a
// light, so lamps and lightning catch the rain.
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, ambient_light_disabled, specular_disabled;

uniform vec3 color : source_color = vec3(0.62, 0.66, 0.7);
/** How see-through a streak is at its core: lower = fainter, finer rain. */
uniform float opacity : hint_range(0.0, 1.0, 0.01) = 0.45;
/** Softens the streaks: 0 = crisp line, 1 = a wide soft smear (also softens the ends). */
uniform float blur : hint_range(0.0, 1.0, 0.01) = 0.5;
/** Streaks are drawn at least this many pixels wide; thinner ones fade instead (no sparkle). */
uniform float min_pixel_width : hint_range(0.5, 4.0, 0.1) = 1.5;
/** Brightness with no light on it. */
uniform float ambient_glow : hint_range(0.0, 2.0, 0.01) = 0.35;
uniform float light_scatter : hint_range(0.0, 8.0, 0.01) = 1.5;
uniform float forward_scatter : hint_range(0.0, 0.95, 0.01) = 0.7;

varying float pixel_fade;

// The quad is widened by this to make room for the blurred falloff.
float widen() {
	return 1.0 + blur * 3.0;
}

void vertex() {
	// Axis-aligned billboard: keep the streak's length axis, face the camera around it.
	vec3 axis = MODEL_MATRIX[1].xyz;
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 to_cam = normalize(CAMERA_POSITION_WORLD - origin);
	vec3 side = normalize(cross(axis, to_cam)) * length(MODEL_MATRIX[0].xyz);
	// Size of one pixel at this distance; keep the core at least min_pixel_width wide.
	float view_z = max(-(VIEW_MATRIX * vec4(origin, 1.0)).z, 0.01);
	float pixel = 2.0 * view_z / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float core = 2.0 * length(side);
	float wanted = max(core, pixel * min_pixel_width);
	pixel_fade = core / max(wanted, 1e-6);
	side *= (wanted / max(core, 1e-6)) * widen();
	vec3 world = origin + side * VERTEX.x * 2.0 + axis * VERTEX.y;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	MODELVIEW_MATRIX = mat4(1.0);
	MODELVIEW_NORMAL_MATRIX = mat3(1.0);
}

void fragment() {
	float along = UV.y; // 0 = head, 1 = tail: fade the tail.
	// Across the width: a solid core that melts into a soft edge as blur goes up.
	float w = widen();
	float d = abs(UV.x - 0.5) * 2.0; // 0 at the centre line, 1 at the quad edge.
	float core = 1.0 / w;
	float profile = 1.0 - smoothstep(core * mix(0.6, 0.0, blur), mix(core, 1.0, blur), d);
	profile *= profile;
	// Along the length: soft head, fading tail.
	float ends = smoothstep(0.0, 0.05 + 0.25 * blur, along) * mix(1.0, 0.15, along);
	// Spreading the streak wider keeps roughly the same amount of rain on screen.
	float spread = mix(1.0, 1.0 / w, 0.6);
	ALPHA = clamp(opacity * profile * ends * spread * pixel_fade, 0.0, 1.0);
	ALBEDO = color;
	NORMAL = vec3(0.0, 0.0, 1.0);
	EMISSION = color * ambient_glow;
}

float scatter_phase(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5);
}

void light() {
	float phase = min(scatter_phase(dot(LIGHT, -VIEW), forward_scatter), 4.0);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * phase * light_scatter / PI;
}
