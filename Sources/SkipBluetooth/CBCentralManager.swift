// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

#if SKIP
import androidx.__
import android.__
import android.content.IntentFilter
import android.content.Intent
import android.content.Context
import android.content.BroadcastReceiver
import android.Manifest
import android.app.__
import android.content.pm.__
import android.bluetooth.__
import android.bluetooth.le.__
import android.os.ParcelUuid
import android.os.Build

public enum CBConnectionEvent: Int, @unchecked Sendable {
    case peerDisconnected = 0
    case peerConnected = 1
}

open class CBCentralManager: CBManager {
    private let scanDelegate = BleScanCallback(central: self)
    private let gattDelegate = BleGattCallback(central: self)

    private lazy var bondingReceiver: BondCallback! = BondCallback { device in
        tryConnect(to: device)
    }

    // Support multiple simultaneous connections
    // Maps device address to its BluetoothGatt connection
    private var connectedGatts: [String: BluetoothGatt] = [:]

    // Maps device address to its CBPeripheral for callback lookups
    private var connectedPeripherals: [String: CBPeripheral] = [:]

    // Track device addresses we're currently connected/connecting to
    // This prevents multiple reconnection attempts after bonding
    private var connectedDeviceAddresses: Set<String> = []

    private var scanner: BluetoothLeScanner? {
        adapter?.getBluetoothLeScanner()
    }

    public var delegate: (any CBCentralManagerDelegate)? {
        get {
            gattDelegate.centralManagerDelegate
        } set {
            scanDelegate.delegate = newValue
            gattDelegate.centralManagerDelegate = newValue
        }
    }

    public var isScanning: Bool { adapter?.isDiscovering() ?? false }

    public convenience init() {
        super.init()

        stateChangedHandler = {
            delegate?.centralManagerDidUpdateState(self)
        }

        bondingReceiver = BondCallback { device in
            tryConnect(to: device)
        }

        let filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        let context = ProcessInfo.processInfo.androidContext
        context.registerReceiver(bondingReceiver, filter)
    }

    @available(*, unavailable)
    public convenience init(delegate: (any CBCentralManagerDelegate)?, queue: DispatchQueue?) { fatalError() }

    @available(*, unavailable)
    public init(delegate: (any CBCentralManagerDelegate)?, queue: DispatchQueue, options: [String : Any]? = nil) { fatalError() }

    open func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String : Any]? = nil) {
        guard hasPermission(android.Manifest.permission.BLUETOOTH_SCAN) else {
            logger.error("CBCentralManager.scanForPeripherals: Missing BLUETOOTH_SCAN permission.")
            return
        }

        let settingsBuilder = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_FIRST_MATCH)
        let filterBuilder = ScanFilter.Builder()

        if let serviceUUIDs = serviceUUIDs {
            for uuid in serviceUUIDs {
                filterBuilder.setServiceUuid(ParcelUuid(uuid.kotlin()))
            }
        }

        if let isDuplicate = options?[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool {
            settingsBuilder.setCallbackType(
                isDuplicate ? ScanSettings.CALLBACK_TYPE_ALL_MATCHES : ScanSettings.CALLBACK_TYPE_FIRST_MATCH
            )
        }

        // SKIP NOWARN
        if let uuids = options?[CBCentralManagerScanOptionSolicitedServiceUUIDsKey] as? [CBUUID] {
            for uuid in uuids {
                filterBuilder.setServiceSolicitationUuid(ParcelUuid(uuid.kotlin()))
            }
        }

        let settings = settingsBuilder.build()
        let scanFilters = listOf(filterBuilder.build())

        scanner?.startScan(scanFilters, settings, scanDelegate)
        logger.info("CBCentralManager.scanForPeripherals: Starting Scan")
    }

    public func stopScan() {
        guard hasPermission(android.Manifest.permission.BLUETOOTH_SCAN) else {
            logger.error("CBCentralManager.scanForPeripherals: Missing BLUETOOTH_SCAN permission")
            return
        }

        logger.info("CentralManager.stopScan: Stopping Scan")
        scanner?.stopScan(scanDelegate)
    }

    @available(*, unavailable)
    open class func supports(_ features: CBCentralManager.Feature) -> Bool { fatalError() }

    /// Returns peripherals that match the specified identifiers.
    ///
    /// - Parameter identifiers: A list of peripheral identifiers (UUIDs based on device MAC address).
    /// - Returns: A list of peripherals matching the identifiers.
    ///
    /// - Note: **Android limitation**: Unlike iOS, this method can only return peripherals that are
    ///   currently connected by this app. CoreBluetooth on iOS can retrieve previously-seen peripherals
    ///   that are cached by the system, even if not currently connected. On Android, there is no
    ///   equivalent system cache for BLE peripherals.
    open func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] {
        return identifiers.compactMap { uuid in
            connectedPeripherals.values.first { $0.identifier == uuid }
        }
    }

    /// Returns peripherals that are currently connected and have discovered the specified services.
    ///
    /// - Parameter serviceUUIDs: A list of service UUIDs to filter by.
    /// - Returns: A list of connected peripherals that have the specified services.
    ///
    /// - Note: **Android limitation**: Unlike iOS, this method only returns peripherals connected
    ///   by this app, not system-wide connections. Additionally, the peripheral must have already
    ///   called `discoverServices()` for the service filtering to work. CoreBluetooth on iOS can
    ///   return peripherals connected by any app on the system.
    open func retrieveConnectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [CBPeripheral] {
        guard !serviceUUIDs.isEmpty else {
            return Array(connectedPeripherals.values)
        }

        let serviceUUIDStrings = Set(serviceUUIDs.map { $0.uuidString })
        return connectedPeripherals.values.filter { peripheral in
            guard let services = peripheral.services else { return false }
            return services.contains { serviceUUIDStrings.contains($0.uuid.uuidString) }
        }
    }

    open func connect(_ peripheral: CBPeripheral, options: [String : Any]? = nil) {
        guard hasPermission(android.Manifest.permission.BLUETOOTH_CONNECT) else {
            logger.error("CBCentralManager.connect: Missing BLUETOOTH_CONNECT permission.")
            return
        }
        guard let device = peripheral.device else {
            logger.error("CBCentralManager.connect: Peripheral has no device.")
            return
        }

        logger.log("CBCentralManager.connect: Connecting to \(peripheral.device)")
        tryConnect(to: device)
    }
    
    open func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        guard let address = peripheral.address else {
            logger.warning("CBCentralManager.cancelPeripheralConnection: Peripheral has no address")
            return
        }

        logger.debug("CBCentralManager.cancelPeripheralConnection: Disconnecting \(address)")

        // Use the stored GATT if available, fallback to peripheral's gatt
        if let gatt = connectedGatts[address] {
            gatt.disconnect()
            gatt.close()
        } else if let gatt = peripheral.gatt {
            gatt.disconnect()
            gatt.close()
        }

        // Clean up tracking state
        connectedDeviceAddresses.remove(address)
        connectedPeripherals.removeValue(forKey: address)
        connectedGatts.removeValue(forKey: address)
    }

    @available(*, unavailable)
    open func registerForConnectionEvents(options: [CBConnectionEventMatchingOption : Any]? = nil) { }

    // MARK: NATIVE ANDROID AUXILIARY LOGIC

    private struct BleScanCallback: ScanCallback {
        private let central: CBCentralManager
        var delegate: CBCentralManagerDelegate? {
            didSet {
                delegate?.centralManagerDidUpdateState(central)
            }
        }

        init(central: CBCentralManager) {
            self.central = central
        }

        override func onScanResult(callbackType: Int, result: ScanResult) {
            super.onScanResult(callbackType, result)
            logger.debug("BleScanCallback.onScanResult: \(result.device.name) - \(result.device.address)")

            delegate?.centralManager(central: central, didDiscover: result.toPeripheral(), advertisementData: result.advertisementData, rssi: NSNumber(value: result.rssi))
        }

        @available(*, unavailable)
        override func onBatchScanResults(results: List<ScanResult>) {
            super.onBatchScanResults(results)
            for result in results {
                logger.debug("BleScanCallback.onBatchScanResults: \(result.device.name) - \(result.device.address)")
            }
        }

        override func onScanFailed(errorCode: Int) {
            super.onScanFailed(errorCode)
            logger.warning("BleScanCallback.onScanFailed: Scan failed with error: \(errorCode)")
        }
    }

    private class BondCallback: BroadcastReceiver {
        private let completion: (BluetoothDevice) -> Void
        init(completion: @escaping (BluetoothDevice) -> Void) {
            self.completion = completion
        }

        override func onReceive(context: Context?, intent: Intent?) {
            let action = intent?.action
            switch (action) {
            case BluetoothDevice.ACTION_BOND_STATE_CHANGED:
                // Use version-appropriate API for getParcelableExtra
                let device: BluetoothDevice?
                if Build.VERSION.SDK_INT >= 33 {
                    device = intent?.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice.self.java)
                } else {
                    // Deprecated but required for API < 33
                    device = intent?.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE) as? BluetoothDevice
                }
                let bondState = intent?.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
                switch (bondState) {
                case BluetoothDevice.BOND_BONDED:
                    guard let device = device else {
                        logger.error("BondCallback.onReceive: Device is nil")
                        return
                    }

                    logger.debug("StateChangedReceiver: Bonded with \(device?.name ?? "nil")")
                    completion(device)
                    break
                case BluetoothDevice.BOND_BONDING:
                    logger.debug("StateChangedReceiver: Bonding in progress.")
                    break
                case BluetoothDevice.BOND_NONE:
                    logger.debug("StateChangedReceiver: Bonding failed or broken")
                    break
                default:
                    break
                }
            }
        }
    }
}

// MARK: Private functions
extension CBCentralManager {
    func tryConnect(to device: BluetoothDevice) {
        let deviceAddress = device.address

        // Prevent duplicate connection attempts to the same device
        // This commonly happens when bonding completes and the broadcast fires multiple times
        if connectedDeviceAddresses.contains(deviceAddress) {
            logger.debug("CBCentralManager.tryConnect: Already connected/connecting to \(deviceAddress), skipping")
            return
        }

        logger.log("CBCentralManager.connect: connecting to \(deviceAddress)")
        connectedDeviceAddresses.insert(deviceAddress)
        let gatt = device.connectGatt(context, false, gattDelegate, BluetoothDevice.TRANSPORT_LE)
        connectedGatts[deviceAddress] = gatt
    }

    /// Register a peripheral when connection succeeds (called by BleGattCallback)
    func registerConnectedPeripheral(_ peripheral: CBPeripheral, for address: String) {
        connectedPeripherals[address] = peripheral
    }

    /// Look up a peripheral by device address (called by BleGattCallback)
    func getPeripheral(for address: String) -> CBPeripheral? {
        return connectedPeripherals[address]
    }

    /// Clear connection state for a specific device or all devices
    /// - Parameter address: The device address to clear, or nil to clear all devices
    public func clearConnectedDevice(address: String? = nil) {
        if let address = address {
            // Clear specific device
            logger.debug("CBCentralManager.clearConnectedDevice: clearing address \(address)")
            connectedDeviceAddresses.remove(address)
            connectedPeripherals.removeValue(forKey: address)

            if let gatt = connectedGatts.removeValue(forKey: address) {
                logger.debug("CBCentralManager.clearConnectedDevice: closing GATT for \(address)")
                gatt.disconnect()
                gatt.close()
            }
        } else {
            // Clear all devices
            logger.debug("CBCentralManager.clearConnectedDevice: clearing all \(connectedDeviceAddresses.count) devices")
            for (address, gatt) in connectedGatts {
                logger.debug("CBCentralManager.clearConnectedDevice: closing GATT for \(address)")
                gatt.disconnect()
                gatt.close()
            }
            connectedDeviceAddresses.removeAll()
            connectedPeripherals.removeAll()
            connectedGatts.removeAll()
        }
    }
}

extension CBCentralManager {
    public struct Feature : OptionSet, @unchecked Sendable {
        public let rawValue: UInt

        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }

        @available(*, unavailable)
        public static var extendedScanAndConnect: CBCentralManager.Feature { fatalError() }
    }
}

public protocol CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager)

    @available(*, unavailable)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any])
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber)

    func centralManagerDidConnect(central: CBCentralManager, peripheral: CBPeripheral)

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?)
    func centralManagerDidDisconnectPeripheral(_ central: CBCentralManager, peripheral: CBPeripheral, error: (any Error)?)

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?)
    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral)

    @available(*, unavailable)
    func centralManagerDidUpdateANCSAuthorizationFor(central: CBCentralManager, peripheral: CBPeripheral)
}

extension CBCentralManagerDelegate {
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) { return }
    @available(*, unavailable)
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {}
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) { return }
    public func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) { return }
    public func centralManagerDidConnect(central: CBCentralManager, peripheral: CBPeripheral) { return }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) { return }
    @available(*, unavailable)
    public func centralManagerDidUpdateANCSAuthorizationFor(central: CBCentralManager, peripheral: CBPeripheral) { return }
    public func centralManagerDidDisconnectPeripheral(_ central: CBCentralManager, peripheral: CBPeripheral, error: (any Error)?) { }
}

#endif
#endif

