// Shore zone (see shore_zone.gd): the sea runs into the shallows and up the beach.
// Everything that draws or samples the waves goes through these, and water.gd (shore_sample,
// shore_damp, shore_wave) and underwater_post.glsl mirror them exactly: gameplay, effects and
// the drawn surface must all agree on where the water is.
global uniform sampler2D shore_map : filter_linear, repeat_disable; // r depth, g distance to shore, b zone, a stagger
global uniform vec4 shore_rect; // (corner x, corner z, 1 / size x, 1 / size z); z = 0: no shore zone
global uniform vec4 shore_a;    // (wave height m, wavelength m, phase 0..1, stagger)
global uniform vec4 shore_b;    // (shoal depth m, run-up height m, run-up reach m, damping depth per m of wavelength)
global uniform vec4 shore_c;    // (wave clock: waves so far, wrapped at 256; run-up variation; swash film m; swash lobes)
global uniform vec4 shore_d;    // wet sand: (drying time in waves, how dark, how glossy, unused)

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

// The swash: how high up the beach (an elevation above sea level, m) the water has climbed at
// this moment. Each wave rushes up as its crest reaches the shoreline, slowing like a thrown ball,
// then drains back, faster and faster. Some waves reach further than others. 0 at the start and
// end of each wave's cycle, so neighbouring stretches of beach on different waves never meet in a
// step. Not past the run-up reach inland, so hollows behind the dunes stay dry.
// Along the beach the front is never a smooth line: it runs up in tongues and scallops, some
// reaching further than others, a different pattern every wave (shore_c.w: how much).
// Returns (height, the tongues' share of it, the tongue pattern itself: -1..1, easing in and out).
vec3 shore_swash_parts(vec4 s, vec2 xz) {
	float clock = shore_c.x + s.w * shore_a.w;
	float q = fract(clock); // 0 = a crest arrives at the shoreline
	float n = floor(clock);
	float h = fract(n * 0.618034);
	h = fract(h * h * 37.1 + h * 7.3); // which wave this is, scrambled: 0..1
	float r = q < 0.35 ? 1.0 - (1.0 - q / 0.35) * (1.0 - q / 0.35)
			: 1.0 - ((q - 0.35) / 0.65) * ((q - 0.35) / 0.65);
	float reach = max(shore_b.z, 1.0);
	float a = 6.2831853 * h;
	// Nothing finer than a few metres: smaller ripples in the level met bumps in the sand ahead of
	// the front as rings of water standing on their own. The foam lace frays the edge finer.
	float lobes = sin(dot(xz, vec2(0.61, 0.79)) * 0.55 + a * 3.0) * 0.6 // tongues, ~11 m apart
			+ sin(dot(xz, vec2(-0.83, 0.56)) * 1.3 + a * 5.0) * 0.4; // scallops, ~5 m
	float fade = smoothstep(-reach, -0.7 * reach, s.y);
	float even = shore_b.y * (1.0 + shore_c.y * (2.0 * h - 1.0)) * r * fade;
	// The pattern's own envelope eases in and out (no kink where a new wave's uprush begins, which
	// drew a crease through the foam there).
	float ease = sin(3.14159265 * q);
	return vec3(even * (1.0 + shore_c.w * lobes), even * shore_c.w * lobes, lobes * ease * ease * fade);
}

float shore_swash(vec4 s, vec2 xz) {
	return shore_swash_parts(s, xz).x;
}

// How high wave n's swash climbs at its peak here (m above sea level): shore_swash_parts' sums
// without the rise and fall.
float shore_swash_peak(vec4 s, vec2 xz, float n) {
	float h = fract(n * 0.618034);
	h = fract(h * h * 37.1 + h * 7.3);
	float a = 6.2831853 * h;
	float lobes = sin(dot(xz, vec2(0.61, 0.79)) * 0.55 + a * 3.0) * 0.6
			+ sin(dot(xz, vec2(-0.83, 0.56)) * 1.3 + a * 5.0) * 0.4;
	float reach = max(shore_b.z, 1.0);
	return shore_b.y * (1.0 + shore_c.y * (2.0 * h - 1.0)) * (1.0 + shore_c.w * lobes)
			* smoothstep(-reach, -0.7 * reach, s.y);
}

// How wet the sand is (0..1): soaked while the swash covers it, then drying from the moment the
// backwash leaves it (shore_d.x waves to dry). The wettest of the last several waves counts, so
// the dark mark is where the highest recent ones reached and holds still, fading, instead of each
// wave redrawing it somewhere else. Measured on the baked sand (still, and the same for every
// view), not the terrain's drawn height, which shifts as its detail changes with distance. Only
// for terrain, so nothing physical depends on it.
float shore_wetness(vec4 s, vec2 xz) {
	if (shore_d.x <= 0.0 || s.y < -max(shore_b.z, 1.0) || shore_b.y <= 0.0) return 0.0;
	float sand_y = -s.x;
	// Under the sea itself it is soaked, fading out with depth: the sea floor further out keeps the
	// look the water gives it.
	if (sand_y < 0.0) return 1.0 - smoothstep(0.5, 2.0, -sand_y);
	if (sand_y < shore_swash(s, xz)) return 1.0; // under the swash right now
	float clock = shore_c.x + s.w * shore_a.w;
	float q = fract(clock);
	float n = floor(clock);
	float wet = 0.0;
	for (int back = 0; back < 6; back++) {
		if (back == 0 && q < 0.35) continue; // this wave is still running up
		float peak = shore_swash_peak(s, xz, n - float(back));
		if (peak > sand_y) {
			// The backwash falls as peak * (1 - t^2), t = 0..1 over the last 0.65 of the wave.
			float left = 0.35 + 0.65 * sqrt(1.0 - sand_y / peak);
			wet = max(wet, exp(-max(q + float(back) - left, 0.0) / shore_d.x));
		}
	}
	return wet;
}

// The shore waves at a rest position: (height, foam).
// Crests run in along the distance to the shoreline, grow and sharpen as the floor rises (their
// shoreward faces steepen), can stand no taller than the water is deep (they break), and when one
// reaches the shoreline the water washes up the sand as a thin sheet and drains back. The sheet
// follows the sand itself, so it runs far up a gentle beach and only a little up a steep one.
// The swash laps at every beach the map knows, not only inside the outline.
vec2 shore_wave(vec4 s, vec2 xz) {
	float depth = s.x;
	float height = 0.0;
	float foam = 0.0;
	float stagger = s.w * shore_a.w;
	if (s.z > 0.0) {
		float shoal = max(shore_b.x, 0.1);
		float p = fract(s.y / max(shore_a.y, 1.0) + shore_a.z + stagger); // 0 = crest
		float steep = clamp(1.0 - depth / shoal, 0.0, 1.0);
		float g = pow(p, 1.0 + 1.5 * steep); // fronts bunch up: steep shoreward faces
		float c = pow(0.5 + 0.5 * cos(6.2831853 * g), 1.0 + 2.0 * steep); // crests sharpen
		float amp = shore_a.x * pow(shoal / max(depth, 0.25 * shoal), 0.25) // grows as it slows (Green's law)
				* (1.0 - smoothstep(shoal, 3.0 * shoal, depth)); // only in the shallows
		amp = min(amp, 0.39 * max(depth, 0.0)); // breaks: no taller than 0.78 x the depth, crest to trough
		height = amp * (2.0 * c - 1.0) * s.z;
		foam = steep * steep * smoothstep(0.55, 1.0, c) * step(0.02, amp) * s.z;
	}
	// The swash: a sheet on the sand below the front, thickest behind it, thinning as it drains.
	float sand = -depth;
	float front = shore_swash(s, xz);
	float q = fract(shore_c.x + stagger);
	float film = shore_c.z * clamp((front - sand) / 0.1, 0.0, 1.0)
			* (1.0 - 0.6 * smoothstep(0.35, 1.0, q));
	// Past the front the surface carries on level at the front's height, under the sand, so the
	// edge drawn is where that level meets the beach: the true contour, between mesh vertices too.
	height = max(height, sand < front ? sand + film : front);
	return vec2(height, foam);
}
