class_name ModbusConfig
extends RefCounted

# true — использовать смещение.
# false — использовать исходные адреса.
const USE_ADDRESS_OFFSET: bool = true

# Смещение адресов устройства.
const ADDRESS_OFFSET: int = 10


static func to_wire_address(address: int) -> int:
	if USE_ADDRESS_OFFSET:
		return address + ADDRESS_OFFSET

	return address
