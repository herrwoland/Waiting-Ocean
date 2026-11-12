class_name InputBindings
## The player's controls: which keys, mouse buttons and controller inputs drive each action, and
## letting the player change them. Built on Godot's own InputMap, so game code keeps asking
## Input.is_action_pressed(&'jump') and never knows a key was remapped.
##
## Every row on the Key Bindings page has three slots: two for keyboard/mouse and one for a
## controller. Controllers come through SDL 3 (Godot 4.5+), which maps Xbox, PlayStation, Switch
## and hundreds of other pads onto one standard layout by button *position*, so a single set of
## controller bindings covers them all; only the names shown differ (see pad_family()).
## Saved to user://controls.cfg. Everything here is static: setup() runs once, whoever asks first.

const PATH := "user://controls.cfg"
const SLOTS := 3 # key, alt key, controller
const PAD_SLOT := 2
## Stick dead zone for every remappable action (Godot's default 0.5 wastes half the stick).
const DEADZONE := 0.2
## How far a stick or trigger must go to count while waiting for a new binding.
const CAPTURE_AXIS := 0.6

## The rows the player sees. "kb": the actions the two keyboard/mouse slots drive; "pad": the
## actions the controller slot drives (look has its own pad actions: a stick turns at its own
## speed, set apart from the turn keys). Rows are saved by "id".
const ROWS: Array[Dictionary] = [
	{"id": "move_forward", "name": "Move Forward", "kb": ["move_forward"], "pad": ["move_forward"]},
	{"id": "move_back", "name": "Move Back", "kb": ["move_back"], "pad": ["move_back"]},
	{"id": "move_left", "name": "Move Left", "kb": ["move_left"], "pad": ["move_left"]},
	{"id": "move_right", "name": "Move Right", "kb": ["move_right"], "pad": ["move_right"]},
	{"id": "sprint", "name": "Sprint", "kb": ["sprint"], "pad": ["sprint"]},
	{"id": "jump", "name": "Jump / Swim Up", "kb": ["jump", "swim_up"], "pad": ["jump", "swim_up"]},
	{"id": "swim_down", "name": "Swim Down", "kb": ["swim_down"], "pad": ["swim_down"]},
	{"id": "interact", "name": "Interact", "kb": ["interact"], "pad": ["interact"]},
	{"id": "sonar_pulse", "name": "Sonar Pulse", "kb": ["sonar_pulse"], "pad": ["sonar_pulse"]},
	{"id": "turn_left", "name": "Turn Left", "kb": ["turn_left"], "pad": ["pad_turn_left"]},
	{"id": "turn_right", "name": "Turn Right", "kb": ["turn_right"], "pad": ["pad_turn_right"]},
	{"id": "look_up", "name": "Look Up", "kb": ["look_up"], "pad": ["pad_look_up"]},
	{"id": "look_down", "name": "Look Down", "kb": ["look_down"], "pad": ["pad_look_down"]},
]

## Controller defaults, by row id: a button index (JoyButton) or [axis, direction].
## Positions, not letters: 0 is the bottom face button (A / Cross / Switch B).
const PAD_DEFAULTS := {
	"move_forward": [JOY_AXIS_LEFT_Y, -1], "move_back": [JOY_AXIS_LEFT_Y, 1],
	"move_left": [JOY_AXIS_LEFT_X, -1], "move_right": [JOY_AXIS_LEFT_X, 1],
	"sprint": JOY_BUTTON_LEFT_STICK,
	"jump": JOY_BUTTON_A,
	"swim_down": JOY_BUTTON_B,
	"interact": JOY_BUTTON_X,
	"sonar_pulse": JOY_BUTTON_RIGHT_SHOULDER,
	"turn_left": [JOY_AXIS_RIGHT_X, -1], "turn_right": [JOY_AXIS_RIGHT_X, 1],
	"look_up": [JOY_AXIS_RIGHT_Y, -1], "look_down": [JOY_AXIS_RIGHT_Y, 1],
}

enum Family { XBOX, PLAYSTATION, NINTENDO }
const FAMILY_NAMES: Array[String] = ["Xbox", "PlayStation", "Switch"]
## Button names per family, by JoyButton index (SDL positions).
const BUTTON_NAMES: Array = [
	["A", "B", "X", "Y", "View", "Xbox", "Menu", "LS", "RS", "LB", "RB", "D-Up", "D-Down", "D-Left", "D-Right", "Share", "P1", "P2", "P3", "P4", "Touchpad"],
	["Cross", "Circle", "Square", "Triangle", "Create", "PS", "Options", "L3", "R3", "L1", "R1", "D-Up", "D-Down", "D-Left", "D-Right", "Mute", "P1", "P2", "P3", "P4", "Touchpad"],
	["B", "A", "Y", "X", "-", "Home", "+", "LS", "RS", "L", "R", "D-Up", "D-Down", "D-Left", "D-Right", "Capture", "P1", "P2", "P3", "P4", "Touchpad"],
]
const TRIGGER_NAMES: Array = [["LT", "RT"], ["L2", "R2"], ["ZL", "ZR"]]
const MOUSE_NAMES := {
	MOUSE_BUTTON_LEFT: "Left Click", MOUSE_BUTTON_RIGHT: "Right Click", MOUSE_BUTTON_MIDDLE: "Middle Click",
	MOUSE_BUTTON_WHEEL_UP: "Wheel Up", MOUSE_BUTTON_WHEEL_DOWN: "Wheel Down",
	MOUSE_BUTTON_XBUTTON1: "Mouse 4", MOUSE_BUTTON_XBUTTON2: "Mouse 5",
}

static var _set_up := false
static var _defaults := {} # row id -> [event or null] * SLOTS
static var _slots := {} # row id -> [event or null] * SLOTS, what is in force
static var family := Family.XBOX # of the controller used last (or plugged in)

## Makes sure every action exists, takes the project's own keys as the defaults, adds the
## controller defaults, then lays the saved bindings over them. Safe to call any number of times.
static func setup() -> void:
	if _set_up:
		return
	_set_up = true
	for row in ROWS:
		for action in row.kb + row.pad:
			if not InputMap.has_action(action):
				InputMap.add_action(action)
		var keys: Array = InputMap.action_get_events(row.kb[0]).filter(
			func(e: InputEvent) -> bool: return e is InputEventKey or e is InputEventMouseButton)
		var pad_default: Variant = PAD_DEFAULTS[row.id]
		var pad_event: InputEvent
		if pad_default is Array:
			pad_event = _axis_event(pad_default[0], pad_default[1])
		else:
			pad_event = _button_event(pad_default)
		_defaults[row.id] = [keys[0] if keys.size() > 0 else null, keys[1] if keys.size() > 1 else null, pad_event]
	_slots = _copy(_defaults)
	_add_pause_action()
	var joypads := Input.get_connected_joypads()
	if not joypads.is_empty():
		note_device(joypads[0])
	var config := ConfigFile.new()
	if config.load(PATH) == OK:
		for row in ROWS:
			var saved: Variant = config.get_value("bindings", row.id, null)
			if saved is Array and saved.size() == SLOTS:
				_slots[row.id] = saved.map(_from_dict)
	apply()

## Esc / Start open the pause menu; not remappable, so the menu is always one press away.
## Also gives the menus' own accept/cancel a controller's A and B (Godot's built-in ui_accept and
## ui_cancel have keys only; the d-pad and left stick already move between buttons).
static func _add_pause_action() -> void:
	if not InputMap.action_has_event(&'ui_accept', _button_event(JOY_BUTTON_A)):
		InputMap.action_add_event(&'ui_accept', _button_event(JOY_BUTTON_A))
	if not InputMap.action_has_event(&'ui_cancel', _button_event(JOY_BUTTON_B)):
		InputMap.action_add_event(&'ui_cancel', _button_event(JOY_BUTTON_B))
	if InputMap.has_action(&'pause'):
		return
	InputMap.add_action(&'pause')
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	InputMap.action_add_event(&'pause', esc)
	InputMap.action_add_event(&'pause', _button_event(JOY_BUTTON_START))

## Writes the slots into the InputMap.
static func apply() -> void:
	for row in ROWS:
		for action in row.kb + row.pad:
			InputMap.action_erase_events(action)
			InputMap.action_set_deadzone(action, DEADZONE)
	for row in ROWS:
		var slots: Array = _slots[row.id]
		for action in row.kb:
			for i in PAD_SLOT:
				if slots[i]: InputMap.action_add_event(action, slots[i])
		for action in row.pad:
			if slots[PAD_SLOT]: InputMap.action_add_event(action, slots[PAD_SLOT])

static func save() -> void:
	var config := ConfigFile.new()
	for row in ROWS:
		config.set_value("bindings", row.id, _slots[row.id].map(_to_dict))
	config.save(PATH)

static func get_event(row_id: String, slot: int) -> InputEvent:
	return _slots[row_id][slot]

## Binds `event` to a slot. Whatever else had it gets this slot's old binding instead (a swap),
## so nothing is ever left doing two jobs and nothing is silently lost.
static func bind(row_id: String, slot: int, event: InputEvent) -> void:
	var old: InputEvent = _slots[row_id][slot]
	var key := _to_dict(event)
	for other in ROWS:
		for other_slot in _group(slot):
			if (other.id != row_id or other_slot != slot) and _to_dict(_slots[other.id][other_slot]) == key:
				_slots[other.id][other_slot] = old
	_slots[row_id][slot] = event
	apply()

static func clear(row_id: String, slot: int) -> void:
	_slots[row_id][slot] = null
	apply()

## The keyboard/mouse slots share one pool, the controller slot its own.
static func _group(slot: int) -> Array:
	return [PAD_SLOT] if slot == PAD_SLOT else range(PAD_SLOT)

static func snapshot() -> Dictionary:
	return _copy(_slots)

## Whether the bindings in force are the same as a snapshot (compared by what they press, not
## by event object).
static func matches(saved: Dictionary) -> bool:
	for id in _slots:
		for slot in SLOTS:
			if _to_dict(_slots[id][slot]) != _to_dict(saved.get(id, [null, null, null])[slot]):
				return false
	return true

static func restore(saved: Dictionary) -> void:
	_slots = _copy(saved)
	apply()

static func reset_to_defaults() -> void:
	_slots = _copy(_defaults)
	apply()

static func _copy(from: Dictionary) -> Dictionary:
	var out := {}
	for id in from:
		out[id] = from[id].duplicate()
	return out

# --- Capturing a new binding ---

## Whether `event` can be bound into `slot`, as the event to store (or null). Releases, small
## stick wobbles, mouse motion and the wrong kind of device all give null.
static func capture(event: InputEvent, slot: int) -> InputEvent:
	if slot == PAD_SLOT:
		if event is InputEventJoypadButton and event.pressed:
			return _button_event(event.button_index)
		if event is InputEventJoypadMotion and absf(event.axis_value) >= CAPTURE_AXIS:
			return _axis_event(event.axis, signi(roundi(signf(event.axis_value))))
		return null
	if event is InputEventKey and event.pressed and not event.echo:
		var key := InputEventKey.new()
		key.physical_keycode = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
		return key
	if event is InputEventMouseButton and event.pressed:
		var mouse := InputEventMouseButton.new()
		mouse.button_index = event.button_index
		return mouse
	return null

## Esc (or a controller's Start) stops waiting for a binding without changing anything.
static func is_cancel(event: InputEvent) -> bool:
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
		return true
	return event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_START

# --- Names ---

## Remembers which kind of controller is in use, from its name or maker, so the menu can call
## its buttons by the names printed on it.
static func note_device(device: int) -> void:
	var name := Input.get_joy_name(device).to_lower()
	var vendor: Variant = Input.get_joy_info(device).get("vendor_id", 0)
	if vendor == 0x054C or ["playstation", "dualshock", "dualsense", "ps3", "ps4", "ps5"].any(func(s: String) -> bool: return s in name):
		family = Family.PLAYSTATION
	elif vendor == 0x057E or ["nintendo", "switch", "pro controller", "joy-con"].any(func(s: String) -> bool: return s in name):
		family = Family.NINTENDO
	else:
		family = Family.XBOX

static func family_name() -> String:
	return FAMILY_NAMES[family]

## What a binding is called, eg. "W", "Left Click", "Cross", "R Stick Left".
static func event_name(event: InputEvent) -> String:
	if event == null:
		return "-"
	if event is InputEventKey:
		var shown := DisplayServer.keyboard_get_keycode_from_physical(event.physical_keycode)
		return OS.get_keycode_string(shown if shown != KEY_NONE else event.physical_keycode)
	if event is InputEventMouseButton:
		return MOUSE_NAMES.get(event.button_index, "Mouse %d" % event.button_index)
	if event is InputEventJoypadButton:
		var names: Array = BUTTON_NAMES[family]
		return names[event.button_index] if event.button_index < names.size() else "Button %d" % event.button_index
	if event is InputEventJoypadMotion:
		match event.axis:
			JOY_AXIS_TRIGGER_LEFT: return TRIGGER_NAMES[family][0]
			JOY_AXIS_TRIGGER_RIGHT: return TRIGGER_NAMES[family][1]
		var stick := "L Stick" if event.axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y] else "R Stick"
		var horizontal: bool = event.axis in [JOY_AXIS_LEFT_X, JOY_AXIS_RIGHT_X]
		var way := ("Right" if event.axis_value > 0.0 else "Left") if horizontal else ("Down" if event.axis_value > 0.0 else "Up")
		return "%s %s" % [stick, way]
	return "?"

# --- Events <-> saved form ---

static func _button_event(index: int) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.device = -1 # any controller
	event.button_index = index
	return event

static func _axis_event(axis: int, direction: int) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new()
	event.device = -1
	event.axis = axis
	event.axis_value = float(direction)
	return event

static func _to_dict(event: InputEvent) -> Dictionary:
	if event is InputEventKey: return {"key": int(event.physical_keycode)}
	if event is InputEventMouseButton: return {"mouse": int(event.button_index)}
	if event is InputEventJoypadButton: return {"button": int(event.button_index)}
	if event is InputEventJoypadMotion: return {"axis": int(event.axis), "dir": signi(roundi(signf(event.axis_value)))}
	return {}

static func _from_dict(saved: Variant) -> InputEvent:
	if not saved is Dictionary or saved.is_empty():
		return null
	if saved.has("key"):
		var key := InputEventKey.new()
		key.physical_keycode = saved.key
		return key
	if saved.has("mouse"):
		var mouse := InputEventMouseButton.new()
		mouse.button_index = saved.mouse
		return mouse
	if saved.has("button"):
		return _button_event(saved.button)
	if saved.has("axis"):
		return _axis_event(saved.axis, saved.dir)
	return null

# --- For game code ---

## The right stick as a look vector (x: right, y: down), with a round dead zone and a gentle
## curve: fine aim near the centre, full speed at the rim.
static func pad_look() -> Vector2:
	setup()
	var v := Input.get_vector(&'pad_turn_left', &'pad_turn_right', &'pad_look_up', &'pad_look_down', DEADZONE)
	return v * v.length()
