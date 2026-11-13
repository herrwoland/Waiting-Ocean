shader_type particles;
// Rain drops falling around the camera (see rain.gd). Each drop ends on the real FFT wave surface
// (or on solid geometry via the heightfield collider) and may throw a splash there.

global uniform sampler2DArray displacements;
global uniform uint num_cascades;
#include "res://assets/shaders/spatial/shore.gdshaderinc"

uniform vec3 center;                     // Camera position, set every frame.
uniform float radius = 40.0;             // Drops fall in a disc this wide around the camera (m).
uniform float column_height = 30.0;      // ...from this far above the camera/water.
uniform float water_level = 0.0;
uniform vec4 map_scales[4];              // Wave cascades, copied from the water node.
uniform vec2 wind = vec2(0.0);           // Horizontal wind velocity (m/s).
uniform float fall_speed = 12.0;         // m/s.
uniform float streak_length = 0.9;       // m, at fall_speed.
uniform float streak_width = 0.012;      // m.
uniform float splash_radius = 22.0;      // Only drops this close to the camera splash.
uniform float splash_chance = 0.5;
uniform int splash_droplets = 5;         // Droplets thrown up per splash (plus one ring on water).
uniform float splash_speed = 2.2;        // m/s upwards.

float hash(uint n) {
	n = (n << 13u) ^ n;
	n = n * (n * n * 15731u + 789221u) + 1376312589u;
	return float(n & 0x7fffffffu) / float(0x7fffffff);
}

vec3 displacement(vec2 xz) {
	vec3 d = vec3(0.0);
	for (uint i = 0u; i < min(num_cascades, 4u); i++) {
		vec4 s = map_scales[i];
		d += textureLod(displacements, vec3(xz * s.xy, float(i)), 0.0).xyz * s.z * shore_damp(shore_sample(xz), 1.0 / s.x);
	}
	return d;
}

// The waves also move sideways (choppy crests), so find which rest point lands on `xz` first,
// like the other water effects do. Otherwise drops end up to a metre off the real surface.
float wave_height(vec2 xz) {
	vec2 rest = xz;
	vec3 d = vec3(0.0);
	for (int i = 0; i < 3; i++) {
		d = displacement(rest);
		rest = xz - d.xz;
	}
	return water_level + d.y + shore_wave(shore_sample(rest), rest).x;
}

void start() {
	uint seed = NUMBER * 13u + RANDOM_SEED;
	if (RESTART_POSITION) {
		float angle = hash(seed) * 6.2832;
		float dist = sqrt(hash(seed + 1u)) * radius;
		// Always start at the top: drops born mid-air would appear under decks and roofs.
		float top = max(center.y, water_level) + column_height;
		vec3 p = vec3(center.x + cos(angle) * dist, top - hash(seed + 2u) * 2.0, center.z + sin(angle) * dist);
		// Start upwind, so the column the camera sees is full despite the slant.
		p.xz -= wind * ((p.y - water_level) / fall_speed) * 0.5;
		TRANSFORM = mat4(1.0);
		TRANSFORM[3].xyz = p;
	}
	if (RESTART_VELOCITY) {
		float speed = fall_speed * mix(0.85, 1.15, hash(seed + 3u));
		VELOCITY = vec3(wind.x, -speed, wind.y) * mix(0.9, 1.1, hash(seed + 4u));
	}
	CUSTOM.x = hash(seed + 5u); // Splash roll.
}

void process() {
	vec3 p = TRANSFORM[3].xyz;
	// The streak is centred on the particle, so end it as soon as its front half would dip in:
	// anything below the surface gets tinted by the water (red/orange specks).
	float front = streak_length * 0.5 + length(VELOCITY) * DELTA;
	float surface = wave_height(p.xz);
	bool hit_water = p.y - front < surface;
	if (hit_water || COLLIDED) {
		if (CUSTOM.x < splash_chance && distance(p.xz, center.xz) < splash_radius) {
			// A crown: a ring spreading on the water plus droplets thrown up and out.
			mat4 splash = mat4(1.0);
			splash[3].xyz = hit_water ? vec3(p.x, surface + 0.02, p.z) : p;
			uint flags = FLAG_EMIT_POSITION | FLAG_EMIT_VELOCITY | FLAG_EMIT_CUSTOM;
			uint seed = NUMBER * 31u + uint(TIME * 60.0);
			if (hit_water) {
				emit_subparticle(splash, vec3(0.0), vec4(1.0), vec4(1.0, 0.0, hash(seed), 1.0), flags);
			}
			for (int k = 0; k < splash_droplets; k++) {
				uint ks = seed + uint(k) * 7u;
				float a = (float(k) + hash(ks)) / float(splash_droplets) * 6.2832;
				float out_speed = mix(0.4, 1.3, hash(ks + 1u));
				vec3 v = vec3(cos(a) * out_speed, splash_speed * mix(0.5, 1.2, hash(ks + 2u)), sin(a) * out_speed);
				emit_subparticle(splash, v, vec4(1.0), vec4(0.0, 0.0, hash(ks + 3u), hit_water ? 1.0 : 0.0), flags);
			}
		}
		ACTIVE = false;
	}
	// Streak along the fall direction: basis Y = direction * length, X/Z = width.
	vec3 dir = normalize(VELOCITY);
	vec3 side = normalize(cross(dir, abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 other = cross(side, dir);
	float len = streak_length * length(VELOCITY) / fall_speed;
	// Drops brushing past the lens would fill the screen with one giant streak: hide them.
	float near = smoothstep(1.2, 2.5, distance(p, center));
	len *= near;
	TRANSFORM[0].xyz = side * streak_width * near;
	TRANSFORM[1].xyz = dir * len;
	TRANSFORM[2].xyz = other * streak_width * near;
}
