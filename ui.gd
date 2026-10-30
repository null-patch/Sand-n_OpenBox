extends CanvasLayer
# Game interface: GMod-style spawn menu (C), info panels, and a GTA V-style weapon wheel (hold Q).

const TOOLS := [
	{"name": "Physgun", "action": "physgun"},
	{"name": "Box", "action": "type", "value": 0},
	{"name": "Sphere", "action": "type", "value": 1},
	{"name": "Cylinder", "action": "type", "value": 2},
	{"name": "Textures", "action": "library"},
	{"name": "Camera", "action": "camera"},
]
const WHEEL_RADIUS := 180.0
const WHEEL_DEAD_ZONE := 56.0
const PANEL_BG := Color(0.08, 0.09, 0.11, 0.86)
const ACCENT := Color(0.25, 0.6, 1.0, 0.9)
const TEXT := Color(0.95, 0.95, 0.95)

var game: Node
var wheel_open := false
var wheel_selected := -1
var spawn_open := false
var spawn_panel: PanelContainer
var tool_title: Label
var tool_sub: Label
var info_label: Label
var notify_label: Label
var overlay: Overlay


class Overlay extends Control:
	var ui: Node

	func _draw() -> void:
		ui.draw_layer(self)


func _ready() -> void:
	layer = 5
	overlay = Overlay.new()
	overlay.ui = self
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)

	_build_tool_panel()
	_build_info_panel()
	_build_help_panel()
	_build_spawn_menu()
	_build_notify()


func _process(_delta: float) -> void:
	if game == null:
		return

	var physgun: bool = game.get("physgun_enabled")
	var t: int = game.get("current_type")
	if physgun:
		tool_title.text = "Physgun"
		tool_sub.text = "Left: grab | Right: drop | Wheel: distance"
	else:
		tool_title.text = str(TOOLS[1 + t]["name"])
		tool_sub.text = "Left: place | Right: delete"

	var chunks: Dictionary = game.get("chunk_nodes")
	var pc: Vector2i = game.get("player_chunk")
	info_label.text = "FPS: %d\nChunks loaded: %d\nChunk: %s" % [
		Engine.get_frames_per_second(), chunks.size(), str(pc)
	]

	if wheel_open:
		_update_wheel_selection()
	overlay.queue_redraw()


# ---------- Input ----------

func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or key.echo:
		return

	if key.keycode == KEY_Q:
		if key.pressed and not wheel_open and not spawn_open and not _library_open():
			_open_wheel()
		elif not key.pressed and wheel_open:
			_close_wheel()
	elif key.keycode == KEY_C and key.pressed and not wheel_open:
		_toggle_spawn()


# ---------- Weapon wheel ----------

func _open_wheel() -> void:
	wheel_open = true
	wheel_selected = -1
	_set_mouse(false)


func _close_wheel() -> void:
	var pick := wheel_selected
	wheel_open = false
	wheel_selected = -1
	_restore_mouse()
	if pick >= 0:
		_apply_tool(pick)


func _update_wheel_selection() -> void:
	var center := get_viewport().get_visible_rect().size * 0.5
	var d := get_viewport().get_mouse_position() - center
	if d.length() < WHEEL_DEAD_ZONE:
		wheel_selected = -1
		return
	var slice := TAU / TOOLS.size()
	var a := atan2(d.x, -d.y)
	wheel_selected = int(floor(fposmod(a + slice * 0.5, TAU) / slice)) % TOOLS.size()


func _apply_tool(i: int) -> void:
	var t: Dictionary = TOOLS[i]
	var action: String = t["action"]
	match action:
		"physgun":
			_set_physgun(not bool(game.get("physgun_enabled")))
		"type":
			_set_physgun(false)
			game.set("current_type", t["value"])
		"library":
			spawn_open = false
			spawn_panel.visible = false
			game.call("_open_library")
		"camera":
			game.call("_toggle_third_person")
	if action != "library":
		notify("Tool: %s" % t["name"])


func _set_physgun(on: bool) -> void:
	game.set("physgun_enabled", on)
	if not on:
		game.call("_drop_held_prop")


# ---------- Spawn menu (C) ----------

func _build_spawn_menu() -> void:
	spawn_panel = PanelContainer.new()
	spawn_panel.add_theme_stylebox_override("panel", _style())
	spawn_panel.custom_minimum_size = Vector2(340, 460)
	spawn_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	spawn_panel.visible = false
	add_child(spawn_panel)

	var root := VBoxContainer.new()
	spawn_panel.add_child(root)
	_label(root, "Spawn Menu  (C to close)", 18)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	var props := _tab(tabs, "Props")
	for i in [1, 2, 3]:
		_button(props, "Spawn %s" % TOOLS[i]["name"], _apply_tool.bind(i))

	var skins := _tab(tabs, "Skins")
	var files: Array = game.get("skin_files")
	for i in files.size():
		_button(skins, str(files[i]), Callable(game, "_apply_skin").bind(i))

	var textures := _tab(tabs, "Textures")
	_button(textures, "Open texture library (Tab)", _open_library_from_menu)

	var tools := _tab(tabs, "Tools")
	_button(tools, "Toggle physgun (G)", _apply_tool.bind(0))
	_button(tools, "Toggle third person (V)", _apply_tool.bind(5))


func _toggle_spawn() -> void:
	if _library_open():
		return
	spawn_open = not spawn_open
	spawn_panel.visible = spawn_open
	if spawn_open:
		_set_mouse(false)
	else:
		_restore_mouse()


func _open_library_from_menu() -> void:
	spawn_open = false
	spawn_panel.visible = false
	game.call("_open_library")


func _tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)
	return vb


func _button(parent: Node, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	parent.add_child(b)


# ---------- HUD panels ----------

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


func _build_info_panel() -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style())
	p.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	p.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(p)
	info_label = _label(p, "", 14)


func _build_help_panel() -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style())
	p.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	p.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	p.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(p)
	_label(p, "C: spawn menu   Hold Q: weapon wheel\nWASD move | Space jump | Esc: free mouse\nTab: textures | G: physgun | E: prop type | V: camera", 13)


func _build_notify() -> void:
	notify_label = Label.new()
	notify_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	notify_label.offset_top = 60
	notify_label.offset_bottom = 100
	notify_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	notify_label.add_theme_font_size_override("font_size", 20)
	notify_label.add_theme_color_override("font_color", TEXT)
	notify_label.modulate.a = 0.0
	overlay.add_child(notify_label)


func notify(text: String) -> void:
	notify_label.text = text
	notify_label.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(1.2)
	tw.tween_property(notify_label, "modulate:a", 0.0, 0.5)


# ---------- Drawing (called from Overlay) ----------

func draw_layer(c: Control) -> void:
	var center := c.size * 0.5
	if wheel_open:
		_draw_wheel(c, center)
	elif not spawn_open:
		_draw_crosshair(c, center)


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


func _draw_wheel(c: Control, center: Vector2) -> void:
	var n := TOOLS.size()
	var slice := TAU / n
	var font := ThemeDB.fallback_font

	c.draw_circle(center, WHEEL_RADIUS + 6.0, Color(0, 0, 0, 0.35))

	for i in n:
		var a0 := i * slice - slice * 0.5
		var a1 := a0 + slice
		var pts := PackedVector2Array([center])
		var steps := 16
		for s in steps + 1:
			var a := lerpf(a0, a1, float(s) / steps)
			pts.append(center + Vector2(sin(a), -cos(a)) * WHEEL_RADIUS)
		var col := ACCENT if i == wheel_selected else PANEL_BG
		c.draw_colored_polygon(pts, col)

	c.draw_circle(center, WHEEL_DEAD_ZONE, PANEL_BG)

	for i in n:
		var a := i * slice
		var dir := Vector2(sin(a), -cos(a))
		var pos := center + dir * WHEEL_RADIUS * 0.66
		var label_text := str(TOOLS[i]["name"])
		var w := font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		c.draw_string(font, pos + Vector2(-w * 0.5, 6), label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, TEXT)

	var center_text := "Release to select"
	if wheel_selected >= 0:
		center_text = str(TOOLS[wheel_selected]["name"])
	var cw := font.get_string_size(center_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	c.draw_string(font, center + Vector2(-cw * 0.5, 6), center_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, TEXT)


# ---------- Mouse and helpers ----------

func _library_open() -> bool:
	var lib: bool = game.get("library_open")
	return lib


func _set_mouse(captured: bool) -> void:
	game.set("mouse_captured", captured)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE


func _restore_mouse() -> void:
	if not wheel_open and not spawn_open and not _library_open():
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
