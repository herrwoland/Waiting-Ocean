// Shore zone (see shore_zone.gd): the sea runs into the shallows and up the beach.
// Everything that draws or samples the waves goes through these, and water.gd (shore_sample,
// shore_damp, shore_wave) and underwater_post.glsl mirror them exactly: gameplay, effects and
// the drawn surface must all agree on where the water is.
global uniform sampler2D shore_map : filter_linear, repeat_disable; // r depth, g distance to shore, b zone, a stagger
global uniform vec4 shore_rect; // (corner x, corner z, 1 / size x, 1 / size z); z = 0: no shore zone
global uniform vec4 shore_a;    // (wave height m, wavelength m, phase 0..1, stagger)
global uniform vec4 shore_b;    // (shoal depth m, run-up height m, run-up reach m, damping depth per m of wavelength)

// The shore map at a rest position (before the waves move it): outside the zone, open sea.
vec4 shore_sample(vec2 xz) {
	vec2 uv = (xz - shore_rect.xy) * shore_rect.zw;
	if (shore_rect.z <= 0.0 || uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return vec4(400.0, 2000.0, 0.0, 0.0);
	}
	vec4 s = textureLod(shore_map, uv, 0.0);
	// Towards the map's border the floor fades to open sea, so whatever the depth there, the
	// waves never meet a seam.
	vec2 edge = min(uv, 1.0 - uv) / shore_rect.zw;
	s.x = mix(400.0, s.x, smoothstep(0.0, 30.0, min(edge.x, edge.y)));
	return s;
}

// How much of a wave cascade survives here: waves feel the floor once the water is shallower
// than a fraction of their length, so the long swell dies first and the chop last, gradually,
// and none run on under dry land. Wherever the map knows the floor, outline or not.
float shore_damp(vec4 s, float wavelength) {
	return smoothstep(0.0, shore_b.w * wavelength, s.x);
}

// The shore waves at a rest position: (height, foam).
// Crests run in along the distance to the shoreline, grow and sharpen as the floor rises (their
// shoreward faces steepen), can stand no taller than the water is deep (they break), and when one
// reaches the shoreline the water climbs the sand and drains back.
vec2 shore_wave(vec4 s) {
	if (s.z <= 0.0) return vec2(0.0);
	float depth = s.x;
	float shoal = max(shore_b.x, 0.1);
	float stagger = s.w * shore_a.w;
	float p = fract(s.y / max(shore_a.y, 1.0) + shore_a.z + stagger); // 0 = crest
	float steep = clamp(1.0 - depth / shoal, 0.0, 1.0);
	float g = pow(p, 1.0 + 1.5 * steep); // fronts bunch up: steep shoreward faces
	float c = pow(0.5 + 0.5 * cos(6.2831853 * g), 1.0 + 2.0 * steep); // crests sharpen
	float amp = shore_a.x * pow(shoal / max(depth, 0.25 * shoal), 0.25) // grows as it slows (Green's law)
			* (1.0 - smoothstep(shoal, 3.0 * shoal, depth)); // only in the shallows
	amp = min(amp, 0.39 * max(depth, 0.0)); // breaks: no taller than 0.78 x the depth, crest to trough
	float height = amp * (2.0 * c - 1.0);
	float q = fract(shore_a.z + stagger); // the phase at the shoreline: 0 = a crest arrives
	float rise = q < 0.15 ? smoothstep(0.0, 0.15, q) : 1.0 - smoothstep(0.15, 0.9, q);
	float reach = max(shore_b.z, 1.0);
	float band = smoothstep(-1.3 * reach, -reach, s.y) * (1.0 - smoothstep(0.0, 4.0, s.y));
	height += shore_b.y * rise * band;
	float foam = max(steep * steep * smoothstep(0.55, 1.0, c) * step(0.02, amp),
			band * (1.0 - smoothstep(-2.0, 3.0, s.y)) * rise);
	return vec2(height, foam) * s.z;
}
