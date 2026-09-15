// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

/// What one bond broadcast says about a device.
enum BondBroadcastOutcome: Equatable {
    /// The device is bonded.
    case bonded
    /// Bonding started.
    case bonding
    /// Bonding ended without a bond: the pairing was cancelled, timed out or refused.
    case pairingCancelled
    /// A bond that existed was removed.
    case unbonded
    /// The phone holds a bond whose keys the device no longer has.
    case bondLost
    /// Nothing a central acts on.
    case ignored
}

/// Classifies Android's bond broadcasts: `ACTION_BOND_STATE_CHANGED`, and `ACTION_KEY_MISSING`
/// (API 36).
///
/// CoreBluetooth reports a peer that removed its pairing information as
/// `CBError.peerRemovedPairingInformation`. Android reports the same connection with an ordinary
/// status (19, the remote terminated the link) and announces the loss separately: its stack
/// detects encryption failing for want of a key, tries to re-pair, and broadcasts
/// `ACTION_KEY_MISSING` while it still holds the bond. Key-missing on a device the phone is
/// bonded to is that loss. On a device with no bond it says nothing a user can act on.
///
/// Values are Android's: the actions' strings and `BluetoothDevice.BOND_NONE` (10),
/// `BOND_BONDING` (11) and `BOND_BONDED` (12). They are literals so the classifier compiles and
/// is tested off Android, and so a compile SDK below 36 still builds.
enum BondBroadcastClassifier {
    static let actionBondStateChanged = "android.bluetooth.device.action.BOND_STATE_CHANGED"
    static let actionKeyMissing = "android.bluetooth.device.action.KEY_MISSING"
    static let bondNone = 10
    static let bondBonding = 11
    static let bondBonded = 12

    /// - Parameters:
    ///   - action: The broadcast's action.
    ///   - bondState: `EXTRA_BOND_STATE` for a bond-state change; the device's current bond state
    ///     for key-missing.
    ///   - previousBondState: `EXTRA_PREVIOUS_BOND_STATE` for a bond-state change; unused for
    ///     key-missing.
    static func classify(action: String?, bondState: Int, previousBondState: Int) -> BondBroadcastOutcome {
        if action == actionKeyMissing {
            return bondState == bondBonded ? .bondLost : .ignored
        }
        guard action == actionBondStateChanged else { return .ignored }
        if bondState == bondBonded { return .bonded }
        if bondState == bondBonding { return .bonding }
        if bondState == bondNone {
            return previousBondState == bondBonding ? .pairingCancelled : .unbonded
        }
        return .ignored
    }
}
#endif
