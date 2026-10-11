extends Node3D

const PIGMENT = preload("res://shaders/pigment.gdshader")
const LEAF_SHADER = preload("res://shaders/leaf.gdshader")
const LEAF_SPRIG = preload("res://assets/sprites/leaf_sprig.png")
const PLAYER = preload("res://scripts/squirrel.gd")
const BRANCH = preload("res://scripts/branch.gd")
const TERRAIN = preload("res://scripts/terrain.gd")
const TRUNK_KIT = preload("res://assets/trees/trunk_kit.glb")
const SEGMENT_HEIGHT = 4.0
const CAMERA_FOV = 30.0
const CAMERA_PITCH = 9.0
const CAMERA_DISTANCE = 15.0
const GLIDE_DISTANCE = 18.5
const OVERVIEW_DISTANCE = 36.0
const WATER_Y = -0.45
const ROCK = Color("a8877a")
const MOSS = Color("85994d")
const MOSS_LIGHT = Color("a8b46a")
const LEAF = Color("7f9550")
const LEAF_LIGHT = Color("b3bd74")
var rng = RandomNumberGenerator.new()
var leaf_rng = RandomNumberGenerator.new() # separate so leaf cards don't shift the level layout
var materials: Dictionary = {}
var sphere: SphereMesh
var branches: Array[Node3D] = []
var terrain
var trunk_pieces = {"base": [], "mid": [], "top": [], "lean": [], "fork": []}
var player: CharacterBody3D
var camera: Camera3D
var stamina_bar: ProgressBar
var state_label: Label
var checkpoint_label: Label
var controls: Label
var glide_pulse = 0.0
var camera_target = Vector3.ZERO
var camera_distance = CAMERA_DISTANCE
var look_ahead = 1.3
var elapsed = 0.0
var checkpoint_index = 0
var checks = [Vector3(-6,0.6,0),Vector3(12.6,0.6,0),Vector3(32,0.6,0),Vector3(50,0.6,0),Vector3(86,0.6,0),Vector3(118,0.6,0)]
var smoke_test = false
var capture_frames = 0

func _ready():
	rng.seed = 8246
	leaf_rng.seed = 5113
	var args = OS.get_cmdline_user_args()
	smoke_test = "--smoke-test" in args
	sphere = SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 18
	sphere.rings = 9
	_inputs()
	_load_trunk_kit()
	_environment()
	_terrain()
	_trees()
	_sunbeams()
	player = CharacterBody3D.new()
	player.name = "Squirrel"
	player.set_script(PLAYER)
	add_child(player)
	camera = Camera3D.new()
	camera.fov = CAMERA_FOV
	camera.far = 260
	camera.current = true
	# The camera follows the interpolated squirrel in _process, so it is not itself interpolated.
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera)
	_sky()
	_hud()
	for arg in args:
		if arg.begins_with("--at="):
			var at = arg.trim_prefix("--at=").split_floats(",")
			player.position = Vector3(at[0], at[1], 0)
	# Distant scenery doesn't need to cast shadows.
	for node in find_children("*","MeshInstance3D",true,false):
		if node.global_position.z < -10: node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	reset_camera()
	if smoke_test: _smoke_sequence.call_deferred()

func _inputs():
	var bindings = {"left":[KEY_A,KEY_LEFT],"right":[KEY_D,KEY_RIGHT],"up":[KEY_W,KEY_UP],"down":[KEY_S,KEY_DOWN],"jump":[KEY_SPACE],"attach":[KEY_E],"glide":[KEY_SHIFT],"restart":[KEY_R],"overview":[KEY_Q],"help":[KEY_H],"quit":[KEY_ESCAPE]}
	for action in bindings:
		InputMap.add_action(action)
		for key in bindings[action]:
			var event = InputEventKey.new()
			event.physical_keycode = key
			InputMap.action_add_event(action,event)

# options map directly to pigment shader uniforms: moss, moss_color, lump, rim, grain_scale.
func paint(color: Color, options := {}) -> ShaderMaterial:
	var key = color.to_html() + str(options)
	if not materials.has(key):
		var material = ShaderMaterial.new()
		material.shader = PIGMENT
		material.set_shader_parameter("paint_color",color)
		for option in options:
			material.set_shader_parameter(option,options[option])
		materials[key] = material
	return materials[key]

func flat(color: Color, additive = false) -> StandardMaterial3D:
	var key = "flat" + color.to_html() + str(additive)
	if not materials.has(key):
		var material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = color
		if additive:
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		materials[key] = material
	return materials[key]

func ellipsoid(parent: Node3D, at: Vector3, radii: Vector3, color: Color, options := {}) -> MeshInstance3D:
	var node = MeshInstance3D.new()
	node.mesh = sphere
	node.material_override = paint(color, options)
	node.position = at
	node.scale = radii
	parent.add_child(node)
	return node

func rock(parent: Node3D, at: Vector3, radii: Vector3, mossy = 1.0) -> MeshInstance3D:
	return ellipsoid(parent, at, radii, ROCK, {"moss": mossy, "moss_color": MOSS, "lump": 0.35})

func foliage(parent: Node3D, at: Vector3, radii: Vector3, color = LEAF, light = LEAF_LIGHT) -> MeshInstance3D:
	return ellipsoid(parent, at, radii, color, {"moss": 1.0, "moss_color": light, "lump": 0.45})

func leaf_material(color: Color, light: Color) -> ShaderMaterial:
	var key = "leaf" + color.to_html() + light.to_html()
	if not materials.has(key):
		var material = ShaderMaterial.new()
		material.shader = LEAF_SHADER
		material.set_shader_parameter("leaves",LEAF_SPRIG)
		material.set_shader_parameter("paint_color",color)
		material.set_shader_parameter("light_color",light)
		materials[key] = material
	return materials[key]

func add_leaf_clump(tool: SurfaceTool, center: Vector3, radii: Vector3):
	# A clump of leaf cards scattered through an ellipsoid at random angles. Normals
	# point away from the clump centre so it shades as one soft volume; vertex colour
	# R records how far out each vertex sits (0 centre, 1 surface) for interior shade.
	var count = int(20.0*(radii.x*radii.y + radii.y*radii.z + radii.x*radii.z))
	for k in range(count):
		var direction = Vector3(leaf_rng.randfn(),leaf_rng.randfn(),leaf_rng.randfn()).normalized()
		var at = center + direction*radii*sqrt(leaf_rng.randf_range(0.15,1.0))
		var face = (direction + Vector3(leaf_rng.randfn(),leaf_rng.randfn(),leaf_rng.randfn())*0.8).normalized()
		var across = face.cross(Vector3.UP if absf(face.y) < 0.9 else Vector3.RIGHT).normalized().rotated(face, leaf_rng.randf_range(0,TAU))
		var up = face.cross(across)
		var half = leaf_rng.randf_range(0.55,0.85)*clampf(radii.y+0.2,0.6,1.0)
		var flip = 1.0 if leaf_rng.randf() < 0.5 else -1.0
		var corners = [Vector2(-1,-1),Vector2(1,-1),Vector2(1,1),Vector2(-1,1)]
		for i in [0,1,2,0,2,3]:
			var c = corners[i]
			var vertex = at + (across*c.x*flip + up*c.y)*half
			var offset = (vertex - center)/radii
			tool.set_normal(offset.normalized())
			tool.set_color(Color(clampf(offset.length(),0,1),0,0))
			tool.set_uv(Vector2(c.x*0.5+0.5, 0.5-c.y*0.5))
			tool.add_vertex(vertex)

func leaf_crown(parent: Node3D, clumps: Array, color = LEAF, light = LEAF_LIGHT, shadow = true) -> MeshInstance3D:
	# clumps: [[center, radii], ...] merged into one leaf mesh. The cards themselves
	# don't cast shadows (they'd flicker and self-shadow); a shrunken ellipsoid proxy
	# per clump still drops the crown's shadow on the ground.
	var tool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var proxy = SurfaceTool.new()
	proxy.begin(Mesh.PRIMITIVE_TRIANGLES)
	for clump in clumps:
		add_leaf_clump(tool, clump[0], clump[1])
		proxy.append_from(sphere, 0, Transform3D(Basis.from_scale(clump[1]*0.6), clump[0]))
	var node = MeshInstance3D.new()
	node.mesh = tool.commit()
	node.material_override = leaf_material(color, light)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	if shadow:
		var caster = MeshInstance3D.new()
		caster.mesh = proxy.commit()
		caster.material_override = flat(Color.BLACK)
		caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		node.add_child(caster)
	return node

func box(at: Vector3, size: Vector3, color: Color, solid = false, options := {}) -> Node3D:
	var root: Node3D = StaticBody3D.new() if solid else Node3D.new()
	root.position = at
	add_child(root)
	var mesh = MeshInstance3D.new()
	var cube = BoxMesh.new()
	cube.size = size
	mesh.mesh = cube
	mesh.material_override = paint(color, options)
	root.add_child(mesh)
	if solid: _collider(root, size)
	return root

func _collider(body: Node3D, size: Vector3):
	var collision = CollisionShape3D.new()
	var shape = BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)

func limb(parent: Node3D, a: Vector3, b: Vector3, radius: float, color: Color, options := {}):
	var node = MeshInstance3D.new()
	var mesh = CylinderMesh.new()
	mesh.top_radius = radius*0.64
	mesh.bottom_radius = radius
	mesh.height = a.distance_to(b)
	mesh.radial_segments = 10
	mesh.rings = 1
	node.mesh = mesh
	node.material_override = paint(color, options)
	parent.add_child(node)
	node.position = (a+b)*0.5
	var axis = (b-a).normalized()
	var side = axis.cross(Vector3.FORWARD).normalized()
	if side.length_squared()<0.1: side = Vector3.RIGHT
	node.basis = Basis(side,axis,side.cross(axis).normalized())

func _environment():
	var world = WorldEnvironment.new()
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("f1e6cf")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Lavender-rose ambient gives shaded sides the reference's soft pink-violet cast.
	env.ambient_light_color = Color("cdbcbf")
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.environment = env
	add_child(world)
	var sun = DirectionalLight3D.new()
	add_child(sun)
	sun.look_at_from_position(Vector3(6,9,5), Vector3.ZERO)
	sun.light_color = Color("ffe3bf")
	sun.light_energy = 0.42
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.55
	sun.directional_shadow_max_distance = 70

func _sky():
	var backdrop = MeshInstance3D.new()
	var quad = QuadMesh.new()
	quad.size = Vector2(340,220)
	backdrop.mesh = quad
	var material = ShaderMaterial.new()
	material.shader = preload("res://shaders/sky.gdshader")
	backdrop.material_override = material
	backdrop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	backdrop.position = Vector3(0,0,-200)
	camera.add_child(backdrop)

func _sunbeams():
	var material = ShaderMaterial.new()
	material.shader = preload("res://shaders/sunbeam.gdshader")
	var x = -26.0
	while x < 150:
		var beam = MeshInstance3D.new()
		var quad = QuadMesh.new()
		quad.size = Vector2(rng.randf_range(1.5,5.0),70)
		beam.mesh = quad
		beam.material_override = material
		beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		beam.position = Vector3(x,14,rng.randf_range(-16,-3))
		beam.rotation.z = -0.62
		add_child(beam)
		x += rng.randf_range(4,11)

func _terrain():
	# Landform and water courses live in terrain.gd; this places them and dresses them.
	terrain = TERRAIN.new(8246)
	var floor_material = ShaderMaterial.new()
	floor_material.shader = preload("res://shaders/floor.gdshader")
	var ground = MeshInstance3D.new()
	ground.mesh = terrain.ground_mesh()
	ground.material_override = floor_material
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)
	var water = MeshInstance3D.new()
	water.mesh = terrain.water_mesh()
	var water_material = ShaderMaterial.new()
	water_material.shader = preload("res://shaders/water.gdshader")
	water.material_override = water_material
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)
	# The play strip is flat ground with collision, broken only where water crosses.
	var edges = [terrain.AREA.position.x]
	for gap in terrain.GAPS: edges.append_array([gap.x, gap.y])
	edges.append(terrain.AREA.end.x)
	for k in range(0, edges.size(), 2):
		var strip = MeshInstance3D.new()
		var cube = BoxMesh.new()
		cube.size = Vector3(edges[k+1]-edges[k], 2.4, terrain.PLAY_HALF_DEPTH*2)
		strip.mesh = cube
		strip.material_override = floor_material
		var body = StaticBody3D.new()
		body.position = Vector3((edges[k]+edges[k+1])/2, -1.2, 0)
		add_child(body)
		body.add_child(strip)
		_collider(body, cube.size)
	for x in [9.0,10.5,43.3,80.0,82.0]:
		var stone = StaticBody3D.new()
		stone.position = Vector3(x,-0.5,0)
		add_child(stone)
		_collider(stone, Vector3(0.85,1.0,1.4))
		rock(stone, Vector3(0,0.05,0), Vector3(0.55,0.5,0.8), 0.9)
		foam(Vector3(x,WATER_Y,0), Vector2(0.62,0.9), true)
	_banks()
	_floor_props()
	_sprites()
	for point in checks:
		limb(self,point-Vector3(0,0.6,0.65),point+Vector3(0,0.7,-0.65),0.055,Color("7d5f4b"))
		var bulb = MeshInstance3D.new()
		bulb.mesh = sphere
		bulb.material_override = flat(Color("ffe2a0"))
		bulb.position = point+Vector3(0,0.75,-0.65)
		bulb.scale = Vector3(0.13,0.17,0.13)
		add_child(bulb)
		var halo = MeshInstance3D.new()
		halo.mesh = sphere
		halo.material_override = flat(Color(0.16,0.11,0.04), true)
		halo.position = bulb.position
		halo.scale = Vector3.ONE*0.32
		add_child(halo)

func _banks():
	# Rocks and plants crowd every water edge to break up the shoreline. The play line
	# (|z| < 1.8) stays clear so the gaps read cleanly.
	for sample in terrain.bank_samples(1.2):
		var p: Vector2 = sample[0]
		var out: Vector2 = sample[1]
		if absf(p.y) < 1.8 or rng.randf() < 0.2: continue
		var at = p + out*rng.randf_range(-0.1,0.5)
		var y = terrain.height(at.x, at.y)
		var r = rng.randf_range(0.3,1.0)
		rock(self, Vector3(at.x, y-0.12, at.y), Vector3(r*1.25, r*0.7, r))
		var roll = rng.randf()
		var plant = p + out*rng.randf_range(0.6,1.6)
		var plant_y = terrain.height(plant.x, plant.y)
		if roll < 0.3: fern(Vector3(plant.x, plant_y, plant.y), rng.randf_range(0.6,1.1))
		elif roll < 0.55: foliage(self, Vector3(plant.x, plant_y+0.1, plant.y), Vector3(0.7,0.45,0.6), Color("7a904f"), MOSS_LIGHT)
		elif roll < 0.62: mushrooms(Vector3(plant.x, plant_y, plant.y))
	# Little rapids where brooks run down out of the hills.
	for rapid in terrain.rapids():
		var p: Vector2 = rapid[0]
		var along: Vector2 = rapid[1]
		var y = terrain.water_level(p.x, p.y)
		for k in range(3):
			var spot = p + along*(k*0.5) + Vector2(-along.y, along.x)*rng.randf_range(-0.4,0.4)
			foam(Vector3(spot.x, y, spot.y), Vector2(0.1, rapid[2]*rng.randf_range(0.5,0.9)), false, -along.angle())
		for s in [-1.0, 1.0]:
			var side = p + Vector2(-along.y, along.x)*s*(rapid[2]*0.9)
			rock(self, Vector3(side.x, y-0.1, side.y), Vector3(0.5,0.4,0.45))

func _floor_props():
	# Large tilted slabs and boulders on the rising hills behind the play line.
	for i in range(22):
		var at = _spot(-26,-9)
		var r = rng.randf_range(2.0,3.4)
		var slab = rock(self, at + Vector3(0,r*0.2,0), Vector3(r*1.5,r*0.7,r*0.9))
		slab.rotation = Vector3(0,rng.randf_range(-0.5,0.5),rng.randf_range(-0.35,0.35))
	for i in range(100):
		var at = _spot(-30,-3.5)
		var r = rng.randf_range(0.6,1.7)
		rock(self, at - Vector3(0,0.25,0), Vector3(r*1.2,r*0.75,r*0.85))
	# Small round moss-capped stones scattered over the floor, in front and behind.
	for i in range(220):
		var at = _spot(-20,-2.8) if i%3 else _spot(3,12)
		var r = rng.randf_range(0.22,0.6)
		ellipsoid(self, at - Vector3(0,0.05,0), Vector3(r*1.1,r*0.8,r), ROCK, {"moss": 1.4, "moss_color": MOSS, "lump": 0.3})
	for i in range(9):
		var at = _spot(-22,-8)
		var length = rng.randf_range(5,9)
		var angle = rng.randf_range(-0.6,0.6)
		var end = Vector3(at.x + cos(angle)*length, 0, at.z + sin(angle)*length*0.5)
		end.y = terrain.height(end.x, end.z) + rng.randf_range(0.4,1.6)
		limb(self, at + Vector3(0,0.2,0), end, 0.45, Color("9a6e5a"), {"moss": 1.0, "moss_color": MOSS, "grain_scale": Vector3(3,3,0.4)})
	for i in range(140):
		var at = _spot(-14,-2.8) if i%2 else _spot(2.8,11)
		fern(at, rng.randf_range(0.5,1.0))
	for i in range(36):
		var at = _spot(-10,-2.8) if i%2 else _spot(2.8,8)
		mushrooms(at)
	# Bushy clumps on the slopes so the floor never reads as bare.
	for i in range(140):
		var at = _spot(-24,-3)
		foliage(self, at + Vector3(0,0.15,0), Vector3(rng.randf_range(0.8,1.6),rng.randf_range(0.5,0.9),0.8), Color("7f9550") if i%2 else Color("8d9a58"), LEAF_LIGHT)
	# Ground cover along the play strip, kept low so landings stay readable.
	for i in range(240):
		var x = rng.randf_range(-22,130)
		var z = rng.randf_range(0.8,2.3) if i%2==0 else rng.randf_range(-2.4,-0.8)
		if terrain.in_gap(x) or terrain.is_water(x,z,0.4): continue
		foliage(self, Vector3(x,0.04,z), Vector3(0.32,0.18,0.28), MOSS if i%3 else Color("a2ab68"), MOSS_LIGHT)
		if i%2==0: flowers(Vector3(x,0.16,z))
	for i in range(200):
		flowers(_spot(-12,10) + Vector3(0,0.03,0))
	# Low foreground framing below the play line.
	for i in range(34):
		var at = _spot(7,12)
		foliage(self, at - Vector3(0,0.4,0), Vector3(rng.randf_range(1.0,1.8),0.7,0.8), Color("7a904f"), MOSS_LIGHT)

func _spot(z0: float, z1: float, x0 = -30.0, x1 = 140.0) -> Vector3:
	# A random dry point on the forest floor (off the play strip), at ground height.
	for attempt in range(30):
		var x = rng.randf_range(x0,x1)
		var z = rng.randf_range(z0,z1)
		if absf(z) < terrain.PLAY_HALF_DEPTH or terrain.is_water(x, z, 1.0): continue
		return Vector3(x, terrain.height(x, z), z)
	return Vector3(x0, terrain.height(x0, z0), z0)

func _sprites():
	# Painted cards (tools/blender/sprites.py) fill the far hills cheaply: one
	# MultiMesh draw per texture. The camera is a fixed side view, so cards simply face it.
	var layers = [
		["tree", ["tree_a","tree_b","tree_c","tree_d"], 320, Vector2(-90,-30), Vector2(-90,220), Vector2(16,30), 0.5],
		["bush", ["bush_a","bush_b","bush_c"], 700, Vector2(-48,-5), Vector2(-60,180), Vector2(3,6), 2.0],
		["fern", ["fern_a","fern_b"], 420, Vector2(-30,-4), Vector2(-40,160), Vector2(1.4,2.4), 1.0],
	]
	for layer in layers:
		var names: Array = layer[1]
		var placements = []
		for name in names: placements.append([])
		for i in range(layer[2]):
			var z = rng.randf_range(layer[3].x, layer[3].y)
			var x = rng.randf_range(layer[4].x, layer[4].y)
			if terrain.is_water(x, z, 0.8): continue
			var size = rng.randf_range(layer[5].x, layer[5].y)
			# aspect = width/height of the painted card; size is its larger side.
			var aspect: float = layer[6]
			var card = Vector3(size*minf(aspect,1.0), size/maxf(aspect,1.0), 1.0)
			var at = Vector3(x, terrain.height(x, z) - card.y*0.04, z)
			var shade = rng.randf_range(0.88,1.05)
			placements[i % names.size()].append([Transform3D(Basis.from_scale(card), at), Color(shade, shade, shade*rng.randf_range(0.95,1.03))])
		for k in range(names.size()):
			var quad = QuadMesh.new()
			quad.center_offset = Vector3(0,0.5,0)
			var multimesh = MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.use_colors = true
			multimesh.mesh = quad
			multimesh.instance_count = placements[k].size()
			for i in range(placements[k].size()):
				multimesh.set_instance_transform(i, placements[k][i][0])
				multimesh.set_instance_color(i, placements[k][i][1])
			var image = load("res://assets/sprites/%s.png" % names[k]).get_image()
			image.generate_mipmaps()
			var material = ShaderMaterial.new()
			material.shader = preload("res://shaders/sprite.gdshader")
			material.set_shader_parameter("sprite", ImageTexture.create_from_image(image))
			var cards = MultiMeshInstance3D.new()
			cards.multimesh = multimesh
			cards.material_override = material
			cards.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(cards)

func fern(at: Vector3, size: float):
	var fronds = rng.randi_range(5,8)
	for k in range(fronds):
		var angle = TAU*k/fronds + rng.randf_range(-0.3,0.3)
		var frond = MeshInstance3D.new()
		frond.mesh = sphere
		frond.material_override = paint(Color("5d7d3a"), {"moss": 1.0, "moss_color": Color("87a24f")})
		frond.scale = Vector3(0.6,0.03,0.09)*size
		frond.position = at + Vector3(cos(angle)*0.5,0.3,sin(angle)*0.5)*size
		frond.rotation = Vector3(0,-angle,0.35)
		add_child(frond)

func mushrooms(at: Vector3):
	for k in range(rng.randi_range(1,3)):
		var spot = at + Vector3(rng.randf_range(-0.25,0.25),0,rng.randf_range(-0.15,0.15))
		var h = rng.randf_range(0.12,0.25)
		ellipsoid(self, spot + Vector3(0,h*0.5,0), Vector3(0.03,h*0.5,0.03), Color("efe2c8"))
		ellipsoid(self, spot + Vector3(0,h,0), Vector3(0.1,0.06,0.1), Color("c9563a"), {"rim": 0.2})
		for d in range(3):
			var dot = MeshInstance3D.new()
			dot.mesh = sphere
			dot.material_override = flat(Color("fbf3e4"))
			dot.position = spot + Vector3(rng.randf_range(-0.06,0.06),h+0.05,0.06)
			dot.scale = Vector3.ONE*0.017
			add_child(dot)

func flowers(at: Vector3):
	for j in range(rng.randi_range(1,3)):
		var spot = at + Vector3(rng.randf_range(-0.3,0.3),rng.randf_range(0,0.12),rng.randf_range(-0.15,0.15))
		var petal = MeshInstance3D.new()
		petal.mesh = sphere
		petal.material_override = flat(Color("f3eba6") if j%2==0 else Color("fbf6e6"))
		petal.position = spot
		petal.scale = Vector3(0.06,0.03,0.06)
		add_child(petal)

func foam(at: Vector3, radii: Vector2, ring = false, yaw = 0.0):
	# Crisp white waterline accents, like the reference's hand-drawn foam.
	var node = MeshInstance3D.new()
	if ring:
		var torus = TorusMesh.new()
		torus.inner_radius = 0.9
		torus.outer_radius = 1.0
		torus.rings = 24
		node.mesh = torus
	else:
		node.mesh = sphere
	node.material_override = flat(Color("fbfaf1"))
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.position = at + Vector3(0,0.01,0)
	node.scale = Vector3(radii.x,0.02 if ring else 0.012,radii.y)
	node.rotation.y = yaw
	add_child(node)

func _trees():
	for data in [Vector2(-10,12),Vector2(-2,16),Vector2(6,20),Vector2(16,17),Vector2(24,24),Vector2(34,20),Vector2(47,26),Vector2(54,18),
			Vector2(62,22),Vector2(70,18),Vector2(76,24),Vector2(88,22),Vector2(96,26),Vector2(104,18),Vector2(112,24),Vector2(124,20)]:
		_tree(data.x,data.y,0.0,true)
	for i in range(80):
		var at = _spot(-38,-8)
		_background_tree(at.x,at.z)

func _load_trunk_kit():
	# Pieces from tools/blender/trunk_kit.py, grouped by name prefix. Each piece keeps
	# its socket transforms (child empties) where the next piece attaches.
	var kit = TRUNK_KIT.instantiate()
	for node in kit.find_children("*","MeshInstance3D",true,false):
		var sockets: Array[Transform3D] = []
		for child in node.get_children():
			if "_socket_" in String(child.name): sockets.append(child.transform)
		for role in trunk_pieces:
			if node.name.begins_with("trunk_%s_" % role):
				trunk_pieces[role].append({"mesh": node.mesh, "sockets": sockets})
	kit.free()

func trunk_mesh(mids: int) -> ArrayMesh:
	# Climbable trunks stay straight: base + random middles + top, each turned by a
	# random 45° step, merged into one mesh.
	var tool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pieces = [_pick(trunk_pieces["base"])]
	for k in range(mids):
		var mid = _pick(trunk_pieces["mid"])
		while trunk_pieces["mid"].size() > 1 and mid == pieces[-1]: mid = _pick(trunk_pieces["mid"])
		pieces.append(mid)
	pieces.append(_pick(trunk_pieces["top"]))
	for k in range(pieces.size()):
		var turn = Basis(Vector3.UP, rng.randi_range(0,7)*PI/4)
		tool.append_from(pieces[k]["mesh"], 0, Transform3D(turn, Vector3(0, k*SEGMENT_HEIGHT, 0)))
	return tool.commit()

func grown_trunk_mesh(tips: Array) -> ArrayMesh:
	# Background trees grow by following sockets: a trunk run of straight and leaning
	# pieces, forks that split into limbs, and tops. Tip positions are collected for
	# the crown.
	var tool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	_grow(tool, _pick(trunk_pieces["base"]), Transform3D(), rng.randi_range(2,4), 2, tips)
	return tool.commit()

func _grow(tool: SurfaceTool, piece: Dictionary, at: Transform3D, budget: int, forks: int, tips: Array):
	tool.append_from(piece["mesh"], 0, at)
	if piece["sockets"].is_empty():
		tips.append(at * Vector3(0, SEGMENT_HEIGHT*0.8, 0))
		return
	for socket in piece["sockets"]:
		var joint = at * socket
		var role = "top"
		if budget > 0 and joint.basis.get_scale().x > 0.45:
			if forks > 0 and budget <= 2 and rng.randf() < 0.75: role = "fork"
			else: role = "lean" if rng.randf() < 0.55 else "mid"
		var next = _pick(trunk_pieces[role])
		var child = joint * Transform3D(_upright_turn(joint, next), Vector3.ZERO)
		_grow(tool, next, child, budget-1, forks-1 if role == "fork" else forks, tips)

func _upright_turn(joint: Transform3D, piece: Dictionary) -> Basis:
	# Pick a random 45° turn that keeps every outgoing socket within ~55° of vertical,
	# so leans and forks wander without toppling. Falls back to the most upright turn.
	var valid = []
	var best = Basis()
	var best_up = -2.0
	for k in range(8):
		var turn = Basis(Vector3.UP, k*PI/4)
		var lowest = 1.0
		for socket in piece["sockets"]:
			lowest = minf(lowest, (joint.basis * turn * socket.basis).y.normalized().y)
		if lowest > 0.58: valid.append(turn)
		if lowest > best_up:
			best_up = lowest
			best = turn
	return _pick(valid) if not valid.is_empty() else best

func _background_tree(x: float, z: float):
	var tree = Node3D.new()
	tree.position = Vector3(x,terrain.height(x,z)-0.3,z)
	add_child(tree)
	var size = rng.randf_range(1.0,1.7)
	var tips = []
	var trunk = MeshInstance3D.new()
	trunk.mesh = grown_trunk_mesh(tips)
	trunk.material_override = paint(Color("f2e2da"), {"use_vertex_color": true, "grain_scale": Vector3(3.5,0.35,3.5)})
	trunk.scale = Vector3.ONE*size
	tree.add_child(trunk)
	# Crown clumps gather around each limb tip.
	var clumps = []
	for tip in tips:
		for k in range(4):
			var spread = Vector3(rng.randf_range(-2.0,2.0),rng.randf_range(-0.6,1.4),rng.randf_range(-1.2,1.2))
			clumps.append([tip*size + spread,Vector3(rng.randf_range(1.6,2.4),1.0,1.4)*(0.7+size*0.3)])
	leaf_crown(tree,clumps,Color("9fa877"),Color("c5c895"),z > -10)

func _pick(options: Array):
	# Seeded so the forest is identical every run.
	return options[rng.randi_range(0, options.size()-1)]

func _tree(x: float, height: float, z: float, climbable: bool):
	var tree = Node3D.new()
	tree.position = Vector3(x,0,z)
	add_child(tree)
	var mids = maxi(1, roundi((height-7.0)/SEGMENT_HEIGHT))
	# Crown sits in the tapering top segment; climbing reaches just below it.
	height = SEGMENT_HEIGHT*(mids+1) + 3.0
	tree.set_meta("height",height)
	var bark = Color("8f6552") if climbable else Color("ad8e80")
	var trunk = MeshInstance3D.new()
	trunk.mesh = trunk_mesh(mids)
	trunk.material_override = paint(Color.WHITE if climbable else Color("f2e2da"), {"use_vertex_color": true, "grain_scale": Vector3(3.5,0.35,3.5)})
	if not climbable: trunk.scale = Vector3(1.35,1.0,1.35)
	tree.add_child(trunk)
	var leaf = LEAF if climbable else Color("9fa877")
	var leaf_light = LEAF_LIGHT if climbable else Color("c5c895")
	for i in range(5):
		var h = 2.6+i*height/6.0
		var side = 1.0 if i%2==0 else -1.0
		if climbable:
			# Long springy branches the squirrel can run out along.
			var branch = Node3D.new()
			branch.set_script(BRANCH)
			add_child(branch)
			branch.setup(self, tree, Vector3(x,h,0), side, 5.6-i*0.35, bark, rng)
			branches.append(branch)
	var clumps = []
	for i in range(8):
		clumps.append([Vector3(rng.randf_range(-3.2,3.2),height+rng.randf_range(-1.2,1.5),rng.randf_range(-1.6,-0.4)),Vector3(rng.randf_range(1.8,2.6),1.0,1.5)])
	leaf_crown(tree,clumps,leaf,leaf_light)
	if climbable:
		var area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 1
		var collision = CollisionShape3D.new()
		var shape = BoxShape3D.new()
		shape.size = Vector3(1.8,height+1,2)
		collision.shape = shape
		collision.position.y = height/2
		area.add_child(collision)
		tree.add_child(area)
		area.body_entered.connect(func(body):
			if body == player and not player.nearby_trunks.has(tree): player.nearby_trunks.append(tree))
		area.body_exited.connect(func(body):
			if body == player: player.nearby_trunks.erase(tree))

func _hud():
	var layer = CanvasLayer.new()
	add_child(layer)
	var root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var panel = PanelContainer.new()
	panel.position = Vector2(20,20)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.25,0.22,0.2,0.32)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel",style)
	root.add_child(panel)
	var stack = VBoxContainer.new()
	stack.add_theme_constant_override("separation",5)
	panel.add_child(stack)
	stamina_bar = ProgressBar.new()
	stamina_bar.custom_minimum_size = Vector2(180,8)
	stamina_bar.show_percentage = false
	var back = StyleBoxFlat.new()
	back.bg_color = Color(1,1,1,0.18)
	back.set_corner_radius_all(4)
	var fill = StyleBoxFlat.new()
	fill.bg_color = Color("fbe7b0")
	fill.set_corner_radius_all(4)
	stamina_bar.add_theme_stylebox_override("background",back)
	stamina_bar.add_theme_stylebox_override("fill",fill)
	stack.add_child(stamina_bar)
	state_label = _label(stack,13)
	checkpoint_label = _label(stack,13)
	controls = _label(root,13)
	controls.text = "A/D run   SPACE jump   W or E grip trunk   W/S climb   SHIFT glide\nS+SPACE drop through branch   Q wide view   R retry   H hide help"
	controls.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	controls.position = Vector2(20,-54)

func _label(parent: Control, size: int) -> Label:
	var label = Label.new()
	label.add_theme_font_size_override("font_size",size)
	label.add_theme_color_override("font_color",Color("fff8e6"))
	label.add_theme_color_override("font_shadow_color",Color(0.2,0.15,0.12,0.6))
	label.add_theme_constant_override("shadow_offset_x",1)
	label.add_theme_constant_override("shadow_offset_y",1)
	parent.add_child(label)
	return label

func _camera_goal(at: Vector3) -> Vector3:
	# Look ahead of the squirrel and below it during fast falls so landings stay visible.
	return at + Vector3(look_ahead, 1.1 + clampf(player.velocity.y*0.09, -2.2, 0.4), 0)

func _place_camera():
	var pitch = deg_to_rad(CAMERA_PITCH)
	camera.position = camera_target + Vector3(0, sin(pitch), cos(pitch))*camera_distance
	camera.look_at(camera_target)

func reset_camera():
	look_ahead = player.facing*1.3
	camera_target = _camera_goal(player.position)
	_place_camera()
	glide_pulse = 0

func _process(delta):
	if Input.is_action_just_pressed("quit"): get_tree().quit()
	elapsed += delta
	glide_pulse = maxf(0,glide_pulse-delta)
	var squirrel_position = player.get_global_transform_interpolated().origin
	look_ahead = lerpf(look_ahead, player.facing*1.3 + clampf(player.velocity.x*0.12,-1.0,1.0), 1-exp(-delta*2.5))
	camera_target = camera_target.lerp(_camera_goal(squirrel_position),1-exp(-delta*(2.0 if glide_pulse>0 else 6.0)))
	var distance_goal = OVERVIEW_DISTANCE if Input.is_action_pressed("overview") else (GLIDE_DISTANCE if player.gliding else CAMERA_DISTANCE)
	camera_distance = lerpf(camera_distance,distance_goal,1-exp(-delta*3))
	_place_camera()
	stamina_bar.value = player.stamina
	state_label.text = "%s  ·  glide %d%%" % [player.movement_state().to_lower(),roundi(player.stamina)]
	var hint = "W or E to grip trunk" if not player.nearby_trunks.is_empty() and not player.climbing else "Gain height. Open your glide."
	checkpoint_label.text = "Lantern %d / %d  ·  %s" % [checkpoint_index+1,checks.size(),hint]
	if Input.is_action_just_pressed("help"): controls.visible = not controls.visible
	for i in range(checks.size()):
		if i>checkpoint_index and player.position.distance_to(checks[i])<1.8:
			checkpoint_index = i
			player.spawn_point = checks[i]
			player.stamina = 100
	var args = OS.get_cmdline_user_args()
	if "--capture" in args:
		if "--overview" in args: Input.action_press("overview")
		if "--freeze" in args: player.set_physics_process(false)
		# --tap=a,b presses actions once early; --hold=a,b holds them from then on.
		for arg in args:
			if arg.begins_with("--tap=") and capture_frames == 3:
				for action in arg.trim_prefix("--tap=").split(","): Input.action_press(action)
			if arg.begins_with("--tap=") and capture_frames == 5:
				for action in arg.trim_prefix("--tap=").split(","): Input.action_release(action)
			if arg.begins_with("--hold=") and capture_frames == 8:
				for action in arg.trim_prefix("--hold=").split(","): Input.action_press(action)
		if "--glide" in args:
			Input.action_press("glide")
			Input.action_press("right")
		capture_frames += 1
		var shot = 50
		for arg in args:
			if arg.begins_with("--frame="): shot = int(arg.trim_prefix("--frame="))
		if capture_frames == (300 if "--perf" in args else shot):
			_capture.call_deferred()

func _capture():
	await RenderingServer.frame_post_draw
	var path = "res://prototype-preview.png"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): path = arg.trim_prefix("--out=")
	get_viewport().get_texture().get_image().save_png(path)
	print("capture fps=%d draw_calls=%d objects=%d" % [Performance.get_monitor(Performance.TIME_FPS), Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)])
	get_tree().quit()

func _ticks(count: int):
	for i in range(count):
		await get_tree().physics_frame

func _smoke_sequence():
	await _ticks(60)
	assert(player.is_on_floor(), "Player must settle on ground")
	assert(player.stamina == 100, "Resting restores stamina")
	Input.action_press("jump")
	await _ticks(3)
	Input.action_release("jump")
	assert(player.velocity.y > 0, "Jump must launch upward")
	await _ticks(60)
	assert(player.is_on_floor(), "Ordinary jump must land")
	player.position = Vector3(-2,0.6,0)
	player.velocity = Vector3.ZERO
	await _ticks(5)
	assert(not player.climbing, "Overlap alone must not attach")
	assert(not player.nearby_trunks.is_empty(), "Trunk detector must find tree")
	Input.action_press("attach")
	await _ticks(3)
	Input.action_release("attach")
	assert(player.climbing, "E must attach")
	var original_y = player.position.y
	Input.action_press("up")
	await _ticks(20)
	Input.action_release("up")
	assert(player.position.y > original_y + 0.5, "W must climb")
	Input.action_press("right")
	Input.action_press("jump")
	await _ticks(3)
	Input.action_release("jump")
	Input.action_release("right")
	assert(not player.climbing and player.velocity.x > 0, "Directional trunk leap must detach")
	await _ticks(12)
	assert(player.velocity.x > 5.0, "Leap must keep its momentum in the air")
	# Climbing past a branch while holding its direction runs out onto it.
	player.position = Vector3(-2,0.6,0)
	player.velocity = Vector3.ZERO
	await _ticks(5)
	Input.action_press("attach")
	await _ticks(2)
	Input.action_release("attach")
	Input.action_press("up")
	Input.action_press("right")
	await _ticks(32)
	assert(not player.climbing and player.branch != null, "Holding a direction past a branch must step onto it")
	assert(player.velocity.x > 5.0, "Branch dismount must keep running")
	Input.action_release("up")
	# Detent: running out pauses at the tip before running off.
	var tip = player.branch
	for i in range(90):
		if is_equal_approx(player.position.x, tip.tip_x()): break
		await _ticks(1)
	await _ticks(6)
	assert(player.branch == tip and is_equal_approx(player.position.x, tip.tip_x()), "Tip detent must hold the squirrel briefly")
	await _ticks(20)
	assert(player.branch == null, "Holding outward past the detent must run off the tip")
	Input.action_release("right")
	# Landing from above catches the branch; running back toward the trunk hugs it.
	player.respawn()
	player.position = Vector3(tip.position.x + 2.5, tip.surface_y(tip.position.x + 2.5) + 2.0, 0)
	await _ticks(40)
	assert(player.branch == tip, "Falling onto a branch must land on it")
	Input.action_press("left")
	for i in range(60):
		if player.climbing: break
		await _ticks(1)
	assert(player.climbing and player.trunk == tip.tree and player.climb_side == 1.0, "Running back to the trunk must hug it on the same side")
	await _ticks(15)
	assert(player.climbing and player.climb_side == -1.0, "Holding the run direction must swing around to the far side")
	Input.action_release("left")
	# Springboard: a jump from the tip launches higher than a ground jump.
	player.respawn()
	player.position = Vector3(tip.tip_x() - 0.2, tip.surface_y(tip.tip_x()) + 1.0, 0)
	await _ticks(40)
	assert(player.branch == tip, "Must land near the tip")
	Input.action_press("down")
	await _ticks(8)
	Input.action_release("down")
	await _ticks(4)
	Input.action_press("jump")
	var launch = 0.0
	for i in range(4):
		await _ticks(1)
		launch = maxf(launch, player.velocity.y)
	assert(launch > player.JUMP_SPEED + 0.5, "Tip jump must get a springboard boost")
	Input.action_release("jump")
	await _ticks(60)
	# S+Space drops through a branch rather than jumping.
	player.respawn()
	player.position = Vector3(tip.position.x + 2.5, tip.surface_y(tip.position.x + 2.5) + 1.0, 0)
	await _ticks(40)
	assert(player.branch == tip, "Must land before drop test")
	var branch_y = player.position.y
	Input.action_press("down")
	Input.action_press("jump")
	await _ticks(3)
	Input.action_release("jump")
	Input.action_release("down")
	await _ticks(20)
	assert(player.branch == null and player.position.y < branch_y - 0.5, "Down+jump must drop through a branch")
	player.position = Vector3(10,12,0)
	player.velocity = Vector3(0,-20,0)
	Input.action_press("glide")
	await _ticks(15)
	assert(player.gliding, "Glide must activate in fast fall")
	assert(player.velocity.y > -3, "Glide must brake fast fall")
	assert(player.stamina < 100, "Glide must consume stamina")
	assert(absf(player.velocity.x) > 1.0, "Glide must carry forward without input")
	# Running out mid-glide must fall cleanly, not flicker: no recovery while glide is held.
	player.position = Vector3(-21,14,0) # open air, clear of every branch
	player.stamina = 2.0
	await _ticks(20)
	assert(player.stamina == 0 and not player.gliding, "Exhausted glide must close and stay closed")
	assert(player.velocity.y < -player.GLIDE_FALL_SPEED*2, "Exhausted glide must fall at full speed")
	Input.action_release("glide")
	await _ticks(10)
	assert(player.stamina > 0, "Stamina must recover once glide is released")
	player.respawn()
	await _ticks(5)
	assert(player.stamina == 100 and not player.climbing, "Retry must reset resources and attachment")
	player.position = Vector3(12.6,0.6,0)
	await _ticks(5)
	assert(checkpoint_index == 1, "Lantern must save retry point")
	player.position = Vector3(10,-2,0)
	await _ticks(5)
	assert(player.position.distance_to(checks[1]) < 1, "Creek fall must restore checkpoint")
	assert(is_equal_approx(player.position.z,0), "Movement must remain on plane")
	print("SMOKE PASS: ground, variable jump, trunk grip/climb/leap momentum, springy branches (catch, detent, hug, springboard, drop-through), glide braking, carry and exhaustion, stamina, checkpoints and creek retry")
	get_tree().quit()
