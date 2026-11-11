extends Node
## The game's own developer console commands (autoload, after Console). Press ~ in game to open
## the console; "commands_list" lists every command with what it does, "cvars" every variable.
## While the console is open the game is paused and the mouse is free, so typing never walks
## the player about; commands that animate (power, weather blends) play out once it closes.
## The scene's nodes are looked up when a command runs, so they survive a scene reload.
## Toggles take on/off (or 1/0); left out, they flip.

const PRESET_DIR := 'res://assets/weather/presets/'
const LEVIATHAN_ENCOUNTER := 'res://assets/scripts/world/leviathan_encounter.gd'
const POWER_PANEL := 'res://scenes/boat/power_panel.gd'
const FURNACE := 'res://scenes/boat/furnace_fire.gd'
const BOAT := 'res://assets/models/ship/boat.gd'

var _mouse_mode_before := Input.MOUSE_MODE_VISIBLE
var _volumetric_fog_before := true # fog off remembers it, fog on brings it back
var _rain_before := 0.7 # rain off remembers how hard it was

func _ready() -> void:
	Console.pause_enabled = true
	Console.console_opened.connect(_on_console_opened)
	Console.console_closed.connect(_on_console_closed)
	Console.print_line('Type [system_color color=CONSOLE_COLOR_LITERAL]commands_list[/system_color] for every command, [system_color color=CONSOLE_COLOR_LITERAL]cvars[/system_color] for every variable.')

	Console.add_command('leviathan', _leviathan, 0, 0, 'Calls the leviathan now, night or day, anywhere.')
	Console.add_command('leviathan_gone', _leviathan_gone, 0, 0, 'Removes the leviathan if one is out.')
	Console.add_command('weather', _weather, ['preset', 'seconds'], 0, 'Switches to a weather preset (blending over seconds if given). No preset: lists them.')
	Console.add_command_autocomplete_list('weather', _preset_names())
	Console.add_command('rain', _rain, ['on|off|0..1'], 0, 'Turns the rain on/off or sets how hard it falls.')
	Console.add_command('fog', _fog, ['on|off'], 0, 'Turns the fog (and volumetric fog) on/off.')
	Console.add_command('clouds', _clouds, ['0..1'], 0, 'Sets how much of the sky is cloud. No value: prints it.')
	Console.add_command('water', _water, ['on|off'], 0, 'Shows/hides the water surface.')
	Console.add_command('infinite_breath', _infinite_breath, ['on|off'], 0, 'The air never runs out under water.')
	Console.add_command('infinite_fuel', _infinite_fuel, ['on|off'], 0, 'The furnace never burns down (fills it up).')
	Console.add_command('fuel', _fuel, ['0..100'], 0, 'Sets the furnace fuel in percent. No value: prints it.')
	Console.add_command('power', _power, ['on|off'], 0, 'Pulls the ship\'s power lever (plays once the console closes).')
	Console.add_command('engine_power', _engine_power, ['newtons'], 0, 'Sets each engine cell full-throttle thrust (default 400000, max 1000000). No value: prints it.')
	Console.add_command('day', _day, ['1..5'], 0, 'Starts that morning (unsaved). No value: restarts today.')
	Console.add_command('fps', _fps, ['on|off'], 0, 'Shows/hides the FPS counter.')
	Console.add_cvar_reference('time_scale', Engine, 'time_scale', 'Game speed (1 = normal).')

## Variables pointing into the scene are (re)made on each opening: the scene may have changed.
func _on_console_opened() -> void:
	_mouse_mode_before = Input.get_mouse_mode()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	var env := _environment()
	if env:
		Console.add_cvar_reference('fog_density', env, 'fog_density', 'Distance fog density.')
		Console.add_cvar_reference('volumetric_fog_density', env, 'volumetric_fog_density', 'Volumetric fog density.')
		Console.add_cvar_reference('exposure', env, 'tonemap_exposure', 'Tonemap exposure.')
	var weather := _weather_node()
	if weather and weather.sun:
		Console.add_cvar_reference('sun_energy', weather.sun, 'light_energy', 'Sun brightness (under 0.55 counts as night for the leviathan).')
	if weather and weather.rain:
		Console.add_cvar_reference('rain_wind', weather.rain, 'wind_strength', 'How hard the wind drives the rain.')

func _on_console_closed() -> void:
	Input.set_mouse_mode(_mouse_mode_before)

# --- Commands ---

func _leviathan() -> void:
	var encounter := _find_scripted(LEVIATHAN_ENCOUNTER)
	if not encounter: return
	if encounter.is_active():
		Console.print_warning('The leviathan is already out.')
		return
	encounter.summon()
	if encounter.is_active():
		Console.print_info('It is rising.')
	else:
		Console.print_error('It did not come (no ship, player or water set on the encounter).')

func _leviathan_gone() -> void:
	var encounter := _find_scripted(LEVIATHAN_ENCOUNTER)
	if not encounter: return
	for child in encounter.get_children():
		if child is Leviathan and not child.is_queued_for_deletion():
			child.queue_free()
			Console.print_info('Gone. (A ship it took stays taken until morning: try "day".)')
			return
	Console.print_warning('There is no leviathan out.')

func _weather(preset_name: String, seconds: String) -> void:
	var weather := _weather_node()
	if not weather: return
	if preset_name.is_empty():
		var current := weather.preset.resource_path.get_file().get_basename() if weather.preset else '?'
		Console.print_line('Presets: %s   (started as: %s)' % [', '.join(_preset_names()), current])
		return
	var path := PRESET_DIR + preset_name + '.tres'
	if not ResourceLoader.exists(path):
		Console.print_error('No preset "%s". Presets: %s' % [preset_name, ', '.join(_preset_names())])
		return
	weather.transition_to(load(path), seconds.to_float() if seconds.is_valid_float() else 0.0)
	Console.print_info('Weather: %s' % preset_name)

func _rain(value: String) -> void:
	var weather := _weather_node()
	if not weather or not weather.rain: return
	var rain := weather.rain
	if value.is_valid_float():
		rain.intensity = clampf(value.to_float(), 0.0, 1.0)
	else:
		var on: Variant = _parse_toggle(value, rain.intensity > 0.001)
		if on == null: return
		if not on and rain.intensity > 0.001:
			_rain_before = rain.intensity
		rain.intensity = _rain_before if on else 0.0
	Console.print_info('Rain: %.2f' % rain.intensity)

func _fog(value: String) -> void:
	var env := _environment()
	if not env: return
	var on: Variant = _parse_toggle(value, env.fog_enabled or env.volumetric_fog_enabled)
	if on == null: return
	if on:
		env.fog_enabled = true
		env.volumetric_fog_enabled = _volumetric_fog_before
	else:
		_volumetric_fog_before = env.volumetric_fog_enabled
		env.fog_enabled = false
		env.volumetric_fog_enabled = false
	Console.print_info('Fog: %s' % _on_off(on))

func _clouds(value: String) -> void:
	var env := _environment()
	var sky := env.sky.sky_material as ShaderMaterial if env and env.sky else null
	if not sky or sky.get_shader_parameter(&'coverage') == null:
		Console.print_error('This sky has no clouds to change.')
		return
	if value.is_empty():
		Console.print_line('Clouds: %.2f' % sky.get_shader_parameter(&'coverage'))
		return
	if not value.is_valid_float():
		Console.print_error('Give a number from 0 to 1.')
		return
	sky.set_shader_parameter(&'coverage', clampf(value.to_float(), 0.0, 1.0))
	for child in _weather_node().get_children(true):
		if child is CloudMap: child.restart() # redraw now rather than drift in
	Console.print_info('Clouds: %.2f' % sky.get_shader_parameter(&'coverage'))

func _water(value: String) -> void:
	var water := get_tree().get_first_node_in_group(&'water') as Node3D
	if not water:
		Console.print_error('No water in this scene.')
		return
	var on: Variant = _parse_toggle(value, water.visible)
	if on == null: return
	water.visible = on
	Console.print_info('Water: %s' % _on_off(on))

func _infinite_breath(value: String) -> void:
	var player := get_tree().get_first_node_in_group(&'player')
	var oxygen := player.get_node_or_null(^'OxygenController') if player else null
	if not oxygen:
		Console.print_error('No player breath to change.')
		return
	var on: Variant = _parse_toggle(value, oxygen.infinite_breath)
	if on == null: return
	oxygen.infinite_breath = on
	if on: oxygen.breath = oxygen.max_breath
	Console.print_info('Infinite breath: %s' % _on_off(on))

func _infinite_fuel(value: String) -> void:
	var furnace := _find_scripted(FURNACE)
	if not furnace: return
	var on: Variant = _parse_toggle(value, furnace.infinite_fuel)
	if on == null: return
	furnace.infinite_fuel = on
	if on: furnace.set_fuel(furnace.max_fuel)
	Console.print_info('Infinite fuel: %s' % _on_off(on))

func _fuel(value: String) -> void:
	var furnace := _find_scripted(FURNACE)
	if not furnace: return
	if not value.is_empty():
		if not value.is_valid_float():
			Console.print_error('Give a percentage from 0 to 100.')
			return
		furnace.set_fuel(furnace.max_fuel * clampf(value.to_float(), 0.0, 100.0) / 100.0)
	Console.print_info('Fuel: %d%%' % roundi(furnace.fuel_level() * 100.0))

func _engine_power(value: String) -> void:
	var boat := _find_scripted(BOAT)
	if not boat: return
	if not value.is_empty():
		if not value.is_valid_float():
			Console.print_error('Give a thrust in newtons, eg. 400000.')
			return
		boat.set_engine_power(value.to_float())
	Console.print_info('Engine power: %d N per cell' % roundi(boat.engine_power))

func _power(value: String) -> void:
	var panel := _find_scripted(POWER_PANEL)
	if not panel: return
	var on: Variant = _parse_toggle(value, panel.on)
	if on == null: return
	if on != panel.on:
		panel._on_lever_pulled(null)
	Console.print_info('Power: %s' % _on_off(on))

func _day(value: String) -> void:
	if not value.is_empty():
		if not value.is_valid_int() or value.to_int() < 1 or value.to_int() > GameState.FINAL_DAY:
			Console.print_error('Give a day from 1 to %d.' % GameState.FINAL_DAY)
			return
		GameState.current_day = value.to_int()
	GameState.start_day()
	Console.print_info('Morning of day %d.' % GameState.current_day)

func _fps(value: String) -> void:
	var overlay := get_tree().current_scene.get_node_or_null(^'FpsOverlay') as CanvasLayer if get_tree().current_scene else null
	if not overlay:
		Console.print_error('No FPS counter in this scene.')
		return
	var on: Variant = _parse_toggle(value, overlay.visible)
	if on == null: return
	overlay.visible = on
	Console.print_info('FPS: %s' % _on_off(on))

# --- Helpers ---

## true/false from on/off, 1/0, true/false; empty flips `current`. null (and an error) otherwise.
func _parse_toggle(value: String, current: bool) -> Variant:
	match value.strip_edges().to_lower():
		'': return not current
		'on', '1', 'true', 'yes': return true
		'off', '0', 'false', 'no': return false
	Console.print_error('Expected on or off, got "%s".' % value)
	return null

func _on_off(on: bool) -> String:
	return 'on' if on else 'off'

func _preset_names() -> PackedStringArray:
	var names := PackedStringArray()
	for file in ResourceLoader.list_directory(PRESET_DIR):
		if file.ends_with('.tres'):
			names.append(file.get_basename())
	return names

func _weather_node() -> Weather:
	var weather := get_tree().get_first_node_in_group(&'weather') as Weather
	if not weather:
		Console.print_error('No weather in this scene.')
	return weather

func _environment() -> Environment:
	var weather := get_tree().get_first_node_in_group(&'weather') as Weather
	if weather and weather.world_environment:
		return weather.world_environment.environment
	return get_viewport().world_3d.environment if get_viewport().world_3d else null

## The first node in the current scene running the script at `path` (or null and an error).
func _find_scripted(path: String) -> Node:
	var scene := get_tree().current_scene
	if scene:
		for node in scene.find_children('*', '', true, false):
			var script := node.get_script() as Script
			if script and script.resource_path == path:
				return node
	Console.print_error('Nothing in this scene runs %s.' % path.get_file())
	return null
