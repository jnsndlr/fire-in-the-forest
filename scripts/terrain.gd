extends RefCounted

# Landform for the creekside: the play strip (|z| <= 2.5) stays flat at y=0, the
# forest floor rolls up into hills behind it, and water courses (meandering
# brooks, a curving foreground river, a pond) are carved in. Water surfaces sit
# WATER_DEPTH below the uncarved land, and hills flatten near water so streams
# always run downhill.

const PLAY_HALF_DEPTH = 2.5
const WATER_DEPTH = 0.45
const BED_DEPTH = 1.2
const CELL = 0.5
const AREA = Rect2(-80, -95, 300, 127)
# x ranges where water crosses the play line (no ground collision there).
const GAPS = [Vector2(8,12), Vector2(42,45), Vector2(78,84)]

var noise := FastNoiseLite.new()
var courses = []  # {"points": PackedVector2Array of (x,z), "half_widths": PackedFloat32Array, "brook": bool}
var pools = []    # {"center": Vector2, "radii": Vector2}
var distance := PackedFloat32Array()
var columns = 0
var rows = 0

func _init(seed: int):
	noise.seed = seed
	noise.frequency = 0.025
	noise.fractal_octaves = 3
	_brook(10.0, 2.0, 1.1, 0.0, -80.0, 5.0, 0.3)
	_brook(43.5, 1.5, 0.9, 0.0, -80.0, 4.0, 2.1)
	_brook(81.0, 3.0, 3.0, 4.0, -6.0, 0.0, 0.0) # pond inlet across the play line
	_brook(86.0, 1.2, 0.9, -14.0, -80.0, 4.5, 4.0) # feeds the pond from the hills
	_river()
	pools.append({"center": Vector2(81,-10), "radii": Vector2(10,5.5)})
	pools.append({"center": Vector2(89,-15), "radii": Vector2(6,3.5)})
	_rasterize()

func _brook(x0: float, near: float, far: float, z_start: float, z_end: float, meander: float, phase: float):
	var points = PackedVector2Array()
	var widths = PackedFloat32Array()
	# Starts in the river (when crossing the play line) and winds back into the hills.
	var z = river_z(x0) if z_start >= 0 else z_start
	while z >= z_end:
		var wander = smoothstep(3.0, 22.0, -z)
		var x = x0 + meander*wander*(sin(z*0.13 + phase) + 0.5*sin(z*0.31 + phase*2.0))
		points.append(Vector2(x, z))
		widths.append(lerpf(near, far, smoothstep(-2.0, -40.0, z)))
		z -= 1.5
	courses.append({"points": points, "half_widths": widths, "brook": true})

func river_z(x: float) -> float:
	# Zig-zags along the foreground; sometimes hugging the play strip's bank, sometimes
	# leaving a strip of floor. Bends off toward the camera at both ends.
	var z = 6.3 + 2.0*sin(x*0.16) + 0.9*sin(x*0.37 + 1.0)
	return z + maxf(0.0, -2.0 - x)*0.9 + maxf(0.0, x - 62.0)*0.9

func _river():
	var points = PackedVector2Array()
	var widths = PackedFloat32Array()
	var x = -16.0
	while x <= 74.0:
		points.append(Vector2(x, river_z(x)))
		widths.append(2.3 + 0.8*sin(x*0.17))
		x += 1.5
	courses.append({"points": points, "half_widths": widths, "brook": false})

func _rasterize():
	# Signed distance to the nearest water edge on a grid (negative = in water),
	# written only near each course so the cost stays small.
	columns = int(AREA.size.x/CELL) + 1
	rows = int(AREA.size.y/CELL) + 1
	distance.resize(columns*rows)
	distance.fill(99.0)
	for course in courses:
		var points: PackedVector2Array = course["points"]
		var widths: PackedFloat32Array = course["half_widths"]
		for i in range(points.size()-1):
			var a = points[i]
			var b = points[i+1]
			var reach = maxf(widths[i], widths[i+1]) + 3.0
			_stamp(Rect2(a, Vector2.ZERO).expand(b).grow(reach), func(p: Vector2):
				var ab = b - a
				var t = clampf((p-a).dot(ab)/ab.length_squared(), 0.0, 1.0)
				return p.distance_to(a + ab*t) - lerpf(widths[i], widths[i+1], t))
	for pool in pools:
		var c: Vector2 = pool["center"]
		var r: Vector2 = pool["radii"]
		_stamp(Rect2(c - r, r*2).grow(3.0), func(p: Vector2):
			var wobble = 1.0 + 0.12*noise.get_noise_2d(p.x*3.0, p.y*3.0)
			return ((p - c)/r).length()*minf(r.x, r.y) - minf(r.x, r.y)*wobble)

func _stamp(bounds: Rect2, signed_distance: Callable):
	var i0 = maxi(0, int((bounds.position.x - AREA.position.x)/CELL))
	var i1 = mini(columns-1, int((bounds.end.x - AREA.position.x)/CELL) + 1)
	var j0 = maxi(0, int((bounds.position.y - AREA.position.y)/CELL))
	var j1 = mini(rows-1, int((bounds.end.y - AREA.position.y)/CELL) + 1)
	for j in range(j0, j1+1):
		for i in range(i0, i1+1):
			var p = AREA.position + Vector2(i, j)*CELL
			var index = j*columns + i
			distance[index] = minf(distance[index], signed_distance.call(p))

func water_distance(x: float, z: float) -> float:
	var fx = clampf((x - AREA.position.x)/CELL, 0.0, columns - 1.001)
	var fz = clampf((z - AREA.position.y)/CELL, 0.0, rows - 1.001)
	var i = int(fx)
	var j = int(fz)
	var tx = fx - i
	var tz = fz - j
	var top = lerpf(distance[j*columns + i], distance[j*columns + i + 1], tx)
	var bottom = lerpf(distance[(j+1)*columns + i], distance[(j+1)*columns + i + 1], tx)
	return lerpf(top, bottom, tz)

func is_water(x: float, z: float, margin = 0.0) -> bool:
	return water_distance(x, z) < margin

func in_gap(x: float) -> bool:
	for gap in GAPS:
		if x > gap.x and x < gap.y: return true
	return false

func land(x: float, z: float) -> float:
	# Uncarved ground: flat play strip, gentle front, hills rising behind.
	if z >= 0.0:
		# Front bank rises gently toward the camera so the world's edge never shows.
		return 0.9*smoothstep(9.0, 16.0, z) + 3.0*smoothstep(16.0, 32.0, z)
	var rise = pow(smoothstep(-4.0, -80.0, z), 1.3)*12.0
	var hills = (noise.get_noise_2d(x, z)*0.5 + 0.5)*5.0*smoothstep(-5.0, -28.0, z)
	# Keep stream valleys monotonic so water never runs uphill.
	return rise + hills*smoothstep(1.0, 7.0, water_distance(x, z))

func height(x: float, z: float) -> float:
	var carve = 1.0 - smoothstep(-0.6, 0.9, water_distance(x, z))
	var h = land(x, z) - carve*BED_DEPTH
	if absf(z) < PLAY_HALF_DEPTH and not in_gap(x):
		h = minf(h, -0.6) # hidden beneath the play-strip ground boxes
	return h

func water_level(x: float, z: float) -> float:
	return land(x, z) - WATER_DEPTH

func ground_mesh() -> ArrayMesh:
	return _grid(func(x, z): return height(x, z), func(_a, _b, _c, _d): return true, false)

func water_mesh() -> ArrayMesh:
	# Only quads near water; UV.x carries water depth so the shader can draw shoreline foam.
	var wet = func(a, b, c, d): return minf(minf(a, b), minf(c, d)) < 1.0
	return _grid(func(x, z): return water_level(x, z), wet, true)

func _axis(start: float, end: float, fine_start: float, fine_end: float, fine: float, coarse: float) -> PackedFloat32Array:
	# Fine spacing where the camera looks closely, coarse in the far hills.
	var values = PackedFloat32Array()
	var v = start
	while v < end:
		values.append(v)
		v += fine if v >= fine_start and v < fine_end else coarse
	values.append(end)
	return values

func _grid(height_at: Callable, keep: Callable, water: bool) -> ArrayMesh:
	var xs = _axis(AREA.position.x, AREA.end.x, -34.0, 145.0, 0.6, 2.0)
	var zs = _axis(AREA.position.y, AREA.end.y, -32.0, 16.0, 0.5, 2.0)
	var tool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var heights = PackedFloat32Array()
	var wets = PackedFloat32Array()
	for z in zs:
		for x in xs:
			heights.append(height_at.call(x, z))
			wets.append(water_distance(x, z))
	var index = 0
	var lookup = PackedInt32Array()
	lookup.resize(xs.size()*zs.size())
	lookup.fill(-1)
	for j in range(zs.size()-1):
		for i in range(xs.size()-1):
			var corners = [j*xs.size()+i, j*xs.size()+i+1, (j+1)*xs.size()+i+1, (j+1)*xs.size()+i]
			if not keep.call(wets[corners[0]], wets[corners[1]], wets[corners[2]], wets[corners[3]]): continue
			for k in corners:
				if lookup[k] == -1:
					var x = xs[k % xs.size()]
					var z = zs[k / xs.size()]
					if water: tool.set_uv(Vector2(clampf(heights[k] - height(x, z), 0.0, 2.0), 0.0))
					tool.add_vertex(Vector3(x, heights[k], z))
					lookup[k] = index
					index += 1
			tool.add_index(lookup[corners[0]])
			tool.add_index(lookup[corners[1]])
			tool.add_index(lookup[corners[2]])
			tool.add_index(lookup[corners[0]])
			tool.add_index(lookup[corners[2]])
			tool.add_index(lookup[corners[3]])
	tool.generate_normals()
	return tool.commit()

func bank_samples(step: float) -> Array:
	# Points just outside each water course's edges (position, outward direction).
	var samples = []
	for course in courses:
		var points: PackedVector2Array = course["points"]
		var widths: PackedFloat32Array = course["half_widths"]
		for i in range(points.size()-1):
			var a = points[i]
			var b = points[i+1]
			var along = (b - a).normalized()
			var side = Vector2(-along.y, along.x)
			var count = maxi(1, int(a.distance_to(b)/step))
			for k in range(count):
				var t = float(k)/count
				var p = a.lerp(b, t)
				var w = lerpf(widths[i], widths[i+1], t)
				for s in [-1.0, 1.0]:
					var at = p + side*s*(w + 0.15)
					if not is_water(at.x, at.y, -0.05): samples.append([at, side*s])
	for pool in pools:
		var c: Vector2 = pool["center"]
		var r: Vector2 = pool["radii"]
		var count = int(r.x*2.0)
		for k in range(count):
			var angle = TAU*k/count
			var direction = Vector2(cos(angle), sin(angle))
			var at = c + direction*r*1.03
			if not is_water(at.x, at.y, -0.05): samples.append([at, direction])
	return samples

func rapids() -> Array:
	# Spots along the brooks, back in the hills, for small foam rapids across the stream.
	var spots = []
	for course in courses:
		if not course["brook"]: continue
		var points: PackedVector2Array = course["points"]
		var widths: PackedFloat32Array = course["half_widths"]
		for i in range(4, points.size()-1, 5):
			if points[i].y < -8.0:
				spots.append([points[i], (points[i+1]-points[i]).normalized(), widths[i]])
	return spots
