// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

/// What an operation held for a bond should do next.
enum BondRequestDecision: Equatable {
    /// A bond exists: replay the held operations.
    case replay
    /// Look again shortly. The stack may be pairing on its own, and asking over the top of it
    /// is what breaks the pairing already in flight.
    case awaitGrace
    /// Nothing is pairing: ask for a bond with `createBond()`.
    case requestBond
    /// Wait. A bond is in flight and takes as long as the user takes.
    case park
    /// No bond is coming: fail the held operations.
    case fail
}

/// Decides whether a pre-bond deferral asks Android to bond, waits, or gives up.
///
/// CoreBluetooth pairs on its own: the first secure operation raises the prompt and the stack
/// carries the bond through. Android does that too, most of the time — its GATT layer starts
/// encryption when a peer answers `GATT_INSUFFICIENT_AUTHENTICATION`, and a prompt follows
/// about 200 ms later. But not always: on the Pixel the same encrypted write twice produced no
/// prompt, no `ACTION_BOND_STATE_CHANGED` broadcast and no failure, and the operation held for
/// that broadcast waited 37 minutes. `BluetoothDevice.createBond()` is the documented way to
/// ask, so the deferral asks — second, not first.
///
/// Second matters. Java's bond state reaches `BOND_BONDING` only once a PIN or consent request
/// arrives, so for the first few hundred milliseconds a pairing the stack has already started
/// is indistinguishable from no pairing at all: the state still reads `BOND_NONE` and no
/// broadcast has been sent. A `createBond()` issued into that gap is not rejected — it bonds a
/// second time over a link already running SMP, which can abort the pairing that was working.
/// So `BOND_NONE` buys a short grace period first, and only a grace period that ends with
/// nothing pairing asks.
///
/// The return value of `createBond()` settles less than it appears to. True means the request
/// was accepted for dispatch, not that bonding will begin — when another device is mid-bond the
/// native layer drops it silently, with no broadcast, and that shape ends at the window rather
/// than at the false branch. So the bond state, not the return value, is what decides: the one
/// shape that means "no bond is coming" is false with the state still `BOND_NONE`.
///
/// Values are Android's `BluetoothDevice.BOND_*` constants as literals, so the gate compiles
/// and is tested off Android.
enum BondRequestGate {
    static let bondNone = 10
    static let bondBonding = 11
    static let bondBonded = 12

    /// How long the stack gets to start its own pairing before we ask for one. Comfortably
    /// longer than the ~200 ms a prompt takes to follow an encrypted write, and short enough
    /// that a stack which started nothing is not left sitting.
    static let stackPairingGraceSeconds: Double = 2

    /// How long a bond that was asked for is given to reach `BOND_BONDING`. The broadcast is
    /// the proof that a prompt exists; past it the wait is unbounded, because PIN entry takes
    /// as long as the user takes.
    static let bondStartTimeoutSeconds: Double = 10

    /// The peer answered an operation with the pairing prompt.
    static func onPark(bondState: Int) -> BondRequestDecision {
        if bondState == bondBonded { return .replay }
        if bondState == bondNone { return .awaitGrace }
        // `BOND_BONDING`, and any state Android does not name: waiting is what the deferral
        // already did, and it is the answer that can never cut a prompt short.
        return .park
    }

    /// The grace period has elapsed, and nothing has ended the wait.
    static func onGrace(bondingSeen: Bool, bondState: Int) -> BondRequestDecision {
        if bondState == bondBonded { return .replay }
        // The stack got there by itself: leave its pairing alone and wait it out.
        if bondingSeen || bondState == bondBonding { return .park }
        return .requestBond
    }

    /// `createBond()` has returned, and the bond state was read after it.
    static func afterRequest(started: Bool, bondState: Int) -> BondRequestDecision {
        if bondState == bondBonded { return .replay }
        if started || bondState == bondBonding { return .park }
        return .fail
    }

    /// The window armed for a bond that was asked for has elapsed.
    static func onCheck(bondingSeen: Bool, bondState: Int) -> BondRequestDecision {
        if bondState == bondBonded { return .replay }
        if bondingSeen || bondState == bondBonding { return .park }
        return .fail
    }
}
#endif
