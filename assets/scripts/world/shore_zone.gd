@tool
class_name ShoreZone
extends Path3D
## A stretch of coast where the sea runs into the shallows and washes up the beach.
##
## Draw its outline with this Path3D's points, seen from above: heights and curve handles are
## ignored and the last point joins the first. Then press Bake: it reads the sea floor under the
## outline (Terrain3D plus any static collision, eg. the stony beach) and stores, per texel,
##   r: depth of the sea floor below sea level (m, negative on dry land),
##   g: distance to the shoreline (m, positive out to sea, negative inland),
##   b: how much of the zone applies (0 at the outline, 1 once edge_fade inside it),
##   a: a slow noise that staggers the waves along the coast.
## water.gd hands the map to the water shader, the underwater effect and get_wave_height(), and
## all three work the waves out from it the same way: the ocean's own waves die down as the
## water gets shallow, and shore waves roll in, steepen and run up the sand.
## Bake again whenever the outline or the terrain under it changes.

const MAX_SIZE := 1024 # texels per side
const DEEP := 400.0 # depth given where nothing was found below (m)
const SAVE_DIR := 'res://assets/water/shore/'

@export_tool_button('Bake', 'Bake') var bake_button: Callable = bake
## Size of one texel of the baked map (m). Smaller follows the shoreline more closely.
@export_range(0.25, 4.0, 0.05, 'suffix:m') var texel_size := 1.0
## The zone fades in over this distance inside its outline, so its edge never shows (m).
@export_range(0.0, 100.0, 0.5, 'suffix:m') var edge_fade := 25.0
## Blur of the shoreline distance (texels): rounds off the crests' kinks around rocks and coves.
@export_range(0, 16) var shore_smoothing := 4
## Things the bake looks straight through, as if they were not there (with everything under
## them). Piers and other decks standing over open water are skipped on their own.
@export var ignore: Array[Node3D] = []
@export_group('Baked')
## The baked map (see the class description). Saved next to the other shore maps.
@export var baked: Image
## World XZ area the map covers: position = its corner, size = its extent (m).
@export var baked_rect := Rect2()

var texture: ImageTexture

func _ready() -> void:
	add_to_group(&'shore_zone')
	if baked and not Engine.is_editor_hint():
		texture = ImageTexture.create_from_image(baked)

## World XZ area the baked map covers (stored in the map itself; baked_rect for older maps).
func map_rect() -> Rect2:
	return baked.get_meta(&'rect', baked_rect) if baked else baked_rect

## The outline in world XZ.
func outline() -> PackedVector2Array:
	var poly := PackedVector2Array()
	if not curve: return poly
	for i in curve.point_count:
		var p := global_transform * curve.get_point_position(i)
		poly.append(Vector2(p.x, p.z))
	return poly

func bake() -> void:
	var poly := outline()
	if poly.size() < 3:
		push_warning('ShoreZone "%s": draw at least 3 points before baking.' % name)
		return
	var t0 := Time.get_ticks_msec()
	var bb := Rect2(poly[0], Vector2.ZERO)
	for p in poly: bb = bb.expand(p)
	var texel := maxf(texel_size, maxf(bb.size.x, bb.size.y) / float(MAX_SIZE - 2))
	bb = bb.grow(texel)
	var w := ceili(bb.size.x / texel)
	var h := ceili(bb.size.y / texel)
	var n := w * h
	var sea_level := 0.0
	var water := get_tree().get_first_node_in_group(&'water') as Node3D if is_inside_tree() else null
	if water: sea_level = water.global_position.y

	# Sea floor under every texel centre.
	var depth := PackedFloat64Array()
	depth.resize(n)
	var terrain := _find_terrain()
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.new()
	query.collide_with_areas = false
	var ignore_rids: Array[RID] = []
	for node in ignore:
		if node is CollisionObject3D: ignore_rids.append(node.get_rid())
		if node: for body in node.find_children('*', 'CollisionObject3D', true, false): ignore_rids.append(body.get_rid())
	for y in h:
		for x in w:
			var pos := bb.position + Vector2(x + 0.5, y + 0.5) * texel
			var floor_y := -INF
			if terrain:
				var th: float = terrain.data.get_height(Vector3(pos.x, 0.0, pos.y))
				if not is_nan(th): floor_y = th
			query.from = Vector3(pos.x, sea_level + 150.0, pos.y)
			query.to = Vector3(pos.x, sea_level - DEEP, pos.y)
			query.exclude = ignore_rids
			for attempt in 6:
				var hit := space.intersect_ray(query)
				if hit.is_empty(): break
				var top: float = hit.position.y
				if _is_afloat(hit.collider) or _is_deck(space, hit, pos, top):
					query.exclude = query.exclude + [hit.rid] # boats, the player, piers: not the ground
					continue
				floor_y = maxf(floor_y, top)
				break
			depth[y * w + x] = clampf(sea_level - floor_y, -50.0, DEEP) if floor_y > -INF else DEEP
	depth = _blur(depth, w, h, 1)

	# Signed distance to the shoreline: out to sea from the nearest dry texel, inland from the
	# nearest wet one.
	var land := PackedByteArray()
	var sea := PackedByteArray()
	land.resize(n)
	sea.resize(n)
	for i in n:
		land[i] = 1 if depth[i] <= 0.0 else 0
		sea[i] = 1 - land[i]
	var to_land := _distance_field(land, w, h)
	var to_sea := _distance_field(sea, w, h)
	var shore := PackedFloat64Array()
	shore.resize(n)
	for i in n:
		var d := (sqrt(to_land[i]) - 0.5) if land[i] == 0 else -(sqrt(to_sea[i]) - 0.5)
		shore[i] = clampf(d * texel, -200.0, 2000.0)
	shore = _blur(_blur(shore, w, h, shore_smoothing), w, h, shore_smoothing)

	# Fade in from the outline.
	var outside := PackedByteArray()
	outside.resize(n)
	for y in h:
		for x in w:
			var pos := bb.position + Vector2(x + 0.5, y + 0.5) * texel
			outside[y * w + x] = 0 if Geometry2D.is_point_in_polygon(pos, poly) else 1
	var to_outside := _distance_field(outside, w, h)

	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0 / 90.0
	noise.fractal_octaves = 2
	noise.seed = hash(name)

	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBAH)
	for y in h:
		for x in w:
			var i := y * w + x
			var pos := bb.position + Vector2(x + 0.5, y + 0.5) * texel
			var inside := 0.0
			if outside[i] == 0:
				var d := (sqrt(to_outside[i]) - 0.5) * texel
				inside = smoothstep(0.0, edge_fade, d) if edge_fade > 0.0 else 1.0
			img.set_pixel(x, y, Color(depth[i], shore[i], inside, clampf(0.5 + 0.5 * noise.get_noise_2dv(pos), 0.0, 1.0)))

	baked_rect = Rect2(bb.position, Vector2(w, h) * texel)
	img.set_meta(&'rect', baked_rect) # travels with the map, so the two can never disagree
	if Engine.is_editor_hint():
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)
		var path := SAVE_DIR + '%s_%s.res' % [owner.name if owner else 'scene', name]
		ResourceSaver.save(img, path)
		img.take_over_path(path)
	baked = img
	texture = ImageTexture.create_from_image(img)
	print('ShoreZone "%s": baked %dx%d texels of %.2f m in %d ms.' % [name, w, h, texel, Time.get_ticks_msec() - t0])

## Something that moves about: a boat (its decks are StaticBody3D pieces inside the hull's
## RigidBody3D), the player. Never the ground.
static func _is_afloat(collider: Object) -> bool:
	var node := collider as Node
	while node:
		if node is RigidBody3D or node is CharacterBody3D or node is AnimatableBody3D:
			return true
		node = node.get_parent()
	return false

## A pier, jetty or anything else standing over open water: below its underside the ray drops
## more than half a metre before it meets the next thing. Waves run under it, not up it.
static func _is_deck(space: PhysicsDirectSpaceState3D, hit: Dictionary, pos: Vector2, top: float) -> bool:
	var below := PhysicsRayQueryParameters3D.create(Vector3(pos.x, top - 0.01, pos.y), Vector3(pos.x, top - DEEP, pos.y))
	below.exclude = [hit.rid]
	var next := space.intersect_ray(below)
	var ground: float = next.position.y if not next.is_empty() else top - DEEP
	# From that ground straight up: the first thing met is the underside, if there is a gap.
	var up := PhysicsRayQueryParameters3D.create(Vector3(pos.x, ground + 0.02, pos.y), Vector3(pos.x, top + 0.01, pos.y))
	var under := space.intersect_ray(up)
	return not under.is_empty() and under.rid == hit.rid and under.position.y - ground > 0.5

func _find_terrain() -> Node:
	var root := get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().current_scene
	if not root: root = get_tree().root
	var found := root.find_children('*', 'Terrain3D', true, false)
	return found[0] if not found.is_empty() else null

## Squared distance (texels) from every texel to the nearest one where mask is 1
## (Felzenszwalb & Huttenlocher, columns then rows).
static func _distance_field(mask: PackedByteArray, w: int, h: int) -> PackedFloat64Array:
	const FAR := 1e12
	var f := PackedFloat64Array()
	f.resize(w * h)
	for i in w * h: f[i] = 0.0 if mask[i] else FAR
	var line := PackedFloat64Array()
	line.resize(h)
	for x in w:
		for y in h: line[y] = f[y * w + x]
		line = _distance_1d(line)
		for y in h: f[y * w + x] = line[y]
	line.resize(w)
	for y in h:
		for x in w: line[x] = f[y * w + x]
		line = _distance_1d(line)
		for x in w: f[y * w + x] = line[x]
	return f

static func _distance_1d(f: PackedFloat64Array) -> PackedFloat64Array:
	var n := f.size()
	var d := PackedFloat64Array()
	d.resize(n)
	var v := PackedInt32Array()
	v.resize(n)
	var z := PackedFloat64Array()
	z.resize(n + 1)
	var k := 0
	v[0] = 0
	z[0] = -INF
	z[1] = INF
	for q in range(1, n):
		var s := ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0 * (q - v[k]))
		while s <= z[k]:
			k -= 1
			s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0 * (q - v[k]))
		k += 1
		v[k] = q
		z[k] = s
		z[k + 1] = INF
	k = 0
	for q in n:
		while z[k + 1] < q: k += 1
		d[q] = (q - v[k]) * (q - v[k]) + f[v[k]]
	return d

## Box blur of the given radius (texels), edges clamped.
static func _blur(src: PackedFloat64Array, w: int, h: int, r: int) -> PackedFloat64Array:
	if r <= 0: return src
	var tmp := PackedFloat64Array()
	tmp.resize(w * h)
	var out := PackedFloat64Array()
	out.resize(w * h)
	var inv := 1.0 / (2 * r + 1)
	for y in h: # running sums: a window slides along each row, then each column
		var row := y * w
		var s := 0.0
		for o in range(-r, r + 1): s += src[row + clampi(o, 0, w - 1)]
		for x in w:
			tmp[row + x] = s * inv
			s += src[row + mini(x + r + 1, w - 1)] - src[row + maxi(x - r, 0)]
	for x in w:
		var s := 0.0
		for o in range(-r, r + 1): s += tmp[clampi(o, 0, h - 1) * w + x]
		for y in h:
			out[y * w + x] = s * inv
			s += tmp[mini(y + r + 1, h - 1) * w + x] - tmp[maxi(y - r, 0) * w + x]
	return out
