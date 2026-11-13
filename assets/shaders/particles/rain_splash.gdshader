shader_type particles;
// Rain splash pieces, emitted by rain_drops.gdshader where a drop lands (see rain.gd):
//   CUSTOM.x = 1: a flat ring spreading on the surface, 0: a droplet thrown up out of the crown.
// Position, velocity and CUSTOM come from the drop; CUSTOM.y is used here as the age.

uniform float droplet_size = 0.05;   // m
uniform float ring_size = 0.35;      // Final ring radius (m).
uniform float gravity = 9.8;

// Water surface, so rings ride the waves and droplets end when they fall back in (anything
// under the surface gets tinted by the water). Same lookup as rain_drops.gdshader.
global uniform sampler2DArray displacements;
global uniform uint num_cascades;
#include "res://assets/shaders/spatial/shore.gdshaderinc"
uniform float water_level = 0.0;
uniform vec4 map_scales[4];

float wave_height(vec2 xz) {
	vec2 rest = xz;
	vec3 d = vec3(0.0);
	for (int it = 0; it < 3; it++) {
		d = vec3(0.0);
		for (uint i = 0u; i < min(num_cascades, 4u); i++) {
			vec4 s = map_scales[i];
			d += textureLod(displacements, vec3(rest * s.xy, float(i)), 0.0).xyz * s.z * shore_damp(shore_sample(rest), 1.0 / s.x);
		}
		rest = xz - d.xz;
	}
	return water_level + d.y + shore_wave(shore_sample(rest)).x;
}

void start() {
	if (RESTART_CUSTOM) CUSTOM = vec4(0.0);
	CUSTOM.y = 0.0;
}

void process() {
	CUSTOM.y += DELTA;
	float age = clamp(CUSTOM.y / LIFETIME, 0.0, 1.0);
	if (age >= 1.0) ACTIVE = false;
	float s;
	bool on_water = CUSTOM.w > 0.5;
	if (CUSTOM.x > 0.5) {
		VELOCITY = vec3(0.0);
		TRANSFORM[3].y = wave_height(TRANSFORM[3].xz) + 0.03;
		s = ring_size * mix(0.2, 1.0, sqrt(age)) * mix(0.7, 1.3, CUSTOM.z);
	} else {
		VELOCITY.y -= gravity * DELTA;
		if (on_water && VELOCITY.y < 0.0 && TRANSFORM[3].y < wave_height(TRANSFORM[3].xz)) ACTIVE = false;
		s = droplet_size * mix(0.6, 1.4, CUSTOM.z) * (1.0 - 0.5 * age);
	}
	TRANSFORM[0].xyz = vec3(s, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, s, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, s);
	COLOR = vec4(1.0, 1.0, 1.0, 1.0 - age);
}
