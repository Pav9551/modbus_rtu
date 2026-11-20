extends Node
## Transport is the Serial autoload. No serial ports are opened here.

signal coil_received(request_id: int, unit: int, address: int, value: bool)
signal coil_written(request_id: int, unit: int, address: int, value: bool)
signal request_failed(request_id: int, reason: String)
signal input_register_received(
	request_id: int,
	unit: int,
	address: int,
	value: int
)

@export var response_timeout_ms: int = 1000
@export var quiet_time_ms: int = 10
@export var max_queue_size: int = 64

var _queue: Array[Dictionary] = []
var _active: Dictionary = {}
var _rx := PackedByteArray()
var _next_id := 1
var _deadline := 0
var _not_before := 0
var _poll_enabled := false
var _poll_unit := 1
var _poll_addresses: Array[int] = []
var _poll_index := 0
var _poll_interval_ms := 10
var _poll_due := 0
var _poll_function: int = 0x01

func _ready() -> void:
	Serial.bytes_received.connect(_on_bytes_received)
	Serial.connection_changed.connect(_on_connection_changed)
	_not_before = Time.get_ticks_msec() + quiet_time_ms

func read_coil(unit: int, address: int) -> int:
	return _enqueue(unit, 0x01, address, false)
func read_input_register(unit: int, address: int) -> int:
	return _enqueue(unit, 0x04, address, false)

func write_coil(unit: int, address: int, value: bool) -> int:
	return _enqueue(unit, 0x05, address, value)

func start_polling(
	unit: int,
	addresses: Array[int],
	interval_ms: int = 100
) -> bool:
	return _start_polling(unit, addresses, interval_ms, 0x01)


func start_input_register_polling(
	unit: int,
	addresses: Array[int],
	interval_ms: int = 100
) -> bool:
	return _start_polling(unit, addresses, interval_ms, 0x04)

func _start_polling(
	unit: int,
	addresses: Array[int],
	interval_ms: int,
	function: int
) -> bool:
	if unit < 1 or unit > 247 or addresses.is_empty() or interval_ms < 1:
		return false

	for address in addresses:
		if address < 0 or address > 65535:
			return false

	_poll_unit = unit
	_poll_addresses.assign(addresses)
	_poll_index = 0
	_poll_interval_ms = interval_ms
	_poll_function = function
	_poll_due = 0
	_poll_enabled = true
	return true

func stop_polling() -> void:
	# Does not cancel a request already queued or transmitted.
	_poll_enabled = false

func _enqueue(
	unit: int,
	function: int,
	address: int,
	value: bool
) -> int:
	if not Serial.connected or _queue.size() >= max_queue_size:
		return -1

	if unit < 1 or unit > 247:
		return -1

	if address < 0 or address > 65535:
		return -1

	# Адрес для отправки устройству.
	var wire_address: int = ModbusConfig.to_wire_address(address)

	if wire_address < 0 or wire_address > 65535:
		push_warning(
			"Адрес %d после пересчёта стал %d: вне диапазона 0–65535"
			% [address, wire_address]
		)
		return -1

	var id := _next_id
	_next_id += 1

	_queue.append({
		"id": id,
		"unit": unit,
		"fc": function,

		# Исходный адрес для логики программы.
		"address": address,

		# Пересчитанный адрес для пакета Modbus.
		"wire_address": wire_address,

		"value": value
	})

	return id

func _process(_delta: float) -> void:
	if not Serial.connected:
		return

	var now := Time.get_ticks_msec()

	if not _active.is_empty() and now >= _deadline:
		_fail_active(
			"Response timeout; a write may already have been executed"
		)

	if (
		_poll_enabled
		and now >= _poll_due
		and _active.is_empty()
		and _queue.is_empty()
	):
		_enqueue(
			_poll_unit,
			_poll_function,
			_poll_addresses[_poll_index],
			false
		)
		_poll_index = (_poll_index + 1) % _poll_addresses.size()
		_poll_due = now + _poll_interval_ms

	if _active.is_empty() and not _queue.is_empty() and now >= _not_before:
		_send_next()

func _send_next() -> void:
	_active = _queue.pop_front()
	_rx.clear()

	var function := int(_active.fc)
	var frame := PackedByteArray([
		int(_active.unit),
		function
	])

	# В пакет отправляем адрес со смещением.
	_append_u16(frame, int(_active.wire_address))

	if function == 0x01 or function == 0x04:
		_append_u16(frame, 1)
	else:
		_append_u16(
			frame,
			0xFF00 if bool(_active.value) else 0x0000
		)

	# Далее оставьте существующий код функции:
	# расчёт CRC, установка тайм-аута и отправка.

	var crc := _crc16(frame)
	frame.append(crc & 0xFF)
	frame.append((crc >> 8) & 0xFF)

	_active["frame"] = frame

	var tx_ms := int(ceil(88000.0 / float(Serial.BAUD_RATE)))
	_deadline = Time.get_ticks_msec() + tx_ms + response_timeout_ms

	if not Serial.send_bytes(frame):
		_fail_active("Transport rejected the request")

func _on_bytes_received(data: PackedByteArray) -> void:
	_not_before = Time.get_ticks_msec() + quiet_time_ms

	if _active.is_empty():
		return

	_rx.append_array(data)

	if _rx.size() > 256:
		_fail_active("Receive buffer overflow")
		return

	if _rx.size() < 2:
		return

	var function := int(_active.fc)

	if _rx[0] != int(_active.unit):
		_fail_active("Unexpected unit address")
		return

	var exception := _rx[1] == (function | 0x80)

	if not exception and _rx[1] != function:
		_fail_active("Unexpected function code")
		return

	var expected_length: int = 5

	if not exception:
		match function:
			0x01:
				expected_length = 6
			0x04:
				expected_length = 7
			0x05:
				expected_length = 8
			_:
				_fail_active("Unsupported function code")
				return

		if (function == 0x01 or function == 0x04) and _rx.size() >= 3:
			var expected_byte_count := 1 if function == 0x01 else 2

			if int(_rx[2]) != expected_byte_count:
				_fail_active(
					"Expected exactly %d data byte(s)" % expected_byte_count
				)
				return

	if _rx.size() < expected_length:
		return

	if _rx.size() != expected_length:
		_fail_active("Extra bytes; check framing and local echo")
		return

	var crc := _crc16(_rx.slice(0, expected_length - 2))

	if (
		_rx[expected_length - 2] != (crc & 0xFF)
		or _rx[expected_length - 1] != ((crc >> 8) & 0xFF)
	):
		_fail_active("CRC mismatch")
		return

	if exception:
		_fail_active("Modbus exception 0x%02X" % _rx[2])
		return

	var request: Dictionary = _active.duplicate()
	var coil_value := false
	var register_value := 0

	match function:
		0x01:
			coil_value = (_rx[3] & 1) != 0

		0x04:
			register_value = (int(_rx[3]) << 8) | int(_rx[4])

		0x05:
			var expected: PackedByteArray = request.frame

			if _rx != expected:
				_fail_active("Write acknowledgement mismatch")
				return

			coil_value = bool(request.value)

	_finish_active()

	match function:
		0x01:
			coil_received.emit(
				int(request.id),
				int(request.unit),
				int(request.address),
				coil_value
			)

		0x04:
			input_register_received.emit(
				int(request.id),
				int(request.unit),
				int(request.address),
				register_value
			)

		0x05:
			coil_written.emit(
				int(request.id),
				int(request.unit),
				int(request.address),
				coil_value
			)

func _finish_active() -> void:
	_active = {}
	_rx.clear()
	_not_before = Time.get_ticks_msec() + quiet_time_ms

func _fail_active(reason: String) -> void:
	if _active.is_empty():
		return
	var id := int(_active.id)
	_finish_active()
	request_failed.emit(id, reason)

func _on_connection_changed(is_connected: bool, _port: String) -> void:
	_not_before = Time.get_ticks_msec() + quiet_time_ms
	if is_connected:
		_poll_due = _not_before
		return
	var ids: Array[int] = []
	if not _active.is_empty():
		ids.append(int(_active.id))
	for request in _queue:
		ids.append(int(request.id))
	_active = {}
	_queue.clear()
	_rx.clear()
	for id in ids:
		request_failed.emit(id, "Disconnected; a write outcome may be unknown")

func _append_u16(target: PackedByteArray, value: int) -> void:
	target.append((value >> 8) & 0xFF)
	target.append(value & 0xFF)

func _crc16(data: PackedByteArray) -> int:
	var crc := 0xFFFF
	for byte in data:
		crc ^= byte
		for _bit in range(8):
			if (crc & 1) != 0:
				crc = (crc >> 1) ^ 0xA001
			else:
				crc >>= 1
	return crc & 0xFFFF
