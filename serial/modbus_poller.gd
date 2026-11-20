extends Node

signal coil_updated(unit: int, address: int, value: bool)
signal input_register_updated(unit: int, address: int, value: int)

@export var unit: int = 1
@export var poll_interval_ms: int = 20
@export var response_timeout_ms: int = 1000

@export var coil_addresses: Array[int] = [5, 6, 7, 8, 9]
@export var input_register_addresses: Array[int] = [0, 1, 2]

const READ_COIL: int = 0x01
const READ_INPUT_REGISTER: int = 0x04

var _items: Array[Dictionary] = []
var _index: int = 0
var _pending_request_id: int = -1
var _next_poll_at: int = 0


func _ready() -> void:
	_build_poll_items()

	Serial.connection_changed.connect(_on_connection_changed)

	Modbus.coil_received.connect(_on_coil_received)
	Modbus.input_register_received.connect(_on_input_register_received)
	Modbus.request_failed.connect(_on_request_failed)

	Modbus.response_timeout_ms = response_timeout_ms
	Modbus.stop_polling()

	_on_connection_changed(Serial.connected, Serial.selected_port)


func _build_poll_items() -> void:
	_items.clear()

	for address in coil_addresses:
		_items.append({
			"fc": READ_COIL,
			"address": address,
		})

	for address in input_register_addresses:
		_items.append({
			"fc": READ_INPUT_REGISTER,
			"address": address,
		})


func _process(_delta: float) -> void:
	if not Serial.connected or _items.is_empty():
		return

	if _pending_request_id != -1:
		return

	var now := Time.get_ticks_msec()

	if now < _next_poll_at:
		return

	var item: Dictionary = _items[_index]
	var address: int = int(item["address"])
	var request_id: int = -1

	match int(item["fc"]):
		READ_COIL:
			request_id = Modbus.read_coil(unit, address)

		READ_INPUT_REGISTER:
			request_id = Modbus.read_input_register(unit, address)

	if request_id == -1:
		_next_poll_at = now + poll_interval_ms
		return

	_pending_request_id = request_id
	_index = (_index + 1) % _items.size()


func _on_connection_changed(
	is_connected: bool,
	_port: String
) -> void:
	_pending_request_id = -1

	if is_connected:
		_index = 0
		_next_poll_at = Time.get_ticks_msec() + poll_interval_ms


func _complete_request(request_id: int) -> bool:
	if request_id != _pending_request_id:
		return false

	_pending_request_id = -1
	_next_poll_at = Time.get_ticks_msec() + poll_interval_ms
	return true


func _on_coil_received(
	request_id: int,
	received_unit: int,
	address: int,
	value: bool
) -> void:
	if not _complete_request(request_id):
		return

	coil_updated.emit(received_unit, address, value)


func _on_input_register_received(
	request_id: int,
	received_unit: int,
	address: int,
	value: int
) -> void:
	if not _complete_request(request_id):
		return

	input_register_updated.emit(received_unit, address, value)


func _on_request_failed(request_id: int, reason: String) -> void:
	if not _complete_request(request_id):
		return

	push_warning(
		"Modbus, запрос №%d: %s" % [request_id, reason]
	)
