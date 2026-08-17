## CODED BY CHAT GPT and KIMI

class_name AudioInListenToAudioIntensity
extends Node



signal on_percent_intensity_updated(percent_intensity: float)


@export var _audio_stream: AudioStreamPlayer = null
@export var _record_bus_name: String = "Record"
@export var _update_interval: float = 0.05
## Microphone names in order of priority. The first one found in the
## available input device list is selected. If empty or none match,
## the current default input device is kept.
@export var _microphone_priority: Array[String] = []


@export_group("Debug")
@export var _percent_intensity: float = 0.0


var _capture_effect: AudioEffectCapture = null
var _sample_rate: float = 44100.0
var _accumulated_time: float = 0.0

func _ready() -> void:
	print("Input enabled: ",
		ProjectSettings.get_setting("audio/driver/enable_input"))

	var devices := AudioServer.get_input_device_list()

	print("Available microphones:")
	for device in devices:
		print("  - ", device)

	# Select preferred microphone
	var microphone_found := false

	for preferred in _microphone_priority:
		for device in devices:
			if device.to_lower() == preferred.to_lower():
				print("Trying microphone: ", device)

				AudioServer.input_device = device

				print("Godot selected: ", AudioServer.input_device)

				if AudioServer.input_device == device:
					microphone_found = true
				else:
					push_error(
						"Failed to select microphone: " + device
					)

				break

		if microphone_found:
			break

	if not microphone_found:
		push_warning(
			"No preferred microphone found. Using: "
			+ AudioServer.input_device
		)

	print("FINAL MICROPHONE: ", AudioServer.input_device)


	# Create/get recording bus
	var bus_index := AudioServer.get_bus_index(_record_bus_name)

	if bus_index == -1:
		bus_index = AudioServer.bus_count

		AudioServer.add_bus(bus_index)
		AudioServer.set_bus_name(bus_index, _record_bus_name)
		AudioServer.set_bus_mute(bus_index, true)

		var capture := AudioEffectCapture.new()
		AudioServer.add_bus_effect(bus_index, capture)


	# Find capture effect
	_capture_effect = null

	for effect_index in range(
		AudioServer.get_bus_effect_count(bus_index)
	):
		var effect := AudioServer.get_bus_effect(
			bus_index,
			effect_index
		)

		if effect is AudioEffectCapture:
			_capture_effect = effect
			break

	if _capture_effect == null:
		push_error("AudioEffectCapture was not found!")


	# Use INPUT sample rate
	_sample_rate = AudioServer.get_input_mix_rate()

	print("Input sample rate: ", _sample_rate)


	# Start microphone
	if _audio_stream != null:
		_audio_stream.stream = AudioStreamMicrophone.new()
		_audio_stream.bus = _record_bus_name
		_audio_stream.play()

		print("Microphone stream started.")

func _process(delta: float) -> void:
	if _capture_effect == null or not _capture_effect.can_get_buffer(1):
		return

	_accumulated_time += delta
	if _accumulated_time < _update_interval:
		return

	var frames_to_read: int = int(_accumulated_time * _sample_rate)
	_accumulated_time = 0.0
	frames_to_read = min(frames_to_read, _capture_effect.get_frames_available())
	if frames_to_read <= 0:
		return

	var buffer: PackedVector2Array = _capture_effect.get_buffer(frames_to_read)
	var sum: float = 0.0
	for sample in buffer:
		var mono: float = (sample.x + sample.y) * 0.5
		sum += mono * mono

	var rms: float = sqrt(sum / buffer.size())
	_percent_intensity = clampf(rms, 0.0, 1.0)
	on_percent_intensity_updated.emit(_percent_intensity)
