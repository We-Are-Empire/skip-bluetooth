// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

#if SKIP
import android.bluetooth.le.__
import android.bluetooth.__
import android.bluetooth.BluetoothGattCallback
import android.os.Build

public enum CBPeripheralState : Int, @unchecked Sendable {
    case disconnected = 0
    case connecting = 1
    case connected = 2
    case disconnecting = 3
}

public enum CBCharacteristicWriteType : Int, @unchecked Sendable {
    case withResponse = 2
    case withoutResponse = 1
}

extension ScanResult {
    internal var advertisementData: [String: Any] {
        parseAdvertisementData()
    }

    internal func toPeripheral() -> CBPeripheral {
        return CBPeripheral(result: self)
    }

    /// Maps the `ScanResult` to `advertisementData` expected from a scan response
    ///
    /// - Note: Some fields are not available in the `ScanResult` object
    ///         - `kCBAdvDataOverflowServiceUUIDs`
    ///         - `kCBAdvDataSolicitedServiceUUIDs`
    ///
    /// The following are unimplemented:
    /// - `CBAdvertisementDataManufacturerDataKey`
    /// - `CBAdvertisementDataIsConnectable`
    ///
    /// - Returns: The `advertisementData`
    private func parseAdvertisementData() -> [String: Any] {
        let advertisementData: [String: Any] = [:]

        if let deviceName = scanRecord?.deviceName {
            advertisementData[CBAdvertisementDataLocalNameKey] = deviceName
        }

        if let txPowerLevel = scanRecord?.txPowerLevel,
           txPowerLevel != Int.MIN_VALUE {
            advertisementData[CBAdvertisementDataTxPowerLevelKey] = txPowerLevel
        }

        if let uuids = scanRecord?.serviceUuids {
            advertisementData[CBAdvertisementDataServiceUUIDsKey] = uuids.map { $0.uuid }
        }

        advertisementData[CBAdvertisementDataIsConnectable] = isConnectable

        // TODO: CBAdvertisementDataServiceDataKey
        // TODO: CBAdvertisementDataManufacturerDataKey

        return advertisementData
    }
}

/// Represents a queued GATT operation for sequential processing
internal enum GattOperation {
    case readCharacteristic(CBCharacteristic)
    case writeCharacteristic(CBCharacteristic, Data, CBCharacteristicWriteType)
    case writeDescriptor(BluetoothGattDescriptor, ByteArray)
    case readDescriptor(BluetoothGattDescriptor, CBDescriptor)
    case writeDescriptorValue(BluetoothGattDescriptor, CBDescriptor, ByteArray)
}

open class CBPeripheral: CBPeer {
    private var _name: String?
    private var _address: String?
    private let stateWatcher = PeripheralStateWatcher { self.state = $0 }

    private var gattDelegate: BleGattCallback?

    internal let device: BluetoothDevice?

    /// Enables us to connect to this peripheral with the underlying Kotlin API
    internal let gatt: BluetoothGatt?

    /// Per-peripheral delegate (allows different delegates for multiple connections)
    private var _delegate: (any CBPeripheralDelegate)?

    /// Current MTU (Maximum Transmission Unit) for this connection
    /// Default BLE MTU is 23 bytes, updated when MTU is negotiated
    private var _mtu: Int = 23

    // MARK: - Operation Queue
    /// Queue of pending GATT operations (Android only allows one at a time)
    private var operationQueue: [GattOperation] = []
    /// Whether an operation is currently in progress
    private var isOperationInProgress: Bool = false
    /// Lock for thread-safe queue access
    private let queueLock = NSLock()

    internal init(result: ScanResult) {
        super.init(macAddress: result.device.address)
        self._name = result.scanRecord?.deviceName
        self._address = result.device.address
        self.device = result.device

        // Although we can get the `BluetoothDevice` from the `ScanResult`
        // we choose not to because in CoreBluetooth we some APIs aren't
        // available until we connect to the device, e.g. `discoverServices`
        self.gatt = nil
    }

    internal init(gatt: BluetoothGatt, gattDelegate: BleGattCallback) {
        super.init(macAddress: gatt.device.address)
        self._name = gatt.device.name
        self._address = gatt.device.address
        self.device = gatt.device
        // Peripheral is now registered in CBCentralManager via registerConnectedPeripheral()
        // rather than stored directly on the gattDelegate
        self.gattDelegate = gattDelegate
        self.gatt = gatt
    }

    open var delegate: (any CBPeripheralDelegate)? {
        get {
            _delegate
        } set {
            _delegate = newValue
        }
    }

    open var name: String? { _name }
    open var address: String? { _address }
    open private(set) var state: CBPeripheralState = CBPeripheralState.disconnected

    open var services: [CBService]? {
        gattDelegate?.services
    }

    // MARK: - Operation Queue Management

    /// Queue an operation and process if not busy
    private func queueOperation(_ operation: GattOperation) {
        queueLock.lock()
        operationQueue.append(operation)
        let shouldProcess = !isOperationInProgress
        queueLock.unlock()

        if shouldProcess {
            processNextOperation()
        }
    }

    /// Process the next queued operation
    private func processNextOperation() {
        queueLock.lock()
        guard !operationQueue.isEmpty else {
            isOperationInProgress = false
            queueLock.unlock()
            return
        }

        isOperationInProgress = true
        let operation = operationQueue.removeFirst()
        queueLock.unlock()

        executeOperation(operation)
    }

    /// Execute a single GATT operation
    private func executeOperation(_ operation: GattOperation) {
        guard let gatt = gatt else {
            logger.error("CBPeripheral.executeOperation: gatt is nil")
            processNextOperation()
            return
        }

        switch operation {
        case .readCharacteristic(let characteristic):
            logger.debug("CBPeripheral: Executing queued read for \(characteristic.uuid.uuidString)")
            let result = gatt.readCharacteristic(characteristic.kotlin())
            if result != true {
                logger.error("CBPeripheral: Read operation failed to start")
                // Operation failed to start, process next
                processNextOperation()
            }

        case .writeCharacteristic(let characteristic, let data, let type):
            logger.debug("CBPeripheral: Executing queued write for \(characteristic.uuid.uuidString)")
            if Build.VERSION.SDK_INT >= 33 {
                gatt.writeCharacteristic(characteristic.kotlin(), data.kotlin(), type.rawValue)
            } else {
                characteristic.kotlin().setValue(data.kotlin())
                characteristic.kotlin().setWriteType(type.rawValue)
                gatt.writeCharacteristic(characteristic.kotlin())
            }
            // For writes without response, process next immediately
            if type == .withoutResponse {
                processNextOperation()
            }

        case .writeDescriptor(let descriptor, let value):
            logger.debug("CBPeripheral: Executing queued descriptor write")
            if Build.VERSION.SDK_INT >= 33 {
                gatt.writeDescriptor(descriptor, value)
            } else {
                descriptor.setValue(value)
                gatt.writeDescriptor(descriptor)
            }

        case .readDescriptor(let androidDescriptor, let cbDescriptor):
            logger.debug("CBPeripheral: Executing queued descriptor read for \(cbDescriptor.uuid.uuidString)")
            let result = gatt.readDescriptor(androidDescriptor)
            if result != true {
                logger.error("CBPeripheral: Descriptor read operation failed to start")
                processNextOperation()
            }

        case .writeDescriptorValue(let androidDescriptor, let cbDescriptor, let value):
            logger.debug("CBPeripheral: Executing queued descriptor write for \(cbDescriptor.uuid.uuidString)")
            if Build.VERSION.SDK_INT >= 33 {
                gatt.writeDescriptor(androidDescriptor, value)
            } else {
                androidDescriptor.setValue(value)
                gatt.writeDescriptor(androidDescriptor)
            }
        }
    }

    /// Called by BleGattCallback when an operation completes
    internal func onOperationComplete() {
        logger.debug("CBPeripheral: Operation complete, processing next")
        processNextOperation()
    }

    /// Indicates whether the peripheral is ready to send a write without response.
    ///
    /// - Note: On Android, this returns `true` when no GATT operation is currently in progress.
    ///   Since writes are queued internally, you can always call `writeValue(_:for:type:)` and
    ///   the write will be processed when the queue is ready. However, checking this property
    ///   can help you match iOS flow control behavior.
    open var canSendWriteWithoutResponse: Bool {
        queueLock.lock()
        let canSend = !isOperationInProgress
        queueLock.unlock()
        return canSend
    }

    @available(*, unavailable)
    open var ancsAuthorized: Bool { fatalError() }

    /// Retrieves the current RSSI value for the peripheral while connected.
    ///
    /// The result is delivered via the `peripheral(_:didReadRSSI:error:)` delegate method.
    ///
    /// - Note: This method only works while the peripheral is connected. If called when
    ///   disconnected, the operation will fail silently.
    open func readRSSI() {
        guard let gatt = gatt else {
            logger.error("CBPeripheral.readRSSI: gatt is nil")
            return
        }

        let result = gatt.readRemoteRssi()
        if !result {
            logger.warning("CBPeripheral.readRSSI: Failed to initiate RSSI read")
        }
    }

    open func discoverServices(_ serviceUUIDs: [CBUUID]?) {
        guard hasPermission(android.Manifest.permission.BLUETOOTH) else {
            logger.debug("CBPeripheral.discoverService: Missing permissions")
        }

        // TODO: Filter services in callback

        logger.debug("CBPeripheral.discoverService: discovering services...")
        gatt?.discoverServices();
    }

    @available(*, unavailable)
    open func discoverIncludedServices(_ includedServiceUUIDs: [CBUUID]?, for service: CBService) {}

    open func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {
        service.setCharacteristicFilter(characteristicUUIDs)
        delegate?.peripheralDidDiscoverCharacteristicsFor(self, didDiscoverCharacteristicsFor: service, error: nil)
    }

    open func readValue(for characteristic: CBCharacteristic) {
        logger.debug("CBPeripheral.readValue: Queueing read for \(characteristic.uuid.uuidString)")
        queueOperation(.readCharacteristic(characteristic))
    }

    /// Returns the maximum amount of data that can be sent to a characteristic in a single write.
    ///
    /// - Parameter type: The type of write (with or without response).
    /// - Returns: The maximum payload size in bytes.
    ///
    /// - Note: On Android, this is calculated as MTU - 3 (for the ATT header). The default
    ///   BLE MTU is 23 bytes, giving a default write length of 20 bytes. If you've negotiated
    ///   a larger MTU using `requestMtu()`, this value will reflect the larger size.
    open func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        // ATT header is 3 bytes (1 byte opcode + 2 bytes handle)
        return _mtu - 3
    }

    /// Updates the MTU for this peripheral (called by BleGattCallback when MTU changes)
    internal func updateMtu(_ mtu: Int) {
        _mtu = mtu
        logger.debug("CBPeripheral: MTU updated to \(mtu)")
    }

    open func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        logger.debug("CBPeripheral.writeValue: Queueing write for \(characteristic.uuid.uuidString)")
        queueOperation(.writeCharacteristic(characteristic, data, type))
    }

    open func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        guard let gatt = gatt else {
            logger.error("CBPeripheral.setNotifyValue: `gatt` is null which should never happen.")
            return
        }

        // setCharacteristicNotification is a local registration, not a GATT operation
        guard gatt.setCharacteristicNotification(characteristic.kotlin(), enabled) ?? false else {
            logger.warning("CBPeripheral.setNotifyValue: Failed to setup characteristic subscription")
            return
        }

        guard let descriptor = characteristic.kotlin().getDescriptor(java.util.UUID.fromString(CCCD)) else {
            logger.warning("CBPeripheral.setNotifyValue: Failed to find notification descriptor")
            return
        }

        // Determine the correct CCCD value based on characteristic properties
        // Some characteristics use INDICATE (requires ACK) instead of NOTIFY (no ACK)
        // iOS CoreBluetooth handles this automatically, on Android we must check manually
        let properties = characteristic.kotlin().getProperties()
        let supportsIndicate = (properties & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0
        let supportsNotify = (properties & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0

        let value: ByteArray
        if enabled {
            if supportsIndicate {
                logger.debug("CBPeripheral.setNotifyValue: Using INDICATE for \(characteristic.uuid.uuidString)")
                value = BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            } else if supportsNotify {
                logger.debug("CBPeripheral.setNotifyValue: Using NOTIFY for \(characteristic.uuid.uuidString)")
                value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            } else {
                logger.warning("CBPeripheral.setNotifyValue: Characteristic doesn't support NOTIFY or INDICATE")
                value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            }
        } else {
            value = BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        }

        characteristic.kotlin().setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)

        // Queue the descriptor write operation
        logger.debug("CBPeripheral.setNotifyValue: Queueing descriptor write for \(characteristic.uuid.uuidString)")
        queueOperation(.writeDescriptor(descriptor, value))
    }

    /// Discovers the descriptors of a characteristic.
    ///
    /// - Parameter characteristic: The characteristic whose descriptors you want to discover.
    ///
    /// - Note: On Android, descriptors are automatically available after service discovery.
    ///   This method simply calls the delegate immediately with the already-available descriptors.
    ///   Use this for CoreBluetooth API compatibility.
    open func discoverDescriptors(for characteristic: CBCharacteristic) {
        logger.debug("CBPeripheral.discoverDescriptors: Discovering descriptors for \(characteristic.uuid.uuidString)")
        // On Android, descriptors are available immediately after service discovery
        delegate?.peripheralDidDiscoverDescriptorsFor(self, didDiscoverDescriptorsFor: characteristic, error: nil)
    }

    /// Reads the value of a descriptor.
    ///
    /// - Parameter descriptor: The descriptor to read.
    ///
    /// The result is delivered via the `peripheral(_:didUpdateValueFor:error:)` delegate method
    /// for descriptors.
    open func readValue(for descriptor: CBDescriptor) {
        guard let gatt = gatt else {
            logger.error("CBPeripheral.readValue(descriptor): gatt is nil")
            return
        }
        guard let androidDescriptor = descriptor.kotlin() else {
            logger.error("CBPeripheral.readValue(descriptor): descriptor has no Android representation")
            return
        }

        logger.debug("CBPeripheral.readValue: Queueing descriptor read for \(descriptor.uuid.uuidString)")
        queueOperation(.readDescriptor(androidDescriptor, descriptor))
    }

    /// Writes the value of a descriptor.
    ///
    /// - Parameters:
    ///   - data: The data to write to the descriptor.
    ///   - descriptor: The descriptor to write to.
    ///
    /// The result is delivered via the `peripheral(_:didWriteValueFor:error:)` delegate method
    /// for descriptors.
    open func writeValue(_ data: Data, for descriptor: CBDescriptor) {
        guard let gatt = gatt else {
            logger.error("CBPeripheral.writeValue(descriptor): gatt is nil")
            return
        }
        guard let androidDescriptor = descriptor.kotlin() else {
            logger.error("CBPeripheral.writeValue(descriptor): descriptor has no Android representation")
            return
        }

        logger.debug("CBPeripheral.writeValue: Queueing descriptor write for \(descriptor.uuid.uuidString)")
        queueOperation(.writeDescriptorValue(androidDescriptor, descriptor, data.kotlin()))
    }

    @available(*, unavailable)
    open func openL2CAPChannel(_ PSM: CBL2CAPPSM) {}

    private class PeripheralStateWatcher: BluetoothGattCallback {
        private let completion: (CBPeripheralState) -> Void

        init(completion: @escaping (CBPeripheralState) -> Void) {
            self.completion = completion
        }

        override func onConnectionStateChange(gatt: BluetoothGatt, state: Int, newState: Int) {
            switch (newState) {
            case BluetoothProfile.STATE_DISCONNECTED:
                logger.debug("CBPeripheral: Device disconnected")
                completion(CBPeripheralState.disconnected)
                break
            case BluetoothProfile.STATE_CONNECTING:
                logger.debug("CBPeripheral: Device connecting")
                completion(CBPeripheralState.connecting)
                break
            case BluetoothProfile.STATE_CONNECTED:
                logger.debug("CBPeripheral: Device connected")
                completion(CBPeripheralState.connected)
                break
            case BluetoothProfile.STATE_DISCONNECTING:
                logger.debug("CBPeripheral: Device disconnecting")
                completion(CBPeripheralState.disconnecting)
                break
            }
        }
    }
}

public protocol CBPeripheralDelegate {
    func peripheralDidUpdateName(_ peripheral: CBPeripheral)
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService])

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: (any Error)?)
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?)

    @available(*, unavailable)
    func peripheralDidDiscoverIncludedServicesFor(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: (any Error)?)
    func peripheralDidDiscoverCharacteristicsFor(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?)
    func peripheralDidUpdateValueFor(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?)
    func peripheralDidUpdateNotificationStateFor(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?)

    func peripheralDidDiscoverDescriptorsFor(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: (any Error)?)
    func peripheralDidUpdateValueFor(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: (any Error)?)

    func peripheralDidWriteValueFor(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?)
    func peripheralDidWriteValueFor(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: (any Error)?)

    @available(*, unavailable)
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral)

    @available(*, unavailable)
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: (any Error)?)
}

extension CBPeripheralDelegate {
    public func peripheralDidUpdateName(_ peripheral: CBPeripheral) {}
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {}
    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: (any Error)?) {}
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {}

    public func peripheralDidWriteValueFor(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {}
    public func peripheralDidWriteValueFor(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: (any Error)?) {}
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: (any Error)?) {}
    @available(*, unavailable)
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {}
    @available(*, unavailable)
    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {}
    @available(*, unavailable)
    public func peripheralDidDiscoverIncludedServicesFor(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: (any Error)?) {}
    public func peripheralDidDiscoverCharacteristicsFor(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {}
    public func peripheralDidDiscoverDescriptorsFor(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: (any Error)?) {}
    public func peripheralDidUpdateNotificationStateFor(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {}
    public func peripheralDidUpdateValueFor(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {}
    public func peripheralDidUpdateValueFor(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: (any Error)?) {}
}

#endif
#endif

