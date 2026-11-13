shader_type spatial;
render_mode world_vertex_coords, depth_draw_always, cull_disabled;
/**
 * Water lighting model roughly follows the 2019 GDC talk: "Wakes, Explosions and Lighting: Interactive Water Simulation in Atlas".
 * Source: https://gpuopen.com/gdc-presentations/2019/gdc-2019-agtd6-interactive-water-simulation-in-atlas.pdf
 */

#define MAX_CASCADES 8    // I am unsure how to generalize this.
#define REFLECTANCE  0.021 // Reflectance from air to seawater (eta=1.34).

#include "res://assets/shaders/spatial/shore.gdshaderinc"

global uniform vec4 water_color : source_color;
global uniform vec4 foam_color : source_color;
uniform bool backface_culling = true; // Toggle in the material inspector: discards back faces when on.
/** Meters of water that swallow red, green and blue. Short values are a churned storm sea
 * where a metre already greens things and three swallow them; long ones read as clear
 * tropical water you can see a hull through. */
uniform vec3 depth_color_consumption = vec3(2.5, 8.0, 14.0);
/** How much of what lies just under the surface survives being tinted by the water, before
 * depth_color_consumption starts eating it with distance. 0 leaves the sea opaque from above;
 * 1 lets something touching the underside show through untouched. Low values are honest for a
 * churned-up storm sea, higher ones for calm water you can see into. */
uniform float water_clarity : hint_range(0.0, 1.0) = 0.65;
/** How far the surface bends what you see through it. Without this, whatever is under the
 * water sits dead still like it is behind glass; with it, the waves drag it about, which is
 * most of what tells the eye it is looking into water at all. */
uniform float surface_refraction : hint_range(0.0, 1.5) = 0.35;
/** How deep the water has to be before it glows back at you as brightly as it can. Anything
 * lying nearer than this blocks part of that glow and reads as a shadow: the shorter it is,
 * the sooner a body has to be to loom out of the water. */
uniform float water_scatter_range : hint_range(0.5, 60.0) = 9.0;
/** How strongly something dark lying under the surface darkens the water above it. This is
 * laid over the foam as well, on purpose: in a sea this broken the whitecaps would otherwise
 * paint over anything down there, and a body big enough to loom should dim the lot. */
uniform float submerged_shadow : hint_range(0.0, 1.0) = 0.7;
/** How far down a dark mass can still darken the water above it. Kept apart from the murk on
 * purpose: the sea swallows colour within a few meters, but something the size of a whale
 * twenty meters down should still put a shadow on the surface, and tying the two together
 * means anything deep enough to be worth seeing is already gone. */
uniform float submerged_shadow_range : hint_range(1.0, 120.0) = 45.0;

// Radial water shapes (domes, ring swells) from WaterDeformer nodes. Set every frame by water.gd.
group_uniforms water_shapes;
uniform int water_shape_count = 0;
uniform vec4 water_shape_a[16];
uniform vec4 water_shape_b[16];
group_uniforms;

// DryVolume nodes (the inside of a hull...): no surface inside them. Set every frame by water.gd.
group_uniforms dry_volumes;
uniform int dry_count = 0;
uniform vec4 dry_rows[12];  // World-to-local transform, 3 rows per volume.
uniform vec4 dry_bounds[4]; // Area the map covers in local space: (x, z, size x, size z).
uniform sampler2DArray dry_maps : filter_nearest, repeat_disable; // (bottom, top) per spot, local.
group_uniforms;

// Inside a DryVolume? Must mirror DryVolume.contains().
bool in_dry_volume(vec3 world) {
	for (int i = 0; i < dry_count; i++) {
		vec4 w = vec4(world, 1.0);
		vec3 p = vec3(dot(dry_rows[i * 3], w), dot(dry_rows[i * 3 + 1], w), dot(dry_rows[i * 3 + 2], w));
		vec4 b = dry_bounds[i];
		vec2 uv = (p.xz - b.xy) / b.zw;
		if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) continue;
		vec2 span = textureLod(dry_maps, vec3(uv, float(i)), 0.0).rg;
		if (p.y > span.x && p.y < span.y) return true;
	}
	return false;
}

group_uniforms wave_blockers;
uniform int wave_blocker_count = 0;
uniform vec4 wave_blocker_a[8]; // (pos.x, pos.z, frame cos, frame sin)
uniform vec4 wave_blocker_b[8]; // (half x / radius, half z / capsule half length, fade width, flags: +1 box, +2 hole, +4 capsule)
uniform vec4 wave_blocker_c[8]; // calm plane: (height at the centre, dh/dx, dh/dz, unused)
group_uniforms;


/** How rough the surface is below the size the waves are drawn at, as a slope (GGX alpha).
 * The wind sets it at sea (Cox & Munk): ~0.13 in a breath of air, ~0.25 at 12 m/s, ~0.33 in a
 * 20 m/s gale. Lower = a sharp sun path and a horizon that mirrors the sky; higher = a broad,
 * dull glint band. Each weather preset sets its own. */
uniform float roughness : hint_range(0.0, 1.0) = 0.17;
/** How little the bare water is lit like paint. Water hardly scatters light off its surface: what
 * you see is the sky mirrored in it and the deep colour coming up from below, so at 0 it reads
 * milky and pale. Higher values darken it and leave the reflections; foam is left out, it stays matte. */
uniform float metallic : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0; // Global normal strength
/** Brightness of the glints lights leave on the waves: the sun or moon path, lamps on the
 * water. Each glint already follows its light's colour and energy; this scales them all. */
uniform float light_reflection : hint_range(0.0, 4.0, 0.01) = 1.0;

// The thin top of a wave (set from the Water node's Translucency dials): its colour turns paler
// and greener where the sun comes through it, and what lies behind it shows through a little.
// Nothing is added on top of the light it gets, so it never glows.
group_uniforms translucency;
uniform vec3 sss_color : source_color = vec3(0.16, 0.55, 0.46);
uniform float sss_strength = 2.0;
uniform float sss_see_through = 0.5;
uniform float sss_power = 4.0;
uniform float sss_distortion = 0.3;
uniform float sss_height_bias = 0.0;
uniform float sss_crest_glow = 0.3;
/** Height (m) of a typical crest above sea level, measured from the waves by water.gd. */
uniform float sss_wave_amplitude = 1.0;
/** Direction to the sun (world), w = how much it is up. Set every frame by water.gd. */
uniform vec4 sss_sun = vec4(0.0);
group_uniforms;

/** How far up a typical crest this bit of wave is: 0 at sea level, 1 at the crest, squared so it
 *  gathers into the tops where the water is thinnest. */
float crest_amount(float height) {
	float c = clamp((height / max(sss_wave_amplitude, 0.05) - sss_height_bias)
			/ max(1.0 - sss_height_bias, 0.05), 0.0, 1.5);
	return c * c;
}

group_uniforms wave_foam;
/** Texture laid over the wave foam: bright = foam, dark = gaps. White (or none) leaves the foam
 * as the simulation makes it. */
uniform sampler2D foam_noise_tex : hint_default_white, repeat_enable, filter_linear_mipmap;
/** World size (m) of one tile of foam_noise_tex. */
uniform float foam_texture_tile_size : hint_range(0.5, 64.0, 0.1) = 6.0;
/** How much foam_noise_tex shapes the foam (0 = not at all). */
uniform float foam_texture_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
group_uniforms;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];               // Scales for displacement/normal maps. Packed: [uv scale, displacement scale, normal scale]
global uniform uint num_cascades;
global uniform sampler2DArray displacements;         // Each layer represents one wave cascade.
global uniform sampler2DArray normals : hint_normal; // Each layer represents one wave cascade.

group_uniforms underwater;
/** Index of refraction of water. Sets the size of Snell's window (~97 degree cone). Seawater is ~1.34. */
uniform float water_ior : hint_range(1.0, 2.0) = 1.34;
/** Per-channel IOR spread, gives the edge of Snell's window a faint rainbow fringe. */
uniform float ior_dispersion : hint_range(0.0, 0.05) = 0.01;
/** How strongly the refracted ray bends the screen sample. 1.0 = physically based offset. */
uniform float window_refraction_strength : hint_range(0.0, 1.5) = 0.6;
/** Brightness of the world seen through Snell's window. */
uniform float window_brightness : hint_range(0.0, 4.0) = 1.0;
/** Blur toward the edge of the window, where the whole horizon gets squeezed together. */
uniform float window_edge_blur : hint_range(0.0, 6.0) = 3.0;
/** Colour of the lit water column, seen through total internal reflection. Also the underwater fog colour. */
/** How far the camera itself is below the surface (m), fed by water.gd. Decides whether a
 * back face is the underside we are looking up at, or a crest folding over in front of us. */
uniform float camera_submersion = 0.0;
uniform vec3 underwater_color : source_color = vec3(0.04, 0.13, 0.14);
/** How much light reaches the water from above right now, 0..1, fed by water.gd (dims the
 * underwater colour at night, see Water: underwater_follows_light). Not a weather setting. */
uniform float underwater_light = 1.0;
/** Per-meter extinction (r, g, b) used by the underwater screen effect. Red dies first. */
uniform vec3 underwater_absorption = vec3(0.22, 0.06, 0.05);
group_uniforms;

// Rain hitting the sea (see rain.gd, which drives rain_intensity).
group_uniforms rain;
uniform float rain_intensity : hint_range(0.0, 1.0, 0.01) = 0.0;
/** Spacing of the ripple rings (m). */
uniform float rain_ripple_size : hint_range(0.1, 3.0, 0.01) = 0.7;
/** How strongly the rings bend reflections and the view through the water. */
uniform float rain_ripple_strength : hint_range(0.0, 2.0, 0.01) = 0.6;
/** Rings per second in each spot. */
uniform float rain_ripple_speed : hint_range(0.1, 4.0, 0.01) = 1.3;
/** Ripples fade out beyond this distance (m). */
uniform float rain_ripple_distance : hint_range(5.0, 150.0, 1.0) = 45.0;
/** How matte and beaten-down the surface gets in heavy rain. */
uniform float rain_matte : hint_range(0.0, 1.0, 0.01) = 0.6;
/** How much heavy rain flattens the smallest waves. */
uniform float rain_flatten : hint_range(0.0, 1.0, 0.01) = 0.25;
/** Seen from underwater: how much the impact rings light up the underside of the surface. */
uniform float rain_underside_rings : hint_range(0.0, 3.0, 0.01) = 1.2;
/** Seen from underwater: extra bending of the view through the rain-beaten surface. */
uniform float rain_underside_refraction : hint_range(0.0, 4.0, 0.01) = 2.0;
group_uniforms;

vec2 rain_hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

/** Slope of the rain ripple rings at a world position (add to the surface gradient). `rings`
 *  gets how strongly a fresh ring crest passes here (0..1), for drawing them from below. */
vec2 rain_ripples(vec2 world_xz, float time, out float rings) {
	vec2 slope = vec2(0.0);
	rings = 0.0;
	for (int layer = 0; layer < 2; layer++) {
		vec2 q = world_xz / rain_ripple_size + float(layer) * vec2(0.37, 0.71);
		vec2 id = floor(q);
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				vec2 cell = id + vec2(float(x), float(y));
				vec2 h = rain_hash22(cell + float(layer) * 17.0);
				if (fract(h.x * 13.7 + h.y * 7.1) > rain_intensity) continue; // Fewer drops in light rain.
				float phase = fract(time * rain_ripple_speed * mix(0.8, 1.2, h.y) + h.x * 7.3);
				vec2 d = q - (cell + 0.2 + 0.6 * h);
				float r = length(d);
				float u = (r - phase * 0.9) / 0.1; // Ring radius grows to ~0.9 cells.
				float ring = -2.0 * u * exp(-u * u) * (1.0 - phase) * (1.0 - phase);
				slope += d / max(r, 1e-3) * ring;
				rings = max(rings, exp(-u * u * 2.0) * (1.0 - phase) * (1.0 - phase));
			}
		}
	}
	return slope * rain_ripple_strength * 0.35;
}

// UnderwaterGlow nodes (lamps, lures, glowing things under the water), set every frame by water.gd.
group_uniforms underwater_glow;
/** How brightly underwater glows light up the water seen from above it (0 = not at all). With
 *  the camera under the water it's the Water node's underwater_glow_strength instead. */
uniform float glow_above_water : hint_range(0.0, 4.0, 0.01) = 1.0;
uniform int glow_count = 0;
uniform vec4 glow_a[16]; // (position, core size)
uniform vec4 glow_b[16]; // (colour * strength, reach)
group_uniforms;

/** Seamless foam pattern the wake and contact foam are cut from (bright = foam). */
uniform sampler2D foam_pattern_tex : repeat_enable, filter_linear_mipmap;

// White water from WaterDeformers and breach splashes (breaking swell rings, dome flanks, the
// boil left where something went under). Cut from foam_pattern_tex like the wake, so it is lace
// and patches, never a solid sheet.
group_uniforms shape_foam;
/** Opacity of the white water. */
uniform float shape_foam_strength : hint_range(0.0, 1.0, 0.01) = 0.9;
/** Breaks it into patches; as the foam fades it falls apart into lace and then islands. */
uniform float shape_foam_breakup : hint_range(0.0, 1.0, 0.01) = 0.55;
/** World size (m) of one tile of the foam pattern. */
uniform float shape_foam_tile_size : hint_range(1.0, 64.0, 0.1) = 9.0;
/** How much the pattern's gaps show through thick foam (0 = solid white). */
uniform float shape_foam_lace : hint_range(0.0, 1.0, 0.01) = 0.5;
/** Bubbles stirred under the foam glow pale green-blue (uses wake_tint_color). */
uniform float shape_foam_tint : hint_range(0.0, 1.0, 0.01) = 0.5;
group_uniforms;

// Ship wakes: world-space trail map (r = foam, g = churn) around the camera, from wake_map.gd.
group_uniforms wake;
uniform sampler2D wake_map : filter_linear, repeat_disable;
uniform vec4 wake_map_rect = vec4(0.0); // xz of the map corner, map size (m), 1 = active
/** Opacity of wake foam. */
uniform float wake_foam_strength : hint_range(0.0, 1.0, 0.01) = 0.9;
/** Breaks the wake foam into patches and streaks. High values can cut a faint wake away
 *  entirely, so keep it below the strength the boat lays down (WakeEmitter's foam). */
uniform float wake_foam_breakup : hint_range(0.0, 1.0, 0.01) = 0.4;
/** World size (m) of one tile of the foam pattern. */
uniform float wake_foam_tile_size : hint_range(1.0, 64.0, 0.1) = 12.0;
/** How much the pattern's gaps show through thick foam (0 = solid white fresh wake). */
uniform float wake_foam_lace : hint_range(0.0, 1.0, 0.01) = 0.6;
/** How much churned wake water flattens the waves (a ship leaves a smoother lane behind it). */
uniform float wake_flatten : hint_range(0.0, 1.0, 0.01) = 0.35;
/** Colour of churned wake water. */
uniform vec3 wake_tint_color : source_color = vec3(0.2, 0.42, 0.4);
/** Strength of the churned-water tint. */
uniform float wake_tint_strength : hint_range(0.0, 1.0, 0.01) = 0.6;
group_uniforms;

vec2 wake_sample(vec2 world_xz) {
	if (wake_map_rect.w < 0.5) return vec2(0.0);
	vec2 uv = (world_xz - wake_map_rect.xy) / wake_map_rect.z;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return vec2(0.0);
	vec2 edge = smoothstep(vec2(0.0), vec2(0.05), uv) * smoothstep(vec2(0.0), vec2(0.05), 1.0 - uv);
	// Strength * life left: a wake keeps its look and then fades out over its last seconds.
	vec4 m = textureLod(wake_map, uv, 0.0);
	return m.rg * smoothstep(0.0, 0.25, m.ba) * edge.x * edge.y;
}

// Pale churned water where the surface meets anything poking through it (hulls, creatures,
// rocks, the shore), with a lighter band of "shallow" water around it.
group_uniforms contact_foam;
uniform bool contact_foam_enabled = true;
/** How far from the contact line the foam reaches (m). */
uniform float contact_foam_width : hint_range(0.05, 5.0, 0.01) = 1.2;
/** Screen samples used to find nearby objects. More = smoother ring around them, but slower. */
uniform int contact_foam_samples : hint_range(0, 32) = 16;
/** Foam opacity. */
uniform float contact_foam_strength : hint_range(0.0, 1.0, 0.01) = 0.85;
/** Breaks the foam into patches: 0 = solid band, 1 = scattered clumps. */
uniform float contact_foam_breakup : hint_range(0.0, 1.0, 0.01) = 0.45;
/** World size (m) of one tile of the foam texture (the wave foam's foam_noise_tex). */
uniform float contact_foam_tile_size : hint_range(1.0, 64.0, 0.1) = 7.3;
/** How fast the foam churns. */
uniform float contact_foam_speed : hint_range(0.0, 3.0, 0.01) = 0.35;
/** Rings of foam pulsing out from the contact line (0 = none). */
uniform float contact_foam_rings : hint_range(0.0, 1.0, 0.01) = 0.35;
/** Colour of the lighter water band around objects. */
uniform vec3 contact_tint_color : source_color = vec3(0.22, 0.45, 0.42);
/** How far the lighter band reaches (m). */
uniform float contact_tint_width : hint_range(0.1, 10.0, 0.01) = 1.6;
/** Strength of the lighter band. */
uniform float contact_tint_strength : hint_range(0.0, 1.0, 0.01) = 0.5;
/** The search for nearby objects is the costliest part of the water, so it only runs near the
 * things water.gd lists (anything reaching into the water around the camera), where a quick look
 * finds terrain close by, or where the sea floor behind the water is closer than this (m).
 * Out on the open sea it is skipped. */
uniform float contact_shore_depth : hint_range(0.0, 100.0, 0.1) = 20.0;
/** Width of the foam band along a shoreline in a shore zone's map (m), set by water.gd from its
 *  shore_foam_width. Drawn like contact foam, from the baked distance to the shore. 0 = off. */
uniform float shore_foam_width = 0.0;
uniform int contact_body_count = 0;
uniform vec4 contact_bodies[16]; // (centre, radius), set every frame by water.gd.
group_uniforms;

// Light shafts are drawn by underwater_effect.gd, not by this shader. Like the caustics below,
// they live here so the whole water look is tuned in one material.
group_uniforms light_shafts;
uniform bool shafts_enabled = true;
/** Overall brightness of the underwater light shafts. */
uniform float shaft_strength : hint_range(0.0, 2.0, 0.01) = 0.2;
/** Colour of the shafts (multiplied with the sun colour). */
uniform vec3 shaft_tint : source_color = vec3(1.0);
/** Caps how bright the shafts can glow. Lower = no blown-out beams towards the sun. */
uniform float shaft_max_brightness : hint_range(0.0, 4.0, 0.01) = 1.0;
/** Shapes the beams: > 1 = crisp defined rays, < 1 = soft hazy glow. */
uniform float shaft_contrast : hint_range(0.1, 4.0, 0.01) = 1.0;
/** How focused light must be to form a ray. Higher = fewer, stronger rays. */
uniform float shaft_threshold : hint_range(0.0, 3.0, 0.01) = 1.0;
/** Thin streaks (low) vs broad beams (high): how much small waves are smoothed away. */
uniform float shaft_softness : hint_range(1.0, 8.0, 0.1) = 3.0;
/** Pattern size. > 1 = more, narrower rays closer together. */
uniform float shaft_scale : hint_range(0.1, 4.0, 0.01) = 1.0;
/** Depth (m) at which the waves focus light most sharply. Deeper = thinner, more intense rays. */
uniform float shaft_focus_depth : hint_range(0.5, 40.0, 0.5) = 8.0;
/** How far from the camera shafts are gathered (m). */
uniform float shaft_max_distance : hint_range(5.0, 150.0, 1.0) = 40.0;
/** Forward scattering. Higher = shafts concentrate towards the sun, fade looking away from it. */
uniform float shaft_scattering : hint_range(0.0, 0.95, 0.01) = 0.6;
/** Ray march samples per pixel. Fewer = faster but grainier. */
uniform int shaft_quality : hint_range(4, 64) = 24;
group_uniforms;

// Caustics are drawn by caustics_effect.gd, not by this shader. They live here so the whole
// water look is tuned in one material; water.gd forwards them to the effect every frame.
group_uniforms caustics;
uniform bool caustics_enabled = true;
/** Overall brightness of the caustic light net. */
uniform float caustic_strength : hint_range(0.0, 5.0, 0.01) = 0.6;
/** Colour of the caustic light (multiplied with the sun colour). */
uniform vec3 caustic_tint : source_color = vec3(1.0);
/** Caps how bright a caustic line can get. Lower = no blown-out hot spots. */
uniform float caustic_max_brightness : hint_range(0.0, 10.0, 0.01) = 1.5;
/** Shapes the lines: > 1 = thin crisp lines, < 1 = soft broad light. */
uniform float caustic_contrast : hint_range(0.1, 4.0, 0.01) = 1.0;
/** How much the gaps between lines darken (light the waves focus away). 0 = only add light. */
uniform float caustic_darkening : hint_range(0.0, 1.0, 0.01) = 0.5;
/** Pattern size. > 1 = smaller, denser net. */
uniform float caustic_scale : hint_range(0.1, 8.0, 0.01) = 1.0;
/** Depth (m) where caustics are sharpest. Higher also focuses harder: thinner, brighter lines. */
uniform float caustic_focus_depth : hint_range(0.5, 30.0, 0.1) = 6.0;
/** Below the focus depth, caustics fade out over roughly this many meters. */
uniform float caustic_fade_depth : hint_range(0.5, 60.0, 0.1) = 9.0;
/** Rainbow split at the caustic edges. */
uniform float caustic_dispersion : hint_range(0.0, 0.03, 0.0005) = 0.004;
/** Wave cascade that draws the caustics (-1 = smallest waves). Mid-sized waves make the classic net. */
uniform int caustic_cascade : hint_range(-1, 7) = 1;
group_uniforms;

// Height of the wind waves alone around the surface they ride on, for the translucency. Water
// shapes and calm planes are left out: a dome or a swell they lift is a hill of solid water,
// not a thin crest light can come through.
varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying float blocker_mask;
varying float blocker_hole;
varying float underside; // 1.0 when this fragment is the water surface seen from below.
varying float rain_wet; // How rain-beaten this bit of surface is (0..1), for the lighting.
varying vec3 shore_depth; // Shore zone (see shore.gdshaderinc): (depth to the floor, zone weight, distance to the shoreline).
varying vec2 shore_slope; // Slope of the shore waves (dh/dx, dh/dz).
varying float shore_foam;

// Wave-blocker attenuation at a rest position (pre-displacement). Returns
// (mask, hole, calm height): mask 0 inside a blocker rising to 1 across its fade width;
// hole 1 inside a HOLE blocker (surface discarded there); calm height = where the calmed
// water lies there, on the strongest blocker's calm plane (see wave_blocker.gd).
// Must mirror distance_xz() in wave_blocker.gd and blocker_calm() in water.gd exactly.
vec3 wave_blocker_eval(vec2 p) {
	float mask = 1.0;
	float hole = 0.0;
	float calm_height = 0.0;
	for (int i = 0; i < wave_blocker_count; i++) {
		vec4 a = wave_blocker_a[i];
		vec4 b = wave_blocker_b[i];
		vec2 rel = p - a.xy;
		int flags = int(b.w + 0.5);
		float d;
		vec2 lp = vec2(a.z*rel.x + a.w*rel.y, -a.w*rel.x + a.z*rel.y);
		if ((flags & 1) == 1) { // box footprint, rotated by yaw
			vec2 q = abs(lp) - b.xy;
			d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
		} else if ((flags & 4) == 4) { // capsule seen from above: a stadium along its axis
			d = length(vec2(max(abs(lp.x) - b.y, 0.0), lp.y)) - b.x;
		} else { // circle footprint
			d = length(rel) - b.x;
		}
		float m = smoothstep(0.0, max(b.z, 0.001), d);
		if (m < mask) {
			mask = m;
			vec4 c = wave_blocker_c[i];
			calm_height = c.x + dot(c.yz, rel);
		}
		if ((flags & 2) == 2 && d <= 0.0) {
			hole = 1.0;
		}
	}
	return vec3(mask, hole, calm_height);
}

// Sum of all water shapes at a rest position. Returns (height, dh/dx, dh/dz, calm); `foam` gets
// the white water they add. Must mirror water_shapes_eval() in water.gd and water_shapes.glsli.
//   dome: a = (x, z, width, height), b = (trough, calm, 0, foam)
//   ring: a = (x, z, radius, amplitude), b = (width, 0, 1, foam)
//   boil: a = (x, z, width, 0),          b = (0, 0, 2, foam)   (foam patch only, no height)
vec4 water_shapes_eval(vec2 p, out float foam) {
	vec4 result = vec4(0.0);
	foam = 0.0;
	for (int i = 0; i < water_shape_count; i++) {
		vec4 a = water_shape_a[i];
		vec4 b = water_shape_b[i];
		vec2 rel = p - a.xy;
		if (b.z < 0.5) {
			// Gaussian dome, with an optional trough ring around it: h = H e^-q (1 - t q).
			float w2 = a.z * a.z;
			float q = dot(rel, rel) / w2;
			if (q > 16.0) continue;
			float e = exp(-q);
			float h = a.w * e * (1.0 - b.x * q);
			vec2 grad = -a.w * e * (1.0 + b.x - b.x * q) * 2.0 * rel / w2;
			result.xyz += vec3(h, grad);
			result.w = max(result.w, b.y * e);
			foam = max(foam, b.w * clamp(length(grad) * 1.5, 0.0, 1.0)); // Water sheeting off steep flanks.
		} else if (b.z < 1.5) {
			// Gaussian swell travelling outwards.
			float r = length(rel);
			float u = (r - a.z) / b.x;
			if (abs(u) > 4.0) continue;
			float g = exp(-u * u);
			result.xyz += vec3(a.w * g, a.w * g * (-2.0 * u / b.x) * rel / max(r, 1e-3));
			// A swell only breaks where it is steep: real crests spill from a slope of ~0.3 (the
			// limit is ~0.44). Then a white line runs just ahead of the crest and leaves a fading
			// trail of spent foam behind it. A gentle swell stays clean, except that the sea's own
			// small waves break a little more readily riding its crest (gated by them in fragment()).
			float steep = abs(a.w) * 0.858 / b.x; // Steepest slope of the swell.
			float breaking = smoothstep(0.12, 0.35, steep);
			float lead = u - 0.35;
			float crest = lead > 0.0 ? exp(-lead * lead * 6.0) // the breaking line, bright
					: 0.55 * exp(-lead * lead * 4.0) + 0.45 * exp(-lead * lead * 0.6); // spent foam behind
			foam = max(foam, b.w * (breaking * crest + 0.25 * g));
		} else {
			// Churned water left where something went under.
			float q = dot(rel, rel) / (a.z * a.z);
			if (q > 16.0) continue;
			foam = max(foam, b.w * exp(-q));
		}
	}
	return result;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Gaps in the foam pattern: 0 in its foam cells, 1 in the open water between them. Two layers
// drifting apart so it never looks frozen or tiled. The pattern's red runs ~0.4 in the open
// water to ~0.9 in the foam.
float foam_gaps(vec2 uv, vec2 drift) {
	float p = texture(foam_pattern_tex, uv + drift).r * 0.7
	        + texture(foam_pattern_tex, uv * 2.7 - drift.yx * 1.8).r * 0.3;
	return 1.0 - smoothstep(0.4, 0.9, p);
}

// Light the UnderwaterGlow nodes throw into the water along a ray (origin o, unit dir d, `len`
// meters of water). Must mirror underwater_glow() in underwater_post.glsl, which explains it.
vec3 underwater_glow(vec3 o, vec3 d, float len) {
	vec3 sum = vec3(0.0);
	for (int i = 0; i < glow_count; i++) {
		vec4 a = glow_a[i];
		vec4 b = glow_b[i];
		vec3 to_light = a.xyz - o;
		float t0 = dot(to_light, d);
		float size = max(a.w, 0.01);
		float h = sqrt(max(dot(to_light, to_light) - t0 * t0, 0.0) + size * size);
		float along = (atan((len - t0) / h) + atan(t0 / h)) * size / (h * PI);
		float murk = 3.0 / max(b.w, 1.0);
		float fade = exp(-murk * (length(to_light) + max(h - size, 0.0)));
		sum += b.rgb * max(along, 0.0) * fade;
	}
	return sum;
}

vec3 scene_world_at(sampler2D depth_tex, vec2 uv, mat4 inv_proj, mat4 inv_view, out bool sky) {
	float d = textureLod(depth_tex, uv, 0.0).r;
	// Off the screen there is nothing to read: the depth there is whatever the far edge holds
	// (the hull beside you), placed along a ray it never lay on -- a point a metre from the lens,
	// which put contact foam on the water at the screen edges when standing at the rail.
	sky = d <= 0.0 || any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)));
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return (inv_view * vec4(v.xyz / v.w, 1.0)).xyz;
}

/**
 * Contact foam around anything the surface meets. `gap` is the distance (m) from this bit of
 * water to the nearest opaque surface near the waterline. Returns (foam, tint) amounts in 0..1.
 */
vec2 contact_foam_eval(float gap, vec2 world_xz, float time) {
	if (!contact_foam_enabled) return vec2(0.0);
	// A solid core out to a third of the width, fading out a third past it (the old linear ramp,
	// raised to 1.5, left only a thin line standing once the texture had eaten in).
	float near = 1.0 - smoothstep(0.3 * contact_foam_width, 1.3 * contact_foam_width, gap);
	float t = time * contact_foam_speed;
	// Cut from the same texture as the wave foam (foam_noise_tex), so the two read as one sea:
	// two reads at unrelated sizes and angles drifting apart, stretched back to its contrast.
	vec2 uv = world_xz / contact_foam_tile_size;
	float tex = texture(foam_noise_tex, uv + t * vec2(0.125, 0.09)).r * 0.6
			+ texture(foam_noise_tex, mat2(vec2(0.799, 0.602), vec2(-0.602, 0.799)) * uv * 0.413 + 0.37 - t * vec2(0.07, 0.11)).r * 0.4;
	float gaps = 1.0 - clamp(0.5 + (tex - 0.5) * 1.39, 0.0, 1.0);
	gaps = mix(0.5, gaps, foam_texture_strength); // A white (or no) texture leaves a plain band.
	// Rings: bands at fixed distances from the contact line, drifting outwards.
	float rings = 0.5 + 0.5 * sin(gap / contact_foam_width * 9.0 - time * 2.2 + gaps * 3.0);
	float shape = near + contact_foam_rings * rings * near * (1.0 - near) * 1.5;
	// The texture eats into the band from its outer edge, so its outline is the texture's own
	// shapes, and a softer ramp than before: the distance from the contact search is noisy, and a
	// hard cut turned that noise into pixels flicking on and off. Kept off 0 so the faint edge
	// of the search never turns into foam.
	float threshold = 0.1 + gaps * contact_foam_breakup;
	float foam = smoothstep(threshold, threshold + 0.35, shape);
	foam *= 1.0 - 0.35 * gaps; // The texture's gaps show through the solid core too.
	float tint = (1.0 - smoothstep(0.0, contact_tint_width, gap)) * contact_tint_strength;
	return vec2(clamp(foam * contact_foam_strength, 0.0, 1.0), tint);
}

void vertex() {
	UV = VERTEX.xz;
	float wake_churn = 0.0;
	float shape_foam;
	vec4 shape = water_shapes_eval(VERTEX.xz, shape_foam);
	vec3 blocker = wave_blocker_eval(VERTEX.xz);
	blocker_mask = blocker.x;
	blocker_hole = blocker.y;
	vec4 shore = shore_sample(VERTEX.xz);
	shore_depth = shore.xzy;
	// is optimized: first check if the distance is greater than 150 meters.
	// if so, then don't calculate the displacement.
	float distance_cam = length(VERTEX.xz - CAMERA_POSITION_WORLD.xz);
	if (distance_cam < 1024.0) // fall of to 0 at 600 meters
	{
		float distance_factor = min(exp(-(distance_cam-512.0)*0.007), 1.0); // Displacement amonut falls off after 256m.

		// Read displacements from displacement maps.
		vec3 displacement = vec3(0);
		for (uint i = 0U; i < num_cascades; ++i) {
			vec4 scales = map_scales[i];
			displacement += texture(displacements, vec3(UV*scales.xy, float(i))).xyz * scales.z
					* shore_damp(shore, 1.0 / scales.x); // the shallows calm the long waves first
		}
		wake_churn = wake_sample(VERTEX.xz).y; // world_vertex_coords: VERTEX is in world space.
		// Domes smooth out the waves riding on them; churned wake water is flatter too.
		float wave_scale = blocker_mask * (1.0 - shape.w) * (1.0 - wake_flatten * wake_churn);
		VERTEX += displacement * distance_factor * wave_scale;
		wave_height = displacement.y * distance_factor * wave_scale;
	}
	else
	{
		wave_height = 0.0;
	}
	// Calmed water lies on its blocker's calm plane: sea level by a shore, the swell under a ship.
	float calm_lift = blocker.z * (1.0 - blocker_mask);
	// Shore waves (no distance fade: the CPU never fades them either). Their slope comes from two
	// more looks half a metre away, only inside a shore zone. A calm zone calms them like any wave
	// (a hull's calm plane already follows them, see _wave_plane in water.gd).
	vec2 shore_wave_here = shore_wave(shore) * blocker_mask;
	shore_foam = shore_wave_here.y;
	shore_slope = vec2(0.0);
	if (shore.z > 0.0) {
		shore_slope = (vec2(shore_wave(shore_sample(VERTEX.xz + vec2(0.5, 0.0))).x,
				shore_wave(shore_sample(VERTEX.xz + vec2(0.0, 0.5))).x) * blocker_mask - shore_wave_here.x) * 2.0;
	}
	wave_height += shore_wave_here.x;
	VERTEX.y += shape.x + calm_lift + shore_wave_here.x;
}

/** Filter weights for a cubic B-spline. */
vec4 cubic_weights(float a) {
	float a2 = a*a;
	float a3 = a2*a;

	float w0 =-a3     + a2*3.0 - a*3.0 + 1.0;
	float w1 = a3*3.0 - a2*6.0         + 4.0;
	float w2 =-a3*3.0 + a2*3.0 + a*3.0 + 1.0;
	float w3 = a3;
	return vec4(w0, w1, w2, w3) / 6.0;
}

/** Performs bicubic B-spline filtering on the provided sampler. */
// Source: https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-20-fast-third-order-texture-filtering
vec4 texture_bicubic(in sampler2DArray sampler, in vec3 uvw) {
	vec2 dims = vec2(textureSize(sampler, 0).xy);
	vec2 dims_inv = 1.0 / dims;
	uvw.xy = uvw.xy*dims + 0.5;

	vec2 fuv = fract(uvw.xy);
	vec4 wx = cubic_weights(fuv.x);
	vec4 wy = cubic_weights(fuv.y);

	vec4 g = vec4(wx.xz + wx.yw, wy.xz + wy.yw);
	vec4 h = (vec4(wx.yw, wy.yw) / g + vec2(-1.5, 0.5).xyxy + floor(uvw.xy).xxyy)*dims_inv.xxyy;
	vec2 w = g.xz / (g.xz + g.yw);
	return mix(
		mix(texture(sampler, vec3(h.yw, uvw.z)), texture(sampler, vec3(h.xw, uvw.z)), w.x),
		mix(texture(sampler, vec3(h.yz, uvw.z)), texture(sampler, vec3(h.xz, uvw.z)), w.x), w.y);
}

/** Samples the screen with mirrored edges, so strongly bent rays don't smear the border pixels. */
vec3 screen_mirrored(in sampler2D tex, vec2 uv, float lod) {
	uv = 1.0 - abs(1.0 - abs(uv)); // Mirror into [0, 1] (valid for uv in [-1, 2]).
	return textureLod(tex, clamp(uv, vec2(0.001), vec2(0.999)), lod).rgb;
}

/**
 * Shades the water surface as seen from below: Snell's window + total internal reflection.
 * All vectors in view space. `n` is the surface normal facing the (underwater) camera.
 * Returns rgb = colour, a = average transmittance (how much of the air world is visible).
 */
vec4 shade_underside(vec3 view, vec3 n, vec2 screen_uv, float foam) {
	vec3 incident = -view;
	vec3 etas = water_ior + vec3(-1.0, 0.0, 1.0) * ior_dispersion;
	vec3 transmitted = vec3(0.0);
	vec3 transmittance = vec3(0.0);
	for (int c = 0; c < 3; c++) {
		vec3 t = refract(incident, n, etas[c]);
		if (dot(t, t) < 1e-6) continue; // Total internal reflection: nothing from above gets through.

		// Fresnel for the water->air interface must use the angle on the air side.
		float cos_t = clamp(dot(t, -n), 0.0, 1.0);
		float tr = 1.0 - (REFLECTANCE + (1.0 - REFLECTANCE) * pow(1.0 - cos_t, 5.0));
		// Bend the screen lookup by how far the refracted ray deviates from the straight one.
		vec2 bend = (t - incident).xy * window_refraction_strength;
		vec2 uv = screen_uv + vec2(bend.x, -bend.y);
		transmitted[c] = screen_mirrored(screen_texture, uv, (1.0 - cos_t) * window_edge_blur)[c];
		transmittance[c] = tr;
	}

	// Outside the window the surface is a mirror of the water column below it.
	vec3 color = transmitted * transmittance * window_brightness + underwater_color * underwater_light * (1.0 - transmittance);

	// Foam blocks the window: dark silhouettes against the sky, pale against the depths.
	// (foam can exceed 1 since foam_alpha sums over cascades; clamp so mix() can't overshoot.)
	float avg_t = dot(transmittance, vec3(1.0 / 3.0));
	color = mix(color, foam_color.rgb * mix(0.35, 0.12, avg_t), clamp(foam, 0.0, 1.0));

	// Absorption between the camera and the surface is applied by the underwater screen effect
	// (underwater_effect.gd), which also covers everything else seen underwater.
	return vec4(color, avg_t);
}

void fragment() {
	if (backface_culling && !FRONT_FACING) {
		discard;
	}
	if (blocker_hole > 0.5) {
		discard; // inside a HOLE wave blocker there is no water surface at all
	}
	if (dry_count > 0 && in_dry_volume((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz)) {
		discard; // inside a hull (DryVolume): the sea stops at its walls
	}
	float map_size = float(textureSize(normals, 0).x);
	float dist = length(VERTEX.xz);
	// Read foam and normal information from normal maps.
	vec3 gradient = vec3(0);
	float foam_alpha = 0.0;
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 coords = vec3(UV*scales.xy, float(i));
		float ppm = map_size * min(scales.x, scales.y); // Pixels per meter
		// Mix between bicubic and bilinear filtering depending on the world space pixels per meter.
		// This is dependent on the tile size as well as displacement/normal map resolution.
		// Bicubic is four extra reads, so it is skipped where the mix would throw it away anyway
		// (every cascade at 1024, the smallest one at 512). Same for the whole cascade, so no seams.
		float bilinear = min(1.0, ppm*0.1);
		vec4 normal_sample = texture(normals, coords);
		if (bilinear < 1.0) normal_sample = mix(texture_bicubic(normals, coords), normal_sample, bilinear);
		gradient += normal_sample.xyw * vec3(scales.ww, 1.0)
				* shore_damp(vec4(shore_depth.x, 0.0, shore_depth.y, 0.0), 1.0 / scales.x);
	}
	// Foam texture. The 3.0 keeps the foam exactly as strong as before for a white texture (this
	// used to be one stretched read per cascade, summed).
	// Two reads at unrelated sizes and angles, so the pattern never visibly repeats; the blend is
	// stretched back to the texture's own contrast.
	vec2 foam_uv = UV / foam_texture_tile_size;
	float foam_tex = texture(foam_noise_tex, foam_uv).r * 0.6
			+ texture(foam_noise_tex, mat2(vec2(0.799, 0.602), vec2(-0.602, 0.799)) * foam_uv * 0.413 + 0.37).r * 0.4;
	foam_tex = clamp(0.5 + (foam_tex - 0.5) * 1.39, 0.0, 1.0);
	foam_alpha = 3.0 * mix(1.0, foam_tex, foam_texture_strength);
	gradient *= blocker_mask; // calm zones lose their wave normals and foam too
	float shape_foam;
	vec4 shape = water_shapes_eval(UV, shape_foam);
	gradient.xy *= 1.0 - shape.w;
	// Rain: rings from drop impacts near the camera, and the smallest waves beaten flat.
	float rain_fade = rain_intensity * (1.0 - smoothstep(rain_ripple_distance * 0.6, rain_ripple_distance, length(VERTEX)));
	float rain_rings = 0.0;
	vec2 rain_slope = rain_fade > 0.001 ? rain_ripples(UV, TIME, rain_rings) * rain_fade : vec2(0.0);
	rain_rings *= rain_fade;
	gradient.xy *= 1.0 - rain_flatten * rain_intensity;
	rain_wet = rain_intensity * rain_matte;
	float wave_foam = smoothstep(0.0, 1.0, gradient.z*0.75);
	foam_factor = max(wave_foam * exp(-dist*0.0075), shore_foam * foam_tex);

	// A back face is the underside when WE are under the water, not when this particular scrap
	// of sea happens to sit above our eyes: that comparison is a horizontal plane at eye level,
	// and it cuts a hard line across the waves, dark above it and lit below.
	vec3 world_frag = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz; // used further down too
	underside = (!FRONT_FACING && camera_submersion > 0.0) ? 1.0 : 0.0;

	// Contact foam: distance to the nearest opaque surface near the waterline, found with a small
	// screen-space search around this pixel (plus the point straight behind it), so the foam rings
	// objects on all sides rather than only where they are seen through the water.
	float contact_gap = 1e6;
	if (contact_foam_enabled) {
		bool sky;
		vec3 behind = scene_world_at(depth_texture, SCREEN_UV, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX, sky);
		if (!sky) contact_gap = length(behind - world_frag);
		float reach = max(contact_foam_width * 2.0, contact_tint_width);
		// Only search where there can be something to find (see contact_shore_depth).
		bool search = !sky && world_frag.y - behind.y < contact_shore_depth; // Depth, not the slanted view ray.
		for (int i = 0; i < contact_body_count && !search; i++) {
			vec3 d = world_frag - contact_bodies[i].xyz;
			float r = contact_bodies[i].w + reach;
			search = dot(d, d) < r * r;
		}
		vec2 radius_uv = 0.5 * reach * vec2(PROJECTION_MATRIX[0][0], PROJECTION_MATRIX[1][1]) / max(-VERTEX.z, 0.1);
		radius_uv = min(radius_uv, vec2(0.08));
		// How far the sample pattern is turned: one random turn per 2x2 block of pixels, and each
		// pixel of the block a quarter step further round, so the four together cover four times
		// the samples. They pool their results below (a 2x2 blur). One turn for every
		// pixel draws the pattern's own lines along a hull instead; one per pixel alone was grain.
		vec2 cell = mod(floor(FRAGCOORD.xy), 2.0);
		float spin = hash12(floor(FRAGCOORD.xy * 0.5)) * 6.2832 + (cell.x + 2.0 * cell.y) * 0.6;
		// Terrain is not listed: four reads at the edge of the search catch a cliff or a headland,
		// which is all a coastline can be at this size. Small things are listed, so never missed.
		for (int i = 0; i < 4 && !search; i++) {
			float angle = float(i) * 1.5708 + spin;
			vec3 q = scene_world_at(depth_texture, SCREEN_UV + vec2(cos(angle), sin(angle)) * radius_uv, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX, sky);
			search = !sky && distance(q, world_frag) < reach * 2.0;
		}
		float soft = max(contact_foam_width * 0.3, 0.05);
		float pull = 0.0;
		float hits = 0.0;
		if (search) {
			// Every sample has a say, not just the nearest. Taking the nearest alone let one sample
			// landing on something by chance put a white speck there, so a hull's band was salt
			// grain (no TAA here to smooth it). Instead: how near the samples that found something
			// are (a soft minimum over them), and how many found it. Too few, and it is pushed out
			// of reach, gradually, so it changes smoothly from pixel to pixel.
			for (int i = 0; i < contact_foam_samples; i++) {
				float k = (float(i) + 0.5) / float(contact_foam_samples);
				float angle = float(i) * 2.39996 + spin; // Golden angle spiral.
				// Linear radius packs samples near the centre, where the foam edge needs precision.
				vec2 uv = SCREEN_UV + vec2(cos(angle), sin(angle)) * k * radius_uv;
				vec3 q = scene_world_at(depth_texture, uv, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX, sky);
				if (sky) continue;
				vec3 rel = q - world_frag;
				// Above-water parts count for less: hulls flare, waves bob. Below the water they count
				// for more: foam is where something breaks the surface, not over a body swimming a
				// metre down or a hull's flank under the waterline (which lit it up around the boat).
				rel.y *= rel.y > 0.0 ? 0.5 : 3.0;
				float d = length(rel);
				float found = 1.0 - smoothstep(0.5 * reach, reach, d);
				hits += found;
				pull += found * exp(-d / soft);
			}
		}
		// The 2x2 blur: each pixel adds what its neighbours in the block found (the GPU shades
		// pixels in 2x2 blocks and hands their differences over for free). Out here in plain
		// control flow, where every pixel of the block takes part.
		vec2 side = 1.0 - 2.0 * cell; // Towards the other pixel of the block, in x and y.
		float pull_x = pull + dFdxFine(pull) * side.x;
		float pull_y = pull + dFdyFine(pull) * side.y;
		float hits_x = hits + dFdxFine(hits) * side.x;
		float hits_y = hits + dFdyFine(hits) * side.y;
		float quad_pull = (pull + max(pull_x, 0.0) + max(pull_y, 0.0)) / 3.0;
		float quad_hits = (hits + max(hits_x, 0.0) + max(hits_y, 0.0)) / 3.0;
		if (quad_hits > 0.0) {
			float near_gap = -soft * log(max(quad_pull / quad_hits, 1e-6));
			float cover = quad_hits / float(max(contact_foam_samples, 1));
			contact_gap = min(contact_gap, near_gap + (1.0 - smoothstep(0.08, 0.3, cover)) * reach);
		}
	}
	// The shoreline's own band: the distance to it, scaled so contact foam's look (its core, rings
	// and lace) spans shore_foam_width. From the baked map, so it costs nothing and holds still.
	if (shore_foam_width > 0.0 && shore_depth.z < 1000.0) {
		contact_gap = min(contact_gap, max(shore_depth.z, 0.0) * contact_foam_width / shore_foam_width);
	}
	vec2 contact = contact_foam_eval(contact_gap, world_frag.xz, TIME);

	// Ship wake: foam cut from the foam pattern (two drifting layers), plus lighter churned water.
	vec2 wake = wake_sample(world_frag.xz);
	float wake_noise = foam_gaps(world_frag.xz / wake_foam_tile_size, TIME * vec2(0.004, 0.003));
	float wake_foam = smoothstep(wake_noise * wake_foam_breakup, wake_noise * wake_foam_breakup + 0.25, wake.x) * wake_foam_strength;
	wake_foam *= 1.0 - wake_foam_lace * wake_noise; // Keeps the lace visible in thick fresh foam too.
	contact.x = max(contact.x, wake_foam);
	// White water from the water shapes, cut into lace the same way. Where the sea's own waves
	// are cresting it holds on longest, so a weak swell only catches their whitecaps.
	if (shape_foam > 0.001) { // Its texture reads only where there is any.
		float shape_noise = foam_gaps(world_frag.xz / shape_foam_tile_size, TIME * vec2(0.006, -0.004)) * (1.0 - 0.7 * wave_foam);
		// A crest never breaks all along its length at once: big patches of it stay dark.
		float shape_patches = 1.0 - smoothstep(0.4, 0.9, texture(foam_pattern_tex, world_frag.xz / (shape_foam_tile_size * 7.0) + 0.21).r);
		float shape_threshold = 0.15 * (1.0 - wave_foam) + shape_noise * shape_foam_breakup + shape_patches * 0.5;
		float shape_white = smoothstep(shape_threshold, shape_threshold + 0.25, shape_foam);
		shape_white *= (1.0 - shape_foam_lace * shape_noise) * shape_foam_strength;
		contact.x = max(contact.x, shape_white);
	}
	gradient.xy *= 1.0 - wake_flatten * wake.y;

	if (underside > 0.5) {
		gradient *= mix(0.015, normal_strength, exp(-length(VERTEX)*0.0175));
		gradient.xy += shape.yz; // Water shapes are large and smooth, never faded with distance.
		gradient.xy += shore_slope; // So are the shore waves.
		gradient.xy += rain_slope * rain_underside_refraction;
		vec3 n_down = (VIEW_MATRIX * vec4(-normalize(vec3(-gradient.x, 1.0, -gradient.y)), 0.0)).xyz;
		vec4 under = shade_underside(VIEW, n_down, SCREEN_UV, max(foam_factor * foam_alpha * foam_alpha, contact.x));

		// Unlit: everything comes from the refracted/reflected light computed above.
		NORMAL = n_down;
		ALBEDO = vec3(0.0);
		// Rain seen from below: impact rings catch the light, brightest inside Snell's window.
		EMISSION = under.rgb * (1.0 + rain_rings * rain_underside_rings * (0.3 + 0.7 * under.a));
		SPECULAR = 0.0;
		ROUGHNESS = 1.0;
		RADIANCE = vec4(0.0, 0.0, 0.0, 1.0);
		IRRADIANCE = vec4(0.0, 0.0, 0.0, 1.0);
		ALPHA = 1.0;
		fresnel = 0.0;
	} else {
	// ===================== shine through ===================================#
	// Look through the surface along a ray bent by its slope. How far it bends depends on how
	// deep the thing behind lies -- a sea floor metres down swims about, something just under
	// the surface barely moves -- so read the depth straight through first, then bend by it.
	float depth_tex = texture(depth_texture, SCREEN_UV).r;
	vec4 world_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_tex, 1.0);
	world_pos.xyz /= world_pos.w;
	float through = clamp(VERTEX.z - world_pos.z, 0.0, 8.0); // meters of water in the way
	vec3 refr_n = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	vec2 look_uv = SCREEN_UV + (VIEW_MATRIX * vec4(refr_n, 0.0)).xy
			* surface_refraction * through / max(-VERTEX.z, 1.0);
	look_uv = clamp(look_uv, vec2(0.002), vec2(0.998));
	depth_tex = texture(depth_texture, look_uv).r;
	world_pos = INV_PROJECTION_MATRIX * vec4(look_uv * 2.0 - 1.0, depth_tex, 1.0);
	world_pos.xyz /= world_pos.w;
	if (world_pos.z > VERTEX.z) {
		// That sample sits in front of the water, so bending to it would drag something above
		// the surface down into it. Look straight through instead.
		look_uv = SCREEN_UV;
		depth_tex = texture(depth_texture, SCREEN_UV).r;
		world_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_tex, 1.0);
		world_pos.xyz /= world_pos.w;
	}
	// Soft edge where the water thins out over the sand. Measured straight down to the floor:
	// along the view it depends on the angle -- looking steeply down by your feet the path through
	// shallow water is short, further out at a grazing angle long -- which drew a ring of glassy
	// water (with a foam line on it) around the player that moved with them. Something above the
	// water behind it (a rock seen past a crest) keeps the old along-the-view edge.
	float behind_y = (INV_VIEW_MATRIX * vec4(world_pos.xyz, 1.0)).y;
	float smooth_alpha = behind_y < world_frag.y
			? smoothstep(0.0, 0.5, world_frag.y - behind_y)
			: 1.0 - smoothstep(world_pos.z + 0.66, world_pos.z, VERTEX.z);
	ALPHA *= clamp(smooth_alpha, 0.00, 1.0);
	if (ALPHA < 0.9){
		foam_factor = clamp(foam_factor + 0.5 - ALPHA, 0.0, 1.0);
	}

	// What survives the water in the way: each channel absorbed over the distance the light
	// travelled through it, so red goes first and the rest follows. Written this way on
	// purpose -- the old form floored the result at the water colour, so nothing under the
	// surface could ever read DARKER than the water, and anything lurking down there was
	// wiped out rather than showing as a shadow.
	vec3 screen_albedo = texture(screen_texture, look_uv, 0.0).rgb;
	// The whole way the light travels through the water, not just its depth along the view axis:
	// that shrinks as the view grazes the surface, and shallows seen at a slant went glassy.
	float through_water = VERTEX.z > world_pos.z ? length(world_pos.xyz - VERTEX) : 0.0;
	// The thin top of a wave is only a metre or so of water, however far the view goes on behind
	// it, so what stands above the sea beyond it (the sky, a hull) shows through it a little.
	// Not what lies below the surface: from above the sea, the view through a crest meets the next
	// wave, never the deep, and the deep must not darken it.
	float crest = crest_amount(wave_height);
	bool above_sea = depth_tex <= 0.0 || behind_y > world_frag.y - wave_height;
	float colour_path = above_sea
			? mix(through_water, min(through_water, 1.0), clamp(crest, 0.0, 1.0) * sss_see_through)
			: through_water;
	vec3 survives = exp(-colour_path / max(depth_color_consumption, vec3(0.01))) * water_clarity;
	// The sea's colour is light scattered back out of the water column, so it builds up with
	// depth rather than simply being there. Something lying in the way cuts the column short
	// and takes that glow with it -- which is what makes a body under the surface read as a
	// shadow instead of fading into the same flat colour as the open sea.
	float lit_column = 1.0 - exp(-colour_path / max(water_scatter_range, 0.1));	vec3 depth_water_color = screen_albedo * survives + water_color.rgb * lit_column;
	// ===================== shine through ===================================#
	depth_water_color = mix(depth_water_color, contact_tint_color, contact.y);
	depth_water_color = mix(depth_water_color, wake_tint_color, max(wake.y * wake_tint_strength, clamp(shape_foam, 0.0, 1.0) * shape_foam_tint));
	ALBEDO = mix(depth_water_color, foam_color.rgb, foam_factor * foam_alpha * foam_alpha);
	ALBEDO = mix(ALBEDO, foam_color.rgb, contact.x);
	// A dark mass under the water swallows the light that would come back up through it, so
	// the surface above goes dim -- foam and all. This is what turns something down there
	// from a smudge into a shadow.
	float blocking = exp(-through_water / max(submerged_shadow_range, 1.0))
			* clamp(1.0 - dot(screen_albedo, vec3(0.3333)), 0.0, 1.0);
	ALBEDO *= 1.0 - blocking * submerged_shadow;
	METALLIC = metallic * (1.0 - clamp(max(foam_factor * foam_alpha * foam_alpha, contact.x), 0.0, 1.0));
	foam_factor = max(foam_factor, contact.x); // Contact foam is matte and lit like foam too.
	// Fresnel needs the wave normal, so it is worked out at the end, once NORMAL is set.
	vec3 emission_glow = vec3(0.0); // Added once fresnel is known.

	// Underwater glows seen through the surface: the lit water along the view ray, bent down
	// into the sea, for as far as the ray goes before it hits something. Foam is in the way.
	if (glow_count > 0 && glow_above_water > 0.0) {
		vec3 view_ray = normalize(world_frag - CAMERA_POSITION_WORLD);
		vec3 into_sea = refract(view_ray, normalize(vec3(-gradient.x, 1.0, -gradient.y)), 1.0 / water_ior);
		if (dot(into_sea, into_sea) < 0.5) into_sea = view_ray;
		float water_len = depth_tex > 0.0 ? min(length(world_pos.xyz - VERTEX), 2000.0) : 2000.0; // 0 = nothing behind.
		vec3 glow = underwater_glow(world_frag, into_sea, water_len);
		emission_glow = glow * glow_above_water * (1.0 - clamp(foam_factor * foam_alpha * foam_alpha, 0.0, 1.0));
	}

	gradient *= mix(0.015, normal_strength, exp(-dist*0.0175)); // Blend normal with terrain normal as distance increases.
	gradient.xy += shape.yz; // Water shapes are large and smooth, never faded with distance.
	gradient.xy += shore_slope; // So are the shore waves.
	gradient.xy += rain_slope;
	vec3 world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	NORMAL = (VIEW_MATRIX * vec4(world_normal, 0.0)).xyz;

	// Translucency: where the sun comes through the thin top of a wave towards the eye, the water
	// is lit from behind by light that has lost its red, so its colour turns paler and greener.
	// Only the colour changes; the lighting is the same as everywhere else. A little of it stays
	// in high crests from any side. Foam covers it.
	if (crest > 0.0 && sss_strength > 0.0) {
		vec3 to_eye = normalize(CAMERA_POSITION_WORLD - world_frag);
		vec3 bent = normalize(sss_sun.xyz + world_normal * sss_distortion);
		float back = pow(clamp(dot(-to_eye, bent), 0.0, 1.0), sss_power) * sss_sun.w;
		float thin = 0.5 - 0.5 * dot(sss_sun.xyz, world_normal); // Turned from the sun: lit from behind.
		float shift = clamp(crest * (back * thin * thin + sss_crest_glow) * sss_strength, 0.0, 1.0);
		float foam_cover = clamp(max(foam_factor * foam_alpha * foam_alpha, contact.x), 0.0, 1.0);
		ALBEDO = mix(ALBEDO, sss_color, shift * (1.0 - foam_cover));
	}

	// How much of the sky each bit of wave mirrors, from its own slope: a face turned away
	// from us catches more of it than one turned towards us.
	float wet_roughness = mix(roughness, max(roughness, 0.85), rain_wet); // Rain: matte, hazy surface.
	float facing = clamp(dot(VIEW, NORMAL), 0.0, 1.0);
	fresnel = mix(pow(1.0 - facing, 5.0*exp(-2.69*wet_roughness)) / (1.0 + 22.7*pow(wet_roughness, 1.5)), 1.0, REFLECTANCE);
	// `roughness` is a microfacet slope (GGX alpha, ~Cox-Munk), Godot's ROUGHNESS its square root.
	// Foam is matte, more so where little sky is mirrored.
	ROUGHNESS = clamp(sqrt(wet_roughness) + (1.0 - fresnel) * foam_factor, 0.0, 1.0);
	EMISSION += emission_glow * (1.0 - fresnel);
	}
}

float smith_masking_shadowing(in float cos_theta, in float alpha) {
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta*cos_theta)); // Approximate: 1.0 / (alpha * tan(acos(cos_theta)))
	float a_sq = a*a;
	return a < 1.6 ? (1.0 - 1.259*a + 0.396*a_sq) / (3.535*a + 2.181*a_sq) : 0.0;
}

// Source: https://github.com/godotengine/godot/blob/7b56111c297f24304eb911fe75082d8cdc3d4141/drivers/gles3/shaders/scene.glsl#L995
float ggx_distribution(in float cos_theta, in float alpha) {
	float a_sq = alpha*alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d*d);
}

void light() {
	if (underside < 0.5) { // Underside is fully shaded in fragment().
		vec3 halfway = normalize(LIGHT + VIEW);
		float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
		float dot_nv = max(dot(NORMAL, VIEW), 2e-5);

		// --- SPECULAR ---
		float wet_roughness = mix(roughness, max(roughness, 0.85), rain_wet);
		float light_mask = smith_masking_shadowing(wet_roughness, dot_nv);
		float view_mask = smith_masking_shadowing(wet_roughness, dot_nl);
		float microfacet_distribution = ggx_distribution(dot(NORMAL, halfway), wet_roughness);
		float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
		// LIGHT_COLOR is colour * energy * PI; divided back out so a light of energy 1 glints as it
		// always did, a dim moon barely at all and a warm lamp warm.
		SPECULAR_LIGHT += fresnel * microfacet_distribution * geometric_attenuation / (4.0 * dot_nv + 0.1) * ATTENUATION
				* LIGHT_COLOR / PI * light_reflection;

		// --- DIFFUSE ---
		const vec3 sss_modifier = vec3(0.9,1.15,0.85); // Subsurface scattering produces a 'greener' color.
		float sss_near = 0.5*pow(dot_nv, 2.0);
		float lambertian = 0.5*dot_nl;
		DIFFUSE_LIGHT += mix(sss_near * sss_modifier / (1.0 + light_mask) + lambertian, foam_color.rgb, foam_factor) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
		// Translucency: the light coming through the thin top of a wave lights its far side, like
		// any light lights a surface (it falls on the colour fragment() turned it, so it is never
		// brighter than the light itself). Lamps light crests from behind the same way.
		float crest = crest_amount(wave_height);
		if (crest > 0.0) {
			float back = pow(clamp(dot(-VIEW, normalize(LIGHT + NORMAL * sss_distortion)), 0.0, 1.0), sss_power);
			float thin = 0.5 - 0.5 * dot(LIGHT, NORMAL);
			DIFFUSE_LIGHT += min(crest, 1.0) * back * thin * thin * sss_strength * (1.0 - fresnel) * (1.0 - foam_factor)
					* ATTENUATION * LIGHT_COLOR;
		}
	}
}
