extends Node

signal state_changed(new_state: int)
signal values_updated
signal profile_finished
signal grid_connection_changed(connected: bool)
signal operation_rejected(reason: String)


enum State {
	STOPPED,
	READY,
	ACCELERATING,
	INITIAL_VOLTAGE,
	EXCITATION,
	READY_FOR_GRID,
	IN_GRID,
	STOPPING
}


# ---------------------------------------------------------
# Настройки воспроизведения.
# ---------------------------------------------------------

@export_group("Профиль")

# 1.0 — одна секунда модели за одну реальную секунду.
@export_range(0.1, 10.0, 0.1)
var playback_speed: float = 1.0

# Автоматически открыть затвор при запуске симуляции.
@export var automatic_sequence: bool = true


# ---------------------------------------------------------
# Управление возбуждением через Modbus.
# ---------------------------------------------------------

@export_group("Управление возбуждением")

@export_range(1, 247, 1)
var excitation_unit: int = 1

@export_range(0, 65535, 1)
var excitation_coil_7_address: int = 7

@export_range(0, 65535, 1)
var excitation_coil_6_address: int = 6

# За сколько секунд времени профиля до начала возбуждения
# отправлять команды включения.
#
# При значении 2.0:
# команды отправляются примерно на 32-й секунде,
# возбуждение начинается на 34-й секунде.
@export_range(0.1, 10.0, 0.1)
var excitation_command_lead_time: float = 2.0


# ---------------------------------------------------------
# Обратная связь TOP / BOT.
# ---------------------------------------------------------

@export_group("Обратная связь TOP / BOT")

# Адреса в RegisterData.input_registers.
# Это обратная связь, а не адреса управляющих coil.
@export var top_register_address: int = 0
@export var bot_register_address: int = 1


# ---------------------------------------------------------
# Настройки остановки.
# ---------------------------------------------------------

@export_group("Остановка")

# Скорость снижения оборотов, об/мин за реальную секунду.
@export var deceleration_rate: float = 100.0

# Скорость снижения тока возбуждения за реальную секунду.
@export var excitation_fall_rate: float = 2.0


@export_group("Напряжение при остановке")

# Постоянная времени обычного экспоненциального спада.
# Напряжение начинает снижаться сразу после начала остановки.
# Чем больше значение, тем медленнее снижение.
@export_range(1.0, 600.0, 1.0)
var voltage_decay_time: float = 120.0

# Длительность снижения напряжения до нуля,
# если вал остановлен и TOP/BOT одновременно включены.
# Задаётся в реальных секундах.
@export_range(0.1, 60.0, 0.1)
var fast_voltage_fall_duration: float = 10.0

# Порог обнуления при обычном экспоненциальном спаде.
# В режиме снижения за 10 секунд этот порог не используется.
@export_range(0.01, 5.0, 0.01)
var voltage_zero_threshold: float = 0.5


# ---------------------------------------------------------
# Данные модели.
# ---------------------------------------------------------

var simulation_running: bool = false

var excitation_current: float = 0.0
var stator_voltage: float = 0.0
var shaft_speed: float = 0.0

var gate_open: bool = false
var excitation_contactor_closed: bool = false

# true только тогда, когда соответствующий регистр равен 1.
var top_enabled: bool = false
var bot_enabled: bool = false

var top_state_known: bool = false
var bot_state_known: bool = false

var grid_connected: bool = false
var synchronization_permitted: bool = false
var protections_permitted: bool = false

var current_state: State = State.STOPPED

var profile_time: float = 0.0
var profile_completed: bool = false

const PROFILE_DURATION: float = 60.0
const EXCITATION_START_TIME: float = 34.0

var _stopping: bool = false

# Запросы включения приняты модулем Modbus.
# Это не подтверждение фактического включения устройства.
var _excitation_commands_sent: bool = false

# Состояние режима снижения напряжения за заданное время.
var _fast_voltage_fall_active: bool = false
var _fast_voltage_fall_elapsed: float = 0.0
var _fast_voltage_fall_start: float = 0.0


# ---------------------------------------------------------
# Узловые точки профиля.
# ---------------------------------------------------------

var _speed_points: Array[Vector2] = [
	Vector2(0.0, 0.0),
	Vector2(60.0, 1400.0),
]

var _current_points: Array[Vector2] = [
	Vector2(0.0, 0.0),
	Vector2(14.0, 2.0),
	Vector2(15.0, 3.0),
	Vector2(16.0, 2.0),
	Vector2(34.0, 2.0),
	Vector2(35.0, 8.0),
	Vector2(36.0, 12.0),
	Vector2(37.0, 8.0),
	Vector2(38.0, 7.0),
	Vector2(60.0, 7.0),
]

var _voltage_points: Array[Vector2] = [
	Vector2(0.0, 0.0),
	Vector2(34.0, 150.0),
	Vector2(35.0, 800.0),
	Vector2(36.0, 950.0),
	Vector2(37.0, 800.0),
	Vector2(38.0, 780.0),
	Vector2(60.0, 780.0),
]


func _ready() -> void:
	_update_transistor_feedback()
	print("Состояние станции: ", get_state_text())


func _process(delta: float) -> void:
	_update_transistor_feedback()

	if _stopping:
		_update_stopping(delta)

	elif simulation_running and gate_open:
		var next_profile_time: float = profile_time

		if not profile_completed:
			next_profile_time = minf(
				profile_time + delta * playback_speed,
				PROFILE_DURATION
			)

		# Заранее отправляем команды включения возбуждения.
		var command_time: float = maxf(
			EXCITATION_START_TIME - excitation_command_lead_time,
			0.0
		)

		if (
			not _excitation_commands_sent
			and next_profile_time >= command_time
		):
			if not _send_excitation_commands():
				values_updated.emit()
				return

		# К началу возбуждения TOP и BOT должны одновременно
		# быть равны 1. Проверка продолжается и после
		# завершения профиля, включая работу в сети.
		if (
			next_profile_time >= EXCITATION_START_TIME
			and not _excitation_is_permitted()
		):
			_stop_due_to_excitation_feedback()
			values_updated.emit()
			return

		if not profile_completed:
			profile_time = next_profile_time
			_apply_profile()

			if profile_time >= EXCITATION_START_TIME:
				excitation_contactor_closed = true

			if profile_time >= PROFILE_DURATION:
				profile_completed = true
				print("Воспроизведение профиля завершено")
				profile_finished.emit()

		# Проверяем внешние разрешения подключения.
		if grid_connected and not can_connect_to_grid():
			disconnect_from_grid()

	_update_state()
	values_updated.emit()


# ---------------------------------------------------------
# Команды включения возбуждения.
# ---------------------------------------------------------

func _send_excitation_commands() -> bool:
	if _excitation_commands_sent:
		return true

	if not Serial.connected:
		stop_simulation()
		return _reject(
			"Нельзя включить возбуждение: нет подключения"
		)

	var coil_7_request_id: int = Modbus.write_coil(
		excitation_unit,
		excitation_coil_7_address,
		true
	)

	if coil_7_request_id == -1:
		stop_simulation()
		return _reject(
			"Запрос включения coil %d не принят"
			% excitation_coil_7_address
		)

	var coil_6_request_id: int = Modbus.write_coil(
		excitation_unit,
		excitation_coil_6_address,
		true
	)

	if coil_6_request_id == -1:
		stop_simulation()
		return _reject(
			(
				"Запрос включения coil %d не принят. "
				+ "Запрос для coil %d уже был принят"
			) % [
				excitation_coil_6_address,
				excitation_coil_7_address
			]
		)

	_excitation_commands_sent = true

	print(
		(
			"t=%.2f с | Запросы включения возбуждения приняты: "
			+ "coil %d = true, coil %d = true"
		) % [
			profile_time,
			excitation_coil_7_address,
			excitation_coil_6_address
		]
	)

	return true


# ---------------------------------------------------------
# Команды отключения возбуждения.
# ---------------------------------------------------------

func _send_excitation_off_commands() -> void:
	if not Serial.connected:
		push_warning(
			"Нет подключения: команды отключения возбуждения "
			+ "не отправлены. Выполняется только остановка модели"
		)
		return

	# При стандартных настройках:
	# Modbus.write_coil(1, 7, false)
	# Modbus.write_coil(1, 6, false)

	var coil_7_request_id: int = Modbus.write_coil(
		excitation_unit,
		excitation_coil_7_address,
		false
	)

	var coil_6_request_id: int = Modbus.write_coil(
		excitation_unit,
		excitation_coil_6_address,
		false
	)

	if coil_7_request_id == -1:
		push_warning(
			"Запрос отключения coil %d не принят"
			% excitation_coil_7_address
		)

	if coil_6_request_id == -1:
		push_warning(
			"Запрос отключения coil %d не принят"
			% excitation_coil_6_address
		)

	if coil_7_request_id != -1 and coil_6_request_id != -1:
		print(
			(
				"Запросы отключения возбуждения приняты: "
				+ "coil %d = false, coil %d = false"
			) % [
				excitation_coil_7_address,
				excitation_coil_6_address
			]
		)


# ---------------------------------------------------------
# Обратная связь TOP / BOT.
# ---------------------------------------------------------

func _update_transistor_feedback() -> void:
	top_state_known = RegisterData.input_registers.has(
		top_register_address
	)

	bot_state_known = RegisterData.input_registers.has(
		bot_register_address
	)

	top_enabled = (
		RegisterData.input_registers.get(
			top_register_address,
			0
		) == 1
	)

	bot_enabled = (
		RegisterData.input_registers.get(
			bot_register_address,
			0
		) == 1
	)


func _excitation_is_permitted() -> bool:
	# Возбуждение разрешено только при одновременно
	# включённых TOP и BOT и наличии обоих регистров.
	return (
		top_state_known
		and bot_state_known
		and top_enabled
		and bot_enabled
	)


func get_top_state_text() -> String:
	if not top_state_known:
		return "нет данных"

	return "true" if top_enabled else "false"


func get_bot_state_text() -> String:
	if not bot_state_known:
		return "нет данных"

	return "true" if bot_enabled else "false"


func _stop_due_to_excitation_feedback() -> void:
	push_warning(
		(
			"Останов: регистры TOP и BOT должны быть равны 1. "
			+ "Регистр %d = %s; регистр %d = %s"
		) % [
			top_register_address,
			str(
				RegisterData.input_registers.get(
					top_register_address,
					"нет данных"
				)
			),
			bot_register_address,
			str(
				RegisterData.input_registers.get(
					bot_register_address,
					"нет данных"
				)
			)
		]
	)

	stop_simulation()


# ---------------------------------------------------------
# Запуск, остановка и сброс.
# ---------------------------------------------------------

func start_simulation() -> void:
	if simulation_running:
		return

	if _stopping:
		_reject(
			"Дождись окончания остановки или вызови reset_model()"
		)
		return

	_update_transistor_feedback()
	_reset_fast_voltage_fall()

	profile_time = 0.0
	profile_completed = false
	_excitation_commands_sent = false

	_apply_profile()

	simulation_running = true
	_set_state(State.READY)

	if automatic_sequence:
		open_gate()


func stop_simulation() -> void:
	# Повторный вызов не перезапускает остановку
	# и не отправляет команды заново в каждом кадре.
	if _stopping:
		return

	_reset_fast_voltage_fall()

	# Отправляем команды до начала остановки модели.
	_send_excitation_off_commands()

	simulation_running = false
	gate_open = false
	_stopping = true

	disconnect_from_grid()
	_disable_excitation_flags()

	_set_state(State.STOPPING)


func reset_model() -> void:
	_reset_fast_voltage_fall()

	simulation_running = false
	gate_open = false
	_stopping = false

	disconnect_from_grid()
	_disable_excitation_flags()

	synchronization_permitted = false
	protections_permitted = false

	profile_time = 0.0
	profile_completed = false
	_excitation_commands_sent = false

	shaft_speed = 0.0
	excitation_current = 0.0
	stator_voltage = 0.0

	# Сброс модели не отправляет команды оборудованию
	# и не изменяет регистры обратной связи.
	_update_transistor_feedback()

	_set_state(State.STOPPED)
	values_updated.emit()


# ---------------------------------------------------------
# Управление затвором.
# ---------------------------------------------------------

func open_gate() -> bool:
	if not simulation_running:
		return _reject("Сначала запусти симуляцию")

	gate_open = true
	return true


func close_gate() -> void:
	stop_simulation()


# ---------------------------------------------------------
# Управление возбуждением.
# ---------------------------------------------------------

func enable_excitation() -> bool:
	_update_transistor_feedback()

	if not simulation_running or not gate_open:
		return _reject(
			"Симуляция не запущена или затвор закрыт"
		)

	# Этот метод разрешает возбуждение только при уже
	# полученной обратной связи TOP/BOT.
	# Автоматическая отправка команд выполняется в _process().
	if not _excitation_is_permitted():
		_stop_due_to_excitation_feedback()

		return _reject(
			"Возбуждение запрещено: "
			+ "TOP и BOT должны одновременно быть равны 1"
		)

	excitation_contactor_closed = true
	return true


func disable_excitation() -> void:
	stop_simulation()


func _disable_excitation_flags() -> void:
	excitation_contactor_closed = false

	# TOP и BOT не изменяем.
	# Их значения поступают только из RegisterData.


# ---------------------------------------------------------
# Подключение к сети.
# ---------------------------------------------------------

func is_ready_for_grid() -> bool:
	_update_transistor_feedback()

	return (
		simulation_running
		and gate_open
		and profile_completed
		and _excitation_is_permitted()
	)


func can_connect_to_grid() -> bool:
	return (
		is_ready_for_grid()
		and synchronization_permitted
		and protections_permitted
	)


func connect_to_grid() -> bool:
	if not can_connect_to_grid():
		if (
			simulation_running
			and profile_time >= EXCITATION_START_TIME
			and not _excitation_is_permitted()
		):
			_stop_due_to_excitation_feedback()

		return _reject(
			"Нет готовности профиля, разрешения TOP/BOT, "
			+ "синхронизации или защит"
		)

	if grid_connected:
		return true

	grid_connected = true
	grid_connection_changed.emit(true)

	_set_state(State.IN_GRID)
	return true


func disconnect_from_grid() -> void:
	if not grid_connected:
		return

	grid_connected = false
	grid_connection_changed.emit(false)


# ---------------------------------------------------------
# Воспроизведение профиля.
# ---------------------------------------------------------

func _apply_profile() -> void:
	shaft_speed = _sample_profile(
		_speed_points,
		profile_time
	)

	excitation_current = _sample_profile(
		_current_points,
		profile_time
	)

	stator_voltage = _sample_profile(
		_voltage_points,
		profile_time
	)


func _sample_profile(
	points: Array[Vector2],
	time: float
) -> float:
	if time <= points[0].x:
		return points[0].y

	for index in range(1, points.size()):
		var left: Vector2 = points[index - 1]
		var right: Vector2 = points[index]

		if time <= right.x:
			var weight: float = (
				(time - left.x) / (right.x - left.x)
			)

			return lerpf(left.y, right.y, weight)

	return points[points.size() - 1].y


# ---------------------------------------------------------
# Снижение напряжения за заданное время.
# ---------------------------------------------------------

func _reset_fast_voltage_fall() -> void:
	_fast_voltage_fall_active = false
	_fast_voltage_fall_elapsed = 0.0
	_fast_voltage_fall_start = 0.0


# ---------------------------------------------------------
# Плавная остановка.
# ---------------------------------------------------------

func _update_stopping(delta: float) -> void:
	# Плавное торможение вала.
	shaft_speed = move_toward(
		shaft_speed,
		0.0,
		maxf(deceleration_rate, 0.0) * delta
	)

	# Плавное уменьшение тока возбуждения.
	excitation_current = move_toward(
		excitation_current,
		0.0,
		maxf(excitation_fall_rate, 0.0) * delta
	)

	# Возбуждение считается включённым только тогда,
	# когда TOP и BOT одновременно равны 1.
	var excitation_output_enabled: bool = (
		_excitation_is_permitted()
	)

	var use_timed_fall: bool = (
		shaft_speed == 0.0
		and excitation_output_enabled
	)

	if use_timed_fall:
		# Запоминаем начальное напряжение только
		# при входе в режим снижения за заданное время.
		if not _fast_voltage_fall_active:
			_fast_voltage_fall_active = true
			_fast_voltage_fall_elapsed = 0.0
			_fast_voltage_fall_start = maxf(
				stator_voltage,
				0.0
			)

			print(
				(
					"Вал остановлен, TOP и BOT включены. "
					+ "Снижение напряжения с %.2f В "
					+ "до нуля за %.1f с"
				) % [
					_fast_voltage_fall_start,
					fast_voltage_fall_duration
				]
			)

		var duration: float = maxf(
			fast_voltage_fall_duration,
			0.001
		)

		_fast_voltage_fall_elapsed = minf(
			_fast_voltage_fall_elapsed + delta,
			duration
		)

		var progress: float = clampf(
			_fast_voltage_fall_elapsed / duration,
			0.0,
			1.0
		)

		# Линейное снижение от зафиксированного
		# напряжения до нуля за заданное время.
		stator_voltage = lerpf(
			_fast_voltage_fall_start,
			0.0,
			progress
		)

		if _fast_voltage_fall_elapsed >= duration:
			stator_voltage = 0.0

	else:
		# Если условие исчезло, возвращаем обычный
		# экспоненциальный спад от текущего напряжения.
		_reset_fast_voltage_fall()

		var decay_time: float = maxf(
			voltage_decay_time,
			0.001
		)

		stator_voltage *= exp(-delta / decay_time)

		if stator_voltage <= maxf(voltage_zero_threshold, 0.001):
			stator_voltage = 0.0

	# Полная остановка — после обнуления всех значений.
	if (
		shaft_speed == 0.0
		and excitation_current == 0.0
		and stator_voltage == 0.0
	):
		_stopping = false
		_reset_fast_voltage_fall()
		_set_state(State.STOPPED)
		print("Остановка завершена")


# ---------------------------------------------------------
# Обновление состояния.
# ---------------------------------------------------------

func _update_state() -> void:
	if _stopping:
		_set_state(State.STOPPING)

	elif not simulation_running:
		_set_state(State.STOPPED)

	elif grid_connected:
		_set_state(State.IN_GRID)

	elif not gate_open:
		_set_state(State.READY)

	elif profile_completed:
		_set_state(State.READY_FOR_GRID)

	elif profile_time >= EXCITATION_START_TIME:
		_set_state(State.EXCITATION)

	elif profile_time > 0.0:
		_set_state(State.INITIAL_VOLTAGE)

	else:
		_set_state(State.ACCELERATING)


func _set_state(new_state: State) -> void:
	if current_state == new_state:
		return

	current_state = new_state

	print(
		"t=%.2f с | %s"
		% [profile_time, get_state_text()]
	)

	state_changed.emit(int(current_state))


func get_state_text() -> String:
	match current_state:
		State.STOPPED:
			return "Остановлена"

		State.READY:
			return "Готова к запуску"

		State.ACCELERATING:
			return "Начало разгона"

		State.INITIAL_VOLTAGE:
			return "Разгон и начальный рост напряжения"

		State.EXCITATION:
			return "Рост и установление тока и напряжения"

		State.READY_FOR_GRID:
			return "Профиль завершён, ожидание подключения"

		State.IN_GRID:
			return "Работа в сети"

		State.STOPPING:
			return "Остановка"

	return "Неизвестное состояние"


func _reject(reason: String) -> bool:
	push_warning(reason)
	operation_rejected.emit(reason)
	return false
