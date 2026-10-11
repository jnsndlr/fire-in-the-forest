extends CharacterBody3D

const RUN_SPEED = 6.5
const JUMP_SPEED = 9.0
const GRAVITY = 25.0
const GLIDE_SPEED = 8.0
const GLIDE_FALL_SPEED = 2.1
var stamina = 100.0
var climbing = false
var gliding = false
var facing = 1.0
var trunk: Node3D
var nearby_trunks: Array[Node3D] = []
var coyote = 0.0
var jump_buffer = 0.0
var opening = 0.0
var anim_time = 0.0
var spawn_point = Vector3(-6, 1, 0)
var visual: Node3D
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
	capsule.height = 0.85
	shape.shape = capsule
	add_child(shape)
	visual = Node3D.new()
	add_child(visual)
	_build_squirrel()
	position = spawn_point

func _build_squirrel():
	var rust = Color("a75d38")
	var cream = Color("eed9af")
	forest.ellipsoid(visual, Vector3(0,0,0), Vector3(0.31,0.43,0.25), rust)
	forest.ellipsoid(visual, Vector3(0.05,-0.03,0.17), Vector3(0.23,0.32,0.13), cream)
	forest.ellipsoid(visual, Vector3(0.16,0.40,0), Vector3(0.28,0.25,0.24), rust)
	forest.ellipsoid(visual, Vector3(0.37,0.36,0), Vector3(0.19,0.12,0.15), cream)
	forest.ellipsoid(visual, Vector3(0.51,0.37,0), Vector3(0.045,0.045,0.065), Color("493b3b"))
	for z in [-0.19,0.19]:
		forest.ellipsoid(visual, Vector3(0.17,0.64,z*0.65), Vector3(0.09,0.17,0.075), rust)
		forest.ellipsoid(visual, Vector3(0.27,0.47,z), Vector3(0.055,0.065,0.035), Color("252b2a"))
		forest.ellipsoid(visual, Vector3(0.285,0.49,z*1.08), Vector3(0.017,0.02,0.015), Color.WHITE)
		var arm = Node3D.new()
		visual.add_child(arm)
		arm.position = Vector3(0.10,0.12,z)
		forest.ellipsoid(arm, Vector3(0,-0.15,0), Vector3(0.09,0.22,0.095), rust)
		arms.append(arm)
		var leg = Node3D.new()
		visual.add_child(leg)
		leg.position = Vector3(-0.08,-0.22,z)
		forest.ellipsoid(leg, Vector3(0.08,-0.12,0), Vector3(0.18,0.12,0.095), rust)
		legs.append(leg)
	tail = Node3D.new()
	visual.add_child(tail)
	tail.position = Vector3(-0.23,-0.12,0)
	forest.ellipsoid(tail, Vector3(-0.25,0.32,0), Vector3(0.23,0.49,0.24), rust)
	forest.ellipsoid(tail, Vector3(-0.20,0.70,0), Vector3(0.25,0.28,0.22), rust.lightened(0.08))

func _physics_process(delta):
	anim_time += delta
	var direction = Input.get_axis("left", "right")
	if direction != 0:
		facing = sign(direction)
	coyote = 0.12 if is_on_floor() else maxf(0,coyote-delta)
	jump_buffer = maxf(0,jump_buffer-delta)
	if Input.is_action_just_pressed("jump"):
		jump_buffer = 0.12
	if Input.is_action_just_pressed("attach"):
		if climbing:
			climbing = false
		elif not nearby_trunks.is_empty():
			trunk = nearby_trunks[0]
			for candidate in nearby_trunks:
				if absf(candidate.position.x-position.x) < absf(trunk.position.x-position.x):
					trunk = candidate
			climbing = true
	if climbing:
		gliding = false
		velocity = Vector3.ZERO
		position.x = move_toward(position.x, trunk.position.x + facing*0.25, delta*8)
		position.y = clampf(position.y + Input.get_axis("down","up")*4.2*delta, 0.5, float(trunk.get_meta("height")))
		if jump_buffer > 0:
			climbing = false
			jump_buffer = 0
			velocity = Vector3((direction if direction != 0 else facing)*8.5, JUMP_SPEED*0.9, 0)
			coyote = 0
	else:
		var want_glide = Input.is_action_pressed("glide") and not is_on_floor() and stamina > 0 and velocity.y < 1.0
		if want_glide and not gliding:
			opening = 0.18
			forest.glide_pulse = 0.18
		gliding = want_glide
		opening = maxf(0,opening-delta)
		velocity.x = move_toward(velocity.x, direction*(GLIDE_SPEED if gliding else RUN_SPEED), (13.0 if gliding else 35.0)*delta)
		if jump_buffer > 0 and coyote > 0:
			velocity.y = JUMP_SPEED
			jump_buffer = 0
			coyote = 0
		if gliding:
			velocity.y = move_toward(velocity.y, -GLIDE_FALL_SPEED, 100.0*delta)
		else:
			velocity.y = maxf(velocity.y-GRAVITY*delta,-24.0)
		move_and_slide()
	position.z = 0
	stamina = clampf(stamina + (-100.0/3.0 if gliding else 100.0/7.0)*delta, 0,100)
	if position.y < -5 or Input.is_action_just_pressed("restart"):
		respawn()
	_animate(delta,direction)

func _animate(delta, direction):
	visual.rotation.y = lerp_angle(visual.rotation.y, 0.0 if facing > 0 else PI, delta*18)
	visual.rotation.z = lerp_angle(visual.rotation.z, -0.12 if gliding else 0.0,delta*10)
	var running = is_on_floor() and absf(direction)>0
	for i in range(2):
		var phase = anim_time*15.0 + i*PI
		arms[i].rotation.z = lerp_angle(arms[i].rotation.z, (1.3 if i == 0 else -1.3) if gliding else (sin(phase)*0.5 if running or climbing else -0.25),delta*16)
		legs[i].rotation.z = lerp_angle(legs[i].rotation.z, -0.6 if gliding else (sin(phase+PI)*0.6 if running or climbing else 0.0),delta*16)
	tail.rotation.z = sin(anim_time*4)*0.08 + (0.4 if gliding else 0.0)

func respawn():
	position = spawn_point
	velocity = Vector3.ZERO
	stamina = 100
	climbing = false
	gliding = false
	coyote = 0
	jump_buffer = 0
	opening = 0
	forest.reset_camera()

func movement_state() -> String:
	if climbing: return "CLIMBING"
	if gliding: return "GLIDING"
	if is_on_floor(): return "RUNNING" if absf(velocity.x)>0.2 else "RESTING"
	return "RISING" if velocity.y>0 else "FALLING"
