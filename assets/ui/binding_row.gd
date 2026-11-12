class_name BindingRow
extends PanelContainer
## One line of the Key Bindings page: the action's name, then its three slots (key, alt key,
## controller). Click a slot, or pick it with left/right and press Enter / A, to rebind it;
## right-click or Delete clears it. The settings menu does the listening (see `rebind_requested`).

signal rebind_requested(row: BindingRow, slot: int)

const SLOT_WIDTHS: Array[float] = [76.0, 76.0, 100.0] # key, alt key, controller ("L Stick Right")
const NAME_WIDTH := 120.0

var row_id: String
var selected := 0 # the slot left/right moves between
var _waiting_slot := -1 # the slot showing "...", waiting for a key or button
var _slots: Array[Button] = []

static func make(id: String, text: String) -> BindingRow:
	var row := BindingRow.new()
	row.row_id = id
	row._build(text)
	return row

## The column headings, laid out like a row so they line up.
static func header(slot_titles: Array[String]) -> HBoxContainer:
	var line := HBoxContainer.new()
	var spacer := Control.new()
	spacer.custom_minimum_size.x = NAME_WIDTH + 8.0 # + the row's left margin
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(spacer)
	for i in slot_titles.size():
		var label := Label.new()
		label.theme_type_variation = &'HintLabel'
		label.text = slot_titles[i]
		label.custom_minimum_size.x = SLOT_WIDTHS[i]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line.add_child(label)
	var right_margin := Control.new()
	right_margin.custom_minimum_size.x = 4.0
	line.add_child(right_margin)
	return line

func _build(text: String) -> void:
	theme_type_variation = &'SettingRow'
	focus_mode = Control.FOCUS_ALL
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(line)
	var name_label := Label.new()
	name_label.text = text
	name_label.custom_minimum_size.x = NAME_WIDTH
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(name_label)
	for i in InputBindings.SLOTS:
		var button := Button.new()
		button.custom_minimum_size.x = SLOT_WIDTHS[i]
		button.clip_text = true
		button.focus_mode = Control.FOCUS_NONE
		button.button_mask = MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT
		button.gui_input.connect(_on_slot_input.bind(i))
		line.add_child(button)
		_slots.append(button)
	mouse_entered.connect(grab_focus)
	focus_entered.connect(_restyle)
	focus_exited.connect(_restyle)
	refresh()

## Shows the bindings as they stand (and "..." in a slot waiting for a new one).
func refresh(waiting_slot := -1) -> void:
	_waiting_slot = waiting_slot
	for i in _slots.size():
		_slots[i].text = "..." if i == waiting_slot else InputBindings.event_name(InputBindings.get_event(row_id, i))
	_restyle()

func _restyle() -> void:
	theme_type_variation = &'SettingRowFocus' if has_focus() else &'SettingRow'
	for i in _slots.size():
		var lit := i == _waiting_slot or (has_focus() and i == selected)
		_slots[i].theme_type_variation = &'BindingSlotSelected' if lit else &'BindingSlot'

func _on_slot_input(event: InputEvent, slot: int) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	selected = slot
	grab_focus()
	_restyle()
	if event.button_index == MOUSE_BUTTON_LEFT:
		rebind_requested.emit(self, slot)
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		InputBindings.clear(row_id, slot)
		refresh()
	accept_event()

func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed(&'ui_left', true):
		selected = maxi(selected - 1, 0)
		_restyle()
		accept_event()
	elif event.is_action_pressed(&'ui_right', true):
		selected = mini(selected + 1, _slots.size() - 1)
		_restyle()
		accept_event()
	elif event.is_action_pressed(&'ui_accept'):
		rebind_requested.emit(self, selected)
		accept_event()
	elif event is InputEventKey and event.pressed and event.physical_keycode in [KEY_DELETE, KEY_BACKSPACE]:
		InputBindings.clear(row_id, selected)
		refresh()
		accept_event()
