## CODED BY CHAT GPT
class_name AudioInListenToAudioToBuildSpectrogramArray
extends Node


signal on_percent_intensity_updated(percent_intensity: float)

## Emits one vertical spectrogram column.
##
## The array contains one intensity value per frequency bin.
signal on_spectrogram_column_updated(column: PackedFloat32Array)

@export var _audio_stream: AudioStreamPlayer = null
@export var _record_bus_name: String = "Record"
@export var _update_interval: float = 0.05

## Number of frequency bins in the spectrogram.
@export_range(8, 512, 1)
var _frequency_bins: int = 64

## Lowest frequency represented by the spectrogram.
@export var _min_frequency: float = 20.0

## Highest frequency represented by the spectrogram.
## 0 means Nyquist frequency.
@export var _max_frequency: float = 0.0

## Number of columns retained in the spectrogram.
## For example:
## 200 columns * 0.05 seconds = approximately 10 seconds.
@export_range(1, 2000, 1)
var _max_spectrogram_columns: int = 200

## Use logarithmic frequency spacing.
## This generally looks much better for an audio spectrogram.
@export var _log_frequency_scale: bool = true


## Microphone names in order of priority.
@export var _microphone_priority: Array[String] = []


@export_group("Debug")
@export var _percent_intensity: float = 0.0

## The actual accumulated spectrogram.
##
## Each element is one time column:
##
## _spectrogram[time][frequency]
##
## Therefore:
##   _spectrogram.size()              = number of time columns
##   _spectrogram[x].size()           = number of frequency bins
var _spectrogram: Array[PackedFloat32Array] = []


var _capture_effect: AudioEffectCapture = null
var _spectrum_effect: AudioEffectSpectrumAnalyzer = null
var _spectrum_instance: AudioEffectSpectrumAnalyzerInstance = null

var _sample_rate: float = 44100.0
var _accumulated_time: float = 0.0


func _ready() -> void:
	print("Input enabled: ",
		ProjectSettings.get_setting("audio/driver/enable_input"))

	var devices := AudioServer.get_input_device_list()

	print("Available microphones:")
	for device in devices:
		print("  - ", device)


	# ---------------------------------------------------------
	# Select preferred microphone
	# ---------------------------------------------------------

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


	# ---------------------------------------------------------
	# Create/get recording bus
	# ---------------------------------------------------------

	var bus_index := AudioServer.get_bus_index(_record_bus_name)

	if bus_index == -1:
		bus_index = AudioServer.bus_count

		AudioServer.add_bus(bus_index)
		AudioServer.set_bus_name(bus_index, _record_bus_name)

		# We don't want microphone audio to come out
		# of the speakers.
		AudioServer.set_bus_mute(bus_index, true)


	# ---------------------------------------------------------
	# Find/create AudioEffectCapture
	# ---------------------------------------------------------

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
		_capture_effect = AudioEffectCapture.new()
		AudioServer.add_bus_effect(
			bus_index,
			_capture_effect
		)


	# ---------------------------------------------------------
	# Find/create Spectrum Analyzer
	# ---------------------------------------------------------

	_spectrum_effect = null
	_spectrum_instance = null

	for effect_index in range(
		AudioServer.get_bus_effect_count(bus_index)
	):
		var effect := AudioServer.get_bus_effect(
			bus_index,
			effect_index
		)

		if effect is AudioEffectSpectrumAnalyzer:
			_spectrum_effect = effect
			break


	if _spectrum_effect == null:
		_spectrum_effect = AudioEffectSpectrumAnalyzer.new()

		# The analyzer needs enough history to perform
		# frequency analysis.
		_spectrum_effect.buffer_length = 2.0

		_spectrum_effect.fft_size = (
			AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
		)

		AudioServer.add_bus_effect(
			bus_index,
			_spectrum_effect
		)


	# ---------------------------------------------------------
	# Get spectrum analyzer instance
	# ---------------------------------------------------------

	if _audio_stream != null:
		_audio_stream.stream = AudioStreamMicrophone.new()
		_audio_stream.bus = _record_bus_name
		_audio_stream.play()

		print("Microphone stream started.")


	# We need the stream to actually be running before
	# getting the spectrum instance.
	_spectrum_instance = AudioServer.get_bus_effect_instance(
		bus_index,
		AudioServer.get_bus_effect_count(bus_index) - 1
	) as AudioEffectSpectrumAnalyzerInstance


	if _spectrum_instance == null:
		# Search all effects in case the analyzer isn't last.
		for effect_index in range(
			AudioServer.get_bus_effect_count(bus_index)
		):
			var instance := AudioServer.get_bus_effect_instance(
				bus_index,
				effect_index
			)

			if instance is AudioEffectSpectrumAnalyzerInstance:
				_spectrum_instance = instance
				break


	# ---------------------------------------------------------
	# Sample rate
	# ---------------------------------------------------------

	_sample_rate = AudioServer.get_input_mix_rate()

	print("Input sample rate: ", _sample_rate)

	if _max_frequency <= 0.0:
		_max_frequency = _sample_rate * 0.5

	_max_frequency = min(
		_max_frequency,
		_sample_rate * 0.5
	)

	print(
		"Spectrogram frequency range: ",
		_min_frequency,
		" Hz - ",
		_max_frequency,
		" Hz"
	)


# =============================================================
# PROCESS
# =============================================================

func _process(delta: float) -> void:
	if _capture_effect == null:
		return

	if not _capture_effect.can_get_buffer(1):
		return


	_accumulated_time += delta

	if _accumulated_time < _update_interval:
		return


	_accumulated_time = 0.0


	# ---------------------------------------------------------
	# Read microphone samples
	# ---------------------------------------------------------

	var frames_to_read: int = int(
		_update_interval * _sample_rate
	)

	frames_to_read = min(
		frames_to_read,
		_capture_effect.get_frames_available()
	)

	if frames_to_read <= 0:
		return


	var buffer: PackedVector2Array = (
		_capture_effect.get_buffer(frames_to_read)
	)


	# ---------------------------------------------------------
	# Calculate RMS intensity
	# ---------------------------------------------------------

	var sum: float = 0.0

	for sample in buffer:
		var mono: float = (
			sample.x + sample.y
		) * 0.5

		sum += mono * mono


	if buffer.size() > 0:
		var rms := sqrt(
			sum / float(buffer.size())
		)

		_percent_intensity = clampf(
			rms,
			0.0,
			1.0
		)

		on_percent_intensity_updated.emit(
			_percent_intensity
		)


	# ---------------------------------------------------------
	# Build spectrogram column
	# ---------------------------------------------------------

	if _spectrum_instance != null:
		var column := _build_spectrogram_column()

		if column.size() > 0:
			_spectrogram.push_back(column)

			# Keep only the requested amount of history.
			while _spectrogram.size() > _max_spectrogram_columns:
				_spectrogram.pop_front()

			on_spectrogram_column_updated.emit(column)


# =============================================================
# BUILD ONE SPECTROGRAM COLUMN
# =============================================================

func _build_spectrogram_column() -> PackedFloat32Array:
	var column := PackedFloat32Array()

	if _spectrum_instance == null:
		return column


	column.resize(_frequency_bins)


	for i in range(_frequency_bins):
		var frequency_start: float
		var frequency_end: float


		if _log_frequency_scale:
			# Logarithmic frequency distribution.
			var t0 := float(i) / float(_frequency_bins)
			var t1 := float(i + 1) / float(_frequency_bins)

			frequency_start = lerpf(
				log(_min_frequency),
				log(_max_frequency),
				t0
			)

			frequency_end = lerpf(
				log(_min_frequency),
				log(_max_frequency),
				t1
			)

			frequency_start = exp(frequency_start)
			frequency_end = exp(frequency_end)

		else:
			# Linear frequency distribution.
			var t0 := float(i) / float(_frequency_bins)
			var t1 := float(i + 1) / float(_frequency_bins)

			frequency_start = lerpf(
				_min_frequency,
				_max_frequency,
				t0
			)

			frequency_end = lerpf(
				_min_frequency,
				_max_frequency,
				t1
			)


		# Get left/right spectrum magnitude.
		var magnitude := (
			_spectrum_instance.get_magnitude_for_frequency_range(
				frequency_start,
				frequency_end
			)
		)


		# Convert stereo magnitude to mono.
		var energy := (
			magnitude.x + magnitude.y
		) * 0.5


		# Convert to a more useful 0..1-ish intensity.
		#
		# The logarithmic conversion is important because
		# raw FFT magnitudes have a very large dynamic range.
		var db := linear_to_db(
			max(energy, 0.000001)
		)

		var normalized := inverse_lerp(
			-80.0,
			0.0,
			db
		)

		column[i] = clampf(
			normalized,
			0.0,
			1.0
		)


	return column


# =============================================================
# PUBLIC API
# =============================================================

func get_spectrogram() -> Array[PackedFloat32Array]:
	return _spectrogram


func get_latest_spectrogram_column() -> PackedFloat32Array:
	if _spectrogram.is_empty():
		return PackedFloat32Array()

	return _spectrogram[_spectrogram.size() - 1]


func clear_spectrogram() -> void:
	_spectrogram.clear()
