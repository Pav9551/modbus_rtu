extends Node

const BASE_URL := "https://127.0.0.1:8080"

var token: String = ""
var http := HTTPRequest.new()
var write_http := HTTPRequest.new()
var write_in_progress: bool = false

@onready var value_label: Label = $VBoxContainer_scada/ValueLabel
@onready var status_label: Label = $VBoxContainer_scada/StatusLabel

const CHANNEL_ID := 31
const POLL_INTERVAL := 0.1  # Секунды между завершением запроса и следующим.

var poll_timer := Timer.new()


func _ready() -> void:
	add_child(http)
	http.timeout = 15.0
	add_child(poll_timer)
	poll_timer.one_shot = true
	poll_timer.wait_time = POLL_INTERVAL
	poll_timer.timeout.connect(_poll_channel)

	value_label.text = "—"
	status_label.text = "Авторизация..."
	
	add_child(write_http)
	write_http.timeout = 15.0

	var success := await login("admin", "admin")

	if not success:
		status_label.text = "Ошибка авторизации"
		return

	status_label.text = "Подключено"
	await _poll_channel()


func login(username: String, password: String) -> bool:
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json"
	])

	var body := JSON.stringify({
		"username": "admin",
		"password": "admin"
	})

	var error := http.request(
		BASE_URL + "/api/login",
		headers,
		HTTPClient.METHOD_POST,
		body
	)

	print("Запуск HTTP-запроса: ", error_string(error))

	if error != OK:
		return false

	var response: Array = await http.request_completed

	var result: int = response[0]
	var status: int = response[1]
	var text: String = response[3].get_string_from_utf8()

	print("Результат соединения: ", result)
	print("HTTP-статус: ", status)

	if result != HTTPRequest.RESULT_SUCCESS:
		match result:
			HTTPRequest.RESULT_CANT_CONNECT:
				print("Причина: не удалось подключиться к серверу.")
			HTTPRequest.RESULT_CANT_RESOLVE:
				print("Причина: не удалось определить адрес сервера.")
			HTTPRequest.RESULT_CONNECTION_ERROR:
				print("Причина: ошибка чтения или записи соединения.")
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
				print("Причина: ошибка установки HTTPS/TLS-соединения.")
			HTTPRequest.RESULT_TIMEOUT:
				print("Причина: истекло время ожидания.")
			_:
				print("Причина: ошибка HTTPRequest, код ", result)
		return false

	if status < 200 or status >= 300:
		print("Причина: сервер вернул HTTP ", status)
		return false

	var json := JSON.new()
	if json.parse(text) != OK:
		if text.strip_edges().begins_with("<"):
			print("Причина: сервер вернул HTML вместо JSON.")
		else:
			print("Причина: ответ не удалось разобрать как JSON.")
		return false

	if not (json.data is Dictionary):
		print("Причина: JSON-ответ не является объектом.")
		return false

	token = str(json.data.get("token", ""))

	if token.is_empty():
		print("Причина: в JSON-ответе нет непустого поля token.")
		return false

	print("Авторизация выполнена, токен получен.")
	return true
func get_channel(channel_id: int) -> void:
	if token.is_empty():
		print("Сначала необходимо авторизоваться.")
		return

	var url := BASE_URL + "/api/channels/%d" % channel_id
	url += "?nullIfNotFound=TRUE&reduceProps=TRUE&props=value"

	var headers := PackedStringArray([
		"Authorization: Bearer " + token,
		"Accept: application/json"
	])

	var error := http.request(
		url,
		headers,
		HTTPClient.METHOD_GET
	)

	if error != OK:
		print("Не удалось запустить запрос канала: ", error_string(error))
		return

	var response: Array = await http.request_completed

	var result: int = response[0]
	var status: int = response[1]
	var text: String = response[3].get_string_from_utf8()

	print("Результат запроса канала: ", result)
	print("HTTP-статус канала: ", status)
	print("Тело ответа: ", text)

	if result != HTTPRequest.RESULT_SUCCESS:
		print("Ошибка соединения при получении канала.")
		return

	if status < 200 or status >= 300:
		print("Сервер отклонил запрос. Ответ: ", text)
		return

	var json := JSON.new()
	if json.parse(text) != OK:
		print("Ответ канала не является JSON: ", text)
		return

	var data = json.data

	if not (data is Dictionary):
		print("Ожидался JSON-объект.")
		return

	var results = data.get("results", [])

	if not (results is Array) or results.is_empty():
		print("В ответе нет результатов.")
		return

	var channel = results[0]

	if not (channel is Dictionary) or not channel.has("v"):
		print("В результате отсутствует поле v.")
		return

	var value = channel["v"]
	print("Значение канала ", channel_id, ": ", value)
func _poll_channel() -> void:
	var url := BASE_URL + "/api/channels/%d" % CHANNEL_ID
	url += "?nullIfNotFound=TRUE&reduceProps=TRUE&props=value"

	var headers := PackedStringArray([
		"Authorization: Bearer " + token,
		"Accept: application/json"
	])

	var error := http.request(
		url,
		headers,
		HTTPClient.METHOD_GET
	)

	if error != OK:
		status_label.text = "Ошибка запуска: " + error_string(error)
		poll_timer.start()
		return

	var response: Array = await http.request_completed

	var result: int = response[0]
	var status: int = response[1]
	var text: String = response[3].get_string_from_utf8()

	if result != HTTPRequest.RESULT_SUCCESS:
		status_label.text = "Нет связи. Показано предыдущее значение."
		poll_timer.start()
		return

	if status == 401:
		status_label.text = "Доступ отклонён: требуется авторизация"
		return  # Останавливаем опрос, пока не восстановлена авторизация.

	if status < 200 or status >= 300:
		status_label.text = "Ошибка сервера: HTTP %d" % status
		poll_timer.start()
		return

	var json := JSON.new()
	if json.parse(text) != OK:
		status_label.text = "Сервер вернул не JSON"
		poll_timer.start()
		return

	var data = json.data

	if not (data is Dictionary):
		status_label.text = "Неверная структура ответа"
		poll_timer.start()
		return

	var results = data.get("results", [])

	if not (results is Array) or results.is_empty():
		status_label.text = "Нет данных канала"
		poll_timer.start()
		return

	var channel = results[0]

	if not (channel is Dictionary) or not channel.has("v"):
		status_label.text = "В ответе отсутствует поле v"
		poll_timer.start()
		return

	# Обновление формы.
	var value = channel["v"]

	if value == null:
		value_label.text = "Нет значения"
	else:
		value_label.text = str(value)

	status_label.text = "Обновлено: " + Time.get_time_string_from_system()

	# Следующий запрос — только после завершения текущего.
	poll_timer.start()
func set_channel_value(channel_id: int, new_value: Variant) -> bool:
	if token.is_empty():
		print("Запись невозможна: сначала необходимо авторизоваться.")
		return false

	if write_in_progress:
		print("Предыдущая запись ещё не завершена.")
		return false

	write_in_progress = true

	var url := BASE_URL + "/api/channels/%d" % channel_id

	var headers := PackedStringArray([
		"Authorization: Bearer " + token,
		"Content-Type: application/json",
		"Accept: application/json"
	])

	var body := JSON.stringify({
		"value": new_value
	})

	var error := write_http.request(
		url,
		headers,
		HTTPClient.METHOD_PATCH,
		body
	)

	if error != OK:
		write_in_progress = false
		print("Не удалось запустить запись: ", error_string(error))
		return false

	var response: Array = await write_http.request_completed
	write_in_progress = false

	var result: int = response[0]
	var status: int = response[1]
	var text: String = response[3].get_string_from_utf8()

	print("Результат соединения при записи: ", result)
	print("HTTP-статус записи: ", status)

	if not text.is_empty():
		print("Ответ сервера при записи: ", text)

	if result != HTTPRequest.RESULT_SUCCESS:
		print("Ошибка соединения при записи тега.")
		return false

	if status == 401:
		print("Запись отклонена: требуется авторизация.")
		return false

	if status != 204:
		print("Запись не подтверждена: ожидался HTTP 204, получен ", status)
		return false

	print(
		"Сервер подтвердил запись. Канал: ",
		channel_id,
		", значение: ",
		new_value
	)

	return true
