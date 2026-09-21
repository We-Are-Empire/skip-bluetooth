// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

/// What an operation held for a bond should do next.
enum BondRequestDecision: Equatable {
    /// A bond exists: replay the held operations.
    case replay
    /// No bond and none in flight: ask for one with `createBond()`.
    case requestBond
    /// Wait. A bond is in flight and takes as long as the user takes.
    case park
    /// No bond is coming: fail the held operations.
    case fail
}

/// Decides whether a pre-bond deferral asks Android to bond, waits, or gives up.
///
/// CoreBluetooth pairs on its own: the first secure operation raises the prompt and the stack
/// carries the bond through. Android makes no such promise — an encrypted operation answered
/// with `GATT_INSUFFICIENT_AUTHENTICATION` sometimes starts a bond and sometimes starts nothing
/// at all, with no prompt and no `ACTION_BOND_STATE_CHANGED` broadcast, and an operation held
/// for that broadcast then waits forever. `BluetoothDevice.createBond()` is the documented way
/// to ask, so the deferral asks.
///
/// `createBond()` is asynchronous: true means bonding will begin, false means it will not —
/// but it also answers false when a bond already exists or is already in flight, and when the
/// adapter is busy bonding another device. So the bond state, not the return value, is what
/// settles the outcome: the only shape that means "no bond is coming" is false with the state
/// still `BOND_NONE`.
///
/// Values are Android's `BluetoothDevice.BOND_*` constants as literals, so the gate compiles
/// and is tested off Android.
enum BondRequestGate {
    static let bondNone = 10
    static let bondBonding = 11
    static let bondBonded = 12

    /// How long a bond that was asked for is given to reach `BOND_BONDING`. The broadcast is
    /// the proof that a prompt exists; past it the wait is unbounded, because PIN entry takes
    /// as long as the user takes.
    static let bondStartTimeoutSeconds: Double = 10

    /// The peer answered an operation with the pairing prompt.
    static func onPark(bondState: Int) -> BondRequestDecision {
        if bondState == bondBonded { return .replay }
        if bondState == bondNone { return .requestBond }
        // `BOND_BONDING`, and any state Android does not name: waiting is what the deferral
        // already did, and it is the answer that can never cut a prompt short.
        return .park
    }

    /// `createBond()` has returned, and the bond state was read after it.
    static func afterRequest(started: Bool, bondState: Int) -> BondRequestDecision {
        if bondState == bondBonded { return .replay }
        if started || bondState == bondBonding { return .park }
        return .fail
    }

    /// The timeout armed for a bond that was asked for has elapsed.
    static func onCheck(bondingSeen: Bool, bondState: Int) -> BondRequestDecision {
        if bondState == bondBonded { return .replay }
        if bondingSeen || bondState == bondBonding { return .park }
        return .fail
    }
}
#endif
