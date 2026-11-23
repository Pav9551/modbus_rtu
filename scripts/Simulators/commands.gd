extends Node

# Если type не указан, команда считается командой "coil".
#
# Типы команд:
# "coil" — запись в Modbus.
# "set"  — изменение переменной GeneratorState.
# "call" — вызов метода GeneratorState.
#
# delay_after — задержка после выполнения команды.
# Для Modbus задержка начинается после подтверждения записи.
# После последней команды задержка не используется.

@export var commands: Array[Dictionary] = [
	# ---------------------------------------------------------
	# Начальное состояние Modbus.
	# ---------------------------------------------------------

	{"unit": 1, "address": 5, "value": false, "delay_after": 0.0},
	{"unit": 1, "address": 6, "value": false, "delay_after": 0.0},
	{"unit": 1, "address": 7, "value": false, "delay_after": 0.0},
	{"unit": 1, "address": 8, "value": true, "delay_after": 0.0},
	{"unit": 1, "address": 9, "value": false, "delay_after": 0.0},

	# ---------------------------------------------------------
	# Пример изменения переменной модели.
	# Это изменение GeneratorState, а не команда оборудованию.
	# ---------------------------------------------------------

	{
		"type": "set",
		"property": "excitation_contactor_closed",
		"value": false,
		"delay_after": 0.0
	},

	# ---------------------------------------------------------
	# Основная последовательность Modbus.
	# ---------------------------------------------------------

	{"unit": 1, "address": 5, "value": true, "delay_after": 1.0},
	{"unit": 1, "address": 5, "value": false, "delay_after": 1.0},
	{"unit": 1, "address": 9, "value": true, "delay_after": 1.0},
	{"unit": 1, "address": 8, "value": false, "delay_after": 1.0},
	#{"unit": 1, "address": 7, "value": true, "delay_after": 1.0},
	#{"unit": 1, "address": 6, "value": true, "delay_after": 1.0},
	# Открыть затвор.
	# За 20 секунд вал успеет разогнаться до 150 об/мин
	# при acceleration_rate = 10 и немного поработать.
	{
		"type": "call",
		"method": "open_gate",
		"args": [],
		"delay_after": 50.0
	},

	# Закрыть затвор и дать время на торможение.
	{
		"type": "call",
		"method": "close_gate",
		"args": [],
		"delay_after": 10.0
	},

	# Завершить симуляцию.
	{
		"type": "call",
		"method": "stop_simulation",
		"args": [],
		"delay_after": 0.0
	},
	# ---------------------------------------------------------
	# Дополнительные примеры — раскомментируй при необходимости.
	# Числовые значения здесь только примеры.
	# ---------------------------------------------------------

	# {
	# 	"type": "set",
	# 	"property": "excitation_current",
	# 	"value": 2.0,
	# 	"delay_after": 1.0
	# },

	# {
	# 	"type": "set",
	# 	"property": "stator_voltage",
	# 	"value": 220.0,
	# 	"delay_after": 1.0
	# },

	# {
	# 	"type": "set",
	# 	"property": "shaft_speed",
	# 	"value": 1500.0,
	# 	"delay_after": 1.0
	# },

	# Уже true при выполнении последовательности,
	# поэтому повторный start_simulation обычно не нужен.
	# {
	# 	"type": "call",
	# 	"method": "start_simulation",
	# 	"args": [],
	# 	"delay_after": 0.0
	# },

	# Остановить симуляцию и прекратить дальнейшие шаги.
	# {
	# 	"type": "call",
	# 	"method": "stop_simulation",
	# 	"args": [],
	# 	"delay_after": 0.0
	# },

	# Сбросить модель и прекратить дальнейшие шаги.
	# {
	# 	"type": "call",
	# 	"method": "reset_model",
	# 	"args": [],
	# 	"delay_after": 0.0
	# },
]


var _was_running: bool = false
var _sequence_active: bool = false
var _command_index: int = 0
var _pending_request: int = -1

# Защита от продолжения старого запуска после задержки.
var _sequence_id: int = 0


func _ready() -> void:
	Modbus.coil_written.connect(_on_coil_written)
	Modbus.request_failed.connect(_on_request_failed)
	Serial.connection_changed.connect(_on_connection_changed)


func _process(_delta: float) -> void:
	var running: bool = GeneratorState.simulation_running

	if running and not _was_running:
		_start_sequence()

	elif not running and _was_running:
		_stop_sequence()

	_was_running = running


func _start_sequence() -> void:
	if _sequence_active or _pending_request != -1:
		push_warning(
			"Новый запуск отклонён: предыдущая последовательность "
			+ "или запрос ещё не завершены"
		)
		return

	if not Serial.connected:
		push_warning("Нельзя запустить команды: нет подключения")
		return

	_sequence_id += 1
	_command_index = 0
	_sequence_active = true

	print("Запуск последовательности команд")

	_send_next_command()


func _stop_sequence() -> void:
	_sequence_active = false
	_sequence_id += 1

	# Не сбрасываем _pending_request:
	# уже отправленная команда ещё может получить ответ.


func _send_next_command() -> void:
	if not _sequence_active:
		return

	if not GeneratorState.simulation_running or not Serial.connected:
		_stop_sequence()
		return

	if _pending_request != -1:
		return

	if _command_index >= commands.size():
		_sequence_active = false
		print("Все команды выполнены")
		return

	var command: Dictionary = commands[_command_index]
	var command_type: String = str(command.get("type", "coil"))

	match command_type:
		"coil":
			_execute_coil_command(command)

		"set":
			_execute_set_command(command)

		"call":
			_execute_call_command(command)

		_:
			_fail_command(
				"Неизвестный тип команды: %s" % command_type
			)


func _execute_coil_command(command: Dictionary) -> void:
	if (
		not command.has("unit")
		or not command.has("address")
		or not command.has("value")
	):
		_fail_command("Для coil нужны поля unit, address и value")
		return

	var unit: int = int(command["unit"])
	var address: int = int(command["address"])
	var value: bool = bool(command["value"])

	if unit < 1 or unit > 247:
		_fail_command("unit должен быть в диапазоне 1–247")
		return

	if address < 0 or address > 65535:
		_fail_command("address должен быть в диапазоне 0–65535")
		return

	_pending_request = Modbus.write_coil(unit, address, value)

	if _pending_request == -1:
		_fail_command("Запрос записи Modbus не принят")
		return

	print(
		"Команда ", _command_index + 1,
		": устройство ", unit,
		", coil ", address,
		", запись ", int(value)
	)


func _execute_set_command(command: Dictionary) -> void:
	if not command.has("property") or not command.has("value"):
		_fail_command("Для set нужны поля property и value")
		return

	var property_name: String = str(command["property"])
	var value: Variant = command["value"]

	# Разрешаем только переменные из твоего GeneratorState.
	match property_name:
		"simulation_running", "excitation_contactor_closed":
			if typeof(value) != TYPE_BOOL:
				_fail_command(
					"Для %s требуется bool: true или false"
					% property_name
				)
				return

		"excitation_current", "stator_voltage", "shaft_speed":
			if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
				_fail_command(
					"Для %s требуется число" % property_name
				)
				return

			value = float(value)

		_:
			_fail_command(
				"Недопустимая переменная GeneratorState: %s"
				% property_name
			)
			return

	var current_sequence_id: int = _sequence_id

	GeneratorState.set(property_name, value)

	print("GeneratorState.", property_name, " = ", value)

	if current_sequence_id != _sequence_id or not _sequence_active:
		return

	_finish_current_command()


func _execute_call_command(command: Dictionary) -> void:
	if not command.has("method"):
		_fail_command("Для call нужно поле method")
		return

	var method_name: String = str(command["method"])
	var arguments: Variant = command.get("args", [])

	if not arguments is Array:
		_fail_command("Поле args должно быть массивом")
		return

	# Все три метода твоего GeneratorState не имеют аргументов.
	if not arguments.is_empty():
		_fail_command(
			"Метод %s вызывается без аргументов" % method_name
		)
		return

	var current_sequence_id: int = _sequence_id

	match method_name:
		"start_simulation":
			GeneratorState.start_simulation()

		"stop_simulation":
			GeneratorState.stop_simulation()

		"reset_model":
			GeneratorState.reset_model()

		"open_gate":
			if not GeneratorState.open_gate():
				_fail_command("Открытие затвора отклонено")
				return

		"close_gate":
			GeneratorState.close_gate()

		"enable_excitation":
			if not GeneratorState.enable_excitation():
				_fail_command("Включение возбуждения отклонено")
				return

		"disable_excitation":
			GeneratorState.disable_excitation()

		"connect_to_grid":
			if not GeneratorState.connect_to_grid():
				_fail_command("Подключение к сети отклонено")
				return

		"disconnect_from_grid":
			GeneratorState.disconnect_from_grid()

		_:
			_fail_command(
				"Недопустимый метод GeneratorState: %s"
				% method_name
			)
			return

	print("Вызван GeneratorState.", method_name, "()")

	if current_sequence_id != _sequence_id or not _sequence_active:
		return

	_finish_current_command()


func _on_coil_written(
	request_id: int,
	unit: int,
	address: int,
	value: bool
) -> void:
	if _pending_request == -1 or request_id != _pending_request:
		return

	_pending_request = -1

	print(
		"Подтверждено: устройство ", unit,
		", coil ", address,
		", значение ", int(value)
	)

	if not _sequence_active:
		return

	_finish_current_command()


func _finish_current_command() -> void:
	if not _sequence_active:
		return

	if not GeneratorState.simulation_running or not Serial.connected:
		_stop_sequence()
		return

	var command: Dictionary = commands[_command_index]
	var delay_seconds: float = maxf(
		float(command.get("delay_after", 0.0)),
		0.0
	)

	var current_sequence_id: int = _sequence_id

	_command_index += 1

	if _command_index >= commands.size():
		_sequence_active = false
		print("Все команды выполнены")
		return

	if delay_seconds > 0.0:
		await get_tree().create_timer(delay_seconds).timeout

	# Старый запуск не должен продолжаться после нового.
	if current_sequence_id != _sequence_id:
		return

	if not _sequence_active:
		return

	if not GeneratorState.simulation_running or not Serial.connected:
		_stop_sequence()
		return

	# Передаём идентификатор, чтобы проверить его
	# также при фактическом выполнении отложенного вызова.
	_continue_sequence.call_deferred(current_sequence_id)


func _continue_sequence(expected_sequence_id: int) -> void:
	if expected_sequence_id != _sequence_id:
		return

	_send_next_command()


func _on_request_failed(request_id: int, reason: String) -> void:
	if _pending_request == -1 or request_id != _pending_request:
		return

	_pending_request = -1
	_fail_command(reason)


func _on_connection_changed(
	is_connected: bool,
	_port: String
) -> void:
	if not is_connected:
		_stop_sequence()
		_pending_request = -1


func _fail_command(reason: String) -> void:
	push_warning(
		"Ошибка команды %d: %s"
		% [_command_index + 1, reason]
	)

	_stop_sequence()
