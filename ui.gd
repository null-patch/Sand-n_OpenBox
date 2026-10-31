extends CanvasLayer
# Pause menu (Esc), Developer Info overlay, and the Q weapon wheel.

const SETTINGS_FILE := "user://settings.cfg"
const WHEEL_RADIUS := 180.0
const WHEEL_DEAD_ZONE := 56.0
const PANEL_BG := Color(0.08, 0.09, 0.11, 0.86)
const ACCENT := Color(0.25, 0.6, 1.0, 0.9)
const TEXT := Color(0.95, 0.95, 0.95)
const SAMPLE_INTERVAL := 0.25
const FPS_HISTORY := 120

# Only unlocked entries appear on the wheel. Locked entries stay hidden until implemented.
var weapons := [
	{"id": "physgun", "name": "Physgun", "unlocked": true},
	{"id": "spawn", "name": "Spawn Tool", "unlocked": true},
	{"id": "gravity", "name": "Gravity Gun", "unlocked": false},
	{"id": "tool", "name": "Tool Gun", "unlocked": false},
	{"id": "portal", "name": "Portal Gun", "unlocked": false},
	{"id": "pistol", "name": "Pistol", "unlocked": false},
	{"id": "smg", "name": "SMG", "unlocked": false},
	{"id": "shotgun", "name": "Shotgun", "unlocked": false},
	{"id": "rifle", "name": "Rifle", "unlocked": false},
]

var game: Node
var equipped := "physgun"
var paused := false
var wheel_open := false
var wheel_selected := -1
var skin_open := false
var dev_info := false
var fps_samples: Array = []
var sample_timer := 0.0
var debug_timer := 0.0

var overlay: Overlay
var graph: Graph
var pause_panel: PanelContainer
var options_box: VBoxContainer
var dev_check: CheckBox
var skin_panel: PanelContainer
var debug_panel: PanelContainer
var pose_panel: PanelContainer
var debug_label: Label
var tool_title: Label
var tool_sub: Label
var notify_label: Label



class Overlay extends Control:
	var ui

	func _draw() -> void:
		ui.draw_layer(self)


class Graph extends Control:
	var ui

	func _draw() -> void:
		ui.draw_graph(self)


func _ready() -> void:
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS

	overlay = Overlay.new()
	overlay.ui = self
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)

	_load_settings()
	_build_tool_panel()
	_build_help_panel()
	_build_debug_panel()
	_build_pause_menu()
	_build_skin_panel()
	_build_pose_panel()
	_build_notify()


func _process(delta: float) -> void:
	if game == null:
		return

	sample_timer += delta
	if sample_timer >= SAMPLE_INTERVAL:
		sample_timer = 0.0
		fps_samples.append(Engine.get_frames_per_second())
		if fps_samples.size() > FPS_HISTORY:
			fps_samples.pop_front()

	tool_title.text = _name_of(equipped)
	match equipped:
		"physgun":
			tool_sub.text = "Left: grab | Right: drop | Wheel: distance"
		"spawn":
			tool_sub.text = "Choose a skin below (Esc closes)"
		_:
			tool_sub.text = "Hold Q to equip"

	if dev_info:
		debug_timer += delta
		if debug_timer >= SAMPLE_INTERVAL:
			debug_timer = 0.0
			_update_debug()
			graph.queue_redraw()

	if wheel_open:
		_update_wheel_selection()
	overlay.queue_redraw()


# ---------- Input ----------

func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or key.echo:
		return

	if key.keycode == KEY_ESCAPE and key.pressed:
		if skin_open:
			_close_skins()
		elif _library_open():
			game.call("_close_library")
		else:
			_toggle_pause()
	elif key.keycode == KEY_Q and not paused:
		if key.pressed and not wheel_open:
			_open_wheel()
		elif not key.pressed and wheel_open:
			_close_wheel()


# ---------- Pause menu (Esc) ----------

func _build_pause_menu() -> void:
	pause_panel = PanelContainer.new()
	pause_panel.add_theme_stylebox_override("panel", _style())
	pause_panel.custom_minimum_size = Vector2(360, 0)
	pause_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	pause_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	pause_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	pause_panel.visible = false
	add_child(pause_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	pause_panel.add_child(vb)

	_label(vb, "Paused", 22)
	_button(vb, "Resume", _toggle_pause)
	_button(vb, "Options", _toggle_options)
	_button(vb, "Poses", _toggle_poses)

	options_box = VBoxContainer.new()
	options_box.visible = false
	vb.add_child(options_box)

	dev_check = CheckBox.new()
	dev_check.text = "Developer Info"
	dev_check.button_pressed = dev_info
	dev_check.toggled.connect(_on_dev_toggled)
	options_box.add_child(dev_check)

	_button(vb, "Texture Library", _open_library_from_pause)
	_button(vb, "Quit", func(): get_tree().quit())


func _toggle_pause() -> void:
	if wheel_open:
		return
	if paused:
		_unpause()
		_restore_mouse()
	else:
		paused = true
		get_tree().paused = true
		pause_panel.visible = true
		_set_mouse(false)


func _unpause() -> void:
	paused = false
	get_tree().paused = false
	pause_panel.visible = false
	pose_panel.visible = false


func _toggle_options() -> void:
	options_box.visible = not options_box.visible


func _open_library_from_pause() -> void:
	_unpause()
	game.call("_open_library")


func _on_dev_toggled(on: bool) -> void:
	dev_info = on
	debug_panel.visible = on
	_save_settings()


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_FILE) == OK:
		dev_info = bool(cfg.get_value("ui", "developer_info", false))


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("ui", "developer_info", dev_info)
	cfg.save(SETTINGS_FILE)


# ---------- Developer Info overlay ----------

func _build_debug_panel() -> void:
	debug_panel = PanelContainer.new()
	debug_panel.add_theme_stylebox_override("panel", _style())
	debug_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	debug_panel.visible = dev_info
	add_child(debug_panel)

	var vb := VBoxContainer.new()
	debug_panel.add_child(vb)
	debug_label = _label(vb, "", 13)

	graph = Graph.new()
	graph.ui = self
	graph.custom_minimum_size = Vector2(300, 48)
	vb.add_child(graph)


func _update_debug() -> void:
	var pl: CharacterBody3D = game.get("player")
	var p := pl.global_position
	var fps: float = Engine.get_frames_per_second()
	var lo := fps
	var hi := fps
	for f in fps_samples:
		lo = minf(lo, f)
		hi = maxf(hi, f)
	var yaw := fposmod(rad_to_deg(pl.rotation.y), 360.0)
	var chunks: Dictionary = game.get("chunk_nodes")
	var wanted: Dictionary = game.get("wanted")
	var pc: Vector2i = game.get("player_chunk")
	var held = game.get("held_prop")
	var mem := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var objs := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))

	debug_label.text = (
		"FPS %.0f (min %.0f / max %.0f)  frame %.1f ms\n" % [fps, lo, hi, 1000.0 / maxf(fps, 1.0)]
		+ "Pos %.1f, %.1f, %.1f  facing %.0f deg\n" % [p.x, p.y, p.z, yaw]
		+ "Chunk %s  loaded %d  wanted %d\n" % [str(pc), chunks.size(), wanted.size()]
		+ "Held prop: %s\n" % ("yes" if is_instance_valid(held) else "no")
		+ "Memory %.1f MB  objects %d  draw calls %d\n" % [mem, objs, draws]
		+ "Network: N/A (singleplayer)"
	)


func draw_graph(c: Control) -> void:
	c.draw_rect(Rect2(Vector2.ZERO, c.size), Color(0, 0, 0, 0.4))
	if fps_samples.size() < 2:
		return
	var top := 60.0
	for f in fps_samples:
		top = maxf(top, f)
	var pts := PackedVector2Array()
	for i in fps_samples.size():
		var x := c.size.x * float(i) / (FPS_HISTORY - 1)
		var y := c.size.y - (float(fps_samples[i]) / top) * c.size.y
		pts.append(Vector2(x, y))
	c.draw_polyline(pts, ACCENT, 2.0)


# ---------- Weapon wheel (Q) ----------

func _equipped() -> Array:
	var out: Array = []
	for w in weapons:
		if w["unlocked"]:
			out.append(w)
	return out


func _name_of(id: String) -> String:
	for w in weapons:
		if w["id"] == id:
			return str(w["name"])
	return id


func _open_wheel() -> void:
	if paused or _library_open() or skin_open:
		return
	wheel_open = true
	wheel_selected = -1
	_set_mouse(false)


func _close_wheel() -> void:
	var items := _equipped()
	var pick := wheel_selected
	wheel_open = false
	wheel_selected = -1
	if pick >= 0 and pick < items.size():
		_equip(str(items[pick]["id"]))
	else:
		_restore_mouse()


func _update_wheel_selection() -> void:
	var n := _equipped().size()
	if n == 0:
		wheel_selected = -1
		return
	var center := get_viewport().get_visible_rect().size * 0.5
	var d := get_viewport().get_mouse_position() - center
	if d.length() < WHEEL_DEAD_ZONE:
		wheel_selected = -1
		return
	var slice := TAU / n
	var a := atan2(d.x, -d.y)
	wheel_selected = int(floor(fposmod(a + slice * 0.5, TAU) / slice)) % n


func _equip(id: String) -> void:
	equipped = id
	game.set("physgun_enabled", id == "physgun")
	if id != "physgun":
		game.call("_drop_held_prop")
	if id == "spawn":
		_open_skins()
	else:
		_close_skins()
	notify(_name_of(id))


func _draw_wheel(c: Control, center: Vector2) -> void:
	var items := _equipped()
	var n := items.size()
	if n == 0:
		return
	var slice := TAU / n
	var font := ThemeDB.fallback_font

	c.draw_circle(center, WHEEL_RADIUS + 6.0, Color(0, 0, 0, 0.35))
	for i in n:
		var a0 := i * slice - slice * 0.5
		var pts := PackedVector2Array([center])
		for s in 17:
			var a := lerpf(a0, a0 + slice, s / 16.0)
			pts.append(center + Vector2(sin(a), -cos(a)) * WHEEL_RADIUS)
		c.draw_colored_polygon(pts, ACCENT if i == wheel_selected else PANEL_BG)
	c.draw_circle(center, WHEEL_DEAD_ZONE, PANEL_BG)

	for i in n:
		var a := i * slice
		var text: String = items[i]["name"]
		var pos := center + Vector2(sin(a), -cos(a)) * WHEEL_RADIUS * 0.66
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		c.draw_string(font, pos + Vector2(-w * 0.5, 6), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, TEXT)

	var center_text := "Release to equip"
	if wheel_selected >= 0 and wheel_selected < n:
		center_text = str(items[wheel_selected]["name"])
	var cw := font.get_string_size(center_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	c.draw_string(font, center + Vector2(-cw * 0.5, 6), center_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, TEXT)


# ---------- Spawn tool skin panel ----------

func _build_skin_panel() -> void:
	skin_panel = PanelContainer.new()
	skin_panel.add_theme_stylebox_override("panel", _style())
	skin_panel.custom_minimum_size = Vector2(260, 0)
	skin_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	skin_panel.visible = false
	add_child(skin_panel)

	var vb := VBoxContainer.new()
	skin_panel.add_child(vb)
	_label(vb, "Spawn Tool: pick a skin", 15)
	var files: Array = game.get("skin_files")
	for i in files.size():
		_button(vb, str(files[i]), _pick_skin.bind(i))


func _pick_skin(i: int) -> void:
	game.call("_apply_skin", i)


func _open_skins() -> void:
	skin_open = true
	skin_panel.visible = true
	_set_mouse(false)


func _close_skins() -> void:
	skin_open = false
	skin_panel.visible = false
	_restore_mouse()


# ---------- Always-on HUD ----------

func _build_tool_panel() -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style())
	p.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	p.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(p)
	var vb := VBoxContainer.new()
	p.add_child(vb)
	tool_title = _label(vb, "", 26)
	tool_sub = _label(vb, "", 14)


func _build_help_panel() -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style())
	p.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	p.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	p.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(p)
	_label(p, "Esc: pause | Hold Q: weapon wheel\nWASD move | Space jump | V: camera\nTab: textures | Left/Right click: use tool", 13)


func _build_notify() -> void:
	notify_label = Label.new()
	notify_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	notify_label.offset_top = 60
	notify_label.offset_bottom = 100
	notify_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	notify_label.add_theme_font_size_override("font_size", 20)
	notify_label.add_theme_color_override("font_color", TEXT)
	notify_label.modulate.a = 0.0
	add_child(notify_label)


func notify(text: String) -> void:
	notify_label.text = text
	notify_label.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(1.2)
	tw.tween_property(notify_label, "modulate:a", 0.0, 0.5)


# ---------- Drawing ----------

func draw_layer(c: Control) -> void:
	if wheel_open:
		_draw_wheel(c, c.size * 0.5)
	elif _gameplay_active():
		_draw_crosshair(c, c.size * 0.5)


func _gameplay_active() -> bool:
	return not paused and not wheel_open and not skin_open and not _library_open()


func _draw_crosshair(c: Control, center: Vector2) -> void:
	var shadow := Color(0, 0, 0, 0.6)
	for off in [Vector2(1, 1), Vector2.ZERO]:
		var col := shadow if off != Vector2.ZERO else TEXT
		c.draw_line(center + off + Vector2(-9, 0), center + off + Vector2(-3, 0), col, 2.0)
		c.draw_line(center + off + Vector2(3, 0), center + off + Vector2(9, 0), col, 2.0)
		c.draw_line(center + off + Vector2(0, -9), center + off + Vector2(0, -3), col, 2.0)
		c.draw_line(center + off + Vector2(0, 3), center + off + Vector2(0, 9), col, 2.0)

	var held = game.get("held_prop")
	if is_instance_valid(held):
		c.draw_arc(center, 14.0, 0.0, TAU, 32, ACCENT, 2.0)


# ---------- Mouse and helpers ----------

func _library_open() -> bool:
	return bool(game.get("library_open"))


func _set_mouse(captured: bool) -> void:
	game.set("mouse_captured", captured)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE


func _restore_mouse() -> void:
	if paused or wheel_open or skin_open or _library_open():
		return
	_set_mouse(true)


func _style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	return sb


func _label(parent: Node, text: String, font_size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", TEXT)
	parent.add_child(l)
	return l


func _button(parent: Node, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	parent.add_child(b)


# ---------- Poses panel ----------

func _build_pose_panel() -> void:
	pose_panel = PanelContainer.new()
	pose_panel.add_theme_stylebox_override("panel", _style())
	pose_panel.custom_minimum_size = Vector2(260, 0)
	pose_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	pose_panel.visible = false
	add_child(pose_panel)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(240, 420)
	pose_panel.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)

	_label(vb, "Poses (move to stop posing)", 15)
	_button(vb, "Auto (movement)", _pick_pose.bind(""))
	for n in game.call("get_pose_names"):
		_button(vb, str(n).replace("_", " "), _pick_pose.bind(str(n)))


func _toggle_poses() -> void:
	pose_panel.visible = not pose_panel.visible


func _pick_pose(anim_name: String) -> void:
	if anim_name == "":
		game.call("clear_pose")
	else:
		game.call("set_pose", anim_name)
