// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

#if SKIP
import android.content.pm.PackageManager
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.os.Build

// MARK: Globals
let CCCD = "00002902-0000-1000-8000-00805f9b34fb"

/// Checks if the given permission is granted
internal func hasPermission(_ permission: String) -> Bool {
    let context = ProcessInfo.processInfo.androidContext
    return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
}

/// Handles behavior for calling `CBCentralManagerDelegate`and `CBPeripheralDelegate` callbacks after a connection has been established
internal class BleGattCallback: BluetoothGattCallback {
    private let central: CBCentralManager

    private(set) var services: [CBService]?

    var centralManagerDelegate: CBCentralManagerDelegate?

    init(central: CBCentralManager) {
        self.central = central
    }

    /// Get the peripheral for a GATT connection, creating and registering one if needed
    private func getOrCreatePeripheral(for gatt: BluetoothGatt) -> CBPeripheral {
        let address = gatt.device.address
        if let existing = central.getPeripheral(for: address) {
            return existing
        }
        // Create new peripheral and register it
        let peripheral = CBPeripheral(gatt: gatt, gattDelegate: self)
        central.registerConnectedPeripheral(peripheral, for: address)
        return peripheral
    }

    // MARK: CBCentralManagerDelegate equivalent functions
    override func onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
        let deviceAddress = gatt.device.address

        if status == BluetoothGatt.GATT_SUCCESS {
            if newState == BluetoothProfile.STATE_CONNECTED {
                logger.debug("GattCallback.onConnectionStateChange: Connected to \(deviceAddress)")
                let peripheral = getOrCreatePeripheral(for: gatt)
                centralManagerDelegate?.centralManagerDidConnect(central, peripheral)
            } else {
                logger.debug("GattCallback.onConnectionStateChange: Disconnected from \(deviceAddress)")
                // Get peripheral before clearing (or create a temporary one for the callback)
                let peripheral = central.getPeripheral(for: deviceAddress) ?? CBPeripheral(gatt: gatt, gattDelegate: self)
                // Clear only this specific device's tracking so reconnection is possible
                central.clearConnectedDevice(address: deviceAddress)
                centralManagerDelegate?.centralManagerDidDisconnectPeripheral(central, peripheral, nil)
            }
        } else {
            logger.debug("GattCallback.onConnectionStateChange: Failed for \(deviceAddress), status: \(status)")
            let peripheral = central.getPeripheral(for: deviceAddress) ?? CBPeripheral(gatt: gatt, gattDelegate: self)
            // Clear only this specific device's tracking on connection failure so retry is possible
            central.clearConnectedDevice(address: deviceAddress)
            let error = NSError(domain: "skip.bluetooth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Central manager failed to connect with. Status: \(status)"])
            centralManagerDelegate?.centralManager(central, didFailToConnect: peripheral, error: error)
        }
    }

    // MARK: CBPeripheralDelegate equivalent functions
    override func onServicesDiscovered(gatt: BluetoothGatt, state: Int) {
        let address = gatt.device.address
        guard let peripheral = central.getPeripheral(for: address) else {
            logger.warning("BleGattCallback.onServicesDiscovered: No peripheral found for \(address)")
            return
        }

        if state == BluetoothGatt.GATT_SUCCESS {
            logger.debug("BleGattCallback.onServicesDiscovered: successfully discovered services for \(address)")
            let services = gatt.services.map { $0.toService() }
            self.services = Array(services)
            peripheral.delegate?.peripheral(peripheral, nil)
        } else {
            logger.debug("BleGattCallback.onServicesDiscovered: failed to discover services for \(address)")
            let error = NSError(domain: "skip.bluetooth", code: state, userInfo: nil)
            peripheral.delegate?.peripheral(peripheral: peripheral, didDiscoverServices: error)
        }
    }

    // API 33+ version - value passed as parameter
    override func onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, state: Int ) {
        handleCharacteristicRead(gatt: gatt, characteristic: characteristic, value: value, state: state)
    }

    // API < 33 version (deprecated) - value from characteristic.getValue()
    @available(*, deprecated, message: "Use onCharacteristicRead with value parameter for API 33+")
    override func onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, state: Int) {
        let value = characteristic.getValue() ?? ByteArray(size: 0)
        handleCharacteristicRead(gatt: gatt, characteristic: characteristic, value: value, state: state)
    }

    private func handleCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, state: Int) {
        let address = gatt.device.address
        guard let peripheral = central.getPeripheral(for: address) else {
            logger.warning("BluetoothGattCallback.onCharacteristicRead: No peripheral found for \(address)")
            return
        }
        let APPLE_GENERAL_ERROR = 241

        let cbCharacteristic = CBCharacteristic(platformValue: characteristic, value: Data(value))
        logger.debug("BluetoothGattCallback.onCharacteristicRead: Characteristic read \(characteristic.uuid) for \(address)")

        if state == APPLE_GENERAL_ERROR {
            peripheral.delegate?.peripheralDidUpdateValueFor(
                peripheral,
                didUpdateValueFor: cbCharacteristic,
                error: NSError(domain: "skip.bluetooth", code: state, userInfo: nil)
            )
        } else {
            peripheral.delegate?.peripheralDidUpdateValueFor(
                peripheral,
                didUpdateValueFor: cbCharacteristic,
                error: nil
            )
        }

        // Signal operation complete to process next queued operation
        peripheral.onOperationComplete()
    }

    override func onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, state: Int) {
        let address = gatt.device.address
        guard let peripheral = central.getPeripheral(for: address) else {
            logger.warning("BluetoothGattCallback.onCharacteristicWrite: No peripheral found for \(address)")
            return
        }

        if state == BluetoothGatt.GATT_SUCCESS {
            logger.debug("BluetoothGattCallback.onCharacteristicWrite: Successfully wrote to \(address)")
            peripheral.delegate?.peripheralDidWriteValueFor(peripheral, didWriteValueFor: CBCharacteristic(platformValue: characteristic), error: nil)
        } else {
            let error = NSError(domain: "skip.bluetooth", code: state, userInfo: [NSLocalizedDescriptionKey: "Write to peripheral failed"])
            logger.error("BluetoothGattCallback.onCharacteristicWrite: Failed to write to \(address) with error: \(error)")
            peripheral.delegate?.peripheralDidWriteValueFor(peripheral, didWriteValueFor: CBCharacteristic(platformValue: characteristic), error: error)
        }

        // Signal operation complete to process next queued operation
        peripheral.onOperationComplete()
    }

    // API 33+ version - value passed as parameter
    override func onDescriptorRead(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, state: Int, value: ByteArray) {
        handleDescriptorRead(gatt: gatt, descriptor: descriptor, state: state, value: value)
    }

    // API < 33 version (deprecated) - value from descriptor.getValue()
    @available(*, deprecated, message: "Use onDescriptorRead with value parameter for API 33+")
    override func onDescriptorRead(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, state: Int) {
        let value = descriptor.getValue() ?? ByteArray(size: 0)
        handleDescriptorRead(gatt: gatt, descriptor: descriptor, state: state, value: value)
    }

    private func handleDescriptorRead(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, state: Int, value: ByteArray) {
        let address = gatt.device.address
        guard let peripheral = central.getPeripheral(for: address) else {
            logger.warning("BluetoothGattCallback.onDescriptorRead: No peripheral found for \(address)")
            return
        }

        let cbCharacteristic = CBCharacteristic(platformValue: descriptor.characteristic)

        guard state == BluetoothGatt.GATT_SUCCESS else {
            logger.debug("BluetoothGattCallback.onDescriptorRead: Failed to read from \(address)")
            // For non-CCCD descriptors, call the descriptor delegate
            if descriptor.uuid != java.util.UUID.fromString(CCCD) {
                let cbDescriptor = CBDescriptor(platformValue: descriptor, characteristic: cbCharacteristic)
                peripheral.delegate?.peripheralDidUpdateValueFor(
                    peripheral,
                    didUpdateValueFor: cbDescriptor,
                    error: NSError(domain: "skip.bluetooth", code: state, userInfo: nil)
                )
            }
            peripheral.onOperationComplete()
            return
        }

        if descriptor.uuid == java.util.UUID.fromString(CCCD) {
            // CCCD handling for notifications
            if (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) {
                logger.debug("BluetoothGattCallback.onDescriptorRead: Successfully subscribed to characteristic on \(address)")
                cbCharacteristic.setIsNotifying(to: true)
            } else {
                logger.debug("BluetoothGattCallback.onDescriptorRead: Successfully unsubscribed from characteristic on \(address)")
                cbCharacteristic.setIsNotifying(to: false)
            }

            peripheral.delegate?.peripheralDidUpdateNotificationStateFor(
                peripheral,
                didUpdateNotificationStateFor: cbCharacteristic,
                error: nil
            )
        } else {
            // General descriptor read
            logger.debug("BluetoothGattCallback.onDescriptorRead: Read descriptor \(descriptor.uuid) on \(address)")
            let cbDescriptor = CBDescriptor(platformValue: descriptor, characteristic: cbCharacteristic, value: Data(value))
            peripheral.delegate?.peripheralDidUpdateValueFor(
                peripheral,
                didUpdateValueFor: cbDescriptor,
                error: nil
            )
        }

        peripheral.onOperationComplete()
    }

    override func onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, state: Int) {
        let address = gatt.device.address
        guard let peripheral = central.getPeripheral(for: address) else {
            logger.warning("BluetoothGattCallback.onDescriptorWrite: No peripheral found for \(address)")
            return
        }

        let cbCharacteristic = CBCharacteristic(platformValue: descriptor.characteristic)

        guard state == BluetoothGatt.GATT_SUCCESS else {
            logger.debug("BluetoothGattCallback.onDescriptorWrite: Failed to write to \(address)")
            // Call appropriate delegate based on descriptor type
            if descriptor.uuid == java.util.UUID.fromString(CCCD) {
                peripheral.delegate?.peripheralDidWriteValueFor(peripheral, didWriteValueFor: cbCharacteristic, error: NSError(domain: "skip.bluetooth", code: state, userInfo: nil))
            } else {
                let cbDescriptor = CBDescriptor(platformValue: descriptor, characteristic: cbCharacteristic)
                peripheral.delegate?.peripheralDidWriteValueFor(peripheral, didWriteValueFor: cbDescriptor, error: NSError(domain: "skip.bluetooth", code: state, userInfo: nil))
            }
            peripheral.onOperationComplete()
            return
        }

        if descriptor.uuid == java.util.UUID.fromString(CCCD) {
            logger.debug("BluetoothGattCallback.onDescriptorWrite: Notification enabled successfully on \(address)")
            // Notification is set up - no need to read to confirm, just mark as notifying
            cbCharacteristic.setIsNotifying(to: true)
            peripheral.delegate?.peripheralDidUpdateNotificationStateFor(
                peripheral,
                didUpdateNotificationStateFor: cbCharacteristic,
                error: nil
            )
        } else {
            // General descriptor write
            logger.debug("BluetoothGattCallback.onDescriptorWrite: Descriptor \(descriptor.uuid) written on \(address)")
            let cbDescriptor = CBDescriptor(platformValue: descriptor, characteristic: cbCharacteristic)
            peripheral.delegate?.peripheralDidWriteValueFor(peripheral, didWriteValueFor: cbDescriptor, error: nil)
        }

        // Signal operation complete
        peripheral.onOperationComplete()
    }

    // API 33+ version - value passed as parameter
    override func onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
        handleCharacteristicChanged(gatt: gatt, characteristic: characteristic, value: value)
    }

    // API < 33 version (deprecated) - value from characteristic.getValue()
    @available(*, deprecated, message: "Use onCharacteristicChanged with value parameter for API 33+")
    override func onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        let value = characteristic.getValue() ?? ByteArray(size: 0)
        handleCharacteristicChanged(gatt: gatt, characteristic: characteristic, value: value)
    }

    private func handleCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
        let address = gatt.device.address
        guard let peripheral = central.getPeripheral(for: address) else {
            logger.warning("BluetoothGattCallback.onCharacteristicChanged: No peripheral found for \(address)")
            return
        }

        let cbCharacteristic = CBCharacteristic(platformValue: characteristic, value: Data(value))
        logger.debug("BluetoothGattCallback.onCharacteristicChanged: Characteristic changed \(characteristic.uuid) on \(address)")
        peripheral.delegate?.peripheralDidUpdateValueFor(
            peripheral,
            didUpdateValueFor: cbCharacteristic,
            error: nil
        )
    }

    override func onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
        let address = gatt.device.address
        guard let peripheral = central.getPeripheral(for: address) else {
            logger.warning("BluetoothGattCallback.onReadRemoteRssi: No peripheral found for \(address)")
            return
        }

        if status == BluetoothGatt.GATT_SUCCESS {
            logger.debug("BluetoothGattCallback.onReadRemoteRssi: RSSI=\(rssi) for \(address)")
            peripheral.delegate?.peripheral(peripheral, didReadRSSI: NSNumber(value: rssi), error: nil)
        } else {
            let error = NSError(domain: "skip.bluetooth", code: status, userInfo: [NSLocalizedDescriptionKey: "Failed to read RSSI"])
            logger.error("BluetoothGattCallback.onReadRemoteRssi: Failed for \(address) with status \(status)")
            peripheral.delegate?.peripheral(peripheral, didReadRSSI: NSNumber(value: rssi), error: error)
        }
    }

    override func onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
        let address = gatt.device.address
        guard let peripheral = central.getPeripheral(for: address) else {
            logger.warning("BluetoothGattCallback.onMtuChanged: No peripheral found for \(address)")
            return
        }

        if status == BluetoothGatt.GATT_SUCCESS {
            logger.debug("BluetoothGattCallback.onMtuChanged: MTU=\(mtu) for \(address)")
            peripheral.updateMtu(mtu)
        } else {
            logger.warning("BluetoothGattCallback.onMtuChanged: Failed for \(address) with status \(status)")
        }
    }
}

#endif
#endif
