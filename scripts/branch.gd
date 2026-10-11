extends Node3D

# A springy, walkable branch. The squirrel runs along its top surface directly
# (no physics collider), so the surface can curve, taper and flex. The tip sags
# under load and rebounds; a jump on the upswing or near the tip gains height.

const SEGMENTS = 6
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

func setup(forest: Node3D, tree_node: Node3D, base: Vector3, branch_side: float, branch_length: float, bark: Color, rng: RandomNumberGenerator):
	tree = tree_node
	side = branch_side
	length = branch_length
	position = base
	rise = rng.randf_range(0.15,0.6)
	droop = rng.randf_range(0.05,0.5)
	kink = rng.randf_range(-0.25,0.35)
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
	# A short twig and leaf clusters ride along the bending branch.
	var twig = _rider(rng.randf_range(0.45,0.65))
	forest.limb(twig, Vector3.ZERO, Vector3(side*rng.randf_range(0.5,0.9),rng.randf_range(0.6,1.0),-0.35), 0.06, bark)
	for t in [0.62, 0.82, 1.0]:
		var leaves = _rider(t)
		forest.leaf_crown(leaves, [[Vector3(rng.randf_range(-0.3,0.3),rng.randf_range(0.45,0.85),rng.randf_range(-1.3,-0.7)), Vector3(rng.randf_range(0.8,1.3),0.5,0.75)]])
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
