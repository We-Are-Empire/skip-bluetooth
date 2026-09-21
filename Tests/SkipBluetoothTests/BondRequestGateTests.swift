// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
import XCTest
import Foundation
@testable import SkipBluetooth

#if SKIP
import android.bluetooth.BluetoothDevice
#endif

final class BondRequestGateTests: XCTestCase {
    // MARK: - Parking

    /// The Pixel on 2026-09-21 (HW1): an encrypted write answered with the pairing prompt, and
    /// the stack started nothing — no dialog, no broadcast. The wait exists for that case, but
    /// it never asks first: for the first few hundred milliseconds a pairing the stack *has*
    /// started looks exactly like this.
    func testAnUnbondedDeviceWaitsBeforeAsking() {
        XCTAssertEqual(BondRequestGate.onPark(bondState: BondRequestGate.bondNone),
                       BondRequestDecision.awaitGrace)
    }

    /// The stack's own pairing got far enough to be visible. Asking now would be a second bond
    /// over a link already running SMP.
    func testADeviceAlreadyBondingIsWaitedFor() {
        XCTAssertEqual(BondRequestGate.onPark(bondState: BondRequestGate.bondBonding),
                       BondRequestDecision.park)
    }

    /// Fast "Just Works" bonding can complete between the callback thread reading the status and
    /// the main actor acting on it. The held operations then have their answer.
    func testADeviceBondedByTheTimeWeLookIsReplayed() {
        XCTAssertEqual(BondRequestGate.onPark(bondState: BondRequestGate.bondBonded),
                       BondRequestDecision.replay)
    }

    /// A state Android does not name is not a reason to declare a failure.
    func testAnUnknownBondStateIsWaitedFor() {
        XCTAssertEqual(BondRequestGate.onPark(bondState: -1), BondRequestDecision.park)
    }

    // MARK: - The grace period

    /// Nothing pairing when the grace period ends: this is the Pixel's hang, and the only shape
    /// that asks.
    func testAGracePeriodThatFoundNoPairingAsks() {
        XCTAssertEqual(BondRequestGate.onGrace(bondingSeen: false, bondState: BondRequestGate.bondNone),
                       BondRequestDecision.requestBond)
    }

    /// The ordinary path: the stack paired by itself and the broadcast arrived. We never ask.
    func testAGracePeriodLeavesTheStacksOwnPairingAlone() {
        XCTAssertEqual(BondRequestGate.onGrace(bondingSeen: true, bondState: BondRequestGate.bondNone),
                       BondRequestDecision.park)
    }

    /// The same, for a broadcast this process missed: the live state still says so.
    func testAGracePeriodLeavesAPairingItOnlySeesInTheStateAlone() {
        XCTAssertEqual(BondRequestGate.onGrace(bondingSeen: false, bondState: BondRequestGate.bondBonding),
                       BondRequestDecision.park)
    }

    /// A "Just Works" bond can land inside the grace period.
    func testAGracePeriodThatFindsABondReplays() {
        XCTAssertEqual(BondRequestGate.onGrace(bondingSeen: false, bondState: BondRequestGate.bondBonded),
                       BondRequestDecision.replay)
    }

    /// The grace period never fails a wait: nothing has been asked for yet.
    func testAGracePeriodNeverFails() {
        XCTAssertNotEqual(BondRequestGate.onGrace(bondingSeen: false, bondState: BondRequestGate.bondNone),
                          BondRequestDecision.fail)
        XCTAssertNotEqual(BondRequestGate.onGrace(bondingSeen: true, bondState: -1),
                          BondRequestDecision.fail)
    }

    // MARK: - The request

    func testATrueReturnIsWaitedFor() {
        XCTAssertEqual(BondRequestGate.afterRequest(started: true, bondState: BondRequestGate.bondNone),
                       BondRequestDecision.park)
    }

    /// `createBond()` answers false while a bond is already in flight, so the state decides.
    func testAFalseReturnWhileBondingIsWaitedFor() {
        XCTAssertEqual(BondRequestGate.afterRequest(started: false, bondState: BondRequestGate.bondBonding),
                       BondRequestDecision.park)
    }

    /// It also answers false when the bond already exists.
    func testAFalseReturnWhenAlreadyBondedIsReplayed() {
        XCTAssertEqual(BondRequestGate.afterRequest(started: false, bondState: BondRequestGate.bondBonded),
                       BondRequestDecision.replay)
    }

    /// The one shape that means no bond is coming: refused, and nothing started. A request the
    /// native layer drops because another device is mid-bond returns *true*, so it is not this
    /// shape — it ends at the window instead.
    func testAFalseReturnWithNoBondFails() {
        XCTAssertEqual(BondRequestGate.afterRequest(started: false, bondState: BondRequestGate.bondNone),
                       BondRequestDecision.fail)
    }

    // MARK: - The window

    /// The window is for a bond that never started. Once `BOND_BONDING` has been seen the user is
    /// at a PIN prompt, which takes as long as it takes.
    func testTheWindowDoesNotCutAPromptShort() {
        XCTAssertEqual(BondRequestGate.onCheck(bondingSeen: true, bondState: BondRequestGate.bondNone),
                       BondRequestDecision.park)
    }

    /// A broadcast this process missed still leaves the state to read.
    func testTheWindowDoesNotFireWhileBonding() {
        XCTAssertEqual(BondRequestGate.onCheck(bondingSeen: false, bondState: BondRequestGate.bondBonding),
                       BondRequestDecision.park)
    }

    func testTheWindowReplaysWhenTheBondLanded() {
        XCTAssertEqual(BondRequestGate.onCheck(bondingSeen: false, bondState: BondRequestGate.bondBonded),
                       BondRequestDecision.replay)
    }

    /// Ten seconds on, nothing bonding and nothing bonded: the operation is told, rather than
    /// waiting out the 37 minutes the Pixel waited.
    func testTheWindowFailsWhenNoBondEverStarted() {
        XCTAssertEqual(BondRequestGate.onCheck(bondingSeen: false, bondState: BondRequestGate.bondNone),
                       BondRequestDecision.fail)
    }

    // MARK: - Bounds

    /// 2.0 and 10.0, not 2 and 10: transpiled, an Int literal compares unequal to a Double.
    /// Together they bound a bond that never starts at twelve seconds.
    func testTheWaitIsBoundedAtTwelveSeconds() {
        XCTAssertEqual(BondRequestGate.stackPairingGraceSeconds, 2.0)
        XCTAssertEqual(BondRequestGate.bondStartTimeoutSeconds, 10.0)
    }

    /// The gate and the broadcast classifier both stand in for Android's `BOND_*` constants with
    /// literals, so they can be read off Android. On Android the platform defines them, and this
    /// is where both spellings are held to it. Off Android there is nothing to compare against
    /// and the test asserts nothing.
    func testTheBondStatesAreAndroidsConstants() {
        #if SKIP
        XCTAssertEqual(BondRequestGate.bondNone, BluetoothDevice.BOND_NONE)
        XCTAssertEqual(BondRequestGate.bondBonding, BluetoothDevice.BOND_BONDING)
        XCTAssertEqual(BondRequestGate.bondBonded, BluetoothDevice.BOND_BONDED)
        XCTAssertEqual(BondBroadcastClassifier.bondNone, BluetoothDevice.BOND_NONE)
        XCTAssertEqual(BondBroadcastClassifier.bondBonding, BluetoothDevice.BOND_BONDING)
        XCTAssertEqual(BondBroadcastClassifier.bondBonded, BluetoothDevice.BOND_BONDED)
        #endif
    }
}
