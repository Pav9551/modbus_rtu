extends Button

@export_group("Подключение к SCADA")
@export var base_url: String = "https://127.0.0.1:8080"
@export var username: String = "admin"
@export var password: String = "admin"

@export_group("Теги SCADA: coils")
@export var c5_tag_name: String = "C5"
@export var c8_tag_name: String = "C8"
@export var c16_tag_name: String = "C16"
@export var c7_tag_name: String = "C7"
@export var c26_tag_name: String = "C26"

@export_group("Теги SCADA: входные регистры")
@export var input_reg0_tag_name: String = "InputReg0"
@export var input_reg1_tag_name: String = "InputReg1"
@export var input_reg2_tag_name: String = "InputReg2"

@export_group("Отладка")
@export var print_all_passports: bool = false

var token: String = ""
var http: HTTPRequest
var busy: bool = false


func _ready() -> void:
	http = HTTPRequest.new()
	add_child(http)
	http.timeout = 15.0

	pressed.connect(_on_pressed)

	_set_busy(true)
	text = "Авторизация..."

	var success: bool = await _login()

	if success:
		text = "Отправить все значения"
	else:
		text = "Повторить авторизацию"

	_set_busy(false)


func _set_busy(value: bool) -> void:
	busy = value
	disabled = value


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

	var url := base_url.trim_suffix("/") + path

	var error := http.request(
		url,
		headers,
		method,
		body
	)

	if error != OK:
		print(
			"Ошибка запуска запроса ",
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

	print(
		"Запрос ", path,
		": результат=", result,
		", HTTP=", status
	)

	if with_auth and status == 401:
		token = ""

	return {
		"connected": result == HTTPRequest.RESULT_SUCCESS,
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
		print("Ошибка соединения при авторизации.")
		return false

	var status: int = int(response["status"])

	if status < 200 or status >= 300:
		print("Авторизация отклонена. HTTP: ", status)
		return false

	var json := JSON.new()

	if json.parse(str(response["text"])) != OK:
		print("Ответ авторизации не является JSON.")
		return false

	if not (json.data is Dictionary):
		print("Неверная структура ответа авторизации.")
		return false

	var data: Dictionary = json.data
	var received_token: Variant = data.get("token", "")

	if not (received_token is String):
		print("Поле token не является строкой.")
		return false

	token = str(received_token)

	if token.is_empty():
		print("Сервер не вернул токен.")
		return false

	print("Авторизация выполнена.")
	return true


# Снимок всех значений для одной отправки.
func _get_sources() -> Array[Dictionary]:
	var sources: Array[Dictionary] = [
		{
			"source": "C5",
			"tag": c5_tag_name,
			"kind": "coil",
			"received": RegisterData.c5_received,
			"value": RegisterData.c5_value
		},
		{
			"source": "C8",
			"tag": c8_tag_name,
			"kind": "coil",
			"received": RegisterData.c8_received,
			"value": RegisterData.c8_value
		},
		{
			"source": "C16",
			"tag": c16_tag_name,
			"kind": "coil",
			"received": RegisterData.c16_received,
			"value": RegisterData.c16_value
		},
		{
			"source": "C7",
			"tag": c7_tag_name,
			"kind": "coil",
			"received": RegisterData.c7_received,
			"value": RegisterData.c7_value
		},
		{
			"source": "C26",
			"tag": c26_tag_name,
			"kind": "coil",
			"received": RegisterData.c26_received,
			"value": RegisterData.c26_value
		}
	]

	var register_tag_names: Array[String] = [
		input_reg0_tag_name,
		input_reg1_tag_name,
		input_reg2_tag_name
	]

	for address in range(3):
		sources.append({
			"source": "InputReg%d" % address,
			"tag": register_tag_names[address],
			"kind": "register",
			"received": RegisterData.input_registers.has(address),
			"value": RegisterData.input_registers.get(address, 0)
		})

	return sources


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


func _print_available_tags(passports: Array) -> void:
	print("========== ДОСТУПНЫЕ ТЕГИ ==========")

	for item in passports:
		if not (item is Dictionary):
			continue

		var passport: Dictionary = item

		print(
			"Имя=", JSON.stringify(passport.get("name", "")),
			", ID=", passport.get("ID", ""),
			", тип=", passport.get("type", ""),
			", запись=", passport.get("writable", false)
		)

	print("====================================")


# Подготовка всех записей до первой отправки.
func _prepare_jobs(
	passports: Array,
	sources: Array[Dictionary]
) -> Array[Dictionary]:
	var jobs: Array[Dictionary] = []
	var used_ids: Dictionary = {}
	var has_errors: bool = false

	for source in sources:
		var source_name: String = str(source["source"])
		var target_name: String = str(source["tag"])
		var source_kind: String = str(source["kind"])

		print(
			"Проверка ", source_name,
			": имя тега=", JSON.stringify(target_name),
			", данные получены=", source["received"],
			", значение=", source["value"]
		)

		if not source["received"]:
			print("ОШИБКА: нет данных источника ", source_name)
			has_errors = true

		if target_name.strip_edges().is_empty():
			print("ОШИБКА: не задано имя тега для ", source_name)
			has_errors = true
			continue

		var matches: Array[Dictionary] = []

		for item in passports:
			if not (item is Dictionary):
				continue

			var passport: Dictionary = item

			if str(passport.get("name", "")) == target_name:
				matches.append(passport)

		if matches.size() != 1:
			print(
				"ОШИБКА: для имени ",
				JSON.stringify(target_name),
				" найдено паспортов: ",
				matches.size(),
				". Требуется ровно один."
			)

			has_errors = true
			continue

		var found: Dictionary = matches[0]

		if found.get("writable", false) != true:
			print(
				"ОШИБКА: запись в тег '",
				target_name,
				"' не разрешена."
			)

			has_errors = true
			continue

		var tag_id: String = _normalize_tag_id(found.get("ID"))

		if tag_id.is_empty():
			print(
				"ОШИБКА: некорректный ID тега '",
				target_name,
				"'."
			)

			has_errors = true
			continue

		if used_ids.has(tag_id):
			print(
				"ОШИБКА: несколько источников направлены ",
				"в один тег, ID=",
				tag_id
			)

			has_errors = true
			continue

		used_ids[tag_id] = true

		var tag_type: String = str(found.get("type", ""))
		var value_to_send: Variant

		if source_kind == "coil":
			var coil_value: bool = bool(source["value"])

			if tag_type == "boolean":
				value_to_send = coil_value
			elif _is_numeric_tag(tag_type):
				value_to_send = 1 if coil_value else 0
			else:
				print(
					"ОШИБКА: неподдерживаемый тип для coil ",
					source_name,
					": ",
					tag_type
				)

				has_errors = true
				continue
		else:
			# Значение регистра передаём целиком, не как 0/1.
			if not _is_numeric_tag(tag_type):
				print(
					"ОШИБКА: для регистра ",
					source_name,
					" нужен числовой тег. Получен тип: ",
					tag_type
				)

				has_errors = true
				continue

			value_to_send = int(source["value"])

		jobs.append({
			"source": source_name,
			"name": target_name,
			"id": tag_id,
			"value": value_to_send
		})

	if has_errors:
		print("Проверка не пройдена. Ни одной записи не отправлено.")
		return []

	return jobs


func _on_pressed() -> void:
	if busy:
		return

	_set_busy(true)

	# При отсутствии токена это нажатие только восстанавливает вход.
	if token.is_empty():
		text = "Авторизация..."

		var logged_in: bool = await _login()

		if logged_in:
			text = "Отправить все значения"
		else:
			text = "Повторить авторизацию"

		_set_busy(false)
		return

	text = "Получение паспортов..."

	print("")
	print("========== ЗАПРОС ПАСПОРТОВ ==========")
	print(
		"GET ",
		base_url.trim_suffix("/"),
		"/api/v2/passports"
	)
	print("Authorization: Bearer [токен скрыт]")

	var response: Dictionary = await _request(
		"/api/v2/passports",
		HTTPClient.METHOD_GET
	)

	if not response["connected"]:
		text = "Нет связи со SCADA"
		_set_busy(false)
		return

	var status: int = int(response["status"])

	if status < 200 or status >= 300:
		print("Ответ сервера: ", response["text"])

		if token.is_empty():
			text = "Повторить авторизацию"
		else:
			text = "Ошибка получения паспортов"

		_set_busy(false)
		return

	if print_all_passports:
		print("Полное тело ответа паспортов:")
		print(response["text"])

	var json := JSON.new()

	if json.parse(str(response["text"])) != OK:
		text = "Ответ паспортов не JSON"
		print("Ошибка разбора JSON: ", json.get_error_message())

		_set_busy(false)
		return

	if not (json.data is Array):
		text = "Неверный формат паспортов"
		print("Ожидался массив паспортов.")

		_set_busy(false)
		return

	var passports: Array = json.data

	print("Получено паспортов: ", passports.size())

	if print_all_passports:
		print(JSON.stringify(passports, "\t"))

	_print_available_tags(passports)

	# Фиксируем все восемь значений перед началом записи.
	var sources: Array[Dictionary] = _get_sources()
	var jobs: Array[Dictionary] = _prepare_jobs(passports, sources)

	if jobs.is_empty():
		text = "Отправка отменена. См. Output"
		_set_busy(false)
		return

	var confirmed: int = 0

	for job in jobs:
		text = "Запись %d/%d: %s" % [
			confirmed + 1,
			jobs.size(),
			str(job["name"])
		]

		var success: bool = await _write_job(job)

		if not success:
			text = "Остановлено: подтверждено %d/%d" % [
				confirmed,
				jobs.size()
			]

			print(
				"Отправка остановлена на теге '",
				job["name"],
				"'. Подтверждено записей: ",
				confirmed,
				"/",
				jobs.size(),
				". Уже выполненные записи не отменены."
			)

			_set_busy(false)
			return

		confirmed += 1

	text = "Отправлено: %d/%d" % [
		confirmed,
		jobs.size()
	]

	print("Сервер подтвердил все ", confirmed, " записей.")
	_set_busy(false)


func _write_job(job: Dictionary) -> bool:
	var path := "/api/channels/" + str(job["id"]).uri_encode()

	var body := JSON.stringify({
		"value": job["value"]
	})

	print(
		"Запись ", job["source"],
		" → тег '", job["name"],
		"', ID=", job["id"],
		", значение=", job["value"]
	)

	var response: Dictionary = await _request(
		path,
		HTTPClient.METHOD_PATCH,
		body
	)

	if not response["connected"]:
		print(
			"Ошибка соединения. Результат текущей записи неизвестен. ",
			"Проверь значение в SCADA перед повторной отправкой."
		)
		return false

	var response_text: String = str(response["text"])

	if not response_text.is_empty():
		print("Ответ сервера: ", response_text)

	var status: int = int(response["status"])

	if status != 204:
		print(
			"Запись тега '", job["name"],
			"' не подтверждена. HTTP: ", status
		)
		return false

	print("Подтверждена запись тега '", job["name"], "'.")
	return true
