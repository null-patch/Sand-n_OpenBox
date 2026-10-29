extends Node3D

const CHUNK_SIZE := 32.0
const LOAD_RADIUS := 4              # 9x9 chunks around the player
const LOADS_PER_FRAME := 2          # spreads loading out to avoid hitches on weak PCs
const MAX_PROPS_PER_CHUNK := 150
const REACH := 80.0
const SPEED := 6.0
const JUMP := 6.0
const SAVE_DIR := "user://world"
const TYPE_NAMES := ["Box", "Sphere", "Cylinder"]
const PROP_COLORS := [
	Color(0.9, 0.3, 0.25), Color(0.2, 0.6, 0.9), Color(0.2, 0.8, 0.4),
	Color(0.95, 0.8, 0.2), Color(0.6, 0.3, 0.8), Color(0.9, 0.9, 0.9)
]

var gravity := 9.8
var world: Node3D
var chunk_nodes := {}      # Vector2i -> Node3D (loaded chunks only)
var chunk_data := {}       # Vector2i -> {"props": Array, "next_id": int}
var wanted := {}           # Vector2i -> true
var load_queue: Array = []
var player_chunk := Vector2i(-999999, -999999)
var player: CharacterBody3D
var head: Node3D
var camera: Camera3D
var hud: Label
var ground_mat: StandardMaterial3D
var prop_mats: Array = []
var prop_meshes: Array = []
var prop_shapes: Array = []
var current_type := 0
var mouse_captured := true


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	_build_environment()
	_build_prop_assets()
	world = Node3D.new()
	world.name = "World"
	add_child(world)
	_build_player()
	_build_hud()

	# Load the spawn chunk synchronously so the player doesn't fall through the void.
	player_chunk = Vector2i.ZERO
	_load_chunk(Vector2i.ZERO)
	_refresh_chunks()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(_delta: float) -> void:
	var pc := _chunk_of(player.global_position)
	if pc != player_chunk:
		player_chunk = pc
		_refresh_chunks()
	_process_load_queue()
	_update_hud()


func _physics_process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W): dir.z -= 1
	if Input.is_physical_key_pressed(KEY_S): dir.z += 1
	if Input.is_physical_key_pressed(KEY_A): dir.x -= 1
	if Input.is_physical_key_pressed(KEY_D): dir.x += 1
	dir = (player.global_basis * dir).normalized()

	player.velocity.x = dir.x * SPEED
	player.velocity.z = dir.z * SPEED
	if player.is_on_floor():
		if Input.is_physical_key_pressed(KEY_SPACE):
			player.velocity.y = JUMP
	else:
		player.velocity.y -= gravity * delta
	player.move_and_slide()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			mouse_captured = not mouse_captured
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mouse_captured else Input.MOUSE_MODE_VISIBLE
		elif event.keycode == KEY_E:
			current_type = (current_type + 1) % TYPE_NAMES.size()

	if not mouse_captured:
		return

	if event is InputEventMouseMotion:
		player.rotate_y(-event.relative.x * 0.0025)
		head.rotate_x(-event.relative.y * 0.0025)
		head.rotation.x = clampf(head.rotation.x, -1.5, 1.5)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_spawn_at_cursor()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_delete_at_cursor()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		for coord in chunk_nodes.keys():
			_snapshot(chunk_nodes[coord], chunk_data[coord])
			_write_chunk_file(coord, chunk_data[coord])


# ---------- Chunk streaming ----------

func _refresh_chunks() -> void:
	wanted.clear()
	for dx in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
		for dz in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
			wanted[player_chunk + Vector2i(dx, dz)] = true

	for coord in chunk_nodes.keys():
		if not wanted.has(coord):
			_unload_chunk(coord)

	load_queue.clear()
	for coord in wanted.keys():
		if not chunk_nodes.has(coord):
			load_queue.append(coord)
	load_queue.sort_custom(func(a, b): return a.distance_squared_to(player_chunk) < b.distance_squared_to(player_chunk))


func _process_load_queue() -> void:
	var n := 0
	while not load_queue.is_empty() and n < LOADS_PER_FRAME:
		var coord: Vector2i = load_queue.pop_front()
		if wanted.has(coord) and not chunk_nodes.has(coord):
			_load_chunk(coord)
		n += 1


func _load_chunk(coord: Vector2i) -> void:
	var data := _read_chunk_file(coord)

	var root := Node3D.new()
	root.name = "Chunk_%d_%d" % [coord.x, coord.y]
	root.position = _chunk_origin(coord)
	root.set_meta("coord", coord)
	world.add_child(root)

	# Ground tile: collision and mesh share the same box size.
	var body := StaticBody3D.new()
	body.position = Vector3(CHUNK_SIZE * 0.5, -0.5, CHUNK_SIZE * 0.5)
	var col := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(CHUNK_SIZE, 1.0, CHUNK_SIZE)
	col.shape = box_shape
	body.add_child(col)
	var mi := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = box_shape.size
	mi.mesh = box_mesh
	mi.material_override = ground_mat
	body.add_child(mi)
	root.add_child(body)

	for p in data.props:
		_spawn_prop_node(root, p)

	chunk_nodes[coord] = root
	chunk_data[coord] = data


func _unload_chunk(coord: Vector2i) -> void:
	var root: Node3D = chunk_nodes[coord]
	var data: Dictionary = chunk_data[coord]
	_snapshot(root, data)
	_write_chunk_file(coord, data)
	root.queue_free()
	chunk_nodes.erase(coord)
	chunk_data.erase(coord)


# Copy live physics transforms back into the saved data before unloading.
func _snapshot(root: Node3D, data: Dictionary) -> void:
	var by_id := {}
	for p in data.props:
		by_id[p.id] = p
	for child in root.get_children():
		if child.has_meta("id") and by_id.has(child.get_meta("id")):
			var p: Dictionary = by_id[child.get_meta("id")]
			p.pos = [child.position.x, child.position.y, child.position.z]
			p.rot = [child.rotation.x, child.rotation.y, child.rotation.z]


# ---------- Persistence ----------

func _chunk_path(c: Vector2i) -> String:
	return "%s/chunk_%d_%d.json" % [SAVE_DIR, c.x, c.y]


func _read_chunk_file(coord: Vector2i) -> Dictionary:
	var data := {"props": [], "next_id": 1}
	var path := _chunk_path(coord)
	if FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			data.next_id = int(parsed.get("next_id", 1))
			for p in parsed.get("props", []):
				data.props.append({
					"id": int(p.id), "type": int(p.type), "color": int(p.color),
					"pos": p.pos, "rot": p.rot
				})
	return data


func _write_chunk_file(coord: Vector2i, data: Dictionary) -> void:
	# Don't create files for empty chunks.
	if data.props.is_empty() and not FileAccess.file_exists(_chunk_path(coord)):
		return
	var f := FileAccess.open(_chunk_path(coord), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))


# ---------- Props ----------

func _spawn_prop_node(root: Node3D, p: Dictionary) -> void:
	var t: int = p.type
	var body := RigidBody3D.new()
	body.mass = 5.0
	body.set_meta("id", p.id)
	body.position = _arr2v(p.pos)
	body.rotation = _arr2v(p.rot)

	var col := CollisionShape3D.new()
	col.shape = prop_shapes[t]
	body.add_child(col)

	var mi := MeshInstance3D.new()
	mi.mesh = prop_meshes[t]
	mi.material_override = prop_mats[p.color]
	body.add_child(mi)

	root.add_child(body)


func _spawn_at_cursor() -> void:
	var hit := _raycast()
	if hit.is_empty():
		return
	var coord := _chunk_of(hit.position)
	if not chunk_nodes.has(coord):
		return
	var data: Dictionary = chunk_data[coord]
	if data.props.size() >= MAX_PROPS_PER_CHUNK:
		return

	var local: Vector3 = hit.position + Vector3.UP * 0.6 - _chunk_origin(coord)
	var p := {
		"id": data.next_id,
		"type": current_type,
		"color": randi() % PROP_COLORS.size(),
		"pos": [local.x, local.y, local.z],
		"rot": [0.0, randf() * TAU, 0.0]
	}
	data.next_id += 1
	data.props.append(p)
	_spawn_prop_node(chunk_nodes[coord], p)


func _delete_at_cursor() -> void:
	var hit := _raycast()
	if hit.is_empty():
		return
	var body = hit.collider
	if not (body is RigidBody3D and body.has_meta("id")):
		return
	var root: Node3D = body.get_parent()
	var coord: Vector2i = root.get_meta("coord")
	var id = body.get_meta("id")
	var data: Dictionary = chunk_data[coord]
	data.props = data.props.filter(func(p): return p.id != id)
	body.queue_free()


func _raycast() -> Dictionary:
	var from := camera.global_position
	var to := from - camera.global_basis.z * REACH
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [player.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)


# ---------- Setup ----------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.6, 0.75, 0.9)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.8, 0.8)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = false  # shadows are expensive on weak GPUs
	add_child(sun)


func _build_prop_assets() -> void:
	ground_mat = StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.35, 0.5, 0.3)

	for c in PROP_COLORS:
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.9
		prop_mats.append(m)

	# Low-poly meshes and shapes are created once and shared by all props.
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var sph := SphereMesh.new()
	sph.radius = 0.5
	sph.height = 1.0
	sph.radial_segments = 12
	sph.rings = 6
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.5
	cyl.height = 1.0
	cyl.radial_segments = 12
	prop_meshes = [box, sph, cyl]

	var bs := BoxShape3D.new()
	bs.size = Vector3.ONE
	var ss := SphereShape3D.new()
	ss.radius = 0.5
	var cs := CylinderShape3D.new()
	cs.radius = 0.5
	cs.height = 1.0
	prop_shapes = [bs, ss, cs]


func _build_player() -> void:
	player = CharacterBody3D.new()
	player.position = Vector3(0, 3, 0)

	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	col.shape = cap
	col.position.y = 0.9
	player.add_child(col)

	head = Node3D.new()
	head.position.y = 1.6
	player.add_child(head)

	camera = Camera3D.new()
	camera.far = 250.0
	camera.current = true
	head.add_child(camera)

	add_child(player)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	hud = Label.new()
	hud.position = Vector2(10, 10)
	layer.add_child(hud)
	add_child(layer)


func _update_hud() -> void:
	hud.text = "Tool: %s (E to change)\nLeft click: place | Right click: delete | Esc: toggle mouse\nChunks loaded: %d | FPS: %d | Chunk: %s" % [
		TYPE_NAMES[current_type], chunk_nodes.size(),
		Engine.get_frames_per_second(), str(player_chunk)
	]


# ---------- Helpers ----------

func _chunk_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / CHUNK_SIZE), floori(p.z / CHUNK_SIZE))


func _chunk_origin(c: Vector2i) -> Vector3:
	return Vector3(c.x * CHUNK_SIZE, 0.0, c.y * CHUNK_SIZE)


func _arr2v(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])
