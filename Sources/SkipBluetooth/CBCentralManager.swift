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

    /// Tracks discovered device addresses when allowDuplicates is false.
    private var discoveredAddresses: Set<String> = []
    /// Whether to suppress duplicate scan results (mirrors iOS allowDuplicates: false).
    private var suppressDuplicates: Bool = false

    private lazy var bondingReceiver: BondCallback! = BondCallback(
        completion: { device in
            self.onDeviceBonded(device)
        },
        bondFailed: { device, wasBonding in
            self.onDeviceBondFailed(device, wasBonding: wasBonding)
        })

    // Support multiple simultaneous connections
    // Maps device address to its BluetoothGatt connection
    private var connectedGatts: [String: BluetoothGatt] = [:]

    // Maps device address to its CBPeripheral for callback lookups
    private var connectedPeripherals: [String: CBPeripheral] = [:]

    // Track device addresses we're currently connected/connecting to
    // This prevents multiple reconnection attempts after bonding
    private var connectedDeviceAddresses: Set<String> = []

    // BLE-audit F1: the four collections above are read on Android binder threads
    // (every GATT callback runs `central.getPeripheral(...)` BEFORE its main-actor hop)
    // and mutated from both binder + main threads. With >1 sensor connected Android
    // delivers callbacks on independent binder threads → unsynchronized concurrent
    // access = ConcurrentModificationException / lost-update, and a dropped lookup is a
    // dropped power/HR/cadence sample. Serialize ALL access through this lock. Discipline:
    // never hold it across a re-entrant callout (no locked method calls another), and
    // keep `connectGatt`/`close` outside the critical section.
    internal let stateLock = NSLock()

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

        bondingReceiver = BondCallback(
            completion: { device in
                self.onDeviceBonded(device)
            },
            bondFailed: { device, wasBonding in
                self.onDeviceBondFailed(device, wasBonding: wasBonding)
            })

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

        // Always use ALL_MATCHES — FIRST_MATCH returns empty scan records (no name,
        // no service UUIDs, rssi=0) on many Android chipsets. Deduplication for
        // allowDuplicates: false is handled in onScanResult instead, matching iOS behavior.
        let settingsBuilder = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)

        let allowDuplicates = (options?[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool) ?? false
        stateLock.lock()
        suppressDuplicates = !allowDuplicates
        discoveredAddresses.removeAll()
        stateLock.unlock()

        // Android requires one ScanFilter per service UUID — setServiceUuid() overwrites, not appends.
        var scanFilters: [ScanFilter] = []
        if let serviceUUIDs = serviceUUIDs {
            for uuid in serviceUUIDs {
                let filterBuilder = ScanFilter.Builder()
                filterBuilder.setServiceUuid(ParcelUuid(uuid.kotlin()))
                scanFilters.append(filterBuilder.build())
            }
        } else {
            // No filter — scan for all devices
            scanFilters.append(ScanFilter.Builder().build())
        }

        // SKIP NOWARN
        if let uuids = options?[CBCentralManagerScanOptionSolicitedServiceUUIDsKey] as? [CBUUID] {
            for uuid in uuids {
                let filterBuilder = ScanFilter.Builder()
                filterBuilder.setServiceSolicitationUuid(ParcelUuid(uuid.kotlin()))
                scanFilters.append(filterBuilder.build())
            }
        }

        let settings = settingsBuilder.build()

        // SKIP REPLACE: scanner?.startScan(scanFilters.toList(), settings, scanDelegate)
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
        stateLock.lock()
        discoveredAddresses.removeAll()
        stateLock.unlock()
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
        stateLock.lock(); defer { stateLock.unlock() }
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
        stateLock.lock(); defer { stateLock.unlock() }
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

        // Only call disconnect() — do NOT call close() here.
        // close() deregisters the BluetoothGattCallback, preventing the
        // onConnectionStateChange(STATE_DISCONNECTED) callback from firing.
        // close() and tracking cleanup happen in the callback instead.
        stateLock.lock()
        let trackedGatt = connectedGatts[address]
        stateLock.unlock()
        if let gatt = trackedGatt {
            gatt.disconnect()
        } else if let gatt = peripheral.gatt {
            gatt.disconnect()
        }
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
            let address = result.device.address

            // Deduplicate when allowDuplicates is false (mirrors iOS CoreBluetooth behavior)
            if central.suppressDuplicates {
                central.stateLock.lock()
                let alreadySeen = central.discoveredAddresses.contains(address)
                if !alreadySeen { central.discoveredAddresses.insert(address) }
                central.stateLock.unlock()
                if alreadySeen { return }
            }

            // Deliver through the shared FIFO pipeline, not synchronously: CoreBluetooth delivers
            // scan results on the same serial queue as every other delegate callback, so a
            // didDiscover must stay ordered relative to connection/value callouts.
            let scanDelegate = self.delegate
            let scanCentral = self.central
            let discovered = result.toPeripheral()
            let advertisementData = result.advertisementData
            let rssi = NSNumber(value: result.rssi)
            BleCallbackPipeline.shared.dispatch {
                scanDelegate?.centralManager(central: scanCentral, didDiscover: discovered, advertisementData: advertisementData, rssi: rssi)
            }
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
        /// Bonding ended without a bond. `wasBonding` distinguishes a pairing
        /// that just failed (cancelled PIN, timeout, refusal) from an unbond of
        /// a device that was already paired.
        private let bondFailed: (BluetoothDevice, Bool) -> Void
        init(completion: @escaping (BluetoothDevice) -> Void,
             bondFailed: @escaping (BluetoothDevice, Bool) -> Void) {
            self.completion = completion
            self.bondFailed = bondFailed
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
                    guard let device = device else {
                        logger.error("BondCallback.onReceive: Device is nil")
                        return
                    }
                    let previous = intent?.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE,
                                                       BluetoothDevice.ERROR)
                    bondFailed(device, previous == BluetoothDevice.BOND_BONDING)
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
        // This commonly happens when bonding completes and the broadcast fires multiple times.
        // BLE-audit F1: atomic check-and-claim so a double-fired bond broadcast on two
        // threads can't both pass the guard and connectGatt twice.
        stateLock.lock()
        if connectedDeviceAddresses.contains(deviceAddress) {
            stateLock.unlock()
            logger.debug("CBCentralManager.tryConnect: Already connected/connecting to \(deviceAddress), skipping")
            return
        }
        connectedDeviceAddresses.insert(deviceAddress)
        stateLock.unlock()

        logger.log("CBCentralManager.connect: connecting to \(deviceAddress)")
        let gatt = device.connectGatt(context, false, gattDelegate, BluetoothDevice.TRANSPORT_LE)
        stateLock.lock()
        connectedGatts[deviceAddress] = gatt
        stateLock.unlock()
    }

    /// Register a peripheral when connection succeeds (called by BleGattCallback)
    func registerConnectedPeripheral(_ peripheral: CBPeripheral, for address: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        connectedPeripherals[address] = peripheral
    }

    /// Look up a peripheral by device address (called by BleGattCallback, on a binder thread)
    /// Bonding succeeded: connect if this bond was what we were waiting on, and
    /// replay any ATT operations the peer had answered with the pairing prompt.
    func onDeviceBonded(_ device: BluetoothDevice) {
        getPeripheral(for: device.address)?.resumeOperationsAwaitingBond()
        tryConnect(to: device)
    }

    /// Bonding ended without a bond. When it followed `BOND_BONDING` the
    /// pairing itself failed (cancelled PIN, timeout, refusal), which is what
    /// CoreBluetooth reports as `CBATTError.insufficientAuthentication` on the
    /// operation that triggered it — so fail the held operations rather than
    /// leaving the caller waiting for a callback that can never arrive.
    func onDeviceBondFailed(_ device: BluetoothDevice, wasBonding: Bool) {
        guard wasBonding else { return }
        getPeripheral(for: device.address)?.failOperationsAwaitingBond()
    }

    func getPeripheral(for address: String) -> CBPeripheral? {
        stateLock.lock(); defer { stateLock.unlock() }
        return connectedPeripherals[address]
    }

    /// Clear connection state for a specific device or all devices
    /// - Parameter address: The device address to clear, or nil to clear all devices
    public func clearConnectedDevice(address: String? = nil) {
        // BLE-audit F1: atomic multi-collection clear under the lock. The gatt
        // disconnect()/close() calls below don't re-enter (Android fires their callbacks
        // asynchronously on a binder thread), so holding the lock across them is safe.
        stateLock.lock(); defer { stateLock.unlock() }
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

