extends Node3D

const PIGMENT = preload("res://shaders/pigment.gdshader")
const PLAYER = preload("res://scripts/squirrel.gd")
var rng = RandomNumberGenerator.new()
var materials: Dictionary = {}
var player: CharacterBody3D
var camera: Camera3D
var stamina_bar: ProgressBar
var state_label: Label
var checkpoint_label: Label
var glide_pulse = 0.0
var camera_target = Vector3.ZERO
var checkpoint_index = 0
var checks = [Vector3(-6,0.6,0),Vector3(12,0.6,0),Vector3(32,0.6,0)]
var smoke_test = false
var capture_frames = 0

func _ready():
	rng.seed = 8246
	smoke_test = "--smoke-test" in OS.get_cmdline_user_args()
	_inputs()
	_environment()
	_terrain()
	_trees()
	player = CharacterBody3D.new()
	player.name = "Squirrel"
	player.set_script(PLAYER)
	add_child(player)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 8.5
	camera.far = 160
	camera.current = true
	add_child(camera)
	reset_camera()
	_hud()
	if smoke_test: _smoke_sequence.call_deferred()

func _inputs():
	var bindings = {"left":[KEY_A,KEY_LEFT],"right":[KEY_D,KEY_RIGHT],"up":[KEY_W,KEY_UP],"down":[KEY_S,KEY_DOWN],"jump":[KEY_SPACE],"attach":[KEY_E],"glide":[KEY_SHIFT],"restart":[KEY_R],"overview":[KEY_Q],"quit":[KEY_ESCAPE]}
	for action in bindings:
		InputMap.add_action(action)
		for key in bindings[action]:
			var event = InputEventKey.new()
			event.physical_keycode = key
			InputMap.action_add_event(action,event)

func paint(color: Color) -> ShaderMaterial:
	var key = color.to_html()
	if not materials.has(key):
		var material = ShaderMaterial.new()
		material.shader = PIGMENT
		material.set_shader_parameter("paint_color",color.srgb_to_linear())
		materials[key] = material
	return materials[key]

func ellipsoid(parent: Node3D, at: Vector3, radii: Vector3, color: Color) -> MeshInstance3D:
	var node = MeshInstance3D.new()
	var mesh = SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	node.mesh = mesh
	node.material_override = paint(color)
	node.position = at
	node.scale = radii
	parent.add_child(node)
	return node

func box(at: Vector3, size: Vector3, color: Color, solid = false) -> Node3D:
	var root: Node3D = StaticBody3D.new() if solid else Node3D.new()
	root.position = at
	add_child(root)
	var mesh = MeshInstance3D.new()
	var cube = BoxMesh.new()
	cube.size = size
	mesh.mesh = cube
	mesh.material_override = paint(color)
	root.add_child(mesh)
	if solid:
		var collision = CollisionShape3D.new()
		var shape = BoxShape3D.new()
		shape.size = size
		collision.shape = shape
		root.add_child(collision)
	return root

func limb(parent: Node3D, a: Vector3, b: Vector3, radius: float, color: Color):
	var node = MeshInstance3D.new()
	var mesh = CylinderMesh.new()
	mesh.top_radius = radius*0.64
	mesh.bottom_radius = radius
	mesh.height = a.distance_to(b)
	mesh.radial_segments = 9
	node.mesh = mesh
	node.material_override = paint(color)
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
	env.background_color = Color("dfe6be")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("f8e4cb")
	env.ambient_light_energy = 0.3
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_light_color = Color("e1dfbd")
	env.fog_density = 0.016
	world.environment = env
	add_child(world)
	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35,-35,-20)
	sun.light_color = Color("ffe0b0")
	sun.light_energy = 0.65
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 50
	add_child(sun)

func _terrain():
	# Ground tops at y=0; the creek intentionally breaks the traversal surface.
	box(Vector3(-6,-1.2,0),Vector3(28,2.4,5),Color("b49b7c"),true)
	box(Vector3(27,-1.2,0),Vector3(30,2.4,5),Color("b49b7c"),true)
	box(Vector3(50,-1.2,0),Vector3(10,2.4,5),Color("b49b7c"),true)
	for section in [Vector2(-20,8),Vector2(12,42),Vector2(45,55)]:
		box(Vector3((section.x+section.y)/2,-0.035,0),Vector3(section.y-section.x,0.07,5.1),Color("91a967"))
	for x in [9.0,10.5,43.3]:
		box(Vector3(x,-0.16,0),Vector3(0.85,0.32,1.4),Color("bdb19a"),true)
	var water = MeshInstance3D.new()
	var plane = PlaneMesh.new()
	plane.size = Vector2(90,24)
	water.mesh = plane
	water.position = Vector3(15,-0.55,-4)
	var material = ShaderMaterial.new()
	material.shader = preload("res://shaders/water.gdshader")
	water.material_override = material
	add_child(water)
	# Background banks, boulders, moss and flower groups.
	for i in range(100):
		var x = rng.randf_range(-22,57)
		var z = rng.randf_range(-10,-3)
		var r = rng.randf_range(0.35,1.7)
		ellipsoid(self,Vector3(x,-0.2,z),Vector3(r,r*0.75,r*0.7),Color("bb9c87"))
		ellipsoid(self,Vector3(x,r*0.4,z),Vector3(r*0.8,r*0.22,r*0.7),Color("8ea56c"))
	for i in range(190):
		var x = rng.randf_range(-19,55)
		if (x>8 and x<12) or (x>42 and x<45): continue
		var z = rng.randf_range(0.8,2.8) if i%2==0 else rng.randf_range(-2.8,-0.8)
		var color = Color("97b36e") if i%3 else Color("b7bd77")
		ellipsoid(self,Vector3(x,0.1,z),Vector3(0.3,0.22,0.3),color)
		if i%3==0:
			limb(self,Vector3(x,0.1,z),Vector3(x+0.03,0.4,z),0.025,Color("829957"))
			ellipsoid(self,Vector3(x+0.03,0.4,z),Vector3(0.09,0.035,0.09),Color("fff0ae"))
	for point in checks:
		limb(self,point-Vector3(0,0.6,0.65),point+Vector3(0,0.7,-0.65),0.055,Color("a78565"))
		ellipsoid(self,point+Vector3(0,0.75,-0.65),Vector3(0.16,0.22,0.16),Color("f4cd83"))

func _trees():
	for data in [Vector2(-10,12),Vector2(-2,16),Vector2(6,20),Vector2(16,17),Vector2(24,24),Vector2(34,20),Vector2(47,26),Vector2(54,18)]:
		_tree(data.x,data.y,0.0,true)
	for i in range(42):
		_tree(rng.randf_range(-30,65),rng.randf_range(14,34),rng.randf_range(-35,-8),false)

func _tree(x: float, height: float, z: float, climbable: bool):
	var tree = Node3D.new()
	tree.position = Vector3(x,0,z)
	tree.set_meta("height",height)
	add_child(tree)
	var bark = Color("a98270") if climbable else Color("b8ad91")
	limb(tree,Vector3(0,-0.5,0),Vector3(0.15,height,0),0.52 if climbable else 0.65,bark)
	for i in range(3):
		limb(tree,Vector3(0,0.5,0),Vector3((i-1)*1.0,0,0.3),0.22,bark)
	for i in range(5):
		var h = 2.6+i*height/6.0
		var side = 1.0 if i%2==0 else -1.0
		var length = 3.6-i*0.28
		limb(tree,Vector3(0,h-0.12,0),Vector3(side*length,h+0.13,0),0.16,bark)
		if climbable:
			# Simple flat collision tops stay readable beneath the organic branch mesh.
			box(Vector3(x+side*length/2,h,0),Vector3(length,0.20,0.9),bark,true)
		ellipsoid(tree,Vector3(side*(length-0.3),h+0.7,-0.5),Vector3(1.7,0.65,1.1),Color("a3b775") if climbable else Color("bdc391"))
	for i in range(6):
		ellipsoid(tree,Vector3(rng.randf_range(-2.8,2.8),height+rng.randf_range(-1,1.2),rng.randf_range(-1,1)),Vector3(2.4,1.0,1.6),Color("b4c57b") if climbable else Color("c6cb9b"))
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
	panel.position = Vector2(24,24)
	panel.custom_minimum_size = Vector2(300,0)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.16,0.23,0.19,0.88)
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel",style)
	root.add_child(panel)
	var stack = VBoxContainer.new()
	stack.add_theme_constant_override("separation",8)
	panel.add_child(stack)
	var title = Label.new()
	title.text = "FIRE IN THE FOREST"
	title.add_theme_color_override("font_color",Color("ffedc4"))
	title.add_theme_font_size_override("font_size",21)
	stack.add_child(title)
	var subtitle = Label.new()
	subtitle.text = "Creekside · movement study"
	stack.add_child(subtitle)
	stamina_bar = ProgressBar.new()
	stamina_bar.custom_minimum_size = Vector2(260,12)
	stamina_bar.show_percentage = false
	var fill = StyleBoxFlat.new()
	fill.bg_color = Color("d5c588")
	fill.corner_radius_top_left = 5
	fill.corner_radius_top_right = 5
	fill.corner_radius_bottom_left = 5
	fill.corner_radius_bottom_right = 5
	stamina_bar.add_theme_stylebox_override("fill",fill)
	stack.add_child(stamina_bar)
	state_label = Label.new()
	stack.add_child(state_label)
	checkpoint_label = Label.new()
	stack.add_child(checkpoint_label)
	var controls = Label.new()
	controls.text = "A / D   Move     SPACE   Jump\nE   Grip / release tree     W / S   Climb\nSHIFT   Glide     Hold Q   Wide view\nR   Retry from lantern     ESC   Quit"
	controls.add_theme_font_size_override("font_size",16)
	controls.add_theme_color_override("font_color",Color("eee7cb"))
	controls.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	controls.position = Vector2(24,-108)
	root.add_child(controls)

func reset_camera():
	camera_target = player.position + Vector3(1.3,1.5,0)
	camera.position = camera_target + Vector3(0,1.0,24)
	camera.look_at(camera_target)
	glide_pulse = 0

func _process(delta):
	if Input.is_action_just_pressed("quit"): get_tree().quit()
	glide_pulse = maxf(0,glide_pulse-delta)
	var target = player.position + Vector3(player.facing*1.3,1.5,0)
	camera_target = camera_target.lerp(target,1-exp(-delta*(2.0 if glide_pulse>0 else 6.0)))
	camera.position = camera_target + Vector3(0,1.0,24)
	camera.look_at(camera_target)
	var size_target = 19.0 if Input.is_action_pressed("overview") else (10.0 if player.gliding else 8.5)
	camera.size = lerpf(camera.size,size_target,1-exp(-delta*3))
	stamina_bar.value = player.stamina
	state_label.text = "%s  ·  GLIDE %d%%" % [player.movement_state(),roundi(player.stamina)]
	var hint = "E to grip trunk" if not player.nearby_trunks.is_empty() and not player.climbing else "Gain height. Open your glide."
	checkpoint_label.text = "Lantern %d / 3  ·  %s" % [checkpoint_index+1,hint]
	for i in range(checks.size()):
		if i>checkpoint_index and player.position.distance_to(checks[i])<1.8:
			checkpoint_index = i
			player.spawn_point = checks[i]
			player.stamina = 100
	if "--capture" in OS.get_cmdline_user_args():
		capture_frames += 1
		if capture_frames == 60:
			_capture.call_deferred()

func _capture():
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://prototype-preview.png")
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
	player.position = Vector3(10,12,0)
	player.velocity = Vector3(0,-20,0)
	Input.action_press("glide")
	await _ticks(15)
	assert(player.gliding, "Glide must activate in fast fall")
	assert(player.velocity.y > -3, "Glide must brake fast fall")
	assert(player.stamina < 100, "Glide must consume stamina")
	Input.action_release("glide")
	player.respawn()
	await _ticks(5)
	assert(player.stamina == 100 and not player.climbing, "Retry must reset resources and attachment")
	player.position = Vector3(12,0.6,0)
	await _ticks(5)
	assert(checkpoint_index == 1, "Lantern must save retry point")
	player.position = Vector3(10,-6,0)
	await _ticks(5)
	assert(player.position.distance_to(checks[1]) < 1, "Creek fall must restore checkpoint")
	assert(is_equal_approx(player.position.z,0), "Movement must remain on plane")
	print("SMOKE PASS: ground, jumping, trunk detection/attachment/climb/leap, fast-fall glide braking, stamina, checkpoints and retry")
	get_tree().quit()
