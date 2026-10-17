extends CharacterBody3D

const MODEL = preload("res://assets/characters/squirrel.glb")
const MODEL_SCALE = 1.25
const RUN_ANIM_RATE = 1.6 # run cycles play this much faster than authored at full speed

const RUN_SPEED = 6.5
const GROUND_ACCEL = 40.0
const AIR_ACCEL = 16.0
const AIR_DRAG = 3.0
const JUMP_SPEED = 9.0
const GRAVITY = 25.0
const FALL_GRAVITY = 32.0
const MAX_FALL = 24.0
const GLIDE_SPEED = 8.0
const GLIDE_ACCEL = 10.0
const GLIDE_FALL_SPEED = 2.1
const CLIMB_SPEED = 4.6
const LEAP_SPEED = 6.8
const LEAP_LIFT = 7.0
const HALF_HEIGHT = 0.425
const TRUNK_OFFSET = 0.68
const WATER_RESPAWN_Y = -0.9
const HUG_DISTANCE = 0.75
const HUG_PAUSE = 0.12
const TIP_DETENT = 0.22
const BRANCH_CHARGE_TIME = 0.45
const BRANCH_LAUNCH_SPEED = 15.0
const BRANCH_INNER_LAUNCH_SPEED = 13.5
const LAND_IMPULSE = 0.12
const CLING_RADIUS = 0.82 # body centre from trunk centre while climbing
const CLING_FRONT = 0.6 # radians the cling spot sits toward the camera from the trunk's side
const ORBIT_SPEED = 10.0 # radians/s when scurrying around to the other side
const TRUNK_RADIUS = 0.56 # trunk kit radius; fork limbs scale it down by their girth
var stamina = 100.0
var climbing = false
var gliding = false
var facing = 1.0
var trunk: Node3D
var climb_side = -1.0
var limb = 0.0 # fork limb (side) being climbed above the split; 0 below it
var climb_input = 0.0
var nearby_trunks: Array[Node3D] = []
var branch: Node3D
var dropped_branch: Node3D
var hug_pause = 0.0
var detent = 0.0
var crouching = false
var coyote = 0.0
var jump_buffer = 0.0
var jump_armed = false
var branch_charge = 0.0
var regrab = 0.0
var drop_timer = 0.0
var opening = 0.0
var squash = 0.0
var climb_angle = 0.0
var cling_time = 0.0
var spawn_point = Vector3(-6, 1, 0)
var visual: Node3D
var anim: AnimationPlayer
var jump_time = 0.0 # scrub position in the jump action while airborne
var landing = 0.0
var was_airborne = false
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
	# Drawn just in front of trunks and branches (z=0) so the squirrel is never hidden;
	# _animate moves it around the trunk while climbing.
	visual.position.z = 0.55
	add_child(visual)
	_build_squirrel()
	position = spawn_point

func _build_squirrel():
	# Rigged flying squirrel from tools/blender/squirrel.py: faces +x, feet at y=0.
	var model = MODEL.instantiate()
	visual.add_child(model)
	model.scale = Vector3.ONE*MODEL_SCALE
	model.position.y = -HALF_HEIGHT
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = forest.paint(Color.WHITE, {"use_vertex_color": true, "rim": 0.35, "pigment_strength": 0.08})
	anim = model.find_children("*", "AnimationPlayer", true, false)[0]
	for loop in ["run", "glide", "idle"]:
		anim.get_animation(loop).loop_mode = Animation.LOOP_LINEAR
	anim.play("idle")

func _physics_process(delta):
	var direction = Input.get_axis("left", "right")
	if direction != 0:
		facing = signf(direction)
	coyote = 0.12 if grounded() else maxf(0,coyote-delta)
	jump_buffer = maxf(0,jump_buffer-delta)
	regrab = maxf(0,regrab-delta)
	drop_timer = maxf(0,drop_timer-delta)
	if Input.is_action_just_pressed("jump"):
		jump_armed = not climbing
		if climbing: jump_buffer = 0.12 # Trunk leaps still happen on press.
	if Input.is_action_just_released("jump") and jump_armed:
		jump_buffer = 0.12
		jump_armed = false
	if climbing and Input.is_action_just_pressed("attach"):
		_release()
	elif not climbing and regrab == 0 and not nearby_trunks.is_empty() and _grip_requested():
		_grip(_nearest_trunk())
	if climbing:
		_climb(delta, direction)
	elif branch:
		_run_branch(delta, direction)
	else:
		_move(delta, direction)
	position.z = 0
	# No recovery while glide is held: an exhausted glide drops into a full fall
	# until the player lets go, instead of flickering open on each sliver of stamina.
	if gliding:
		stamina -= 100.0/3.0*delta
	elif not Input.is_action_pressed("glide"):
		stamina += 100.0/7.0*delta
	stamina = clampf(stamina, 0, 100)
	if position.y < WATER_RESPAWN_Y or Input.is_action_just_pressed("restart"):
		respawn()
	_animate(delta,direction)

func grounded() -> bool:
	return is_on_floor() or branch != null

func trunk_x(tree: Node3D, y: float) -> float:
	return tree.position.x + _climb_line(tree, y).x

func _climb_line(tree: Node3D, y: float) -> Vector4:
	# Where the climb line is at height y: (x offset, z offset, girth, lean dx/dy).
	# Straight up the trunk, then along the fork limb being climbed.
	var path = tree.get_meta("climb_paths")[limb if limb != 0 else climb_side]
	for i in range(1, path.size()):
		var a = path[i-1]
		var b = path[i]
		if y <= b.y or i == path.size()-1:
			var at = a.lerp(b, clampf((y-a.y)/(b.y-a.y), 0, 1))
			return Vector4(at.x, at.z, at.w, (b.x-a.x)/(b.y-a.y))
	return Vector4(0, 0, 1, 0)

func _nearest_trunk() -> Node3D:
	var nearest = nearby_trunks[0]
	for candidate in nearby_trunks:
		if absf(candidate.position.x-position.x) < absf(nearest.position.x-position.x):
			nearest = candidate
	return nearest

func _grip(tree: Node3D, side = 0.0):
	_leave_branch()
	trunk = tree
	limb = 0.0
	var offset = position.x - trunk.position.x
	if side == 0.0:
		side = signf(offset) if absf(offset) > 0.05 else -facing
	climb_side = side
	climb_angle = _cling_angle()
	climbing = true
	gliding = false
	crouching = false
	velocity = Vector3.ZERO

func _release():
	climbing = false
	hug_pause = 0
	regrab = 0.3

func _grip_requested() -> bool:
	# Holding W only catches trunks in the air, so running along a branch with W held doesn't re-grip.
	if Input.is_action_just_pressed("attach") or Input.is_action_just_pressed("up"):
		return true
	return Input.is_action_pressed("up") and not grounded()

func _branch_beside(side: float) -> Node3D:
	# A branch on the held side whose base is near the squirrel's feet (generous below, so it hops up).
	var feet = position.y - HALF_HEIGHT
	for candidate in forest.branches:
		if candidate.tree == trunk and candidate.side == side:
			var top = candidate.surface_y(candidate.position.x + side*0.5)
			if feet > top - 0.5 and feet < top + 0.6:
				return candidate
	return null

func _climb(delta, direction):
	# After hugging the trunk from a branch, a short beat lets the hug read; keep
	# holding the run direction and the squirrel swings around to the far side.
	hug_pause = maxf(0, hug_pause-delta)
	var steer = direction if hug_pause == 0 else 0.0
	if steer != 0:
		climb_side = signf(steer)
	facing = -climb_side
	climb_input = Input.get_axis("down","up")
	var bottom = HALF_HEIGHT + 0.08
	# Above the split, stay on the limb taken; switching sides goes around that limb.
	var path = trunk.get_meta("climb_paths")[limb if limb != 0 else climb_side]
	if position.y <= path[1].y: limb = 0.0
	elif limb == 0: limb = climb_side
	position.y = clampf(position.y + climb_input*CLIMB_SPEED*delta, bottom, path[-1].y)
	var line = _climb_line(trunk, position.y)
	var offset = TRUNK_OFFSET - TRUNK_RADIUS*(1-line.z)
	position.x = move_toward(position.x, trunk.position.x + line.x + climb_side*offset, delta*10)
	var beside = _branch_beside(climb_side) if steer != 0 else null
	if beside and jump_buffer == 0:
		_release()
		facing = climb_side
		position.x = beside.position.x + climb_side*0.5
		velocity = Vector3(climb_side*RUN_SPEED, 0, 0)
		_land_on(beside, 0.0)
	elif jump_buffer > 0:
		# Leap away on the side the squirrel is clinging to (the held direction).
		_release()
		jump_buffer = 0
		coyote = 0
		facing = climb_side
		velocity = Vector3(climb_side*LEAP_SPEED, LEAP_LIFT, 0)
		squash = -0.25
	elif climb_input < 0 and position.y <= bottom:
		_release()

func _land_on(target: Node3D, fall_speed: float):
	branch = target
	jump_armed = false # Landing with Space held must not charge or jump on release.
	detent = 0
	velocity.y = 0
	gliding = false
	position.y = branch.surface_y(position.x) + HALF_HEIGHT
	branch.impulse(position.x, -fall_speed*LAND_IMPULSE)
	if fall_speed > 4.0:
		squash = clampf(fall_speed/40.0, 0.1, 0.35)

func _leave_branch():
	if branch:
		branch.release()
	branch = null
	if crouching: jump_armed = false
	crouching = false
	branch_charge = 0.0

func _run_branch(delta, direction):
	gliding = false
	if (Input.is_action_pressed("down") and Input.is_action_just_pressed("jump")) or (crouching and Input.is_action_just_pressed("down")):
		# Drop immediately and consume the release so it cannot trigger another jump.
		dropped_branch = branch
		drop_timer = 0.3
		jump_buffer = 0
		jump_armed = false
		coyote = 0
		_leave_branch()
		velocity.y = -1.0
		return
	if Input.is_action_just_pressed("jump"):
		crouching = true
		branch_charge = 0.0
	if crouching:
		if Input.is_action_pressed("jump"):
			branch_charge = minf(1.0, branch_charge + delta/BRANCH_CHARGE_TIME)
		velocity.x = 0 # Plant feet, even at the tip; A/D now aims the release.
	else:
		velocity.x = move_toward(velocity.x, direction*RUN_SPEED, GROUND_ACCEL*delta)
	var x = position.x + velocity.x*delta
	var toward_trunk = direction != 0 and signf(direction) == -branch.side
	if not crouching and toward_trunk and absf(x - trunk_x(branch.tree, position.y)) < HUG_DISTANCE:
		# Squirrels hug back onto the trunk instead of running off the inside end.
		var side = branch.side
		_grip(branch.tree, side)
		hug_pause = HUG_PAUSE
		return
	var past_tip = (x - branch.tip_x())*branch.side > 0
	if past_tip:
		# Detent: the squirrel pauses at the tip; keep holding outward to run off.
		var outward = direction != 0 and signf(direction) == branch.side
		detent += delta if outward else 0.0
		if detent < TIP_DETENT:
			x = branch.tip_x()
			velocity.x = 0
		else:
			_leave_branch()
			position.x = x
			velocity.x = direction*RUN_SPEED*0.6
			return
	else:
		detent = 0
	position.x = x
	branch.carry(x, 1.0, branch_charge)
	position.y = branch.surface_y(x) + HALF_HEIGHT
	if jump_buffer > 0:
		jump_buffer = 0
		coyote = 0
		# Charge determines the launch, independent of the spring's current phase.
		var strength = smoothstep(0.0, 0.5, branch.t_at(x))
		var full_speed = lerpf(BRANCH_INNER_LAUNCH_SPEED, BRANCH_LAUNCH_SPEED, strength)
		velocity.y = lerpf(JUMP_SPEED, full_speed, branch_charge)
		if crouching: velocity.x = direction*LEAP_SPEED
		branch.impulse(x, 2.0*branch_charge)
		squash = -0.25
		_leave_branch()

func _move(delta, direction):
	var on_floor = is_on_floor()
	var want_glide = Input.is_action_pressed("glide") and not on_floor and stamina > 0 and velocity.y < 1.0 and not (jump_buffer > 0 and coyote > 0)
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
		velocity.y = JUMP_SPEED
		squash = -0.25
		jump_buffer = 0
		coyote = 0
	if gliding:
		velocity.y = move_toward(velocity.y, -GLIDE_FALL_SPEED, 100.0*delta)
	else:
		velocity.y = maxf(velocity.y-(GRAVITY if velocity.y > 0 else FALL_GRAVITY)*delta,-MAX_FALL)
	var fall_speed = -velocity.y
	var previous_feet = position.y - HALF_HEIGHT
	move_and_slide()
	if is_on_floor() and not on_floor and fall_speed > 4.0:
		squash = clampf(fall_speed/40.0, 0.1, 0.35)
	if velocity.y <= 0:
		_catch_branch(previous_feet, fall_speed)

func _catch_branch(previous_feet: float, fall_speed: float):
	# Branches are one-way: land only when the feet cross the surface from above.
	var feet = position.y - HALF_HEIGHT
	for candidate in forest.branches:
		if candidate == dropped_branch and drop_timer > 0:
			continue
		if candidate.contains(position.x):
			var top = candidate.surface_y(position.x)
			if previous_feet >= top - 0.05 and feet <= top + 0.02:
				_land_on(candidate, fall_speed)
				return

func _cling_angle() -> float:
	# 0 = trunk's right edge, PI = left edge, PI/2 = facing the camera.
	return CLING_FRONT if climb_side > 0 else PI - CLING_FRONT

func _animate(delta, direction):
	var running = grounded() and absf(direction)>0 and not climbing and not crouching
	var target: Basis
	var target_position = Vector3(0,0,0.55) # just in front of trunks and branches
	var scurrying = false
	if climbing:
		# Cling to the bark like the reference squirrels: belly to the trunk, head up,
		# on the camera-facing edge. Switching sides scurries around the front of the trunk.
		var goal = _cling_angle()
		var orbiting = absf(climb_angle-goal) > 0.01
		climb_angle = move_toward(climb_angle, goal, delta*ORBIT_SPEED)
		scurrying = climb_input != 0 or orbiting
		var outward = Vector3(cos(climb_angle), 0, sin(climb_angle))
		var line = _climb_line(trunk, position.y)
		# The model runs along +x with its back to +y: nose up the trunk, belly to the bark.
		# On a fork limb the spine leans with it.
		target = Basis(Vector3.BACK, -atan(line.w)) * Basis(Vector3.UP, outward, Vector3.UP.cross(outward))
		target_position = Vector3(trunk.position.x + line.x - position.x, 0, line.y) + outward*(CLING_RADIUS - TRUNK_RADIUS*(1-line.z))
	else:
		# Pitch the body along its motion; tilt the belly toward camera while gliding so the membrane reads.
		var pitch = 0.0
		var tilt = 0.0
		if gliding: pitch = -0.08; tilt = -0.85*facing
		elif not grounded(): pitch = clampf(velocity.y*0.035, -0.35, 0.3)
		elif running: pitch = -0.1
		target = Basis.from_euler(Vector3(tilt, 0.0 if facing > 0 else PI, pitch))
	var fast = 1-exp(-delta*16)
	visual.quaternion = visual.quaternion.slerp(target.get_rotation_quaternion(), fast)
	# Ease onto the trunk, then follow the orbit exactly so swings arc around the front
	# of the trunk instead of cutting through it.
	cling_time = cling_time + delta if climbing else 0.0
	visual.position = target_position if cling_time > 0.2 else visual.position.lerp(target_position, fast)
	squash = lerpf(squash, 0.0, 1-exp(-delta*10))
	var crouch = lerpf(0.08, 0.3, branch_charge) if crouching and not climbing else 0.0
	visual.scale = Vector3(1+(squash+crouch)*0.6, 1-squash-crouch, 1+(squash+crouch)*0.6)
	_play_animation(delta, running, scurrying)

func _play_animation(delta, running, scurrying):
	var airborne = not climbing and not gliding and not grounded()
	if was_airborne and not airborne and grounded() and not running:
		landing = 0.15
	was_airborne = airborne
	landing = maxf(0, landing-delta)
	if airborne:
		# Scrub the jump by vertical speed: launch while rising fast, stretch at the peak,
		# reach for the ground while falling.
		var rise = velocity.y/JUMP_SPEED
		var goal = lerpf(0.6, 0.3, clampf(rise, 0, 1)) if rise > 0 else lerpf(0.62, 0.82, clampf(-velocity.y/10.0, 0, 1))
		if anim.current_animation != "jump" or landing > 0:
			jump_time = goal
			anim.play("jump", 0.1)
		jump_time = move_toward(jump_time, goal, delta*1.5)
		anim.speed_scale = 1.0
		anim.seek(jump_time, true)
	elif landing > 0:
		if anim.current_animation != "jump":
			anim.play("jump", 0.05)
		if anim.current_animation_position < 0.86:
			anim.seek(0.86, true)
		anim.speed_scale = 1.5
	elif gliding:
		# The rip-cord opening snaps the limbs out; settling into a glide blends softer.
		_switch("glide", 0.08 if opening > 0 else 0.2, 1.0)
	elif climbing:
		# The gallop doubles as the bounding climb gait; stand still against the bark otherwise.
		if scurrying: _switch("run", 0.15, 1.3)
		else: _switch("idle", 0.25, 1.0)
	elif running:
		_switch("run", 0.15, clampf(absf(velocity.x)/RUN_SPEED, 0.4, 1.2)*RUN_ANIM_RATE)
	else:
		_switch("idle", 0.25, 1.0)

func _switch(animation: String, blend: float, speed: float):
	if anim.current_animation != animation:
		anim.play(animation, blend)
	anim.speed_scale = speed

func respawn():
	position = spawn_point
	velocity = Vector3.ZERO
	stamina = 100
	_leave_branch()
	climbing = false
	gliding = false
	hug_pause = 0
	coyote = 0
	jump_buffer = 0
	jump_armed = false
	regrab = 0
	drop_timer = 0
	opening = 0
	squash = 0
	reset_physics_interpolation()
	forest.reset_camera()

func movement_state() -> String:
	if crouching: return "CHARGED" if branch_charge >= 1.0 else "CHARGING"
	if climbing: return "CLIMBING"
	if gliding: return "GLIDING"
	if grounded(): return "RUNNING" if absf(velocity.x)>0.2 else "RESTING"
	return "RISING" if velocity.y>0 else "FALLING"
