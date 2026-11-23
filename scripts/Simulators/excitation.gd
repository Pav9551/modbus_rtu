extends Node

# Настройки запуска.
@export var auto_start_simulation: bool = true
@export var auto_open_gate: bool = false

# Интервал вывода значений в консоль.
@export_range(0.1, 10.0, 0.1)
var print_interval: float = 0.5

var _timer: Timer


func _ready() -> void:
	RegisterData.input_registers[0] = 0;
	RegisterData.input_registers[1] = 0;
	_timer = Timer.new()
	_timer.wait_time = print_interval
	_timer.one_shot = false
	add_child(_timer)

	_timer.timeout.connect(_print_values)

	if auto_start_simulation:
		GeneratorState.start_simulation()

	if auto_open_gate and GeneratorState.simulation_running:
		GeneratorState.open_gate()

	_timer.start()
	print("Монитор модели запущен. Случайная генерация отключена.")


func _print_values() -> void:
	# Выводим значения даже после остановки симуляции,
	# чтобы видеть плавное торможение вала.
	print(
		"Состояние: ", GeneratorState.get_state_text(),
		" | Iв=", snappedf(GeneratorState.excitation_current, 0.01),
		" А | Uст=", snappedf(GeneratorState.stator_voltage, 0.1),
		" В | n=", snappedf(GeneratorState.shaft_speed, 0.1),
		" об/мин | затвор=", GeneratorState.gate_open,
		" | контактор=", GeneratorState.excitation_contactor_closed,
		" | TOP разрешён=", RegisterData.input_registers[0],
		" | BOT разрешён=", RegisterData.input_registers[1],
		" | сеть=", GeneratorState.grid_connected
	)
