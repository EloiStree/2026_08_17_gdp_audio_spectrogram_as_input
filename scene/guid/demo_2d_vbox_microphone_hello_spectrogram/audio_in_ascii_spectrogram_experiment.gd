class_name AudioInAsciiSpectrogramExperiment
extends Node


signal on_spectrogram_as_text_updated(text: String)

@export_group("Spectrogram")
@export var _width: int = 128
@export var _height: int = 64

## Characters go from lowest intensity to highest intensity.
@export var _characters: String = " .:-=+*#%@"

## Print a new frame every N received columns.
## 1 = maximum update rate.
@export_range(1, 20, 1)
var _print_every_n_columns: int = 1


var _ascii_buffer: Array[String] = []
var _column_counter: int = 0
var _spectrogram_text: String = ""


func _ready() -> void:
	_create_empty_buffer()



func _create_empty_buffer() -> void:
	_ascii_buffer.clear()

	var empty_line := ""

	for x in range(_width):
		empty_line += " "

	for y in range(_height):
		_ascii_buffer.append(empty_line)


func on_spectrogram_column_updated(
	column: PackedFloat32Array
) -> void:

	if column.is_empty():
		return

	_column_counter += 1

	if _column_counter < _print_every_n_columns:
		return

	_column_counter = 0

	_add_column(column)

	_update_spectrogram_text()


func _add_column(column: PackedFloat32Array) -> void:
	# Move everything one character to the left.
	for y in range(_height):
		var line := _ascii_buffer[y]

		if line.length() > 1:
			line = line.substr(1)

		line += " "

		_ascii_buffer[y] = line


	# Draw newest frequency column on the right.
	#
	# Spectrogram convention:
	#
	#       high frequency
	#              ↑
	#              │
	#              │
	#              │
	#              ↓
	#       low frequency
	#
	# Therefore we reverse the input frequency order.
	for y in range(_height):
		var source_index := _frequency_index_for_row(
			y,
			column.size()
		)

		var intensity := column[source_index]

		var character := _intensity_to_character(
			intensity
		)

		var line := _ascii_buffer[y]

		line = line.substr(
			0,
			_width - 1
		)

		line += character

		_ascii_buffer[y] = line


func _frequency_index_for_row(
	row: int,
	column_size: int
) -> int:

	if column_size <= 1:
		return 0

	# Top row = highest frequency.
	# Bottom row = lowest frequency.
	var normalized := float(row) / float(_height - 1)

	var index := int(
		(1.0 - normalized) * float(column_size - 1)
	)

	return clampi(
		index,
		0,
		column_size - 1
	)


func _intensity_to_character(
	intensity: float
) -> String:

	intensity = clampf(
		intensity,
		0.0,
		1.0
	)

	var character_count := _characters.length()

	if character_count <= 1:
		return " "

	var index := int(
		intensity * float(character_count - 1)
	)

	index = clampi(
		index,
		0,
		character_count - 1
	)

	return _characters.substr(index, 1)


func _update_spectrogram_text() -> void:
	_spectrogram_text = get_spectrogram_text()
	on_spectrogram_as_text_updated.emit(_spectrogram_text)


func get_spectrogram_text() -> String:
	return "\n".join(_ascii_buffer)
