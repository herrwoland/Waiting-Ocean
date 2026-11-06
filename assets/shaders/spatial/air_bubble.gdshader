shader_type spatial;
// See-through things in the water, like air bubbles.
//
// The underwater screen effect fogs every pixel by the distance in the depth buffer. A bubble
// that doesn't write depth gets fogged as if it were as far as what's behind it (usually lost in
// the murk); one that does write depth gets fogged right, but then whatever shows through it gets
// only the bubble's share of fog, a clear window onto things far behind. So a bubble is two passes,
// drawn after the water surface (render priority above mat_water's 0):
//   1. air_bubble_through.gdshader (priority 1, this material's next_pass) multiplies what's behind
//      by what gets through the skin and through the water between, red going first;
//   2. this one (priority 2) adds the lit skin and the fog over that stretch, and writes depth.
// The screen effect then fogs the lot by the bubble's distance, and what's seen through it comes
// out as fogged as it would without the bubble. Opacity is per bubble (instance uniform), so both
// passes share it. Fog values come from water.gd.
render_mode blend_add, depth_draw_always, cull_back;

#include "air_bubble.gdshaderinc"

/** Colour of the skin. Per bubble (AirBubble.color sets it). */
instance uniform vec3 tint : source_color = vec3(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.06;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	vec3 lost, veil;
	bubble_water_behind(VERTEX, SCREEN_UV, INV_VIEW_MATRIX, INV_PROJECTION_MATRIX, lost, veil);
	float a = bubble_opacity(NORMAL, VIEW);
	ALBEDO = tint * a;
	EMISSION = (1.0 - a) * veil;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = specular * a;
	ALPHA = 1.0;
}
