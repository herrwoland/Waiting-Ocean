// Shared by air_bubble.gdshader (the bubble's skin) and air_bubble_through.gdshader (what you see
// through it). See air_bubble.gdshader for why there are two passes.

/** How much of what's behind the bubble its skin hides (0 = clear, 1 = solid). Per bubble. */
instance uniform float opacity : hint_range(0.0, 1.0) = 0.3;
/** Extra opacity at the rim, where you look along the skin. */
instance uniform float rim_opacity : hint_range(0.0, 1.0) = 0.0;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

global uniform vec4 underwater_fog;    // rgb fog colour (lit), a = light loss per meter of depth
global uniform vec4 underwater_absorb; // rgb extinction per meter, a = silhouette range (m)
global uniform vec4 underwater_view;   // x water level, y camera submersion, z/w fog down/up

// UnderwaterGlow nodes, set every frame by water.gd (apply_glows_to(), for meshes in the
// underwater_see_through group). Hidden from the inspector: they're not for setting by hand.
group_uniforms internal;
uniform int glow_count = 0;
uniform vec4 glow_a[16]; // (position, core size)
uniform vec4 glow_b[16]; // (colour * strength, reach)
uniform float glow_strength = 1.0;
group_uniforms;

// Light the glows throw into the water along a ray (origin o, unit dir d, `len` meters).
// Copy of underwater_glow() in underwater_post.glsl, which explains it.
vec3 bubble_glow(vec3 o, vec3 d, float len) {
	vec3 sum = vec3(0.0);
	for (int i = 0; i < glow_count; i++) {
		vec4 a = glow_a[i];
		vec4 b = glow_b[i];
		vec3 to_light = a.xyz - o;
		float t0 = dot(to_light, d);
		float size = max(a.w, 0.01);
		float h = sqrt(max(dot(to_light, to_light) - t0 * t0, 0.0) + size * size);
		float along = (atan((len - t0) / h) + atan(t0 / h)) * size / (h * 3.14159265);
		float murk = 3.0 / max(b.w, 1.0);
		float fade = exp(-murk * (length(to_light) + max(h - size, 0.0)));
		sum += b.rgb * max(along, 0.0) * fade;
	}
	return sum;
}

float bubble_opacity(vec3 normal, vec3 view) {
	float a = opacity;
	if (rim_opacity > 0.0) a = mix(a, 1.0, rim_opacity * pow(1.0 - abs(dot(normal, view)), 3.0));
	return a;
}

// The water between the bubble and what's behind it, which the underwater screen effect leaves
// out (it fogs this pixel by the bubble's distance). `lost`: how much of each colour from behind
// gets through it. `veil`: the fog it lays over that, already divided by what the effect will take
// off it again on the way from the bubble to us. Mirrors through_water() in underwater_post.glsl.
void bubble_water_behind(vec3 vertex, vec2 screen_uv, mat4 inv_view, mat4 inv_proj, out vec3 lost, out vec3 veil) {
	lost = vec3(1.0);
	veil = vec3(0.0);
	float lens = underwater_view.y;
	float wet = smoothstep(0.0, 0.08, lens);
	if (wet <= 0.0) return; // Above the water the screen effect does nothing.

	vec3 dir = normalize((inv_view * vec4(vertex, 0.0)).xyz);
	float d = texture(depth_tex, screen_uv).r;
	float behind = 1e4; // depth 0 = sky
	if (d > 0.0) {
		vec4 v = inv_proj * vec4(screen_uv * 2.0 - 1.0, d, 1.0);
		behind = length(v.xyz / v.w);
	}
	// A ray looking up leaves the water through the surface (taken flat, like the effect).
	float exit_dist = dir.y > 1e-4 ? lens / dir.y : 1e4;
	float here = min(length(vertex), exit_dist);
	behind = clamp(behind, here, exit_dist);

	vec3 absorb = underwater_absorb.rgb;
	float range = max(underwater_absorb.a, 1.0);
	float seen_depth = max(lens - dir.y * min(behind, range), 0.0);
	vec3 fog = underwater_fog.rgb * exp(-underwater_fog.a * seen_depth);
	fog *= mix(underwater_view.z, underwater_view.w, dir.y * 0.5 + 0.5);

	lost = mix(vec3(1.0), exp(-absorb * (behind - here)), wet);
	veil = fog * (exp(-here / range) - exp(-behind / range));
	// The effect adds glow light only out to the bubble; the rest of it is the bubble's to add.
	if (glow_count > 0) {
		vec3 o = inv_view[3].xyz;
		veil += (bubble_glow(o, dir, behind) - bubble_glow(o, dir, here)) * glow_strength;
	}
	// The effect will dim all this by the water between us and the bubble: undo that.
	veil /= max(exp(-absorb * here), vec3(1e-3));
	veil = min(veil * wet, vec3(64.0));
}
