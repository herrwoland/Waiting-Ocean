class_name SettingRow
extends PanelContainer
## One line of the settings menu: the name on the left, "<  value  >" on the right. Every kind of
## setting changes the same way: left/right (keys or pad, while the row is highlighted), the
## arrow buttons, or a click on the value. Sliders also drag, and show their value by the name.
## Built in code by the factories below; the settings menu listens to `changed`.

signal changed(value: Variant)

enum Kind { TOGGLE, CHOICE, SLIDER }

const MIDDLE_WIDTH := 140.0 # the value / slider between the arrows, the same on every row

var kind: Kind
var value: Variant

var _names: Array[String] = [] # TOGGLE/CHOICE: what each option is called
var _values: Array = [] # TOGGLE/CHOICE: the option values, in order
var _step := 0.1 # SLIDER
var _format: Callable # SLIDER: value -> the text shown by the name
var _value_button: Button # TOGGLE/CHOICE
var _slider: HSlider # SLIDER
var _readout: Label # SLIDER

static func toggle(text: String) -> SettingRow:
	return _make(text, Kind.TOGGLE, ["Off", "On"], [false, true])

static func choice(text: String, names: Array[String], values: Array) -> SettingRow:
	return _make(text, Kind.CHOICE, names, values)

static func slider(text: String, lo: float, hi: float, step: float, format: Callable) -> SettingRow:
	var row := _make(text, Kind.SLIDER, [], [])
	row._step = step
	row._format = format
	row._slider.min_value = lo
	row._slider.max_value = hi
	row._slider.step = step
	return row

static func _make(text: String, row_kind: Kind, names: Array[String], values: Array) -> SettingRow:
	var row := SettingRow.new()
	row.kind = row_kind
	row._names = names
	row._values = values
	row._build(text)
	return row

func _build(text: String) -> void:
	theme_type_variation = &'SettingRow'
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(line)

	var name_label := Label.new()
	name_label.text = text
	line.add_child(name_label)
	_readout = Label.new()
	_readout.theme_type_variation = &'ValueLabel'
	_readout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(_readout)

	line.add_child(_arrow('<', -1))
	if kind == Kind.SLIDER:
		_slider = HSlider.new()
		_slider.custom_minimum_size.x = MIDDLE_WIDTH
		_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_slider.focus_mode = Control.FOCUS_NONE # left/right belong to the row
		_slider.value_changed.connect(_on_slider_moved)
		line.add_child(_slider)
	else:
		_value_button = Button.new()
		_value_button.theme_type_variation = &'SettingValue'
		_value_button.custom_minimum_size.x = MIDDLE_WIDTH
		_value_button.focus_mode = Control.FOCUS_NONE
		_value_button.pressed.connect(_cycle)
		line.add_child(_value_button)
	line.add_child(_arrow('>', 1))

	mouse_entered.connect(grab_focus) # the highlight follows the mouse too
	focus_entered.connect(func() -> void: theme_type_variation = &'SettingRowFocus')
	focus_exited.connect(func() -> void: theme_type_variation = &'SettingRow')

func _arrow(text: String, direction: int) -> Button:
	var button := Button.new()
	button.text = text
	button.theme_type_variation = &'ArrowButton'
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(nudge.bind(direction))
	return button

## Shows `new_value` without announcing it (the menu already knows).
func set_value(new_value: Variant) -> void:
	value = new_value
	if kind == Kind.SLIDER:
		_slider.set_value_no_signal(new_value)
		_readout.text = _format.call(new_value)
	else:
		var index := _values.find(new_value)
		_value_button.text = _names[index] if index >= 0 else str(new_value)

## One step left (-1) or right (+1). Lists stop at their ends; on/off just flips.
func nudge(direction: int) -> void:
	match kind:
		Kind.SLIDER:
			_set_and_announce(clampf(value + direction * _step, _slider.min_value, _slider.max_value))
		Kind.TOGGLE:
			_set_and_announce(not value)
		Kind.CHOICE:
			var index := clampi(_values.find(value) + direction, 0, _values.size() - 1)
			_set_and_announce(_values[index])

## A click on the value: the next option, wrapping round.
func _cycle() -> void:
	grab_focus()
	if kind == Kind.TOGGLE:
		nudge(1)
	else:
		_set_and_announce(_values[(_values.find(value) + 1) % _values.size()])

func _on_slider_moved(new_value: float) -> void:
	grab_focus()
	_set_and_announce(new_value)

func _set_and_announce(new_value: Variant) -> void:
	if new_value == value:
		return
	set_value(new_value)
	changed.emit(new_value)

func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed(&'ui_left', true):
		nudge(-1)
		accept_event()
	elif event.is_action_pressed(&'ui_right', true):
		nudge(1)
		accept_event()
	elif event.is_action_pressed(&'ui_accept') and kind != Kind.SLIDER:
		_cycle()
		accept_event()
