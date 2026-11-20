extends Control

const LOG_INTERVAL: float = 5.0
const MAX_ROWS: int = 500

# Если C8 соответствует адресу 7, поменяй значение на 7.
const C8_ADDRESS: int = 8

@onready var status_label: Label = $StatusLabel
@onready var poller = $ModbusPoller
@onready var register_table: Tree = $RegisterTable

@onready var _register_labels: Dictionary = {
	0: $VBoxContainer/InputRegister0Label,
	1: $VBoxContainer/InputRegister1Label,
	2: $VBoxContainer/InputRegister2Label
}

var _latest_values: Dictionary = {}

var _c8_value: bool = false
var _c8_received: bool = false

var _table_root: TreeItem
var _log_timer: Timer


func _ready() -> void:
	for label: Label in _register_labels.values():
		label.text = "—"

	_setup_table()

	Serial.connection_changed.connect(_on_connection_changed)
	poller.coil_updated.connect(_on_coil_updated)
	poller.input_register_updated.connect(
		_on_input_register_updated
	)

	_on_connection_changed(
		Serial.connected,
		Serial.selected_port
	)

	_log_timer = Timer.new()
	_log_timer.wait_time = LOG_INTERVAL
	_log_timer.one_shot = false
	add_child(_log_timer)

	_log_timer.timeout.connect(_append_table_row)
	_log_timer.start()


func _setup_table() -> void:
	register_table.clear()
	register_table.columns = 5
	register_table.hide_root = true
	register_table.column_titles_visible = true

	register_table.set_column_title(0, "Время")
	register_table.set_column_title(1, "in: EXC C8")
	register_table.set_column_title(2, "out: TOP")
	register_table.set_column_title(3, "out: BOT")
	register_table.set_column_title(4, "out: EXC RESET")

	# Выравнивание заголовков по левому краю.
	for column in range(register_table.columns):
		register_table.set_column_title_alignment(
			column,
			HORIZONTAL_ALIGNMENT_LEFT
		)

	register_table.set_column_custom_minimum_width(0, 180)

	for column in range(1, register_table.columns):
		register_table.set_column_custom_minimum_width(
			column, 100
		)

	register_table.set_column_custom_minimum_width(4, 150)

	_table_root = register_table.create_item()


func _on_connection_changed(
	is_connected: bool,
	port: String
) -> void:
	status_label.text = (
		"Подключено: " + port
		if is_connected
		else "Устройство не подключено"
	)

	# Не используем старые значения после переподключения.
	_latest_values.clear()
	_c8_value = false
	_c8_received = false

	for label: Label in _register_labels.values():
		label.text = "—"
		label.remove_theme_color_override("font_color")


func _on_input_register_updated(
	unit: int,
	address: int,
	value: int
) -> void:
	if unit != poller.unit:
		return

	var label: Label = _register_labels.get(address)

	if label == null:
		return

	_latest_values[address] = value

	label.text = str(value)
	label.add_theme_color_override(
		"font_color",
		Color.RED if value == 0 else Color.GREEN
	)


func _on_coil_updated(
	unit: int,
	address: int,
	value: bool
) -> void:
	if unit != poller.unit:
		return

	# Сравниваем исходные адреса программы.
	if address == C8_ADDRESS:
		_c8_value = value
		_c8_received = true

	# Для вывода вычисляем адрес устройства.
	var device_address: int = ModbusConfig.to_wire_address(address)

	print(
		"Устройство=", unit,
		", coil в программе=", address,
		", coil на устройстве=", device_address,
		", значение=", value
	)


func _append_table_row() -> void:
	if not Serial.connected:
		return

	# Для таблицы нужны значения регистров 0, 1 и 2.
	for address in range(3):
		if not _latest_values.has(address):
			return

	var row: TreeItem = register_table.create_item(
		_table_root
	)

	# Столбец 0 — время.
	row.set_text(
		0,
		Time.get_datetime_string_from_system(false, true)
	)

	# Столбец 1 — C8 coil.
	if _c8_received:
		row.set_text(1, "1" if _c8_value else "0")
		row.set_custom_color(
			1,
			Color.GREEN if _c8_value else Color.RED
		)
	else:
		row.set_text(1, "—")

	# Столбцы 2, 3 и 4 — регистры 0, 1 и 2.
	# 0 -> out: TOP
	# 1 -> out: BOT
	# 2 -> out: EXC RESET
	for address in range(3):
		var value: int = int(_latest_values[address])
		var column: int = address + 2

		row.set_text(column, str(value))
		row.set_custom_color(
			column,
			Color.RED if value == 0 else Color.GREEN
		)

	# Оставляем только последние MAX_ROWS строк.
	while _table_root.get_child_count() > MAX_ROWS:
		var oldest_row: TreeItem = _table_root.get_child(0)
		oldest_row.free()

	# Автопрокрутка к последней добавленной строке.
	register_table.scroll_to_item.call_deferred(row)
