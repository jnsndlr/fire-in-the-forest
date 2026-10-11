extends Node3D

# A springy, walkable branch. The squirrel runs along its top surface directly
# (no physics collider), so the surface can curve, taper and flex. The tip sags
# under load and rebounds; a jump on the upswing or near the tip gains height.
# Forking twigs with leaves at their tips ride along the bending branch.

const LIMBS = preload("res://scripts/limbs.gd")

const SEGMENTS = 8
const STIFFNESS = 220.0
const DAMPING = 3.5
const SAG = 0.16
const MIN_DEFLECTION = -0.9
const MAX_DEFLECTION = 0.6
const START = 0.35 # walkable surface begins just outside the trunk

var tree: Node3D
var side = 1.0
var length = 5.0
var rise = 0.3
var droop = 0.2
var kink = 0.0
var wiggle_phase = 0.0
var root_radius = 0.2
var tip_radius = 0.06
var deflection = 0.0
var speed = 0.0
var load_at = -1.0
var load_weight = 1.0
var segments: Array[MeshInstance3D] = []
var riders: Array[Node3D] = []

func setup(forest: Node3D, tree_node: Node3D, base: Vector3, branch_side: float, branch_length: float, bark: Color, rng: RandomNumberGenerator, lift := 0.0, twig_rng: RandomNumberGenerator = rng):
	# lift (0..1) tilts the branch upward: higher branches climb out of the trunk
	# and level off toward the tip, like a real crown reaching for light.
	tree = tree_node
	side = branch_side
	length = branch_length
	position = base
	rise = rng.randf_range(0.15,0.6) + lift*length*rng.randf_range(0.3,0.45)
	droop = rng.randf_range(0.05,0.5) + lift*length*0.15
	kink = rng.randf_range(-0.25,0.35)*(1.0-lift*0.6)
	wiggle_phase = rng.randf_range(0,TAU)
	var material = forest.paint(bark, {"moss": 1.0, "moss_color": forest.MOSS_LIGHT, "grain_scale": Vector3(0.35,3.5,3.5)})
	for i in range(SEGMENTS):
		var mesh = CylinderMesh.new()
		mesh.height = 1.0
		mesh.bottom_radius = radius(float(i)/SEGMENTS)
		mesh.top_radius = radius(float(i+1)/SEGMENTS)
		mesh.radial_segments = 10
		mesh.rings = 1
		var node = MeshInstance3D.new()
		node.mesh = mesh
		node.material_override = material
		add_child(node)
		segments.append(node)
	# Side twigs fork off along the outer half (more of them on higher branches),
	# and a fan of twigs carries the line on past the walkable tip. They grow up and
	# back from the branch, so the running surface and the squirrel stay clear.
	var stops = [1.0]
	for k in range(2 + roundi(lift*2.0)):
		stops.append(lerpf(0.3, 0.9, (k + twig_rng.randf_range(0.2,0.8))/(2.0 + roundi(lift*2.0))))
	for t in stops:
		var rider = _rider(t)
		var tool = SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		var tips = []
		var tip = t == 1.0
		var count = 2 if tip else 1
		for c in range(count):
			# Tip twigs carry on along the branch's own line; side twigs vary from
			# reaching steeply up to angling out and slightly down.
			var direction: Vector3
			if tip:
				var along = _point(1.0) - _point(0.9)
				direction = (along.normalized() + Vector3(0, c*0.5, -twig_rng.randf_range(0.1,0.4))).normalized()
			else:
				var up = twig_rng.randf_range(-0.15,1.2)
				direction = Vector3(side*cos(up), sin(up), -twig_rng.randf_range(0.1,0.7))
			var size = lerpf(1.0, 0.6, t)
			LIMBS.grow(tool, Vector3.ZERO, direction, twig_rng.randf_range(1.0,1.5)*size + (0.6 if tip else 0.0), radius(t)*0.75, 1 if size < 0.8 or twig_rng.randf() < 0.5 else 2, twig_rng, tips)
		var twigs = MeshInstance3D.new()
		twigs.mesh = tool.commit()
		twigs.material_override = material
		rider.add_child(twigs)
		var clumps = []
		for at in tips:
			clumps.append([at + Vector3(0,0.15,-0.2), Vector3(twig_rng.randf_range(0.55,0.8),twig_rng.randf_range(0.35,0.5),0.55)])
		forest.leaf_crown(rider, clumps)
	_refresh()

func _rider(t: float) -> Node3D:
	var node = Node3D.new()
	node.set_meta("t", t)
	add_child(node)
	riders.append(node)
	return node

func shape(t: float) -> float:
	# Cantilever bend profile: 0 at the trunk, 1 at the tip.
	return t*t*(3.0-t)*0.5

func radius(t: float) -> float:
	return lerpf(root_radius, tip_radius, t)

func _point(t: float) -> Vector3:
	# Rise, droop and a mid-branch elbow give each branch its own natural bend.
	var y = rise*t - droop*t*t + kink*sin(t*PI) + deflection*shape(t)
	var z = sin(t*3.0 + wiggle_phase)*0.12*t
	return Vector3(side*length*t, y, z)

func t_at(x: float) -> float:
	return clampf((x - position.x)*side/length, 0.0, 1.0)

func contains(x: float) -> bool:
	var u = (x - position.x)*side
	return u >= START and u <= length

func tip_x() -> float:
	return position.x + side*length

func surface_y(x: float) -> float:
	var t = t_at(x)
	return position.y + _point(t).y + radius(t)*0.9

func surface_speed(x: float) -> float:
	return speed*shape(t_at(x))

func carry(x: float, weight: float):
	load_at = t_at(x)
	load_weight = weight

func release():
	load_at = -1.0

func impulse(x: float, amount: float):
	speed += amount*shape(t_at(x))

func _physics_process(delta):
	var target = -SAG*load_weight*shape(load_at) if load_at >= 0 else 0.0
	if absf(speed) < 0.002 and absf(deflection-target) < 0.0005:
		return
	speed += (-STIFFNESS*(deflection-target) - DAMPING*speed)*delta
	deflection = clampf(deflection + speed*delta, MIN_DEFLECTION, MAX_DEFLECTION)
	_refresh()

func _refresh():
	for i in range(SEGMENTS):
		var a = _point(float(i)/SEGMENTS)
		var b = _point(float(i+1)/SEGMENTS)
		var axis = b - a
		var across = axis.cross(Vector3.FORWARD).normalized()
		var out = across.cross(axis.normalized())
		# Slight overlap hides seams at the bends.
		segments[i].transform = Transform3D(Basis(across, axis*1.06, out), (a+b)*0.5)
	for rider in riders:
		rider.position = _point(rider.get_meta("t"))
