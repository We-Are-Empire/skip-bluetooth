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
    /// Whether an LE scan this central started is still running, and with which filter. Guarded
    /// by `stateLock`.
    internal var scanGate = ScanStartGate()

    private lazy var bondingReceiver: BondCallback! = BondCallback(
        completion: { device in
            self.onDeviceBonded(device)
        },
        bondFailed: { device, wasBonding in
            self.onDeviceBondFailed(device, wasBonding: wasBonding)
        },
        bondLost: { device in
            self.onDeviceBondLost(device)
        })

    /// Receives `ACTION_KEY_MISSING` (API 36). Registered on its own, exported: the broadcast
    /// comes from the Bluetooth stack's process, not this app's.
    private var bondLossReceiver: BondCallback? = nil

    // Support multiple simultaneous connections
    // Maps device address to its BluetoothGatt connection
    private var connectedGatts: [String: BluetoothGatt] = [:]

    // Maps device address to its CBPeripheral for callback lookups
    private var connectedPeripherals: [String: CBPeripheral] = [:]

    // Track device addresses we're currently connected/connecting to
    // This prevents multiple reconnection attempts after bonding
    private var connectedDeviceAddresses: Set<String> = []

    // Addresses a caller asked to connect to, from `connect` until that
    // connection is cancelled or ends. A bond completing for any other
    // address opens no connection: nobody is waiting for it.
    private var requestedConnectAddresses: Set<String> = []

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
            // A radio leaving the powered-on state ends the scan without a callback, so the next
            // request after power-on has to start one. Recorded before the delegate hears the
            // change, because the delegate is what asks for the scan again.
            if self.state != CBManagerState.poweredOn {
                self.stateLock.lock()
                self.scanGate.scanEnded()
                self.stateLock.unlock()
            }
            delegate?.centralManagerDidUpdateState(self)
        }

        bondingReceiver = BondCallback(
            completion: { device in
                self.onDeviceBonded(device)
            },
            bondFailed: { device, wasBonding in
                self.onDeviceBondFailed(device, wasBonding: wasBonding)
            },
            bondLost: { device in
                self.onDeviceBondLost(device)
            })

        let filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        let context = ProcessInfo.processInfo.androidContext
        context.registerReceiver(bondingReceiver, filter)

        // A device that no longer holds this phone's bond keys fails its connection with an
        // ordinary status; the stack announces the loss only in this broadcast. It is sent to
        // holders of BLUETOOTH_CONNECT, the permission every connect here already needs, so a
        // permission granted after launch still receives it.
        if Build.VERSION.SDK_INT >= 36 {
            let lossReceiver = BondCallback(
                completion: { _ in },
                bondFailed: { _, _ in },
                bondLost: { device in
                    self.onDeviceBondLost(device)
                })
            bondLossReceiver = lossReceiver
            let keyMissingFilter = IntentFilter(BondBroadcastClassifier.actionKeyMissing)
            context.registerReceiver(lossReceiver, keyMissingFilter, Context.RECEIVER_EXPORTED)
            if !hasPermission(android.Manifest.permission.BLUETOOTH_CONNECT) {
                logger.info("CBCentralManager: BLUETOOTH_CONNECT is not granted yet; key-missing broadcasts arrive once it is")
            }
        }

        // Android leaves a GATT client open when the app process ends; iOS does
        // not. See `ProcessTerminationCleanup`.
        ProcessTerminationCleanup.shared.register(self)
    }

    deinit {
        ProcessTerminationCleanup.shared.unregister(self)
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
        // The filter as the scan gate compares it: service UUIDs, then solicitation UUIDs.
        var filterKey: [String] = []
        if let serviceUUIDs = serviceUUIDs {
            for uuid in serviceUUIDs {
                let filterBuilder = ScanFilter.Builder()
                filterBuilder.setServiceUuid(ParcelUuid(uuid.kotlin()))
                scanFilters.append(filterBuilder.build())
                filterKey.append("service:" + uuid.uuidString)
            }
        } else {
            // No filter — scan for all devices
            scanFilters.append(ScanFilter.Builder().build())
            filterKey.append("all")
        }

        // SKIP NOWARN
        if let uuids = options?[CBCentralManagerScanOptionSolicitedServiceUUIDsKey] as? [CBUUID] {
            for uuid in uuids {
                let filterBuilder = ScanFilter.Builder()
                filterBuilder.setServiceSolicitationUuid(ParcelUuid(uuid.kotlin()))
                scanFilters.append(filterBuilder.build())
                filterKey.append("solicited:" + uuid.uuidString)
            }
        }

        // A request for the scan that is already running starts nothing: Android counts every
        // startScan against five per 30 s and returns nothing after that. See `ScanStartGate`.
        stateLock.lock()
        let decision = scanGate.request(filter: filterKey)
        stateLock.unlock()
        switch decision {
        case .keepRunning:
            logger.debug("CBCentralManager.scanForPeripherals: the scan is already running with this filter")
            return
        case .restart:
            scanner?.stopScan(scanDelegate)
        case .start:
            break
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
        scanGate.scanEnded()
        discoveredAddresses.removeAll()
        stateLock.unlock()
    }

    @available(*, unavailable)
    open class func supports(_ features: CBCentralManager.Feature) -> Bool { fatalError() }

    /// Returns peripherals that match the specified identifiers, whether or
    /// not they are advertising.
    ///
    /// This is the route to a peripheral no scan can produce. A connected LE
    /// peripheral stops advertising, and the link that silences it may be one
    /// the system holds rather than ours — Android's ACL is shared between
    /// every GATT client and server on the phone, so a device can sit
    /// connected, invisible to scanning, after this app has released its own
    /// client. Bonded devices and system-wide GATT connections are both
    /// addressable without a sighting, and a `CBPeripheral`'s identifier is
    /// derived from its address, so an identifier resolves back to a device
    /// with no radio work at all.
    ///
    /// - Parameter identifiers: Peripheral identifiers (UUIDs derived from the device address).
    /// - Returns: The peripherals found, in the order asked for. Identifiers
    ///   the system does not know are absent, so the result may be shorter
    ///   than the request.
    open func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] {
        guard !identifiers.isEmpty else { return [] }
        let wanted = Set(identifiers)
        var found: [UUID: CBPeripheral] = [:]

        // Ours first: a live peripheral carries its GATT and its discovered
        // services, which a freshly built one does not.
        stateLock.lock()
        for peripheral in connectedPeripherals.values {
            if wanted.contains(peripheral.identifier) {
                found[peripheral.identifier] = peripheral
            }
        }
        stateLock.unlock()

        for device in systemConnectedDevices() {
            record(device, wanted: wanted, into: &found)
        }
        if found.count < wanted.count {
            for device in systemBondedLEDevices() {
                record(device, wanted: wanted, into: &found)
            }
        }

        return identifiers.compactMap { found[$0] }
    }

    /// Returns the LE peripherals the phone currently holds a connection to —
    /// including connections opened by other apps and by the system's own
    /// GATT server profiles, which is what CoreBluetooth reports on iOS.
    ///
    /// - Parameter serviceUUIDs: Services to filter by. A peripheral this app
    ///   has connected to is kept only when its discovered services match. A
    ///   peripheral held by someone else publishes no service list to us, and
    ///   is kept rather than guessed away: it may well be the camera the
    ///   caller is looking for. Pass an empty list to skip filtering.
    open func retrieveConnectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [CBPeripheral] {
        stateLock.lock()
        let ours = Array(connectedPeripherals.values)
        stateLock.unlock()

        var byIdentifier: [UUID: CBPeripheral] = [:]
        for peripheral in ours {
            byIdentifier[peripheral.identifier] = peripheral
        }
        for device in systemConnectedDevices() {
            let peripheral = CBPeripheral(device: device)
            if byIdentifier[peripheral.identifier] == nil {
                byIdentifier[peripheral.identifier] = peripheral
            }
        }

        let peripherals = Array(byIdentifier.values)
        guard !serviceUUIDs.isEmpty else { return peripherals }

        let serviceUUIDStrings = Set(serviceUUIDs.map { $0.uuidString })
        return peripherals.filter { peripheral in
            guard let services = peripheral.services else { return true }
            return services.contains { serviceUUIDStrings.contains($0.uuid.uuidString) }
        }
    }

    /// Keep a device only when it is one of the identifiers asked for, and
    /// never over an entry a live peripheral already filled.
    private func record(_ device: BluetoothDevice,
                        wanted: Set<UUID>,
                        into found: inout [UUID: CBPeripheral]) {
        let peripheral = CBPeripheral(device: device)
        guard wanted.contains(peripheral.identifier), found[peripheral.identifier] == nil else {
            return
        }
        found[peripheral.identifier] = peripheral
    }

    /// Every LE device the system can name without a scan: the ones it is
    /// connected to right now (any app, any profile) and the ones bonded to
    /// this phone. Classic-only bonds are left out — they are not peripherals.
    private func systemKnownDevices() -> [BluetoothDevice] {
        var devices = systemConnectedDevices()
        var seen = Set(devices.map { $0.address })

        for device in systemBondedLEDevices() {
            guard !seen.contains(device.address) else { continue }
            seen.insert(device.address)
            devices.append(device)
        }
        return devices
    }

    /// The LE devices the phone is connected to right now — any app, any
    /// profile, including the system's own GATT server. This is what
    /// CoreBluetooth reports on iOS, and the reason a camera nobody in this
    /// app is talking to can still be addressable.
    private func systemConnectedDevices() -> [BluetoothDevice] {
        guard hasPermission(android.Manifest.permission.BLUETOOTH_CONNECT) else {
            logger.error("CBCentralManager.systemConnectedDevices: Missing BLUETOOTH_CONNECT permission.")
            return []
        }
        guard let connected = bluetoothManager?.getConnectedDevices(BluetoothProfile.GATT) else {
            return []
        }
        var devices: [BluetoothDevice] = []
        for device in connected {
            devices.append(device)
        }
        return devices
    }

    /// The LE devices bonded to this phone. Classic-only bonds are left out —
    /// they are not peripherals.
    private func systemBondedLEDevices() -> [BluetoothDevice] {
        guard hasPermission(android.Manifest.permission.BLUETOOTH_CONNECT) else {
            logger.error("CBCentralManager.systemBondedLEDevices: Missing BLUETOOTH_CONNECT permission.")
            return []
        }
        guard let bonded = adapter?.getBondedDevices() else { return [] }
        var devices: [BluetoothDevice] = []
        for device in bonded where device.type != BluetoothDevice.DEVICE_TYPE_CLASSIC {
            devices.append(device)
        }
        return devices
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
        stateLock.lock()
        requestedConnectAddresses.insert(device.address)
        stateLock.unlock()
        tryConnect(to: device)
    }
    
    open func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        guard let address = peripheral.address else {
            logger.warning("CBCentralManager.cancelPeripheralConnection: Peripheral has no address")
            return
        }

        // A connect that never reached STATE_CONNECTED is cancelled, not
        // disconnected, and Android reports no state change for a cancelled
        // connect: the onConnectionStateChange that closes the client and
        // clears this tracking can never run. Release it here instead, or the
        // GATT client stays registered for the life of the process and the
        // address stays in `connectedDeviceAddresses`, where `tryConnect`
        // reads it as "already connecting" and silently skips every later
        // connect to that camera. Held under one lock so a CONNECTED callback
        // racing in (it takes the same lock in `registerConnectedPeripheral`)
        // either lands first and gets the disconnect path below, or lands
        // after the close that deregisters it.
        stateLock.lock()
        requestedConnectAddresses.remove(address)
        let trackedGatt = connectedGatts[address]
        let isEstablished = connectedPeripherals[address] != nil
        if !isEstablished, let pendingGatt = trackedGatt {
            logger.debug("CBCentralManager.cancelPeripheralConnection: Cancelling pending connect to \(address)")
            connectedGatts.removeValue(forKey: address)
            connectedDeviceAddresses.remove(address)
            pendingGatt.disconnect()
            pendingGatt.close()
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        logger.debug("CBCentralManager.cancelPeripheralConnection: Disconnecting \(address)")

        // Established link: only call disconnect() — do NOT call close() here.
        // close() deregisters the BluetoothGattCallback, preventing the
        // onConnectionStateChange(STATE_DISCONNECTED) callback from firing.
        // close() and tracking cleanup happen in the callback instead.
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
            // No scan is running after a failure, so the next request starts one.
            central.stateLock.lock()
            central.scanGate.scanEnded()
            central.stateLock.unlock()
        }
    }

    private class BondCallback: BroadcastReceiver {
        private let completion: (BluetoothDevice) -> Void
        /// Bonding ended without a bond. `wasBonding` distinguishes a pairing
        /// that just failed (cancelled PIN, timeout, refusal) from an unbond of
        /// a device that was already paired.
        private let bondFailed: (BluetoothDevice, Bool) -> Void
        /// The device no longer holds this phone's bond keys (`ACTION_KEY_MISSING`).
        private let bondLost: (BluetoothDevice) -> Void
        init(completion: @escaping (BluetoothDevice) -> Void,
             bondFailed: @escaping (BluetoothDevice, Bool) -> Void,
             bondLost: @escaping (BluetoothDevice) -> Void) {
            self.completion = completion
            self.bondFailed = bondFailed
            self.bondLost = bondLost
        }

        override func onReceive(context: Context?, intent: Intent?) {
            let action = intent?.action
            // Use version-appropriate API for getParcelableExtra
            let device: BluetoothDevice?
            if Build.VERSION.SDK_INT >= 33 {
                device = intent?.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice.self.java)
            } else {
                // Deprecated but required for API < 33
                device = intent?.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE) as? BluetoothDevice
            }
            guard let device = device else {
                logger.error("BondCallback.onReceive: Device is nil for \(action ?? "nil")")
                return
            }

            let bondState: Int
            let previousBondState: Int
            if action == BondBroadcastClassifier.actionKeyMissing {
                bondState = device.bondState
                previousBondState = BluetoothDevice.ERROR
            } else {
                bondState = intent?.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR) ?? BluetoothDevice.ERROR
                previousBondState = intent?.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR) ?? BluetoothDevice.ERROR
            }

            switch BondBroadcastClassifier.classify(action: action, bondState: bondState, previousBondState: previousBondState) {
            case .bonded:
                logger.debug("StateChangedReceiver: Bonded with \(device.name ?? "nil")")
                completion(device)
            case .bonding:
                logger.debug("StateChangedReceiver: Bonding in progress.")
            case .pairingCancelled:
                logger.debug("StateChangedReceiver: Bonding failed")
                bondFailed(device, true)
            case .unbonded:
                logger.debug("StateChangedReceiver: Bond removed")
                bondFailed(device, false)
            case .bondLost:
                logger.info("BondCallback.onReceive: key missing for bonded device \(device.address)")
                bondLost(device)
            case .ignored:
                logger.debug("BondCallback.onReceive: ignoring \(action ?? "nil") with bond state \(bondState)")
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
    /// Bonding succeeded: replay any ATT operations the peer had answered with
    /// the pairing prompt, and connect only if a caller's connect to this
    /// device is still outstanding. Android can broadcast `BOND_BONDED` again
    /// for a device whose link has already ended, and a connection opened for
    /// that broadcast belongs to no caller.
    func onDeviceBonded(_ device: BluetoothDevice) {
        getPeripheral(for: device.address)?.resumeOperationsAwaitingBond()
        stateLock.lock()
        let isRequested = requestedConnectAddresses.contains(device.address)
        stateLock.unlock()
        guard isRequested else {
            logger.debug("CBCentralManager.onDeviceBonded: no connect outstanding for \(device.address), not connecting")
            return
        }
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

    /// The device no longer holds this phone's bond keys. CoreBluetooth has no callback for
    /// this: it reports the loss as `peerRemovedPairingInformation` on the failure itself, and
    /// Android reports that failure with an ordinary status, before or after this broadcast.
    /// Delivered through the callback pipeline so it stays ordered with the connection callbacks
    /// a delegate pairs it with.
    func onDeviceBondLost(_ device: BluetoothDevice) {
        let peripheral = getPeripheral(for: device.address) ?? CBPeripheral(device: device)
        BleCallbackPipeline.shared.dispatch {
            self.delegate?.centralManagerDidLoseBond(self, peripheral: peripheral)
        }
    }

    func getPeripheral(for address: String) -> CBPeripheral? {
        stateLock.lock(); defer { stateLock.unlock() }
        return connectedPeripherals[address]
    }

    /// Clear connection state for the connected device whose peripheral
    /// identifier matches, leaving every other connection alone. A caller
    /// holding an identifier rather than a MAC address (the wrapper's public
    /// surface is identifier-keyed) needs this to name one device: clearing
    /// "all" to reach one closes every other camera's GATT client behind its
    /// owner's back, and closing deregisters the callback, so nobody is ever
    /// told the link went away.
    /// - Returns: true when a matching connection was found and cleared.
    @discardableResult
    public func clearConnectedDevice(peripheralIdentifier: String) -> Bool {
        stateLock.lock()
        var match: String? = nil
        for (address, peripheral) in connectedPeripherals {
            if peripheral.identifier.uuidString == peripheralIdentifier {
                match = address
                break
            }
        }
        stateLock.unlock()

        guard let address = match else { return false }
        clearConnectedDevice(address: address)
        return true
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
            requestedConnectAddresses.remove(address)
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
            requestedConnectAddresses.removeAll()
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

    /// Android only: the peripheral no longer holds this phone's bond keys (`ACTION_KEY_MISSING`,
    /// API 36). CoreBluetooth folds the same fact into `peerRemovedPairingInformation`.
    func centralManagerDidLoseBond(_ central: CBCentralManager, peripheral: CBPeripheral)

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
    public func centralManagerDidLoseBond(_ central: CBCentralManager, peripheral: CBPeripheral) { }
}

#endif
#endif

