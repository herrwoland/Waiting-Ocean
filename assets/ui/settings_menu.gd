extends CanvasLayer
## Settings menu: a short list of sections (Graphics, Brightness, Controls, Audio), each its own
## page that fits without scrolling. Every setting is a SettingRow ("name   < value >") changed
## the same way with mouse, keys or pad. Changes show at once; Apply keeps them, Discard puts the
## page back as it was. Esc on a page applies. Values persist to user://settings.cfg.

signal closed

const SETTINGS_PATH := "user://settings.cfg"
const WAVE_RESOLUTIONS: Array[int] = [256, 512, 1024]
## Resolutions that break the ocean. Left out of the list players see; take one out of here to
## offer it again.
const WAVE_RESOLUTIONS_DISABLED: Array[int] = [256]
const DEFAULT_WAVE_RESOLUTION := 512
const MESH_QUALITY_NAMES: Array[String] = ["Low", "High", "High 8K"]
const EFFECTS_QUALITY_NAMES: Array[String] = ["Low", "Medium", "High"]
## Frame rate caps offered, 0 = uncapped. Engine.max_fps takes these directly.
const FPS_LIMITS: Array[int] = [0, 30, 60, 75, 120, 144, 165, 240]

## Where each setting lives in the config file (unchanged from the old tabbed menu, so saved
## settings carry over).
const CONFIG_SECTIONS := {
	"fullscreen": "display", "vsync": "display", "fps_limit": "display",
	"brightness": "graphics", "wave_resolution": "graphics",
	"mesh_quality": "graphics", "ps1_mode": "graphics", "water_effects": "graphics",
	"lens_drops": "graphics",
	"mouse_sensitivity": "controls", "fov": "controls", "invert_look": "controls",
	"master_volume": "audio", "sfx_volume": "audio", "music_volume": "audio",
}

## Each page: its title and the settings on it, top to bottom.
const PAGES: Array[Dictionary] = [
	{"title": "Graphics", "settings": ["fullscreen", "vsync", "fps_limit", "ps1_mode",
		"wave_resolution", "mesh_quality", "water_effects", "lens_drops"]},
	{"title": "Brightness", "settings": ["brightness"]},
	{"title": "Controls", "settings": ["mouse_sensitivity", "invert_look", "fov"]},
	{"title": "Audio", "settings": ["master_volume", "sfx_volume", "music_volume"]},
]

var water: Node
var player: Node
var retro_post: CanvasLayer

var _values := {} # setting key -> current value: the one truth the rows, the game and the file follow
var _rows := {} # setting key -> SettingRow
var _page := -1 # open page (index into PAGES), -1 = the section list
var _page_before := {} # the open page's values when it opened, for Discard
var _section_buttons: Array[Button] = []
var _using_keys := false # last input came from keys/pad: keep a visible focus for them

@onready var title_label: Label = %Title
@onready var sections_box: VBoxContainer = %Sections
@onready var page_box: VBoxContainer = %Page
@onready var rows_box: VBoxContainer = %Rows
@onready var brightness_extra: Control = %BrightnessExtra
@onready var brightness_preview: Control = %BrightnessPreview

func _ready() -> void:
	for i in PAGES.size():
		_section_buttons.append(_section_button(PAGES[i].title, _open_page.bind(i)))
	_section_buttons.append(_section_button("Back", _close))
	%ApplyButton.pressed.connect(_apply_page)
	%DiscardButton.pressed.connect(_discard_page)

	var tenths := func(v: float) -> String: return str(roundi(v * 10.0))
	_add_row("fullscreen", SettingRow.toggle("Fullscreen"))
	_add_row("vsync", SettingRow.toggle("V-Sync"))
	var fps_names: Array[String] = []
	for limit in FPS_LIMITS: fps_names.append("Unlimited" if limit == 0 else str(limit))
	_add_row("fps_limit", SettingRow.choice("Frame Rate Limit", fps_names, FPS_LIMITS))
	_add_row("ps1_mode", SettingRow.toggle("PS1 Filter"))
	var wave_names: Array[String] = []
	for res in _offered_wave_resolutions(): wave_names.append("%dx%d" % [res, res])
	_add_row("wave_resolution", SettingRow.choice("Wave Resolution", wave_names, _offered_wave_resolutions()))
	_add_row("mesh_quality", SettingRow.choice("Ocean Mesh Quality", MESH_QUALITY_NAMES, [0, 1, 2]))
	_add_row("water_effects", SettingRow.choice("Water Effects", EFFECTS_QUALITY_NAMES, [0, 1, 2]))
	_add_row("lens_drops", SettingRow.toggle("Rain on Lens"))
	_add_row("brightness", SettingRow.slider("Brightness", 0.0, 1.0, 0.01,
		func(v: float) -> String: return str(roundi(v * 100.0))))
	_add_row("mouse_sensitivity", SettingRow.slider("Mouse Sensitivity", 0.5, 10.0, 0.25,
		func(v: float) -> String: return "%.2f" % v))
	_add_row("invert_look", SettingRow.toggle("Invert Look"))
	_add_row("fov", SettingRow.slider("Field of View", 50.0, 110.0, 1.0,
		func(v: float) -> String: return str(roundi(v))))
	_add_row("master_volume", SettingRow.slider("Master Volume", 0.0, 1.0, 0.1, tenths))
	_add_row("sfx_volume", SettingRow.slider("Sound Effects", 0.0, 1.0, 0.1, tenths))
	_add_row("music_volume", SettingRow.slider("Music", 0.0, 1.0, 0.1, tenths))

func _section_button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	button.mouse_entered.connect(button.grab_focus)
	sections_box.add_child(button)
	return button

func _add_row(key: String, row: SettingRow) -> void:
	_rows[key] = row
	row.visible = false
	row.changed.connect(func(value: Variant) -> void:
		_values[key] = value
		_apply(key))
	rows_box.add_child(row)

func _offered_wave_resolutions() -> Array[int]:
	return WAVE_RESOLUTIONS.filter(func(res: int) -> bool: return not res in WAVE_RESOLUTIONS_DISABLED)

## Called by main once the world nodes exist: starts from how the game is set up now (so a first
## run keeps the project's defaults), lays the saved settings over that and applies them all.
func setup(water_node: Node, player_node: Node, retro_post_node: CanvasLayer) -> void:
	water = water_node
	player = player_node
	retro_post = retro_post_node
	_values = _current_values()
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		for key in CONFIG_SECTIONS:
			_values[key] = config.get_value(CONFIG_SECTIONS[key], key, _values[key])
	# Saved numbers can come back as floats; the lists match them exactly.
	for key in ["fps_limit", "wave_resolution", "mesh_quality", "water_effects"]:
		_values[key] = int(_values[key])
	for key in ["fullscreen", "vsync", "ps1_mode", "lens_drops", "invert_look"]:
		_values[key] = bool(_values[key])
	# eg. an old saved 128, a resolution we have since had to disable, or a hand-edited cap.
	if not _values.wave_resolution in _offered_wave_resolutions():
		_values.wave_resolution = DEFAULT_WAVE_RESOLUTION
	if not _values.fps_limit in FPS_LIMITS:
		_values.fps_limit = 0
	for key in _values:
		_apply(key)

## The settings as the game has them right now, before any saved file.
func _current_values() -> Dictionary:
	var rain := _rain()
	return {
		"fullscreen": DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN,
		"vsync": DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED,
		"fps_limit": Engine.max_fps,
		"brightness": 0.5,
		"wave_resolution": water.map_size,
		"mesh_quality": water.mesh_quality,
		"ps1_mode": retro_post.visible,
		"water_effects": 2,
		"lens_drops": rain.lens_drops_enabled if rain else true,
		"mouse_sensitivity": player.mouse_sensitivity * 1000.0,
		"fov": player.camera.fov,
		"invert_look": player.invert_look,
		"master_volume": _bus_volume(&'Master'),
		"sfx_volume": _bus_volume(&'SFX'),
		"music_volume": _bus_volume(&'Music'),
	}

## Puts one setting's value into the game.
func _apply(key: String) -> void:
	var value: Variant = _values[key]
	match key:
		"fullscreen":
			var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if value else DisplayServer.WINDOW_MODE_WINDOWED
			if DisplayServer.window_get_mode() != mode:
				DisplayServer.window_set_mode(mode)
		"vsync": # both ways: main.gd turns v-sync off at startup
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if value else DisplayServer.VSYNC_DISABLED)
		"fps_limit": Engine.max_fps = value
		"brightness": _apply_brightness()
		"wave_resolution":
			if water.map_size != value: water.map_size = value
		"mesh_quality":
			if water.mesh_quality != value: water.mesh_quality = value
		"ps1_mode":
			retro_post.visible = value
			_apply_render_scale()
		"water_effects":
			water.set_effects_quality(value)
			var rain := _rain()
			if rain: rain.set_effects_quality(value)
		"lens_drops":
			var rain := _rain()
			if rain: rain.lens_drops_enabled = value
		"mouse_sensitivity": player.mouse_sensitivity = value / 1000.0
		"fov": player.camera.fov = value
		"invert_look": player.invert_look = value
		"master_volume": _set_bus_volume(&'Master', value)
		"sfx_volume": _set_bus_volume(&'SFX', value)
		"music_volume": _set_bus_volume(&'Music', value)

# --- Opening, pages and closing ---

func open() -> void:
	_values.fullscreen = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN # F11
	_show_sections(0)
	visible = true

func _show_sections(focus_index: int) -> void:
	_page = -1
	title_label.text = "Settings"
	page_box.visible = false
	sections_box.visible = true
	if _using_keys:
		_section_buttons[focus_index].grab_focus()

func _open_page(index: int) -> void:
	_page = index
	var keys: Array = PAGES[index].settings
	title_label.text = PAGES[index].title
	for key in _rows:
		_rows[key].visible = key in keys
		_rows[key].set_value(_values[key])
	brightness_extra.visible = "brightness" in keys
	_page_before = {}
	for key in keys:
		_page_before[key] = _values[key]
	sections_box.visible = false
	page_box.visible = true
	if _using_keys:
		_rows[keys[0]].grab_focus()

func _apply_page() -> void:
	save_settings()
	_show_sections(_page)

func _discard_page() -> void:
	for key in _page_before:
		if _values[key] != _page_before[key]:
			_values[key] = _page_before[key]
			_apply(key)
	_show_sections(_page)

func _close() -> void:
	visible = false
	closed.emit()

## Esc: a page applies and goes back to the list; the list closes the menu.
func back() -> void:
	if _page >= 0:
		_apply_page()
	else:
		_close()

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		if not _using_keys and event.is_pressed():
			_using_keys = true
			if get_viewport().gui_get_focus_owner() == null:
				if _page >= 0: _rows[PAGES[_page].settings[0]].grab_focus()
				else: _section_buttons[0].grab_focus()
	elif event is InputEventMouseButton:
		_using_keys = false

# --- Saving ---

## Saves every setting. Public so main can save after the F11 fullscreen toggle.
func save_settings() -> void:
	_values.fullscreen = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
	var config := ConfigFile.new()
	for key in CONFIG_SECTIONS:
		config.set_value(CONFIG_SECTIONS[key], key, _values[key])
	config.save(SETTINGS_PATH)

# --- Brightness, render scale and sound ---

## Brightness, the way horror games do it: a gamma curve on the finished picture, so the dark
## lifts (or deepens) while lamps and fire stay put. 0.5 leaves the picture as authored.
## Done with the environment's colour correction, inside the tonemap pass it already runs:
## it costs nothing, works with the PS1 filter on or off, and leaves the menus alone.
static func brightness_exponent(value: float) -> float:
	return pow(2.0, (0.5 - value) * 2.0) # 0 -> 2 (darker), 0.5 -> 1, 1 -> 0.5 (brighter)

func _apply_brightness() -> void:
	var exponent := brightness_exponent(_values.brightness)
	brightness_preview.exponent = exponent
	var envs := get_tree().root.find_children("*", "WorldEnvironment", true, false)
	if envs.is_empty() or envs[0].environment == null:
		return
	var env: Environment = envs[0].environment
	var curve := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for i in 33:
		var x := i / 32.0
		var v := pow(x, exponent)
		offsets.append(x)
		colors.append(Color(v, v, v))
	curve.offsets = offsets
	curve.colors = colors
	var lut := GradientTexture1D.new()
	lut.gradient = curve
	lut.width = 256
	env.adjustment_enabled = true
	env.adjustment_color_correction = lut

## The 3D scene renders at the PS1 filter's resolution while PS1 mode is on (anything more is
## thrown away by the pixelation), full resolution otherwise. The UI is unaffected: it keeps the
## viewport's own resolution. (There is no Render Scale setting: the game already draws at
## 854x480, where scaling 3D down saved ~0.3 ms and could only blur, never pixelate.)
func _apply_render_scale() -> void:
	var scale := 1.0
	if retro_post and retro_post.visible:
		var post := retro_post.get_node_or_null(^'PostRect') as CanvasItem
		var rows = post.material.get_shader_parameter(&'target_rows') if post and post.material else null
		var pixelate = post.material.get_shader_parameter(&'pixelate') if post and post.material else false
		var height := get_viewport().get_visible_rect().size.y
		if pixelate == true and rows is float and height > 0.0:
			# Whole-pixel cells, so each 3D pixel is exactly one big pixel (a post shader with
			# target_rows/pixelate; the current lowres_post snaps by resolution_scale instead).
			scale *= 1.0 / maxf(round(height / rows), 1.0)
	get_viewport().scaling_3d_scale = scale

func _rain() -> Node:
	return get_tree().get_first_node_in_group(&'rain')

## Sets a bus to a 0..1 level, muting it outright at the bottom so it goes properly silent
## instead of merely very quiet.
func _set_bus_volume(bus_name: StringName, value: float) -> void:
	var bus := AudioServer.get_bus_index(bus_name)
	if bus < 0: return
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(value, 0.001)))
	AudioServer.set_bus_mute(bus, value <= 0.001)

func _bus_volume(bus_name: StringName) -> float:
	var bus := AudioServer.get_bus_index(bus_name)
	return db_to_linear(AudioServer.get_bus_volume_db(bus)) if bus >= 0 else 1.0
