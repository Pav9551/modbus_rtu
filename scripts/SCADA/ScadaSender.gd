extends Node

@export_group("Подключение к SCADA")
@export var base_url: String = "https://127.0.0.1:8080"
@export var username: String = "admin"
@export var password: String = "admin"

@export_group("Автоматическая отправка")
@export var sending_enabled: bool = true
@export var send_interval: float = 0.5

@export_group("Теги SCADA: сигналы контроллера")
@export var controller_flags_tag_name: String = "ControllerFlags"

@export_group("Теги SCADA: состояние модели")
@export var simulation_running_tag_name: String = "SimulationRunning"
@export var excitation_current_tag_name: String = "ExcitationCurrent"
@export var stator_voltage_tag_name: String = "StatorVoltage"
@export var shaft_speed_tag_name: String = "ShaftSpeed"
@export var excitation_contactor_closed_tag_name: String = "ExcitationContactorClosed"

@export_group("Отладка")
@export var print_all_passports: bool = false
@export var print_successful_requests: bool = false

var token: String = ""
var http: HTTPRequest
var send_timer: Timer
var busy: bool = false

var _cached_passports: Array = []


func _ready() -> void:
	http = HTTPRequest.new()
	http.timeout = 15.0
	add_child(http)

	send_timer = Timer.new()
	send_timer.one_shot = true
	add_child(send_timer)

	send_timer.timeout.connect(_on_send_timer_timeout)

	print("ScadaSender запущен.")
	_schedule_next_cycle()


func _schedule_next_cycle(delay: float = -1.0) -> void:
	if not is_inside_tree():
		return

	var next_delay: float = maxf(send_interval, 0.1)

	if delay >= 0.0:
		next_delay = delay

	send_timer.start(maxf(next_delay, 0.01))


func _on_send_timer_timeout() -> void:
	var started_at: int = Time.get_ticks_msec()
	var cycle_executed: bool = false

	if sending_enabled and not busy:
		cycle_executed = true
		busy = true
		await _send_cycle()
		busy = false

	var elapsed: float = (
		float(Time.get_ticks_msec() - started_at) / 1000.0
	)

	if cycle_executed and print_successful_requests:
		print(
			"ScadaSender: длительность цикла — ",
			snappedf(elapsed, 0.001),
			" с"
		)

	# Интервал отсчитывается от начала предыдущего цикла.
	var remaining: float = maxf(
		maxf(send_interval, 0.1) - elapsed,
		0.01
	)

	_schedule_next_cycle(remaining)


# Вызови после изменения тегов, их типов или прав записи в SCADA.
func clear_passports_cache() -> void:
	_cached_passports.clear()
	print("ScadaSender: кеш паспортов очищен.")


func _request(
	path: String,
	method: HTTPClient.Method,
	body: String = "",
	with_auth: bool = true
) -> Dictionary:
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json"
	])

	if with_auth:
		headers.append("Authorization: Bearer " + token)

	var url: String = base_url.trim_suffix("/") + path

	var error: Error = http.request(
		url,
		headers,
		method,
		body
	)

	if error != OK:
		print(
			"ScadaSender: ошибка запуска запроса ",
			path,
			": ",
			error_string(error)
		)

		return {
			"connected": false,
			"status": 0,
			"text": ""
		}

	var response: Array = await http.request_completed

	var result: int = response[0]
	var status: int = response[1]
	var response_text: String = response[3].get_string_from_utf8()
	var connected: bool = result == HTTPRequest.RESULT_SUCCESS

	if print_successful_requests or not connected or status >= 300:
		print(
			"ScadaSender: ", path,
			", результат=", result,
			", HTTP=", status
		)

	if with_auth and status == 401:
		token = ""
		_cached_passports.clear()

	return {
		"connected": connected,
		"status": status,
		"text": response_text
	}


func _login() -> bool:
	token = ""

	var response: Dictionary = await _request(
		"/api/login",
		HTTPClient.METHOD_POST,
		JSON.stringify({
			"username": username,
			"password": password
		}),
		false
	)

	if not response["connected"]:
		print("ScadaSender: нет связи при авторизации.")
		return false

	var status: int = int(response["status"])

	if status < 200 or status >= 300:
		print("ScadaSender: авторизация отклонена, HTTP ", status)
		return false

	var json := JSON.new()

	if json.parse(str(response["text"])) != OK:
		print("ScadaSender: ответ авторизации не является JSON.")
		return false

	if not (json.data is Dictionary):
		print("ScadaSender: неверная структура ответа авторизации.")
		return false

	var data: Dictionary = json.data
	var received_token: Variant = data.get("token", "")

	if not (received_token is String):
		print("ScadaSender: поле token не является строкой.")
		return false

	token = str(received_token)

	if token.is_empty():
		print("ScadaSender: сервер не вернул токен.")
		return false

	print("ScadaSender: авторизация выполнена.")
	return true


func _ensure_passports() -> bool:
	if not _cached_passports.is_empty():
		return true

	var response: Dictionary = await _request(
		"/api/v2/passports",
		HTTPClient.METHOD_GET
	)

	if not response["connected"]:
		print("ScadaSender: не удалось получить паспорта.")
		return false

	var status: int = int(response["status"])

	if status < 200 or status >= 300:
		print(
			"ScadaSender: ошибка получения паспортов. HTTP=",
			status,
			", ответ=",
			response["text"]
		)
		return false

	var json := JSON.new()

	if json.parse(str(response["text"])) != OK:
		print("ScadaSender: ответ паспортов не является JSON.")
		return false

	if not (json.data is Array):
		print("ScadaSender: ожидался массив паспортов.")
		return false

	var passports: Array = json.data

	if passports.is_empty():
		print("ScadaSender: сервер вернул пустой список паспортов.")
		return false

	_cached_passports = passports

	if print_all_passports:
		print(
			"GET ",
			base_url.trim_suffix("/"),
			"/api/v2/passports"
		)
		print(JSON.stringify(_cached_passports, "\t"))

	return true


# Упаковка сигналов контроллера:
# бит 0 — C5
# бит 1 — C16
# бит 2 — C7
# бит 3 — C8
# бит 4 — C26
# бит 5 — InputReg0
# бит 6 — InputReg1
# бит 7 — InputReg2
func _get_controller_flags() -> int:
	var flags: int = 0

	if RegisterData.c5_value:
		flags |= 1 << 0

	if RegisterData.c16_value:
		flags |= 1 << 1

	if RegisterData.c7_value:
		flags |= 1 << 2

	if RegisterData.c8_value:
		flags |= 1 << 3

	if RegisterData.c26_value:
		flags |= 1 << 4

	if int(RegisterData.input_registers.get(0, 0)) == 1:
		flags |= 1 << 5

	if int(RegisterData.input_registers.get(1, 0)) == 1:
		flags |= 1 << 6

	if int(RegisterData.input_registers.get(2, 0)) == 1:
		flags |= 1 << 7

	return flags

# Создаёт снимок шести источников.
func _get_sources() -> Array[Dictionary]:
	var missing := PackedStringArray()

	if not RegisterData.c5_received:
		missing.append("C5")

	if not RegisterData.c8_received:
		missing.append("C8")

	if not RegisterData.c16_received:
		missing.append("C16")

	if not RegisterData.c7_received:
		missing.append("C7")

	if not RegisterData.c26_received:
		missing.append("C26")

	var registers_valid: bool = true

	for address in range(3):
		if not RegisterData.input_registers.has(address):
			missing.append("InputReg%d" % address)
			continue

		var register_value: int = int(
			RegisterData.input_registers[address]
		)

		if register_value != 0 and register_value != 1:
			registers_valid = false
			print(
				"ScadaSender: InputReg",
				address,
				" должен содержать 0 или 1, получено ",
				register_value
			)

	var controller_ready: bool = (
		missing.is_empty() and registers_valid
	)

	var sources: Array[Dictionary] = [
		{
			"source": "ControllerFlags",
			"tag": controller_flags_tag_name,
			"kind": "register",
			"received": controller_ready,
			"missing": ", ".join(missing),
			"value": _get_controller_flags()
		},
		{
			"source": "GeneratorState.simulation_running",
			"tag": simulation_running_tag_name,
			"kind": "coil",
			"received": true,
			"value": GeneratorState.simulation_running
		},
		{
			"source": "GeneratorState.excitation_current",
			"tag": excitation_current_tag_name,
			"kind": "model_float",
			"received": true,
			"value": GeneratorState.excitation_current
		},
		{
			"source": "GeneratorState.stator_voltage",
			"tag": stator_voltage_tag_name,
			"kind": "model_float",
			"received": true,
			"value": GeneratorState.stator_voltage
		},
		{
			"source": "GeneratorState.shaft_speed",
			"tag": shaft_speed_tag_name,
			"kind": "model_float",
			"received": true,
			"value": GeneratorState.shaft_speed
		},
		{
			"source": "GeneratorState.excitation_contactor_closed",
			"tag": excitation_contactor_closed_tag_name,
			"kind": "coil",
			"received": true,
			"value": GeneratorState.excitation_contactor_closed
		}
	]

	return sources


func _all_sources_received(sources: Array[Dictionary]) -> bool:
	var ready: bool = true

	for source in sources:
		if source["received"]:
			continue

		ready = false

		var missing: String = str(source.get("missing", ""))

		if not missing.is_empty():
			print("ScadaSender: ожидание данных: ", missing)
		else:
			print(
				"ScadaSender: источник не готов: ",
				source["source"]
			)

	return ready


func _normalize_tag_id(raw_id: Variant) -> String:
	if raw_id is int:
		return str(raw_id)

	if raw_id is float:
		var numeric_id: float = float(raw_id)

		if not is_finite(numeric_id):
			return ""

		if numeric_id != floor(numeric_id):
			return ""

		return str(int(numeric_id))

	if raw_id is String:
		var string_id: String = str(raw_id)

		if string_id.is_valid_int():
			return str(string_id.to_int())

	return ""


func _is_numeric_tag(tag_type: String) -> bool:
	return tag_type in [
		"int8", "int16", "int32", "int64",
		"uint8", "uint16", "uint32", "uint64",
		"float", "double"
	]


# Проверяет все назначения до первой записи.
func _prepare_jobs(
	passports: Array,
	sources: Array[Dictionary]
) -> Array[Dictionary]:
	var jobs: Array[Dictionary] = []
	var used_ids: Dictionary = {}

	for source in sources:
		var source_name: String = str(source["source"])
		var target_name: String = str(source["tag"])

		if target_name.strip_edges().is_empty():
			print("ScadaSender: не задан тег для ", source_name)
			return []

		var matches: Array[Dictionary] = []

		for item in passports:
			if not (item is Dictionary):
				continue

			var passport: Dictionary = item

			if str(passport.get("name", "")) == target_name:
				matches.append(passport)

		if matches.size() != 1:
			print(
				"ScadaSender: для имени '",
				target_name,
				"' найдено паспортов: ",
				matches.size(),
				". Требуется один."
			)
			return []

		var found: Dictionary = matches[0]

		if found.get("writable", false) != true:
			print(
				"ScadaSender: запись в тег '",
				target_name,
				"' запрещена."
			)
			return []

		var tag_id: String = _normalize_tag_id(found.get("ID"))

		if tag_id.is_empty():
			print("ScadaSender: некорректный ID тега ", target_name)
			return []

		if used_ids.has(tag_id):
			print(
				"ScadaSender: несколько источников направлены ",
				"в один тег, ID=",
				tag_id
			)
			return []

		used_ids[tag_id] = true

		var tag_type: String = str(found.get("type", ""))
		var source_kind: String = str(source["kind"])
		var value_to_send: Variant = null

		match source_kind:
			"coil":
				if tag_type != "boolean" and not _is_numeric_tag(tag_type):
					print(
						"ScadaSender: неподдерживаемый тип булева тега ",
						target_name,
						": ",
						tag_type
					)
					return []

				var coil_value: bool = bool(source["value"])

				# API принимает число даже для boolean-тегов.
				value_to_send = 1 if coil_value else 0

			"register":
				if tag_type != "int16":
					print(
						"ScadaSender: для ",
						target_name,
						" ожидается int16, получен ",
						tag_type
					)
					return []

				var register_value: int = int(source["value"])

				if register_value < -32768 or register_value > 32767:
					print(
						"ScadaSender: значение ",
						source_name,
						" вне диапазона Int16: ",
						register_value,
						". Цикл отменён."
					)
					return []

				value_to_send = register_value

			"model_float":
				if tag_type not in ["float", "double"]:
					print(
						"ScadaSender: для ",
						target_name,
						" ожидается float или double, получен ",
						tag_type
					)
					return []

				var model_value: float = float(source["value"])

				if not is_finite(model_value):
					print(
						"ScadaSender: некорректное значение ",
						source_name,
						": ",
						model_value,
						". Цикл отменён."
					)
					return []

				value_to_send = model_value

			_:
				print(
					"ScadaSender: неизвестный вид источника ",
					source_name,
					": ",
					source_kind
				)
				return []

		jobs.append({
			"source": source_name,
			"name": target_name,
			"id": tag_id,
			"value": value_to_send
		})

	return jobs


func _send_cycle() -> void:
	var initial_sources: Array[Dictionary] = _get_sources()

	if not _all_sources_received(initial_sources):
		return

	if token.is_empty():
		var logged_in: bool = await _login()

		if not logged_in:
			return

	if not sending_enabled:
		return

	var passports_ready: bool = await _ensure_passports()

	if not passports_ready:
		return

	# Единый снимок после подготовительных HTTP-запросов.
	var sources: Array[Dictionary] = _get_sources()

	if not _all_sources_received(sources):
		return

	var jobs: Array[Dictionary] = _prepare_jobs(
		_cached_passports,
		sources
	)

	if jobs.is_empty():
		print("ScadaSender: проверка не пройдена, запись отменена.")
		return

	var confirmed: int = 0

	for job in jobs:
		if not sending_enabled:
			print(
				"ScadaSender: отправка выключена. Подтверждено ",
				confirmed,
				"/",
				jobs.size()
			)
			return

		var success: bool = await _write_job(job)

		if not success:
			print(
				"ScadaSender: цикл остановлен. Подтверждено ",
				confirmed,
				"/",
				jobs.size(),
				". Уже выполненные записи не отменены."
			)
			return

		confirmed += 1

	if print_successful_requests:
		print(
			"ScadaSender: отправлено ",
			confirmed,
			"/",
			jobs.size()
		)


func _write_job(job: Dictionary) -> bool:
	var path: String = (
		"/api/channels/" + str(job["id"]).uri_encode()
	)

	var response: Dictionary = await _request(
		path,
		HTTPClient.METHOD_PATCH,
		JSON.stringify({
			"value": job["value"]
		})
	)

	if not response["connected"]:
		print(
			"ScadaSender: ошибка связи при записи '",
			job["name"],
			"'. Результат текущей записи неизвестен."
		)
		return false

	var status: int = int(response["status"])

	if status != 204:
		print(
			"ScadaSender: запись '",
			job["name"],
			"' не подтверждена. HTTP=",
			status,
			", ответ=",
			response["text"]
		)
		return false

	if print_successful_requests:
		print(
			"ScadaSender: ",
			job["source"],
			" → ",
			job["name"],
			" = ",
			job["value"]
		)

	return true
