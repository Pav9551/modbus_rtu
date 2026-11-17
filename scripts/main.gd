extends Control

@onready var status_label: Label = $StatusLabel
@onready var input_register_0_label: Label = $InputRegister0Label
@onready var input_register_1_label: Label = $InputRegister1Label

const UNIT: int = 1
const POLL_INTERVAL_MS: int = 20
const RESPONSE_TIMEOUT_MS: int = 1000

# Порядок опроса:
# coils 5–9, затем Input Registers 0 и 1.
var _poll_items: Array[Dictionary] = [
	{"fc": 0x01, "address": 5},
	{"fc": 0x01, "address": 6},
	{"fc": 0x01, "address": 7},
	{"fc": 0x01, "address": 8},
	{"fc": 0x01, "address": 9},
	{"fc": 0x04, "address": 0},
	{"fc": 0x04, "address": 1},
]

var _poll_index: int = 0
var _pending_request_id: int = -1
var _next_poll_at: int = 0
var _poll_enabled: bool = true


func _ready() -> void:
	input_register_0_label.text = "—"
	input_register_1_label.text = "—"
	Serial.connection_changed.connect(_on_connection_changed)

	Modbus.coil_received.connect(_on_coil_received)
	Modbus.coil_written.connect(_on_coil_written)
	Modbus.input_register_received.connect(_on_input_register_received)
	Modbus.request_failed.connect(_on_request_failed)

	Modbus.response_timeout_ms = RESPONSE_TIMEOUT_MS

	# Расписанием смешанного опроса управляет этот Control.
	# Встроенный опрос Modbus не запускаем.
	Modbus.stop_polling()

	_on_connection_changed(
		Serial.connected,
		Serial.selected_port
	)


func _process(_delta: float) -> void:
	if not _poll_enabled or not Serial.connected:
		return

	# Не ставим следующий запрос опроса,
	# пока предыдущий не завершился.
	if _pending_request_id != -1:
		return

	var now := Time.get_ticks_msec()

	if now < _next_poll_at:
		return

	var item: Dictionary = _poll_items[_poll_index]
	var function: int = int(item["fc"])
	var address: int = int(item["address"])
	var request_id: int = -1

	match function:
		0x01:
			request_id = Modbus.read_coil(UNIT, address)

		0x04:
			request_id = Modbus.read_input_register(UNIT, address)

	if request_id == -1:
		# Например, очередь заполнена.
		# Позже повторяем тот же адрес.
		_next_poll_at = now + POLL_INTERVAL_MS
		return

	_pending_request_id = request_id
	_poll_index = (_poll_index + 1) % _poll_items.size()


func _exit_tree() -> void:
	_poll_enabled = false


func _on_connection_changed(
	is_connected: bool,
	port: String
) -> void:
	if is_connected:
		status_label.text = "Подключено: " + port

		# После подключения начинаем проход с первого адреса.
		_poll_index = 0
		_next_poll_at = Time.get_ticks_msec() + POLL_INTERVAL_MS
	else:
		status_label.text = "Устройство не подключено"

		# Запросы при отключении сбрасывает сам Modbus.
		_pending_request_id = -1


func _complete_poll_request(request_id: int) -> void:
	if request_id != _pending_request_id:
		return

	_pending_request_id = -1
	_next_poll_at = Time.get_ticks_msec() + POLL_INTERVAL_MS


func _on_coil_received(
	request_id: int,
	unit: int,
	address: int,
	value: bool
) -> void:
	_complete_poll_request(request_id)

	print(
		"RX №", request_id,
		": устройство=", unit,
		", coil=", address,
		", значение=", value
	)


func _on_input_register_received(
	request_id: int,
	unit: int,
	address: int,
	value: int
) -> void:
	# Обязательно оставляем: разрешает следующий запрос опроса.
	_complete_poll_request(request_id)

	if unit != UNIT:
		return

	match address:
		0:
			input_register_0_label.text = str(value)

		1:
			input_register_1_label.text = str(value)

	print(
		"RX №", request_id,
		": устройство=", unit,
		", input register=", address,
		", значение=", value
	)


func _on_coil_written(
	request_id: int,
	unit: int,
	address: int,
	value: bool
) -> void:
	print(
		"Запись подтверждена №", request_id,
		": устройство=", unit,
		", coil=", address,
		", значение=", value
	)


func _on_request_failed(
	request_id: int,
	reason: String
) -> void:
	_complete_poll_request(request_id)

	push_warning(
		"Modbus, запрос №%d: %s" % [request_id, reason]
	)
