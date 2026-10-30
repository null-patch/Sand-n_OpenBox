extends Node3D

const CHUNK_SIZE := 32.0
const LOAD_RADIUS := 4
const LOADS_PER_FRAME := 2
const MAX_PROPS_PER_CHUNK := 150
const REACH := 80.0
const SPEED := 6.0
const JUMP := 6.0
const SAVE_DIR := "user://world"
const TEX_DIR := "user://textures"
const LIB_FILE := "user://textures/library.json"
const MAX_TEX_SIZE := 512
const TYPE_NAMES := ["Box", "Sphere", "Cylinder"]
const PROP_COLORS := [
	Color(0.9, 0.3, 0.25), Color(0.2, 0.6, 0.9), Color(0.2, 0.8, 0.4),
	Color(0.95, 0.8, 0.2), Color(0.6, 0.3, 0.8), Color(0.9, 0.9, 0.9)
]
const PHYSGUN_MIN_DISTANCE := 2.0
const PHYSGUN_MAX_DISTANCE := 30.0
const PHYSGUN_SCROLL_STEP := 2.0
const PHYSGUN_STIFFNESS := 18.0
const PHYSGUN_DAMPING := 6.0
const PHYSGUN_MAX_ACCELERATION := 80.0
const PHYSGUN_MAX_SPEED := 24.0
const SKIN_DIR := "user://skins"


var gravity := 9.8
var world: Node3D
var chunk_nodes := {}
var chunk_data := {}
var wanted := {}
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

var physgun_enabled := false
var held_prop: RigidBody3D
var physgun_hold_distance := 10.0
var prop_transfer_queued := false

# Texture library
var lib_items: Array = []        # [{"name": String, "file": String}], index 0 is Default
var lib_textures: Array = []     # Texture2D for each lib_items index
var prop_tex_mats := {}          # lib index -> StandardMaterial3D
var ground_tex := 0
var prop_tex := 0
var target := "ground"           # "ground" or "props"
var library_open := false
var library_panel: PanelContainer
var library_list: VBoxContainer
var target_btn: Button
var status_label: Label
var file_dialog: FileDialog

# Character
var model: Node3D
var hips: Node3D
var head_pivot: Node3D
var arm_l: Node3D
var arm_r: Node3D
var leg_l: Node3D
var leg_r: Node3D
var third_person := false
var anim_phase := 0.0
var body_mats: Array = []     # {"mat": StandardMaterial3D, "color": Color}
var skin_files: Array = []    # index 0 is always "Default"
var skin_index := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	DirAccess.make_dir_recursive_absolute(SKIN_DIR)
	DirAccess.make_dir_recursive_absolute(TEX_DIR)
	_build_environment()
	_build_prop_assets()
	_load_library()
	world = Node3D.new()
	world.name = "World"
	add_child(world)
	_build_player()
	_scan_skins()
	_apply_skin(0)
	_build_library_ui()
	var ui: CanvasLayer = preload("res://ui.gd").new()
	ui.game = self
	add_child(ui)

	player_chunk = Vector2i.ZERO
	_load_chunk(Vector2i.ZERO)
	_refresh_chunks()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	var pc := _chunk_of(player.global_position)
	if pc != player_chunk:
		player_chunk = pc
		_refresh_chunks()
	_process_load_queue()
	_animate_character(delta)


func _physics_process(delta: float) -> void:
	var dir := Vector3.ZERO
	if not library_open:
		if Input.is_physical_key_pressed(KEY_W):
			dir.z -= 1
		if Input.is_physical_key_pressed(KEY_S):
			dir.z += 1
		if Input.is_physical_key_pressed(KEY_A):
			dir.x -= 1
		if Input.is_physical_key_pressed(KEY_D):
			dir.x += 1

	dir = (player.global_basis * dir).normalized()
	player.velocity.x = dir.x * SPEED
	player.velocity.z = dir.z * SPEED

	if player.is_on_floor():
		if Input.is_physical_key_pressed(KEY_SPACE) and not library_open:
			player.velocity.y = JUMP
	else:
		player.velocity.y -= gravity * delta

	player.move_and_slide()
	_update_physgun()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if library_open:
				_close_library()
			else:
				mouse_captured = not mouse_captured
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mouse_captured else Input.MOUSE_MODE_VISIBLE
		elif event.keycode == KEY_TAB:
			if library_open:
				_close_library()
			else:
				_open_library()
		elif event.keycode == KEY_E and not library_open:
			current_type = (current_type + 1) % TYPE_NAMES.size()
		elif event.keycode == KEY_G and not library_open:
			_toggle_physgun()
		elif event.keycode == KEY_V and not library_open:
			_toggle_third_person()

	if not mouse_captured:
		return

	if event is InputEventMouseMotion:
		player.rotate_y(-event.relative.x * 0.0025)
		head.rotate_x(-event.relative.y * 0.0025)
		head.rotation.x = clampf(head.rotation.x, -1.5, 1.5)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed and physgun_enabled and is_instance_valid(held_prop):
				var adjustment := PHYSGUN_SCROLL_STEP
				if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					adjustment = -adjustment
				physgun_hold_distance = clampf(
					physgun_hold_distance + adjustment,
					PHYSGUN_MIN_DISTANCE,
					PHYSGUN_MAX_DISTANCE
				)
			return

		if not event.pressed:
			return

		if event.button_index == MOUSE_BUTTON_LEFT:
			if physgun_enabled:
				_grab_at_cursor()
			else:
				_spawn_at_cursor()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if physgun_enabled:
				_drop_held_prop()
			else:
				_delete_at_cursor()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_drop_held_prop()
		for coord in chunk_nodes.keys():
			_snapshot(chunk_nodes[coord], chunk_data[coord])
			_write_chunk_file(coord, chunk_data[coord])


# ---------- Texture library ----------

func _build_library_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)

	library_panel = PanelContainer.new()
	library_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	library_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	library_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	library_panel.custom_minimum_size = Vector2(440, 0)
	library_panel.visible = false
	layer.add_child(library_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	library_panel.add_child(vbox)

	var title := Label.new()
	title.text = "Texture Library"
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	target_btn = Button.new()
	target_btn.pressed.connect(_toggle_target)
	vbox.add_child(target_btn)

	library_list = VBoxContainer.new()
	library_list.add_theme_constant_override("separation", 4)
	vbox.add_child(library_list)

	var import_btn := Button.new()
	import_btn.text = "Import own texture (PNG / JPG)..."
	import_btn.pressed.connect(func(): file_dialog.popup_centered_ratio(0.6))
	vbox.add_child(import_btn)

	status_label = Label.new()
	vbox.add_child(status_label)

	var hint := Label.new()
	hint.text = "Tab or Esc: close"
	vbox.add_child(hint)

	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
	file_dialog.file_selected.connect(_import_texture)
	add_child(file_dialog)

	_update_target_button()
	_build_library_rows()


func _open_library() -> void:
	_drop_held_prop()
	library_open = true
	library_panel.visible = true
	mouse_captured = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_library_rows()


func _close_library() -> void:
	library_open = false
	library_panel.visible = false
	mouse_captured = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _toggle_target() -> void:
	target = "props" if target == "ground" else "ground"
	_update_target_button()
	_set_status("")


func _update_target_button() -> void:
	target_btn.text = "Applying to: %s (click to switch)" % ("Ground" if target == "ground" else "New props")


func _build_library_rows() -> void:
	for c in library_list.get_children():
		c.queue_free()
	for i in lib_items.size():
		var btn := Button.new()
		var tags := ""
		if i == ground_tex:
			tags += "  [ground]"
		if i == prop_tex:
			tags += "  [props]"
		btn.text = "%s%s" % [lib_items[i]["name"], tags]
		btn.icon = lib_textures[i]
		btn.expand_icon = true
		btn.custom_minimum_size = Vector2(0, 52)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(_on_pick.bind(i))
		library_list.add_child(btn)


func _on_pick(i: int) -> void:
	if target == "ground":
		ground_tex = i
		_apply_ground_texture()
		_set_status("Ground texture: %s" % lib_items[i]["name"])
	else:
		prop_tex = i
		_set_status("New props will use: %s" % lib_items[i]["name"])
	_save_library()
	_build_library_rows()


func _set_status(msg: String) -> void:
	status_label.text = msg


func _load_library() -> void:
	lib_items = [{"name": "Default", "file": ""}]
	if FileAccess.file_exists(LIB_FILE):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(LIB_FILE))
		if parsed is Dictionary:
			ground_tex = int(parsed.get("ground", 0))
			prop_tex = int(parsed.get("props", 0))
			for item in parsed.get("items", []):
				if item is Dictionary and str(item.get("file", "")) != "":
					lib_items.append({"name": str(item.get("name", "Texture")), "file": str(item["file"])})
	ground_tex = clampi(ground_tex, 0, lib_items.size() - 1)
	prop_tex = clampi(prop_tex, 0, lib_items.size() - 1)

	lib_textures.clear()
	for item in lib_items:
		lib_textures.append(_texture_for_item(item))
	_apply_ground_texture()


func _texture_for_item(item: Dictionary) -> Texture2D:
	var file: String = item.get("file", "")
	if file != "" and FileAccess.file_exists(file):
		var img := Image.load_from_file(file)
		if img != null and not img.is_empty():
			img.generate_mipmaps()
			return ImageTexture.create_from_image(img)
	return _make_grass_texture()


func _apply_ground_texture() -> void:
	ground_mat.albedo_texture = lib_textures[ground_tex]


func _import_texture(path: String) -> void:
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		_set_status("Could not read that image.")
		return

	var w := img.get_width()
	var h := img.get_height()
	var factor := float(MAX_TEX_SIZE) / maxf(w, h)
	if factor < 1.0:
		img.resize(int(w * factor), int(h * factor), Image.INTERPOLATE_BILINEAR)

	var fname := "tex_%d.png" % Time.get_ticks_usec()
	var dest := "%s/%s" % [TEX_DIR, fname]
	if img.save_png(dest) != OK:
		_set_status("Could not save the texture.")
		return

	lib_items.append({"name": path.get_file().get_basename(), "file": dest})
	lib_textures.append(_texture_for_item(lib_items[lib_items.size() - 1]))
	_save_library()
	_build_library_rows()
	_set_status("Imported: %s" % lib_items[lib_items.size() - 1]["name"])


func _save_library() -> void:
	var custom: Array = []
	for i in range(1, lib_items.size()):
		custom.append(lib_items[i])
	var f := FileAccess.open(LIB_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"ground": ground_tex, "props": prop_tex, "items": custom}))


# ---------- Chunk streaming ----------

func _refresh_chunks() -> void:
	wanted.clear()
	for dx in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
		for dz in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
			wanted[player_chunk + Vector2i(dx, dz)] = true

	# Keep the held prop's chunk loaded so it isn't unloaded mid-grab.
	if is_instance_valid(held_prop):
		var held_root := held_prop.get_parent()
		if held_root is Node3D and held_root.has_meta("coord"):
			var held_coord: Vector2i = held_root.get_meta("coord")
			wanted[held_coord] = true

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
					"tex": int(p.get("tex", 0)),
					"pos": p.pos, "rot": p.rot
				})
	return data


func _write_chunk_file(coord: Vector2i, data: Dictionary) -> void:
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
	mi.material_override = _prop_material(p)
	body.add_child(mi)

	root.add_child(body)


func _prop_material(p: Dictionary) -> Material:
	var idx: int = p.get("tex", 0)
	if idx <= 0 or idx >= lib_textures.size():
		return prop_mats[p.color]
	if not prop_tex_mats.has(idx):
		var m := StandardMaterial3D.new()
		m.albedo_texture = lib_textures[idx]
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3(0.5, 0.5, 0.5)
		m.roughness = 0.9
		prop_tex_mats[idx] = m
	return prop_tex_mats[idx]


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
		"tex": prop_tex,
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


# ---------- Physgun ----------

func _toggle_physgun() -> void:
	physgun_enabled = not physgun_enabled
	if not physgun_enabled:
		_drop_held_prop()


func _grab_at_cursor() -> void:
	if is_instance_valid(held_prop):
		return

	var hit := _raycast()
	if hit.is_empty():
		return

	var body = hit.collider
	if not (body is RigidBody3D and body.has_meta("id")):
		return

	var root: Node = body.get_parent()
	if not (root is Node3D and root.has_meta("coord")):
		return

	held_prop = body
	held_prop.sleeping = false
	physgun_hold_distance = clampf(
		camera.global_position.distance_to(held_prop.global_position),
		PHYSGUN_MIN_DISTANCE,
		PHYSGUN_MAX_DISTANCE
	)


func _drop_held_prop() -> void:
	held_prop = null


func _update_physgun() -> void:
	if not is_instance_valid(held_prop):
		held_prop = null
		return

	var hold_point := camera.global_position - camera.global_basis.z * physgun_hold_distance
	var error := hold_point - held_prop.global_position

	# Spring-and-damping controller, with gravity compensation and bounded acceleration.
	var acceleration := (
		error * PHYSGUN_STIFFNESS
		- held_prop.linear_velocity * PHYSGUN_DAMPING
		+ Vector3.UP * gravity
	)
	acceleration = acceleration.limit_length(PHYSGUN_MAX_ACCELERATION)

	held_prop.sleeping = false
	held_prop.linear_velocity = held_prop.linear_velocity.limit_length(PHYSGUN_MAX_SPEED)
	held_prop.apply_central_force(acceleration * held_prop.mass)

	var root := held_prop.get_parent()
	if root is Node3D and root.has_meta("coord"):
		var current_owner: Vector2i = root.get_meta("coord")
		var destination := _chunk_of(held_prop.global_position)
		if destination != current_owner and not prop_transfer_queued:
			prop_transfer_queued = true
			call_deferred("_transfer_held_prop_if_needed")


func _transfer_held_prop_if_needed() -> void:
	prop_transfer_queued = false

	if not is_instance_valid(held_prop):
		return

	var source_root := held_prop.get_parent()
	if not (source_root is Node3D and source_root.has_meta("coord")):
		return

	var source_coord: Vector2i = source_root.get_meta("coord")
	var destination_coord := _chunk_of(held_prop.global_position)
	if source_coord == destination_coord:
		return

	# Load the destination before reparenting so the prop has somewhere to go.
	wanted[destination_coord] = true
	if not chunk_nodes.has(destination_coord):
		_load_chunk(destination_coord)

	var source_data: Dictionary = chunk_data[source_coord]
	var destination_data: Dictionary = chunk_data[destination_coord]
	var prop_id := int(held_prop.get_meta("id"))
	var record_index := -1

	for i in range(source_data["props"].size()):
		var record: Dictionary = source_data["props"][i]
		if int(record.get("id", -1)) == prop_id:
			record_index = i
			break

	if record_index == -1:
		return

	var moved_record: Dictionary = source_data["props"][record_index].duplicate(true)
	source_data["props"].remove_at(record_index)

	var new_id := int(destination_data.get("next_id", 1))
	destination_data["next_id"] = new_id + 1
	moved_record["id"] = new_id

	held_prop.reparent(chunk_nodes[destination_coord], true)
	held_prop.set_meta("id", new_id)

	moved_record["pos"] = [
		held_prop.position.x,
		held_prop.position.y,
		held_prop.position.z
	]
	moved_record["rot"] = [
		held_prop.rotation.x,
		held_prop.rotation.y,
		held_prop.rotation.z
	]
	destination_data["props"].append(moved_record)


func _raycast() -> Dictionary:
	var from := camera.global_position
	var to := from - camera.global_basis.z * REACH
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [player.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)


# ---------- Character ----------

func _build_character() -> void:
	var shirt := _body_mat(Color(0.2, 0.45, 0.85))
	var pants := _body_mat(Color(0.25, 0.25, 0.3))
	var skin := _body_mat(Color(0.93, 0.76, 0.6))
	var hair := _body_mat(Color(0.25, 0.15, 0.08))

	model = Node3D.new()
	player.add_child(model)

	hips = Node3D.new()
	hips.position.y = 0.95
	model.add_child(hips)

	_box(hips, Vector3(0.45, 0.7, 0.25), Vector3(0, 0.35, 0), shirt)

	head_pivot = Node3D.new()
	head_pivot.position.y = 0.7
	hips.add_child(head_pivot)
	_box(head_pivot, Vector3(0.28, 0.28, 0.28), Vector3(0, 0.16, 0), skin)
	_box(head_pivot, Vector3(0.3, 0.08, 0.3), Vector3(0, 0.3, 0), hair)

	arm_l = Node3D.new()
	arm_l.position = Vector3(-0.3, 0.65, 0)
	hips.add_child(arm_l)
	_box(arm_l, Vector3(0.14, 0.65, 0.14), Vector3(0, -0.33, 0), shirt)

	arm_r = Node3D.new()
	arm_r.position = Vector3(0.3, 0.65, 0)
	hips.add_child(arm_r)
	_box(arm_r, Vector3(0.14, 0.65, 0.14), Vector3(0, -0.33, 0), shirt)

	leg_l = Node3D.new()
	leg_l.position = Vector3(-0.12, 0, 0)
	hips.add_child(leg_l)
	_box(leg_l, Vector3(0.16, 0.95, 0.16), Vector3(0, -0.475, 0), pants)

	leg_r = Node3D.new()
	leg_r.position = Vector3(0.12, 0, 0)
	hips.add_child(leg_r)
	_box(leg_r, Vector3(0.16, 0.95, 0.16), Vector3(0, -0.475, 0), pants)

	model.visible = false


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)


func _animate_character(delta: float) -> void:
	head_pivot.rotation.x = head.rotation.x

	var hspeed := Vector2(player.velocity.x, player.velocity.z).length()
	var amp := clampf(hspeed / SPEED, 0.0, 1.0)
	anim_phase += delta * hspeed * 1.6
	var swing := sin(anim_phase) * 0.7 * amp

	leg_l.rotation.x = swing
	leg_r.rotation.x = -swing
	arm_l.rotation.x = -swing * 0.8
	arm_r.rotation.x = swing * 0.8

	if not player.is_on_floor():
		arm_l.rotation.x = -1.2
		arm_r.rotation.x = -1.2


func _toggle_third_person() -> void:
	third_person = not third_person
	model.visible = third_person
	camera.position = Vector3(0.5, 0.1, 3.0) if third_person else Vector3.ZERO


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	return m


# ---------- Setup ----------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.6, 0.75, 0.9)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.8, 0.8)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.6, 0.75, 0.9)
	env.fog_depth_begin = 50.0
	env.fog_depth_end = 130.0
	env.fog_depth_curve = 1.0
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = false
	add_child(sun)


func _build_prop_assets() -> void:
	ground_mat = StandardMaterial3D.new()
	ground_mat.uv1_triplanar = true
	ground_mat.uv1_world_triplanar = true
	ground_mat.uv1_scale = Vector3(0.5, 0.5, 0.5)
	ground_mat.roughness = 1.0

	for c in PROP_COLORS:
		prop_mats.append(_mat(c))

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


# Body material that the skin system can retexture. Keeps its base color for the Default skin.
func _body_mat(c: Color) -> StandardMaterial3D:
	var m := _mat(c)
	body_mats.append({"mat": m, "color": c})
	return m


# Scans user://skins for images. Index 0 is always the built-in Default.
func _scan_skins() -> void:
	skin_files = ["Default"]
	var dir := DirAccess.open(SKIN_DIR)
	if dir:
		for f in dir.get_files():
			if f.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
				skin_files.append(f)
	skin_index = clampi(skin_index, 0, skin_files.size() - 1)


func _apply_skin(index: int) -> void:
	skin_index = clampi(index, 0, skin_files.size() - 1)
	var tex: Texture2D = null
	if skin_index > 0:
		tex = _load_skin_texture(skin_files[skin_index])
		if tex == null:
			skin_index = 0  # file failed to load, fall back to Default
	for entry in body_mats:
		var m: StandardMaterial3D = entry.mat
		m.albedo_texture = tex
		m.albedo_color = Color.WHITE if tex else entry.color


func _load_skin_texture(file: String) -> Texture2D:
	var img := Image.load_from_file(SKIN_DIR + "/" + file)
	if img == null:
		push_warning("Could not load skin: " + file)
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _cycle_skin() -> void:
	_apply_skin((skin_index + 1) % skin_files.size())


# Procedural GMod-style flatgrass: bright green with fine speckle and no dark edges.
func _make_grass_texture() -> ImageTexture:
	var s := 128
	var img := Image.create(s, s, false, Image.FORMAT_RGB8)
	for y in s:
		for x in s:
			var n := randf_range(-1.0, 1.0)
			var v := randf_range(-0.5, 0.5)
			var r := 0.30 + n * 0.035
			var g := 0.56 + n * 0.05 + v * 0.02
			var b := 0.18 + n * 0.025
			img.set_pixel(x, y, Color(r, g, b))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


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
	camera.far = 200.0
	camera.current = true
	head.add_child(camera)

	add_child(player)
	_build_character()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	hud = Label.new()
	hud.position = Vector2(10, 10)
	layer.add_child(hud)
	add_child(layer)


func _update_hud() -> void:
	var tool_name: String = "Physgun" if physgun_enabled else str(TYPE_NAMES[current_type])
	var tool_controls := "Left click: grab | Right click: drop | Wheel: adjust distance"
	if not physgun_enabled:
		tool_controls = "Left click: place | Right click: delete"

	var hold_status := ""
	if is_instance_valid(held_prop):
		hold_status = "\nGrab distance: %.1f m" % physgun_hold_distance

	hud.text = "Tool: %s (G to toggle; E changes prop type)\nWASD move | Space jump | V: camera view | Tab: texture library\n%s%s\nEsc: toggle mouse\nChunks loaded: %d | FPS: %d | Chunk: %s" % [
		tool_name,
		tool_controls,
		hold_status,
		chunk_nodes.size(),
		Engine.get_frames_per_second(),
		str(player_chunk)
	]


# ---------- Helpers ----------

func _chunk_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / CHUNK_SIZE), floori(p.z / CHUNK_SIZE))


func _chunk_origin(c: Vector2i) -> Vector3:
	return Vector3(c.x * CHUNK_SIZE, 0.0, c.y * CHUNK_SIZE)

	
func _arr2v(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])
