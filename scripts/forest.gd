extends Node3D

const PIGMENT = preload("res://shaders/pigment.gdshader")
const PLAYER = preload("res://scripts/squirrel.gd")
const CAMERA_FOV = 30.0
const CAMERA_PITCH = 9.0
const CAMERA_DISTANCE = 15.0
const GLIDE_DISTANCE = 18.5
const OVERVIEW_DISTANCE = 36.0
const WATER_Y = -0.45
const ROCK = Color("c09a85")
const MOSS = Color("9cb064")
const MOSS_LIGHT = Color("c8d27f")
const LEAF = Color("8fa75c")
const LEAF_LIGHT = Color("d3dc8e")
var rng = RandomNumberGenerator.new()
var materials: Dictionary = {}
var sphere: SphereMesh
var platforms: Array[StaticBody3D] = []
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
var checks = [Vector3(-6,0.6,0),Vector3(12.6,0.6,0),Vector3(32,0.6,0)]
var smoke_test = false
var capture_frames = 0

func _ready():
	rng.seed = 8246
	var args = OS.get_cmdline_user_args()
	smoke_test = "--smoke-test" in args
	sphere = SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 18
	sphere.rings = 9
	_inputs()
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

func platform(at: Vector3, size: Vector3):
	# Invisible one-way collision top; the squirrel ignores it until its feet are above "top".
	var body = StaticBody3D.new()
	body.position = at
	body.set_meta("top", at.y + size.y/2)
	add_child(body)
	_collider(body, size)
	platforms.append(body)

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
	env.ambient_light_color = Color("d8bfc8")
	env.ambient_light_energy = 0.62
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.environment = env
	add_child(world)
	var sun = DirectionalLight3D.new()
	add_child(sun)
	sun.look_at_from_position(Vector3(6,9,5), Vector3.ZERO)
	sun.light_color = Color("ffe3bf")
	sun.light_energy = 0.95
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
	while x < 70:
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
	# Ground tops at y=0; the creek intentionally breaks the traversal surface.
	var ground = {"moss": 1.0, "moss_color": MOSS, "grain_scale": Vector3(1,2.5,1)}
	var sections = [Vector2(-20,8),Vector2(12,42),Vector2(45,55)]
	for section in sections:
		box(Vector3((section.x+section.y)/2,-1.2,0),Vector3(section.y-section.x,2.4,5),ROCK,true,ground)
		# Lumpy mossy boulders break the straight bank edge, with a broken foam line at the waterline.
		var x = section.x + 0.4
		while x < section.y - 0.4:
			rock(self, Vector3(x,-0.5,rng.randf_range(2.2,2.7)), Vector3(rng.randf_range(0.7,1.3),rng.randf_range(0.42,0.6),0.6))
			if rng.randf() < 0.7:
				foam(Vector3(x+rng.randf_range(-0.3,0.3),WATER_Y,3.05), Vector2(rng.randf_range(0.5,1.1),0.12))
			x += rng.randf_range(1.0,1.8)
	for x in [9.0,10.5,43.3]:
		var stone = StaticBody3D.new()
		stone.position = Vector3(x,-0.5,0)
		add_child(stone)
		_collider(stone, Vector3(0.85,1.0,1.4))
		rock(stone, Vector3(0,0.05,0), Vector3(0.55,0.5,0.8), 0.9)
		foam(Vector3(x,WATER_Y,0), Vector2(0.62,0.9), true)
	var water = MeshInstance3D.new()
	var plane = PlaneMesh.new()
	plane.size = Vector2(130,46)
	water.mesh = plane
	water.position = Vector3(17,WATER_Y,-9)
	var material = ShaderMaterial.new()
	material.shader = preload("res://shaders/water.gdshader")
	water.material_override = material
	add_child(water)
	# Background banks: mossy boulder formations behind the creek.
	for i in range(70):
		var x = rng.randf_range(-26,62)
		var z = rng.randf_range(-14,-3.5)
		var r = rng.randf_range(0.6,2.4)
		rock(self, Vector3(x,-0.3,z), Vector3(r*1.2,r*0.8,r*0.8))
		if rng.randf() < 0.5:
			foliage(self, Vector3(x+rng.randf_range(-0.5,0.5),r*0.5,z+0.2), Vector3(r*0.7,r*0.35,r*0.5))
	for i in range(14):
		var x = rng.randf_range(-24,60)
		var z = rng.randf_range(-9,-5)
		var r = rng.randf_range(2.5,4.0)
		rock(self, Vector3(x,r*0.35,z), Vector3(r*1.3,r,r*0.9))
	# Ground cover on the play strip: moss clumps and small cream-yellow flowers.
	for i in range(170):
		var x = rng.randf_range(-19,55)
		if (x>7.6 and x<12.4) or (x>41.6 and x<45.4): continue
		var z = rng.randf_range(0.8,2.3) if i%2==0 else rng.randf_range(-2.4,-0.8)
		var color = MOSS if i%3 else Color("adb86a")
		foliage(self, Vector3(x,0.06,z), Vector3(0.34,0.2,0.3), color, MOSS_LIGHT)
		if i%2==0: flowers(Vector3(x,0.2,z))
	# Low foreground framing below the play line, kept clear of landing surfaces.
	for i in range(18):
		var x = rng.randf_range(-22,60)
		foliage(self, Vector3(x,-1.0,rng.randf_range(4.5,6.0)), Vector3(rng.randf_range(1.0,1.8),0.8,0.8), Color("7f9a52"), MOSS_LIGHT)
	for point in checks:
		limb(self,point-Vector3(0,0.6,0.65),point+Vector3(0,0.7,-0.65),0.055,Color("8f6c52"))
		var bulb = MeshInstance3D.new()
		bulb.mesh = sphere
		bulb.material_override = flat(Color("ffe2a0"))
		bulb.position = point+Vector3(0,0.75,-0.65)
		bulb.scale = Vector3(0.15,0.2,0.15)
		add_child(bulb)
		var halo = MeshInstance3D.new()
		halo.mesh = sphere
		halo.material_override = flat(Color(0.35,0.25,0.1), true)
		halo.position = bulb.position
		halo.scale = Vector3.ONE*0.42
		add_child(halo)

func flowers(at: Vector3):
	for j in range(rng.randi_range(1,3)):
		var spot = at + Vector3(rng.randf_range(-0.3,0.3),rng.randf_range(0,0.12),rng.randf_range(-0.15,0.15))
		var petal = MeshInstance3D.new()
		petal.mesh = sphere
		petal.material_override = flat(Color("f6eba0") if j%2==0 else Color("fbf3d9"))
		petal.position = spot
		petal.scale = Vector3(0.07,0.035,0.07)
		add_child(petal)

func foam(at: Vector3, radii: Vector2, ring = false):
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
	add_child(node)

func _trees():
	for data in [Vector2(-10,12),Vector2(-2,16),Vector2(6,20),Vector2(16,17),Vector2(24,24),Vector2(34,20),Vector2(47,26),Vector2(54,18)]:
		_tree(data.x,data.y,0.0,true)
	for i in range(46):
		_tree(rng.randf_range(-34,70),rng.randf_range(16,34),rng.randf_range(-36,-8),false)
	# Far hazy layer: simple trunks and crowns that dissolve into the atmosphere.
	for i in range(40):
		var x = rng.randf_range(-60,100)
		var z = rng.randf_range(-80,-42)
		var height = rng.randf_range(30,50)
		var tree = Node3D.new()
		tree.position = Vector3(x,0,z)
		add_child(tree)
		limb(tree,Vector3(0,-1,0),Vector3(0,height,0),1.2,Color("c9a796"))
		for j in range(4):
			ellipsoid(tree,Vector3(rng.randf_range(-5,5),height+rng.randf_range(-3,3),0),Vector3(6,3,3),Color("cdd29a"))

func _tree(x: float, height: float, z: float, climbable: bool):
	var tree = Node3D.new()
	tree.position = Vector3(x,0,z)
	tree.set_meta("height",height)
	add_child(tree)
	var bark = Color("a76f58") if climbable else Color("c3a08d")
	var bark_paint = {"grain_scale": Vector3(3.5,0.35,3.5), "moss": 0.6, "moss_color": MOSS}
	limb(tree,Vector3(0,-0.5,0),Vector3(0.15,height,0),0.52 if climbable else 0.7,bark,bark_paint)
	for i in range(3):
		limb(tree,Vector3(0,0.6,0),Vector3((i-1)*1.1,-0.1,0.35),0.24,bark,bark_paint)
	var leaf = LEAF if climbable else Color("b4be82")
	var leaf_light = LEAF_LIGHT if climbable else Color("dcdca6")
	for i in range(5):
		var h = 2.6+i*height/6.0
		var side = 1.0 if i%2==0 else -1.0
		var length = 3.6-i*0.28
		# Mossy tops read as walkable; collision is a flat one-way top matched to the limb.
		limb(tree,Vector3(0,h,0),Vector3(side*length,h+0.06,0),0.17,bark,{"moss": 1.0, "moss_color": MOSS_LIGHT, "grain_scale": Vector3(0.35,3.5,3.5)})
		if climbable:
			platform(Vector3(x+side*length/2,h+0.04,0),Vector3(length,0.2,0.9))
		for j in range(3):
			foliage(tree,Vector3(side*(length-0.2+rng.randf_range(-0.6,0.4)),h+rng.randf_range(0.5,1.0),rng.randf_range(-1.4,-0.7)),Vector3(rng.randf_range(0.9,1.4),0.55,0.8),leaf,leaf_light)
	for i in range(8):
		foliage(tree,Vector3(rng.randf_range(-3.2,3.2),height+rng.randf_range(-1.2,1.5),rng.randf_range(-1.6,-0.4)),Vector3(rng.randf_range(1.8,2.6),1.0,1.5),leaf,leaf_light)
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
	checkpoint_label.text = "Lantern %d / 3  ·  %s" % [checkpoint_index+1,hint]
	if Input.is_action_just_pressed("help"): controls.visible = not controls.visible
	for i in range(checks.size()):
		if i>checkpoint_index and player.position.distance_to(checks[i])<1.8:
			checkpoint_index = i
			player.spawn_point = checks[i]
			player.stamina = 100
	var args = OS.get_cmdline_user_args()
	if "--capture" in args:
		if "--glide" in args:
			Input.action_press("glide")
			Input.action_press("right")
		capture_frames += 1
		if capture_frames == 50:
			_capture.call_deferred()

func _capture():
	await RenderingServer.frame_post_draw
	var path = "res://prototype-preview.png"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): path = arg.trim_prefix("--out=")
	get_viewport().get_texture().get_image().save_png(path)
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
	assert(player.velocity.x > 6.0, "Leap must keep its momentum in the air")
	# Branch at x=-2 (height 2.6, extends right) is one-way: jump up through it, then drop back down.
	player.position = Vector3(0.8,1.0,0)
	player.velocity = Vector3(0,11,0)
	await _ticks(70)
	assert(player.is_on_floor() and player.position.y > 2.9, "Branches must be passable from below and land from above")
	Input.action_press("down")
	Input.action_press("jump")
	await _ticks(3)
	Input.action_release("jump")
	Input.action_release("down")
	await _ticks(30)
	assert(player.position.y < 2.5, "Down+jump must drop through a branch")
	player.position = Vector3(10,12,0)
	player.velocity = Vector3(0,-20,0)
	Input.action_press("glide")
	await _ticks(15)
	assert(player.gliding, "Glide must activate in fast fall")
	assert(player.velocity.y > -3, "Glide must brake fast fall")
	assert(player.stamina < 100, "Glide must consume stamina")
	assert(absf(player.velocity.x) > 1.0, "Glide must carry forward without input")
	Input.action_release("glide")
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
	print("SMOKE PASS: ground, variable jump, trunk grip/climb/leap momentum, one-way branches and drop-through, glide braking and carry, stamina, checkpoints and creek retry")
	get_tree().quit()
