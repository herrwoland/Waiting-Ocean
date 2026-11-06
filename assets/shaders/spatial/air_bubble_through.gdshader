shader_type spatial;
// First pass of an air bubble: dims what's behind it, colour by colour, for the bubble's skin and
// for the water between the bubble and that. See air_bubble.gdshader.
render_mode blend_mul, unshaded, depth_draw_never, cull_back, fog_disabled;

#include "air_bubble.gdshaderinc"

void fragment() {
	vec3 lost, veil;
	bubble_water_behind(VERTEX, SCREEN_UV, INV_VIEW_MATRIX, INV_PROJECTION_MATRIX, lost, veil);
	ALBEDO = (1.0 - bubble_opacity(NORMAL, VIEW)) * lost;
}
