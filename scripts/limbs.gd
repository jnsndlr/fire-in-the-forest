extends RefCounted

# Procedural bark limbs: tapered tubes that curve up toward the light and fork
# into smaller limbs, merged into one mesh. Used for the twigs on walkable
# branches and the limbs that fan up into each crown.

const SIDES = 7
const STEPS = 4

static func grow(tool: SurfaceTool, from: Vector3, direction: Vector3, length: float, radius: float, depth: int, rng: RandomNumberGenerator, tips: Array):
	var points = [from]
	var radii = [radius]
	var dir = direction.normalized()
	var bend = Vector3(rng.randfn()*0.12, 0.07, rng.randfn()*0.05)
	var end_radius = radius*(0.55 if depth > 0 else 0.2)
	for k in range(1, STEPS+1):
		dir = (dir + bend).normalized()
		points.append(points[-1] + dir*length/STEPS)
		radii.append(lerpf(radius, end_radius, float(k)/STEPS))
	tube(tool, points, radii)
	if depth == 0:
		tips.append(points[-1])
		return
	# The leader carries on from the end; one or two side limbs split off partway,
	# turned mostly within the side-view plane so the silhouette reads.
	grow(tool, points[-1], dir.rotated(_axis(rng), rng.randf_range(-0.35,0.35)), length*rng.randf_range(0.6,0.75), end_radius, depth-1, rng, tips)
	var flip = 1.0 if rng.randf() < 0.5 else -1.0
	for c in range(rng.randi_range(1,2)):
		var k = rng.randi_range(2, STEPS-1)
		var angle = flip*rng.randf_range(0.45,0.85)
		flip = -flip
		var side = dir.rotated(_axis(rng), angle)
		grow(tool, points[k], side, length*rng.randf_range(0.45,0.6), radii[k]*0.7, depth-1, rng, tips)

static func _axis(rng: RandomNumberGenerator) -> Vector3:
	return Vector3(rng.randfn()*0.35, rng.randfn()*0.35, 1.0).normalized()

static func tube(tool: SurfaceTool, points: Array, radii: Array):
	# Rings along the path, closed to a point at the end.
	var rings = []
	for i in range(points.size()):
		var along = (points[mini(i+1, points.size()-1)] - points[maxi(i-1, 0)]).normalized()
		var reference = Vector3.BACK if absf(along.z) < 0.9 else Vector3.UP
		var u = along.cross(reference).normalized()
		var v = along.cross(u)
		var ring = []
		for s in range(SIDES):
			var a = TAU*s/SIDES
			ring.append(u*cos(a) + v*sin(a))
		rings.append(ring)
	for i in range(points.size()-1):
		for s in range(SIDES):
			var n = (s+1) % SIDES
			for corner in [[i,s],[i+1,s],[i+1,n],[i,s],[i+1,n],[i,n]]:
				var normal = rings[corner[0]][corner[1]]
				tool.set_normal(normal)
				tool.add_vertex(points[corner[0]] + normal*radii[corner[0]])
	var last = points.size()-1
	var cap = points[last] + (points[last]-points[last-1]).normalized()*radii[last]
	for s in range(SIDES):
		var n = (s+1) % SIDES
		for corner in [s, -1, n]:
			var normal = rings[last][corner] if corner >= 0 else (cap-points[last]).normalized()
			tool.set_normal(normal)
			tool.add_vertex(cap if corner < 0 else points[last] + normal*radii[last])
