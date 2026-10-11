extends CharacterBody3D

const RUN_SPEED = 6.5
const GROUND_ACCEL = 40.0
const AIR_ACCEL = 16.0
const AIR_DRAG = 3.0
const JUMP_SPEED = 9.0
const JUMP_CUT = 0.5
const GRAVITY = 25.0
const FALL_GRAVITY = 32.0
const MAX_FALL = 24.0
const GLIDE_SPEED = 8.0
const GLIDE_ACCEL = 10.0
const GLIDE_FALL_SPEED = 2.1
const CLIMB_SPEED = 4.6
const LEAP_SPEED = 8.5
const HALF_HEIGHT = 0.425
const TRUNK_OFFSET = 0.68
const WATER_RESPAWN_Y = -0.9
var stamina = 100.0
var climbing = false
var gliding = false
var facing = 1.0
var trunk: Node3D
var climb_side = -1.0
var climb_input = 0.0
var nearby_trunks: Array[Node3D] = []
var ignored_platforms = {}
var coyote = 0.0
var jump_buffer = 0.0
var regrab = 0.0
var drop_timer = 0.0
var opening = 0.0
var squash = 0.0
var anim_time = 0.0
var spawn_point = Vector3(-6, 1, 0)
var visual: Node3D
var membrane: Node3D
var arms: Array[Node3D] = []
var legs: Array[Node3D] = []
var tail: Node3D
var forest: Node3D

func _ready():
	forest = get_parent()
	axis_lock_linear_z = true
	var shape = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	capsule.radius = 0.23
	capsule.height = HALF_HEIGHT*2
	shape.shape = capsule
	add_child(shape)
	visual = Node3D.new()
	add_child(visual)
	_build_squirrel()
	position = spawn_point

func _build_squirrel():
	# Side-profile flying squirrel: head toward +x, symmetric in z so it reads facing either way.
	var rust = Color("b0592f")
	var cream = Color("f3e2bc")
	var fur = {"rim": 0.35}
	membrane = Node3D.new()
	visual.add_child(membrane)
	forest.ellipsoid(membrane, Vector3(0,-0.04,0), Vector3(1,1,1), Color("c98a5c"), fur)
	membrane.scale = Vector3(0.2,0.05,0.2)
	forest.ellipsoid(visual, Vector3(0,0,0), Vector3(0.33,0.40,0.26), rust, fur)
	forest.ellipsoid(visual, Vector3(0.10,-0.08,0), Vector3(0.24,0.30,0.22), cream, fur)
	forest.ellipsoid(visual, Vector3(0.17,0.40,0), Vector3(0.28,0.25,0.24), rust, fur)
	forest.ellipsoid(visual, Vector3(0.36,0.33,0), Vector3(0.18,0.12,0.15), cream, fur)
	forest.ellipsoid(visual, Vector3(0.52,0.35,0), Vector3(0.045,0.04,0.05), Color("3b2a2a"))
	for z in [-0.19,0.19]:
		forest.ellipsoid(visual, Vector3(0.12,0.63,z*0.7), Vector3(0.08,0.15,0.07), rust, fur)
		# Big dark flying-squirrel eyes with a crisp highlight.
		forest.ellipsoid(visual, Vector3(0.29,0.45,z*0.92), Vector3(0.075,0.085,0.05), Color("1f2223"))
		forest.ellipsoid(visual, Vector3(0.32,0.48,z*1.1), Vector3(0.022,0.026,0.02), Color.WHITE)
		var arm = Node3D.new()
		visual.add_child(arm)
		arm.position = Vector3(0.14,0.10,z)
		forest.ellipsoid(arm, Vector3(0,-0.15,0), Vector3(0.08,0.2,0.085), rust, fur)
		arms.append(arm)
		var leg = Node3D.new()
		visual.add_child(leg)
		leg.position = Vector3(-0.10,-0.22,z)
		forest.ellipsoid(leg, Vector3(0.06,-0.12,0), Vector3(0.17,0.12,0.09), rust, fur)
		legs.append(leg)
	tail = Node3D.new()
	visual.add_child(tail)
	tail.position = Vector3(-0.26,-0.14,0)
	# Flying squirrels have a broad, flattened tail.
	forest.ellipsoid(tail, Vector3(-0.30,0.22,0), Vector3(0.24,0.42,0.12), rust.lightened(0.05), fur)
	forest.ellipsoid(tail, Vector3(-0.28,0.58,0), Vector3(0.22,0.24,0.11), rust.lightened(0.14), fur)

func _physics_process(delta):
	anim_time += delta
	var direction = Input.get_axis("left", "right")
	if direction != 0:
		facing = signf(direction)
	coyote = 0.12 if is_on_floor() else maxf(0,coyote-delta)
	jump_buffer = maxf(0,jump_buffer-delta)
	regrab = maxf(0,regrab-delta)
	drop_timer = maxf(0,drop_timer-delta)
	if Input.is_action_just_pressed("jump"):
		jump_buffer = 0.12
	if climbing and Input.is_action_just_pressed("attach"):
		_release()
	elif not climbing and regrab == 0 and not nearby_trunks.is_empty() and (Input.is_action_just_pressed("attach") or Input.is_action_pressed("up")):
		_grip()
	if climbing:
		_climb(delta, direction)
	else:
		_move(delta, direction)
	position.z = 0
	stamina = clampf(stamina + (-100.0/3.0 if gliding else 100.0/7.0)*delta, 0,100)
	if position.y < WATER_RESPAWN_Y or Input.is_action_just_pressed("restart"):
		respawn()
	_animate(delta,direction)

func trunk_x(tree: Node3D, y: float) -> float:
	# Trunks lean slightly: the mesh runs from (0,-0.5) to (0.15,height).
	return tree.position.x + 0.15*(y+0.5)/(float(tree.get_meta("height"))+0.5)

func _grip():
	trunk = nearby_trunks[0]
	for candidate in nearby_trunks:
		if absf(candidate.position.x-position.x) < absf(trunk.position.x-position.x):
			trunk = candidate
	var offset = position.x - trunk_x(trunk, position.y)
	climb_side = signf(offset) if absf(offset) > 0.05 else -facing
	climbing = true
	gliding = false
	velocity = Vector3.ZERO

func _release():
	climbing = false
	regrab = 0.3

func _climb(delta, direction):
	if direction != 0:
		climb_side = signf(direction)
	facing = -climb_side
	climb_input = Input.get_axis("down","up")
	var bottom = HALF_HEIGHT + 0.08
	position.y = clampf(position.y + climb_input*CLIMB_SPEED*delta, bottom, float(trunk.get_meta("height")))
	position.x = move_toward(position.x, trunk_x(trunk, position.y) + climb_side*TRUNK_OFFSET, delta*10)
	if jump_buffer > 0:
		# Leap away on the side the squirrel is clinging to (the held direction).
		_release()
		jump_buffer = 0
		coyote = 0
		facing = climb_side
		velocity = Vector3(climb_side*LEAP_SPEED, JUMP_SPEED*0.9, 0)
		squash = -0.25
	elif climb_input < 0 and position.y <= bottom:
		_release()

func _move(delta, direction):
	var on_floor = is_on_floor()
	var want_glide = Input.is_action_pressed("glide") and not on_floor and stamina > 0 and velocity.y < 1.0
	if want_glide and not gliding:
		opening = 0.18
		forest.glide_pulse = 0.18
	gliding = want_glide
	opening = maxf(0,opening-delta)
	if gliding:
		# A glide keeps carrying the squirrel forward even without input.
		var glide_direction = direction if direction != 0 else facing
		velocity.x = move_toward(velocity.x, glide_direction*GLIDE_SPEED, GLIDE_ACCEL*delta)
	elif on_floor:
		velocity.x = move_toward(velocity.x, direction*RUN_SPEED, GROUND_ACCEL*delta)
	elif direction != 0 and (signf(velocity.x) != direction or absf(velocity.x) < RUN_SPEED):
		velocity.x = move_toward(velocity.x, direction*RUN_SPEED, AIR_ACCEL*delta)
	else:
		# Preserve leap momentum in the air; only bleed off gently.
		velocity.x = move_toward(velocity.x, direction*RUN_SPEED if direction != 0 else 0.0, AIR_DRAG*delta)
	if jump_buffer > 0 and coyote > 0:
		if Input.is_action_pressed("down") and _standing_on_platform():
			drop_timer = 0.25
		else:
			velocity.y = JUMP_SPEED
			squash = -0.25
		jump_buffer = 0
		coyote = 0
	if Input.is_action_just_released("jump") and velocity.y > 0 and not gliding:
		velocity.y *= JUMP_CUT
	if gliding:
		velocity.y = move_toward(velocity.y, -GLIDE_FALL_SPEED, 100.0*delta)
	else:
		velocity.y = maxf(velocity.y-(GRAVITY if velocity.y > 0 else FALL_GRAVITY)*delta,-MAX_FALL)
	var fall_speed = -velocity.y
	_update_platforms()
	move_and_slide()
	if is_on_floor() and not on_floor and fall_speed > 4.0:
		squash = clampf(fall_speed/40.0, 0.1, 0.35)

func _update_platforms():
	# Branches are one-way: they only collide once the squirrel's feet are above their top.
	var feet = position.y - HALF_HEIGHT
	for platform in forest.platforms:
		var pass_through = drop_timer > 0 or feet < float(platform.get_meta("top")) - 0.08
		if pass_through and not ignored_platforms.has(platform):
			add_collision_exception_with(platform)
			ignored_platforms[platform] = true
		elif not pass_through and ignored_platforms.has(platform):
			remove_collision_exception_with(platform)
			ignored_platforms.erase(platform)

func _standing_on_platform() -> bool:
	for i in get_slide_collision_count():
		var collision = get_slide_collision(i)
		if collision.get_normal().y > 0.7 and collision.get_collider() in forest.platforms:
			return true
	return false

func _animate(delta, direction):
	var blend = 1-exp(-delta*14)
	var running = is_on_floor() and absf(direction)>0 and not climbing
	var climbing_moving = climbing and climb_input != 0
	var yaw = 0.0 if facing > 0 else PI
	# Pitch the body along its motion; tilt the belly toward camera while gliding so the membrane reads.
	var pitch = 0.0
	var tilt = 0.0
	if climbing: pitch = PI*0.46
	elif gliding: pitch = -0.08; tilt = 0.85*facing
	elif not is_on_floor(): pitch = clampf(velocity.y*0.035, -0.35, 0.3)
	elif running: pitch = -0.1
	visual.rotation.y = lerp_angle(visual.rotation.y, yaw, delta*16)
	visual.rotation.x = lerp_angle(visual.rotation.x, tilt, blend)
	visual.rotation.z = lerp_angle(visual.rotation.z, pitch, blend)
	squash = lerpf(squash, 0.0, 1-exp(-delta*10))
	visual.scale = Vector3(1+squash*0.6, 1-squash, 1+squash*0.6)
	var open = 1.15 if opening > 0 else 1.0
	membrane.scale = membrane.scale.lerp(Vector3(0.5,0.035,0.55)*open if gliding else Vector3(0.2,0.05,0.2), 1-exp(-delta*(30 if gliding else 10)))
	for i in range(2):
		var side = 1.0 if i == 0 else -1.0
		var phase = anim_time*(15.0 if running else 10.0) + i*PI
		var swing = sin(phase)*0.6 if running or climbing_moving else 0.0
		# Glide: limbs splay outward (toward ±z) to stretch the membrane.
		arms[i].rotation.x = lerp_angle(arms[i].rotation.x, side*1.25 if gliding else 0.0, blend)
		legs[i].rotation.x = lerp_angle(legs[i].rotation.x, side*1.1 if gliding else 0.0, blend)
		arms[i].rotation.z = lerp_angle(arms[i].rotation.z, 0.5 if gliding else (swing if running or climbing else -0.25), blend)
		legs[i].rotation.z = lerp_angle(legs[i].rotation.z, -0.5 if gliding else -swing, blend)
	var trail = clampf(-velocity.y*0.04, -0.4, 0.5) if not climbing else -0.3
	tail.rotation.z = lerp_angle(tail.rotation.z, sin(anim_time*4)*0.08 + (0.9 if gliding else trail), blend)

func respawn():
	position = spawn_point
	velocity = Vector3.ZERO
	stamina = 100
	climbing = false
	gliding = false
	coyote = 0
	jump_buffer = 0
	regrab = 0
	drop_timer = 0
	opening = 0
	squash = 0
	reset_physics_interpolation()
	forest.reset_camera()

func movement_state() -> String:
	if climbing: return "CLIMBING"
	if gliding: return "GLIDING"
	if is_on_floor(): return "RUNNING" if absf(velocity.x)>0.2 else "RESTING"
	return "RISING" if velocity.y>0 else "FALLING"
