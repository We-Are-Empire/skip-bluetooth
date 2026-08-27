// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

#if SKIP
import android.content.pm.PackageManager
import android.bluetooth.BluetoothDevice
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

// MARK: CoreBluetooth error parity

/// userInfo key carrying the original Android GATT status.
internal let kGATTStatusKey = "SkipBluetoothGATTStatus"

/// An ATT-context failure — a GATT operation callback (`onServicesDiscovered`,
/// `onCharacteristicRead`, and friends).
///
/// Android's ATT statuses are 0x01...0x11 and match `CBATTError` one for one
/// (5 insufficient authentication, 15 insufficient encryption, 14 unlikely
/// error), so the value carries over and only the domain changes. Anything
/// outside that range is a connection-level status.
internal func attParityError(status: Int, message: String? = nil) -> NSError {
    if status >= 1 && status <= 17 {
        var userInfo: [String: Any] = [kGATTStatusKey: status]
        // Always describe the status: it is the only copy that reaches logs and
        // any caller still parsing the message rather than the code.
        userInfo[NSLocalizedDescriptionKey] = message ?? "Bluetooth ATT failure (GATT status \(status))"
        return NSError(domain: "CBATTErrorDomain", code: status, userInfo: userInfo)
    }
    return connectionParityError(status: status, message: message)
}

/// Whether Android still holds a bond for this device.
///
/// The discriminator CoreBluetooth gets for free and Android does not: an
/// authentication failure means "the peer dropped our key" when we are still
/// bonded, and "pairing never completed" (cancelled PIN, timeout) when we are
/// not. Without it, both look identical and the user gets told to forget a
/// camera they merely declined to pair with.
internal func isDeviceBonded(_ gatt: BluetoothGatt) -> Bool {
    return gatt.device.bondState == BluetoothDevice.BOND_BONDED
}

/// What an ATT operation callback should do with its status.
internal enum ATTOutcome {
    /// Deliver the value/completion with no error.
    case success
    /// Deliver this error to the delegate.
    case failure(NSError)
    /// Deliver nothing yet: the peer is asking to pair. The operation is held
    /// and replayed once the bond resolves.
    case awaitBond
}

/// Classify an ATT operation status, taking the bond state into account.
///
/// An encrypted characteristic answers `GATT_INSUFFICIENT_AUTHENTICATION` (5)
/// or `GATT_INSUFFICIENT_ENCRYPTION` (15) until a bond exists. On a device that
/// is not bonded yet that is the expected first step of pairing, and
/// CoreBluetooth delivers *nothing* to the delegate while pairing is in flight
/// — then exactly one callback once it settles. `.awaitBond` reproduces that:
/// delivering an error here declares a failure mid-pairing, and delivering a
/// success here fabricates a value the peer never sent.
///
/// The same statuses on an already-bonded device mean the opposite: the bond we
/// hold is no longer accepted, which is the stale-bond case worth surfacing.
///
/// - Important: call this on the thread the GATT callback arrived on, before
///   hopping to the delivery pipeline. `bondState` is live, and fast "Just
///   Works" bonding can complete during the hop — reading it late would
///   reclassify a pre-bond prompt as a stale-bond failure.
internal func attOutcome(status: Int, gatt: BluetoothGatt, message: String? = nil) -> ATTOutcome {
    if status == BluetoothGatt.GATT_SUCCESS { return .success }
    if (status == 5 || status == 15) && !isDeviceBonded(gatt) { return .awaitBond }
    return .failure(attParityError(status: status, message: message))
}

/// A connection failure classified with the bond state taken into account.
///
/// Stays in `CBErrorDomain`: CoreBluetooth documents the
/// `centralManager(_:didFailToConnect:error:)` error as a `CBError`, and never
/// delivers a `CBATTError` there — authentication surfaces on iOS as an ATT
/// failure on the first secure operation, not as a connect failure.
internal func connectionFailureError(status: Int, gatt: BluetoothGatt, message: String? = nil) -> NSError {
    let isAuthFailure = (status == 5 || status == 6 || status == 61 || status == 137)
    if isAuthFailure && !isDeviceBonded(gatt) {
        // Never bonded: the pairing was cancelled, timed out, or was refused —
        // not a bond the peer removed. `connectionFailed` says "this attempt
        // did not succeed, try again" without asserting a stale bond.
        return connectionError(code: 10, status: status,
                               message: message ?? "Pairing was not completed")
    }
    return connectionParityError(status: status, message: message)
}

/// A connection-context failure (`onConnectionStateChange`), whose statuses
/// share no numbering with CoreBluetooth and so are mapped explicitly.
///
/// Codes are `CBError`: 6 connectionTimeout, 7 peripheralDisconnected,
/// 10 connectionFailed (the default), 14 peerRemovedPairingInformation.
internal func connectionError(code: Int, status: Int, message: String) -> NSError {
    var userInfo: [String: Any] = [kGATTStatusKey: status]
    userInfo[NSLocalizedDescriptionKey] = message
    return NSError(domain: "CBErrorDomain", code: code, userInfo: userInfo)
}

internal func connectionParityError(status: Int, message: String? = nil) -> NSError {
    var code = 10
    if status == 5 || status == 6 || status == 61 || status == 137 {
        // The peer rejected or no longer holds our link key: HCI authentication
        // failure (5), PIN-or-key-missing (6), MIC failure (61), GATT_AUTH_FAIL
        // (137). CoreBluetooth reports the same dead end as
        // peerRemovedPairingInformation, which is what tells a caller to prompt
        // for a re-pair instead of silently retrying.
        code = 14
    } else if status == 8 || status == 34 {
        code = 6
    } else if status == 19 || status == 22 {
        code = 7
    }
    // Everything else, 62 (failed to establish) and 133 (generic GATT error)
    // included, keeps the `connectionFailed` default. Neither is conclusive on
    // its own — a stale bond often surfaces as 133 too — so callers that care
    // must consult the bond state rather than the status alone.
    return connectionError(code: code, status: status,
                           message: message ?? "Bluetooth failure (GATT status \(status))")
}

// MARK: Serial delegate-callback delivery (CoreBluetooth parity)

/// A delegate callout queued for serial main-actor delivery.
/// (A concrete class element rather than `AsyncStream<() -> Void>` — concrete element types
/// are the transpile-proven `AsyncStream` shape.)
internal final class BleCallout {
    let body: () -> Void
    init(_ body: @escaping () -> Void) {
        self.body = body
    }
}

/// A single serial FIFO pipeline that delivers ALL BLE delegate callbacks on the main actor.
///
/// iOS CoreBluetooth delivers every `CBCentralManagerDelegate`/`CBPeripheralDelegate` callback on
/// ONE serial queue, so callbacks can never overtake each other. Spawning an independent
/// unstructured `Task { @MainActor }` per Android GATT/scan callback (the previous approach here)
/// gives NO ordering guarantee between tasks — back-to-back notifications could be delivered
/// reordered or bursty, which measurably corrupted recorded power averages. Funneling every
/// delegate callout through this one unbounded channel restores CoreBluetooth-parity serial FIFO
/// delivery:
/// - Producers are Android binder threads. Callbacks for a single `BluetoothGatt` are serialized
///   by Android, but different devices deliver on independent binder threads, so `dispatch(_:)`
///   takes a dedicated lock around the enqueue to make the cross-thread enqueue order total and
///   well-defined. `yield` itself is a synchronous, non-blocking, order-preserving channel send.
///   (A dedicated lock, not `CBCentralManager.stateLock`: the pipeline is process-global and
///   must not couple to any one manager's lock discipline.)
/// - One long-lived consumer task executes the callouts on the main actor, strictly in enqueue
///   order, for the lifetime of the process.
internal final class BleCallbackPipeline {
    static let shared = BleCallbackPipeline()

    private let lock = NSLock()
    private let enqueue: (BleCallout) -> Void

    private init() {
        let (stream, continuation) = AsyncStream.makeStream(of: BleCallout.self)
        self.enqueue = { callout in continuation.yield(callout) }
        Task { @MainActor in
            for await callout in stream {
                callout.body()
            }
        }
    }

    /// Enqueues a delegate callout for in-order delivery on the main actor.
    func dispatch(_ block: @escaping () -> Void) {
        lock.lock()
        enqueue(BleCallout(block))
        lock.unlock()
    }
}

/// Handles behavior for calling `CBCentralManagerDelegate`and `CBPeripheralDelegate` callbacks after a connection has been established.
///
/// All delegate callbacks are funneled through `BleCallbackPipeline` for serial, in-order
/// delivery on the main actor, matching iOS CoreBluetooth's single serial delegate queue.
/// Android GATT callbacks fire on a binder thread — direct access to main-actor-isolated state
/// from a binder thread causes a libdispatch assertion crash.
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
                BleCallbackPipeline.shared.dispatch {
                    self.centralManagerDelegate?.centralManagerDidConnect(self.central, peripheral)
                }
            } else {
                logger.debug("GattCallback.onConnectionStateChange: Disconnected from \(deviceAddress)")
                let peripheral = central.getPeripheral(for: deviceAddress) ?? CBPeripheral(gatt: gatt, gattDelegate: self)
                central.clearConnectedDevice(address: deviceAddress)
                gatt.close()
                BleCallbackPipeline.shared.dispatch {
                    self.centralManagerDelegate?.centralManagerDidDisconnectPeripheral(self.central, peripheral, nil)
                }
            }
        } else {
            logger.debug("GattCallback.onConnectionStateChange: Failed for \(deviceAddress), status: \(status)")
            let peripheral = central.getPeripheral(for: deviceAddress) ?? CBPeripheral(gatt: gatt, gattDelegate: self)
            central.clearConnectedDevice(address: deviceAddress)
            gatt.close()
            let error = connectionFailureError(status: status, gatt: gatt, message: "Central manager failed to connect. Status: \(status)")
            BleCallbackPipeline.shared.dispatch {
                self.centralManagerDelegate?.centralManager(self.central, didFailToConnect: peripheral, error: error)
            }
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
            BleCallbackPipeline.shared.dispatch {
                peripheral.delegate?.peripheral(peripheral, nil)
            }
        } else {
            logger.debug("BleGattCallback.onServicesDiscovered: failed to discover services for \(address)")
            let error = attParityError(status: state)
            BleCallbackPipeline.shared.dispatch {
                peripheral.delegate?.peripheral(peripheral: peripheral, didDiscoverServices: error)
            }
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
        let cbCharacteristic = CBCharacteristic(platformValue: characteristic, value: Data(value))
        logger.debug("BluetoothGattCallback.onCharacteristicRead: Characteristic read \(characteristic.uuid) for \(address)")

        // Classified here, on the callback thread: `bondState` is live (see
        // `attOutcome`). Any non-success status is a failed read — not just
        // Apple's 241 — bar the pre-bond prompt, which is held for the bond.
        let outcome = attOutcome(status: state, gatt: gatt)

        BleCallbackPipeline.shared.dispatch {
            switch outcome {
            case .awaitBond:
                // No delegate callback: a read answered with the pairing prompt
                // carries no value, and on API < 33 `characteristic.getValue()`
                // would hand back a stale one. The queue still advances.
                peripheral.deferCurrentOperationUntilBonded()
            case .failure(let readError):
                peripheral.delegate?.peripheralDidUpdateValueFor(
                    peripheral,
                    didUpdateValueFor: cbCharacteristic,
                    error: readError
                )
            case .success:
                peripheral.delegate?.peripheralDidUpdateValueFor(
                    peripheral,
                    didUpdateValueFor: cbCharacteristic,
                    error: nil
                )
            }

            // Signal operation complete to process next queued operation
            peripheral.onOperationComplete()
        }
    }

    override func onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, state: Int) {
        let address = gatt.device.address
        guard let peripheral = central.getPeripheral(for: address) else {
            logger.warning("BluetoothGattCallback.onCharacteristicWrite: No peripheral found for \(address)")
            return
        }

        let cbChar = CBCharacteristic(platformValue: characteristic)
        let outcome = attOutcome(status: state, gatt: gatt, message: "Write to peripheral failed")

        BleCallbackPipeline.shared.dispatch {
            switch outcome {
            case .awaitBond:
                peripheral.deferCurrentOperationUntilBonded()
            case .failure(let error):
                logger.error("BluetoothGattCallback.onCharacteristicWrite: Failed to write to \(address) with error: \(error)")
                peripheral.delegate?.peripheralDidWriteValueFor(peripheral, didWriteValueFor: cbChar, error: error)
            case .success:
                logger.debug("BluetoothGattCallback.onCharacteristicWrite: Successfully wrote to \(address)")
                peripheral.delegate?.peripheralDidWriteValueFor(peripheral, didWriteValueFor: cbChar, error: nil)
            }

            // Signal operation complete to process next queued operation
            peripheral.onOperationComplete()
        }
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

        let readOutcome = attOutcome(status: state, gatt: gatt)
        if case .awaitBond = readOutcome {
            BleCallbackPipeline.shared.dispatch {
                peripheral.deferCurrentOperationUntilBonded()
                peripheral.onOperationComplete()
            }
            return
        }
        if case .failure(let descriptorError) = readOutcome {
            logger.debug("BluetoothGattCallback.onDescriptorRead: Failed to read from \(address)")
            BleCallbackPipeline.shared.dispatch {
                // For non-CCCD descriptors, call the descriptor delegate
                if descriptor.uuid != java.util.UUID.fromString(CCCD) {
                    let cbDescriptor = CBDescriptor(platformValue: descriptor, characteristic: cbCharacteristic)
                    peripheral.delegate?.peripheralDidUpdateValueFor(
                        peripheral,
                        didUpdateValueFor: cbDescriptor,
                        error: descriptorError
                    )
                }
                peripheral.onOperationComplete()
            }
            return
        }

        BleCallbackPipeline.shared.dispatch {
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
    }

    override func onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, state: Int) {
        let address = gatt.device.address
        guard let peripheral = central.getPeripheral(for: address) else {
            logger.warning("BluetoothGattCallback.onDescriptorWrite: No peripheral found for \(address)")
            return
        }

        let cbCharacteristic = CBCharacteristic(platformValue: descriptor.characteristic)
        let writeOutcome = attOutcome(status: state, gatt: gatt)

        BleCallbackPipeline.shared.dispatch {
            if case .awaitBond = writeOutcome {
                // Subscribing to an encrypted characteristic answers with the
                // pairing prompt until the bond exists; held, not failed.
                peripheral.deferCurrentOperationUntilBonded()
                peripheral.onOperationComplete()
                return
            }
            if case .failure(let descriptorError) = writeOutcome {
                logger.debug("BluetoothGattCallback.onDescriptorWrite: Failed to write to \(address)")
                // Call appropriate delegate based on descriptor type
                if descriptor.uuid == java.util.UUID.fromString(CCCD) {
                    peripheral.delegate?.peripheralDidWriteValueFor(peripheral, didWriteValueFor: cbCharacteristic, error: descriptorError)
                } else {
                    let cbDescriptor = CBDescriptor(platformValue: descriptor, characteristic: cbCharacteristic)
                    peripheral.delegate?.peripheralDidWriteValueFor(peripheral, didWriteValueFor: cbDescriptor, error: descriptorError)
                }
                peripheral.onOperationComplete()
                return
            }

            if descriptor.uuid == java.util.UUID.fromString(CCCD) {
                logger.debug("BluetoothGattCallback.onDescriptorWrite: Notification enabled successfully on \(address)")
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
        BleCallbackPipeline.shared.dispatch {
            peripheral.delegate?.peripheralDidUpdateValueFor(
                peripheral,
                didUpdateValueFor: cbCharacteristic,
                error: nil
            )
        }
    }

    override func onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
        let address = gatt.device.address
        guard let peripheral = central.getPeripheral(for: address) else {
            logger.warning("BluetoothGattCallback.onReadRemoteRssi: No peripheral found for \(address)")
            return
        }

        BleCallbackPipeline.shared.dispatch {
            if status == BluetoothGatt.GATT_SUCCESS {
                logger.debug("BluetoothGattCallback.onReadRemoteRssi: RSSI=\(rssi) for \(address)")
                peripheral.delegate?.peripheral(peripheral, didReadRSSI: NSNumber(value: rssi), error: nil)
            } else {
                let error = connectionParityError(status: status, message: "Failed to read RSSI")
                logger.error("BluetoothGattCallback.onReadRemoteRssi: Failed for \(address) with status \(status)")
                peripheral.delegate?.peripheral(peripheral, didReadRSSI: NSNumber(value: rssi), error: error)
            }
        }
    }

    override func onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
        let address = gatt.device.address
        guard let peripheral = central.getPeripheral(for: address) else {
            logger.warning("BluetoothGattCallback.onMtuChanged: No peripheral found for \(address)")
            return
        }

        let error: Error?
        if status == BluetoothGatt.GATT_SUCCESS {
            logger.debug("BluetoothGattCallback.onMtuChanged: MTU=\(mtu) for \(address)")
            peripheral.updateMtu(mtu)
            error = nil
        } else {
            logger.warning("BluetoothGattCallback.onMtuChanged: Failed for \(address) with status \(status)")
            error = connectionParityError(status: status, message: "MTU change failed")
        }

        BleCallbackPipeline.shared.dispatch {
            peripheral.delegate?.peripheral(peripheral, didUpdateMtu: mtu, error: error)
        }
    }
}

#endif
#endif
