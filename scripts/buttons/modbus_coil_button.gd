extends Button

@export_range(1, 247) var unit_id: int = 1
@export_range(0, 65535) var coil_address: int = 8

# Используется, пока состояние coil ещё неизвестно.
@export var first_write_value: bool = true

@export_group("Цвета состояния")
@export var color_on: Color = Color("#268a46")
@export var color_off: Color = Color("#b53838")
@export var color_unknown: Color = Color("#555b65")

var _next_value: bool = true

var _pending_request: int = -1
var _pending_read: int = -1

var _coil_value: bool = false
var _coil_state_known: bool = false

var _style_normal: StyleBoxFlat
var _style_hover: StyleBoxFlat
var _style_pressed: StyleBoxFlat
var _style_disabled: StyleBoxFlat


func _ready() -> void:
	_next_value = first_write_value

	_setup_styles()

	pressed.connect(_on_pressed)

	Serial.connection_changed.connect(_on_connection_changed)

	Modbus.coil_received.connect(_on_coil_received)
	Modbus.coil_written.connect(_on_coil_written)
	Modbus.request_failed.connect(_on_request_failed)

	if Serial.connected:
		_request_coil_state()

	_update_button()


func _setup_styles() -> void:
	_style_normal = _create_style()
	_style_hover = _create_style()
	_style_pressed = _create_style()
	_style_disabled = _create_style()

	add_theme_stylebox_override("normal", _style_normal)
	add_theme_stylebox_override("hover", _style_hover)
	add_theme_stylebox_override("pressed", _style_pressed)
	add_theme_stylebox_override("hover_pressed", _style_pressed)
	add_theme_stylebox_override("disabled", _style_disabled)

	for theme_name in [
		"font_color",
		"font_hover_color",
		"font_pressed_color",
		"font_hover_pressed_color",
		"font_disabled_color",
		"font_focus_color"
	]:
		add_theme_color_override(theme_name, Color.WHITE)


func _create_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()

	style.set_corner_radius_all(6)
	style.set_border_width_all(1)

	style.border_color = Color(0.0, 0.0, 0.0, 0.3)

	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0

	return style


func _request_coil_state() -> void:
	if not Serial.connected:
		return

	if _pending_read != -1:
		return

	_pending_read = Modbus.read_coil(unit_id, coil_address)

	if _pending_read == -1:
		push_warning(
			"Запрос чтения не принят: устройство %d, coil %d"
			% [unit_id, coil_address]
		)


func _on_pressed() -> void:
	if not Serial.connected:
		return

	if _pending_request != -1:
		return

	var request_id: int = Modbus.write_coil(
		unit_id,
		coil_address,
		_next_value
	)

	if request_id == -1:
		push_warning(
			"Запрос записи не принят: устройство %d, coil %d"
			% [unit_id, coil_address]
		)

		_update_button()
		return

	_pending_request = request_id
	_update_button()


func _on_coil_received(
	request_id: int,
	unit: int,
	address: int,
	value: bool
) -> void:
	if unit != unit_id or address != coil_address:
		return

	if request_id == _pending_read:
		_pending_read = -1

	# Обрабатываем как собственное чтение,
	# так и результаты общего опроса Modbus.
	_coil_value = value
	_coil_state_known = true

	# Во время записи _next_value хранит отправленное значение.
	if _pending_request == -1:
		_next_value = not value

	_update_button()


func _on_coil_written(
	request_id: int,
	unit: int,
	address: int,
	value: bool
) -> void:
	if request_id != _pending_request:
		return

	if unit != unit_id or address != coil_address:
		return

	_pending_request = -1

	_coil_value = value
	_coil_state_known = true
	_next_value = not value

	print(
		"Устройство ", unit,
		", coil ", address,
		": запись ", int(value),
		" подтверждена"
	)

	# Дополнительно проверяем состояние чтением.
	_request_coil_state()
	_update_button()


func _on_request_failed(
	request_id: int,
	reason: String
) -> void:
	if request_id == _pending_read:
		_pending_read = -1
		_coil_state_known = false

		push_warning(
			"Ошибка чтения: устройство %d, coil %d: %s"
			% [unit_id, coil_address, reason]
		)

		_update_button()
		return

	if request_id != _pending_request:
		return

	_pending_request = -1
	_coil_state_known = false

	push_warning(
		"Ошибка записи: устройство %d, coil %d: %s"
		% [unit_id, coil_address, reason]
	)

	# Запись могла выполниться даже при потере ответа.
	_request_coil_state()
	_update_button()


func _on_connection_changed(
	is_connected: bool,
	_port: String
) -> void:
	_coil_state_known = false
	_pending_read = -1
	_pending_request = -1

	if is_connected:
		_request_coil_state()

	_update_button()


func _update_button() -> void:
	disabled = (
		not Serial.connected
		or _pending_request != -1
	)

	_update_color()

	if not Serial.connected:
		text = "Coil %d: нет подключения" % coil_address

	elif _pending_request != -1:
		text = "Coil %d: запись %d..." % [
			coil_address,
			int(_next_value)
		]

	elif _coil_state_known:
		text = "Coil %d: %d → записать %d" % [
			coil_address,
			int(_coil_value),
			int(_next_value)
		]

	else:
		text = "Coil %d: ? → записать %d" % [
			coil_address,
			int(_next_value)
		]


func _update_color() -> void:
	var base_color: Color = color_unknown

	if Serial.connected and _coil_state_known:
		base_color = color_on if _coil_value else color_off

	_style_normal.bg_color = base_color
	_style_hover.bg_color = base_color.lightened(0.15)
	_style_pressed.bg_color = base_color.darkened(0.15)

	# При записи кнопка заблокирована,
	# но сохраняет цвет последнего известного состояния.
	_style_disabled.bg_color = base_color
