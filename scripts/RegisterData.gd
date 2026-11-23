extends Node

# Последние полученные значения входных регистров.
# Ключ — адрес регистра, значение — его значение.
var input_registers: Dictionary = { 0: 0, 1: 0, 2: 0 }

# Значения coils.
var c5_value: bool = false
var c8_value: bool = false
var c16_value: bool = false
var c7_value: bool = false
var c26_value: bool = false

# Признаки получения данных.
# Позволяют отличать полученный false от отсутствия данных.
var c5_received: bool = false
var c8_received: bool = false
var c16_received: bool = false
var c7_received: bool = false
var c26_received: bool = false


func clear_values() -> void:
	input_registers.clear()

	c5_value = false
	c8_value = false
	c16_value = false
	c7_value = false
	c26_value = false

	c5_received = false
	c8_received = false
	c16_received = false
	c7_received = false
	c26_received = false
