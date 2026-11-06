extends Node
## Breath management with no HUD: running out of air desaturates the screen,
## closes a vignette (oxygen_overlay.gdshader) and raises a heartbeat that
## quickens as things get dire. Hitting zero emits player_died — the mission
## controller restages the same morning.

@export var player: CharacterBody3D
@export var overlay_rect: ColorRect
@export var heartbeat_player: AudioStreamPlayer
## Bubbles from the mouth (optional). A held breath releases nothing: one short involuntary
## gasp of bubbles a few seconds before the air runs out, then a steady stream once drowned
## (unconscious, the air escaping the lungs) until the morning restarts.
@export var breath_bubbles: BubbleEmitter
## Seconds of breath left when the gasp happens.
@export var gasp_bubbles_at: float = 3.0
@export var gasp_bubbles_duration: float = 0.5
## Emission while drowned (0..1 of the emitter's budget).
@export var drowned_bubble_stream: float = 0.35
## Seconds of unconsciousness after the air runs out, before the fade to the next morning:
## the body goes limp and sinks, the view drifts up towards the light, air escapes in a stream
## and the heartbeat slows and stops.
@export var drown_duration: float = 4.0
## How far the view tilts up (radians) and rolls while drowning.
@export var drown_look_up: float = 0.7
@export var drown_roll: float = 0.25

var _gasped := false
@export var max_breath: float = 40.0 # seconds of air — tune survival time here
@export var recover_rate: float = 12.0 # breath regained per second at the surface
@export var effect_start_fraction: float = 0.2 # breath fraction left when the screen effect starts
@export var flash_start_intensity: float = 0.4 # fraction of the effect ramp where the red flash begins

var breath: float
var infinite_breath := false # dev console: the air never runs down
var _died := false
var _drown_time := -1.0 # Seconds since drowning began (< 0 = not drowning).
var _drown_start_pitch := 0.0
var _drown_start_roll := 0.0
var _flash_phase := 0.0 # red pulses so far (fractional): the rate may change without the pulse jumping
## Air to breathe under the water (AirBubble pockets): source -> breath regained per second.
var _air_sources := {}

## Start breathing from `source` (eg. an air pocket the head is in), regaining `rate` seconds of
## breath per second for as long as it lasts. Call leave_air() when the head leaves it.
func enter_air(source: Object, rate: float) -> void:
	_air_sources[source] = rate

func leave_air(source: Object) -> void:
	_air_sources.erase(source)

## A gulp of air: `amount` seconds of breath at once (<= 0: a full breath).
func gulp_air(amount: float = 0.0) -> void:
	if _died: return
	breath = max_breath if amount <= 0.0 else minf(breath + amount, max_breath)

func _ready() -> void:
	breath = max_breath
	heartbeat_player.stream = _make_heartbeat_stream()
	EventBus.day_started.connect(_on_day_started)

func _on_day_started(_day: int) -> void:
	breath = max_breath
	_died = false
	_gasped = false
	if breath_bubbles: breath_bubbles.stream = 0.0
	if _drown_time >= 0.0:
		player.unconscious = false
		player.camera.rotation.x = 0.0
		player.camera.rotation.z = 0.0
		_set_hud_visible(true)
	_drown_time = -1.0

func _process(delta: float) -> void:
	if _drown_time >= 0.0:
		_process_drowning(delta)
		return
	var air_rate := 0.0
	for source in _air_sources.keys():
		if is_instance_valid(source): air_rate = maxf(air_rate, _air_sources[source])
		else: _air_sources.erase(source)
	if air_rate > 0.0:
		breath = minf(breath + air_rate * delta, max_breath)
	elif player._ears_underwater and not infinite_breath:
		breath = maxf(breath - delta, 0.0)
	else:
		breath = minf(breath + recover_rate * delta, max_breath)

	# The screen stays clean until only effect_start_fraction of breath is
	# left, then the full visual ramp plays out over what remains.
	var breath_fraction := breath / max_breath
	var effect := clampf((effect_start_fraction - breath_fraction) / effect_start_fraction, 0.0, 1.0)
	overlay_rect.material.set_shader_parameter(&'intensity', effect)

	# Drowning flash: kicks in partway up the effect ramp, pulsing 1/s and
	# accelerating to 3/s as the last breath approaches.
	var flash_t := clampf((effect - flash_start_intensity) / (1.0 - flash_start_intensity), 0.0, 1.0)
	overlay_rect.material.set_shader_parameter(&'flash_amount', flash_t)
	_flash_phase = fmod(_flash_phase + lerpf(1.0, 3.0, flash_t) * delta, 1.0)
	overlay_rect.material.set_shader_parameter(&'flash_phase', _flash_phase)

	# Heartbeat fades in past one third spent breath and quickens toward the
	# end — the sound deliberately forewarns long before the screen reacts.
	var spent := 1.0 - breath_fraction
	if spent > 0.3:
		if not heartbeat_player.playing:
			heartbeat_player.play()
		heartbeat_player.volume_db = lerpf(-40.0, -4.0, (spent - 0.3) / 0.7)
		heartbeat_player.pitch_scale = lerpf(0.85, 1.7, spent)
	elif heartbeat_player.playing:
		heartbeat_player.stop()

	if breath_bubbles:
		if breath <= gasp_bubbles_at and not _gasped and player._ears_underwater:
			_gasped = true
			breath_bubbles.burst(gasp_bubbles_duration)
		elif breath > gasp_bubbles_at + 1.0:
			_gasped = false # Surfaced and recovered: the next dive can gasp again.

	if breath <= 0.0 and not _died:
		_died = true
		if breath_bubbles:
			breath_bubbles.burst(0.6)
			breath_bubbles.stream = drowned_bubble_stream
		# Unconscious for a few seconds before the morning restarts (see _process_drowning).
		_drown_time = 0.0
		player.unconscious = true
		_drown_start_pitch = player.camera.rotation.x
		_drown_start_roll = player.camera.rotation.z
		_set_hud_visible(false) # No crosshair on an unconscious body.

func _set_hud_visible(shown: bool) -> void:
	var hud := player.get_node_or_null(^'HUD') as CanvasLayer
	if hud: hud.visible = shown

func _process_drowning(delta: float) -> void:
	_drown_time += delta
	var t := clampf(_drown_time / maxf(drown_duration, 0.01), 0.0, 1.0)
	var smooth := t * t * (3.0 - 2.0 * t)
	# The view drifts up towards the light and rolls, like a limp head.
	player.camera.rotation.x = lerpf(_drown_start_pitch, drown_look_up, smooth)
	player.camera.rotation.z = lerpf(_drown_start_roll, drown_roll, smooth)
	# The air thins out as the lungs empty.
	if breath_bubbles:
		breath_bubbles.stream = drowned_bubble_stream * (1.0 - 0.6 * t)
	# The heartbeat slows, fades and stops.
	if heartbeat_player.playing:
		heartbeat_player.pitch_scale = lerpf(1.0, 0.45, t)
		heartbeat_player.volume_db = lerpf(-4.0, -40.0, t)
		if t >= 0.9: heartbeat_player.stop()
	overlay_rect.material.set_shader_parameter(&'intensity', 1.0)
	overlay_rect.material.set_shader_parameter(&'flash_amount', 0.0) # No panic flashes any more.
	if _drown_time >= drown_duration and _drown_time - delta < drown_duration:
		EventBus.player_died.emit()

## Generates a looping two-thump heartbeat entirely in code (no asset needed).
func _make_heartbeat_stream() -> AudioStreamWAV:
	var rate := 22050
	var frames := rate # one second loop
	var data := PackedByteArray()
	data.resize(frames * 2)
	for i in frames:
		var t := float(i) / float(rate)
		var envelope := exp(-t * 22.0)
		if t >= 0.24:
			envelope += 0.65 * exp(-(t - 0.24) * 22.0)
		var sample := sin(TAU * 52.0 * t) * envelope
		data.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 20000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = frames
	wav.data = data
	return wav
