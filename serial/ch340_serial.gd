extends Node

signal connection_changed(is_connected: bool, port: String)
signal bytes_received(data: PackedByteArray)

const TARGET_VID := "067B"
const TARGET_PID := "2303"
const BAUD_RATE := 9600
const RECONNECT_DELAY_SEC := 2.0

var manager: GdSerialManager
var scanner: GdSerial
var selected_port := ""
var connected := false
var reconnect_timer := 0.0

func _ready() -> void:
	manager = GdSerialManager.new()
	scanner = GdSerial.new()
	manager.data_received.connect(_on_data_received)
	manager.port_disconnected.connect(_on_port_disconnected)
	connect_to_ch340()

func _process(delta: float) -> void:
	manager.poll_events()
	if connected:
		return
	reconnect_timer -= delta
	if reconnect_timer <= 0.0:
		reconnect_timer = RECONNECT_DELAY_SEC
		connect_to_ch340()

func connect_to_ch340() -> void:
	if connected:
		return
	selected_port = find_ch340_port()
	if selected_port.is_empty():
		connection_changed.emit(false, "")
		return
	connected = manager.open(selected_port, BAUD_RATE, 0, GdSerialManager.MODE_RAW)
	if not connected:
		selected_port = ""
	reconnect_timer = RECONNECT_DELAY_SEC
	connection_changed.emit(connected, selected_port)

func find_ch340_port() -> String:
	var ports: Dictionary = scanner.list_ports()
	for index in ports:
		var info: Dictionary = ports[index]
		var port_name := str(info.get("port_name", ""))
		var port_type := str(info.get("port_type", ""))
		var device_name := str(info.get("device_name", ""))
		if port_type.contains("VID: " + TARGET_VID) and port_type.contains("PID: " + TARGET_PID):
			return port_name
		if device_name.to_upper().contains("CH340"):
			return port_name
	return ""

func send_bytes(data: PackedByteArray) -> bool:
	if not connected or selected_port.is_empty():
		return false
	manager.write(selected_port, data)
	return true

func _on_data_received(port: String, data: PackedByteArray) -> void:
	if connected and port == selected_port:
		bytes_received.emit(data)

func _on_port_disconnected(port: String) -> void:
	if port != selected_port:
		return
	connected = false
	selected_port = ""
	reconnect_timer = RECONNECT_DELAY_SEC
	connection_changed.emit(false, "")

func _exit_tree() -> void:
	if manager != null and connected and not selected_port.is_empty():
		manager.close(selected_port)
	connected = false
