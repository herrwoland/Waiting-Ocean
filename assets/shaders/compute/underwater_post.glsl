#[versions]

shafts = "#define MODE_SHAFTS";
composite = "";

#[compute]

#version 450

#VERSION_DEFINES
// Underwater screen effect (runs after transparents, see underwater_effect.gd).
// Per pixel: how far does this ray travel through water before it leaves through the surface
// or hits something? That length carries the absorption, in-scattering, shafts, wobble, blur
// and vignette. Asking instead where the ray STARTS paints the sky with water colour whenever
// the lens is near the surface, because the near plane is a few centimeters tall. The waterline where a wave
// crosses the lens is torn up with froth and bubbles.
// Two versions: `shafts` ray marches light shafts at half resolution (noisy, cheap), and
// `composite` blurs them away while applying everything else at full resolution.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#ifdef MODE_SHAFTS
layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D shaft_image;
#else
layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D color_image;
layout(set = 0, binding = 2) uniform sampler2D source_tex; // Copy of the color buffer.
layout(set = 0, binding = 6) uniform sampler2D shaft_tex;  // Output of the shafts pass.
#endif
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 3) uniform sampler2DArray displacements;
layout(set = 0, binding = 4, std140) uniform Params {
	mat4 inv_projection;
	mat4 cam_to_world;
	vec4 map_scales[4];   // xy uv scale, z displacement scale
	vec4 fog_color;       // rgb in-scattered colour, a = light loss per meter of depth
	vec4 absorption;      // rgb extinction per meter, a = number of cascades
	vec4 effect;          // x time, y distortion, z blur (px), w waterline width (px)
	vec4 effect2;         // x vignette, y water level (world y), z silhouette range (m), w waterline foam
	vec4 sun_dir;         // xyz direction towards the sun (world), w = shaft strength
	vec4 sun_color;       // rgb light colour * energy, w = max shaft march distance (m)
	vec4 shafts;          // x focus map uv scale, y march steps, z forward scattering g, w contrast
	vec4 shaft_tint;      // rgb tint, a = max brightness
	vec4 shafts2;         // x threshold, y waterline churn, z wave blocker count, w lens submersion (m)
	vec4 shape_count;     // x = number of water shapes, y = waterline foam burst (0..1), z = 1 if the lens is in a DryVolume
	vec4 shape_a[16];
	vec4 shape_b[16];
	vec4 shadow_origin;   // Sun shadow map, see water_shadow.glsli.
	vec4 shadow_right;
	vec4 shadow_up;
	vec4 shadow_fwd;
	vec4 fog_gradient;    // x brightness looking straight down, y looking straight up
	vec4 blocker_a[8];    // Wave blockers, see wave_blocker.gd: (pos.x, pos.z, frame cos, frame sin)
	vec4 blocker_b[8];    // (half x / radius, half z / capsule half length, fade width, flags)
	vec4 blocker_c[8];    // calm plane: (height at the centre, dh/dx, dh/dz, unused)
	vec4 glow_info;       // x = number of UnderwaterGlow nodes, y = overall strength
	vec4 glow_a[16];      // (position, core size)
	vec4 glow_b[16];      // (colour * strength, reach)
	vec4 beam_info;       // x = number of light beams, y = overall strength, z = march steps per lamp, w = forward scattering g
	vec4 beam_a[8];       // Lamps shining into the water: (position, range)
	vec4 beam_b[8];       // (direction it shines, cos of the cone edge; omni: -2)
	vec4 beam_c[8];       // (colour * energy, cos where the cone reaches full brightness; omni: -1)
	vec4 beam_info2;      // x = shafts (0 smooth cone .. 1 fully broken into streaks by the waves)
	vec4 pulse_a;         // Sonar pulse, see sonar_pulse.gd: xyz where it was sent from, w = radius the front has reached (m)
	vec4 pulse_b;         // x visibility (0 = off), y range (m), z grain, w sideways streaks
	vec4 pulse_c;         // rgb echo colour * brightness, w = range ring spacing (m, 0 = none)
	vec4 pulse_d;         // rgb background colour, w = facing sharpness
	vec4 pulse_e;         // x front glow, y grain seed, z dissolve, w opacity
	vec4 pulse_f;         // x seconds since sent, y front speed (m/s), z afterglow time (s), w afterglow flare
	vec4 pulse_g;         // x how bright an echo is at the edge of the range compared to close by, y echo of the sea surface itself
	vec4 shore_rect;      // Shore zone, see shore.gdshaderinc: (corner x, corner z, 1 / size x, 1 / size z)
	vec4 shore_a;         // (wave height, wavelength, phase, stagger)
	vec4 shore_b;         // (shoal depth, run-up height, run-up reach, damping depth per m of wavelength)
	vec4 shore_c;         // (wave clock, run-up variation, swash film, swash lobes)
} p;
layout(set = 0, binding = 8) uniform sampler2D shore_map;

#include "water_shapes.glsli"

#ifdef MODE_SHAFTS
layout(set = 0, binding = 5) uniform sampler2D focus_tex; // Light focus map, see caustics.glsl.
layout(set = 0, binding = 7) uniform sampler2D shadow_tex; // Sun shadow map, see water_shadow.glsli.
#include "water_shadow.glsli"
#endif

layout(push_constant, std430) uniform PushConstant {
	vec2 size;       // Full resolution.
	vec2 shaft_size; // Half resolution light shaft buffer.
} pc;

vec3 view_pos(vec2 uv, float depth) {
	// No y flip here: inv_projection comes from get_view_projection(), which already carries
	// it. Flipping again turns every direction taken from here upside down.
	vec4 v = p.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return v.xyz / v.w;
}

// Calm zones (ShoreCalm and the like) flatten the waves, so the surface here is not the one
// the FFT alone would give. Without this the effect tests against a sea that is not being
// drawn, and everything keyed to the waterline goes wrong near a shore.
// Returns (mask, height of the calmed water), see blocker_calm() in water.gd.
// Must mirror wave_blocker_eval() in water.gdshader and blocker_calm() in water.gd.
vec2 wave_blocker_calm(vec2 pos) {
	float mask = 1.0;
	float calm_height = 0.0;
	int count = int(p.shafts2.z + 0.5);
	for (int i = 0; i < count; i++) {
		vec4 a = p.blocker_a[i];
		vec4 b = p.blocker_b[i];
		vec2 rel = pos - a.xy;
		int flags = int(b.w + 0.5);
		vec2 lp = vec2(a.z*rel.x + a.w*rel.y, -a.w*rel.x + a.z*rel.y);
		float d;
		if ((flags & 1) == 1) { // box footprint, rotated by yaw
			vec2 q = abs(lp) - b.xy;
			d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
		} else if ((flags & 4) == 4) { // capsule seen from above
			d = length(vec2(max(abs(lp.x) - b.y, 0.0), lp.y)) - b.x;
		} else { // circle
			d = length(rel) - b.x;
		}
		float m = smoothstep(0.0, max(b.z, 0.001), d);
		if (m < mask) {
			mask = m;
			vec4 c = p.blocker_c[i];
			calm_height = c.x + dot(c.yz, rel);
		}
	}
	return vec2(mask, calm_height);
}

// Shore zone: mirrors shore.gdshaderinc exactly (see there).
vec4 shore_sample(vec2 xz) {
	vec2 uv = (xz - p.shore_rect.xy) * p.shore_rect.zw;
	if (p.shore_rect.z <= 0.0 || uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return vec4(400.0, 2000.0, 0.0, 0.0);
	}
	vec4 s = textureLod(shore_map, uv, 0.0);
	vec2 edge = min(uv, 1.0 - uv) / p.shore_rect.zw;
	s.x = mix(400.0, s.x, smoothstep(0.0, 30.0, min(edge.x, edge.y)));
	return s;
}

float shore_damp(vec4 s, float wavelength) {
	return smoothstep(0.0, p.shore_b.w * wavelength, s.x);
}

float shore_swash(vec4 s, vec2 xz) {
	float clock = p.shore_c.x + s.w * p.shore_a.w;
	float q = fract(clock);
	float n = floor(clock);
	float h = fract(n * 0.618034);
	h = fract(h * h * 37.1 + h * 7.3);
	float r = q < 0.35 ? 1.0 - (1.0 - q / 0.35) * (1.0 - q / 0.35)
			: 1.0 - ((q - 0.35) / 0.65) * ((q - 0.35) / 0.65);
	float reach = max(p.shore_b.z, 1.0);
	float a = 6.2831853 * h;
	float lobes = sin(dot(xz, vec2(0.61, 0.79)) * 0.55 + a * 3.0) * 0.6
			+ sin(dot(xz, vec2(-0.83, 0.56)) * 1.3 + a * 5.0) * 0.4;
	return p.shore_b.y * (1.0 + p.shore_c.y * (2.0 * h - 1.0)) * (1.0 + p.shore_c.w * lobes) * r
			* smoothstep(-reach, -0.7 * reach, s.y);
}

float shore_wave(vec4 s, vec2 xz) {
	float depth = s.x;
	float height = 0.0;
	float stagger = s.w * p.shore_a.w;
	if (s.z > 0.0) {
		float shoal = max(p.shore_b.x, 0.1);
		float ph = fract(s.y / max(p.shore_a.y, 1.0) + p.shore_a.z + stagger);
		float steep = clamp(1.0 - depth / shoal, 0.0, 1.0);
		float g = pow(ph, 1.0 + 1.5 * steep);
		float c = pow(0.5 + 0.5 * cos(6.2831853 * g), 1.0 + 2.0 * steep);
		float amp = p.shore_a.x * pow(shoal / max(depth, 0.25 * shoal), 0.25) * (1.0 - smoothstep(shoal, 3.0 * shoal, depth));
		amp = min(amp, 0.39 * max(depth, 0.0));
		height = amp * (2.0 * c - 1.0) * s.z;
	}
	float sand = -depth;
	float front = shore_swash(s, xz);
	float q = fract(p.shore_c.x + stagger);
	float film = p.shore_c.z * clamp((front - sand) / 0.1, 0.0, 1.0) * (1.0 - 0.6 * smoothstep(0.35, 1.0, q));
	return max(height, sand < front ? sand + film : front);
}

vec3 displacement(vec2 xz) {
	vec3 d = vec3(0.0);
	int n = int(p.absorption.a);
	vec4 shore = shore_sample(xz);
	for (int i = 0; i < n; i++) {
		vec4 s = p.map_scales[i];
		d += textureLod(displacements, vec3(xz * s.xy, float(i)), 0.0).xyz * s.z * shore_damp(shore, 1.0 / s.x);
	}
	return d;
}

// The FFT displaces horizontally too (choppy waves), so find which rest position lands on
// `xz` with a couple of fixed-point iterations before reading the height.
float wave_height(vec2 xz) {
	vec2 shape = water_shapes(xz);
	vec2 calm = wave_blocker_calm(xz);
	vec2 rest = xz;
	vec3 d = vec3(0.0);
	for (int i = 0; i < 3; i++) {
		d = displacement(rest) * (1.0 - shape.y) * calm.x;
		rest = xz - d.xz;
	}
	return p.effect2.y + d.y + shape.x + calm.y * (1.0 - calm.x) + shore_wave(shore_sample(rest), rest) * calm.x;
}

#ifndef MODE_SHAFTS
float hash12(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
	           mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}

// The scene at `uv` seen through the water in front of it: absorbed over the distance to what
// is there and veiled by `fog` over the same stretch (`exit_dist`: where the ray leaves through
// the surface). Each sample is fogged by its own distance, before any blurring: blurred first,
// a near object's edge took in the bare scene behind it (the sky, unfogged) while its own short
// distance kept the fog off, and something close, like your own body, had a rim of sky round it.
// One pixel each, colour and depth, not filtered: a filtered colour mixes in the pixel behind
// the edge, which a filtered depth doesn't account for.
vec3 through_water(vec2 uv, float exit_dist, vec3 fog) {
	ivec2 px = clamp(ivec2(uv * pc.size), ivec2(0), ivec2(pc.size) - 1);
	float depth = texelFetch(depth_tex, px, 0).r;
	float hit = depth <= 0.0 ? 1e4 : length(view_pos(uv, depth)); // depth 0 = sky.
	float dist = min(hit, max(exit_dist, 0.0));
	vec3 c = texelFetch(source_tex, px, 0).rgb;
	return c * exp(-p.absorption.rgb * dist) + fog * (1.0 - exp(-dist / max(p.effect2.z, 1.0)));
}

vec3 blurred(vec2 uv, float radius_px, float exit_dist, vec3 fog) {
	vec2 r = radius_px / pc.size;
	vec3 c = through_water(uv, exit_dist, fog) * 0.4;
	c += through_water(uv + vec2( r.x,  r.y), exit_dist, fog) * 0.15;
	c += through_water(uv + vec2(-r.x,  r.y), exit_dist, fog) * 0.15;
	c += through_water(uv + vec2( r.x, -r.y), exit_dist, fog) * 0.15;
	c += through_water(uv + vec2(-r.x, -r.y), exit_dist, fog) * 0.15;
	return c;
}

// Light the UnderwaterGlow nodes throw into the murk along a view ray (origin o, unit dir d,
// `len` meters of water), like lamps in volumetric fog. Closed form of the in-scattering along
// the ray: it falls off with the square of the distance from the light, softened inside a core
// of radius `size` so it stays finite, and is normalised so that looking straight through a
// light gives exactly its strength. Must mirror underwater_glow() in water.gdshader.
vec3 underwater_glow(vec3 o, vec3 d, float len) {
	vec3 sum = vec3(0.0);
	int count = int(p.glow_info.x + 0.5);
	for (int i = 0; i < count; i++) {
		vec4 a = p.glow_a[i];
		vec4 b = p.glow_b[i];
		vec3 to_light = a.xyz - o;
		float t0 = dot(to_light, d); // Where along the ray it passes closest to the light.
		float size = max(a.w, 0.01);
		float h = sqrt(max(dot(to_light, to_light) - t0 * t0, 0.0) + size * size);
		float along = (atan((len - t0) / h) + atan(t0 / h)) * size / (h * 3.14159265);
		// The murk between us and the light hides it by about `reach`, and it also dims the light
		// on its way out to the ray before it scatters towards us, which keeps the halo compact.
		float murk = 3.0 / max(b.w, 1.0);
		float fade = exp(-murk * (length(to_light) + max(h - size, 0.0)));
		sum += b.rgb * max(along, 0.0) * fade;
	}
	return sum;
}

vec3 world_at(vec2 uv) {
	return (p.cam_to_world * vec4(view_pos(uv, textureLod(depth_tex, uv, 0.0).r), 1.0)).xyz;
}

// Sonar pulse (sonar_pulse.gd): a shell of sound races out from where it was sent, and every
// surface it has passed answers in proportion to how squarely it faces back at the sender,
// fading with distance. The answer is drawn as a grainy, scan-smeared echo in place of the
// murk; as the pulse dies the picture crumbles away grain by grain instead of dimming.
// Like the phosphor on a sonar screen, each point flares as the front passes it and settles
// to an afterglow, and the strongest echoes are the last to let go as the picture fades.
// Costs nothing unless a pulse is showing (a handful of extra depth taps per pixel then).
vec3 sonar_pulse(vec2 uv, vec2 pxf, vec3 under) {
	float range = max(p.pulse_b.y, 0.1);
	float seed = p.pulse_e.y;
	// Grain: blotchy speckle a few pixels across, like ultrasound, and runs of it smeared
	// sideways like a scan line. Squared so it is mostly dark with bright flecks.
	vec2 jitter = vec2(seed * 37.3, seed * 11.9);
	// Sized for the game's low-res look: finer grain would just average away to grey.
	float blotch = vnoise(pxf / 4.0 + jitter) * 0.7 + hash12(floor(pxf / 2.0) + seed * 91.7) * 0.3;
	float streak = vnoise(vec2(pxf.x / mix(3.0, 22.0, p.pulse_b.w), pxf.y / 2.0) + jitter);
	float grain = mix(blotch, streak, p.pulse_b.w * 0.7);
	grain = smoothstep(0.3, 0.75, grain) * 1.8; // mostly dark, bright flecks

	float echo = 0.0;
	float depth = textureLod(depth_tex, uv, 0.0).r;
	if (depth > 0.0) { // depth 0 = nothing there (sky)
		vec3 pos = world_at(uv);
		vec3 to_origin = p.pulse_a.xyz - pos;
		float r = length(to_origin);
		if (r < p.pulse_a.w && r < range) {
			// Normal from the depth buffer a couple of pixels out (softer, like a blurry echo),
			// taking the nearer neighbour on each axis so silhouettes do not grow a halo.
			vec2 texel = 2.0 / pc.size;
			vec3 xa = world_at(uv + vec2(texel.x, 0.0)) - pos, xb = pos - world_at(uv - vec2(texel.x, 0.0));
			vec3 ya = world_at(uv + vec2(0.0, texel.y)) - pos, yb = pos - world_at(uv - vec2(0.0, texel.y));
			float lxa = length(xa), lxb = length(xb), lya = length(ya), lyb = length(yb);
			vec3 dx = lxa < lxb ? xa : xb;
			vec3 dy = lya < lyb ? ya : yb;
			vec3 n = normalize(cross(dx, dy));
			float facing = pow(abs(dot(n, to_origin / max(r, 1e-4))), p.pulse_d.w);
			// Edges (a jump in depth to the neighbour) answer hardest: outlines read first.
			float jump = max(max(lxa, lxb) / max(min(lxa, lxb), 1e-4), max(lya, lyb) / max(min(lya, lyb), 1e-4));
			float edge = smoothstep(2.0, 6.0, jump);
			// Unlike light in this water, the pulse carries: echoes only dim gently with distance,
			// so whatever is within range shows, then cut off over its last tenth.
			float fall = mix(1.0, p.pulse_g.x, sqrt(r / range)) * (1.0 - smoothstep(range * 0.9, range, r));
			echo = (facing * 0.7 + edge) * fall;
			// The underside of the waves is everywhere overhead and would bury what hangs under
			// it, so the sea surface itself gives only a faint answer.
			if (abs(pos.y - wave_height(pos.xz)) < 0.3 + 0.01 * r) echo *= p.pulse_g.y;
			// Phosphor: flares when the front reaches it, then decays to the afterglow.
			float since_hit = max(p.pulse_f.x - r / max(p.pulse_f.y, 1.0), 0.0);
			echo *= 1.0 + p.pulse_f.w * exp(-since_hit / max(p.pulse_f.z, 0.01));
			if (p.pulse_c.w > 0.0) { // range rings
				float ring = abs(fract(r / p.pulse_c.w) - 0.5) * 2.0;
				echo *= 0.5 + 1.0 * smoothstep(0.82, 1.0, ring);
			}
			// The front itself: a bright band just behind it while it is still travelling.
			float behind = p.pulse_a.w - r;
			echo += p.pulse_e.x * exp(-behind * 0.8) * step(p.pulse_a.w, range - 0.01) * (0.3 + 0.7 * facing);
		}
	}
	echo *= mix(1.0, grain, p.pulse_b.z); // speckle
	echo = smoothstep(0.04, 1.4, echo); // dark floor, soft ceiling: near walls do not burn out flat
	vec3 col = p.pulse_d.rgb * mix(1.0, 0.5 + grain * 0.5, p.pulse_b.z) + p.pulse_c.rgb * echo;

	// As visibility falls, each 2x2 cell drops out at its own moment (dissolve 0 = plain fade).
	float dz = clamp(p.pulse_e.z, 0.0, 0.95);
	// Strong echoes hold on longer, like a phosphor burned in brighter.
	float vis = pow(p.pulse_b.x, 1.0 / (1.0 + 3.0 * echo * step(0.01, p.pulse_f.z)));
	float keep = clamp((vis - hash12(floor(pxf * 0.5) + 17.0) * dz) / (1.0 - dz), 0.0, 1.0);
	return mix(under, col, keep * p.pulse_e.w);
}

// 3x3 tent of bilinear taps over the half-res shaft buffer: hides the ray march dither.
vec3 shafts_filtered(vec2 uv) {
	vec2 r = 1.5 / pc.shaft_size;
	vec3 c = vec3(0.0);
	float total = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			float w = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
			c += textureLod(shaft_tex, uv + vec2(x, y) * r, 0.0).rgb * w;
			total += w;
		}
	}
	return c / total;
}
#endif

#ifdef MODE_SHAFTS
const float WATER_IOR = 1.333;
const float PI = 3.14159265;

// Henyey-Greenstein phase function: g > 0 scatters light forward, so shafts glow brightest
// when looking towards the sun.
float phase_hg(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5));
}

// Marches the view ray through the water. Every sample looks straight up the refracted sun
// direction to the surface and asks the focus map how much light the waves focus onto it.
// The pattern is constant along that direction, which is what draws the streaks.
vec3 light_shafts(vec3 origin, vec3 dir, float max_dist, float jitter) {
	vec3 to_light = -refract(-p.sun_dir.xyz, vec3(0.0, 1.0, 0.0), 1.0 / WATER_IOR);
	if (to_light.y <= 0.01 || p.sun_dir.w <= 0.0) return vec3(0.0);
	int steps = max(int(p.shafts.y), 1);
	float dt = min(max_dist, p.sun_color.w) / float(steps);
	vec3 sum = vec3(0.0);
	for (int i = 0; i < steps; i++) {
		float t = (float(i) + jitter) * dt;
		vec3 pos = origin + dir * t;
		float depth = p.effect2.y - pos.y; // Approximate the surface as flat at water level.
		if (depth <= 0.0) continue;
		vec2 surface_xz = pos.xz + to_light.xz * (depth / to_light.y);
		float focus = textureLod(focus_tex, surface_xz * p.shafts.x, 0.0).r;
		// Only the focused part stands out; the average light is already in the fog colour.
		float bright = pow(max(focus - p.shafts2.x, 0.0), p.shafts.w);
		// Nothing gets focused where something above the water blocks the sun.
		bright *= sun_visibility(vec3(surface_xz.x, p.effect2.y, surface_xz.y));
		sum += bright * exp(-p.absorption.rgb * (t + depth / to_light.y));
	}
	vec3 light = sum * dt * phase_hg(dot(dir, to_light), p.shafts.z) * p.sun_color.rgb * p.shaft_tint.rgb * p.sun_dir.w;
	return min(light, vec3(p.shaft_tint.a));
}
#endif

#ifdef MODE_SHAFTS
// Beams of lamps (the searchlight, anything in the underwater_beam group) through the murk.
// For each lamp, march only the stretch of the view ray that passes within its range and under
// the surface, asking at each step: is this point inside your cone, and how much of your light
// survives the water it crossed to get here? Only the underwater part of that path dims it (a
// lamp above the water shines through air first). The surface is taken as flat and the beam as
// straight, not bent by refraction.
// A lamp above the water shines down through the waves, which focus it like they focus the sun:
// each point in the beam looks back along its light to where it came through the surface and
// reads the focus map there. Along a line from the lamp that answer never changes, so the beam
// breaks into streaks fanning out from where it enters the sea, swaying with the waves.
// The focus map averages 1 (the waves only move light around), so the beam keeps its brightness.
// A searchlight's mirror gathers its light into a beam, so it does not fade with the square of
// the distance like a bare bulb: it holds up to about BEAM_THROW meters, then starts to spread.
const float BEAM_THROW = 8.0;

vec3 light_beams(vec3 origin, vec3 dir, float max_dist, float jitter) {
	int count = int(p.beam_info.x + 0.5);
	if (count == 0 || p.beam_info.y <= 0.0) return vec3(0.0);
	int steps = max(int(p.beam_info.z + 0.5), 1);
	// Where the ray leaves the water going up (flat surface), else as far as it sees.
	float wet_end = max_dist;
	if (dir.y > 1e-4) wet_end = min(wet_end, max(p.effect2.y - origin.y, 0.0) / dir.y);
	vec3 sum = vec3(0.0);
	for (int j = 0; j < count; j++) {
		vec4 a = p.beam_a[j];
		vec4 b = p.beam_b[j];
		vec4 c = p.beam_c[j];
		// The part of the ray inside the lamp's range (a sphere around it).
		vec3 oc = origin - a.xyz;
		float half_b = dot(oc, dir);
		float disc = half_b * half_b - (dot(oc, oc) - a.w * a.w);
		if (disc <= 0.0) continue;
		disc = sqrt(disc);
		float t0 = max(-half_b - disc, 0.0);
		float t1 = min(-half_b + disc, wet_end);
		if (t1 <= t0) continue;
		float dt = (t1 - t0) / float(steps);
		float light_depth = p.effect2.y - a.y; // < 0: the lamp is above the water
		vec3 lamp = vec3(0.0);
		for (int i = 0; i < steps; i++) {
			float t = t0 + (float(i) + jitter) * dt;
			vec3 pos = origin + dir * t;
			float depth = p.effect2.y - pos.y;
			if (depth <= 0.0) continue;
			vec3 from_light = pos - a.xyz;
			float r2 = dot(from_light, from_light);
			float r = sqrt(r2);
			vec3 l = from_light / max(r, 1e-4);
			float cone = smoothstep(b.w, c.w, dot(l, b.xyz));
			if (cone <= 0.0) continue;
			float wet = light_depth >= 0.0 ? r : r * depth / max(depth - light_depth, 1e-3);
			float streaks = 1.0;
			if (light_depth < 0.0 && p.beam_info2.x > 0.0) {
				// Where the line from the lamp to here crosses the (flat) surface.
				vec2 surface_xz = mix(pos.xz, a.xz, depth / (depth - light_depth));
				float focus = textureLod(focus_tex, surface_xz * p.shafts.x, 0.0).r;
				streaks = mix(1.0, min(focus, 4.0), p.beam_info2.x);
			}
			float range_fade = 1.0 - smoothstep(0.6 * a.w, a.w, r);
			vec3 through = exp(-p.absorption.rgb * (wet + t)); // to the point, then on to us
			float phase = phase_hg(dot(dir, -l), p.beam_info.w);
			lamp += through * (streaks * cone * range_fade * phase / (1.0 + r2 / (BEAM_THROW * BEAM_THROW)));
		}
		sum += c.rgb * lamp * dt;
	}
	// Soft ceiling: a strong beam saturates towards full brightness instead of clipping into
	// a flat white shape, so standing right in it still shows its falloff.
	return vec3(1.0) - exp(-sum * p.beam_info.y);
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(px, ivec2(pc.shaft_size)))) return;
	vec2 uv = (vec2(px) + 0.5) / pc.shaft_size;

	vec3 near_view = view_pos(uv, 1.0);
	vec3 near_world = (p.cam_to_world * vec4(near_view, 1.0)).xyz;
	vec3 shafts = vec3(0.0);
	if (p.shafts2.w > 0.0) { // Only while the lens itself is under.
		float depth = textureLod(depth_tex, uv, 0.0).r;
		float dist = depth <= 0.0 ? 1e4 : length(view_pos(uv, depth)); // depth 0 = far plane (sky).
		vec3 ray_dir = normalize(mat3(p.cam_to_world) * near_view);
		float jitter = fract(52.9829189 * fract(dot(vec2(px), vec2(0.06711056, 0.00583715))));
		shafts = light_shafts(p.cam_to_world[3].xyz, ray_dir, dist, jitter);
		shafts += light_beams(p.cam_to_world[3].xyz, ray_dir, dist, jitter);
	}
	imageStore(shaft_image, px, vec4(shafts, 1.0));
}
#else
void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(px, ivec2(pc.size)))) return;
	// Inside a hull (DryVolume) the sea outside may stand above the lens, but none of it is here.
	if (p.shape_count.z > 0.5) return;
	vec2 uv = (vec2(px) + 0.5) / pc.size;

	// Where this pixel's ray starts (near plane, reverse-z => depth 1.0), in world space.
	vec3 near_view = view_pos(uv, 1.0);
	vec3 near_world = (p.cam_to_world * vec4(near_view, 1.0)).xyz;
	float submersion = wave_height(near_world.xz) - near_world.y; // > 0 means underwater.

	vec3 scene = textureLod(source_tex, uv, 0.0).rgb;
	// Waterline width is given in pixels; convert to meters on the (tiny) near plane.
	float pixel_meters = length(view_pos(uv + vec2(0.0, 1.0) / pc.size, 1.0) - near_view);
	float thickness = max(p.effect.w * pixel_meters, 1e-6);
	// Is the lens in the water at all? Everything the water does to the picture follows from
	// the path below, which falls to nothing by itself as we surface; this only fades the
	// things that come from the lens being wet rather than from the water in front of it.
	float lens = p.shafts2.w;
	float wet = smoothstep(0.0, 0.08, lens);
	// Froth reaches further than the line itself, and further still while you are going under.
	// Pixel scale like the line: across the whole screen the near plane spans only a couple
	// of centimeters of world height, so a band measured in meters would swallow the view.
	float churn = p.shafts2.y;
	// A burst thrown up each time the head breaks the surface, either way (see water.gd's
	// crossing_foam_*). It widens the band and thickens the froth, then dies away.
	float burst = p.shape_count.y;
	float foam = p.effect2.w * (1.0 + burst * 2.0);
	float band = thickness * (1.5 + 4.0 * churn + 10.0 * burst);
	float reach = max(3.0 * thickness, foam > 0.0 ? band * 2.0 : 0.0);
	if (wet <= 0.0 && submersion < -reach) return; // Lens dry and away from the waterline.

	vec3 result = scene;
	if (wet > 0.0) {
		float t = p.effect.x;
		vec2 wobble = vec2(sin(uv.y * 23.0 + t * 1.7) + sin(uv.y * 41.0 - t * 2.3) * 0.5,
		                   cos(uv.x * 19.0 + t * 1.3) + cos(uv.x * 37.0 + t * 2.9) * 0.5);
		vec2 suv = clamp(uv + wobble * p.effect.y, vec2(0.0), vec2(1.0));

		vec3 view_dir = normalize(mat3(p.cam_to_world) * view_pos(suv, 1.0));
		float depth = textureLod(depth_tex, suv, 0.0).r;
		float hit = depth <= 0.0 ? 1e4 : length(view_pos(suv, depth)); // depth 0 = sky.
		// A ray only carries water for as long as it is in the water. Looking up it leaves
		// through the surface overhead, so the sky stays the sky even with the lens under;
		// level or downward it never leaves, and we see the full murk. Applied to every
		// pixel alike, so there is no seam between what the surface covers and what it does not.
		float exit_dist = view_dir.y > 1e-4 ? lens / view_dir.y : 1e4;
		float dist = min(hit, max(exit_dist, 0.0));

		// Light fades with depth. The scattered light you see along a view comes from the water
		// it passes through (out to about the silhouette range), so looking up you see shallower,
		// brighter water - a faint glow overhead even when deep - and looking down, only black.
		float seen_depth = max(lens - view_dir.y * min(dist, p.effect2.z), 0.0);
		vec3 fog = p.fog_color.rgb * exp(-p.fog_color.a * seen_depth);
		fog *= mix(p.fog_gradient.x, p.fog_gradient.y, view_dir.y * 0.5 + 0.5);
		// Detail and colour are absorbed quickly (absorption), but the light scattered into the
		// view builds up over a much longer range (silhouette range). So a distant creature is
		// lost as a lit object yet still blocks the glow behind it: a dark shape in the murk
		// (see through_water()).
		// Wobble and blur come from the lens being in the water, so they fade in as it goes
		// under. What the water does to the light does not fade: the path above already says
		// how much water there was. Fading that too lets you see clear to the sea floor for
		// the moment you are only a few centimeters down.
		vec3 under = blurred(suv, p.effect.z, exit_dist, fog);
		if (wet < 1.0) under = mix(through_water(uv, exit_dist, fog), under, wet);
		// Lamps and glowing things light up the water around them, over the same stretch of it.
		if (p.glow_info.x > 0.5) under += underwater_glow(p.cam_to_world[3].xyz, view_dir, dist) * p.glow_info.y;

		under += shafts_filtered(suv);

		if (p.pulse_b.x > 0.0) under = sonar_pulse(suv, vec2(px), under);

		vec2 v = uv - 0.5;
		under *= 1.0 - p.effect2.x * dot(v, v) * 2.0 * wet;
		result = under;
	}

	// Meniscus: the thin dark lip right at the interface, where the surface is edge-on.
	float line = 1.0 - smoothstep(0.0, thickness * 2.0, abs(submersion));
	result *= 1.0 - 0.5 * line;

	// Froth. A sea like this never gives you a clean waterline: it tears along the chop,
	// foams white, and drags a cloud of air down with you as you go under.
	if (foam > 0.0) {
		float t = p.effect.x;
		float ragged = (vnoise(vec2(uv.x * 26.0, t * 0.9)) - 0.5) * 2.0
		             + (vnoise(vec2(uv.x * 71.0, t * 1.7)) - 0.5);
		float froth = 1.0 - smoothstep(0.0, band, abs(submersion - ragged * band * 0.35));
		froth *= 0.1 + 0.9 * vnoise(vec2(uv.x * 150.0, uv.y * 150.0 - t * 3.0));
		// Foam is only ever as bright as the light falling on it, so it greys out at night.
		// The air dragged under is real geometry, not screen noise: see PlungeBubbles on
		// the player, which emits by how hard you hit the water.
		float lum = dot(result, vec3(0.299, 0.587, 0.114));
		vec3 lit = min(p.sun_color.rgb, vec3(1.0));
		result = mix(result, lit * clamp(lum * 1.6 + 0.25, 0.15, 1.0),
				clamp(froth * 0.7, 0.0, 0.8) * foam);

	}

	imageStore(color_image, px, vec4(result, 1.0));
}
#endif
